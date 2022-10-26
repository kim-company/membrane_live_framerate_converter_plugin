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
    :slots,
    :cursor
  ]

  def new(framerate = {_, seconds}, starts_at) do
    %__MODULE__{
      starts_at: starts_at,
      ends_at: starts_at + Time.seconds(seconds),
      framerate: framerate,
      slots: generate_slots(framerate, starts_at),
      cursor: 0
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
    candidate = Enum.at(window.slots, window.cursor)

    if Slot.accepts?(candidate, buffer) do
      # overrides buffers when too many frames are assigned to the same slot,
      # i.e., source has an higher framerate.
      slot = Slot.set(candidate, buffer)
      %{window | slots: update_slot_at(window.slots, slot, window.cursor)}
    else
      # assumption: buffer pts come strictly monotonically increasing order
      window = %{window | cursor: window.cursor + 1}
      insert!(window, buffer)
    end
  end

  @doc """
  Freezes the window early such that it will not fill the missing frames up to
  its end but rather till the last filled slot. Used at stream termination.
  """
  def freeze(window) do
    slots = Enum.slice(window.slots, 0, window.cursor + 1)
    %{ends_at: ends_at} = List.last(slots)
    %{window | ends_at: ends_at, slots: slots}
  end

  @doc """
      Accepts a only windows that are either frozen or have been filled with
      insert! calls till accept? returned false. Returns the list of buffers
      contained in the window.
  """
  def make_buffers(%__MODULE__{slots: slots}) do
    Enum.map(slots, fn %Slot{starts_at: starts_at, buffer: buffer} ->
      %Buffer{buffer | pts: ceil(starts_at), dts: nil}
    end)
  end

  def fill_missing_frames(window) do
    slots =
      window.slots
      |> Enum.map_reduce(window.previous_last_buffer, fn x, previous_buffer ->
        if Slot.is_filled?(x) do
          {x, x.buffer}
        else
          if previous_buffer == nil do
            raise "attempted filling slot #{inspect(x)} with an empty buffer"
          end

          {Slot.set(x, previous_buffer), previous_buffer}
        end
      end)
      |> elem(0)

    last_slot = List.last(slots)

    if last_slot == nil or last_slot.buffer == nil do
      raise "last slot is empty: #{inspect(window)}"
    end

    %{window | slots: slots, last_buffer: last_slot.buffer}
  end

  defp update_slot_at(slots, slot, index) do
    Enum.slice(slots, 0, index) ++ [slot] ++ Enum.slice(slots, Range.new(index + 1, -1))
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
