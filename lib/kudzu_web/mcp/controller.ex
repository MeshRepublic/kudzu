defmodule KudzuWeb.MCP.Controller do
  @moduledoc "MCP JSON-RPC 2.0 dispatch controller."

  alias KudzuWeb.MCP.{Protocol, Tools}
  alias KudzuWeb.MCP.Handlers.{System, Hologram, Trace, Agent, Constitution, Cluster, Node, Beamlet}

  @protocol_version "2025-03-26"

  @server_info %{
    "name" => "kudzu",
    "version" => "0.1.0"
  }

  @capabilities %{
    "tools" => %{"listChanged" => false}
  }

  @handler_map %{
    "kudzu_health" => System,
    "kudzu_list_holograms" => Hologram, "kudzu_create_hologram" => Hologram,
    "kudzu_get_hologram" => Hologram, "kudzu_delete_hologram" => Hologram,
    "kudzu_stimulate_hologram" => Hologram, "kudzu_hologram_traces" => Hologram,
    "kudzu_record_trace" => Hologram, "kudzu_hologram_peers" => Hologram,
    "kudzu_add_hologram_peer" => Hologram, "kudzu_get_hologram_constitution" => Hologram,
    "kudzu_set_hologram_constitution" => Hologram, "kudzu_get_hologram_desires" => Hologram,
    "kudzu_add_hologram_desire" => Hologram,
    "kudzu_list_traces" => Trace, "kudzu_get_trace" => Trace, "kudzu_share_trace" => Trace,
    "kudzu_create_agent" => Agent, "kudzu_get_agent" => Agent, "kudzu_delete_agent" => Agent,
    "kudzu_agent_remember" => Agent, "kudzu_agent_learn" => Agent, "kudzu_agent_think" => Agent,
    "kudzu_agent_observe" => Agent, "kudzu_agent_decide" => Agent, "kudzu_agent_recall" => Agent,
    "kudzu_agent_stimulate" => Agent, "kudzu_agent_desires" => Agent,
    "kudzu_agent_add_desire" => Agent, "kudzu_agent_peers" => Agent,
    "kudzu_agent_connect_peer" => Agent,
    "kudzu_list_constitutions" => Constitution, "kudzu_get_constitution_details" => Constitution,
    "kudzu_check_constitution" => Constitution,
    "kudzu_cluster_status" => Cluster, "kudzu_cluster_nodes" => Cluster,
    "kudzu_cluster_connect" => Cluster, "kudzu_cluster_stats" => Cluster,
    "kudzu_node_status" => Node, "kudzu_node_init" => Node,
    "kudzu_mesh_create" => Node, "kudzu_mesh_join" => Node,
    "kudzu_mesh_leave" => Node, "kudzu_mesh_peers" => Node,
    "kudzu_node_capabilities" => Node,
    "kudzu_list_beamlets" => Beamlet, "kudzu_get_beamlet" => Beamlet,
    "kudzu_find_beamlets" => Beamlet
  }

  # --- Public API ---

  def dispatch({:request, id, "initialize", params}) do
    result = %{
      "protocolVersion" => Map.get(params, "protocolVersion", @protocol_version),
      "capabilities" => @capabilities,
      "serverInfo" => @server_info
    }
    {:response, Protocol.encode_response(id, result)}
  end

  def dispatch({:request, id, "ping", _params}) do
    {:response, Protocol.encode_response(id, %{})}
  end

  def dispatch({:request, id, "tools/list", _params}) do
    tools = Tools.list() |> Enum.map(fn t ->
      %{"name" => t.name, "description" => t.description, "inputSchema" => t.inputSchema}
    end)
    {:response, Protocol.encode_response(id, %{"tools" => tools})}
  end

  def dispatch({:request, id, "tools/call", %{"name" => tool_name} = params}) do
    arguments = Map.get(params, "arguments", %{})

    case Map.get(@handler_map, tool_name) do
      nil ->
        {:response, Protocol.encode_error(id, -32602, "Unknown tool: #{tool_name}")}

      handler ->
        try do
          case handler.handle(tool_name, arguments) do
            {:ok, result} ->
              text = Jason.encode!(result, pretty: true)
              {:response, Protocol.encode_response(id, %{
                "content" => [%{"type" => "text", "text" => text}]
              })}

            {:error, _code, message} ->
              {:response, Protocol.encode_response(id, %{
                "content" => [%{"type" => "text", "text" => "Error: #{message}"}],
                "isError" => true
              })}
          end
        rescue
          e ->
            {:response, Protocol.encode_response(id, %{
              "content" => [%{"type" => "text", "text" => "Internal error: #{inspect(e)}"}],
              "isError" => true
            })}
        end
    end
  end

  def dispatch({:request, id, method, _params}) do
    {:response, Protocol.encode_error(id, -32601, "Method not found: #{method}")}
  end

  def dispatch({:notification, "initialized", _params}) do
    :accepted
  end

  def dispatch({:notification, "notifications/cancelled", _params}) do
    :accepted
  end

  def dispatch({:notification, _method, _params}) do
    :accepted
  end

  def dispatch({:batch, items}) do
    results = Enum.map(items, &dispatch/1)
    responses = Enum.filter(results, fn
      {:response, _} -> true
      _ -> false
    end) |> Enum.map(fn {:response, r} -> r end)
    {:batch_response, responses}
  end
end
