defmodule Kudzu.Brain.WorkingMemory do
  @moduledoc """
  The Monarch's bounded attention buffer.

  Holds currently active concepts, recent reasoning chains, and pending questions.
  Lives inside the Brain GenServer state — not a separate process.
  Concepts decay over time and get evicted when they fall below threshold
  or when capacity is exceeded. Evicted concepts become traces.
  """

  defstruct [
    active_concepts: %{},
    recent_chains: [],
    pending_questions: [],
    context: nil,
    max_concepts: 20,
    max_chains: 10,
    max_questions: 5,
    eviction_threshold: 0.1
  ]

  def new(opts \\ []) do
    %__MODULE__{
      max_concepts: Keyword.get(opts, :max_concepts, 20),
      max_chains: Keyword.get(opts, :max_chains, 10),
      max_questions: Keyword.get(opts, :max_questions, 5),
      eviction_threshold: Keyword.get(opts, :eviction_threshold, 0.1)
    }
  end

  def activate(%__MODULE__{} = wm, concept, %{score: score, source: source}) do
    entry = %{
      score: score,
      source: source,
      timestamp: System.monotonic_time(:millisecond)
    }

    updated = case Map.get(wm.active_concepts, concept) do
      nil -> Map.put(wm.active_concepts, concept, entry)
      existing -> Map.put(wm.active_concepts, concept, %{entry | score: max(existing.score, score)})
    end

    %{wm | active_concepts: updated} |> enforce_concept_limit()
  end

  def decay(%__MODULE__{} = wm, amount) do
    updated = wm.active_concepts
    |> Enum.map(fn {concept, entry} -> {concept, %{entry | score: Float.round(entry.score - amount, 10)}} end)
    |> Enum.filter(fn {_concept, entry} -> entry.score >= wm.eviction_threshold end)
    |> Map.new()
    %{wm | active_concepts: updated}
  end

  def add_chain(%__MODULE__{} = wm, chain) do
    chains = [chain | wm.recent_chains] |> Enum.take(wm.max_chains)
    %{wm | recent_chains: chains}
  end

  def add_question(%__MODULE__{} = wm, question) do
    questions = (wm.pending_questions ++ [question]) |> Enum.take(wm.max_questions)
    %{wm | pending_questions: questions}
  end

  def pop_question(%__MODULE__{pending_questions: []} = wm), do: {nil, wm}
  def pop_question(%__MODULE__{pending_questions: [q | rest]} = wm), do: {q, %{wm | pending_questions: rest}}

  def get_priming_concepts(%__MODULE__{} = wm, n \\ 5) do
    wm.active_concepts
    |> Enum.sort_by(fn {_concept, entry} -> entry.score end, :desc)
    |> Enum.take(n)
    |> Enum.map(fn {concept, _entry} -> concept end)
  end

  defp enforce_concept_limit(%__MODULE__{} = wm) do
    if map_size(wm.active_concepts) > wm.max_concepts do
      {lowest_concept, _entry} = wm.active_concepts |> Enum.min_by(fn {_c, e} -> e.score end)
      %{wm | active_concepts: Map.delete(wm.active_concepts, lowest_concept)}
    else
      wm
    end
  end
end
