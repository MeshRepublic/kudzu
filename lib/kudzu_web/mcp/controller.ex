defmodule KudzuWeb.MCP.Controller do
  @moduledoc """
  MCP JSON-RPC 2.0 dispatch controller.

  Every dispatch carries the caller's API key scope (`:read` or `:mutate`,
  see `KudzuWeb.Plugs.APIAuth`). Tools are default-deny: only tools listed
  in `@read_tools` may be called with a read key; every other tool —
  including any tool added in future without updating this list —
  requires `:mutate`. `tools/list` only advertises tools the caller may call.
  """

  alias KudzuWeb.MCP.{Protocol, Tools}
  alias KudzuWeb.Plugs.APIAuth

  alias KudzuWeb.MCP.Handlers.{
    Agent,
    Beamlet,
    Brain,
    Cluster,
    Constitution,
    Hologram,
    Node,
    Semantic,
    System,
    Trace,
    Web
  }

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
    "kudzu_list_holograms" => Hologram,
    "kudzu_create_hologram" => Hologram,
    "kudzu_get_hologram" => Hologram,
    "kudzu_delete_hologram" => Hologram,
    "kudzu_stimulate_hologram" => Hologram,
    "kudzu_hologram_traces" => Hologram,
    "kudzu_record_trace" => Hologram,
    "kudzu_hologram_peers" => Hologram,
    "kudzu_add_hologram_peer" => Hologram,
    "kudzu_get_hologram_constitution" => Hologram,
    "kudzu_set_hologram_constitution" => Hologram,
    "kudzu_get_hologram_desires" => Hologram,
    "kudzu_add_hologram_desire" => Hologram,
    "kudzu_list_traces" => Trace,
    "kudzu_get_trace" => Trace,
    "kudzu_share_trace" => Trace,
    "kudzu_create_agent" => Agent,
    "kudzu_get_agent" => Agent,
    "kudzu_delete_agent" => Agent,
    "kudzu_agent_remember" => Agent,
    "kudzu_agent_learn" => Agent,
    "kudzu_agent_think" => Agent,
    "kudzu_agent_observe" => Agent,
    "kudzu_agent_decide" => Agent,
    "kudzu_agent_recall" => Agent,
    "kudzu_agent_stimulate" => Agent,
    "kudzu_agent_desires" => Agent,
    "kudzu_agent_add_desire" => Agent,
    "kudzu_agent_peers" => Agent,
    "kudzu_agent_connect_peer" => Agent,
    "kudzu_list_constitutions" => Constitution,
    "kudzu_get_constitution_details" => Constitution,
    "kudzu_check_constitution" => Constitution,
    "kudzu_cluster_status" => Cluster,
    "kudzu_cluster_nodes" => Cluster,
    "kudzu_cluster_connect" => Cluster,
    "kudzu_cluster_stats" => Cluster,
    "kudzu_node_status" => Node,
    "kudzu_node_init" => Node,
    "kudzu_mesh_create" => Node,
    "kudzu_mesh_join" => Node,
    "kudzu_mesh_leave" => Node,
    "kudzu_mesh_peers" => Node,
    "kudzu_node_capabilities" => Node,
    "kudzu_list_beamlets" => Beamlet,
    "kudzu_get_beamlet" => Beamlet,
    "kudzu_find_beamlets" => Beamlet,
    "kudzu_semantic_recall" => Semantic,
    "kudzu_associations" => Semantic,
    "kudzu_vocabulary" => Semantic,
    "kudzu_encoder_stats" => Semantic,
    "kudzu_brain_chat" => Brain,
    "kudzu_brain_status" => Brain,
    "kudzu_web_search" => Web,
    "kudzu_web_read" => Web
  }

  # Tools a read-scoped key may call: list / get / check operations with no
  # state change, no LLM spend, and no outbound network access.
  @read_tools MapSet.new([
                "kudzu_health",
                "kudzu_list_holograms",
                "kudzu_get_hologram",
                "kudzu_hologram_traces",
                "kudzu_hologram_peers",
                "kudzu_get_hologram_constitution",
                "kudzu_get_hologram_desires",
                "kudzu_list_traces",
                "kudzu_get_trace",
                "kudzu_get_agent",
                "kudzu_agent_recall",
                "kudzu_agent_desires",
                "kudzu_agent_peers",
                "kudzu_list_constitutions",
                "kudzu_get_constitution_details",
                "kudzu_check_constitution",
                "kudzu_cluster_status",
                "kudzu_cluster_nodes",
                "kudzu_cluster_stats",
                "kudzu_node_status",
                "kudzu_mesh_peers",
                "kudzu_node_capabilities",
                "kudzu_list_beamlets",
                "kudzu_get_beamlet",
                "kudzu_find_beamlets",
                "kudzu_semantic_recall",
                "kudzu_associations",
                "kudzu_vocabulary",
                "kudzu_encoder_stats",
                "kudzu_brain_status"
              ])

  @forbidden_code -32_003

  # --- Public API ---

  @doc "All tool names this server can dispatch."
  @spec tool_names() :: [String.t()]
  def tool_names, do: Map.keys(@handler_map)

  @doc "Scope required to call `tool_name`. Unknown and unlisted tools require `:mutate`."
  @spec required_scope(String.t()) :: KudzuWeb.Plugs.APIAuth.scope()
  def required_scope(tool_name) do
    if MapSet.member?(@read_tools, tool_name), do: :read, else: :mutate
  end

  def dispatch({:request, id, "initialize", params}, _scope) do
    result = %{
      "protocolVersion" => Map.get(params, "protocolVersion", @protocol_version),
      "capabilities" => @capabilities,
      "serverInfo" => @server_info
    }

    {:response, Protocol.encode_response(id, result)}
  end

  def dispatch({:request, id, "ping", _params}, _scope) do
    {:response, Protocol.encode_response(id, %{})}
  end

  def dispatch({:request, id, "tools/list", _params}, scope) do
    tools =
      Tools.list()
      |> Enum.filter(&APIAuth.permits?(scope, required_scope(&1.name)))
      |> Enum.map(fn t ->
        %{"name" => t.name, "description" => t.description, "inputSchema" => t.inputSchema}
      end)

    {:response, Protocol.encode_response(id, %{"tools" => tools})}
  end

  def dispatch({:request, id, "tools/call", %{"name" => tool_name} = params}, scope) do
    arguments = Map.get(params, "arguments", %{})
    required = required_scope(tool_name)

    case Map.get(@handler_map, tool_name) do
      nil ->
        {:response, Protocol.encode_error(id, -32_602, "Unknown tool: #{tool_name}")}

      _handler when required == :mutate and scope != :mutate ->
        {:response,
         Protocol.encode_error(
           id,
           @forbidden_code,
           "Forbidden: #{tool_name} requires mutate scope; this API key is #{scope}-only"
         )}

      handler ->
        try do
          case handler.handle(tool_name, arguments) do
            {:ok, result} ->
              text = Jason.encode!(result, pretty: true)

              {:response,
               Protocol.encode_response(id, %{
                 "content" => [%{"type" => "text", "text" => text}]
               })}

            {:error, _code, message} ->
              {:response,
               Protocol.encode_response(id, %{
                 "content" => [%{"type" => "text", "text" => "Error: #{message}"}],
                 "isError" => true
               })}
          end
        rescue
          e ->
            {:response,
             Protocol.encode_response(id, %{
               "content" => [%{"type" => "text", "text" => "Internal error: #{inspect(e)}"}],
               "isError" => true
             })}
        end
    end
  end

  def dispatch({:request, id, method, _params}, _scope) do
    {:response, Protocol.encode_error(id, -32_601, "Method not found: #{method}")}
  end

  def dispatch({:notification, "initialized", _params}, _scope) do
    :accepted
  end

  def dispatch({:notification, "notifications/cancelled", _params}, _scope) do
    :accepted
  end

  def dispatch({:notification, _method, _params}, _scope) do
    :accepted
  end

  def dispatch({:batch, items}, scope) do
    results = Enum.map(items, &dispatch(&1, scope))

    responses =
      Enum.filter(results, fn
        {:response, _} -> true
        _ -> false
      end)
      |> Enum.map(fn {:response, r} -> r end)

    {:batch_response, responses}
  end
end
