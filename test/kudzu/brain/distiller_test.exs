defmodule Kudzu.Brain.DistillerTest do
  use ExUnit.Case, async: true

  alias Kudzu.Brain.Distiller

  test "extract_chains/1 extracts causal relationships from text" do
    text = "The disk pressure is high because consolidation produces temporary files."
    chains = Distiller.extract_chains(text)
    assert is_list(chains)
    assert length(chains) >= 1
    assert Enum.any?(chains, fn {_s, r, _o} -> r in ["causes", "caused_by", "because", "produces"] end)
  end

  test "extract_chains/1 handles multiple sentences" do
    text = """
    Storage is running low because of large log files.
    The log rotation requires a cron job.
    Consolidation uses temporary disk space.
    """
    chains = Distiller.extract_chains(text)
    assert length(chains) >= 2
  end

  test "extract_chains/1 returns empty list for unstructured text" do
    text = "Hello, how are you today?"
    chains = Distiller.extract_chains(text)
    assert chains == []
  end

  test "extract_reflex_candidates/2 identifies simple cause-action patterns" do
    chains = [
      {"disk_pressure", "caused_by", "temp_files"},
      {"temp_files", "produced_by", "consolidation"}
    ]
    context = %{available_actions: [:restart_consolidation, :cleanup_temps]}
    candidates = Distiller.extract_reflex_candidates(chains, context)
    assert is_list(candidates)
  end

  test "find_knowledge_gaps/2 finds concepts not in any silo" do
    text = "Kubernetes orchestrates containers using pods and services."
    silo_domains = ["self", "health"]
    gaps = Distiller.find_knowledge_gaps(text, silo_domains)
    assert is_list(gaps)
    assert length(gaps) > 0
  end

  test "distill/3 runs full distillation pipeline" do
    text = "The problem was caused by high memory usage. Memory requires monitoring."
    silo_domains = ["self"]
    context = %{available_actions: []}
    result = Distiller.distill(text, silo_domains, context)
    assert is_map(result)
    assert is_list(result.chains)
    assert is_list(result.reflex_candidates)
    assert is_list(result.knowledge_gaps)
  end
end
