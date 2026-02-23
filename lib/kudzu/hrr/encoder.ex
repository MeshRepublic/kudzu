defmodule Kudzu.HRR.Encoder do
  @moduledoc """
  Encodes traces into HRR vectors for compressed memory representation.

  ## Encoding Strategy (V2: Token-Seeded Bundling)

  1. **Tokenize**: Extract text from hint, tokenize with stemming, generate bigrams
  2. **Vectorize**: Each token gets a contextual vector (base + co-occurrence blend)
  3. **Bind**: Token vectors are bound with field-role vectors (content, project, event)
  4. **Bundle**: All bound vectors combine into the final content vector
  5. **Compose**: Content vector is bundled with purpose, origin, and path vectors

  The encoding improves over time as the co-occurrence matrix learns which
  tokens appear together. Day one uses pure token-seeded vectors; day 100
  blends in learned associations.
  """

  alias Kudzu.{HRR, Trace, Salience}
  alias Kudzu.HRR.{EncoderState, Tokenizer}

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

  # Field-specific role vectors for multi-field encoding
  @field_role_seeds %{
    content: "kudzu_field_content_v2",
    summary: "kudzu_field_summary_v2",
    key_events: "kudzu_field_key_events_v2",
    event: "kudzu_field_event_v2",
    description: "kudzu_field_description_v2"
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
    constitution_change: "kudzu_purpose_constitution_change_v1",
    session_context: "kudzu_purpose_session_context_v1",
    research: "kudzu_purpose_research_v1",
    discovery: "kudzu_purpose_discovery_v1"
  }

  @doc """
  Initialize an encoder with role and purpose codebooks.
  """
  @spec init(dim()) :: %{roles: codebook(), purposes: codebook(), field_roles: codebook(), dim: dim()}
  def init(dim \\ HRR.default_dim()) do
    roles = @role_seeds
    |> Enum.map(fn {name, seed} -> {name, HRR.seeded_vector(seed, dim)} end)
    |> Map.new()

    purposes = @purpose_seeds
    |> Enum.map(fn {name, seed} -> {name, HRR.seeded_vector(seed, dim)} end)
    |> Map.new()

    field_roles = @field_role_seeds
    |> Enum.map(fn {name, seed} -> {name, HRR.seeded_vector(seed, dim)} end)
    |> Map.new()

    %{roles: roles, purposes: purposes, field_roles: field_roles, dim: dim}
  end

  @doc """
  Encode a trace into an HRR vector.
  Uses token-seeded bundling with co-occurrence blending for content.
  """
  @spec encode(Trace.t(), map(), EncoderState.t() | nil) :: HRR.vector()
  def encode(%Trace{} = trace, codebook, encoder_state \\ nil) do
    dim = codebook.dim

    # Encode purpose
    purpose_vec = encode_purpose(trace.purpose, codebook)
    purpose_bound = HRR.bind(codebook.roles.purpose, purpose_vec)

    # Encode content using token-seeded bundling (V2)
    content_vec = encode_content_v2(trace.reconstruction_hint, codebook, encoder_state)
    content_bound = HRR.bind(codebook.roles.content, content_vec)

    # Encode origin
    origin_vec = HRR.seeded_vector("origin_#{trace.origin}", dim)
    origin_bound = HRR.bind(codebook.roles.origin, origin_vec)

    # Encode path
    path_vec = encode_path(trace.path, dim)
    path_bound = HRR.bind(codebook.roles.path, path_vec)

    # Bundle all components
    HRR.bundle([purpose_bound, content_bound, origin_bound, path_bound])
  end

  @doc """
  Encode a trace with its salience information.
  """
  @spec encode_with_salience(Trace.t(), Salience.t(), map(), EncoderState.t() | nil) :: HRR.vector()
  def encode_with_salience(%Trace{} = trace, %Salience{} = salience, codebook, encoder_state \\ nil) do
    dim = codebook.dim

    base_vec = encode(trace, codebook, encoder_state)

    salience_vec = encode_salience(salience, dim)
    salience_bound = HRR.bind(codebook.roles.salience, salience_vec)

    HRR.bundle([base_vec, salience_bound])
  end

  @doc """
  Decode a purpose from an HRR vector.
  """
  @spec decode_purpose(HRR.vector(), map()) :: {atom(), float()} | nil
  def decode_purpose(vec, codebook) do
    unbound = HRR.unbind(vec, codebook.roles.purpose)
    HRR.decode(unbound, codebook.purposes)
  end

  @doc """
  Probe a memory vector for similarity to a query trace.
  """
  @spec probe(HRR.vector(), Trace.t(), map(), EncoderState.t() | nil) :: float()
  def probe(memory_vec, %Trace{} = query_trace, codebook, encoder_state \\ nil) do
    query_vec = encode(query_trace, codebook, encoder_state)
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
  Encode a natural language query into an HRR vector for retrieval.
  Uses the same tokenization and co-occurrence blending as trace encoding,
  but without structural roles — just raw content similarity.
  """
  @spec encode_query(String.t(), map(), EncoderState.t() | nil) :: HRR.vector()
  def encode_query(query_text, codebook, encoder_state \\ nil) do
    dim = codebook.dim
    tokens = Tokenizer.tokenize(query_text)

    if tokens == [] do
      HRR.zero_vector(dim)
    else
      token_vecs = Enum.map(tokens, fn token ->
        if encoder_state do
          EncoderState.contextual_vector(encoder_state, token)
        else
          EncoderState.base_vector(token, dim)
        end
      end)

      content_vec = HRR.bundle(token_vecs)
      # Bind with content role so it matches trace content fields
      HRR.bind(codebook.roles.content, content_vec)
    end
  end

  @doc """
  Create a composite memory vector from multiple traces.
  """
  @spec consolidate([Trace.t()], map(), EncoderState.t() | nil) :: HRR.vector()
  def consolidate(traces, codebook, encoder_state \\ nil)
  def consolidate([], codebook, _encoder_state), do: HRR.zero_vector(codebook.dim)
  def consolidate(traces, codebook, encoder_state) do
    traces
    |> Enum.map(fn trace -> encode(trace, codebook, encoder_state) end)
    |> HRR.bundle()
  end

  @doc """
  Create a weighted composite memory vector.
  """
  @spec consolidate_weighted([{Trace.t(), Salience.t()}], map(), EncoderState.t() | nil) :: HRR.vector()
  def consolidate_weighted(trace_salience_pairs, codebook, encoder_state \\ nil)
  def consolidate_weighted([], codebook, _encoder_state), do: HRR.zero_vector(codebook.dim)
  def consolidate_weighted(trace_salience_pairs, codebook, encoder_state) do
    weighted_vecs = Enum.map(trace_salience_pairs, fn {trace, salience} ->
      vec = encode(trace, codebook, encoder_state)
      score = Salience.score(salience)
      HRR.scale(vec, score)
    end)

    dim = codebook.dim
    summed = Enum.reduce(weighted_vecs, HRR.zero_vector(dim), &HRR.add/2)
    HRR.normalize(summed)
  end

  @doc """
  Add a purpose to the codebook.
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

  # --- V2 Content Encoding ---

  defp encode_content_v2(hint, codebook, encoder_state) when is_map(hint) do
    dim = codebook.dim
    field_tokens = Tokenizer.tokenize_hint_by_field(hint)

    if field_tokens == [] do
      # Fallback: if no text fields found, hash the whole hint
      content_str = inspect(hint)
      HRR.seeded_vector(content_str, dim)
    else
      # For each field, vectorize its tokens and bind with field role
      field_vecs = Enum.map(field_tokens, fn {field, tokens} ->
        # Vectorize each token (with co-occurrence blending if available)
        token_vecs = Enum.map(tokens, fn token ->
          if encoder_state do
            EncoderState.contextual_vector(encoder_state, token)
          else
            EncoderState.base_vector(token, dim)
          end
        end)

        # Bundle all token vectors for this field
        field_content = HRR.bundle(token_vecs)

        # Bind with field role (if we have one, otherwise use generic content role)
        field_role = Map.get(codebook.field_roles, field,
                            Map.get(codebook.field_roles, :content, HRR.seeded_vector("kudzu_field_generic_v2", dim)))
        HRR.bind(field_role, field_content)
      end)

      # Bundle all field vectors
      HRR.bundle(field_vecs)
    end
  end

  defp encode_content_v2(nil, _codebook, _encoder_state) do
    HRR.zero_vector(512)
  end

  # --- Purpose Encoding ---

  defp encode_purpose(purpose, codebook) when is_atom(purpose) do
    case Map.get(codebook.purposes, purpose) do
      nil -> HRR.seeded_vector("purpose_#{purpose}", codebook.dim)
      vec -> vec
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

  # --- Path Encoding ---

  defp encode_path([], dim), do: HRR.zero_vector(dim)
  defp encode_path(path, dim) when is_list(path) do
    origin = List.first(path)
    last = List.last(path)
    length = length(path)

    origin_vec = HRR.seeded_vector("path_origin_#{origin}", dim)
    last_vec = HRR.seeded_vector("path_last_#{last}", dim)
    length_vec = HRR.seeded_vector("path_length_#{length}", dim)

    HRR.bundle([origin_vec, last_vec, length_vec])
  end

  # --- Salience Encoding ---

  defp encode_salience(%Salience{} = salience, dim) do
    score = Salience.score(salience)
    importance = salience.importance

    base = HRR.seeded_vector("salience_#{importance}", dim)
    HRR.scale(base, score) |> HRR.normalize()
  end
end
