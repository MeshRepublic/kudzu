defmodule KudzuWeb.NodeController do
  @moduledoc """
  API controller for Kudzu Node management.

  Handles mesh connectivity, storage tiers, and node capabilities.
  """

  use Phoenix.Controller
  alias Kudzu.Node

  @doc """
  Get node status including storage tiers and mesh connectivity.
  GET /api/v1/node
  """
  def status(conn, _params) do
    json(conn, Node.status())
  end

  @doc """
  Initialize this node for Kudzu operation.
  POST /api/v1/node/init
  """
  def init(conn, params) do
    opts = []
    opts = if params["data_dir"], do: [{:data_dir, params["data_dir"]} | opts], else: opts

    case Node.init_node(opts) do
      :ok ->
        json(conn, %{status: "initialized", node: node()})
      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: inspect(reason)})
    end
  end

  @doc """
  Create a new mesh with this node as the seed.
  POST /api/v1/node/mesh/create
  """
  def create_mesh(conn, _params) do
    case Node.create_mesh() do
      :ok ->
        json(conn, %{status: "mesh_created", seed_node: node()})
      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: inspect(reason)})
    end
  end

  @doc """
  Join an existing mesh.
  POST /api/v1/node/mesh/join
  Body: {"peer": "kudzu@titan"}
  """
  def join_mesh(conn, %{"peer" => peer}) do
    peer_node = String.to_atom(peer)

    case Node.join_mesh(peer_node) do
      {:ok, status} ->
        json(conn, %{status: "joined", mesh_status: status, peers: Node.mesh_peers()})
      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: inspect(reason)})
    end
  end

  def join_mesh(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "Missing 'peer' parameter"})
  end

  @doc """
  Leave the mesh (continue operating locally).
  POST /api/v1/node/mesh/leave
  """
  def leave_mesh(conn, _params) do
    Node.leave_mesh()
    json(conn, %{status: "standalone", peers: []})
  end

  @doc """
  List mesh peers.
  GET /api/v1/node/mesh/peers
  """
  def mesh_peers(conn, _params) do
    peers = Node.mesh_peers()
    json(conn, %{
      connected: Node.mesh_connected?(),
      peer_count: length(peers),
      peers: Enum.map(peers, &to_string/1)
    })
  end

  @doc """
  Get storage statistics for all tiers.
  GET /api/v1/node/storage
  """
  def storage_stats(conn, _params) do
    json(conn, Kudzu.storage_stats())
  end

  @doc """
  Get node capabilities (compute, storage, network).
  GET /api/v1/node/capabilities
  """
  def capabilities(conn, _params) do
    json(conn, Node.capabilities())
  end
end
