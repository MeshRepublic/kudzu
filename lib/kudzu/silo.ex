defmodule Kudzu.Silo do
  @moduledoc """
  Expertise Silos — domain-specific knowledge stores backed by holograms.

  Each silo is a hologram with purpose "expertise:<domain>". Relationships
  (subject-relation-object triples) are encoded as HRR vectors and stored
  as traces with reconstruction hints for later retrieval.
  """

  require Logger

  alias Kudzu.Silo.Relationship
  alias Kudzu.HRR

  @purpose_prefix "expertise:"

  @doc """
  Create or find an expertise silo for the given domain.
  Returns {:ok, pid} of the backing hologram.
  """
  @spec create(String.t()) :: {:ok, pid()}
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

  The triple {subject, relation, object} is HRR-encoded and stored as a
  trace with purpose :discovery and reconstruction hints for retrieval.
  """
  @spec store_relationship(String.t(), {String.t(), String.t(), String.t()}) ::
          {:ok, term()} | {:error, term()}
  def store_relationship(domain, {subject, relation, object} = triple) do
    case find(domain) do
      {:ok, pid} ->
        _vector = Relationship.encode(triple)

        Kudzu.Hologram.record_trace(pid, :discovery, %{
          type: "relationship",
          subject: to_string(subject),
          relation: to_string(relation),
          object: to_string(object)
        })

      {:error, :not_found} ->
        {:error, {:silo_not_found, domain}}
    end
  end

  @doc """
  Probe a silo for relationships matching a concept.

  Compares the query concept vector against each stored relationship's
  subject concept vector. Returns results sorted by similarity, descending.
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
          subject = Map.get(hint, :subject, Map.get(hint, "subject", ""))
          subject_vec = Relationship.concept_vector(subject)
          sim = HRR.similarity(query_vec, subject_vec)
          {hint, sim}
        end)
        |> Enum.sort_by(fn {_hint, sim} -> sim end, :desc)

      {:error, :not_found} ->
        []
    end
  end
end
