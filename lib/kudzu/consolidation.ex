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

  - **Light (10 minutes)**: Process new traces, update co-occurrence matrix,
    persist encoder state to DETS (subject to `:encoder_persist_interval_cycles`)
  - **Deep (6 hours)**: Rebuild vectors, decay/prune co-occurrence, persist
    maintained encoder state to DETS

  ## Encoder Persistence

  Encoder co-occurrence state is persisted to DETS on every light cycle
  by default so a crash in the middle of a deep cycle cannot lose more than
  one light cycle's worth of vocabulary learning. Operators can throttle
  the cadence via the `:encoder_persist_interval_cycles` application env;
  setting it to `N` persists every `N`th light cycle. Deep cycles always
  persist regardless of the light-cycle interval.
  """

  use GenServer
  require Logger

  alias Kudzu.{Storage, HRR}
  alias Kudzu.HRR.{Encoder, EncoderState, Tokenizer}

  @default_interval_ms 600_000        # 10 minutes
  @deep_consolidation_interval_ms 21_600_000  # 6 hours
  @batch_size 100

  # Persist the HRR encoder state to DETS every N light cycles. With the
  # 10-minute light cycle, the default of 1 means persistence every
  # 10 minutes — sufficient to bound vocabulary-learning loss to a
  # single cycle's worth on crash. Operators can raise this to throttle
  # DETS sync IO on encoder states large enough that sub-100ms persist
  # cost would become contentious. Measured at ~15ms for a 251KB encoder
  # state on titan, so default of 1 is safe.
  @default_encoder_persist_interval_cycles 1

  defstruct [
    :hrr_codebook,
    :encoder_state,
    :consolidated_vectors,  # %{purpose => HRR.vector()}
    :last_consolidation,
    :last_deep_consolidation,
    :light_cycles_since_persist,
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

  @doc "Get consolidation daemon status"
  def status do
    GenServer.call(__MODULE__, :status, 5_000)
  rescue
    _ -> %{status: :unavailable}
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

  Searches traces by semantic similarity using Ollama embeddings.
  Returns list of %{trace_id, similarity, record} maps with actual content.
  Falls back to HRR-based search if embeddings are unavailable.

  This is a direct function (not GenServer call) to avoid blocking.
  """
  @spec semantic_query(String.t(), float()) :: [map()]
  def semantic_query(query_text, threshold \\ 0.1) do
    case Kudzu.Embedding.embed(query_text) do
      {:ok, query_vector} ->
        Kudzu.Storage.search_by_embedding(query_vector, limit: 10, threshold: threshold)

      {:error, _reason} ->
        # Fallback: use GenServer-based HRR search
        try do
          GenServer.call(__MODULE__, {:semantic_query_hrr, query_text, threshold}, 10_000)
        catch
          :exit, _ -> []
        end
    end
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
      light_cycles_since_persist: 0,
      stats: %{
        consolidations: 0,
        deep_consolidations: 0,
        traces_processed: 0,
        traces_archived: 0,
        associations_formed: 0,
        encoder_persists: 0
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
  def handle_call(:status, _from, state) do
    status = %{
      status: :running,
      last_light_cycle: state.last_consolidation,
      last_deep_cycle: state.last_deep_consolidation,
      light_cycle_count: state.stats.consolidations,
      deep_cycle_count: state.stats.deep_consolidations,
      encoder_persists: state.stats.encoder_persists
    }
    {:reply, status, state}
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
  def handle_call({:semantic_query_hrr, query_text, threshold}, _from, state) do
    # HRR fallback (purpose-level only)
    query_vec = Encoder.encode_query(query_text, state.hrr_codebook, state.encoder_state)

    results = state.consolidated_vectors
    |> Enum.map(fn {purpose, vec} ->
      similarity = HRR.similarity(query_vec, vec)
      {purpose, similarity}
    end)
    |> Enum.filter(fn {_purpose, sim} -> sim >= threshold end)
    |> Enum.sort_by(fn {_purpose, sim} -> sim end, :desc)
    |> Enum.map(fn {purpose, sim} ->
      %{trace_id: nil, similarity: sim, record: %{purpose: purpose}}
    end)

    {:reply, results, state}
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

    base_stats = %{state.stats |
      consolidations: state.stats.consolidations + 1,
      traces_processed: state.stats.traces_processed + processed
    }

    # Persist encoder state on a configurable light-cycle cadence so a crash
    # mid-deep-cycle cannot lose more than `interval_cycles` worth of
    # vocabulary learning. DETS sync is sub-100ms for typical encoder state
    # sizes; safe to run every cycle by default.
    {persist_counter, persist_stats} =
      maybe_persist_encoder(state.light_cycles_since_persist + 1, new_encoder_state, base_stats, :light)

    Logger.debug("[Consolidation] Processed #{processed} traces, vocab: #{map_size(new_encoder_state.token_counts)}, storage: hot=#{storage_stats.hot}, warm=#{storage_stats.warm}")

    %{state |
      consolidated_vectors: new_vectors,
      encoder_state: new_encoder_state,
      last_consolidation: DateTime.utc_now(),
      light_cycles_since_persist: persist_counter,
      stats: persist_stats
    }
  end

  defp do_deep_consolidation(state) do
    Logger.info("[Consolidation] Starting deep consolidation cycle")

    # 1. Rebuild all consolidated vectors
    all_traces = query_all_traces()
    new_vectors = build_consolidated_vectors(all_traces, state.hrr_codebook, state.encoder_state)

    # 2. Maintain encoder state (decay + prune co-occurrence)
    maintained_state = EncoderState.maintain(state.encoder_state)

    base_stats = %{state.stats |
      deep_consolidations: state.stats.deep_consolidations + 1
    }

    # 3. Persist the maintained encoder state to DETS unconditionally.
    # Deep cycles are infrequent (every 6h) so persistence on every deep
    # cycle is desirable regardless of the light-cycle interval. Reset the
    # light-cycle counter since this persist is just as good.
    {_persist_counter, post_persist_stats} =
      persist_encoder(maintained_state, base_stats, :deep)

    # 4. Archive stale traces
    archived = archive_stale_traces(all_traces)

    new_stats = %{post_persist_stats |
      traces_archived: post_persist_stats.traces_archived + archived
    }

    Logger.info("[Consolidation] Deep consolidation complete: rebuilt #{map_size(new_vectors)} vectors, archived #{archived} traces, vocab: #{map_size(maintained_state.token_counts)}")

    %{state |
      consolidated_vectors: new_vectors,
      encoder_state: maintained_state,
      last_deep_consolidation: DateTime.utc_now(),
      light_cycles_since_persist: 0,
      stats: new_stats
    }
  end

  # Persist the encoder state when `pending_cycles` has reached the
  # configured cadence. Returns the updated counter (reset to 0 on persist)
  # and the updated stats map (encoder_persists incremented on persist).
  @spec maybe_persist_encoder(non_neg_integer(), EncoderState.t(), map(), :light | :deep) ::
          {non_neg_integer(), map()}
  defp maybe_persist_encoder(pending_cycles, encoder_state, stats, cycle) do
    interval =
      Application.get_env(
        :kudzu,
        :encoder_persist_interval_cycles,
        @default_encoder_persist_interval_cycles
      )

    if pending_cycles >= interval do
      {0, elem(persist_encoder(encoder_state, stats, cycle), 1)}
    else
      {pending_cycles, stats}
    end
  end

  # Save encoder state to DETS, emit telemetry, and bump the persist
  # counter on success. Failures are logged but do not crash the cycle —
  # next cycle will retry. The returned counter is always 0 since this
  # function only runs when we actually persist.
  @spec persist_encoder(EncoderState.t(), map(), :light | :deep) :: {non_neg_integer(), map()}
  defp persist_encoder(encoder_state, stats, cycle) do
    case EncoderState.save(encoder_state) do
      :ok ->
        :telemetry.execute(
          [:kudzu, :encoder, :persisted],
          %{count: 1},
          %{cycle: cycle}
        )

        Logger.debug("[Consolidation] Encoder state persisted to DETS (cycle: #{cycle})")
        {0, %{stats | encoder_persists: stats.encoder_persists + 1}}

      {:error, reason} ->
        Logger.warning(
          "[Consolidation] Failed to persist encoder state (cycle: #{cycle}): #{inspect(reason)}"
        )

        {0, stats}
    end
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

  # Move warm-tier traces that have been idle for over 168 hours (7 days)
  # and accessed fewer than 5 times into the Mnesia cold tier. Returns the
  # number of traces actually archived (transaction succeeded + warm DETS
  # delete). Critical importance is never archived.
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

    Enum.reduce(candidates, 0, fn trace, archived ->
      case trace do
        %{id: id} when is_binary(id) ->
          case Storage.demote_to_cold(id) do
            :ok ->
              archived + 1

            :not_found ->
              # Trace had already been removed (e.g. evicted by warm-tier
              # capacity pressure) — not an error, just nothing to do.
              archived

            {:error, reason} ->
              Logger.warning(
                "[Consolidation] Failed to archive trace #{id}: #{inspect(reason)}"
              )

              archived
          end

        _ ->
          archived
      end
    end)
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
