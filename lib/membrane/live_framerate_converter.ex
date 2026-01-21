defmodule Membrane.LiveFramerateConverter do
  @moduledoc """
    Drops or duplicates buffers producing a stable output framerate, starts
    when the first packet one is received.
  """

  use Membrane.Filter
  alias Membrane.RawVideo
  alias Membrane.Time
  alias Membrane.Buffer
  require Membrane.Logger

  defmodule Slot do
    defstruct [:starts_at, :ends_at, :buffer]

    def new(starts_at, duration) do
      %__MODULE__{
        starts_at: starts_at,
        ends_at: starts_at + duration
      }
    end

    def next(prev = %__MODULE__{}) do
      %__MODULE__{
        starts_at: prev.ends_at,
        ends_at: prev.ends_at + (prev.ends_at - prev.starts_at)
      }
      |> set(prev.buffer)
    end

    def next_empty(prev = %__MODULE__{}) do
      %__MODULE__{
        starts_at: prev.ends_at,
        ends_at: prev.ends_at + (prev.ends_at - prev.starts_at),
        buffer: nil
      }
    end

    def accepts?(slot, %Buffer{pts: pts}) do
      pts >= slot.starts_at and pts < slot.ends_at
    end

    def old?(slot, %Buffer{pts: pts}) do
      pts <= slot.starts_at
    end

    def set(slot, %Membrane.Buffer{} = buffer) do
      %{slot | buffer: %{buffer | pts: slot.starts_at, dts: nil}}
    end
  end

  def_options framerate: [
                spec: {pos_integer(), pos_integer()},
                default: {30, 1},
                description: """
                Target framerate.
                """
              ],
              queue_capacity: [
                spec: pos_integer(),
                default: 200,
                description: """
                How many buffer this element will collect internally before starting its job.
                """
              ],
              stall_policy: [
                spec: :duplicate | :halt,
                default: :duplicate,
                description: """
                Policy to use when input stops providing data:
                - `:duplicate` - duplicate the last received frame to maintain output framerate (default)
                - `:halt` - stop outputting frames until input resumes or end of stream
                """
              ]

  def_input_pad :input,
    accepted_format: %RawVideo{aligned: true},
    flow_control: :manual,
    demand_unit: :buffers

  def_output_pad :output, accepted_format: %RawVideo{aligned: true}, flow_control: :push

  @impl true
  def handle_init(_ctx, opts) do
    {frames, seconds} = opts.framerate
    period = round(Time.seconds(seconds) / frames)

    {[],
     %{
       period: period,
       framerate: opts.framerate,
       queue: :queue.new(),
       queue_capacity: opts.queue_capacity,
       loading?: true,
       current_slot: nil,
       current_slot_in_queue?: false,
       last_buffer: nil,
       stall_policy: opts.stall_policy,
       stalled?: false
     }}
  end

  @impl true
  def handle_playing(_ctx, state) do
    {[demand: {:input, state.queue_capacity}], state}
  end

  @impl true
  def handle_stream_format(:input, %RawVideo{} = format, _context, %{framerate: framerate} = state) do
    {[stream_format: {:output, %{format | framerate: framerate}}], state}
  end

  @impl true
  def handle_buffer(:input, buffer, _ctx, state = %{loading?: true}) do
    state =
      if state.current_slot == nil do
        %{state | current_slot: Slot.new(buffer.pts, state.period)}
      else
        state
      end

    {push_actions, state} = push_buffer(state, buffer)

    buffered_count =
      :queue.len(state.queue) +
        if state.current_slot != nil and state.current_slot.buffer != nil and
             not state.current_slot_in_queue? do
          1
        else
          0
        end

    if buffered_count >= state.queue_capacity do
      # using parent clock w/o knowing the implications.
      {enqueue_actions, state} = enqueue_current_slot(state)

      {push_actions ++ enqueue_actions ++ [start_timer: {:timer, state.period}],
       %{state | loading?: false}}
    else
      {push_actions ++ build_demand_action(state), state}
    end
  end

  def handle_buffer(:input, buffer, _ctx, state) do
    resume? = state.stalled? and not Slot.old?(state.current_slot, buffer)
    {actions, state} = push_buffer(state, buffer)

    if resume? and state.stall_policy == :duplicate do
      {[notify_parent: {:input_resumed, buffer.pts}] ++ actions, %{state | stalled?: false}}
    else
      {actions, state}
    end
  end

  @impl true
  def handle_tick(:timer, ctx, state) do
    case :queue.out(state.queue) do
      {{:value, :end_of_stream}, queue} ->
        {[stop_timer: :timer, end_of_stream: :output], %{state | queue: queue}}

      {{:value, %Slot{buffer: buffer}}, queue} ->
        state =
          if state.current_slot_in_queue? and state.current_slot != nil and
               state.current_slot.starts_at == buffer.pts do
            current_slot = %{state.current_slot | buffer: nil}
            %{state | queue: queue, current_slot_in_queue?: false, current_slot: current_slot}
          else
            %{state | queue: queue}
          end

        actions = build_demand_action(state) ++ [buffer: {:output, buffer}]

        {actions, state}

      {:empty, _queue} ->
        handle_queue_empty(state.stall_policy, ctx, state)
    end
  end

  defp handle_queue_empty(:duplicate, ctx, state) do
    # Send stall notification only on first stall detection
    actions = if not state.stalled?, do: [notify_parent: {:input_stalled, state.current_slot.ends_at}], else: []

    if state.last_buffer == nil do
      {actions, %{state | stalled?: true}}
    else
      next_slot = Slot.next_empty(state.current_slot)
      duplicated = %{state.last_buffer | pts: next_slot.starts_at, dts: nil}
      next_slot = %{next_slot | buffer: duplicated}

      # Send duplication notification
      actions = actions ++ [notify_parent: {:frame_duplicated, duplicated.pts}]

      state = %{
        state
        | stalled?: true,
          queue: :queue.in(next_slot, state.queue),
          current_slot: next_slot,
          current_slot_in_queue?: true
      }

      {new_actions, new_state} = handle_tick(:timer, ctx, state)
      {actions ++ new_actions, new_state}
    end
  end

  defp handle_queue_empty(:halt, _ctx, state) do
    # Don't output anything, timer keeps running
    # Will output when queue has data again

    # Send stall notification only on first stall detection
    actions = if not state.stalled?, do: [notify_parent: {:input_stalled, state.current_slot.ends_at}], else: []

    {actions, %{state | stalled?: true}}
  end

  @impl true
  def handle_end_of_stream(:input, _ctx, state) do
    actions =
      if state.loading? do
        # timer is started when the loading phase finishes; in this case, it
        # never will!
        [start_timer: {:timer, state.period}]
      else
        []
      end

    state = %{state | queue: :queue.in(:end_of_stream, state.queue), loading?: false}
    {actions, state}
  end

  defp push_buffer(state, buffer) do
    if Slot.accepts?(state.current_slot, buffer) do
      slot =
        if state.stall_policy == :halt do
          %{state.current_slot | buffer: %{buffer | dts: nil}}
        else
          Slot.set(state.current_slot, buffer)
        end

      state = %{state | current_slot: slot, last_buffer: slot.buffer}

      state =
        if not state.loading? and not state.current_slot_in_queue? do
          %{state | queue: :queue.in(slot, state.queue), current_slot_in_queue?: true}
        else
          state
        end

      {[], state}
    else
      if Slot.old?(state.current_slot, buffer) do
        {[notify_parent: {:frame_dropped, buffer.pts, state.current_slot.starts_at}], state}
      else
        # Only push slot to queue if it has a buffer (don't push empty slots)
        queue =
          if state.current_slot.buffer != nil and not state.current_slot_in_queue? do
            :queue.in(state.current_slot, state.queue)
        else
          state.queue
        end

        current_slot =
          if state.stall_policy == :duplicate and state.loading? and
               state.current_slot.buffer != nil do
            Slot.next(state.current_slot)
          else
            Slot.next_empty(state.current_slot)
          end

        push_buffer(
          %{state | queue: queue, current_slot: current_slot, current_slot_in_queue?: false},
          buffer
        )
      end
    end
  end

  defp enqueue_current_slot(state) do
    if state.current_slot != nil and state.current_slot.buffer != nil and
         not state.current_slot_in_queue? do
      {[], %{state | queue: :queue.in(state.current_slot, state.queue), current_slot_in_queue?: true}}
    else
      {[], state}
    end
  end

  defp build_demand_action(state) do
    preferred = state.queue_capacity - :queue.len(state.queue)
    if preferred <= 0, do: [], else: [demand: {:input, preferred}]
  end
end
