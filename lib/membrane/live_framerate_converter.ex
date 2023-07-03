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
        ends_at: Ratio.add(starts_at, duration)
      }
    end

    def next(prev = %__MODULE__{}) do
      %__MODULE__{
        starts_at: prev.ends_at,
        ends_at: Ratio.add(prev.ends_at, Ratio.sub(prev.ends_at, prev.starts_at))
      }
      |> set(prev.buffer)
    end

    def accepts?(slot, %Buffer{pts: pts}) do
      Ratio.gte?(pts, slot.starts_at) and Ratio.lte?(pts, slot.ends_at)
    end

    def old?(slot, %Buffer{pts: pts}) do
      Ratio.lte?(pts, slot.starts_at)
    end

    def set(slot, buffer) do
      %{slot | buffer: %Membrane.Buffer{buffer | pts: slot.starts_at, dts: nil}}
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
              ]

  def_input_pad(:input, accepted_format: %RawVideo{aligned: true}, demand_unit: :buffers)
  def_output_pad(:output, accepted_format: %RawVideo{aligned: true}, mode: :push)

  @impl true
  def handle_init(_ctx, opts) do
    {frames, seconds} = opts.framerate
    period = round(Time.seconds(seconds) / frames)

    {[],
     %{
       period: period,
       framerate: opts.framerate,
       queue: Qex.new(),
       queue_capacity: opts.queue_capacity,
       loading?: true,
       current_slot: nil
     }}
  end

  @impl true
  def handle_playing(_ctx, state) do
    {[demand: {:input, state.queue_capacity}], state}
  end

  @impl true
  def handle_stream_format(:input, format, _context, %{framerate: framerate} = state) do
    {[stream_format: {:output, %RawVideo{format | framerate: framerate}}], state}
  end

  @impl true
  def handle_process_list(:input, buffers, _ctx, state = %{loading?: true}) do
    state =
      if state.current_slot == nil do
        buffer = List.first(buffers)
        %{state | current_slot: Slot.new(buffer.pts, state.period)}
      else
        state
      end

    state = Enum.reduce(buffers, state, fn buffer, state -> push_buffer(state, buffer) end)

    if Enum.count(state.queue) >= state.queue_capacity do
      # using parent clock w/o knowing the implications.
      {[start_timer: {:timer, state.period}], %{state | loading?: false}}
    else
      {build_demand_action(state), state}
    end
  end

  def handle_process_list(:input, buffers, _ctx, state) do
    state = Enum.reduce(buffers, state, fn buffer, state -> push_buffer(state, buffer) end)
    {[], state}
  end

  @impl true
  def handle_tick(:timer, ctx, state) do
    case Qex.pop(state.queue) do
      {{:value, :end_of_stream}, queue} ->
        {[stop_timer: :timer, end_of_stream: :output], %{state | queue: queue}}

      {{:value, %Slot{buffer: buffer}}, queue} ->
        state = %{state | queue: queue}
        {build_demand_action(state) ++ [buffer: {:output, buffer}], state}

      {:empty, _queue} ->
        Membrane.Logger.warn("queue is empty, duplicating buffers")

        # Trick to generate a buffer that starts at the beginning of the next
        # slot with duplicated contents of the last one.
        %Slot{buffer: next} = Slot.next(state.current_slot)

        # TODO: slots are overlapping and the next buffer would be accepted by
        # the previous slot as well. This is a workaround to avoid dangerous
        # changes at this time.
        next = %Membrane.Buffer{next | pts: next.pts + Time.milliseconds(5)}
        state = push_buffer(state, next)
        handle_tick(:timer, ctx, state)
    end
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

    state = %{state | queue: Qex.push(state.queue, :end_of_stream), loading?: false}
    {actions, state}
  end

  defp push_buffer(state, buffer) do
    if Slot.accepts?(state.current_slot, buffer) do
      %{state | current_slot: Slot.set(state.current_slot, buffer)}
    else
      if Slot.old?(state.current_slot, buffer) do
        Membrane.Logger.warn(
          "buffer with pts @ #{inspect(buffer.pts)} received, min threashold is @ #{inspect(state.current_slot.starts_at)} - dropping"
        )

        state
      else
        queue = Qex.push(state.queue, state.current_slot)
        current_slot = Slot.next(state.current_slot)
        push_buffer(%{state | queue: queue, current_slot: current_slot}, buffer)
      end
    end
  end

  defp build_demand_action(state) do
    preferred = state.queue_capacity - Enum.count(state.queue)
    if preferred <= 0, do: [], else: [demand: {:input, preferred}]
  end
end
