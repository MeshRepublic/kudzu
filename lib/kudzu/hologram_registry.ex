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
  """

  use GenServer
  require Logger

  @dets_file ~c"/home/eel/kudzu_data/dets/hologram_registry.dets"
  @persist_interval_ms 60_000

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
  """
  @spec reconstruct_all() :: [{String.t(), pid()}]
  def reconstruct_all do
    GenServer.call(__MODULE__, :reconstruct_all, 60_000)
  end

  @doc "Persist the current state of all live holograms."
  @spec persist_all_live() :: :ok
  def persist_all_live do
    GenServer.cast(__MODULE__, :persist_all_live)
  end

  # Server Implementation

  @impl true
  def init(_opts) do
    dets_dir = Path.dirname(to_string(@dets_file))
    File.mkdir_p!(dets_dir)

    {:ok, _} = :dets.open_file(@dets_file, type: :set)

    count = :dets.info(@dets_file, :size)
    Logger.info("[HologramRegistry] Opened registry with #{count} persisted holograms")

    Process.send_after(self(), :persist_live, @persist_interval_ms)

    {:ok, %{dets: @dets_file}}
  end

  @impl true
  def handle_call({:register, id, metadata}, _from, state) do
    record = metadata
    |> Map.put(:id, id)
    |> Map.put(:created_at, Map.get(metadata, :created_at, DateTime.utc_now()))
    |> Map.put(:last_persisted_at, DateTime.utc_now())

    :dets.insert(state.dets, {id, record})
    :dets.sync(state.dets)

    Logger.info("[HologramRegistry] Registered hologram #{id} (purpose: #{record[:purpose]})")
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:update, id, metadata}, _from, state) do
    case :dets.lookup(state.dets, id) do
      [{^id, existing}] ->
        updated = Map.merge(existing, metadata)
        |> Map.put(:last_persisted_at, DateTime.utc_now())
        :dets.insert(state.dets, {id, updated})
        :dets.sync(state.dets)
        {:reply, :ok, state}

      [] ->
        record = metadata
        |> Map.put(:id, id)
        |> Map.put(:last_persisted_at, DateTime.utc_now())
        :dets.insert(state.dets, {id, record})
        :dets.sync(state.dets)
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:deregister, id}, _from, state) do
    :dets.delete(state.dets, id)
    :dets.sync(state.dets)
    Logger.info("[HologramRegistry] Deregistered hologram #{id}")
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:get, id}, _from, state) do
    result = case :dets.lookup(state.dets, id) do
      [{^id, record}] -> {:ok, record}
      [] -> :not_found
    end
    {:reply, result, state}
  end

  @impl true
  def handle_call(:list_all, _from, state) do
    records = :dets.foldl(fn {_id, record}, acc ->
      [record | acc]
    end, [], state.dets)
    {:reply, records, state}
  end

  @impl true
  def handle_call(:reconstruct_all, _from, state) do
    records = :dets.foldl(fn {_id, record}, acc ->
      [record | acc]
    end, [], state.dets)

    Logger.info("[HologramRegistry] Reconstructing #{length(records)} holograms...")

    # Phase 1: Spawn all holograms with their persisted config
    spawned = records
    |> Enum.map(fn record ->
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
          Logger.info("[HologramRegistry] Reconstructed #{record.id} (purpose: #{record[:purpose]})")
          {record.id, pid, record[:peers] || %{}}

        {:error, reason} ->
          Logger.warning("[HologramRegistry] Failed to reconstruct #{record.id}: #{inspect(reason)}")
          nil
      end
    end)
    |> Enum.reject(&is_nil/1)

    # Phase 2: Re-establish peer connections between reconstructed holograms
    pid_map = Map.new(spawned, fn {id, pid, _peers} -> {id, pid} end)

    Enum.each(spawned, fn {_id, pid, peers} ->
      peers
      |> Map.keys()
      |> Enum.each(fn peer_id ->
        case Map.get(pid_map, peer_id) do
          nil -> :ok
          peer_pid ->
            try do
              Kudzu.Hologram.introduce_peer(pid, peer_pid)
            catch
              :exit, _ -> :ok
            end
        end
      end)
    end)

    result = Enum.map(spawned, fn {id, pid, _} -> {id, pid} end)
    Logger.info("[HologramRegistry] Reconstruction complete: #{length(result)} holograms active")

    {:reply, result, state}
  end

  @impl true
  def handle_cast(:persist_all_live, state) do
    do_persist_all_live(state)
    {:noreply, state}
  end

  @impl true
  def handle_info(:persist_live, state) do
    do_persist_all_live(state)
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

  defp do_persist_all_live(state) do
    DynamicSupervisor.which_children(Kudzu.HologramSupervisor)
    |> Enum.map(fn {_, pid, _, _} -> pid end)
    |> Enum.filter(&is_pid/1)
    |> Enum.each(fn pid ->
      try do
        s = Kudzu.Hologram.get_state(pid)
        metadata = %{
          id: s.id,
          purpose: s.purpose,
          constitution: s.constitution,
          desires: s.desires,
          cognition_enabled: s.cognition_enabled,
          cognition_model: s.cognition_model,
          peers: s.peers,
          last_persisted_at: DateTime.utc_now()
        }
        :dets.insert(state.dets, {s.id, metadata})
      catch
        :exit, _ -> :ok
      end
    end)

    :dets.sync(state.dets)
  end
end
