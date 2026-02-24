defmodule Kudzu.Brain.IntegrationTest do
  @moduledoc """
  End-to-end integration tests for the Kudzu Brain.

  These tests verify that the Brain starts, creates its hologram,
  exercises all three reasoning tiers, and that supporting modules
  (silos, tools, inference engine) work correctly together.
  """
  use ExUnit.Case, async: false

  alias Kudzu.Brain

  # Brain takes 2s to init hologram — wait for it
  setup do
    wait_for_brain(50)
    :ok
  end

  defp wait_for_brain(0), do: :ok

  defp wait_for_brain(n) do
    state = Brain.get_state()

    if state.hologram_id do
      :ok
    else
      Process.sleep(100)
      wait_for_brain(n - 1)
    end
  end

  @tag :integration
  test "brain starts, creates hologram, and has initial state" do
    state = Brain.get_state()
    assert state.status == :sleeping
    assert is_binary(state.hologram_id)
    assert length(state.desires) == 5
  end

  @tag :integration
  test "brain runs wake cycle" do
    initial = Brain.get_state()
    Brain.wake_now()
    Process.sleep(2_000)

    state = Brain.get_state()
    assert state.cycle_count > initial.cycle_count
  end

  @tag :integration
  test "self-model silo exists" do
    # Self-model should be created by Brain during init
    {:ok, _pid} = Kudzu.Silo.find("self")
  end

  @tag :integration
  test "introspection tools work" do
    {:ok, health} = Kudzu.Brain.Tools.Introspection.execute("check_health", %{})
    assert health.holograms.count > 0
    assert health.beam.process_count > 0
  end

  @tag :integration
  test "host tools work" do
    {:ok, disk} = Kudzu.Brain.Tools.Host.execute("check_disk", %{})
    assert length(disk.partitions) > 0

    {:ok, mem} = Kudzu.Brain.Tools.Host.execute("check_memory", %{})
    assert mem.total_mb != nil
  end

  @tag :integration
  test "budget tracker starts at zero" do
    state = Brain.get_state()
    assert state.budget.estimated_cost_usd == 0.0
    assert state.budget.api_calls == 0
  end

  @tag :integration
  test "escalation tool records alert" do
    {:ok, result} =
      Kudzu.Brain.Tools.Escalation.execute("record_alert", %{
        "severity" => "warning",
        "summary" => "Integration test alert"
      })

    assert result.recorded == true
  end

  @tag :integration
  test "relationship extractor works" do
    text = "Water causes erosion. Erosion requires time."
    triples = Kudzu.Silo.Extractor.extract_patterns(text)
    assert length(triples) >= 1
  end

  @tag :integration
  test "inference engine probes silos" do
    # Self-model silo should have architecture knowledge
    results = Kudzu.Brain.InferenceEngine.probe("self", "kudzu")
    assert is_list(results)
  end
end
