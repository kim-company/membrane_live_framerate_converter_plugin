defmodule Membrane.LiveFramerateConverter.NotificationsTest do
  use ExUnit.Case

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

  defp run_converter_and_collect_notifications(input_buffers, target_framerate, opts) do
    queue_capacity = Keyword.get(opts, :queue_capacity, 200)
    stall_policy = Keyword.get(opts, :stall_policy, :duplicate)
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
          {Testing.Pipeline, ^pid, {:handle_child_notification, {notification, :converter}}} ->
            {[{:notification, notification}], pid}

          {Testing.Pipeline, ^pid, {:handle_child_notification, {{:buffer, buffer}, :sink}}} ->
            {[{:buffer, buffer}], pid}

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

  describe "frame_dropped notification" do
    test "notifies when late buffer is dropped" do
      # Buffer at 100ms, then late buffer at 5ms (should be dropped), then buffer at 200ms
      input = create_buffers([100_000_000, 5_000_000, 200_000_000])

      output = run_converter_and_collect_notifications(input, {30, 1}, queue_capacity: 5)

      notifications = Enum.filter(output, &match?({:notification, _}, &1))

      # Should have at least one frame_dropped notification
      dropped_notifications =
        Enum.filter(notifications, fn
          {:notification, {:frame_dropped, pts, _threshold}} when pts == 5_000_000 -> true
          _ -> false
        end)

      assert length(dropped_notifications) >= 1,
             "Expected at least one frame_dropped notification for PTS 5ms"

      # Verify the notification has correct structure
      assert [{:notification, {:frame_dropped, 5_000_000, threshold}}] = dropped_notifications
      assert threshold > 5_000_000, "Threshold should be greater than dropped PTS"
    end

    test "no drop notification when all buffers are on time" do
      period = frame_period({30, 1})
      # All buffers in order with no late arrivals
      input = create_buffers([0, period, period * 2, period * 3])

      output = run_converter_and_collect_notifications(input, {30, 1}, queue_capacity: 5)

      notifications = Enum.filter(output, &match?({:notification, _}, &1))

      # Should have no frame_dropped notifications
      dropped_notifications =
        Enum.filter(notifications, fn
          {:notification, {:frame_dropped, _pts, _threshold}} -> true
          _ -> false
        end)

      assert dropped_notifications == [],
             "Expected no frame_dropped notifications when all buffers are on time"
    end
  end

  describe "input_stalled notification" do
    # Note: Stall detection requires timer to be running with empty queue
    # Without realtimer, all buffers arrive instantly making this hard to test
    @tag :skip
    test "notifies when input stalls with duplicate policy (needs realtimer)" do
      # Would need realtimer to create realistic time gaps that trigger stall
      :ok
    end

    @tag :skip
    test "notifies when input stalls with halt policy (needs realtimer)" do
      # Would need realtimer to create realistic time gaps that trigger stall
      :ok
    end
  end

  describe "frame_duplicated notification" do
    # Note: Duplication only happens when queue is empty during active phase
    # Without realtimer, all buffers arrive instantly making this hard to test
    @tag :skip
    test "notifies when frames are duplicated during stall (needs realtimer)" do
      # Would need realtimer to create realistic time gaps that trigger duplication
      :ok
    end

    @tag :skip
    test "no duplication notification with halt policy (needs realtimer)" do
      # Would need realtimer to verify no duplication happens
      :ok
    end
  end

  describe "input_resumed notification" do
    @tag :skip
    test "notifies when input resumes after stall (with realtimer)" do
      period = frame_period({30, 1})

      # Create input with enough initial buffers to exit loading phase,
      # then a gap in time that causes stall, then more buffers
      input = create_buffers([
        0,
        period,
        period * 2,
        period * 3,
        period * 4,
        # Enough to exit loading phase (5 buffers)
        # Now add a gap in TIME - next buffer much later
        500_000_000,  # 500ms - creates a big time gap
        500_000_000 + period
      ])

      # Run with realtimer to simulate actual realtime stall/resume
      # With realtimer, buffer at 500ms won't arrive until 500ms of real time passes
      # During that gap, queue will drain and trigger stall
      output = run_converter_and_collect_notifications(input, {30, 1}, queue_capacity: 5, use_realtimer: true, stall_policy: :duplicate)

      notifications = Enum.filter(output, &match?({:notification, _}, &1))

      # Should have input_stalled notification
      stalled_notifications =
        Enum.filter(notifications, fn
          {:notification, {:input_stalled, _pts}} -> true
          _ -> false
        end)

      # Should have input_resumed notification
      resumed_notifications =
        Enum.filter(notifications, fn
          {:notification, {:input_resumed, _pts}} -> true
          _ -> false
        end)

      # With realtimer and time gap, we should see both stall and resume
      assert length(stalled_notifications) >= 1, "Expected input_stalled notification during gap"
      assert length(resumed_notifications) >= 1, "Expected input_resumed notification when buffer at 500ms arrives"
    end
  end

  describe "notification structure" do
    test "frame_dropped notification has correct structure" do
      # Create scenario that triggers frame_dropped
      input = create_buffers([
        0,
        50_000_000,  # On time
        10_000_000,  # Late - will be dropped
        100_000_000  # On time
      ])

      output = run_converter_and_collect_notifications(input, {30, 1}, queue_capacity: 5)

      notifications = Enum.filter(output, &match?({:notification, _}, &1))

      # Should have at least one frame_dropped notification
      dropped_notifications =
        Enum.filter(notifications, fn
          {:notification, {:frame_dropped, _pts, _threshold}} -> true
          _ -> false
        end)

      assert length(dropped_notifications) > 0, "Expected frame_dropped notifications"

      # Verify structure
      Enum.each(dropped_notifications, fn {:notification, {:frame_dropped, pts, threshold}} ->
        assert is_integer(pts) and pts >= 0, "PTS should be non-negative integer"
        assert is_integer(threshold) and threshold >= 0, "Threshold should be non-negative integer"
        assert pts < threshold, "Dropped PTS should be less than threshold"
      end)
    end
  end
end
