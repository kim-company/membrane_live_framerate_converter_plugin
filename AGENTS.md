## Project Overview

This is a Membrane Framework plugin that converts variable input framerates to stable output framerates for realtime applications. It works by dropping or duplicating frames to maintain a consistent target framerate, making it suitable for live video processing scenarios.

## Development Commands

### Dependencies
```bash
mix deps.get
```

### Testing
```bash
# Run all tests
mix test

# Run a specific test file
mix test test/membrane/live_framerate_converter_comprehensive_test.exs

# Run a specific test
mix test test/membrane/live_framerate_converter_comprehensive_test.exs:9
```

### Code Formatting
```bash
# Check formatting
mix format --check-formatted

# Apply formatting
mix format
```

### Compilation
```bash
mix compile
```

## Architecture

### Core Component: Membrane.LiveFramerateConverter

The plugin implements a Membrane Filter element with these key characteristics:

- **Mode**: Auto flow control input → Auto flow control output
- **Format**: Accepts and produces aligned RawVideo frames
- **Pad Definitions**: Uses `flow_control: :auto` for both input and output
- **Stall Policy**: Configurable behavior when input stops providing data (`:duplicate` or `:halt`)
- **No Loading Phase**: Timer starts on first buffer arrival — zero startup latency

### Frame Processing Algorithm

The converter uses a "slot-based" time window system:

1. **Slot Structure** (`Slot` module): Each slot represents a time window for one output frame
   - `starts_at`: Beginning of the time window (inclusive)
   - `ends_at`: End of the time window (exclusive)
   - `buffer`: The actual frame buffer to output for this slot
   - Uses half-open interval `[starts_at, ends_at)` to avoid boundary overlaps

2. **Processing Flow**:
   - Timer starts on first buffer arrival, ticks at target framerate period
   - **Frame Mapping**: Input buffers with `starts_at <= PTS < ends_at` are assigned to that slot
   - **Frame Dropping**: Late buffers (PTS < slot start) are dropped with notification
   - **Frame Duplication**: For `:duplicate` policy, intermediate empty slots are always
     filled by carrying the last known buffer forward — this prevents PTS gaps in the output
   - **Current Slot Flush**: On timer tick, if the queue is empty but `current_slot` has a
     buffer, it is flushed into the queue and output. This handles the case where input
     arrives between ticks without a subsequent buffer to trigger `advance_slot_and_retry`.

