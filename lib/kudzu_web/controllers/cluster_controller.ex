defmodule KudzuWeb.ClusterController do
  use Phoenix.Controller

  alias Kudzu.Distributed

  @doc """
  Get cluster overview.
  GET /api/v1/cluster
  """
  def index(conn, _params) do
    json(conn, %{
      node: Node.self(),
      distributed: Distributed.distributed?(),
      connected_nodes: Distributed.nodes(),
      node_count: length(Distributed.nodes()) + 1
    })
  end

  @doc """
  List all nodes in the cluster.
  GET /api/v1/cluster/nodes
  """
  def nodes(conn, _params) do
    all_nodes = [Node.self() | Distributed.nodes()]

    nodes_info = Enum.map(all_nodes, fn node ->
      %{
        name: node,
        self: node == Node.self(),
        hologram_count: count_holograms(node)
      }
    end)

    json(conn, %{nodes: nodes_info})
  end

  @doc """
  Connect to a remote node.
  POST /api/v1/cluster/connect
  """
  def connect(conn, %{"node" => node_name}) do
    case Distributed.connect(node_name) do
      true ->
        json(conn, %{connected: true, node: node_name})

      false ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{connected: false, error: "Failed to connect"})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{connected: false, error: inspect(reason)})
    end
  end

  @doc """
  Get cluster-wide statistics.
  GET /api/v1/cluster/stats
  """
  def stats(conn, _params) do
    if Distributed.distributed?() do
      stats = Distributed.cluster_stats()
      json(conn, %{stats: stats})
    else
      # Local stats only
      local_holograms = Registry.select(Kudzu.Registry, [{{{:id, :_}, :_, :_}, [], [true]}])
      |> length()

      json(conn, %{
        stats: %{
          nodes: 1,
          total_holograms: local_holograms,
          per_node: %{
            Node.self() => %{
              hologram_count: local_holograms,
              ollama_available: Kudzu.Cognition.available?()
            }
          }
        }
      })
    end
  end

  defp count_holograms(node) do
    if node == Node.self() do
      Registry.select(Kudzu.Registry, [{{{:id, :_}, :_, :_}, [], [true]}])
      |> length()
    else
      try do
        Distributed.list_holograms(node) |> length()
      rescue
        _ -> 0
      end
    end
  end
end
