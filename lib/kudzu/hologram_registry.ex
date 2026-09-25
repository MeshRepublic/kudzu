defmodule Kudzu.HologramRegistry do
  @moduledoc """
  Persistent registry for hologram metadata.

  Stores hologram configuration in DETS so holograms can be
  reconstructed after a Kudzu restart. This is the missing link
  between durable trace storage and ephemeral GenServer processes.

  ## What Gets Persisted

  For each hologram: id, purpose, constitution, desires,
  cognition_enabled, cognition_model, peers, timestamps.

  ## Lifecycle

  - On hologram creation: register/2 stores metadata
  - On hologram state change: update/2 refreshes metadata
  - On hologram deletion: deregister/1 removes entry
  - On Kudzu startup: reconstruct_all/0 respawns all persisted holograms

  ## Never blocking the registry

  `register/2` is called synchronously from inside a new hologram's
  `init/1`, so this GenServer must stay responsive. Reconstruction
  therefore only *reads* records inside the server; spawning (which loads
  each hologram's traces from storage) runs in the caller. Likewise the
  periodic live-state sweep gathers hologram state in a separate task and
  hands the results back as a cast.

  `reconstructed?/0` reports whether startup reconstruction has finished.
  Find-or-create callers (the Brain's hologram, its silos) wait for it, so
  they find the persisted holograms instead of creating duplicates.
  """

  use GenServer
  require Logger

  @persist_interval_ms 60_000
  # Writes are flushed to disk at most this long after they happen. A sync
  # per call (fsync) serialized every register/2 behind the disk and timed
  # out callers -- including new holograms registering from init/1.
  @sync_delay_ms 1_000
  @reconstruct_concurrency 8
  @reconstruct_timeout_ms 60_000

  # The DETS file path is derived from the runtime :data_root config so test
  # runs land in /tmp and never share a file with the production node.
  @spec dets_file() :: charlist()
  defp dets_file do
    String.to_charlist(
      Path.join([Application.fetch_env!(:kudzu, :data_root), "dets", "hologram_registry.dets"])
    )
  end

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Register a hologram's metadata for persistence."
  @spec register(String.t(), map()) :: :ok
  def register(id, metadata) do
    GenServer.call(__MODULE__, {:register, id, metadata})
  end

  @doc "Update a hologram's persisted metadata."
  @spec update(String.t(), map()) :: :ok
  def update(id, metadata) do
    GenServer.call(__MODULE__, {:update, id, metadata})
  end

  @doc "Remove a hologram from the persistent registry."
  @spec deregister(String.t()) :: :ok
  def deregister(id) do
    GenServer.call(__MODULE__, {:deregister, id})
  end

  @doc "Get metadata for a specific hologram."
  @spec get(String.t()) :: {:ok, map()} | :not_found
  def get(id) do
    GenServer.call(__MODULE__, {:get, id})
  end

  @doc "List all persisted hologram metadata."
  @spec list_all() :: [map()]
  def list_all do
    GenServer.call(__MODULE__, :list_all)
  end

  @doc """
  Reconstruct all persisted holograms.
  Called during startup after DynamicSupervisor is ready.

  Runs in the caller: the registry only hands out the records, so it keeps
  serving `register/2` calls while holograms are respawned. Marks
  reconstruction finished (see `reconstructed?/0`) even if it fails.
  """
  @spec reconstruct_all() :: [{String.t(), pid()}]
  def reconstruct_all do
    records = GenServer.call(__MODULE__, :records_for_reconstruction)

    try do
      reconstruct(records)
    after
      GenServer.cast(__MODULE__, :reconstruction_done)
    end
  end

  @doc false
  # Respawn the given persisted records in the calling process (bounded
  # concurrency) and re-link their peers. Records whose hologram is
  # already running are skipped. Public so tests can reconstruct their own
  # records without respawning every stale record in a shared registry.
  @spec reconstruct([map()]) :: [{String.t(), pid()}]
  def reconstruct(records) do
    Logger.info("[HologramRegistry] Reconstructing #{length(records)} holograms...")
    spawned = spawn_reconstructed(records)
    reconnect_peers(spawned)
    result = Enum.map(spawned, fn {id, pid, _} -> {id, pid} end)
    Logger.info("[HologramRegistry] Reconstruction complete: #{length(result)} holograms active")
    result
  end

  @doc "Whether startup reconstruction has finished."
  @spec reconstructed?() :: boolean()
  def reconstructed? do
    GenServer.call(__MODULE__, :reconstructed?)
  end

  @doc "Persist the current state of all live holograms."
  @spec persist_all_live() :: :ok
  def persist_all_live do
    GenServer.cast(__MODULE__, :persist_all_live)
  end

  # Server Implementation

  @impl true
  def init(_opts) do
    file = dets_file()
    dets_dir = Path.dirname(to_string(file))
    File.mkdir_p!(dets_dir)

    {:ok, _} = :dets.open_file(file, type: :set)

    count = :dets.info(file, :size)
    Logger.info("[HologramRegistry] Opened registry with #{count} persisted holograms")

    Process.send_after(self(), :persist_live, @persist_interval_ms)

    {:ok, %{dets: file, reconstructed: false, sync_scheduled: false}}
  end

  @impl true
  def handle_call({:register, id, metadata}, _from, state) do
    record =
      metadata
      |> Map.put(:id, id)
      |> Map.put(:created_at, Map.get(metadata, :created_at, DateTime.utc_now()))
      |> Map.put(:last_persisted_at, DateTime.utc_now())

    :dets.insert(state.dets, {id, record})

    Logger.info("[HologramRegistry] Registered hologram #{id} (purpose: #{record[:purpose]})")
    {:reply, :ok, schedule_sync(state)}
  end

  @impl true
  def handle_call({:update, id, metadata}, _from, state) do
    case :dets.lookup(state.dets, id) do
      [{^id, existing}] ->
        updated =
          Map.merge(existing, metadata)
          |> Map.put(:last_persisted_at, DateTime.utc_now())

        :dets.insert(state.dets, {id, updated})
        {:reply, :ok, schedule_sync(state)}

      [] ->
        record =
          metadata
          |> Map.put(:id, id)
          |> Map.put(:last_persisted_at, DateTime.utc_now())

        :dets.insert(state.dets, {id, record})
        {:reply, :ok, schedule_sync(state)}
    end
  end

  @impl true
  def handle_call({:deregister, id}, _from, state) do
    :dets.delete(state.dets, id)
    Logger.info("[HologramRegistry] Deregistered hologram #{id}")
    {:reply, :ok, schedule_sync(state)}
  end

  @impl true
  def handle_call({:get, id}, _from, state) do
    result =
      case :dets.lookup(state.dets, id) do
        [{^id, record}] -> {:ok, record}
        [] -> :not_found
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call(:list_all, _from, state) do
    records =
      :dets.foldl(
        fn {_id, record}, acc ->
          [record | acc]
        end,
        [],
        state.dets
      )

    {:reply, records, state}
  end

  @impl true
  def handle_call(:records_for_reconstruction, _from, state) do
    records = :dets.foldl(fn {_id, record}, acc -> [record | acc] end, [], state.dets)
    {:reply, records, state}
  end

  def handle_call(:reconstructed?, _from, state) do
    {:reply, state.reconstructed, state}
  end

  @impl true
  def handle_cast(:persist_all_live, state) do
    start_live_snapshot()
    {:noreply, state}
  end

  def handle_cast(:reconstruction_done, state) do
    {:noreply, %{state | reconstructed: true}}
  end

  def handle_cast({:persist_snapshot, metadata_list}, state) do
    # One batched insert: per-record inserts for hundreds of holograms held
    # the registry for seconds on a busy disk, timing out register/2.
    :dets.insert(state.dets, Enum.map(metadata_list, &{&1.id, &1}))
    {:noreply, schedule_sync(state)}
  end

  @impl true
  def handle_info(:sync, state) do
    :dets.sync(state.dets)
    {:noreply, %{state | sync_scheduled: false}}
  end

  def handle_info(:persist_live, state) do
    start_live_snapshot()
    Process.send_after(self(), :persist_live, @persist_interval_ms)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    do_persist_all_live(state)
    :dets.close(state.dets)
    :ok
  end

  # Private

  defp schedule_sync(%{sync_scheduled: true} = state), do: state

  defp schedule_sync(state) do
    Process.send_after(self(), :sync, @sync_delay_ms)
    %{state | sync_scheduled: true}
  end

  # Spawn every persisted hologram (in the caller, bounded concurrency).
  defp spawn_reconstructed(records) do
    records
    |> Task.async_stream(&spawn_one/1,
      max_concurrency: @reconstruct_concurrency,
      timeout: @reconstruct_timeout_ms,
      on_timeout: :kill_task
    )
    |> Enum.flat_map(fn
      {:ok, nil} -> []
      {:ok, spawned} -> [spawned]
      {:exit, reason} -> log_failed_spawn(reason)
    end)
  end

  # Records whose hologram is already running are skipped, so calling
  # reconstruct_all/0 again never spawns a second process with the same id.
  defp spawn_one(record) do
    case Registry.lookup(Kudzu.Registry, {:id, record.id}) do
      [] -> start_reconstructed(record)
      [_ | _] -> nil
    end
  end

  defp start_reconstructed(record) do
    opts = [
      id: record.id,
      purpose: record[:purpose] || :general,
      desires: record[:desires] || [],
      cognition: record[:cognition_enabled] || false,
      model: record[:cognition_model] || "mistral:latest",
      constitution: record[:constitution] || :mesh_republic,
      reconstruct: true
    ]

    case DynamicSupervisor.start_child(Kudzu.HologramSupervisor, {Kudzu.Hologram, opts}) do
      {:ok, pid} ->
        Logger.info(
          "[HologramRegistry] Reconstructed #{record.id} (purpose: #{record[:purpose]})"
        )

        {record.id, pid, record[:peers] || %{}}

      {:error, reason} ->
        Logger.warning(
          "[HologramRegistry] Failed to reconstruct #{record.id}: #{inspect(reason)}"
        )

        nil
    end
  end

  defp log_failed_spawn(reason) do
    Logger.warning("[HologramRegistry] Reconstruction task exited: #{inspect(reason)}")
    []
  end

  # Re-establish peer connections between reconstructed holograms.
  defp reconnect_peers(spawned) do
    pid_map = Map.new(spawned, fn {id, pid, _peers} -> {id, pid} end)

    Enum.each(spawned, fn {_id, pid, peers} ->
      peers
      |> Map.keys()
      |> Enum.map(&Map.get(pid_map, &1))
      |> Enum.reject(&is_nil/1)
      |> Enum.each(&introduce_peer(pid, &1))
    end)
  end

  defp introduce_peer(pid, peer_pid) do
    Kudzu.Hologram.introduce_peer(pid, peer_pid)
  catch
    :exit, _ -> :ok
  end

  # Gather live hologram state outside the registry process (Hologram
  # get_state calls can be slow while a hologram is busy) and cast the
  # snapshot back for a single DETS write + sync.
  defp start_live_snapshot do
    registry = self()
    Task.start(fn -> GenServer.cast(registry, {:persist_snapshot, live_snapshot()}) end)
  end

  defp do_persist_all_live(state) do
    :dets.insert(state.dets, Enum.map(live_snapshot(), &{&1.id, &1}))
    :dets.sync(state.dets)
  end

  defp live_snapshot do
    DynamicSupervisor.which_children(Kudzu.HologramSupervisor)
    |> Enum.map(fn {_, pid, _, _} -> pid end)
    |> Enum.filter(&is_pid/1)
    |> Enum.flat_map(fn pid ->
      try do
        s = Kudzu.Hologram.get_state(pid)

        [
          %{
            id: s.id,
            purpose: s.purpose,
            constitution: s.constitution,
            desires: s.desires,
            cognition_enabled: s.cognition_enabled,
            cognition_model: s.cognition_model,
            peers: s.peers,
            last_persisted_at: DateTime.utc_now()
          }
        ]
      catch
        :exit, _ -> []
      end
    end)
  end
end
