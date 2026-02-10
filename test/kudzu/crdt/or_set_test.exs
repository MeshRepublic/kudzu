defmodule Kudzu.CRDT.ORSetTest do
  use ExUnit.Case, async: true

  alias Kudzu.CRDT.ORSet

  describe "new/1" do
    test "creates empty set for a node" do
      set = ORSet.new("node1")

      assert set.node_id == "node1"
      assert ORSet.size(set) == 0
      assert ORSet.to_list(set) == []
    end
  end

  describe "add/2" do
    test "adds element to set" do
      set = ORSet.new("node1")
      |> ORSet.add("hello")

      assert ORSet.member?(set, "hello")
      assert ORSet.size(set) == 1
    end

    test "can add same element multiple times (with different tags)" do
      set = ORSet.new("node1")
      |> ORSet.add("hello")
      |> ORSet.add("hello")

      # Still only one logical element
      assert ORSet.size(set) == 1

      # But has multiple tags (for CRDT semantics)
      tags = Map.get(set.elements, "hello")
      assert MapSet.size(tags) == 2
    end

    test "adds multiple different elements" do
      set = ORSet.new("node1")
      |> ORSet.add("a")
      |> ORSet.add("b")
      |> ORSet.add("c")

      assert ORSet.size(set) == 3
      assert "a" in ORSet.to_list(set)
      assert "b" in ORSet.to_list(set)
      assert "c" in ORSet.to_list(set)
    end
  end

  describe "remove/2" do
    test "removes element from set" do
      set = ORSet.new("node1")
      |> ORSet.add("hello")
      |> ORSet.remove("hello")

      refute ORSet.member?(set, "hello")
      assert ORSet.size(set) == 0
    end

    test "removing non-existent element is no-op" do
      set = ORSet.new("node1")
      |> ORSet.remove("hello")

      assert ORSet.size(set) == 0
    end

    test "add after remove results in element present (add-wins)" do
      set = ORSet.new("node1")
      |> ORSet.add("hello")
      |> ORSet.remove("hello")
      |> ORSet.add("hello")

      assert ORSet.member?(set, "hello")
    end
  end

  describe "merge/2" do
    test "merges concurrent adds" do
      set1 = ORSet.new("node1") |> ORSet.add("a")
      set2 = ORSet.new("node2") |> ORSet.add("b")

      merged = ORSet.merge(set1, set2)

      assert ORSet.member?(merged, "a")
      assert ORSet.member?(merged, "b")
    end

    test "add-wins on concurrent add/remove" do
      # Simulate concurrent operations
      base = ORSet.new("node1") |> ORSet.add("hello")

      # Node 1 adds again
      set1 = ORSet.add(base, "hello")

      # Node 2 removes (using base state, doesn't see new add)
      set2 = ORSet.remove(base, "hello")

      # Merge should result in "hello" being present (add wins)
      merged = ORSet.merge(set1, set2)

      assert ORSet.member?(merged, "hello")
    end

    test "merge is commutative" do
      set1 = ORSet.new("node1") |> ORSet.add("a") |> ORSet.add("b")
      set2 = ORSet.new("node2") |> ORSet.add("b") |> ORSet.add("c")

      merged1 = ORSet.merge(set1, set2)
      merged2 = ORSet.merge(set2, set1)

      assert ORSet.equal?(merged1, merged2)
    end

    test "merge is associative" do
      set1 = ORSet.new("node1") |> ORSet.add("a")
      set2 = ORSet.new("node2") |> ORSet.add("b")
      set3 = ORSet.new("node3") |> ORSet.add("c")

      merged_12_3 = ORSet.merge(ORSet.merge(set1, set2), set3)
      merged_1_23 = ORSet.merge(set1, ORSet.merge(set2, set3))

      assert ORSet.equal?(merged_12_3, merged_1_23)
    end

    test "merge is idempotent" do
      set = ORSet.new("node1") |> ORSet.add("a") |> ORSet.add("b")

      merged = ORSet.merge(set, set)

      assert ORSet.equal?(merged, set)
    end
  end

  describe "equal?/2" do
    test "empty sets are equal" do
      set1 = ORSet.new("node1")
      set2 = ORSet.new("node2")

      assert ORSet.equal?(set1, set2)
    end

    test "sets with same elements are equal" do
      set1 = ORSet.new("node1") |> ORSet.add("a") |> ORSet.add("b")
      set2 = ORSet.new("node2") |> ORSet.add("b") |> ORSet.add("a")

      assert ORSet.equal?(set1, set2)
    end

    test "sets with different elements are not equal" do
      set1 = ORSet.new("node1") |> ORSet.add("a")
      set2 = ORSet.new("node2") |> ORSet.add("b")

      refute ORSet.equal?(set1, set2)
    end
  end

  describe "delta/2" do
    test "delta contains only new additions" do
      old = ORSet.new("node1") |> ORSet.add("a")
      new = old |> ORSet.add("b") |> ORSet.add("c")

      delta = ORSet.delta(old, new)

      # Delta should not have "a" tags (already in old)
      refute Map.has_key?(delta.elements, "a")

      # Delta should have "b" and "c"
      assert Map.has_key?(delta.elements, "b")
      assert Map.has_key?(delta.elements, "c")
    end

    test "apply_delta merges delta correctly" do
      set1 = ORSet.new("node1") |> ORSet.add("a")
      set2 = ORSet.new("node2") |> ORSet.add("b")

      delta = ORSet.delta(ORSet.new("node2"), set2)
      merged = ORSet.apply_delta(set1, delta)

      assert ORSet.member?(merged, "a")
      assert ORSet.member?(merged, "b")
    end
  end

  describe "serialization" do
    test "to_map/1 and from_map/1 roundtrip" do
      original = ORSet.new("node1")
      |> ORSet.add("a")
      |> ORSet.add("b")
      |> ORSet.add("c")
      |> ORSet.remove("b")

      map = ORSet.to_map(original)
      restored = ORSet.from_map(map)

      assert ORSet.equal?(original, restored)
      assert restored.node_id == original.node_id
    end
  end
end
