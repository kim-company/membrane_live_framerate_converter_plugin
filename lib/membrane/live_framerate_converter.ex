defmodule Membrane.LiveFramerateConverter do
  @moduledoc """
  A Membrane filter that stabilizes the output framerate for raw video by
  dropping or duplicating buffers.

  The element uses **push** flow control on its input pad, so it receives
  buffers as they arrive from the upstream element. A timer ticks at the
  target framerate, emitting one buffer per tick.

  ## Slot-based frame matching

  The output timeline is divided into consecutive *slots*, each one period
  wide (`[starts_at, ends_at)`). Every input buffer is matched to the slot
  whose time window contains the buffer's PTS. When multiple input buffers
  fall in the same slot the last one wins (higher input framerate → frames
  are dropped). When no input buffer falls in a slot the previous frame is
  carried forward (lower input framerate → frames are duplicated).

  ## Stall handling (`:duplicate` policy)

  When no input arrives for an extended time the queue drains and the element
  enters *stall* mode. In this mode each timer tick duplicates the last
  received frame into the next output slot, keeping the output cadence
  constant. The output timeline keeps advancing.

  When input resumes, the first arriving buffer is placed directly into the
  **next available output slot** — regardless of the buffer's source PTS.
  This means fresh content appears in the output as soon as possible, with
  no accumulated delay from the stall period.

  Because the source PTS timeline is now behind the output timeline, a
  `pts_offset` is computed (`output_slot_start − source_pts`) and applied to
  all subsequent input buffers before slot matching. This keeps the two
  timelines aligned going forward. Multiple stalls simply recompute the
  offset each time.

  The result is a **gapless, strictly monotonic** output at exactly the
  target period throughout normal operation, stalls, and recoveries.

  ## Stall handling (`:halt` policy)

  Output stops while the queue is empty. When input resumes, buffers go
  through normal slot matching and output picks up where it left off.

  ## Notifications

  - `{:frame_dropped, pts, threshold}` — a late buffer arrived (PTS < current slot start)
  - `{:frame_duplicated, pts}` — a frame was duplicated to fill a stall gap
  - `{:input_stalled, pts}` — queue became empty during active playback (sent once per stall)
  - `{:input_resumed, pts}` — first buffer after a `:duplicate`-policy stall; `pts` is the
    original source PTS of the buffer that triggered recovery
  """

  use Membrane.Filter
  alias Membrane.RawVideo
  alias Membrane.Time
  alias Membrane.Buffer

  defmodule Slot do
    @moduledoc false
    defstruct [:starts_at, :ends_at, :buffer]

    def new(starts_at, duration) do
      %__MODULE__{
        starts_at: starts_at,
        ends_at: starts_at + duration
      }
    end

    def next(%__MODULE__{} = prev) do
      %__MODULE__{
        starts_at: prev.ends_at,
        ends_at: prev.ends_at + (prev.ends_at - prev.starts_at)
      }
      |> set(prev.buffer)
    end

    def next_empty(%__MODULE__{} = prev) do
      %__MODULE__{
        starts_at: prev.ends_at,
        ends_at: prev.ends_at + (prev.ends_at - prev.starts_at),
        buffer: nil
      }
    end

    def accepts?(slot, %Buffer{pts: pts}) do
      pts >= slot.starts_at and pts < slot.ends_at
    end

    def old?(slot, %Buffer{pts: pts}) do
      pts <= slot.starts_at
    end

    def set(slot, %Membrane.Buffer{} = buffer) do
      %{slot | buffer: %{buffer | pts: slot.starts_at, dts: nil}}
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
                Deprecated — this option is accepted for backward compatibility
                but no longer affects behaviour.
                """
              ],
              stall_policy: [
                spec: :duplicate | :halt,
                default: :duplicate,
                description: """
                Policy to use when input stops providing data:
                - `:duplicate` - duplicate the last received frame to maintain output framerate (default)
                - `:halt` - stop outputting frames until input resumes or end of stream
                """
              ]

  def_input_pad :input,
    accepted_format: %RawVideo{aligned: true},
    flow_control: :auto

  def_output_pad :output, accepted_format: %RawVideo{aligned: true}, flow_control: :auto

  @impl true
  def handle_init(_ctx, opts) do
    {frames, seconds} = opts.framerate
    period = round(Time.seconds(seconds) / frames)

    {[],
     %{
       period: period,
       framerate: opts.framerate,
       queue: :queue.new(),
       current_slot: nil,
       last_buffer: nil,
       stall_policy: opts.stall_policy,
       stalled?: false,
       pts_offset: 0,
       timer_started?: false
     }}
  end

  @impl true
  def handle_playing(_ctx, state) do
    {[], state}
  end

  @impl true
  def handle_stream_format(
        :input,
        %RawVideo{} = format,
        _context,
        %{framerate: framerate} = state
      ) do
    {[stream_format: {:output, %{format | framerate: framerate}}], state}
  end

  @impl true
  def handle_buffer(:input, buffer, _ctx, state) do
    state =
      if state.current_slot == nil do
        %{state | current_slot: Slot.new(buffer.pts, state.period)}
      else
        state
      end

    {actions, state} = push_buffer(state, buffer)

    if state.timer_started? do
      {actions, state}
    else
      {actions ++ [start_timer: {:timer, state.period}], %{state | timer_started?: true}}
    end
  end

  @impl true
  def handle_tick(:timer, ctx, state) do
    case :queue.out(state.queue) do
      {{:value, :end_of_stream}, queue} ->
        {[stop_timer: :timer, end_of_stream: :output], %{state | queue: queue}}

      {{:value, %Slot{buffer: buffer}}, queue} ->
        {[buffer: {:output, buffer}], %{state | queue: queue}}

      {:empty, _queue} ->
        # Queue is empty. Check if current_slot has a buffer that hasn't
        # been enqueued yet (it was waiting for a future input buffer to
        # trigger advance_slot_and_retry). Flush it into the queue so the
        # timer can output it.
        if state.current_slot != nil and state.current_slot.buffer != nil do
          queue = :queue.in(state.current_slot, state.queue)
          state = %{state | queue: queue, current_slot: %{state.current_slot | buffer: nil}}

          # Re-enter handle_tick now that the queue has an item.
          handle_tick(:timer, ctx, state)
        else
          handle_queue_empty(state.stall_policy, ctx, state)
        end
    end
  end

  defp handle_queue_empty(:duplicate, _ctx, state) do
    # Send stall notification only on first stall detection
    actions =
      if state.stalled?,
        do: [],
        else: [notify_parent: {:input_stalled, state.current_slot.ends_at}]

    if state.last_buffer == nil do
      {actions, %{state | stalled?: true}}
    else
      next_slot = Slot.next_empty(state.current_slot)
      duplicated = %{state.last_buffer | pts: next_slot.starts_at, dts: nil}

      actions =
        actions ++
          [
            notify_parent: {:frame_duplicated, duplicated.pts},
            buffer: {:output, duplicated}
          ]

      # Advance current_slot past the duplicated frame (buffer nil —
      # the duplicate has already been output directly).
      {actions, %{state | stalled?: true, current_slot: next_slot}}
    end
  end

  defp handle_queue_empty(:halt, _ctx, state) do
    # Don't output anything, timer keeps running
    # Send stall notification only on first stall detection
    actions =
      if state.stalled?,
        do: [],
        else: [notify_parent: {:input_stalled, state.current_slot.ends_at}]

    {actions, %{state | stalled?: true}}
  end

  @impl true
  def handle_end_of_stream(:input, _ctx, state) do
    if state.current_slot == nil do
      # No buffers were ever received. Forward EOS directly.
      {[end_of_stream: :output], state}
    else
      # Flush current_slot into the queue if it has an un-enqueued buffer.
      queue =
        if state.current_slot.buffer != nil do
          :queue.in(state.current_slot, state.queue)
        else
          state.queue
        end

      queue = :queue.in(:end_of_stream, queue)
      state = %{state | queue: queue, current_slot: %{state.current_slot | buffer: nil}}

      # If the timer was never started (e.g. very short stream where
      # handle_buffer started the timer already, this is a no-op guard).
      actions =
        if state.timer_started? do
          []
        else
          [start_timer: {:timer, state.period}]
        end

      {actions, %{state | timer_started?: true}}
    end
  end

  # -------------------------------------------------------------------
  # Private helpers
  # -------------------------------------------------------------------

  defp push_buffer(state, buffer) do
    if state.stalled? and state.stall_policy == :duplicate do
      # Stall recovery: place the buffer in the next output slot so fresh
      # content appears immediately. Compute a pts_offset so subsequent
      # input buffers map correctly onto the output timeline.
      new_offset = state.current_slot.ends_at - buffer.pts

      recovery_slot =
        Slot.new(state.current_slot.ends_at, state.period)
        |> Slot.set(buffer)

      # Don't enqueue — leave it in current_slot. The next timer tick
      # will find the queue empty, see current_slot has a buffer, flush
      # it to the queue and output it. This keeps current_slot in sync
      # with the output timeline.
      state = %{
        state
        | current_slot: recovery_slot,
          pts_offset: new_offset,
          stalled?: false,
          last_buffer: recovery_slot.buffer,
          queue: :queue.new()
      }

      {[notify_parent: {:input_resumed, buffer.pts}], state}
    else
      buffer = %{buffer | pts: buffer.pts + state.pts_offset}
      do_push_buffer(state, buffer)
    end
  end

  defp do_push_buffer(state, buffer) do
    cond do
      Slot.accepts?(state.current_slot, buffer) ->
        accept_buffer(state, buffer)

      Slot.old?(state.current_slot, buffer) ->
        {[notify_parent: {:frame_dropped, buffer.pts, state.current_slot.starts_at}], state}

      true ->
        advance_slot_and_retry(state, buffer)
    end
  end

  defp accept_buffer(state, buffer) do
    slot =
      if state.stall_policy == :halt do
        %{state.current_slot | buffer: %{buffer | dts: nil}}
      else
        Slot.set(state.current_slot, buffer)
      end

    {[], %{state | current_slot: slot, last_buffer: slot.buffer}}
  end

  defp advance_slot_and_retry(state, buffer) do
    # Enqueue the current slot — it is now finalised because the incoming
    # buffer belongs to a later slot.
    queue =
      if state.current_slot.buffer != nil do
        :queue.in(state.current_slot, state.queue)
      else
        state.queue
      end

    # Create the next slot. For :duplicate policy, always carry the last
    # known buffer forward so that every intermediate slot is filled —
    # this prevents PTS gaps in the output.
    current_slot =
      cond do
        state.stall_policy == :duplicate and state.current_slot.buffer != nil ->
          Slot.next(state.current_slot)

        state.stall_policy == :duplicate and state.last_buffer != nil ->
          Slot.next_empty(state.current_slot) |> Slot.set(state.last_buffer)

        true ->
          Slot.next_empty(state.current_slot)
      end

    do_push_buffer(%{state | queue: queue, current_slot: current_slot}, buffer)
  end
end
