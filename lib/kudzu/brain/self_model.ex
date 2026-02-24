defmodule Kudzu.Brain.SelfModel do
  @moduledoc """
  Self-model silo — Kudzu's knowledge about its own architecture.

  Seeds foundational architecture triples on init and provides an
  interface for the Brain to observe and query self-knowledge.
  """

  require Logger

  alias Kudzu.Silo

  @domain "self"

  @doc """
  Initialize the self-model silo with architecture knowledge.
  """
  @spec init() :: :ok
  def init do
    {:ok, _} = Silo.create(@domain)
    seed_architecture_knowledge()
    :ok
  rescue
    e ->
      Logger.warning("[SelfModel] Init failed: #{Exception.message(e)}")
      :ok
  end

  defp seed_architecture_knowledge do
    triples = [
      {"kudzu", "built_with", "elixir_otp"},
      {"kudzu", "runs_on", "titan"},
      {"storage", "has_tier", "hot_ets"},
      {"storage", "has_tier", "warm_dets"},
      {"storage", "has_tier", "cold_mnesia"},
      {"consolidation", "runs_every", "10_minutes"},
      {"deep_consolidation", "runs_every", "6_hours"},
      {"hrr_vectors", "have_dimension", "512"},
      {"encoder", "uses", "fft_circular_convolution"},
      {"encoder", "learns", "co_occurrence_matrix"},
      {"brain", "constitution", "kudzu_evolve"},
      {"brain", "reasons_with", "claude_api"},
      {"holograms", "store", "traces"},
      {"traces", "encoded_by", "hrr_encoder"},
      {"beamlets", "provide", "io_capabilities"}
    ]

    Enum.each(triples, fn triple ->
      try do
        Silo.store_relationship(@domain, triple)
      rescue
        _ -> :ok
      catch
        :exit, _ -> :ok
      end
    end)
  end

  @doc """
  Record a new observation about the system.
  """
  @spec observe(String.t(), String.t(), String.t()) :: {:ok, term()} | {:error, term()}
  def observe(subject, relation, object),
    do: Silo.store_relationship(@domain, {subject, relation, object})

  @doc """
  Query the self-model for relationships matching a concept.
  """
  @spec query(String.t()) :: [{map(), float()}]
  def query(concept), do: Silo.probe(@domain, concept)
end
