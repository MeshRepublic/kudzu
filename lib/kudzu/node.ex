defmodule Kudzu.Node do
  @moduledoc """
  Kudzu Node - Full-stack distributed memory for any AI agent.

  Each device runs a complete Kudzu node with all storage tiers:
  - HOT (ETS): Sub-millisecond access, current session
  - WARM (DETS): Persistent local storage, survives restarts
  - COLD (Mnesia): Distributed across mesh, queryable everywhere

  ## Architecture

  ```
  ┌─────────────────────────────────────────────────────────────┐
  │                     YOUR DEVICE                             │
  ├─────────────────────────────────────────────────────────────┤
  │  Local AI Agent (Claude, Ollama, LLaMA, etc)                │
  │       ↓ HTTP API (localhost:4000)                           │
  │  ┌─────────────────────────────────────────────────────┐   │
  │  │  Kudzu Node                                          │   │
  │  │  ┌─────────┐  ┌─────────┐  ┌──────────────────┐     │   │
  │  │  │ HOT     │→ │ WARM    │→ │ COLD             │     │   │
  │  │  │ (ETS)   │  │ (DETS)  │  │ (Mnesia local +  │     │   │
  │  │  │ <1ms    │  │ local   │  │  mesh fragments) │     │   │
  │  │  └─────────┘  └─────────┘  └────────┬─────────┘     │   │
  │  └─────────────────────────────────────│───────────────┘   │
  └────────────────────────────────────────│───────────────────┘
                                           │
              ┌────────────────────────────┴────────────────────────┐
              │              Erlang Distribution (Mesh)             │
              │                (Tailscale / LAN / VPN)              │
              └────────────────────────────┬────────────────────────┘
                                           │
       ┌───────────────┬───────────────────┼───────────────────┬───────────────┐
       ▼               ▼                   ▼                   ▼               ▼
   [titan]        [radiator]           [laptop]            [phone]         [cloud]
   Full Node      Full Node            Full Node           Full Node       Full Node
  ```

  ## Self-Sufficiency

  Each node operates fully offline. The mesh enhances but isn't required:
  - Local AI agents always have fast access to hot/warm tiers
  - Cold tier stores locally when offline, syncs when connected
  - Mesh queries span all connected nodes transparently

  ## Usage

  ```elixir
  # Initialize node (do once per device)
  Kudzu.Node.init()

  # Join the mesh (optional, for distributed memory)
  Kudzu.Node.join_mesh(:"kudzu@titan")

  # Use normally - storage tiers are automatic
  Kudzu.spawn_hologram(purpose: :my_agent)
  ```
  """

  use GenServer
  require Logger

  alias Kudzu.Storage
  alias Kudzu.Storage.MnesiaSchema

  @default_data_dir "~/.kudzu"

  defstruct [
    :node_id,
    :data_dir,
    :mesh_status,
    :connected_peers,
    :local_capabilities,
    :started_at
  ]

  # ============================================================================
  # Client API
  # ============================================================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Initialize this device as a Kudzu node.
  Sets up all storage tiers for local operation.

  ## Options
    - :data_dir - Where to store data (default: ~/.kudzu)
    - :node_name - Erlang node name (default: kudzu@hostname)
  """
  def init_node(opts \\ []) do
    GenServer.call(__MODULE__, {:init_node, opts}, 30_000)
  end

  @doc """
  Join an existing Kudzu mesh.
  Enables distributed cold storage and cross-node queries.

  ## Example
      Kudzu.Node.join_mesh(:"kudzu@titan")
  """
  def join_mesh(peer_node) do
    GenServer.call(__MODULE__, {:join_mesh, peer_node}, 30_000)
  end

  @doc """
  Leave the mesh (continue operating locally).
  """
  def leave_mesh do
    GenServer.call(__MODULE__, :leave_mesh)
  end

  @doc """
  Create a new mesh with this node as the seed.
  Other nodes can then join via join_mesh/1.
  """
  def create_mesh do
    GenServer.call(__MODULE__, :create_mesh, 30_000)
  end

  @doc """
  Get node status including all tiers and mesh connectivity.
  """
  def status do
    GenServer.call(__MODULE__, :status)
  end

  @doc """
  Store a trace - automatically uses tiered storage.
  """
  def store(trace, hologram_id, opts \\ []) do
    importance = Keyword.get(opts, :importance, :normal)
    replicate = Keyword.get(opts, :replicate, false)

    # Store in hot tier
    Storage.store(trace, hologram_id, importance)

    # Optionally replicate to mesh immediately (for critical data)
    if replicate and mesh_connected?() do
      replicate_to_mesh(trace)
    end

    :ok
  end

  @doc """
  Retrieve a trace - checks all tiers, local first then mesh.
  """
  def retrieve(trace_id, opts \\ []) do
    check_mesh = Keyword.get(opts, :check_mesh, true)

    case Storage.retrieve(trace_id) do
      {:hot, record} -> {:ok, record, :hot}
      {:warm, record} -> {:ok, record, :warm}
      {:cold, record} -> {:ok, record, :cold}
      :not_found when check_mesh ->
        query_mesh_for_trace(trace_id)
      :not_found ->
        :not_found
    end
  end

  @doc """
  Query traces by purpose across all tiers and mesh.
  """
  def query(purpose, opts \\ []) do
    local_results = Storage.query(purpose, opts)

    mesh_results =
      if Keyword.get(opts, :include_mesh, true) and mesh_connected?() do
        query_mesh(purpose, opts)
      else
        []
      end

    # Deduplicate by trace ID
    (local_results ++ mesh_results)
    |> Enum.uniq_by(& &1.id)
    |> Enum.take(Keyword.get(opts, :limit, 100))
  end

  @doc """
  Check if connected to mesh.
  """
  def mesh_connected? do
    length(Node.list()) > 0
  end

  @doc """
  List all mesh peers.
  """
  def mesh_peers do
    Node.list()
  end

  @doc """
  Get capabilities of this node.
  """
  def capabilities do
    GenServer.call(__MODULE__, :capabilities)
  end

  # ============================================================================
  # Server Implementation
  # ============================================================================

  @impl true
  def init(opts) do
    data_dir = Keyword.get(opts, :data_dir, @default_data_dir) |> Path.expand()

    state = %__MODULE__{
      node_id: generate_node_id(),
      data_dir: data_dir,
      mesh_status: :standalone,
      connected_peers: [],
      local_capabilities: detect_capabilities(),
      started_at: DateTime.utc_now()
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:init_node, opts}, _from, state) do
    data_dir = Keyword.get(opts, :data_dir, state.data_dir) |> Path.expand()

    # Ensure directories exist
    File.mkdir_p!(Path.join(data_dir, "dets"))
    File.mkdir_p!(Path.join(data_dir, "mnesia"))

    # Initialize Mnesia for local cold storage
    result = MnesiaSchema.init_node()

    new_state = %{state |
      data_dir: data_dir,
      mesh_status: :initialized
    }

    Logger.info("Kudzu node initialized at #{data_dir}")
    {:reply, result, new_state}
  end

  @impl true
  def handle_call({:join_mesh, peer_node}, _from, state) do
    Logger.info("Attempting to join mesh via #{peer_node}")

    result = case Node.connect(peer_node) do
      true ->
        # Connected, now join Mnesia cluster
        case MnesiaSchema.join_mesh(peer_node) do
          :ok ->
            Logger.info("Successfully joined mesh")
            {:ok, :joined}
          {:error, reason} ->
            Logger.warning("Joined nodes but Mnesia sync failed: #{inspect(reason)}")
            {:ok, :partial}
        end
      false ->
        Logger.error("Could not connect to #{peer_node}")
        {:error, :connection_failed}
    end

    new_state = %{state |
      mesh_status: if(match?({:ok, _}, result), do: :connected, else: state.mesh_status),
      connected_peers: Node.list()
    }

    {:reply, result, new_state}
  end

  @impl true
  def handle_call(:leave_mesh, _from, state) do
    # Disconnect from all peers
    Enum.each(Node.list(), &Node.disconnect/1)

    new_state = %{state |
      mesh_status: :standalone,
      connected_peers: []
    }

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:create_mesh, _from, state) do
    result = MnesiaSchema.create_schema([node()])

    new_state = %{state | mesh_status: :mesh_seed}

    {:reply, result, new_state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      node_id: state.node_id,
      node_name: node(),
      data_dir: state.data_dir,
      mesh_status: state.mesh_status,
      connected_peers: Node.list(),
      peer_count: length(Node.list()),
      uptime_seconds: DateTime.diff(DateTime.utc_now(), state.started_at),
      storage: %{
        hot: Storage.stats().hot,
        warm: Storage.stats().warm,
        cold: Storage.stats().cold
      },
      capabilities: state.local_capabilities
    }

    {:reply, status, %{state | connected_peers: Node.list()}}
  end

  @impl true
  def handle_call(:capabilities, _from, state) do
    {:reply, state.local_capabilities, state}
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp generate_node_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  defp detect_capabilities do
    %{
      storage: %{
        hot: true,
        warm: true,
        cold: true
      },
      compute: %{
        ollama: check_ollama(),
        gpu: check_gpu()
      },
      network: %{
        tailscale: check_tailscale()
      }
    }
  end

  defp check_ollama do
    case System.cmd("which", ["ollama"], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp check_gpu do
    case System.cmd("nvidia-smi", [], stderr_to_stdout: true) do
      {_, 0} -> :nvidia
      _ ->
        case System.cmd("rocm-smi", [], stderr_to_stdout: true) do
          {_, 0} -> :amd
          _ -> false
        end
    end
  rescue
    _ -> false
  end

  defp check_tailscale do
    case System.cmd("tailscale", ["status"], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp replicate_to_mesh(trace) do
    # Async replicate to connected peers
    Task.start(fn ->
      Enum.each(Node.list(), fn peer ->
        :rpc.cast(peer, Kudzu.Storage.MnesiaSchema, :store, [trace])
      end)
    end)
  end

  defp query_mesh_for_trace(trace_id) do
    # Query each peer for the trace
    results =
      Node.list()
      |> Enum.map(fn peer ->
        Task.async(fn ->
          :rpc.call(peer, Kudzu.Storage.MnesiaSchema, :retrieve, [trace_id], 5_000)
        end)
      end)
      |> Enum.map(&Task.await(&1, 6_000))
      |> Enum.find(fn
        {:ok, _record} -> true
        _ -> false
      end)

    case results do
      {:ok, record} -> {:ok, record, :mesh}
      _ -> :not_found
    end
  rescue
    _ -> :not_found
  end

  defp query_mesh(purpose, opts) do
    limit = Keyword.get(opts, :limit, 100)

    Node.list()
    |> Enum.flat_map(fn peer ->
      case :rpc.call(peer, Kudzu.Storage.MnesiaSchema, :query_by_purpose, [purpose, limit], 10_000) do
        results when is_list(results) -> results
        _ -> []
      end
    end)
  rescue
    _ -> []
  end
end
