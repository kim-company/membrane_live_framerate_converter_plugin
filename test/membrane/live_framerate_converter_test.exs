defmodule Membrane.LiveFramerateConverterTest do
  use ExUnit.Case

  alias Membrane.Testing.Pipeline
  alias Membrane.RawVideo
  use Membrane.Pipeline

  describe "produces the expected amount of buffers" do
    test "when there are missing frames in the input" do
      test_fixture_pipeline("test/fixtures/low.jsonl", {30, 1}, false)
    end

    test "when there are too many frames" do
      test_fixture_pipeline("test/fixtures/high.jsonl", {30, 1})
    end

    test "when the input framerate is variable" do
      test_fixture_pipeline("test/fixtures/variable.jsonl", {30, 1})
    end

    test "when input is sparse" do
      test_fixture_pipeline("test/fixtures/sparse.jsonl", {30, 1})
    end

    test "works w/o realtimer" do
      test_fixture_pipeline("test/fixtures/sparse.jsonl", {30, 1}, false)
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

  defp count_received_buffers(pid, counter) do
    receive do
      {Membrane.Testing.Pipeline, ^pid, {:handle_child_notification, {{:buffer, _}, :sink}}} ->
        count_received_buffers(pid, counter + 1)

      {Membrane.Testing.Pipeline, ^pid, {:handle_element_end_of_stream, {:sink, :input}}} ->
        counter

      _message ->
        count_received_buffers(pid, counter)
    end
  end

  defp test_fixture_pipeline(path, framerate = {frames, time_unit}, realtimer? \\ true) do
    input = parse_fixture(path)
    input_duration_ms = input |> input_duration() |> Membrane.Time.round_to_milliseconds()
    frame_duration_ms = time_unit / frames * 1000
    expected_count = floor(input_duration_ms / frame_duration_ms)

    links = [
      child(:source, %Membrane.Testing.Source{
        output: Membrane.Testing.Source.output_from_buffers(input),
        stream_format: %RawVideo{
          aligned: true,
          framerate: {0, 1},
          pixel_format: :I420,
          width: 720,
          height: 480
        }
      })
      |> then(fn structure ->
        if realtimer? do
          structure |> child(:realtimer, Membrane.LiveFilter)
        else
          structure
        end
      end)
      |> child(:converter, %Membrane.LiveFramerateConverter{framerate: framerate})
      |> child(:sink, Membrane.Testing.Sink)
    ]

    pid = Membrane.Testing.Pipeline.start_link_supervised!(structure: links)

    assert expected_count == count_received_buffers(pid, 0)
    Pipeline.terminate(pid, blocking?: true)
  end
end
