defmodule Membrane.LiveFramerateConverterTest do
  use ExUnit.Case

  alias Membrane.Testing.Pipeline
  alias Membrane.RawVideo

  defmodule Source do
    @moduledoc """
      Same as Membrane.Testing.Source but instead of asking of paylods in the
      configuration it allows to provide full buffers, giving full control on
      the caller on buffer's pts and dts.
    """
    use Membrane.Source

    def_output_pad(:output, caps: :any)

    def_options(
      output: [
        spec: Enum.t(),
        default: [],
        description: """
        """
      ],
      caps: [
        spec: struct(),
        default: %Membrane.RemoteStream{},
        description: """
        Caps to be sent before the `output`.
        """
      ]
    )

    @impl true
    def handle_init(opts) do
      opts = Map.from_struct(opts)
      {:ok, opts}
    end

    @impl true
    def handle_prepared_to_playing(_ctx, state) do
      {{:ok, caps: {:output, state.caps}}, state}
    end

    @impl true
    def handle_demand(:output, size, :buffers, _ctx, state) do
      {actions, state} = get_actions(state, size)
      {{:ok, actions}, state}
    end

    defp get_actions(%{output: output} = state, size) do
      {buffers, output} = Enum.split(output, size)

      actions =
        case output do
          [] -> [buffer: {:output, buffers}, end_of_stream: :output]
          _non_empty -> [buffer: {:output, buffers}]
        end

      {actions, %{state | output: output}}
    end
  end

  defp parse_fixture(path) do
    path
    |> File.stream!()
    |> Stream.map(&String.trim/1)
    |> Stream.map(&Jason.decode!/1)
    |> Stream.map(fn %{"pts" => pts} -> %Membrane.Buffer{pts: pts, dts: pts, payload: <<>>} end)
    |> Enum.into([])
  end

  defp input_duration(buffers) do
    %{pts: first} = List.first(buffers)
    %{pts: last} = List.last(buffers)
    last - first
  end

  defp assert_received_count(pid, expected, counter) when expected == counter do
    receive do
      {Pipeline, ^pid, {:handle_notification, {{:buffer, _}, :sink}}} ->
        raise "buffer overflow: (#{counter}/#{expected})"

      {Pipeline, ^pid, {:handle_element_end_of_stream, {:sink, :input}}} ->
        :ok

      _message ->
        assert_received_count(pid, expected, counter)
    end
  end

  defp assert_received_count(pid, expected, counter) do
    receive do
      {Pipeline, ^pid, {:handle_notification, {{:buffer, _}, :sink}}} ->
        assert_received_count(pid, expected, counter + 1)

      {Pipeline, ^pid, {:handle_element_end_of_stream, {:sink, :input}}} ->
        raise "premature end-of-stream: #{counter}/#{expected}"

      _message ->
        assert_received_count(pid, expected, counter)
    end
  end

  defp test_fixture_pipeline(path, framerate = {frames, time_unit}, realtimer? \\ true) do
    input = parse_fixture(path)
    input_duration_ms = input |> input_duration() |> Membrane.Time.to_milliseconds()
    frame_duration_ms = time_unit / frames * 1000
    expected_count = floor(input_duration_ms / frame_duration_ms)

    children =
      [
        source: %Source{
          output: input,
          caps: %RawVideo{
            aligned: true,
            framerate: {0, 1},
            pixel_format: :I420,
            width: 720,
            height: 480
          }
        }
      ] ++
        if realtimer? do
          [
            realtimer: Membrane.Realtimer
          ]
        else
          []
        end ++
        [
          converter: %Membrane.LiveFramerateConverter{framerate: framerate},
          sink: Membrane.Testing.Sink
        ]

    {:ok, pid} = Pipeline.start_link(links: Membrane.ParentSpec.link_linear(children))

    assert_received_count(pid, expected_count, 0)
    Pipeline.terminate(pid, blocking?: true)
  end

  describe "produces the expected amount of buffers" do
    test "with a fast producer, short version" do
      test_fixture_pipeline("test/fixtures/short.jsonl", {30, 1})
    end

    @tag skip: true
    test "with a fast producer" do
      test_fixture_pipeline("test/fixtures/fast-pre.jsonl", {30, 1}, false)
    end
  end
end
