defmodule Kudzu.VectorClockTest do
  use ExUnit.Case, async: true

  alias Kudzu.VectorClock

  describe "VectorClock.new/1" do
    test "creates empty clock with nil" do
      vc = VectorClock.new(nil)
      assert vc.clocks == %{}
    end

    test "creates clock initialized for agent" do
      vc = VectorClock.new("agent-1")
      assert vc.clocks == %{"agent-1" => 0}
    end
  end

  describe "VectorClock.increment/2" do
    test "increments agent's counter" do
      vc = VectorClock.new("agent-1")
      |> VectorClock.increment("agent-1")
      |> VectorClock.increment("agent-1")

      assert VectorClock.get(vc, "agent-1") == 2
    end

    test "adds new agent with increment" do
      vc = VectorClock.new("agent-1")
      |> VectorClock.increment("agent-2")

      assert VectorClock.get(vc, "agent-2") == 1
    end
  end

  describe "VectorClock.merge/2" do
    test "takes maximum of each component" do
      vc1 = %VectorClock{clocks: %{"a" => 3, "b" => 1}}
      vc2 = %VectorClock{clocks: %{"a" => 1, "b" => 5, "c" => 2}}

      merged = VectorClock.merge(vc1, vc2)

      assert VectorClock.get(merged, "a") == 3
      assert VectorClock.get(merged, "b") == 5
      assert VectorClock.get(merged, "c") == 2
    end
  end

  describe "VectorClock.compare/2" do
    test "detects equal clocks" do
      vc1 = %VectorClock{clocks: %{"a" => 1, "b" => 2}}
      vc2 = %VectorClock{clocks: %{"a" => 1, "b" => 2}}

      assert VectorClock.compare(vc1, vc2) == :equal
    end

    test "detects happened-before" do
      vc1 = %VectorClock{clocks: %{"a" => 1, "b" => 1}}
      vc2 = %VectorClock{clocks: %{"a" => 2, "b" => 2}}

      assert VectorClock.compare(vc1, vc2) == :before
    end

    test "detects happened-after" do
      vc1 = %VectorClock{clocks: %{"a" => 3, "b" => 3}}
      vc2 = %VectorClock{clocks: %{"a" => 1, "b" => 1}}

      assert VectorClock.compare(vc1, vc2) == :after
    end

    test "detects concurrent events" do
      vc1 = %VectorClock{clocks: %{"a" => 3, "b" => 1}}
      vc2 = %VectorClock{clocks: %{"a" => 1, "b" => 3}}

      assert VectorClock.compare(vc1, vc2) == :concurrent
    end
  end

  describe "VectorClock.happened_before?/2" do
    test "returns true for causal ordering" do
      vc1 = %VectorClock{clocks: %{"a" => 1}}
      vc2 = %VectorClock{clocks: %{"a" => 2}}

      assert VectorClock.happened_before?(vc1, vc2)
      refute VectorClock.happened_before?(vc2, vc1)
    end
  end

  describe "serialization" do
    test "to_map and from_map roundtrip" do
      vc = %VectorClock{clocks: %{"a" => 5, "b" => 3}}

      map = VectorClock.to_map(vc)
      restored = VectorClock.from_map(map)

      assert VectorClock.compare(vc, restored) == :equal
    end
  end
end
