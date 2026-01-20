defmodule Membrane.LiveFramerateConverter.SlotTest do
  use ExUnit.Case, async: true

  alias Membrane.LiveFramerateConverter.Slot
  alias Membrane.Buffer

  describe "Slot.new/2" do
    test "creates slot with correct time windows" do
      starts_at = 0
      duration = 33_333_333  # ~33.33ms (30fps)

      slot = Slot.new(starts_at, duration)

      assert slot.starts_at == 0
      assert slot.ends_at == 33_333_333
      assert slot.buffer == nil
    end

    test "works with non-zero start times" do
      starts_at = 100_000_000  # 100ms
      duration = 16_666_667  # ~16.67ms (60fps)

      slot = Slot.new(starts_at, duration)

      assert slot.starts_at == 100_000_000
      assert slot.ends_at == 116_666_667
    end
  end

  describe "Slot.next/1" do
    test "creates next slot with same duration" do
      slot = Slot.new(0, 33_333_333)
      slot = %{slot | buffer: %Buffer{pts: 0, payload: "test"}}

      next_slot = Slot.next(slot)

      # Next slot starts where previous ended
      assert next_slot.starts_at == 33_333_333
      assert next_slot.ends_at == 66_666_666
      # Buffer is carried over with new PTS
      assert next_slot.buffer.payload == "test"
      assert next_slot.buffer.pts == 33_333_333
    end

    test "maintains slot duration across multiple next calls" do
      slot = Slot.new(0, 40_000_000)  # 25fps
      slot = %{slot | buffer: %Buffer{pts: 0, payload: "a"}}

      slot2 = Slot.next(slot)
      slot3 = Slot.next(slot2)

      assert slot2.ends_at - slot2.starts_at == 40_000_000
      assert slot3.ends_at - slot3.starts_at == 40_000_000
    end
  end

  describe "Slot.accepts?/2" do
    test "accepts buffer within slot time window" do
      slot = Slot.new(100_000_000, 33_333_333)
      # Slot: [100ms, 133.33ms) - half-open interval

      # At start boundary (inclusive)
      assert Slot.accepts?(slot, %Buffer{pts: 100_000_000, payload: <<>>})

      # In middle
      assert Slot.accepts?(slot, %Buffer{pts: 115_000_000, payload: <<>>})

      # Just before end boundary
      assert Slot.accepts?(slot, %Buffer{pts: 133_333_332, payload: <<>>})
    end

    test "rejects buffer before slot" do
      slot = Slot.new(100_000_000, 33_333_333)

      refute Slot.accepts?(slot, %Buffer{pts: 99_999_999, payload: <<>>})
      refute Slot.accepts?(slot, %Buffer{pts: 50_000_000, payload: <<>>})
      refute Slot.accepts?(slot, %Buffer{pts: 0, payload: <<>>})
    end

    test "rejects buffer after slot" do
      slot = Slot.new(100_000_000, 33_333_333)

      # At end boundary (exclusive)
      refute Slot.accepts?(slot, %Buffer{pts: 133_333_333, payload: <<>>})
      refute Slot.accepts?(slot, %Buffer{pts: 133_333_334, payload: <<>>})
      refute Slot.accepts?(slot, %Buffer{pts: 200_000_000, payload: <<>>})
    end
  end

  describe "Slot.old?/2" do
    test "returns true for buffers at or before slot start" do
      slot = Slot.new(100_000_000, 33_333_333)

      assert Slot.old?(slot, %Buffer{pts: 100_000_000, payload: <<>>})
      assert Slot.old?(slot, %Buffer{pts: 99_999_999, payload: <<>>})
      assert Slot.old?(slot, %Buffer{pts: 50_000_000, payload: <<>>})
      assert Slot.old?(slot, %Buffer{pts: 0, payload: <<>>})
    end

    test "returns false for buffers after slot start" do
      slot = Slot.new(100_000_000, 33_333_333)

      refute Slot.old?(slot, %Buffer{pts: 100_000_001, payload: <<>>})
      refute Slot.old?(slot, %Buffer{pts: 150_000_000, payload: <<>>})
      refute Slot.old?(slot, %Buffer{pts: 200_000_000, payload: <<>>})
    end
  end

  describe "Slot.set/2" do
    test "assigns buffer to slot with normalized PTS" do
      slot = Slot.new(100_000_000, 33_333_333)
      buffer = %Buffer{pts: 115_000_000, dts: 115_000_000, payload: "test", metadata: %{key: "value"}}

      slot = Slot.set(slot, buffer)

      # PTS normalized to slot start
      assert slot.buffer.pts == 100_000_000
      # DTS set to nil
      assert slot.buffer.dts == nil
      # Other fields preserved
      assert slot.buffer.payload == "test"
      assert slot.buffer.metadata == %{key: "value"}
    end

    test "handles buffer with nil DTS" do
      slot = Slot.new(0, 33_333_333)
      buffer = %Buffer{pts: 10_000_000, dts: nil, payload: ""}

      slot = Slot.set(slot, buffer)

      assert slot.buffer.pts == 0
      assert slot.buffer.dts == nil
    end
  end
end
