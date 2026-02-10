defmodule Kudzu do
  @moduledoc """
  Kudzu - A distributed agent architecture for navigational memory.

  Kudzu inverts traditional knowledge graphs. Instead of nodes (facts) connected
  by edges (relationships), the path of encounter is primary:

  - That something was recorded
  - Why it was recorded (purpose/context)
  - Where it was placed (proximity relationships)
  - How to navigate back to reconstruct it

  ## Core Concepts

  ### Traces
  The base primitive. A trace records navigation paths, not facts:

      trace = Kudzu.Trace.new("agent-1", :user_preference, ["agent-1"], %{key: "theme"})

  ### Holograms
  Self-aware context agents with embedded peer references:

      {:ok, hologram} = Kudzu.spawn_hologram(purpose: :memory)
      Kudzu.Hologram.record_trace(hologram, :interaction, %{with: "user-123"})

  ### Protocol
  Message types for inter-hologram communication:
  - :ping / :pong - liveness and discovery
  - :query / :query_response - search for traces by purpose
  - :trace_share / :ack - propagate traces through the network
  - :reconstruction_request / :reconstruction_response - retrieve specific traces

  ## Architecture

  Kudzu uses a flat agent mesh rather than traditional layered architecture:

      Hardware → Thin HAL → Agent Mesh (runtime, services, application unified)

  Each hologram can navigate to relevant context elsewhere in the system
  without holding full copies. Context recovery becomes reconstruction via
  trace-following, not retrieval from storage.
  """

  alias Kudzu.{Application, Hologram, Trace, VectorClock, Protocol, Storage}

  # Hologram management
  defdelegate spawn_hologram(opts \\ []), to: Application
  defdelegate spawn_holograms(count, opts \\ []), to: Application
  defdelegate stop_hologram(pid), to: Application
  defdelegate find_by_id(id), to: Application
  defdelegate find_by_purpose(purpose), to: Application
  defdelegate hologram_count(), to: Application
  defdelegate list_holograms(), to: Application

  @doc """
  Create a network of interconnected holograms.
  Each hologram is randomly connected to `connections_per_node` peers.
  """
  @spec create_network(non_neg_integer(), non_neg_integer(), keyword()) :: [{String.t(), pid()}]
  def create_network(size, connections_per_node \\ 5, opts \\ []) do
    # Spawn all holograms
    holograms = spawn_holograms(size, opts)

    # Create random connections
    holograms
    |> Task.async_stream(
      fn {_id, pid} ->
        peers = holograms
        |> Enum.reject(fn {_, p} -> p == pid end)
        |> Enum.take_random(min(connections_per_node, length(holograms) - 1))

        Enum.each(peers, fn {peer_id, _peer_pid} ->
          Hologram.introduce_peer(pid, peer_id)
        end)
      end,
      max_concurrency: System.schedulers_online() * 2,
      ordered: false
    )
    |> Stream.run()

    holograms
  end

  @doc """
  Broadcast a trace to all holograms matching a purpose.
  """
  @spec broadcast_trace(Trace.t(), atom() | String.t()) :: non_neg_integer()
  def broadcast_trace(trace, target_purpose) do
    find_by_purpose(target_purpose)
    |> Enum.map(fn {pid, _id} ->
      Hologram.receive_trace(pid, trace, trace.origin)
    end)
    |> length()
  end

  @doc """
  Query the network for traces matching a purpose, starting from a specific hologram.
  Uses gossip-style propagation with hop limiting.
  """
  @spec network_query(pid() | String.t(), atom() | String.t(), keyword()) :: [Trace.t()]
  def network_query(start, purpose, opts \\ []) do
    max_hops = Keyword.get(opts, :max_hops, 3)
    max_results = Keyword.get(opts, :max_results, 100)

    start_pid = case start do
      pid when is_pid(pid) -> pid
      id when is_binary(id) ->
        case find_by_id(id) do
          {:ok, pid} -> pid
          _ -> nil
        end
    end

    if start_pid do
      do_network_query(start_pid, purpose, max_hops, max_results, MapSet.new())
    else
      []
    end
  end

  defp do_network_query(_pid, _purpose, 0, _max, _visited), do: []
  defp do_network_query(pid, purpose, hops, max, visited) do
    id = Hologram.get_id(pid)

    if MapSet.member?(visited, id) do
      []
    else
      visited = MapSet.put(visited, id)

      # Get local traces
      local = Hologram.recall(pid, purpose)

      if length(local) >= max do
        Enum.take(local, max)
      else
        # Query peers
        peers = Hologram.get_peers(pid)
        |> Enum.sort_by(fn {_, score} -> score end, :desc)
        |> Enum.take(5)
        |> Enum.map(fn {peer_id, _} -> peer_id end)

        peer_results = peers
        |> Enum.flat_map(fn peer_id ->
          case find_by_id(peer_id) do
            {:ok, peer_pid} ->
              do_network_query(peer_pid, purpose, hops - 1, max - length(local), visited)
            _ ->
              []
          end
        end)

        (local ++ peer_results) |> Enum.take(max)
      end
    end
  end

  # ============================================================================
  # Mesh Management - SETI-style distributed memory
  # ============================================================================

  @doc """
  Initialize this node for mesh participation.
  Sets up Mnesia and prepares for distributed storage.
  """
  def init_mesh_node do
    Storage.MnesiaSchema.init_node()
  end

  @doc """
  Create the mesh schema across the given nodes.
  Run this once when setting up a new mesh.

  ## Example

      # On first node
      Kudzu.create_mesh([:"kudzu@titan", :"kudzu@radiator"])
  """
  def create_mesh(nodes) when is_list(nodes) do
    Storage.MnesiaSchema.create_schema(nodes)
  end

  @doc """
  Join an existing mesh.
  Run this on new nodes to join an established mesh.

  ## Example

      # On new node
      Kudzu.join_mesh(:"kudzu@titan")
  """
  def join_mesh(existing_node) do
    Storage.MnesiaSchema.join_mesh(existing_node)
  end

  @doc """
  Get mesh status including all connected nodes and storage stats.
  """
  def mesh_status do
    %{
      node: node(),
      connected_nodes: Node.list(),
      storage: Storage.stats(),
      cold_storage: Storage.MnesiaSchema.stats(),
      holograms: hologram_count()
    }
  end

  @doc """
  Get all nodes in the mesh.
  """
  def mesh_nodes do
    [node() | Node.list()]
  end

  # ============================================================================
  # Storage Delegation
  # ============================================================================

  @doc """
  Store a trace with optional importance level.
  Importance affects aging: :critical traces stay hot longer.
  """
  def store_trace(trace, hologram_id, importance \\ :normal) do
    Storage.store(trace, hologram_id, importance)
  end

  @doc """
  Retrieve a trace by ID from any tier.
  """
  def retrieve_trace(trace_id) do
    Storage.retrieve(trace_id)
  end

  @doc """
  Query traces by purpose across all tiers and mesh nodes.
  """
  def query_traces(purpose, opts \\ []) do
    Storage.query(purpose, opts)
  end

  @doc """
  Get storage statistics.
  """
  def storage_stats do
    Storage.stats()
  end

  @doc """
  Force aging cycle (move hot→warm→cold based on access patterns).
  """
  def age_traces do
    Storage.age_traces()
  end
end
