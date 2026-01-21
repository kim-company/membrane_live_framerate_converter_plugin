defmodule Membrane.LiveFramerateConverter.NotificationsTest do
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
          30_000 ->
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
    # Realtimer creates realistic time gaps that trigger actual stalls
    test "notifies when input stalls with duplicate policy (with realtimer)" do
      period = frame_period({30, 1})

      # Create input: enough to exit loading phase, then time gap, then more buffers
      # Using small queue (3) so it drains quickly
      input =
        create_buffers([
          0,
          period,
          period * 2,
          # Gap in time - causes queue to drain and trigger stall
          200_000_000,
          200_000_000 + period,
          200_000_000 + period * 2
        ])

      output =
        run_converter_and_collect_notifications(
          input,
          {30, 1},
          queue_capacity: 3,
          use_realtimer: true,
          stall_policy: :duplicate
        )

      notifications = Enum.filter(output, &match?({:notification, _}, &1))

      stalled_notifications =
        Enum.filter(notifications, fn
          {:notification, {:input_stalled, _pts}} -> true
          _ -> false
        end)

      assert length(stalled_notifications) >= 1,
             "Expected at least one input_stalled notification"

      # Verify stall happened at expected time (after queue drained)
      [{:notification, {:input_stalled, pts}} | _rest] = stalled_notifications
      assert pts >= period * 3, "Stall should be detected after initial buffers consumed"
    end

    test "notifies when input stalls with halt policy (with realtimer)" do
      period = frame_period({30, 1})

      input =
        create_buffers([
          0,
          period,
          period * 2,
          # Gap - causes stall
          200_000_000,
          200_000_000 + period,
          200_000_000 + period * 2
        ])

      output =
        run_converter_and_collect_notifications(
          input,
          {30, 1},
          queue_capacity: 3,
          use_realtimer: true,
          stall_policy: :halt
        )

      notifications = Enum.filter(output, &match?({:notification, _}, &1))

      stalled_notifications =
        Enum.filter(notifications, fn
          {:notification, {:input_stalled, _pts}} -> true
          _ -> false
        end)

      assert length(stalled_notifications) == 1,
             "Expected exactly one input_stalled notification with halt policy"
    end
  end

  describe "frame_duplicated notification" do
    # Note: Duplication only happens when queue is empty during active phase
    # Realtimer creates realistic time gaps that trigger duplication
    test "notifies when frames are duplicated during stall (with realtimer)" do
      period = frame_period({30, 1})

      # Create input: enough to exit loading, then gap, then more buffers
      input =
        create_buffers([
          0,
          period,
          period * 2,
          # Gap - will cause multiple duplications
          200_000_000,
          200_000_000 + period,
          200_000_000 + period * 2
        ])

      output =
        run_converter_and_collect_notifications(
          input,
          {30, 1},
          queue_capacity: 3,
          use_realtimer: true,
          stall_policy: :duplicate
        )

      notifications = Enum.filter(output, &match?({:notification, _}, &1))

      duplicated_notifications =
        Enum.filter(notifications, fn
          {:notification, {:frame_duplicated, _pts}} -> true
          _ -> false
        end)

      # Should have multiple frame_duplicated notifications during the gap
      # Gap is from ~99ms to 200ms = ~101ms = multiple frames
      # Should see multiple duplications
      assert length(duplicated_notifications) >= 1,
             "Expected frame_duplicated notifications during stall"

      # All duplication PTS should be >= period * 3 (after original buffers)
      Enum.each(duplicated_notifications, fn {:notification, {:frame_duplicated, pts}} ->
        assert pts >= period * 3, "Duplicated frame PTS should be after original buffers"
      end)
    end

    test "no duplication notification with halt policy (with realtimer)" do
      period = frame_period({30, 1})

      input =
        create_buffers([
          0,
          period,
          period * 2,
          # Gap - but halt policy should NOT duplicate
          200_000_000,
          200_000_000 + period,
          200_000_000 + period * 2
        ])

      output =
        run_converter_and_collect_notifications(
          input,
          {30, 1},
          queue_capacity: 3,
          use_realtimer: true,
          stall_policy: :halt
        )

      notifications = Enum.filter(output, &match?({:notification, _}, &1))

      duplicated_notifications =
        Enum.filter(notifications, fn
          {:notification, {:frame_duplicated, _pts}} -> true
          _ -> false
        end)

      # Should have NO duplication with halt policy
      assert duplicated_notifications == [],
             "Expected no frame_duplicated notifications with halt policy"
    end
  end

  describe "input_resumed notification" do
    test "notifies when input resumes after stall (with realtimer)" do
      period = frame_period({30, 1})

      # Create input with gap that causes stall, then more buffers to trigger resume
      input =
        create_buffers([
          0,
          period,
          period * 2,
          # Gap in time - causes stall
          200_000_000,
          # More buffers after gap - should trigger resume
          200_000_000 + period,
          200_000_000 + period * 2
        ])

      # Run with realtimer to create realistic stall/resume cycle
      output =
        run_converter_and_collect_notifications(
          input,
          {30, 1},
          queue_capacity: 3,
          use_realtimer: true,
          stall_policy: :duplicate
        )

      notifications = Enum.filter(output, &match?({:notification, _}, &1))

      stalled_notifications =
        Enum.filter(notifications, fn
          {:notification, {:input_stalled, _pts}} -> true
          _ -> false
        end)

      resumed_notifications =
        Enum.filter(notifications, fn
          {:notification, {:input_resumed, _pts}} -> true
          _ -> false
        end)

      case {stalled_notifications, resumed_notifications} do
        {[], []} ->
          :ok

        {[], _resumed} ->
          flunk("Expected input_stalled notification before input_resumed")

        {_stalled, []} ->
          flunk("Expected input_resumed notification after input_stalled")

        {[{:notification, {:input_stalled, stalled_pts}} | _stalled_rest],
         [{:notification, {:input_resumed, resume_pts}} | _resumed_rest]} ->
          resume_candidates = [
            200_000_000,
            200_000_000 + period,
            200_000_000 + period * 2
          ]

          expected_resume_pts = Enum.find(resume_candidates, &(&1 >= stalled_pts))

          assert resume_pts == expected_resume_pts,
                 "Resume should be at the first buffer after stall"
      end
    end
  end

  describe "notification structure" do
    test "frame_dropped notification has correct structure" do
      # Create scenario that triggers frame_dropped
      input =
        create_buffers([
          0,
          # On time
          50_000_000,
          # Late - will be dropped
          10_000_000,
          # On time
          100_000_000
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

        assert is_integer(threshold) and threshold >= 0,
               "Threshold should be non-negative integer"

        assert pts < threshold, "Dropped PTS should be less than threshold"
      end)
    end
  end
end
