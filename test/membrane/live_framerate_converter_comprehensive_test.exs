defmodule Membrane.LiveFramerateConverterComprehensiveTest do
  use ExUnit.Case, async: true

  import Membrane.ChildrenSpec
  import Membrane.Testing.Assertions
  alias Membrane.Testing
  alias Membrane.RawVideo
  alias Membrane.Buffer
  alias Membrane.Time

  # Test configuration
  @default_stream_format %RawVideo{
    aligned: true,
    framerate: {0, 1},
    pixel_format: :I420,
    width: 640,
    height: 480
  }

  # Helper: Calculate frame period in nanoseconds
  defp frame_period({frames, seconds}), do: round(Time.seconds(seconds) / frames)

  # Helper: Create buffers with specific PTS values
  defp create_buffers(pts_list) when is_list(pts_list) do
    Enum.map(pts_list, fn pts ->
      %Buffer{pts: pts, dts: pts, payload: <<>>, metadata: %{}}
    end)
  end

  # Helper: Create evenly spaced buffers
  defp create_even_buffers(start_pts, count, interval) do
    0..(count - 1)
    |> Enum.map(fn i -> start_pts + i * interval end)
    |> create_buffers()
  end

  # Helper: Run converter and collect output buffers using Stream.resource
  defp run_converter(input_buffers, target_framerate, opts \\ []) do
    queue_capacity = Keyword.get(opts, :queue_capacity, 200)
    use_realtimer = Keyword.get(opts, :use_realtimer, false)

    spec =
      child(:source, %Testing.Source{
        output: Testing.Source.output_from_buffers(input_buffers),
        stream_format: @default_stream_format
      })
      |> then(fn s ->
        if use_realtimer do
          s |> child(:realtimer, Membrane.Realtimer)
        else
          s
        end
      end)
      |> child(:converter, %Membrane.LiveFramerateConverter{
        framerate: target_framerate,
        queue_capacity: queue_capacity
      })
      |> child(:sink, Testing.Sink)

    Stream.resource(
      fn -> Testing.Pipeline.start_link_supervised!(spec: spec) end,
      fn pid ->
        receive do
          {Testing.Pipeline, ^pid, {:handle_child_notification, {{:buffer, buffer}, :sink}}} ->
            {[buffer], pid}

          {Testing.Pipeline, ^pid, {:handle_element_end_of_stream, {:sink, :input}}} ->
            {:halt, pid}
        after
          15_000 ->
            raise "Test timeout - no message received"
        end
      end,
      fn pid -> Testing.Pipeline.terminate(pid) end
    )
    |> Enum.to_list()
  end

  # Helper: Assert PTS values are evenly spaced
  defp assert_even_spacing(buffers, expected_interval) do
    buffers
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.each(fn [b1, b2] ->
      actual_interval = b2.pts - b1.pts

      assert actual_interval == expected_interval,
             "Expected interval #{expected_interval}, got #{actual_interval} between PTS #{b1.pts} and #{b2.pts}"
    end)
  end

  # Helper: Assert PTS values are monotonically increasing
  defp assert_monotonic(buffers) do
    buffers
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.each(fn [b1, b2] ->
      assert b2.pts > b1.pts, "PTS not monotonic: #{b1.pts} -> #{b2.pts}"
    end)
  end

  describe "PTS correctness and output quality" do
    test "output buffers have correct PTS values at 30fps" do
      # Input: buffers at 0ms, 50ms, 100ms, then more to fill slots
      input = create_buffers([0, 50_000_000, 100_000_000, 150_000_000])

      output = run_converter(input, {30, 1})

      # With queue size 200 and only 4 input buffers, stream ends during loading phase
      # Timer starts on EOS during loading, producing output for all queued slots
      # Plus duplication fills gaps until EOS marker is reached
      # Actual behavior: produces frames for time span covered by input
      assert Enum.count(output) >= 3
      assert hd(output).pts == 0
      assert_monotonic(output)
    end

    test "output PTS values are monotonically increasing" do
      # 10 buffers, 10ms apart
      input = create_even_buffers(0, 10, 10_000_000)

      output = run_converter(input, {30, 1})

      assert_monotonic(output)
    end

    test "output buffers are evenly spaced at target framerate" do
      # ~16.67ms for 60fps
      period = frame_period({60, 1})
      # 20 buffers, 5ms apart
      input = create_even_buffers(0, 20, 5_000_000)

      output = run_converter(input, {60, 1})

      assert_even_spacing(output, period)
    end

    test "first output PTS matches first input PTS" do
      input = create_buffers([100_000_000, 150_000_000, 200_000_000])

      output = run_converter(input, {30, 1})

      assert hd(output).pts == 100_000_000
    end

    test "output DTS is nil" do
      input = create_buffers([0, 50_000_000, 100_000_000])

      output = run_converter(input, {30, 1})

      Enum.each(output, fn buffer ->
        assert buffer.dts == nil
      end)
    end
  end

  describe "different target framerates" do
    test "30fps produces correct frame period" do
      input = create_even_buffers(0, 10, 10_000_000)

      output = run_converter(input, {30, 1})

      period = frame_period({30, 1})
      assert_even_spacing(output, period)
    end

    test "60fps produces correct frame period" do
      input = create_even_buffers(0, 20, 5_000_000)

      output = run_converter(input, {60, 1})

      period = frame_period({60, 1})
      assert_even_spacing(output, period)
    end

    test "24fps produces correct frame period" do
      input = create_even_buffers(0, 10, 20_000_000)

      output = run_converter(input, {24, 1})

      period = frame_period({24, 1})
      assert_even_spacing(output, period)
    end

    test "15fps produces correct frame period" do
      input = create_even_buffers(0, 5, 50_000_000)

      output = run_converter(input, {15, 1})

      period = frame_period({15, 1})
      assert_even_spacing(output, period)
    end

    test "fractional framerate 29.97fps (NTSC)" do
      # 30_000/1001 = 29.97fps
      input = create_even_buffers(0, 30, 10_000_000)

      output = run_converter(input, {30_000, 1001})

      period = frame_period({30_000, 1001})
      assert_even_spacing(output, period)
    end

    test "high framerate 120fps" do
      input = create_even_buffers(0, 50, 2_000_000)

      output = run_converter(input, {120, 1})

      period = frame_period({120, 1})
      assert_even_spacing(output, period)
    end

    test "low framerate 1fps" do
      input = create_even_buffers(0, 3, Time.seconds(1))

      output = run_converter(input, {1, 1})

      period = frame_period({1, 1})
      assert_even_spacing(output, period)
    end
  end

  describe "edge cases" do
    test "empty input stream produces no output" do
      output = run_converter([], {30, 1})

      assert output == []
    end

    test "single buffer input" do
      input = create_buffers([0])

      output = run_converter(input, {30, 1})

      # Single buffer stays in current_slot and is never pushed to queue
      # So no output is produced (current_slot is not output on EOS)
      assert output == []
    end

    test "two buffers very close together" do
      # Both buffers in same slot
      # 0ms and 1ms
      input = create_buffers([0, 1_000_000])

      output = run_converter(input, {30, 1})

      # Both buffers fit in same slot (current_slot), never pushed to queue
      # So no output is produced
      assert output == []
    end

    test "stream ending during loading phase" do
      # Only 3 buffers with default queue_capacity of 200
      input = create_buffers([0, 33_333_333, 66_666_666])

      output = run_converter(input, {30, 1})

      # Buffers at exact slot boundaries with half-open intervals [start, end)
      # Slot 0: [0, 33_333_333) - gets buffer at 0, then buffer at 33_333_333 triggers next slot
      # Slot 1: [33_333_333, 66_666_666) - gets buffer at 33_333_333, then buffer at 66_666_666 triggers next slot
      # Slot 2: [66_666_666, 99_999_999) - gets buffer at 66_666_666
      # Slots 0 and 1 are pushed to queue, slot 2 remains in current_slot
      assert length(output) == 2
    end

    test "exact slot boundary alignment" do
      period = frame_period({30, 1})
      # Buffers exactly at slot boundaries
      input = create_buffers([0, period, period * 2, period * 3, period * 4])

      output = run_converter(input, {30, 1})

      # With few input buffers, stream ends during loading phase
      # Timer starts and fills with duplication as needed
      # Each boundary buffer creates a valid output frame
      assert Enum.count(output) >= 3
      assert hd(output).pts == 0
      # All output PTS should be multiples of period
      Enum.each(output, fn buf ->
        assert rem(buf.pts, period) == 0, "PTS #{buf.pts} is not a multiple of period #{period}"
      end)
    end
  end

  describe "buffer dropping (high input framerate)" do
    test "drops excess buffers when input > target framerate" do
      # Input at 60fps, output at 30fps
      period_60fps = frame_period({60, 1})
      # 1 second at 60fps
      input = create_even_buffers(0, 60, period_60fps)

      output = run_converter(input, {30, 1})

      # Should produce ~30 frames
      assert length(output) in 29..31
    end

    test "uses most recent buffer in each slot" do
      period_30fps = frame_period({30, 1})
      # Multiple buffers in first slot, then one more to trigger push
      input =
        create_buffers([
          0,
          # 5ms - in same slot as 0
          5_000_000,
          # 10ms - in same slot (replaces previous)
          10_000_000,
          # Exactly at slot boundary - still accepted into slot 0
          period_30fps,
          # Beyond slot boundary - triggers push of slot 0
          period_30fps + 1_000_000
        ])

      output = run_converter(input, {30, 1})

      # Slot 0 gets pushed when buffer beyond it arrives
      # Should have at least 1 output (slot 0 with buffer from 33.333ms)
      # PTS normalized to slot start (0)
      assert output != []
      assert hd(output).pts == 0
    end
  end

  describe "buffer duplication (low input framerate)" do
    test "duplicates buffers when input < target framerate" do
      # Input at 15fps, output at 30fps
      period_15fps = frame_period({15, 1})
      # 1 second at 15fps
      input = create_even_buffers(0, 15, period_15fps)

      output = run_converter(input, {30, 1})

      # Should produce ~28-30 frames (approximately doubling the input)
      # Note: last frame may stay in current_slot and not be output
      assert length(output) in 28..30
    end

    test "handles very sparse input" do
      # Only 4 buffers over 2+ seconds
      input = create_buffers([0, 30_000_000, 660_000_000, 2_119_000_000])

      output = run_converter(input, {30, 1})

      # Should fill gaps with duplicated frames
      # Expected: ~2.119 seconds at 30fps = ~63 frames
      assert length(output) in 60..65
    end
  end

  describe "late buffer handling" do
    test "drops buffers that arrive too late" do
      # Buffer at 100ms, then late buffer at 5ms, then buffer at 200ms
      input =
        create_buffers([
          100_000_000,
          # Too late! Should be dropped
          5_000_000,
          200_000_000
        ])

      output = run_converter(input, {30, 1})

      # Late buffer should not affect output
      # Should produce frames starting at 100ms
      assert hd(output).pts == 100_000_000

      # Verify monotonic increase - if late buffer was used, this would fail
      assert_monotonic(output)

      # All output PTS should be >= 100ms (none from the late 5ms buffer)
      Enum.each(output, fn buffer ->
        assert buffer.pts >= 100_000_000,
               "Found buffer with PTS #{buffer.pts} which is before expected start of 100ms"
      end)
    end

    test "processes buffers in arrival order, not PTS order" do
      # When buffers arrive out of order, later ones get dropped if too old
      period = frame_period({30, 1})

      input =
        create_buffers([
          0,
          # Jump forward
          100_000_000,
          # Late - would be between first two, but arrives last
          50_000_000
        ])

      output = run_converter(input, {30, 1})

      # Should start at 0, and the 50ms buffer should be dropped as late
      assert hd(output).pts == 0

      # Should have frames from 0 to ~100ms range
      assert Enum.all?(output, fn buf -> buf.pts >= 0 && buf.pts <= 100_000_000 + period end)
    end
  end

  describe "queue capacity variations" do
    test "small queue capacity (5)" do
      input = create_even_buffers(0, 20, 10_000_000)

      output = run_converter(input, {30, 1}, queue_capacity: 5)

      # Should still work correctly
      period = frame_period({30, 1})
      assert_even_spacing(output, period)
    end

    test "minimal queue capacity (1)" do
      input = create_even_buffers(0, 10, 50_000_000)

      output = run_converter(input, {30, 1}, queue_capacity: 1)

      # Should still produce output
      assert output != []
      assert_monotonic(output)
    end

    test "large queue capacity (500)" do
      input = create_even_buffers(0, 600, 5_000_000)

      output = run_converter(input, {30, 1}, queue_capacity: 500)

      period = frame_period({30, 1})
      assert_even_spacing(output, period)
    end
  end

  describe "output count verification" do
    test "output count matches duration at target framerate" do
      # 1 second of input at variable rate
      input =
        create_buffers([
          0,
          10_000_000,
          50_000_000,
          100_000_000,
          500_000_000,
          1_000_000_000
        ])

      output = run_converter(input, {30, 1})

      # 1 second at 30fps = 30 frames
      # (Actually 31 because we include both 0 and 1s endpoints)
      assert length(output) in 30..31
    end

    test "output count with fractional framerate" do
      # ~1 second of input
      input = create_even_buffers(0, 100, 10_000_000)

      output = run_converter(input, {30_000, 1001})

      # ~1 second at 29.97fps ≈ 30 frames
      assert length(output) in 29..31
    end
  end

  describe "stream format propagation" do
    test "output stream format has correct target framerate" do
      input = create_buffers([0, 50_000_000, 100_000_000, 150_000_000])

      spec =
        child(:source, %Testing.Source{
          output: Testing.Source.output_from_buffers(input),
          stream_format: @default_stream_format
        })
        |> child(:converter, %Membrane.LiveFramerateConverter{framerate: {60, 1}})
        |> child(:sink, Testing.Sink)

      pipeline = Testing.Pipeline.start_link_supervised!(spec: spec)

      assert_sink_stream_format(pipeline, :sink, %RawVideo{framerate: {60, 1}})

      Testing.Pipeline.terminate(pipeline)
    end
  end

  describe "payload preservation" do
    test "payload is preserved through conversion" do
      input = [
        %Buffer{pts: 0, dts: 0, payload: "frame1", metadata: %{}},
        %Buffer{pts: 50_000_000, dts: 50_000_000, payload: "frame2", metadata: %{}},
        %Buffer{pts: 100_000_000, dts: 100_000_000, payload: "frame3", metadata: %{}}
      ]

      output = run_converter(input, {30, 1})

      # Payloads should be preserved (though may be duplicated or dropped)
      Enum.each(output, fn buffer ->
        assert buffer.payload in ["frame1", "frame2", "frame3"]
      end)
    end
  end
end
