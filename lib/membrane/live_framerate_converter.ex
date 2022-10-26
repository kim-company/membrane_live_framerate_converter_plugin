defmodule Membrane.LiveFramerateConverter do
  @moduledoc """
    Drops or duplicates buffers producing a stable output framerate, starts
    when the first packet one is received.
  """

  use Membrane.Filter
  alias Membrane.RawVideo
  alias Membrane.Time
  alias Membrane.LiveFramerateConverter.FrameWindow

  require Logger

  # wait time before the timer starts ticking. When input buffers come in
  # realtime, it is mandatory to wait some ms before closing the window
  # otherwise the filter won't receive all buffers belonging to this timeframe.
  @timer_delay_ms 500

  def_options(
    framerate: [
      spec: {pos_integer(), pos_integer()},
      default: {30, 1},
      description: """
      Target framerate.
      """
    ]
  )

  def_input_pad(:input, caps: {RawVideo, aligned: true}, demand_unit: :buffers)
  def_output_pad(:output, caps: {RawVideo, aligned: true}, mode: :push)

  @impl true
  def handle_init(%__MODULE__{} = opts) do
    {:ok,
     %{
       framerate: opts.framerate,
       window: nil,
       early_comers: [],
       closed?: false
     }}
  end

  @impl true
  def handle_prepared_to_playing(_ctx, state) do
    {{:ok, demand: :input}, state}
  end

  @impl true
  def handle_process(:input, buffer, _ctx, state = %{window: nil}) do
    Process.send_after(self(), :start_timer, @timer_delay_ms)
    window = FrameWindow.new(state.framerate, buffer.pts)
    {{:ok, demand: :input}, %{state | window: window}}
  end

  def handle_process(:input, buffer, _ctx, state) do
    if FrameWindow.accepts?(state.window, buffer) do
      {{:ok, demand: :input}, %{state | window: FrameWindow.insert!(state.window, buffer)}}
    else
      if FrameWindow.is_old?(state.window, buffer) do
        Logger.warn("dropping late buffer: #{inspect(buffer)}")
        {:ok, state}
      else
        {:ok, %{state | early_comers: [buffer | state.early_comers]}}
      end
    end
  end

  @impl true
  def handle_other(:start_timer, _ctx, state) do
    # using parent clock w/o knowing the implications.
    {_, seconds} = state.framerate
    {{:ok, start_timer: {:timer, Time.seconds(seconds)}}, state}
  end

  defp fulfill_demand(state) do
    window = FrameWindow.fill_missing_frames(state.window)

    buffer_actions =
      window
      |> FrameWindow.get_buffers()
      |> Enum.map(fn x -> {:buffer, {:output, x}} end)

    # Take care of early comers. Those that are too new need to be buffered
    # again.
    window = FrameWindow.next(window)
    early = Enum.reverse(state.early_comers)

    {accepted, early_comers} =
      Enum.split_while(early, fn x ->
        FrameWindow.accepts?(window, x)
      end)

    window =
      Enum.reduce(accepted, window, fn x, window ->
        FrameWindow.insert!(window, x)
      end)

    {{:ok, buffer_actions ++ [demand: :input]}, %{state | early_comers: Enum.reverse(early_comers), window: window}}
  end

  @impl true
  def handle_tick(:timer, _ctx, state) do
    if state.closed? and length(state.early_comers) == 0 do
      buffer_actions =
        state.window
        |> FrameWindow.freeze()
        |> FrameWindow.fill_missing_frames()
        |> FrameWindow.get_buffers()
        |> Enum.map(fn x -> {:buffer, {:output, x}} end)

      {{:ok, buffer_actions ++ [end_of_stream: :output, stop_timer: :timer]},
       %{state | window: nil}}
    else
      fulfill_demand(state)
    end
  end

  @impl true
  def handle_end_of_stream(:input, _ctx, state) do
    {:ok, %{state | closed?: true}}
  end
end
