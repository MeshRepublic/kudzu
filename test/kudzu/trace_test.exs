defmodule Kudzu.TraceTest do
  use ExUnit.Case, async: true

  alias Kudzu.{Trace, VectorClock}

  describe "Trace.new/4" do
    test "creates trace with required fields" do
      trace = Trace.new("agent-1", :test_purpose)

      assert trace.origin == "agent-1"
      assert trace.purpose == :test_purpose
      assert trace.path == ["agent-1"]
      assert trace.reconstruction_hint == %{}
      assert is_binary(trace.id)
    end

    test "accepts custom path and hints" do
      trace = Trace.new("agent-1", :memory, ["agent-1", "agent-2"], %{key: "value"})

      assert trace.path == ["agent-1", "agent-2"]
      assert trace.reconstruction_hint == %{key: "value"}
    end
  end

  describe "Trace.follow/2" do
    test "adds follower to path" do
      trace = Trace.new("agent-1", :test)
      followed = Trace.follow(trace, "agent-2")

      assert followed.path == ["agent-1", "agent-2"]
    end

    test "increments vector clock" do
      trace = Trace.new("agent-1", :test)
      followed = Trace.follow(trace, "agent-2")

      assert VectorClock.get(followed.timestamp, "agent-2") == 1
    end
  end

  describe "Trace.merge/2" do
    test "merges compatible traces" do
      t1 = Trace.new("agent-1", :test, ["agent-1", "agent-2"])
      t2 = Trace.new("agent-1", :test, ["agent-1", "agent-3"])

      {:ok, merged} = Trace.merge(t1, t2)

      assert "agent-1" in merged.path
      assert "agent-2" in merged.path
      assert "agent-3" in merged.path
    end

    test "rejects incompatible traces" do
      t1 = Trace.new("agent-1", :test)
      t2 = Trace.new("agent-2", :test)  # Different origin

      assert {:error, :incompatible_traces} = Trace.merge(t1, t2)
    end

    test "rejects traces with different purposes" do
      t1 = Trace.new("agent-1", :purpose_a)
      t2 = Trace.new("agent-1", :purpose_b)

      assert {:error, :incompatible_traces} = Trace.merge(t1, t2)
    end
  end

  describe "Trace helper functions" do
    test "path_length returns correct count" do
      trace = Trace.new("a", :test, ["a", "b", "c"])
      assert Trace.path_length(trace) == 3
    end

    test "visited? checks path membership" do
      trace = Trace.new("a", :test, ["a", "b", "c"])

      assert Trace.visited?(trace, "b")
      refute Trace.visited?(trace, "d")
    end

    test "current_location returns last path element" do
      trace = Trace.new("a", :test, ["a", "b", "c"])
      assert Trace.current_location(trace) == "c"
    end

    test "add_hint adds reconstruction metadata" do
      trace = Trace.new("a", :test)
      |> Trace.add_hint(:key1, "value1")
      |> Trace.add_hint(:key2, "value2")

      assert trace.reconstruction_hint == %{key1: "value1", key2: "value2"}
    end
  end
end
