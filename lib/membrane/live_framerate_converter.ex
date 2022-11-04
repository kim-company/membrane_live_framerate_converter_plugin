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
              ],
              telemetry_label: [
                spec: String.t(),
                default: "live-framerate-converter"
              ]

  def_input_pad(:input, caps: {RawVideo, aligned: true}, demand_unit: :buffers, mode: :push)
  def_output_pad(:output, caps: {RawVideo, aligned: true}, mode: :push)

  @impl true
  def handle_init(%__MODULE__{} = opts) do
    {frames, seconds} = opts.framerate
    period = round(Time.seconds(seconds) / frames)

    {:ok,
     %{
       period: period,
       framerate: opts.framerate,
       queue: Q.new(opts.telemetry_label),
       queue_capacity: opts.queue_capacity,
       loading?: true,
       current_slot: nil
     }}
  end

  @impl true
  def handle_caps(:input, %RawVideo{} = caps, _context, %{framerate: framerate} = state) do
    {{:ok, caps: {:output, %{caps | framerate: framerate}}}, state}
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

    if state.queue.count >= state.queue_capacity do
      # using parent clock w/o knowing the implications.
      {{:ok, [start_timer: {:timer, state.period}]}, %{state | loading?: false}}
    else
      {:ok, state}
    end
  end

  def handle_process_list(:input, buffers, _ctx, state) do
    state = Enum.reduce(buffers, state, fn buffer, state -> push_buffer(state, buffer) end)
    {:ok, state}
  end

  @impl true
  def handle_tick(:timer, ctx, state) do
    case Q.pop(state.queue) do
      {{:value, :end_of_stream}, queue} ->
        {{:ok, stop_timer: :timer, end_of_stream: :output}, %{state | queue: queue}}

      {{:value, %Slot{buffer: buffer}}, queue} ->
        {{:ok, buffer: {:output, buffer}}, %{state | queue: queue}}

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

    state = %{state | queue: Q.push(state.queue, :end_of_stream), loading?: false}
    {{:ok, actions}, state}
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
        queue = Q.push(state.queue, state.current_slot)
        current_slot = Slot.next(state.current_slot)
        push_buffer(%{state | queue: queue, current_slot: current_slot}, buffer)
      end
    end
  end
end
