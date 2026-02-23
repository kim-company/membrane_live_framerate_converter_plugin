defmodule Membrane.LiveFramerateConverter do
  @moduledoc """
  A Membrane filter that stabilizes the output framerate for raw video by
  dropping or duplicating buffers.

  The element starts producing output once it has buffered enough input to
  leave the loading phase (`queue_capacity` buffers). After that a timer ticks
  at the target framerate, emitting one buffer per tick.

  ## Slot-based frame matching

  The output timeline is divided into consecutive *slots*, each one period
  wide (`[starts_at, ends_at)`). Every input buffer is matched to the slot
  whose time window contains the buffer's PTS. When multiple input buffers
  fall in the same slot the last one wins (higher input framerate → frames
  are dropped). When no input buffer falls in a slot the previous frame is
  carried forward (lower input framerate → frames are duplicated).

  ## Stall handling (`:duplicate` policy)

  When no input arrives for an extended time the queue drains and the element
  enters *stall* mode. In this mode each timer tick duplicates the last
  received frame into the next output slot, keeping the output cadence
  constant. The output timeline keeps advancing.

  When input resumes, the first arriving buffer is placed directly into the
  **next available output slot** — regardless of the buffer's source PTS.
  This means fresh content appears in the output as soon as possible, with
  no accumulated delay from the stall period.

  Because the source PTS timeline is now behind the output timeline, a
  `pts_offset` is computed (`output_slot_start − source_pts`) and applied to
  all subsequent input buffers before slot matching. This keeps the two
  timelines aligned going forward. Multiple stalls simply recompute the
  offset each time.

  The result is a **gapless, strictly monotonic** output at exactly the
  target period throughout normal operation, stalls, and recoveries.

  ## Stall handling (`:halt` policy)

  Output stops while the queue is empty. When input resumes, buffers go
  through normal slot matching and output picks up where it left off.

  ## Notifications

  - `{:frame_dropped, pts, threshold}` — a late buffer arrived (PTS < current slot start)
  - `{:frame_duplicated, pts}` — a frame was duplicated to fill a stall gap
  - `{:input_stalled, pts}` — queue became empty during active playback (sent once per stall)
  - `{:input_resumed, pts}` — first buffer after a `:duplicate`-policy stall; `pts` is the
    original source PTS of the buffer that triggered recovery
  """

  use Membrane.Filter
  alias Membrane.RawVideo
  alias Membrane.Time
  alias Membrane.Buffer

  defmodule Slot do
    @moduledoc false
    defstruct [:starts_at, :ends_at, :buffer]

    def new(starts_at, duration) do
      %__MODULE__{
        starts_at: starts_at,
        ends_at: starts_at + duration
      }
    end

    def next(%__MODULE__{} = prev) do
      %__MODULE__{
        starts_at: prev.ends_at,
        ends_at: prev.ends_at + (prev.ends_at - prev.starts_at)
      }
      |> set(prev.buffer)
    end

    def next_empty(%__MODULE__{} = prev) do
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
       stalled?: false,
       pts_offset: 0
     }}
  end

  @impl true
  def handle_playing(_ctx, state) do
    {[demand: {:input, state.queue_capacity}], state}
  end

  @impl true
  def handle_stream_format(
        :input,
        %RawVideo{} = format,
        _context,
        %{framerate: framerate} = state
      ) do
    {[stream_format: {:output, %{format | framerate: framerate}}], state}
  end

  @impl true
  def handle_buffer(:input, buffer, _ctx, %{loading?: true} = state) do
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
    push_buffer(state, buffer)
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
    actions =
      if state.stalled?,
        do: [],
        else: [notify_parent: {:input_stalled, state.current_slot.ends_at}]

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
    actions =
      if state.stalled?,
        do: [],
        else: [notify_parent: {:input_stalled, state.current_slot.ends_at}]

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
    if state.stalled? and state.stall_policy == :duplicate do
      # Stall recovery: the output timeline has been advancing via duplication
      # while input was stalled. Don't try to slot-match this buffer — just
      # place it in the next output slot so it appears immediately, then
      # compute an offset so subsequent input buffers map correctly onto the
      # output timeline.
      new_offset = state.current_slot.ends_at - buffer.pts

      new_slot =
        Slot.new(state.current_slot.ends_at, state.period)
        |> Slot.set(buffer)

      state = %{
        state
        | current_slot: new_slot,
          current_slot_in_queue?: false,
          pts_offset: new_offset,
          stalled?: false,
          last_buffer: new_slot.buffer,
          queue: :queue.new()
      }

      state =
        if state.loading? do
          state
        else
          %{state | queue: :queue.in(new_slot, state.queue), current_slot_in_queue?: true}
        end

      {[notify_parent: {:input_resumed, buffer.pts}], state}
    else
      buffer = %{buffer | pts: buffer.pts + state.pts_offset}
      do_push_buffer(state, buffer)
    end
  end

  defp do_push_buffer(state, buffer) do
    cond do
      Slot.accepts?(state.current_slot, buffer) ->
        accept_buffer(state, buffer)

      Slot.old?(state.current_slot, buffer) ->
        {[notify_parent: {:frame_dropped, buffer.pts, state.current_slot.starts_at}], state}

      true ->
        advance_slot_and_retry(state, buffer)
    end
  end

  defp accept_buffer(state, buffer) do
    slot =
      if state.stall_policy == :halt do
        %{state.current_slot | buffer: %{buffer | dts: nil}}
      else
        Slot.set(state.current_slot, buffer)
      end

    state = %{state | current_slot: slot, last_buffer: slot.buffer}

    state = maybe_enqueue_current_slot(state)

    {[], state}
  end

  defp advance_slot_and_retry(state, buffer) do
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

    do_push_buffer(
      %{state | queue: queue, current_slot: current_slot, current_slot_in_queue?: false},
      buffer
    )
  end

  defp maybe_enqueue_current_slot(state) do
    if state.loading? or state.current_slot_in_queue? do
      state
    else
      %{state | queue: :queue.in(state.current_slot, state.queue), current_slot_in_queue?: true}
    end
  end

  defp enqueue_current_slot(state) do
    if state.current_slot != nil and state.current_slot.buffer != nil and
         not state.current_slot_in_queue? do
      {[],
       %{state | queue: :queue.in(state.current_slot, state.queue), current_slot_in_queue?: true}}
    else
      {[], state}
    end
  end

  defp build_demand_action(state) do
    preferred = state.queue_capacity - :queue.len(state.queue)
    if preferred <= 0, do: [], else: [demand: {:input, preferred}]
  end
end
