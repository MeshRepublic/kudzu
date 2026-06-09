defmodule Kudzu.Silo do
  @moduledoc """
  Expertise Silos — domain-specific knowledge stores backed by holograms.

  Each silo is a hologram with purpose "expertise:<domain>". Relationships
  (subject-relation-object triples) are encoded as HRR vectors and stored
  as traces with reconstruction hints for later retrieval.
  """

  require Logger

  alias Kudzu.HRR
  alias Kudzu.Silo.Relationship

  @purpose_prefix "expertise:"

  @doc """
  Create or find an expertise silo for the given domain.
  Returns {:ok, pid} of the backing hologram.
  """
  @spec create(String.t()) :: {:ok, pid()} | {:error, term()}
  def create(domain) do
    purpose = "#{@purpose_prefix}#{domain}"

    case Kudzu.Application.find_by_purpose(purpose) do
      [{pid, _id} | _] ->
        Logger.debug("[Silo] Found existing silo for #{domain}")
        {:ok, pid}

      [] ->
        Logger.info("[Silo] Creating new silo for #{domain}")

        Kudzu.Application.spawn_hologram(
          purpose: purpose,
          constitution: :kudzu_evolve,
          cognition: false
        )
    end
  end

  @doc """
  Delete an expertise silo for the given domain.
  """
  @spec delete(String.t()) :: :ok | {:error, :not_found}
  def delete(domain) do
    case find(domain) do
      {:ok, pid} ->
        Kudzu.Application.stop_hologram(pid)

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @doc """
  List all expertise silos. Returns list of {domain, pid, hologram_id}.
  """
  @spec list() :: [{String.t(), pid(), String.t()}]
  def list do
    Kudzu.Application.list_holograms()
    |> Enum.reduce([], fn pid, acc ->
      try do
        state = :sys.get_state(pid)
        purpose = to_string(state.purpose)

        if String.starts_with?(purpose, @purpose_prefix) do
          domain = String.replace_prefix(purpose, @purpose_prefix, "")
          [{domain, pid, state.id} | acc]
        else
          acc
        end
      rescue
        _ -> acc
      end
    end)
  end

  @doc """
  Find a specific silo by domain. Returns {:ok, pid} or {:error, :not_found}.
  """
  @spec find(String.t()) :: {:ok, pid()} | {:error, :not_found}
  def find(domain) do
    purpose = "#{@purpose_prefix}#{domain}"

    case Kudzu.Application.find_by_purpose(purpose) do
      [{pid, _id} | _] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Store a relationship triple in an expertise silo.

  The triple {subject, relation, object} is HRR-encoded as
  `bind(S, bind(R, O))` and the resulting vector is persisted alongside
  the structured hint under the `:vector` key. Pre-D.5 writes bound the
  vector to `_vector` and discarded it — `probe/2` now reads the stored
  vector and uses it as a secondary similarity signal so the semantic
  encoding finally informs retrieval.
  """
  @spec store_relationship(String.t(), {String.t(), String.t(), String.t()}) ::
          {:ok, term()} | {:error, term()}
  def store_relationship(domain, {subject, relation, object} = triple) do
    case find(domain) do
      {:ok, pid} ->
        vector = Relationship.encode(triple)

        Kudzu.Hologram.record_trace(pid, :discovery, %{
          type: "relationship",
          subject: to_string(subject),
          relation: to_string(relation),
          object: to_string(object),
          vector: vector
        })

      {:error, :not_found} ->
        {:error, {:silo_not_found, domain}}
    end
  end

  @doc """
  Probe a silo for relationships matching a concept.

  Scoring combines two HRR signals:

  1. Subject-concept similarity — `cosine_sim(concept_vector(query),
     concept_vector(subject))`. This is the primary signal and matches
     pre-D.5 behavior: probing for an exact stored subject yields ~1.0.
  2. Bound-triple similarity — when the trace has a persisted `:vector`
     (post-D.5), `cosine_sim(concept_vector(query), stored_vector)` is
     also computed. The final score is the max of the two — the stored
     vector can only *raise* a triple's rank, never lower it, which
     preserves subject-match priority while letting the bound encoding
     surface subtler associations the subject string alone misses.

  Returns `[{hint_map, similarity_float}, ...]` sorted by similarity
  descending.
  """
  @spec probe(String.t(), String.t()) :: [{map(), float()}]
  def probe(domain, query) do
    case find(domain) do
      {:ok, pid} ->
        state = :sys.get_state(pid)
        query_vec = Relationship.concept_vector(query)

        state.traces
        |> Map.values()
        |> Enum.filter(fn trace ->
          hint = trace.reconstruction_hint
          is_map(hint) and Map.get(hint, :type, Map.get(hint, "type")) == "relationship"
        end)
        |> Enum.map(fn trace ->
          hint = trace.reconstruction_hint
          {hint, score_hint(hint, query_vec)}
        end)
        |> Enum.sort_by(fn {_hint, sim} -> sim end, :desc)

      {:error, :not_found} ->
        []
    end
  end

  # Combine subject-concept similarity (primary, preserves test contract)
  # with bound-triple-vector similarity (secondary, from the post-D.5
  # persisted vector). The max means the stored vector can promote a
  # triple but never demote one.
  defp score_hint(hint, query_vec) do
    subject = Map.get(hint, :subject, Map.get(hint, "subject", ""))
    subject_vec = Relationship.concept_vector(to_string(subject))
    subject_sim = safe_similarity(query_vec, subject_vec)

    case Map.get(hint, :vector, Map.get(hint, "vector")) do
      stored when is_list(stored) and stored != [] ->
        max(subject_sim, safe_similarity(query_vec, stored))

      _ ->
        subject_sim
    end
  end

  defp safe_similarity(a, b) when is_list(a) and is_list(b) and length(a) == length(b) do
    HRR.similarity(a, b)
  end

  defp safe_similarity(_, _), do: 0.0

  @doc """
  Semantic search within a silo using Ollama embeddings.

  More accurate than HRR-based probe/2. Embeds the query and compares
  against stored trace embeddings for this silo's hologram.
  """
  @spec semantic_probe(String.t(), String.t(), keyword()) :: [map()]
  def semantic_probe(domain, query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    threshold = Keyword.get(opts, :threshold, 0.1)

    with {:ok, pid} <- find(domain),
         {:ok, query_vector} <- Kudzu.Embedding.embed(query) do
      state = :sys.get_state(pid)

      state.traces
      |> Map.values()
      |> Enum.map(fn trace ->
        case :ets.lookup(:kudzu_embeddings, trace.id) do
          [{_, vector}] ->
            sim = Kudzu.Embedding.cosine_similarity(query_vector, vector)

            if sim >= threshold do
              %{
                trace_id: trace.id,
                similarity: sim,
                data: trace.reconstruction_hint,
                purpose: trace.purpose
              }
            end

          [] ->
            nil
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.sort_by(& &1.similarity, :desc)
      |> Enum.take(limit)
    else
      {:error, :not_found} ->
        []

      {:error, _reason} ->
        # Embedding unavailable, fall back to HRR probe
        probe(domain, query)
        |> Enum.take(limit)
        |> Enum.map(fn {hint, sim} ->
          %{trace_id: nil, similarity: sim, data: hint, purpose: :discovery}
        end)
    end
  end
end
