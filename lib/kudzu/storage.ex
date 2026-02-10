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

  # Aging thresholds
  @hot_to_warm_seconds 3600        # 1 hour without access → warm
  @warm_to_cold_seconds 86400 * 7  # 7 days without access → cold

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

  # Server Implementation

  @impl true
  def init(_opts) do
    # Initialize hot tier (ETS)
    :ets.new(@hot_table, [:named_table, :set, :public, read_concurrency: true])

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

    # Always start in hot tier
    :ets.insert(@hot_table, {trace.id, record})

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
end
