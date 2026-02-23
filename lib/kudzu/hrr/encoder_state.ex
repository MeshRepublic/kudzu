defmodule Kudzu.HRR.EncoderState do
  @moduledoc """
  Manages the evolving state of the HRR encoder.

  Holds the co-occurrence matrix that allows token vectors to be
  influenced by their learned relationships. The state starts empty
  (pure token-seeded encoding) and improves as traces are processed.

  Persisted to DETS across restarts. If missing, starts fresh.
  """

  alias Kudzu.HRR

  @type t :: %__MODULE__{
    co_occurrence: %{String.t() => %{String.t() => float()}},
    token_counts: %{String.t() => non_neg_integer()},
    blend_strength: float(),
    dim: pos_integer(),
    traces_processed: non_neg_integer()
  }

  defstruct [
    co_occurrence: %{},
    token_counts: %{},
    blend_strength: 0.3,
    dim: 512,
    traces_processed: 0
  ]

  @dets_file ~c"/home/eel/kudzu_data/dets/encoder_state.dets"
  @top_k_neighbors 5
  @decay_factor 0.98
  @prune_threshold 1.0

  # --- Construction ---

  @doc """
  Create a new empty encoder state.
  """
  @spec new(pos_integer()) :: t()
  def new(dim \\ HRR.default_dim()) do
    %__MODULE__{dim: dim}
  end

  # --- Co-occurrence Updates ---

  @doc """
  Update co-occurrence matrix with tokens from a single trace.
  Every pair of tokens within the trace increments their co-occurrence count.
  Only uses unigrams (not bigrams) for co-occurrence tracking.
  """
  @spec update_co_occurrence(t(), [String.t()]) :: t()
  def update_co_occurrence(%__MODULE__{} = state, tokens) when is_list(tokens) do
    # Update token counts
    new_counts = Enum.reduce(tokens, state.token_counts, fn token, acc ->
      Map.update(acc, token, 1, &(&1 + 1))
    end)

    # Update co-occurrence for all pairs
    new_cooc = update_pairs(state.co_occurrence, tokens)

    %{state |
      co_occurrence: new_cooc,
      token_counts: new_counts,
      traces_processed: state.traces_processed + 1
    }
  end

  @doc """
  Batch update co-occurrence from multiple traces' token lists.
  """
  @spec update_co_occurrence_batch(t(), [[String.t()]]) :: t()
  def update_co_occurrence_batch(%__MODULE__{} = state, token_lists) do
    Enum.reduce(token_lists, state, &update_co_occurrence(&2, &1))
  end

  # --- Co-occurrence Queries ---

  @doc """
  Get top-K co-occurrence neighbors for a token.
  Returns [{neighbor_token, weight}] sorted by weight descending.
  """
  @spec top_neighbors(t(), String.t(), keyword()) :: [{String.t(), float()}]
  def top_neighbors(%__MODULE__{} = state, token, opts \\ []) do
    k = Keyword.get(opts, :k, @top_k_neighbors)

    case Map.get(state.co_occurrence, token) do
      nil -> []
      neighbors ->
        neighbors
        |> Enum.sort_by(fn {_t, w} -> w end, :desc)
        |> Enum.take(k)
    end
  end

  # --- Contextual Vector Generation ---

  @doc """
  Generate a contextual vector for a token, blending in co-occurrence neighbors.
  When no co-occurrence data exists, returns the pure seeded base vector.
  """
  @spec contextual_vector(t(), String.t()) :: HRR.vector()
  def contextual_vector(%__MODULE__{} = state, token) do
    base = base_vector(token, state.dim)
    neighbors = top_neighbors(state, token)

    if neighbors == [] do
      base
    else
      total_weight = Enum.reduce(neighbors, 0.0, fn {_t, w}, acc -> acc + w end)

      neighbor_blend =
        neighbors
        |> Enum.map(fn {neighbor_token, weight} ->
          nvec = base_vector(neighbor_token, state.dim)
          HRR.scale(nvec, weight / total_weight)
        end)
        |> Enum.reduce(HRR.zero_vector(state.dim), &HRR.add/2)

      blended = HRR.add(base, HRR.scale(neighbor_blend, state.blend_strength))
      HRR.normalize(blended)
    end
  end

  @doc """
  Get the deterministic base vector for a token (no co-occurrence blending).
  """
  @spec base_vector(String.t(), pos_integer()) :: HRR.vector()
  def base_vector(token, dim) do
    HRR.seeded_vector("token_v2_#{token}", dim)
  end

  # --- Maintenance (Deep Consolidation) ---

  @doc """
  Apply decay to all co-occurrence weights.
  Prevents stale associations from dominating.
  """
  @spec decay(t()) :: t()
  def decay(%__MODULE__{} = state) do
    new_cooc =
      state.co_occurrence
      |> Enum.map(fn {token, neighbors} ->
        decayed = neighbors
          |> Enum.map(fn {n, w} -> {n, w * @decay_factor} end)
          |> Map.new()
        {token, decayed}
      end)
      |> Map.new()

    %{state | co_occurrence: new_cooc}
  end

  @doc """
  Prune co-occurrence entries below threshold.
  Keeps the matrix sparse and memory-efficient.
  """
  @spec prune(t()) :: t()
  def prune(%__MODULE__{} = state) do
    new_cooc =
      state.co_occurrence
      |> Enum.map(fn {token, neighbors} ->
        pruned = neighbors
          |> Enum.reject(fn {_n, w} -> w < @prune_threshold end)
          |> Map.new()
        {token, pruned}
      end)
      |> Enum.reject(fn {_token, neighbors} -> neighbors == %{} end)
      |> Map.new()

    %{state | co_occurrence: new_cooc}
  end

  @doc """
  Run full maintenance: decay then prune.
  Called during deep consolidation cycles.
  """
  @spec maintain(t()) :: t()
  def maintain(%__MODULE__{} = state) do
    state |> decay() |> prune()
  end

  # --- Statistics ---

  @doc """
  Get statistics about the encoder state.
  """
  @spec stats(t()) :: map()
  def stats(%__MODULE__{} = state) do
    vocab_size = map_size(state.token_counts)
    cooc_entries = state.co_occurrence
      |> Enum.map(fn {_t, n} -> map_size(n) end)
      |> Enum.sum()

    %{
      vocabulary_size: vocab_size,
      co_occurrence_entries: cooc_entries,
      traces_processed: state.traces_processed,
      blend_strength: state.blend_strength,
      top_tokens: state.token_counts
        |> Enum.sort_by(fn {_t, c} -> c end, :desc)
        |> Enum.take(20)
    }
  end

  # --- Persistence ---

  @doc """
  Save encoder state to DETS.
  """
  @spec save(t()) :: :ok | {:error, term()}
  def save(%__MODULE__{} = state) do
    case :dets.open_file(:encoder_state, file: @dets_file, type: :set) do
      {:ok, table} ->
        :dets.insert(table, {:encoder_state, state})
        :dets.close(table)
        :ok
      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Load encoder state from DETS. Returns new state if not found.
  """
  @spec load(pos_integer()) :: t()
  def load(dim \\ HRR.default_dim()) do
    case :dets.open_file(:encoder_state, file: @dets_file, type: :set) do
      {:ok, table} ->
        result = case :dets.lookup(table, :encoder_state) do
          [{:encoder_state, %__MODULE__{} = state}] -> state
          _ -> new(dim)
        end
        :dets.close(table)
        result
      {:error, _} ->
        new(dim)
    end
  end

  # --- Private ---

  defp update_pairs(cooc, tokens) do
    # For each unique pair of tokens, increment both directions
    pairs = for a <- tokens, b <- tokens, a != b, do: {a, b}

    Enum.reduce(pairs, cooc, fn {a, b}, acc ->
      update_in_map(acc, a, b)
    end)
  end

  defp update_in_map(cooc, a, b) do
    neighbors = Map.get(cooc, a, %{})
    new_weight = Map.get(neighbors, b, 0.0) + 1.0
    Map.put(cooc, a, Map.put(neighbors, b, new_weight))
  end
end