3. **State Management**:
   - `current_slot`: The current time window being filled by input
   - `queue`: Finalised slots ready for output (uses Erlang's `:queue` module)
   - `stalled?`: Whether the element is in stall mode (queue drained during active phase)
   - `pts_offset`: Offset applied to input PTS after stall recovery
   - `last_buffer`: Most recent buffer payload, used for duplication during stalls
   - `timer_started?`: Whether the output timer has been started

### Key Dependencies

- `membrane_core` (~> 1.2): Core Membrane framework
- `membrane_raw_video_format` (~> 0.2): Raw video format definitions
- `:queue`: Erlang's built-in queue module (used for slot buffering)
- `membrane_realtimer_plugin` (test only): Provides realtime processing for tests

### Testing

The test suite includes:

**Unit tests** (`slot_test.exs`):
- Tests for `Slot` module functions (new, next, accepts?, old?, set)

**Comprehensive tests** (`comprehensive_test.exs`):
- PTS correctness and output quality
- Different target framerates (30fps, 60fps, 24fps, fractional)
- Edge cases (empty input, single buffer, boundary alignment)
- Frame dropping and duplication behavior

**Stall policy tests** (`stall_policy_test.exs`):
- Tests for `:duplicate` and `:halt` policies
- Late buffer handling after duplication
- Timing verification for duplicated frames
- Stall recovery: single stall with PTS continuity verification
- Stall recovery: multiple stalls with payload presence from all bursts

**Notification tests** (`notifications_test.exs`):
- Tests for parent notifications (frame_dropped, input_stalled, input_resumed, frame_duplicated)
- Stall recovery notification: verifies `input_resumed` carries the original source PTS
- Note: Stall/resume/duplication notifications require realtimer for realistic testing

## Implementation Notes

### Time Handling
- All PTS values are integers in nanoseconds
- Period calculation: `round(Time.seconds(seconds) / frames)` (in nanoseconds)
- Integer arithmetic is used for all time calculations (addition, subtraction, comparison)
- Buffers are normalized to slot start time: `%{buffer | pts: slot.starts_at, dts: nil}`

### Slot Enqueueing Strategy

Slots are enqueued only when they are **finalised** — i.e. when a later input buffer
triggers `advance_slot_and_retry`, or when end-of-stream arrives. The `current_slot`
is never enqueued while it is still the active target for incoming buffers. This avoids
stale-queue issues where the queue holds an outdated copy of a slot that was later
overwritten by a newer input buffer.

When the timer ticks and the queue is empty, it checks `current_slot` as a fallback:
if `current_slot` has a buffer, it is flushed into the queue and immediately consumed.

### Intermediate Slot Filling (PTS Gap Prevention)

In `advance_slot_and_retry`, for the `:duplicate` policy, every intermediate slot
between the current position and the target slot is filled with a duplicate of the
last known buffer. This ensures the output PTS is always evenly spaced at the target
period — no gaps, regardless of input timing.

The carry-forward uses two branches:
- If `current_slot.buffer` is non-nil: `Slot.next` (carries the slot's own buffer)
- If `current_slot.buffer` is nil but `last_buffer` exists: `Slot.next_empty |> Slot.set(last_buffer)`

### Stall Policies

When input stops providing data (queue becomes empty during timer ticks), two policies are available:

#### `:duplicate` Policy (Default)
- **Behavior**: Duplicates the last received frame to maintain constant output framerate
- **Use Case**: Live streaming where consistent framerate is critical
- **Implementation**: When queue is empty, outputs duplicate of last buffer at next slot's PTS
- **Effect**: Output continues at target framerate even if input stalls

#### `:halt` Policy
- **Behavior**: Stops outputting frames until input resumes or end of stream
- **Use Case**: Scenarios where frame duplication is undesirable
- **Implementation**: When queue is empty, timer continues but no output is produced
- **Effect**: Output pauses during input stalls, resumes when input arrives

### Stall Recovery (`:duplicate` policy)

The output timeline is the authority — it ticks at the target framerate regardless of input.
During a stall, duplication keeps the output cadence constant. When input resumes, the
source PTS is behind the output timeline (the stall created a gap between them).

Recovery is handled in `push_buffer` and fires unconditionally when `stalled? == true`
and a buffer arrives:

1. The buffer is placed in a recovery slot at `current_slot.ends_at` and stored as
   `current_slot` (not enqueued). The next timer tick flushes it via the fallback path.
2. A `pts_offset` is computed: `recovery_slot_start − source_pts`. This maps the source's
   PTS timeline onto the output timeline.
3. The stale queue is flushed, `stalled?` is cleared, and `{:input_resumed, source_pts}`
   is sent to the parent.
4. All subsequent input buffers have `pts_offset` added to their PTS before slot matching,
   so they land in the correct output slots.

**Why recovery is at the top of `push_buffer`:** during a stall the output slot timeline
advances via duplication while source PTS stays where it was. When input resumes, the
source buffer's PTS could land anywhere relative to `current_slot` depending on timing:
behind it (old), inside it (accepted), or ahead of it (future). Checking for stall recovery
before any slot matching handles all three cases uniformly, producing gapless output with
exact period spacing.

Multiple stalls simply recompute the offset each time. The offset can be positive (source
behind output, common case) or negative (source slightly ahead due to fewer duplications
than expected). Both work correctly because `Slot.set` normalizes the output PTS to the
slot boundary.

### Parent Notifications

The converter sends notifications to the parent process for important events:

#### `{:frame_dropped, pts, threshold}`
- **When**: A late buffer arrives (PTS < current slot start)
- **Parameters**:
  - `pts`: The dropped buffer's presentation timestamp
  - `threshold`: The minimum acceptable PTS (current slot start)
- **Use Case**: Monitor input timing issues, detect out-of-order buffers

#### `{:input_stalled, pts}`
- **When**: Queue becomes empty during active phase (first detection only)
- **Parameters**:
  - `pts`: The timestamp where stall was detected (current slot end)
- **Use Case**: Alert that input stopped providing data
- **Note**: Sent once when stall is first detected, not repeatedly

#### `{:input_resumed, pts}`
- **When**: First buffer arrives after a `:duplicate`-policy stall, triggering recovery
- **Parameters**:
  - `pts`: The **original source PTS** of the buffer that triggered recovery (before offset)
- **Use Case**: Track input recovery after stall
- **Note**: Only sent for `:duplicate` policy. The `pts` value reflects the source timeline,
  not the output timeline — useful for correlating with the input stream

#### `{:frame_duplicated, pts}`
- **When**: Frame is duplicated due to stall (`:duplicate` policy only)
- **Parameters**:
  - `pts`: The timestamp of the duplicated frame
- **Use Case**: Track artificial frames inserted to maintain framerate
- **Note**: Sent for each duplication while stalled

### Edge Cases
- **End of Stream**: Flushes current_slot, pushes `:end_of_stream` marker into queue
- **Empty Queue with `:duplicate`**: Duplicates last buffer with PTS at next slot boundary
- **Empty Queue with `:halt`**: No output produced, timer keeps running
- **Late Buffers**: Dropped with `{:frame_dropped, pts, threshold}` notification
- **Boundary Buffers**: Half-open intervals prevent ambiguity at slot boundaries
- **Stall Recovery**: First post-stall buffer bypasses slot matching entirely, placed in next output slot
- **Negative `pts_offset`**: Occurs when fewer duplications happen than expected (source slightly ahead); works correctly because output PTS is always derived from the slot, not the source
- **Multiple Stalls**: Each recovery recomputes `pts_offset` from scratch; offsets do not accumulate
- **Empty Input**: If no buffers arrive before EOS, `end_of_stream` is forwarded directly without starting the timer
