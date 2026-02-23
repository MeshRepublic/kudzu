defmodule KudzuWeb.MCP.Handlers.Agent do
  @moduledoc "MCP handlers for agent tools."

  alias Kudzu.Agent

  def handle("kudzu_create_agent", %{"name" => name} = params) do
    opts = []
    opts = if params["desires"], do: [{:desires, params["desires"]} | opts], else: opts
    opts = if params["cognition"], do: [{:cognition, params["cognition"]} | opts], else: opts
    opts = if params["constitution"], do: [{:constitution, String.to_atom(params["constitution"])} | opts], else: opts

    case Agent.create(name, opts) do
      {:ok, pid} -> {:ok, %{name: name, id: Agent.id(pid), status: "created"}}
      {:error, reason} -> {:error, -32603, "Failed: #{inspect(reason)}"}
    end
  end

  def handle("kudzu_get_agent", %{"name" => name}) do
    with_agent(name, fn pid -> {:ok, Agent.info(pid)} end)
  end

  def handle("kudzu_delete_agent", %{"name" => name}) do
    with_agent(name, fn pid ->
      Agent.destroy(pid)
      {:ok, %{status: "destroyed", name: name}}
    end)
  end

  def handle("kudzu_agent_remember", %{"name" => name, "content" => content} = params) do
    with_agent(name, fn pid ->
      opts = []
      opts = if params["context"], do: [{:context, params["context"]} | opts], else: opts
      opts = if params["importance"], do: [{:importance, String.to_atom(params["importance"])} | opts], else: opts
      case Agent.remember(pid, content, opts) do
        {:ok, trace_id} -> {:ok, %{trace_id: trace_id, type: "memory"}}
        {:error, reason} -> {:error, -32603, inspect(reason)}
      end
    end)
  end

  def handle("kudzu_agent_learn", %{"name" => name, "pattern" => pattern} = params) do
    with_agent(name, fn pid ->
      opts = []
      opts = if params["examples"], do: [{:examples, params["examples"]} | opts], else: opts
      opts = if params["confidence"], do: [{:confidence, params["confidence"]} | opts], else: opts
      case Agent.learn(pid, pattern, opts) do
        {:ok, trace_id} -> {:ok, %{trace_id: trace_id, type: "learning"}}
        {:error, reason} -> {:error, -32603, inspect(reason)}
      end
    end)
  end

  def handle("kudzu_agent_think", %{"name" => name, "thought" => thought}) do
    with_agent(name, fn pid ->
      case Agent.think(pid, thought) do
        {:ok, trace_id} -> {:ok, %{trace_id: trace_id, type: "thought"}}
        {:error, reason} -> {:error, -32603, inspect(reason)}
      end
    end)
  end

  def handle("kudzu_agent_observe", %{"name" => name, "observation" => observation} = params) do
    with_agent(name, fn pid ->
      opts = []
      opts = if params["source"], do: [{:source, params["source"]} | opts], else: opts
      opts = if params["confidence"], do: [{:confidence, params["confidence"]} | opts], else: opts
      case Agent.observe(pid, observation, opts) do
        {:ok, trace_id} -> {:ok, %{trace_id: trace_id, type: "observation"}}
        {:error, reason} -> {:error, -32603, inspect(reason)}
      end
    end)
  end

  def handle("kudzu_agent_decide", %{"name" => name, "decision" => decision, "rationale" => rationale} = params) do
    with_agent(name, fn pid ->
      opts = []
      opts = if params["alternatives"], do: [{:alternatives, params["alternatives"]} | opts], else: opts
      opts = if params["context"], do: [{:context, params["context"]} | opts], else: opts
      case Agent.decide(pid, decision, rationale, opts) do
        {:ok, trace_id} -> {:ok, %{trace_id: trace_id, type: "decision"}}
        {:error, reason} -> {:error, -32603, inspect(reason)}
      end
    end)
  end

  def handle("kudzu_agent_recall", %{"name" => name} = params) do
    with_agent(name, fn pid ->
      opts = []
      opts = if params["limit"], do: [{:limit, params["limit"]} | opts], else: opts
      opts = if params["include_mesh"], do: [{:include_mesh, params["include_mesh"]} | opts], else: opts

      query = cond do
        params["purpose"] -> String.to_atom(params["purpose"])
        params["query"] -> params["query"]
        true -> ""
      end

      memories = Agent.recall(pid, query, opts)
      memories = if is_list(memories), do: memories, else: []
      {:ok, %{count: length(memories), memories: Enum.map(memories, &trace_to_map/1)}}
    end)
  end

  def handle("kudzu_agent_stimulate", %{"name" => name, "prompt" => prompt}) do
    with_agent(name, fn pid ->
      case Agent.stimulate(pid, prompt) do
        {:ok, response, actions} -> {:ok, %{response: response, actions: length(actions)}}
        {:ok, response} -> {:ok, %{response: response}}
        {:error, reason} -> {:error, -32603, inspect(reason)}
      end
    end)
  end

  def handle("kudzu_agent_desires", %{"name" => name}) do
    with_agent(name, fn pid -> {:ok, %{desires: Agent.desires(pid)}} end)
  end

  def handle("kudzu_agent_add_desire", %{"name" => name, "desire" => desire}) do
    with_agent(name, fn pid ->
      Agent.add_desire(pid, desire)
      {:ok, %{status: "added", desires: Agent.desires(pid)}}
    end)
  end

  def handle("kudzu_agent_peers", %{"name" => name}) do
    with_agent(name, fn pid ->
      info = Agent.info(pid)
      {:ok, %{peers: info.peers, peer_count: info.peer_count}}
    end)
  end

  def handle("kudzu_agent_connect_peer", %{"name" => name} = params) do
    with_agent(name, fn pid ->
      peer = cond do
        params["peer_id"] -> params["peer_id"]
        params["peer_name"] ->
          case Agent.find(params["peer_name"]) do
            {:ok, peer_pid} -> Agent.id(peer_pid)
            _ -> nil
          end
        true -> nil
      end

      if peer do
        Agent.connect(pid, peer)
        {:ok, %{status: "connected", peer: peer}}
      else
        {:error, -32602, "Peer not found"}
      end
    end)
  end

  defp with_agent(name, fun) do
    case Agent.find(name) do
      {:ok, pid} -> fun.(pid)
      {:error, :not_found} -> {:error, -32602, "Agent not found: #{name}"}
    end
  end

  defp trace_to_map(trace) when is_struct(trace, Kudzu.Trace) do
    %{id: trace.id, purpose: to_string(trace.purpose),
      reconstruction_hint: trace.reconstruction_hint,
      origin: trace.origin, path: trace.path}
  end
  defp trace_to_map(trace) when is_map(trace), do: trace
  defp trace_to_map(other), do: %{raw: inspect(other)}
end
