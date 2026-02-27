defmodule Kudzu.Brain.WorkingMemoryTest do
  use ExUnit.Case, async: true

  alias Kudzu.Brain.WorkingMemory

  test "new/0 creates empty working memory" do
    wm = WorkingMemory.new()
    assert wm.active_concepts == %{}
    assert wm.recent_chains == []
    assert wm.pending_questions == []
    assert wm.context == nil
  end

  test "activate/3 adds a concept with score and source" do
    wm = WorkingMemory.new()
    wm = WorkingMemory.activate(wm, "disk_pressure", %{score: 0.8, source: "health_silo"})
    assert Map.has_key?(wm.active_concepts, "disk_pressure")
    assert wm.active_concepts["disk_pressure"].score == 0.8
  end

  test "activate/3 reinforces existing concept (score increases)" do
    wm = WorkingMemory.new()
    wm = WorkingMemory.activate(wm, "disk", %{score: 0.5, source: "silo_a"})
    wm = WorkingMemory.activate(wm, "disk", %{score: 0.7, source: "silo_b"})
    assert wm.active_concepts["disk"].score > 0.5
  end

  test "activate/3 evicts lowest-scored concept when at max capacity" do
    wm = WorkingMemory.new(max_concepts: 3)
    wm = WorkingMemory.activate(wm, "a", %{score: 0.3, source: "s"})
    wm = WorkingMemory.activate(wm, "b", %{score: 0.5, source: "s"})
    wm = WorkingMemory.activate(wm, "c", %{score: 0.7, source: "s"})
    wm = WorkingMemory.activate(wm, "d", %{score: 0.9, source: "s"})
    refute Map.has_key?(wm.active_concepts, "a")
    assert Map.has_key?(wm.active_concepts, "d")
    assert map_size(wm.active_concepts) == 3
  end

  test "decay/2 reduces all concept scores" do
    wm = WorkingMemory.new()
    wm = WorkingMemory.activate(wm, "disk", %{score: 0.8, source: "s"})
    wm = WorkingMemory.decay(wm, 0.1)
    assert wm.active_concepts["disk"].score == 0.7
  end

  test "decay/2 removes concepts that fall below threshold" do
    wm = WorkingMemory.new(eviction_threshold: 0.2)
    wm = WorkingMemory.activate(wm, "fading", %{score: 0.25, source: "s"})
    wm = WorkingMemory.decay(wm, 0.1)
    refute Map.has_key?(wm.active_concepts, "fading")
  end

  test "add_chain/2 records a completed reasoning chain" do
    wm = WorkingMemory.new()
    chain = [%{concept: "disk", score: 0.8}, %{concept: "storage", score: 0.7}]
    wm = WorkingMemory.add_chain(wm, chain)
    assert length(wm.recent_chains) == 1
  end

  test "add_chain/2 evicts oldest chain when at max" do
    wm = WorkingMemory.new(max_chains: 2)
    wm = WorkingMemory.add_chain(wm, [%{concept: "a"}])
    wm = WorkingMemory.add_chain(wm, [%{concept: "b"}])
    wm = WorkingMemory.add_chain(wm, [%{concept: "c"}])
    assert length(wm.recent_chains) == 2
    concepts = wm.recent_chains |> Enum.flat_map(fn chain -> Enum.map(chain, & &1.concept) end)
    refute "a" in concepts
  end

  test "add_question/2 adds a pending question" do
    wm = WorkingMemory.new()
    wm = WorkingMemory.add_question(wm, "Why is disk high?")
    assert "Why is disk high?" in wm.pending_questions
  end

  test "pop_question/1 returns and removes first question" do
    wm = WorkingMemory.new()
    wm = WorkingMemory.add_question(wm, "Q1")
    wm = WorkingMemory.add_question(wm, "Q2")
    {question, wm} = WorkingMemory.pop_question(wm)
    assert question == "Q1"
    assert length(wm.pending_questions) == 1
  end

  test "pop_question/1 returns nil when empty" do
    wm = WorkingMemory.new()
    {question, _wm} = WorkingMemory.pop_question(wm)
    assert question == nil
  end

  test "get_priming_concepts/1 returns top active concepts for thought biasing" do
    wm = WorkingMemory.new()
    wm = WorkingMemory.activate(wm, "disk", %{score: 0.9, source: "s"})
    wm = WorkingMemory.activate(wm, "storage", %{score: 0.3, source: "s"})
    wm = WorkingMemory.activate(wm, "consolidation", %{score: 0.7, source: "s"})
    priming = WorkingMemory.get_priming_concepts(wm, 2)
    assert length(priming) == 2
    assert hd(priming) == "disk"
  end
end
