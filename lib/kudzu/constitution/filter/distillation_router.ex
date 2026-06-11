defmodule Kudzu.Constitution.Filter.DistillationRouter do
  @moduledoc """
  Routes filtered triples to expertise / rejection / contested silos
  per the SovereigntyFilter judgment.

  Provenance fields (`source_doc`, `paragraph_offset`, plus judgment-
  specific `:sovereignty_score`, `:principle`, `:rejection_reason`) are
  attached to each trace via `Silo.store_relationship/3`.
  """

  alias Kudzu.Constitution.Filter.SovereigntyFilter
  alias Kudzu.Silo

  @type triple :: {String.t(), String.t(), String.t()}
  @type judgment :: SovereigntyFilter.judgment()
  @type provenance :: %{
          required(:source_doc) => String.t(),
          required(:paragraph_offset) => non_neg_integer(),
          optional(:section_label) => String.t()
        }
  @type silos :: %{
          expertise: String.t(),
          rejection: String.t(),
          contested: String.t()
        }

  @doc """
  Route a triple to the correct silo based on the SovereigntyFilter
  judgment. Provenance is merged into the trace's reconstruction_hint.
  """
  @spec route(triple(), judgment(), provenance(), silos()) :: {:ok, term()} | {:error, term()}
  def route(triple, {:advances, score, principle}, provenance, silos) do
    extra = %{
      origin_type: :distilled,
      sovereignty_score: score,
      principle: principle
    }

    Silo.store_relationship(silos.expertise, triple, Map.merge(provenance, extra))
  end

  def route(triple, {:retards, score, principle, reason}, provenance, silos) do
    extra = %{
      origin_type: :distilled,
      sovereignty_score: -score,
      principle: principle,
      rejection_reason: reason
    }

    Silo.store_relationship(silos.rejection, triple, Map.merge(provenance, extra))
  end

  def route(triple, {:contested, why}, provenance, silos) do
    extra = %{
      origin_type: :contested,
      contested_reason: inspect(why)
    }

    Silo.store_relationship(silos.contested, triple, Map.merge(provenance, extra))
  end
end
