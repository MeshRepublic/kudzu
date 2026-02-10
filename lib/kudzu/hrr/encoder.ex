defmodule Kudzu.HRR.Encoder do
  @moduledoc """
  Encodes traces into HRR vectors for compressed memory representation.

  Each trace is converted to a vector that captures:
  - Purpose (what kind of trace)
  - Content (reconstruction hint)
  - Origin (who created it)
  - Temporal context (when, relative to other traces)

  ## Encoding Strategy

  1. **Role vectors**: Fixed vectors for structural roles (PURPOSE, CONTENT, ORIGIN, etc.)
  2. **Filler vectors**: Generated from content via consistent hashing
  3. **Binding**: role ⊛ filler creates role-filler pairs
  4. **Bundling**: Combine all pairs into single trace vector

  ## Codebook

  The encoder maintains a codebook of known concepts/purposes for
  efficient encoding and decoding.
  """

  alias Kudzu.{HRR, Trace, Salience}

  @type codebook :: %{atom() => HRR.vector()}
  @type dim :: pos_integer()

  # Standard role vectors (seeded for consistency)
  @role_seeds %{
    purpose: "kudzu_role_purpose_v1",
    content: "kudzu_role_content_v1",
    origin: "kudzu_role_origin_v1",
    path: "kudzu_role_path_v1",
    salience: "kudzu_role_salience_v1",
    temporal: "kudzu_role_temporal_v1"
  }

  # Standard purpose vectors
  @purpose_seeds %{
    memory: "kudzu_purpose_memory_v1",
    learning: "kudzu_purpose_learning_v1",
    thought: "kudzu_purpose_thought_v1",
    observation: "kudzu_purpose_observation_v1",
    decision: "kudzu_purpose_decision_v1",
    stimulus: "kudzu_purpose_stimulus_v1",
    action_denied: "kudzu_purpose_action_denied_v1",
    constitution_change: "kudzu_purpose_constitution_change_v1"
  }

  @doc """
  Initialize an encoder with role and purpose codebooks.
  """
  @spec init(dim()) :: %{roles: codebook(), purposes: codebook(), dim: dim()}
  def init(dim \\ HRR.default_dim()) do
    roles = @role_seeds
    |> Enum.map(fn {name, seed} -> {name, HRR.seeded_vector(seed, dim)} end)
    |> Map.new()

    purposes = @purpose_seeds
    |> Enum.map(fn {name, seed} -> {name, HRR.seeded_vector(seed, dim)} end)
    |> Map.new()

    %{roles: roles, purposes: purposes, dim: dim}
  end

  @doc """
  Encode a trace into an HRR vector.
  """
  @spec encode(Trace.t(), map()) :: HRR.vector()
  def encode(%Trace{} = trace, codebook) do
    dim = codebook.dim

    # Encode purpose
    purpose_vec = encode_purpose(trace.purpose, codebook)
    purpose_bound = HRR.bind(codebook.roles.purpose, purpose_vec)

    # Encode content from reconstruction_hint
    content_vec = encode_content(trace.reconstruction_hint, dim)
    content_bound = HRR.bind(codebook.roles.content, content_vec)

    # Encode origin
    origin_vec = HRR.seeded_vector("origin_#{trace.origin}", dim)
    origin_bound = HRR.bind(codebook.roles.origin, origin_vec)

    # Encode path (simplified: just encode path length and last hop)
    path_vec = encode_path(trace.path, dim)
    path_bound = HRR.bind(codebook.roles.path, path_vec)

    # Bundle all components
    HRR.bundle([purpose_bound, content_bound, origin_bound, path_bound])
  end

  @doc """
  Encode a trace with its salience information.
  """
  @spec encode_with_salience(Trace.t(), Salience.t(), map()) :: HRR.vector()
  def encode_with_salience(%Trace{} = trace, %Salience{} = salience, codebook) do
    dim = codebook.dim

    # Get base trace encoding
    base_vec = encode(trace, codebook)

    # Encode salience
    salience_vec = encode_salience(salience, dim)
    salience_bound = HRR.bind(codebook.roles.salience, salience_vec)

    # Bundle with salience
    HRR.bundle([base_vec, salience_bound])
  end

  @doc """
  Decode a purpose from an HRR vector.
  Returns the most likely purpose and confidence score.
  """
  @spec decode_purpose(HRR.vector(), map()) :: {atom(), float()} | nil
  def decode_purpose(vec, codebook) do
    # Unbind purpose role
    unbound = HRR.unbind(vec, codebook.roles.purpose)

    # Find closest purpose
    HRR.decode(unbound, codebook.purposes)
  end

  @doc """
  Probe a memory vector for similarity to a query trace.
  """
  @spec probe(HRR.vector(), Trace.t(), map()) :: float()
  def probe(memory_vec, %Trace{} = query_trace, codebook) do
    query_vec = encode(query_trace, codebook)
    HRR.similarity(memory_vec, query_vec)
  end

  @doc """
  Probe memory for a specific purpose.
  """
  @spec probe_purpose(HRR.vector(), atom(), map()) :: float()
  def probe_purpose(memory_vec, purpose, codebook) do
    purpose_vec = encode_purpose(purpose, codebook)
    purpose_bound = HRR.bind(codebook.roles.purpose, purpose_vec)
    HRR.probe(memory_vec, purpose_bound)
  end

  @doc """
  Create a composite memory vector from multiple traces.
  This is the core of memory consolidation.
  """
  @spec consolidate([Trace.t()], map()) :: HRR.vector()
  def consolidate([], codebook), do: HRR.zero_vector(codebook.dim)
  def consolidate(traces, codebook) do
    traces
    |> Enum.map(fn trace -> encode(trace, codebook) end)
    |> HRR.bundle()
  end

  @doc """
  Create a weighted composite memory vector.
  Traces with higher salience contribute more.
  """
  @spec consolidate_weighted([{Trace.t(), Salience.t()}], map()) :: HRR.vector()
  def consolidate_weighted([], codebook), do: HRR.zero_vector(codebook.dim)
  def consolidate_weighted(trace_salience_pairs, codebook) do
    # Encode and scale by salience score
    weighted_vecs = Enum.map(trace_salience_pairs, fn {trace, salience} ->
      vec = encode(trace, codebook)
      score = Salience.score(salience)
      HRR.scale(vec, score)
    end)

    # Sum and normalize
    dim = codebook.dim
    summed = Enum.reduce(weighted_vecs, HRR.zero_vector(dim), &HRR.add/2)
    HRR.normalize(summed)
  end

  @doc """
  Add a purpose to the codebook (for custom purposes).
  """
  @spec add_purpose(map(), atom()) :: map()
  def add_purpose(codebook, purpose) when is_atom(purpose) do
    if Map.has_key?(codebook.purposes, purpose) do
      codebook
    else
      seed = "kudzu_purpose_#{purpose}_v1"
      vec = HRR.seeded_vector(seed, codebook.dim)
      %{codebook | purposes: Map.put(codebook.purposes, purpose, vec)}
    end
  end

  # Private encoding functions

  defp encode_purpose(purpose, codebook) when is_atom(purpose) do
    case Map.get(codebook.purposes, purpose) do
      nil ->
        # Unknown purpose - generate from name
        HRR.seeded_vector("purpose_#{purpose}", codebook.dim)
      vec ->
        vec
    end
  end

  defp encode_purpose(purpose, codebook) when is_binary(purpose) do
    atom_purpose = try do
      String.to_existing_atom(purpose)
    rescue
      _ -> nil
    end

    if atom_purpose do
      encode_purpose(atom_purpose, codebook)
    else
      HRR.seeded_vector("purpose_#{purpose}", codebook.dim)
    end
  end

  defp encode_content(hint, dim) when is_map(hint) do
    # Encode content by hashing the hint
    content_str = inspect(hint)
    HRR.seeded_vector(content_str, dim)
  end

  defp encode_content(nil, dim), do: HRR.zero_vector(dim)

  defp encode_path([], dim), do: HRR.zero_vector(dim)
  defp encode_path(path, dim) when is_list(path) do
    # Encode path: bundle of origin + length encoding
    origin = List.first(path)
    last = List.last(path)
    length = length(path)

    origin_vec = HRR.seeded_vector("path_origin_#{origin}", dim)
    last_vec = HRR.seeded_vector("path_last_#{last}", dim)
    length_vec = HRR.seeded_vector("path_length_#{length}", dim)

    HRR.bundle([origin_vec, last_vec, length_vec])
  end

  defp encode_salience(%Salience{} = salience, dim) do
    # Encode salience as a vector based on its score and importance
    score = Salience.score(salience)
    importance = salience.importance

    # Create a seeded vector based on importance and scale by score
    base = HRR.seeded_vector("salience_#{importance}", dim)
    HRR.scale(base, score)
    |> HRR.normalize()
  end
end
