defmodule KudzuWeb.MCP.Handlers.Cluster do
  @moduledoc "MCP handlers for cluster tools."

  def handle("kudzu_cluster_status", _params) do
    {:ok, %{
      node: to_string(Node.self()),
      distributed: Node.alive?(),
      connected_nodes: Enum.map(Node.list(), &to_string/1),
      node_count: length(Node.list()) + 1
    }}
  end

  def handle("kudzu_cluster_nodes", _params) do
    nodes = [Node.self() | Node.list()] |> Enum.map(&to_string/1)
    {:ok, %{nodes: nodes}}
  end

  def handle("kudzu_cluster_connect", %{"node" => node_str}) do
    node = String.to_atom(node_str)
    case Node.connect(node) do
      true -> {:ok, %{connected: true, node: node_str}}
      false -> {:error, -32603, "Failed to connect to #{node_str}"}
      :ignored -> {:error, -32603, "Node not alive — start with --name or --sname"}
    end
  end

  def handle("kudzu_cluster_stats", _params) do
    {:ok, %{
      node: to_string(Node.self()),
      nodes: length(Node.list()) + 1,
      holograms: Kudzu.Application.hologram_count(),
      processes: length(Process.list()),
      memory_mb: Float.round(:erlang.memory(:total) / 1_048_576, 1)
    }}
  end
end
