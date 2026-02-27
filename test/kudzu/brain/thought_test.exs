defmodule Kudzu.Brain.ThoughtTest do
  use ExUnit.Case, async: false

  alias Kudzu.Brain.Thought

  setup do
    # Create a test silo with known relationships
    domain = "test_thought_#{:rand.uniform(999999)}"
    {:ok, _pid} = Kudzu.Silo.create(domain)
    Kudzu.Silo.store_relationship(domain, {"disk_pressure", "caused_by", "large_files"})
    Kudzu.Silo.store_relationship(domain, {"large_files", "produced_by", "consolidation"})
    Kudzu.Silo.store_relationship(domain, {"consolidation", "creates", "temp_files"})
    Process.sleep(100)

    on_exit(fn ->
      Kudzu.Silo.delete(domain)
    end)

    %{domain: domain}
  end

  test "run/2 returns a Result struct" do
    result = Thought.run("test concept", monarch_pid: self(), timeout: 5_000)
    assert %Thought.Result{} = result
    assert is_list(result.chain)
    assert is_float(result.confidence)
    assert result.input == "test concept"
  end

  test "run/2 activates concepts from silos", %{domain: _domain} do
    result = Thought.run("disk_pressure", monarch_pid: self(), timeout: 5_000)
    assert is_list(result.activations)
  end

  test "run/2 respects timeout" do
    result = Thought.run("anything", monarch_pid: self(), timeout: 100)
    assert %Thought.Result{} = result
  end

  test "run/2 respects max_depth" do
    result = Thought.run("disk_pressure",
      monarch_pid: self(),
      max_depth: 0,
      timeout: 5_000
    )
    assert %Thought.Result{} = result
    assert result.depth == 0
  end

  test "async_run/2 sends {:thought_result, id, result} to monarch" do
    {:ok, thought_id} = Thought.async_run("test concept",
      monarch_pid: self(),
      timeout: 5_000
    )
    assert is_binary(thought_id)
    assert_receive {:thought_result, ^thought_id, %Thought.Result{}}, 6_000
  end
end
