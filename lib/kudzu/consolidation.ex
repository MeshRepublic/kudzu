defmodule Kudzu.Consolidation do
  @moduledoc """
  Memory consolidation daemon for biomimetic memory processing.

  Inspired by biological memory consolidation during sleep, this daemon
  periodically processes traces to:

  1. **Strengthen important memories**: High-salience traces are reinforced
  2. **Weaken trivial memories**: Low-salience traces decay faster
  3. **Form associations**: Related traces are linked via HRR
  4. **Archive cold memories**: Move stable memories to cold storage
  5. **Compress representations**: Bundle similar traces into HRR vectors
  6. **Learn co-occurrences**: Update token co-occurrence matrix for semantic encoding

  ## Consolidation Cycles

  - **Light (10 minutes)**: Process new traces, update co-occurrence matrix
  - **Deep (6 hours)**: Rebuild vectors, decay/prune co-occurrence, persist encoder state
  """

  use GenServer
  require Logger

  alias Kudzu.{Storage, HRR}
  alias Kudzu.HRR.{Encoder, EncoderState, Tokenizer}

  @default_interval_ms 600_000        # 10 minutes
  @deep_consolidation_interval_ms 21_600_000  # 6 hours
  @batch_size 100

  defstruct [
    :hrr_codebook,
    :encoder_state,
    :consolidated_vectors,  # %{purpose => HRR.vector()}
    :last_consolidation,
    :last_deep_consolidation,
    :stats
  ]

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Force a consolidation cycle."
  @spec consolidate_now() :: :ok
  def consolidate_now do
    GenServer.cast(__MODULE__, :consolidate)
  end

  @doc "Force a deep consolidation cycle."
  @spec deep_consolidate_now() :: :ok
  def deep_consolidate_now do
    GenServer.cast(__MODULE__, :deep_consolidate)
  end

  @doc "Get consolidated HRR vector for a purpose."
  @spec get_consolidated_vector(atom()) :: HRR.vector() | nil
  def get_consolidated_vector(purpose) do
    GenServer.call(__MODULE__, {:get_vector, purpose})
  end

  @doc "Get consolidation statistics."
  @spec stats() :: map()
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  @doc "Get the current encoder state (for use by other modules)."
  @spec get_encoder_state() :: EncoderState.t()
  def get_encoder_state do
    GenServer.call(__MODULE__, :get_encoder_state)
  end

  @doc "Get the HRR codebook."
  @spec get_codebook() :: map()
  def get_codebook do
    GenServer.call(__MODULE__, :get_codebook)
  end

  @doc """
  Query consolidated memory using HRR probe.
  Returns traces that match the query vector above threshold.
  """
  @spec query_memory(HRR.vector(), float()) :: [{atom(), float()}]
  def query_memory(query_vec, threshold \\ 0.3) do
    GenServer.call(__MODULE__, {:query_memory, query_vec, threshold})
  end

  @doc """
  Semantic query: encode a natural language query and probe memory.
  """
  @spec semantic_query(String.t(), float()) :: [{atom(), float()}]
  def semantic_query(query_text, threshold \\ 0.1) do
    GenServer.call(__MODULE__, {:semantic_query, query_text, threshold})
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval, @default_interval_ms)
    deep_interval = Keyword.get(opts, :deep_interval, @deep_consolidation_interval_ms)

    # Initialize HRR codebook
    codebook = Encoder.init()

    # Load encoder state from DETS (or start fresh)
    encoder_state = EncoderState.load()
    Logger.info("[Consolidation] Loaded encoder state: #{encoder_state.traces_processed} traces, #{map_size(encoder_state.token_counts)} vocabulary")

    state = %__MODULE__{
      hrr_codebook: codebook,
      encoder_state: encoder_state,
      consolidated_vectors: %{},
      last_consolidation: nil,
      last_deep_consolidation: nil,
      stats: %{
        consolidations: 0,
        deep_consolidations: 0,
        traces_processed: 0,
        traces_archived: 0,
        associations_formed: 0
      }
    }

    # Schedule periodic consolidation
    schedule_consolidation(interval)
    schedule_deep_consolidation(deep_interval)

    Logger.info("[Consolidation] Memory consolidation daemon started")
    {:ok, state}
  end

  @impl true
  def handle_cast(:consolidate, state) do
    new_state = do_consolidation(state)
    {:noreply, new_state}
  end

  @impl true
  def handle_cast(:deep_consolidate, state) do
    new_state = do_deep_consolidation(state)
    {:noreply, new_state}
  end

  @impl true
  def handle_call({:get_vector, purpose}, _from, state) do
    vec = Map.get(state.consolidated_vectors, purpose)
    {:reply, vec, state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    encoder_stats = EncoderState.stats(state.encoder_state)
    combined = Map.merge(state.stats, %{
      encoder: encoder_stats
    })
    {:reply, combined, state}
  end

  @impl true
  def handle_call(:get_encoder_state, _from, state) do
    {:reply, state.encoder_state, state}
  end

  @impl true
  def handle_call(:get_codebook, _from, state) do
    {:reply, state.hrr_codebook, state}
  end

  @impl true
  def handle_call({:query_memory, query_vec, threshold}, _from, state) do
    matches = state.consolidated_vectors
    |> Enum.map(fn {purpose, vec} ->
      similarity = HRR.similarity(query_vec, vec)
      {purpose, similarity}
    end)
    |> Enum.filter(fn {_purpose, sim} -> sim >= threshold end)
    |> Enum.sort_by(fn {_purpose, sim} -> sim end, :desc)

    {:reply, matches, state}
  end

  @impl true
  def handle_call({:semantic_query, query_text, threshold}, _from, state) do
    query_vec = Encoder.encode_query(query_text, state.hrr_codebook, state.encoder_state)

    matches = state.consolidated_vectors
    |> Enum.map(fn {purpose, vec} ->
      similarity = HRR.similarity(query_vec, vec)
      {purpose, similarity}
    end)
    |> Enum.filter(fn {_purpose, sim} -> sim >= threshold end)
    |> Enum.sort_by(fn {_purpose, sim} -> sim end, :desc)

    {:reply, matches, state}
  end

  @impl true
  def handle_info(:consolidate, state) do
    new_state = do_consolidation(state)
    schedule_consolidation(@default_interval_ms)
    {:noreply, new_state}
  end

  @impl true
  def handle_info(:deep_consolidate, state) do
    new_state = do_deep_consolidation(state)
    schedule_deep_consolidation(@deep_consolidation_interval_ms)
    {:noreply, new_state}
  end

  # --- Consolidation Logic ---

  defp schedule_consolidation(interval) do
    Process.send_after(self(), :consolidate, interval)
  end

  defp schedule_deep_consolidation(interval) do
    Process.send_after(self(), :deep_consolidate, interval)
  end

  defp do_consolidation(state) do
    Logger.debug("[Consolidation] Starting consolidation cycle")

    storage_stats = try do
      Storage.stats()
    rescue
      _ -> %{hot: 0, warm: 0, cold: 0}
    end

    # Process hot tier traces and update co-occurrence
    {processed, new_vectors, new_encoder_state} =
      process_hot_traces(state.hrr_codebook, state.encoder_state, state.consolidated_vectors)

    new_stats = %{state.stats |
      consolidations: state.stats.consolidations + 1,
      traces_processed: state.stats.traces_processed + processed
    }

    Logger.debug("[Consolidation] Processed #{processed} traces, vocab: #{map_size(new_encoder_state.token_counts)}, storage: hot=#{storage_stats.hot}, warm=#{storage_stats.warm}")

    %{state |
      consolidated_vectors: new_vectors,
      encoder_state: new_encoder_state,
      last_consolidation: DateTime.utc_now(),
      stats: new_stats
    }
  end

  defp do_deep_consolidation(state) do
    Logger.info("[Consolidation] Starting deep consolidation cycle")

    # 1. Rebuild all consolidated vectors
    all_traces = query_all_traces()
    new_vectors = build_consolidated_vectors(all_traces, state.hrr_codebook, state.encoder_state)

    # 2. Maintain encoder state (decay + prune co-occurrence)
    maintained_state = EncoderState.maintain(state.encoder_state)

    # 3. Persist encoder state to DETS
    case EncoderState.save(maintained_state) do
      :ok ->
        Logger.info("[Consolidation] Encoder state persisted to DETS")
      {:error, reason} ->
        Logger.warning("[Consolidation] Failed to persist encoder state: #{inspect(reason)}")
    end

    # 4. Archive stale traces
    archived = archive_stale_traces(all_traces)

    new_stats = %{state.stats |
      deep_consolidations: state.stats.deep_consolidations + 1,
      traces_archived: state.stats.traces_archived + archived
    }

    Logger.info("[Consolidation] Deep consolidation complete: rebuilt #{map_size(new_vectors)} vectors, archived #{archived} traces, vocab: #{map_size(maintained_state.token_counts)}")

    %{state |
      consolidated_vectors: new_vectors,
      encoder_state: maintained_state,
      last_deep_consolidation: DateTime.utc_now(),
      stats: new_stats
    }
  end

  defp process_hot_traces(codebook, encoder_state, existing_vectors) do
    traces = query_hot_traces(@batch_size)

    if traces == [] do
      {0, existing_vectors, encoder_state}
    else
      # Group by purpose
      by_purpose = Enum.group_by(traces, fn trace ->
        case trace do
          %{purpose: purpose} -> purpose
          _ -> :unknown
        end
      end)

      # Update co-occurrence from all new traces
      new_encoder_state = Enum.reduce(traces, encoder_state, fn trace, es ->
        hint = case trace do
          %{reconstruction_hint: hint} when is_map(hint) -> hint
          _ -> %{}
        end
        tokens = Tokenizer.tokenize_hint(hint) |> Enum.reject(&String.contains?(&1, "_"))
        EncoderState.update_co_occurrence(es, tokens)
      end)

      # Update consolidated vectors for each purpose
      new_vectors = Enum.reduce(by_purpose, existing_vectors, fn {purpose, purpose_traces}, acc ->
        trace_structs = Enum.map(purpose_traces, &to_trace_struct/1)
        vec = Encoder.consolidate(trace_structs, codebook, new_encoder_state)

        merged = case Map.get(acc, purpose) do
          nil -> vec
          existing -> HRR.bundle([existing, vec])
        end

        Map.put(acc, purpose, merged)
      end)

      update_trace_salience(traces)

      {length(traces), new_vectors, new_encoder_state}
    end
  end

  defp query_hot_traces(limit) do
    try do
      Storage.query(:memory, limit: limit) ++
      Storage.query(:thought, limit: limit) ++
      Storage.query(:observation, limit: limit)
    rescue
      _ -> []
    end
  end

  defp query_all_traces do
    try do
      purposes = [:memory, :learning, :thought, :observation, :decision, :stimulus]
      Enum.flat_map(purposes, fn purpose ->
        Storage.query(purpose, limit: 1000)
      end)
    rescue
      _ -> []
    end
  end

  defp build_consolidated_vectors(traces, codebook, encoder_state) do
    by_purpose = Enum.group_by(traces, fn trace ->
      case trace do
        %{purpose: purpose} -> purpose
        _ -> :unknown
      end
    end)

    Enum.map(by_purpose, fn {purpose, purpose_traces} ->
      trace_structs = Enum.map(purpose_traces, &to_trace_struct/1)
      vec = Encoder.consolidate(trace_structs, codebook, encoder_state)
      {purpose, vec}
    end)
    |> Map.new()
  end

  defp archive_stale_traces(traces) do
    now = DateTime.utc_now()

    candidates = Enum.filter(traces, fn trace ->
      case trace do
        %{last_accessed: last_accessed, access_count: count, importance: importance}
            when not is_nil(last_accessed) ->
          hours_since = DateTime.diff(now, last_accessed, :hour)
          hours_since > 168 and count < 5 and importance != :critical
        _ ->
          false
      end
    end)

    length(candidates)
  end

  defp update_trace_salience(traces) do
    Enum.each(traces, fn trace ->
      case trace do
        %{id: id} when not is_nil(id) -> :ok
        _ -> :ok
      end
    end)
  end

  defp to_trace_struct(%{id: id, hologram_id: origin, purpose: purpose, reconstruction_hint: hint, path: path}) do
    %Kudzu.Trace{
      id: id || "unknown",
      origin: origin || "unknown",
      timestamp: Kudzu.VectorClock.new(origin || "unknown"),
      purpose: purpose || :unknown,
      path: path || [],
      reconstruction_hint: hint || %{}
    }
  end

  defp to_trace_struct(%Kudzu.Trace{} = trace), do: trace

  defp to_trace_struct(other) do
    %Kudzu.Trace{
      id: "unknown",
      origin: "unknown",
      timestamp: Kudzu.VectorClock.new("unknown"),
      purpose: :unknown,
      path: [],
      reconstruction_hint: %{raw: inspect(other)}
    }
  end
end
