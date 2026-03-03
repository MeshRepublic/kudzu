defmodule Kudzu.Storage do
  @moduledoc """
  Tiered storage for traces: ETS (hot) → DETS (warm) → Mnesia (cold)

  Enables SETI-style distributed memory across mesh nodes.

  ## Tiers

  - **Hot (ETS)**: Current session, sub-ms access, in-memory
  - **Warm (DETS)**: Recent traces, local disk, survives restarts
  - **Cold (Mnesia)**: Historical, distributed across mesh nodes

  ## Aging Policy

  Traces move between tiers based on:
  - Time since last access
  - Access frequency
  - Explicit importance hints

  ## Distribution

  Cold tier uses Mnesia's distribution to fragment traces across
  mesh nodes. Each node stores a subset, queries span the mesh.
  """

  use GenServer
  require Logger

  @hot_table :kudzu_traces_hot
  @warm_file ~c"/home/eel/kudzu_data/dets/traces_warm.dets"
  @cold_table :kudzu_traces_cold

  # Embedding storage (separate from traces for performance)
  @embedding_table :kudzu_embeddings
  @embedding_file ~c"/home/eel/kudzu_data/dets/embeddings.dets"

  # Aging thresholds
  @hot_to_warm_seconds 3600        # 1 hour without access → warm
  @warm_to_cold_seconds 86400 * 7  # 7 days without access → cold

  # Storage limits
  @max_hot_entries 50_000
  @max_warm_bytes 500_000_000       # 500MB
  @max_total_bytes 2_000_000_000    # 2GB
  @warm_path "/home/eel/kudzu_data/dets/traces_warm.dets"

  # Trace record for Mnesia
  # {trace_id, hologram_id, purpose, reconstruction_hint, timestamp, last_accessed, access_count}

  defmodule TraceRecord do
    @moduledoc "Trace storage record for tiered storage"
    defstruct [
      :id,
      :hologram_id,
      :purpose,
      :reconstruction_hint,
      :origin,
      :path,
      :clock,
      :created_at,
      :last_accessed,
      :access_count,
      :importance
    ]
  end

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Store a trace (starts in hot tier)"
  def store(trace, hologram_id, importance \\ :normal) do
    GenServer.call(__MODULE__, {:store, trace, hologram_id, importance})
  end

  @doc "Retrieve a trace by ID (checks all tiers)"
  def retrieve(trace_id) do
    GenServer.call(__MODULE__, {:retrieve, trace_id})
  end

  @doc "Query traces by purpose across all tiers"
  def query(purpose, opts \\ []) do
    GenServer.call(__MODULE__, {:query, purpose, opts}, 30_000)
  end

  @doc "Query traces for a specific hologram"
  def query_hologram(hologram_id, opts \\ []) do
    GenServer.call(__MODULE__, {:query_hologram, hologram_id, opts}, 30_000)
  end

  @doc "Force aging cycle (for testing or manual cleanup)"
  def age_traces do
    GenServer.call(__MODULE__, :age_traces, 60_000)
  end

  @doc "Get storage statistics"
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  @doc "Get detailed storage stats with byte counts and utilization"
  def detailed_stats do
    GenServer.call(__MODULE__, :detailed_stats)
  end

  @doc "Evict the lowest-value traces from the warm tier"
  def evict_lowest(count) do
    GenServer.call(__MODULE__, {:evict_lowest, count}, 60_000)
  end

  @doc "Store an embedding vector for a trace."
  def store_embedding(trace_id, vector) when is_list(vector) do
    GenServer.cast(__MODULE__, {:store_embedding, trace_id, vector})
  end

  @doc "Search traces by embedding similarity. Returns top-K with content."
  def search_by_embedding(query_vector, opts \\ []) do
    GenServer.call(__MODULE__, {:search_by_embedding, query_vector, opts}, 30_000)
  end

  @doc "Get the number of embedded traces."
  def embedding_count do
    try do
      :ets.info(@embedding_table, :size) || 0
    rescue
      _ -> 0
    end
  end

  # Server Implementation

  @impl true
  def init(_opts) do
    # Initialize hot tier (ETS)
    :ets.new(@hot_table, [:named_table, :set, :public, read_concurrency: true])

    # Initialize embedding index
    :ets.new(@embedding_table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, _} = :dets.open_file(@embedding_file, [type: :set])
    load_embeddings_from_dets()

    # Initialize warm tier (DETS)
    warm_dir = Path.dirname(to_string(@warm_file))
    File.mkdir_p!(warm_dir)
    {:ok, _} = :dets.open_file(@warm_file, [type: :set])

    # Check if Mnesia cold tier is available
    mnesia_ready = check_mnesia_ready()

    # Schedule periodic aging
    schedule_aging()

    {:ok, %{
      initialized_at: DateTime.utc_now(),
      mnesia_ready: mnesia_ready
    }}
  end

  defp check_mnesia_ready do
    try do
      case :mnesia.system_info(:is_running) do
        :yes ->
          tables = :mnesia.system_info(:tables)
          :kudzu_traces in tables
        _ ->
          false
      end
    rescue
      _ -> false
    end
  end

  @impl true
  def handle_call({:store, trace, hologram_id, importance}, _from, state) do
    record = %TraceRecord{
      id: trace.id,
      hologram_id: hologram_id,
      purpose: trace.purpose,
      reconstruction_hint: trace.reconstruction_hint,
      origin: trace.origin,
      path: trace.path,
      clock: trace.timestamp,
      created_at: DateTime.utc_now(),
      last_accessed: DateTime.utc_now(),
      access_count: 0,
      importance: importance
    }

    # Write to both hot (fast reads) and warm (durable) tiers
    :ets.insert(@hot_table, {trace.id, record})
    :dets.insert(@warm_file, {trace.id, record})

    # Async: embed traces with textual content (if not already embedded)
    if :ets.lookup(@embedding_table, trace.id) == [] do
      maybe_async_embed(trace)
    end

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:retrieve, trace_id}, _from, state) do
    result =
      case :ets.lookup(@hot_table, trace_id) do
        [{^trace_id, record}] ->
          touch_hot(trace_id, record)
          {:hot, record}
        [] ->
          case :dets.lookup(@warm_file, trace_id) do
            [{^trace_id, record}] ->
              # Promote to hot on access
              promote_to_hot(trace_id, record)
              {:warm, record}
            [] ->
              case retrieve_cold(trace_id) do
                {:ok, record} ->
                  promote_to_hot(trace_id, record)
                  {:cold, record}
                :not_found ->
                  :not_found
              end
          end
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:query, purpose, opts}, _from, state) do
    limit = Keyword.get(opts, :limit, 100)

    # Query all tiers
    hot_results = query_ets_by_purpose(purpose, limit)
    warm_results = query_dets_by_purpose(purpose, limit - length(hot_results))
    cold_results =
      if state.mnesia_ready do
        query_mnesia_by_purpose(purpose, limit - length(hot_results) - length(warm_results))
      else
        []
      end

    {:reply, hot_results ++ warm_results ++ cold_results, state}
  end

  @impl true
  def handle_call({:query_hologram, hologram_id, opts}, _from, state) do
    limit = Keyword.get(opts, :limit, 100)

    hot_results = query_ets_by_hologram(hologram_id, limit)
    warm_results = query_dets_by_hologram(hologram_id, limit - length(hot_results))
    cold_results =
      if state.mnesia_ready do
        query_mnesia_by_hologram(hologram_id, limit - length(hot_results) - length(warm_results))
      else
        []
      end

    {:reply, hot_results ++ warm_results ++ cold_results, state}
  end

  @impl true
  def handle_call(:age_traces, _from, state) do
    {demoted_to_warm, demoted_to_cold} = do_age_traces()
    {:reply, %{to_warm: demoted_to_warm, to_cold: demoted_to_cold}, state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    # Check Mnesia status dynamically
    mnesia_ready = check_mnesia_ready()
    cold_size = if mnesia_ready, do: mnesia_size(), else: :not_ready

    stats = %{
      hot: :ets.info(@hot_table, :size),
      warm: :dets.info(@warm_file, :size),
      cold: cold_size,
      mnesia_ready: mnesia_ready
    }

    # Update state if mnesia status changed
    new_state = %{state | mnesia_ready: mnesia_ready}
    {:reply, stats, new_state}
  end

  @impl true
  def handle_call(:detailed_stats, _from, state) do
    hot_count = :ets.info(@hot_table, :size)
    hot_words = :ets.info(@hot_table, :memory)
    wordsize = :erlang.system_info(:wordsize)
    hot_bytes = hot_words * wordsize

    warm_bytes =
      case File.stat(@warm_path) do
        {:ok, %{size: size}} -> size
        _ -> 0
      end

    total_bytes = hot_bytes + warm_bytes

    utilization =
      if @max_total_bytes > 0 do
        Float.round(total_bytes / @max_total_bytes * 100, 1)
      else
        0.0
      end

    stats = %{
      hot_count: hot_count,
      hot_bytes: hot_bytes,
      warm_bytes: warm_bytes,
      total_bytes: total_bytes,
      utilization: utilization,
      max_hot_entries: @max_hot_entries,
      max_warm_bytes: @max_warm_bytes,
      max_total_bytes: @max_total_bytes
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_call({:evict_lowest, count}, _from, state) do
    evicted = do_evict_lowest(count)
    {:reply, evicted, state}
  end

  @impl true
  def handle_cast({:store_embedding, trace_id, vector}, state) do
    :ets.insert(@embedding_table, {trace_id, vector})
    :dets.insert(@embedding_file, {trace_id, vector})
    {:noreply, state}
  end

  @impl true
  def handle_call({:search_by_embedding, query_vector, opts}, _from, state) do
    limit = Keyword.get(opts, :limit, 10)
    threshold = Keyword.get(opts, :threshold, 0.3)
    results = do_embedding_search(query_vector, limit, threshold)
    {:reply, results, state}
  end

  @impl true
  def handle_info(:age_traces, state) do
    do_age_traces()
    schedule_aging()
    {:noreply, state}
  end

  # Private functions

  defp schedule_aging do
    # Run aging every 10 minutes
    Process.send_after(self(), :age_traces, 600_000)
  end

  defp touch_hot(trace_id, record) do
    updated = %{record |
      last_accessed: DateTime.utc_now(),
      access_count: record.access_count + 1
    }
    :ets.insert(@hot_table, {trace_id, updated})
  end

  defp promote_to_hot(trace_id, record) do
    updated = %{record |
      last_accessed: DateTime.utc_now(),
      access_count: record.access_count + 1
    }
    :ets.insert(@hot_table, {trace_id, updated})
    # Remove from lower tier
    :dets.delete(@warm_file, trace_id)
    # Cold deletion handled by Mnesia if present
  end

  defp do_age_traces do
    now = DateTime.utc_now()
    hot_threshold = DateTime.add(now, -@hot_to_warm_seconds)
    warm_threshold = DateTime.add(now, -@warm_to_cold_seconds)

    # Hot → Warm
    demoted_to_warm =
      :ets.foldl(fn {id, record}, acc ->
        if DateTime.compare(record.last_accessed, hot_threshold) == :lt and
           record.importance != :critical do
          :dets.insert(@warm_file, {id, record})
          :ets.delete(@hot_table, id)
          acc + 1
        else
          acc
        end
      end, 0, @hot_table)

    # Warm → Cold (if Mnesia ready)
    demoted_to_cold = 0  # TODO: implement when Mnesia schema is ready

    Logger.debug("Aging cycle: #{demoted_to_warm} to warm, #{demoted_to_cold} to cold")
    {demoted_to_warm, demoted_to_cold}
  end

  defp query_ets_by_purpose(purpose, limit) do
    purpose_atom = if is_atom(purpose), do: purpose, else: String.to_atom(purpose)

    :ets.foldl(fn {_id, record}, acc ->
      if length(acc) < limit and record.purpose == purpose_atom do
        [record | acc]
      else
        acc
      end
    end, [], @hot_table)
  end

  defp query_ets_by_hologram(hologram_id, limit) do
    :ets.foldl(fn {_id, record}, acc ->
      if length(acc) < limit and record.hologram_id == hologram_id do
        [record | acc]
      else
        acc
      end
    end, [], @hot_table)
  end

  defp query_dets_by_purpose(purpose, limit) when limit > 0 do
    purpose_atom = if is_atom(purpose), do: purpose, else: String.to_atom(purpose)

    :dets.foldl(fn {_id, record}, acc ->
      if length(acc) < limit and record.purpose == purpose_atom do
        [record | acc]
      else
        acc
      end
    end, [], @warm_file)
  end
  defp query_dets_by_purpose(_purpose, _limit), do: []

  defp query_dets_by_hologram(hologram_id, limit) when limit > 0 do
    :dets.foldl(fn {_id, record}, acc ->
      if length(acc) < limit and record.hologram_id == hologram_id do
        [record | acc]
      else
        acc
      end
    end, [], @warm_file)
  end
  defp query_dets_by_hologram(_hologram_id, _limit), do: []

  defp query_mnesia_by_hologram(_hologram_id, _limit) do
    # TODO: implement
    []
  end

  defp mnesia_size do
    try do
      :mnesia.table_info(:kudzu_traces, :size)
    rescue
      _ -> 0
    end
  end

  defp query_mnesia_by_purpose(purpose, limit) when limit > 0 do
    purpose_atom = if is_atom(purpose), do: purpose, else: String.to_atom(to_string(purpose))

    try do
      {:atomic, results} = :mnesia.transaction(fn ->
        :mnesia.foldl(fn record, acc ->
          {_, id, hologram_id, rec_purpose, hint, origin, path, clock, created, accessed, count, importance} = record
          if rec_purpose == purpose_atom and length(acc) < limit do
            [%TraceRecord{
              id: id,
              hologram_id: hologram_id,
              purpose: rec_purpose,
              reconstruction_hint: hint,
              origin: origin,
              path: path,
              clock: clock,
              created_at: created,
              last_accessed: accessed,
              access_count: count,
              importance: importance
            } | acc]
          else
            acc
          end
        end, [], :kudzu_traces)
      end)
      results
    rescue
      _ -> []
    end
  end
  defp query_mnesia_by_purpose(_purpose, _limit), do: []

  defp do_evict_lowest(count) do
    now = DateTime.utc_now()

    # Collect all warm traces with their eviction scores
    scored =
      :dets.foldl(fn {id, record}, acc ->
        hours_since_access =
          case record.last_accessed do
            %DateTime{} = last ->
              DateTime.diff(now, last, :second) / 3600.0
            _ ->
              # If last_accessed is not a DateTime, treat as very stale
              720.0
          end

        access_count = record.access_count || 0
        score = access_count / (1 + hours_since_access)
        [{id, score} | acc]
      end, [], @warm_file)

    # Sort by score ascending (lowest = least valuable = evict first)
    to_evict =
      scored
      |> Enum.sort_by(fn {_id, score} -> score end)
      |> Enum.take(count)

    # Delete the selected traces
    Enum.each(to_evict, fn {id, _score} ->
      :dets.delete(@warm_file, id)
    end)

    deleted = length(to_evict)
    Logger.info("[Storage] Evicted #{deleted} lowest-value traces from warm tier")
    deleted
  end

  defp retrieve_cold(trace_id) do
    try do
      case :mnesia.transaction(fn -> :mnesia.read({:kudzu_traces, trace_id}) end) do
        {:atomic, [{_, id, hologram_id, purpose, hint, origin, path, clock, created, accessed, count, importance}]} ->
          {:ok, %TraceRecord{
            id: id,
            hologram_id: hologram_id,
            purpose: purpose,
            reconstruction_hint: hint,
            origin: origin,
            path: path,
            clock: clock,
            created_at: created,
            last_accessed: accessed,
            access_count: count,
            importance: importance
          }}
        {:atomic, []} ->
          :not_found
        _ ->
          :not_found
      end
    rescue
      _ -> :not_found
    end
  end

  # --- Embedding helpers ---

  defp load_embeddings_from_dets do
    count = :dets.foldl(fn {trace_id, vector}, acc ->
      :ets.insert(@embedding_table, {trace_id, vector})
      acc + 1
    end, 0, @embedding_file)

    if count > 0 do
      Logger.info("[Storage] Loaded #{count} embeddings from DETS")
    end
  end

  defp maybe_async_embed(trace) do
    text = extract_text_content(trace)
    if text && String.length(text) > 10 do
      trace_id = trace.id
      Task.start(fn ->
        # Brief delay to avoid flooding Ollama during bulk operations
        Process.sleep(100)
        case Kudzu.Embedding.embed(text, timeout: 15_000) do
          {:ok, vector} ->
            store_embedding(trace_id, vector)
          {:error, _reason} ->
            :ok  # Silent fail — embedding will happen during backfill
        end
      end)
    end
  end

  defp extract_text_content(trace) do
    hint = trace.reconstruction_hint || %{}
    cond do
      is_binary(Map.get(hint, "content")) -> Map.get(hint, "content")
      is_binary(Map.get(hint, :content)) -> Map.get(hint, :content)
      is_binary(Map.get(hint, "text")) -> Map.get(hint, "text")
      is_binary(Map.get(hint, :text)) -> Map.get(hint, :text)
      is_binary(Map.get(hint, "summary")) -> Map.get(hint, "summary")
      is_binary(Map.get(hint, :summary)) -> Map.get(hint, :summary)
      is_binary(Map.get(hint, "message")) -> Map.get(hint, "message")
      is_binary(Map.get(hint, :message)) -> Map.get(hint, :message)
      is_binary(Map.get(hint, "query")) -> Map.get(hint, "query")
      is_binary(Map.get(hint, :query)) -> Map.get(hint, :query)
      is_map(hint) ->
        subj = Map.get(hint, "subject") || Map.get(hint, :subject)
        rel = Map.get(hint, "relation") || Map.get(hint, :relation)
        obj = Map.get(hint, "object") || Map.get(hint, :object)
        if subj && rel && obj, do: "#{subj} #{rel} #{obj}", else: nil
      true -> nil
    end
  end

  defp do_embedding_search(query_vector, limit, threshold) do
    scored =
      :ets.foldl(fn {trace_id, vector}, acc ->
        sim = Kudzu.Embedding.cosine_similarity(query_vector, vector)
        if sim >= threshold do
          [{trace_id, sim} | acc]
        else
          acc
        end
      end, [], @embedding_table)

    top_ids =
      scored
      |> Enum.sort_by(fn {_id, sim} -> sim end, :desc)
      |> Enum.take(limit)

    Enum.map(top_ids, fn {trace_id, similarity} ->
      record = case :ets.lookup(@hot_table, trace_id) do
        [{^trace_id, rec}] -> rec
        [] ->
          case :dets.lookup(@warm_file, trace_id) do
            [{^trace_id, rec}] -> rec
            [] -> nil
          end
      end

      %{trace_id: trace_id, similarity: similarity, record: record}
    end)
    |> Enum.reject(fn %{record: r} -> is_nil(r) end)
  end

end
