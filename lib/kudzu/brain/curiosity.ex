defmodule Kudzu.Brain.Curiosity do
  @moduledoc """
  Generates questions when no one is asking.

  Three sources:
  1. Desire-driven — desires imply knowledge gaps
  2. Gap-driven — working memory dead ends become questions
  3. Salience-driven — unexplored high-salience traces
  """

  alias Kudzu.Brain.WorkingMemory

  @max_questions 5

  @desire_themes %{
    "health" => [
      "What is the current system health status?",
      "What failures have occurred recently?",
      "What recovery actions are available?"
    ],
    "self-model" => [
      "What components make up my architecture?",
      "What are my resource limits?",
      "What capabilities do I have?"
    ],
    "learn" => [
      "What patterns have I observed recently?",
      "What recurring events should I understand better?",
      "What knowledge domains am I weakest in?"
    ],
    "fault tolerance" => [
      "How can I recover from failures automatically?",
      "What single points of failure exist?",
      "What redundancy do I have?"
    ],
    "knowledge gaps" => [
      "What concepts have I encountered but don't understand?",
      "What domains have no expertise silo yet?",
      "What questions have I failed to answer?"
    ]
  }

  def generate(desires, %WorkingMemory{} = wm, silo_domains) do
    desire_qs = generate_from_desires(desires, silo_domains)
    gap_qs = generate_from_gaps(wm)
    salience_qs = generate_from_salience(@max_questions)

    (gap_qs ++ desire_qs ++ salience_qs)
    |> Enum.uniq()
    |> Enum.take(@max_questions)
  end

  def generate_from_desires(desires, silo_domains) do
    desires
    |> Enum.flat_map(fn desire ->
      theme = classify_desire(desire)
      templates = Map.get(@desire_themes, theme, [])

      if has_silo_coverage?(theme, silo_domains) do
        templates |> Enum.drop(1) |> Enum.take(1)
      else
        Enum.take(templates, 1)
      end
    end)
    |> Enum.uniq()
  end

  def generate_from_gaps(%WorkingMemory{recent_chains: chains}) do
    chains
    |> Enum.flat_map(fn chain ->
      chain
      |> Enum.filter(fn
        %{similarity: score} when score < 0.2 -> true
        %{source: "dead_end"} -> true
        _ -> false
      end)
      |> Enum.map(fn
        %{concept: concept} -> "What is #{concept}?"
        _ -> nil
      end)
      |> Enum.reject(&is_nil/1)
    end)
    |> Enum.uniq()
  end

  def generate_from_salience(limit) do
    try do
      state = Kudzu.Consolidation.stats()
      if state[:traces_processed] && state[:traces_processed] > 0 do
        Kudzu.Consolidation.semantic_query("important unresolved", 0.3)
        |> Enum.take(limit)
        |> Enum.map(fn {purpose, _score} -> "What does #{purpose} tell me?" end)
      else
        []
      end
    rescue
      _ -> []
    catch
      :exit, _ -> []
    end
  end

  defp classify_desire(desire) do
    desire_lower = String.downcase(desire)
    cond do
      String.contains?(desire_lower, "health") or String.contains?(desire_lower, "recover") -> "health"
      String.contains?(desire_lower, "self-model") or String.contains?(desire_lower, "architecture") -> "self-model"
      String.contains?(desire_lower, "learn") or String.contains?(desire_lower, "pattern") -> "learn"
      String.contains?(desire_lower, "fault") or String.contains?(desire_lower, "distributed") -> "fault tolerance"
      true -> "knowledge gaps"
    end
  end

  defp has_silo_coverage?(theme, silo_domains) do
    domain_set = MapSet.new(silo_domains |> Enum.map(&String.downcase/1))
    case theme do
      "health" -> MapSet.member?(domain_set, "health")
      "self-model" -> MapSet.member?(domain_set, "self")
      "learn" -> MapSet.member?(domain_set, "learning") or MapSet.member?(domain_set, "patterns")
      "fault tolerance" -> MapSet.member?(domain_set, "fault_tolerance")
      _ -> false
    end
  end
end
