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
    use Ratio

    defstruct [:starts_at, :ends_at, :buffer]

    def new(starts_at, duration) do
      %__MODULE__{
        starts_at: starts_at,
        ends_at: starts_at + duration,
      }
    end

    def next(prev = %__MODULE__{}) do
      %__MODULE__{
        starts_at: prev.ends_at,
        ends_at: prev.ends_at + (prev.ends_at - prev.starts_at),
        buffer: prev.buffer
      }
    end

    def accepts?(slot, %Buffer{pts: pts}) do
      pts >= slot.starts_at and pts <= slot.ends_at
    end

    def set(slot, buffer) do
      %{slot | buffer: buffer}
    end

    def is_filled?(%{buffer: buffer}) do
      buffer != nil
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

  def_input_pad(:input, caps: {RawVideo, aligned: true}, demand_unit: :buffers)
  def_output_pad(:output, caps: {RawVideo, aligned: true}, mode: :push)

  @impl true
  def handle_init(%__MODULE__{} = opts) do
    {frames, seconds} = opts.framerate
    period =
      Time.seconds(seconds) / frames
      |> round()
      |> Time.as_milliseconds()

    {:ok,
     %{
      period: period,
       framerate: opts.framerate,
        queue: Q.new(opts.telemetry_label),
       queue_capacity: opts.queue_capacity,
        loading: true,
        current_slot: nil
     }}
  end

  @impl true
  def handle_prepared_to_playing(_ctx, state) do
    {{:ok, demand: {:input, state.queue_capacity}}, state}
  end

  @impl true
  def handle_caps(:input, %RawVideo{} = caps, _context, %{framerate: framerate} = state) do
    {{:ok, caps: {:output, %{caps | framerate: framerate}}}, state}
  end

  @impl true
  def handle_process(:input, buffer, _ctx, state = %{loading: true}) do
    state = if state.current_slot == nil do
      %{state | current_slot: Slot.new(buffer.pts, state.period)}
    else
      state
    end

    state = push_buffer(state, buffer)

    if state.queue.count >= state.queue_capacity do
      # using parent clock w/o knowing the implications.
      {{:ok, [start_timer: {:timer, state.period}]}, %{state | loading: false}}
    else
      {:ok, state}
    end
  end

  def handle_process(:input, buffer, _ctx, state) do
    {:ok, push_buffer(state, buffer)}
  end

  @impl true
  def handle_tick(:timer, _ctx, state) do
    case Q.pop(state.queue) do
      {{:value, :end_of_stream}, queue} ->
        {{:ok, stop_timer: :timer, end_of_stream: :output}, %{state | queue: queue}} |> dbg()
      {{:value, slot}, queue} ->
        buffer = Slot.prepare_and_get_buffer(slot)
      {{:ok, demand: {:input, 1}, buffer: {:output, buffer}}, %{state | queue: queue}} |> dbg()
      {:empty, _queue} ->
        raise "live framerate converter reached end of the queue"
    end
  end

  @impl true
  def handle_end_of_stream(:input, _ctx, state = %{loading: true}) do
    # reached end-of-stream before completing loading phase. Start the timer and proceed.
    {{:ok, [start_timer: {:timer, state.period}]}, %{state | queue: Q.push(state.queue, :end_of_stream), loading: false}} |> dbg()
  end

  def handle_end_of_stream(:input, _ctx, state) do
    {:ok, %{state | queue: Q.push(state.queue, :end_of_stream)}} |> dbg()
  end

  defp push_buffer(state, buffer) do
    if Slot.accepts?(state.current_slot, buffer) do
      %{state | current_slot: Slot.set(state.current_slot, buffer)} |> dbg()
    else
      queue = Q.push(state.queue, state.current_slot)
      current_slot = Slot.next(state.current_slot)
      push_buffer(%{state | queue: queue, current_slot: current_slot}, buffer) |> dbg()
    end
  end
end
