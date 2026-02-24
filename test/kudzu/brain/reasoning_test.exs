defmodule Kudzu.Brain.ReasoningTest do
  use ExUnit.Case, async: false

  alias Kudzu.Brain.PromptBuilder

  test "prompt builder generates system prompt with desires" do
    state = %Kudzu.Brain{
      hologram_id: "test-id",
      hologram_pid: nil,
      desires: ["desire one", "desire two"],
      cycle_count: 5,
      status: :reasoning,
      config: %{}
    }

    prompt = PromptBuilder.build(state)
    assert prompt =~ "Kudzu Brain"
    assert prompt =~ "desire one"
    assert prompt =~ "desire two"
    assert prompt =~ "test-id"
    assert prompt =~ "Cycle #5"
  end

  test "prompt builder handles nil hologram pid" do
    state = %Kudzu.Brain{
      hologram_id: "test-id",
      hologram_pid: nil,
      desires: [],
      cycle_count: 0,
      status: :sleeping,
      config: %{}
    }

    prompt = PromptBuilder.build(state)
    assert prompt =~ "hologram not ready"
  end

  test "prompt builder handles empty desires" do
    state = %Kudzu.Brain{
      hologram_id: "test-id",
      hologram_pid: nil,
      desires: [],
      cycle_count: 0,
      status: :sleeping,
      config: %{}
    }

    prompt = PromptBuilder.build(state)
    assert prompt =~ "no desires set"
  end

  test "prompt builder includes architecture and guidelines sections" do
    state = %Kudzu.Brain{
      hologram_id: "abc-123",
      hologram_pid: nil,
      desires: ["learn everything"],
      cycle_count: 42,
      status: :reasoning,
      config: %{}
    }

    prompt = PromptBuilder.build(state)
    assert prompt =~ "## Your Architecture"
    assert prompt =~ "## Your Desires"
    assert prompt =~ "## Recent Memory"
    assert prompt =~ "## Available Silos"
    assert prompt =~ "## Guidelines"
    assert prompt =~ "## Current Cycle"
    assert prompt =~ "kudzu_evolve"
    assert prompt =~ "three tiers"
    assert prompt =~ "abc-123"
    assert prompt =~ "Cycle #42"
    assert prompt =~ "reasoning"
  end

  test "prompt builder formats silos section" do
    state = %Kudzu.Brain{
      hologram_id: "test-id",
      hologram_pid: nil,
      desires: [],
      cycle_count: 0,
      status: :sleeping,
      config: %{}
    }

    prompt = PromptBuilder.build(state)
    # Silos section should either list existing silos or say "no silos yet"
    # In test environment, there may be leftover test silos from other tests
    silos = Kudzu.Silo.list()

    if silos == [] do
      assert prompt =~ "no silos yet"
    else
      # If silos exist, at least one domain should appear in the prompt
      {domain, _pid, _id} = hd(silos)
      assert prompt =~ domain
    end
  end
end
