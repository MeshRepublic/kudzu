defmodule KudzuWeb.MCP.Handlers.Node do
  @moduledoc "MCP handlers for node/mesh tools."

  def handle("kudzu_node_status", _params) do
    {:ok, Kudzu.Node.status()}
  end

  def handle("kudzu_node_init", params) do
    opts = []
    opts = if params["data_dir"], do: [{:data_dir, params["data_dir"]} | opts], else: opts
    opts = if params["node_name"], do: [{:node_name, params["node_name"]} | opts], else: opts
    case Kudzu.Node.init_node(opts) do
      :ok -> {:ok, %{status: "initialized"}}
      {:error, reason} -> {:error, -32603, inspect(reason)}
    end
  end

  def handle("kudzu_mesh_create", _params) do
    case Kudzu.Node.create_mesh() do
      :ok -> {:ok, %{status: "mesh_created"}}
      {:error, reason} -> {:error, -32603, inspect(reason)}
    end
  end

  def handle("kudzu_mesh_join", %{"node" => node_str}) do
    node = String.to_atom(node_str)
    case Kudzu.Node.join_mesh(node) do
      {:ok, status} -> {:ok, %{status: status}}
      {:error, reason} -> {:error, -32603, inspect(reason)}
    end
  end

  def handle("kudzu_mesh_leave", _params) do
    Kudzu.Node.leave_mesh()
    {:ok, %{status: "left_mesh"}}
  end

  def handle("kudzu_mesh_peers", _params) do
    {:ok, %{peers: Enum.map(Kudzu.Node.mesh_peers(), &to_string/1)}}
  end

  def handle("kudzu_node_capabilities", _params) do
    {:ok, Kudzu.Node.capabilities()}
  end
end
