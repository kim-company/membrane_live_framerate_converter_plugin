defmodule Membrane.LiveFramerateConverter.StallPolicyTest do
  use ExUnit.Case, async: true

  import Membrane.ChildrenSpec
  alias Membrane.Testing
  alias Membrane.RawVideo
  alias Membrane.Buffer
  alias Membrane.Time

  @default_stream_format %RawVideo{
    aligned: true,
    framerate: {0, 1},
    pixel_format: :I420,
    width: 640,
    height: 480
  }

  defp frame_period({frames, seconds}), do: round(Time.seconds(seconds) / frames)

  defp create_buffers(pts_list) when is_list(pts_list) do
    Enum.map(pts_list, fn pts ->
      %Buffer{pts: pts, dts: pts, payload: <<pts::64>>, metadata: %{}}
    end)
  end

  defp run_converter_with_policy(input_buffers, target_framerate, stall_policy, opts \\ []) do
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
        queue_capacity: queue_capacity,
        stall_policy: stall_policy
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

  describe "duplicate policy (default)" do
    test "duplicates buffers when input is very sparse" do
      period = frame_period({30, 1})
      # Only 4 buffers over 2+ seconds - will cause many duplications
      input = create_buffers([0, 30_000_000, 660_000_000, 2_119_000_000])

      output = run_converter_with_policy(input, {30, 1}, :duplicate)

      # Should fill gaps with duplicated frames
      # ~2.119 seconds at 30fps ≈ 63 frames
      assert length(output) in 60..65

      # All output should have correct PTS spacing
      output
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.each(fn [b1, b2] ->
        diff = b2.pts - b1.pts
        # Should be exactly one period apart
        assert diff == period,
               "PTS gap #{diff} between #{b1.pts} and #{b2.pts}, expected #{period}"
      end)
    end

    test "duplicated buffers have correct timing (exact period intervals)" do
      period = frame_period({30, 1})
      # Input with large gap: 0ms, then nothing until 500ms
      input = create_buffers([0, 500_000_000])

      output = run_converter_with_policy(input, {30, 1}, :duplicate)

      # Should produce frames at: 0, 33ms, 66ms, 99ms, ..., up to ~500ms
      expected_count = div(500_000_000, period) + 1

      assert length(output) >= expected_count - 2
      assert length(output) <= expected_count + 2

      # Verify every frame is at exact period boundaries
      Enum.with_index(output)
      # Check first 10 frames
      |> Enum.take(10)
      |> Enum.each(fn {buffer, idx} ->
        expected_pts = idx * period

        assert buffer.pts == expected_pts,
               "Frame #{idx} has PTS #{buffer.pts}, expected #{expected_pts}"
      end)
    end

    test "duplicated buffer payload matches last received buffer" do
      # Input at 0ms with payload "A", gap, then 200ms with payload "B"
      input = [
        %Buffer{pts: 0, dts: 0, payload: "A", metadata: %{}},
        %Buffer{pts: 200_000_000, dts: 200_000_000, payload: "B", metadata: %{}}
      ]

      output = run_converter_with_policy(input, {30, 1}, :duplicate)

      # First frame should have payload "A"
      assert hd(output).payload == "A"

      # Frames in the gap (between 0 and 200ms) should have duplicated payload "A"
      # Frames 1-4
      gap_frames = Enum.slice(output, 1, 4)

      Enum.each(gap_frames, fn buffer ->
        assert buffer.payload == "A", "Gap frame should have duplicated payload A"
      end)
    end

    test "late buffers are dropped after duplication has advanced current_slot" do
      _period = frame_period({30, 1})

      # Scenario: input at 0ms, gap (causing duplication), then late buffer at 50ms
      # The duplication will advance current_slot beyond 50ms, so 50ms buffer should be dropped
      input = [
        %Buffer{pts: 0, dts: 0, payload: "frame0", metadata: %{}},
        # Gap here - duplication will fill slots
        %Buffer{pts: 300_000_000, dts: 300_000_000, payload: "frame300", metadata: %{}},
        # This buffer arrives "late" - its PTS is before current_slot
        %Buffer{pts: 50_000_000, dts: 50_000_000, payload: "late_frame", metadata: %{}}
      ]

      output = run_converter_with_policy(input, {30, 1}, :duplicate)

      # The late buffer should not appear in output
      # All output should be monotonically increasing PTS
      output
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.each(fn [b1, b2] ->
        assert b2.pts > b1.pts, "PTS not monotonic: #{b1.pts} -> #{b2.pts}"
      end)

      # No output should have payload "late_frame"
      refute Enum.any?(output, fn buf -> buf.payload == "late_frame" end),
             "Late frame should not appear in output"
    end
  end

  describe "halt policy" do
    test "stops outputting when input stalls" do
      # Only 2 buffers with small queue, then stream ends
      # With halt policy, should only output frames we have data for
      input = create_buffers([0, 33_333_333])

      output = run_converter_with_policy(input, {30, 1}, :halt, queue_capacity: 5)

      # Should only output the buffers we received (or close to it)
      # No duplication should occur
      # Note: last buffer may stay in current_slot
      assert length(output) in 0..2
    end

    test "halt policy is configured correctly" do
      # Just verify halt policy can be set and doesn't crash
      input = create_buffers([0, 33_333_333, 66_666_666])

      output = run_converter_with_policy(input, {30, 1}, :halt, queue_capacity: 5)

      # Should produce some output without crashing
      assert length(output) >= 0
    end

    test "halt policy resumes output when input resumes (with realtimer)" do
      period = frame_period({30, 1})

      # Create input with intentional gap in time
      # Buffers at 0ms, 33ms, then gap, then more at 200ms, 233ms
      input =
        create_buffers([
          0,
          period,
          # Gap here
          200_000_000,
          200_000_000 + period
        ])

      # Run with realtimer to simulate realtime stall/resume
      output = run_converter_with_policy(input, {30, 1}, :halt, use_realtimer: true)

      # Should have some output from first burst, then some from second burst
      # No duplication in the gap
      assert length(output) >= 2
      # Not the full ~60 frames duplication would create
      assert length(output) <= 10

      # All output should be monotonically increasing
      output
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.each(fn [b1, b2] ->
        assert b2.pts > b1.pts
      end)
    end
  end

  describe "stall policy comparison" do
    test "duplicate produces more frames than halt during stall (with realtimer)" do
      period = frame_period({30, 1})

      # Create input with time gap that triggers stall
      input =
        create_buffers([
          0,
          period,
          period * 2,
          # Time gap here - will cause stall
          200_000_000,
          200_000_000 + period,
          200_000_000 + period * 2
        ])

      # Run both policies with realtimer
      output_duplicate =
        run_converter_with_policy(input, {30, 1}, :duplicate,
          queue_capacity: 3,
          use_realtimer: true
        )

      output_halt =
        run_converter_with_policy(input, {30, 1}, :halt,
          queue_capacity: 3,
          use_realtimer: true
        )

      # Duplicate should produce MORE frames (duplicates during stall)
      # Halt should produce FEWER frames (halts during stall)
      assert length(output_duplicate) > length(output_halt),
             "Duplicate policy should produce more frames than halt during stall"

      # Duplicate should have frames during the gap period
      # Halt should stop outputting during the gap
      duplicate_pts_during_gap =
        Enum.count(output_duplicate, fn buf ->
          buf.pts >= period * 3 and buf.pts < 200_000_000
        end)

      halt_pts_during_gap =
        Enum.count(output_halt, fn buf ->
          buf.pts >= period * 3 and buf.pts < 200_000_000
        end)

      assert duplicate_pts_during_gap > 0, "Duplicate policy should have frames during gap"
      assert halt_pts_during_gap == 0, "Halt policy should have no frames during gap"
    end

    test "both policies output same frames when input is continuous" do
      period = frame_period({30, 1})
      # Continuous input at target framerate
      input = Enum.map(0..10, fn i -> i * period end) |> create_buffers()

      output_duplicate = run_converter_with_policy(input, {30, 1}, :duplicate, queue_capacity: 5)
      output_halt = run_converter_with_policy(input, {30, 1}, :halt, queue_capacity: 5)

      # Both should produce similar output when input is continuous
      # May differ by 1-2 due to current_slot not being output
      assert abs(length(output_duplicate) - length(output_halt)) <= 2
    end
  end

  describe "duplicate timing verification" do
    test "no gaps in PTS sequence when duplicating" do
      period = frame_period({30, 1})
      # Very sparse input to force duplication
      input = create_buffers([0, 1_000_000_000])

      output = run_converter_with_policy(input, {30, 1}, :duplicate)

      # Every consecutive pair should be exactly one period apart
      output
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.each(fn [b1, b2] ->
        assert b2.pts - b1.pts == period,
               "Gap in PTS: #{b1.pts} -> #{b2.pts}, diff: #{b2.pts - b1.pts}, expected: #{period}"
      end)
    end

    test "duplicated buffers have nil DTS like normal buffers" do
      input = create_buffers([0, 500_000_000])

      output = run_converter_with_policy(input, {30, 1}, :duplicate)

      # All output buffers should have nil DTS (normalized by Slot.set)
      Enum.each(output, fn buffer ->
        assert buffer.dts == nil,
               "Buffer at PTS #{buffer.pts} has DTS #{buffer.dts}, expected nil"
      end)
    end
  end
end
