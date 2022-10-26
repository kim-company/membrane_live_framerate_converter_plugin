defmodule Membrane.LiveFramerateConverter.FrameWindow do
  alias Membrane.Time
  alias Membrane.Buffer

  defmodule Slot do
    defstruct [:starts_at, :ends_at, :buffer]

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

  defstruct [
    # used to fill frames at the beginning of the window
    :previous_last_buffer,
    :last_buffer,
    :starts_at,
    :ends_at,
    :framerate,
    :slots_pending,
    :slots_ready
  ]

  def new(framerate = {_, seconds}, starts_at) do
    %__MODULE__{
      starts_at: starts_at,
      ends_at: starts_at + Time.seconds(seconds),
      framerate: framerate,
      slots_pending: generate_slots(framerate, starts_at),
      slots_ready: []
    }
  end

  def next(old = %__MODULE__{last_buffer: nil}) do
    raise "previous window does not contain a last buffer: #{inspect(old)}"
  end

  def next(old) do
    %{new(old.framerate, old.ends_at) | previous_last_buffer: old.last_buffer, last_buffer: nil}
  end

  def accepts?(window, %Buffer{pts: pts}) do
    pts >= window.starts_at and pts <= window.ends_at
  end

  def is_old?(window, %Buffer{pts: pts}) do
    pts < window.starts_at
  end

  def insert!(window, buffer) do
    [candidate_slot | slots] = window.slots_pending

    if Slot.accepts?(candidate_slot, buffer) do
      # overrides buffers when too many frames are assigned to the same slot,
      # i.e., source has an higher framerate.
      slot = Slot.set(candidate_slot, buffer)
      %{window | slots_pending: [slot | slots]}
    else
      # assumption: buffer pts come strictly monotonically increasing order
      window = %{
        window
        | slots_pending: slots,
          slots_ready: window.slots_ready ++ [candidate_slot]
      }

      insert!(window, buffer)
    end
  end

  @doc """
  Freezes the window early such that it will not fill the missing frames up to
  its end but rather till the last filled slot. Used at stream termination.
  """
  def freeze(window) do
    last_candidate = List.first(window.slots_pending)

    ready =
      if last_candidate != nil and Slot.is_filled?(last_candidate) do
        window.slots_ready ++ [last_candidate]
      else
        window.slots_ready
      end

    %{ends_at: ends_at} = List.last(ready)

    %{window | ends_at: ends_at, slots_pending: [], slots_ready: ready}
  end

  @doc """
      Accepts a only windows that are either frozen or have been filled with
      insert! calls till accept? returned false. Returns the list of buffers
      contained in the window.
  """
  def make_buffers(%{slots_ready: ready, slots_pending: []}) do
    Enum.map(ready, fn %Slot{starts_at: starts_at, buffer: buffer} ->
      %Buffer{buffer | pts: ceil(starts_at), dts: nil}
    end)
  end

  def fill_missing_frames(window) do
    slots_ready =
      window.slots_ready
      |> Enum.map_reduce(window.previous_last_buffer, fn x, previous_buffer ->
        if Slot.is_filled?(x) do
          {x, x.buffer}
        else
          {Slot.set(x, previous_buffer), previous_buffer}
        end
      end)
      |> elem(0)

    %{window | slots_ready: slots_ready, last_buffer: List.last(slots_ready), slots_pending: []}
  end

  defp generate_slots({frames, seconds}, starts_at) do
    interval = Time.seconds(seconds)
    slot_interval = interval / frames

    Range.new(0, frames - 1)
    |> Enum.map(fn index ->
      starts_at = starts_at + slot_interval * index

      %Slot{
        starts_at: starts_at,
        ends_at: starts_at + slot_interval
      }
    end)
  end
end
