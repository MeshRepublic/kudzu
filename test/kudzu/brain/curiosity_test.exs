defmodule Kudzu.Brain.CuriosityTest do
  use ExUnit.Case, async: true

  alias Kudzu.Brain.Curiosity
  alias Kudzu.Brain.WorkingMemory

  @desires [
    "Maintain Kudzu system health and recover from failures",
    "Build accurate self-model of architecture, resources, and capabilities",
    "Learn from every observation — discover patterns in system behavior"
  ]

  test "generate_from_desires/2 produces questions from desires" do
    silos = ["self", "health"]
    questions = Curiosity.generate_from_desires(@desires, silos)
    assert is_list(questions)
    assert length(questions) > 0
    assert Enum.all?(questions, &is_binary/1)
  end

  test "generate_from_desires/2 produces different questions for different silo states" do
    q1 = Curiosity.generate_from_desires(@desires, [])
    q2 = Curiosity.generate_from_desires(@desires, ["self", "health", "architecture"])
    assert q1 != q2
  end

  test "generate_from_gaps/1 produces questions from working memory dead ends" do
    wm = WorkingMemory.new()
    wm = WorkingMemory.add_chain(wm, [
      %{concept: "disk_pressure", similarity: 0.8, source: "health"},
      %{concept: "unknown_cause", similarity: 0.0, source: "dead_end"}
    ])
    questions = Curiosity.generate_from_gaps(wm)
    assert is_list(questions)
  end

  test "generate_from_salience/1 returns a list" do
    questions = Curiosity.generate_from_salience(5)
    assert is_list(questions)
  end

  test "generate/3 combines all sources and returns prioritized questions" do
    wm = WorkingMemory.new()
    silos = ["self"]
    questions = Curiosity.generate(@desires, wm, silos)
    assert is_list(questions)
    assert length(questions) <= 5
  end
end
