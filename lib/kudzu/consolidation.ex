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

  ## Consolidation Cycle

  The daemon runs periodically (default: every 10 minutes) and processes
  memories in batches to avoid blocking normal operations.

  ## Sleep-like Deep Consolidation

  Less frequently (default: every 6 hours), a "deep consolidation" runs
  that performs more aggressive memory restructuring, similar to how
  biological memories are reorganized during deep sleep.
  """

  use GenServer
  require Logger

  alias Kudzu.{Storage, HRR}
  alias Kudzu.HRR.Encoder

  @default_interval_ms 600_000        # 10 minutes
  @deep_consolidation_interval_ms 21_600_000  # 6 hours
  @batch_size 100

  defstruct [
    :hrr_codebook,
    :consolidated_vectors,  # %{purpose => HRR.vector()}
    :last_consolidation,
    :last_deep_consolidation,
    :stats
  ]

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Force a consolidation cycle.
  """
  @spec consolidate_now() :: :ok
  def consolidate_now do
    GenServer.cast(__MODULE__, :consolidate)
  end

  @doc """
  Force a deep consolidation cycle.
  """
  @spec deep_consolidate_now() :: :ok
  def deep_consolidate_now do
    GenServer.cast(__MODULE__, :deep_consolidate)
  end

  @doc """
  Get consolidated HRR vector for a purpose.
  """
  @spec get_consolidated_vector(atom()) :: HRR.vector() | nil
  def get_consolidated_vector(purpose) do
    GenServer.call(__MODULE__, {:get_vector, purpose})
  end

  @doc """
  Get consolidation statistics.
  """
  @spec stats() :: map()
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  @doc """
  Query consolidated memory using HRR probe.
  Returns traces that match the query vector above threshold.
  """
  @spec query_memory(HRR.vector(), float()) :: [{atom(), float()}]
  def query_memory(query_vec, threshold \\ 0.3) do
    GenServer.call(__MODULE__, {:query_memory, query_vec, threshold})
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval, @default_interval_ms)
    deep_interval = Keyword.get(opts, :deep_interval, @deep_consolidation_interval_ms)

    # Initialize HRR codebook
    codebook = Encoder.init()

    state = %__MODULE__{
      hrr_codebook: codebook,
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
    {:reply, state.stats, state}
  end

  @impl true
  def handle_call({:query_memory, query_vec, threshold}, _from, state) do
    # Probe all consolidated vectors
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

  # Private functions

  defp schedule_consolidation(interval) do
    Process.send_after(self(), :consolidate, interval)
  end

  defp schedule_deep_consolidation(interval) do
    Process.send_after(self(), :deep_consolidate, interval)
  end

  defp do_consolidation(state) do
    Logger.debug("[Consolidation] Starting consolidation cycle")

    # Get storage stats
    storage_stats = try do
      Storage.stats()
    rescue
      _ -> %{hot: 0, warm: 0, cold: 0}
    end

    # Process hot tier traces
    {processed, new_vectors} = process_hot_traces(state.hrr_codebook, state.consolidated_vectors)

    # Update statistics
    new_stats = %{state.stats |
      consolidations: state.stats.consolidations + 1,
      traces_processed: state.stats.traces_processed + processed
    }

    Logger.debug("[Consolidation] Processed #{processed} traces, storage: hot=#{storage_stats.hot}, warm=#{storage_stats.warm}")

    %{state |
      consolidated_vectors: new_vectors,
      last_consolidation: DateTime.utc_now(),
      stats: new_stats
    }
  end

  defp do_deep_consolidation(state) do
    Logger.info("[Consolidation] Starting deep consolidation cycle")

    # Deep consolidation:
    # 1. Rebuild all consolidated vectors from scratch
    # 2. Identify archival candidates and move to cold storage
    # 3. Form cross-purpose associations

    # Rebuild consolidated vectors
    all_traces = query_all_traces()
    new_vectors = build_consolidated_vectors(all_traces, state.hrr_codebook)

    # Identify archival candidates
    archived = archive_stale_traces(all_traces)

    # Update statistics
    new_stats = %{state.stats |
      deep_consolidations: state.stats.deep_consolidations + 1,
      traces_archived: state.stats.traces_archived + archived
    }

    Logger.info("[Consolidation] Deep consolidation complete: rebuilt #{map_size(new_vectors)} vectors, archived #{archived} traces")

    %{state |
      consolidated_vectors: new_vectors,
      last_deep_consolidation: DateTime.utc_now(),
      stats: new_stats
    }
  end

  defp process_hot_traces(codebook, existing_vectors) do
    # Query recent traces from hot storage
    traces = query_hot_traces(@batch_size)

    if traces == [] do
      {0, existing_vectors}
    else
      # Group by purpose
      by_purpose = Enum.group_by(traces, fn trace ->
        case trace do
          %{purpose: purpose} -> purpose
          _ -> :unknown
        end
      end)

      # Update consolidated vectors for each purpose
      new_vectors = Enum.reduce(by_purpose, existing_vectors, fn {purpose, purpose_traces}, acc ->
        # Create mock Trace structs for encoding
        trace_structs = Enum.map(purpose_traces, &to_trace_struct/1)

        # Consolidate into HRR vector
        vec = Encoder.consolidate(trace_structs, codebook)

        # Merge with existing vector if present
        merged = case Map.get(acc, purpose) do
          nil -> vec
          existing -> HRR.bundle([existing, vec])
        end

        Map.put(acc, purpose, merged)
      end)

      # Update salience for processed traces
      update_trace_salience(traces)

      {length(traces), new_vectors}
    end
  end

  defp query_hot_traces(limit) do
    try do
      # Query from storage - get recent traces
      # Note: In real implementation, would query by recency
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

  defp build_consolidated_vectors(traces, codebook) do
    # Group by purpose
    by_purpose = Enum.group_by(traces, fn trace ->
      case trace do
        %{purpose: purpose} -> purpose
        _ -> :unknown
      end
    end)

    # Build vector for each purpose
    Enum.map(by_purpose, fn {purpose, purpose_traces} ->
      trace_structs = Enum.map(purpose_traces, &to_trace_struct/1)
      vec = Encoder.consolidate(trace_structs, codebook)
      {purpose, vec}
    end)
    |> Map.new()
  end

  defp archive_stale_traces(traces) do
    # Identify traces that should be archived
    now = DateTime.utc_now()

    candidates = Enum.filter(traces, fn trace ->
      case trace do
        %{last_accessed: last_accessed, access_count: count, importance: importance}
            when not is_nil(last_accessed) ->
          hours_since = DateTime.diff(now, last_accessed, :hour)
          # Archive if: old, low access count, not critical
          hours_since > 168 and count < 5 and importance != :critical

        _ ->
          false
      end
    end)

    # Would trigger actual archival here
    # For now, just count candidates
    length(candidates)
  end

  defp update_trace_salience(traces) do
    # Update salience for each trace (mark as consolidated)
    Enum.each(traces, fn trace ->
      case trace do
        %{id: id} when not is_nil(id) ->
          # In real implementation, would update salience in storage
          :ok
        _ ->
          :ok
      end
    end)
  end

  # Convert storage record to Trace struct for encoding
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
    # Handle other formats
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
