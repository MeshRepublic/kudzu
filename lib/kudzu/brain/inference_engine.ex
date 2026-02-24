defmodule Kudzu.Brain.InferenceEngine do
  @moduledoc """
  Tier 2 Cognition — HRR bind/unbind chain reasoning over expertise silos.

  The inference engine bridges the gap between free reflex pattern-matching
  (Tier 1) and expensive Claude API calls (Tier 3). It uses HRR vector
  operations to find relationships and concepts across expertise silos
  without requiring any LLM calls.

  ## Capabilities

  - **probe/2** — Find concepts related to a query in a specific silo
  - **query_relationship/3** — Find what a subject relates to via a relation
  - **cross_query/1** — Search ALL silos for a concept
  - **confidence/1** — Classify similarity scores into confidence levels
  """

  alias Kudzu.Silo
  alias Kudzu.Silo.Relationship
  alias Kudzu.HRR

  @doc """
  Probe a silo for concepts related to a query.

  Delegates to `Silo.probe/2` which compares the query concept vector
  against stored relationship subject vectors.
  """
  @spec probe(String.t(), String.t()) :: [{map(), float()}]
  def probe(domain, concept) do
    Silo.probe(domain, concept)
  end

  @doc """
  Find what a subject relates to via a given relation.

  Builds an HRR query vector from the subject and relation, then compares
  against all stored relationship vectors in the silo. Returns the top 5
  matches sorted by similarity descending.

  ## Example

      InferenceEngine.query_relationship("geology", "water", "causes")
      # => [{%{subject: "water", relation: "causes", object: "erosion"}, 0.85}, ...]

  """
  @spec query_relationship(String.t(), String.t(), String.t()) :: [{map(), float()}]
  def query_relationship(domain, subject, relation) do
    case Silo.find(domain) do
      {:ok, pid} ->
        state = :sys.get_state(pid)

        # Build query vectors for subject and relation independently.
        # Using partial match: compare subject and relation concept vectors
        # separately, then combine scores. This avoids the HRR placeholder
        # problem where bind(S, bind(R, ?)) introduces uncorrelated noise.
        query_subject = Relationship.concept_vector(subject)
        query_relation = Relationship.relation_vector(relation)

        state.traces
        |> Map.values()
        |> Enum.filter(fn trace ->
          hint = trace.reconstruction_hint
          is_map(hint) and
            Map.get(hint, :type, Map.get(hint, "type")) == "relationship"
        end)
        |> Enum.map(fn trace ->
          hint = trace.reconstruction_hint
          s = Map.get(hint, :subject, Map.get(hint, "subject", ""))
          r = Map.get(hint, :relation, Map.get(hint, "relation", ""))
          o = Map.get(hint, :object, Map.get(hint, "object", ""))

          # Score by subject similarity and relation similarity independently
          subject_sim = HRR.similarity(query_subject, Relationship.concept_vector(s))
          relation_sim = HRR.similarity(query_relation, Relationship.relation_vector(r))

          # Combined score: both must match for high confidence
          # Geometric mean rewards joint matches over partial ones
          sim = :math.sqrt(max(subject_sim, 0.0) * max(relation_sim, 0.0))

          {%{subject: s, relation: r, object: o}, sim}
        end)
        |> Enum.sort_by(fn {_match, sim} -> sim end, :desc)
        |> Enum.take(5)

      {:error, :not_found} ->
        []
    end
  end

  @doc """
  Search ALL expertise silos for a concept.

  Probes every registered silo and combines results with domain labels,
  sorted by similarity descending across all domains.

  ## Example

      InferenceEngine.cross_query("water")
      # => [{"geology", %{...}, 0.9}, {"chemistry", %{...}, 0.7}, ...]

  """
  @spec cross_query(String.t()) :: [{String.t(), map(), float()}]
  def cross_query(concept) do
    Silo.list()
    |> Enum.flat_map(fn {domain, _pid, _id} ->
      probe(domain, concept)
      |> Enum.map(fn {hint, score} -> {domain, hint, score} end)
    end)
    |> Enum.sort_by(fn {_domain, _hint, score} -> score end, :desc)
  end

  @doc """
  Classify a similarity score into a confidence level.

  - > 0.7 → :high
  - > 0.4 → :moderate
  - otherwise → :low
  """
  @spec confidence(float()) :: :high | :moderate | :low
  def confidence(score) when score > 0.7, do: :high
  def confidence(score) when score > 0.4, do: :moderate
  def confidence(_score), do: :low
end
