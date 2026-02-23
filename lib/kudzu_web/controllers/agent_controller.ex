defmodule KudzuWeb.AgentController do
  @moduledoc """
  Universal Agent API Controller.

  Provides a simple REST interface for any AI agent to use Kudzu's
  distributed memory system. Agents don't need to understand storage
  tiers or mesh topology - everything is handled transparently.
  """

  use Phoenix.Controller
  alias Kudzu.Agent

  # ============================================================================
  # Agent Lifecycle
  # ============================================================================

  @doc """
  Create a new agent.
  POST /api/v1/agents
  Body: {"name": "my_assistant", "desires": ["Help users"], "cognition": true}
  """
  def create(conn, params) do
    name = params["name"] || generate_name()

    opts = []
    opts = if params["desires"], do: [{:desires, params["desires"]} | opts], else: opts
    opts = if params["cognition"], do: [{:cognition, params["cognition"]} | opts], else: opts
    opts = if params["constitution"], do: [{:constitution, String.to_atom(params["constitution"])} | opts], else: opts

    case Agent.create(name, opts) do
      {:ok, pid} ->
        conn
        |> put_status(:created)
        |> json(%{
          name: name,
          id: Agent.id(pid),
          status: "created"
        })
      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: inspect(reason)})
    end
  end

  @doc """
  Find an existing agent.
  GET /api/v1/agents/:name
  """
  def find(conn, %{"name" => name}) do
    case Agent.find(name) do
      {:ok, pid} ->
        json(conn, Agent.info(pid))
      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Agent not found"})
    end
  end

  @doc """
  Destroy an agent.
  DELETE /api/v1/agents/:name
  """
  def destroy(conn, %{"name" => name}) do
    case Agent.find(name) do
      {:ok, pid} ->
        Agent.destroy(pid)
        json(conn, %{status: "destroyed", name: name})
      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Agent not found"})
    end
  end

  # ============================================================================
  # Memory Operations
  # ============================================================================

  @doc """
  Remember something.
  POST /api/v1/agents/:name/remember
  Body: {"content": "User prefers dark mode", "importance": "high"}
  """
  def remember(conn, %{"name" => name} = params) do
    with_agent(conn, name, fn pid ->
      content = params["content"] || ""
      opts = []
      opts = if params["context"], do: [{:context, params["context"]} | opts], else: opts
      opts = if params["importance"], do: [{:importance, String.to_atom(params["importance"])} | opts], else: opts

      case Agent.remember(pid, content, opts) do
        {:ok, trace_id} ->
          conn
          |> put_status(:created)
          |> json(%{trace_id: trace_id, type: "memory"})
        {:error, reason} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: inspect(reason)})
      end
    end)
  end

  @doc """
  Learn a pattern.
  POST /api/v1/agents/:name/learn
  Body: {"pattern": "Users ask about auth after login issues", "examples": [...]}
  """
  def learn(conn, %{"name" => name} = params) do
    with_agent(conn, name, fn pid ->
      pattern = params["pattern"] || ""
      opts = []
      opts = if params["examples"], do: [{:examples, params["examples"]} | opts], else: opts
      opts = if params["confidence"], do: [{:confidence, params["confidence"]} | opts], else: opts

      case Agent.learn(pid, pattern, opts) do
        {:ok, trace_id} ->
          conn
          |> put_status(:created)
          |> json(%{trace_id: trace_id, type: "learning"})
        {:error, reason} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: inspect(reason)})
      end
    end)
  end

  @doc """
  Record a thought.
  POST /api/v1/agents/:name/think
  Body: {"thought": "Analyzing the authentication flow..."}
  """
  def think(conn, %{"name" => name} = params) do
    with_agent(conn, name, fn pid ->
      thought = params["thought"] || ""

      case Agent.think(pid, thought) do
        {:ok, trace_id} ->
          conn
          |> put_status(:created)
          |> json(%{trace_id: trace_id, type: "thought"})
        {:error, reason} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: inspect(reason)})
      end
    end)
  end

  @doc """
  Record an observation.
  POST /api/v1/agents/:name/observe
  Body: {"observation": "User clicked logout 3 times", "source": "ui_events"}
  """
  def observe(conn, %{"name" => name} = params) do
    with_agent(conn, name, fn pid ->
      observation = params["observation"] || ""
      opts = []
      opts = if params["source"], do: [{:source, params["source"]} | opts], else: opts
      opts = if params["confidence"], do: [{:confidence, params["confidence"]} | opts], else: opts

      case Agent.observe(pid, observation, opts) do
        {:ok, trace_id} ->
          conn
          |> put_status(:created)
          |> json(%{trace_id: trace_id, type: "observation"})
        {:error, reason} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: inspect(reason)})
      end
    end)
  end

  @doc """
  Record a decision.
  POST /api/v1/agents/:name/decide
  Body: {"decision": "Use JWT", "rationale": "Stateless, scalable", "alternatives": ["sessions", "OAuth"]}
  """
  def decide(conn, %{"name" => name} = params) do
    with_agent(conn, name, fn pid ->
      decision = params["decision"] || ""
      rationale = params["rationale"] || ""
      opts = []
      opts = if params["alternatives"], do: [{:alternatives, params["alternatives"]} | opts], else: opts
      opts = if params["context"], do: [{:context, params["context"]} | opts], else: opts

      case Agent.decide(pid, decision, rationale, opts) do
        {:ok, trace_id} ->
          conn
          |> put_status(:created)
          |> json(%{trace_id: trace_id, type: "decision"})
        {:error, reason} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: inspect(reason)})
      end
    end)
  end

  @doc """
  Recall memories.
  GET /api/v1/agents/:name/recall?query=user+preferences
  """
  def recall(conn, %{"name" => name} = params) do
    with_agent(conn, name, fn pid ->
      query = params["query"] || ""
      opts = []
      opts = if params["limit"], do: [{:limit, String.to_integer(params["limit"])} | opts], else: opts
      opts = if params["include_mesh"], do: [{:include_mesh, params["include_mesh"] == "true"} | opts], else: opts

      memories = Agent.recall(pid, query, opts)
      memories = if is_list(memories), do: memories, else: []

      json(conn, %{
        count: length(memories),
        memories: Enum.map(memories, &trace_to_map/1)
      })
    end)
  end

  @doc """
  Recall memories by purpose.
  GET /api/v1/agents/:name/recall/:purpose
  """
  def recall_by_purpose(conn, %{"name" => name, "purpose" => purpose} = params) do
    with_agent(conn, name, fn pid ->
      purpose_atom = String.to_atom(purpose)
      opts = []
      opts = if params["limit"], do: [{:limit, String.to_integer(params["limit"])} | opts], else: opts
      opts = if params["include_mesh"], do: [{:include_mesh, params["include_mesh"] == "true"} | opts], else: opts

      memories = Agent.recall(pid, purpose_atom, opts)

      json(conn, %{
        purpose: purpose,
        count: length(memories),
        memories: Enum.map(memories, &trace_to_map/1)
      })
    end)
  end

  # ============================================================================
  # Cognition
  # ============================================================================

  @doc """
  Stimulate the agent with a prompt.
  POST /api/v1/agents/:name/stimulate
  Body: {"prompt": "What do you know about the user?"}
  """
  def stimulate(conn, %{"name" => name} = params) do
    with_agent(conn, name, fn pid ->
      prompt = params["prompt"] || ""

      case Agent.stimulate(pid, prompt) do
        {:ok, response, actions} ->
          json(conn, %{
            response: response,
            actions: length(actions)
          })
        {:ok, response} ->
          json(conn, %{response: response})
        {:error, reason} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: inspect(reason)})
      end
    end)
  end

  @doc """
  Get agent's desires.
  GET /api/v1/agents/:name/desires
  """
  def desires(conn, %{"name" => name}) do
    with_agent(conn, name, fn pid ->
      json(conn, %{desires: Agent.desires(pid)})
    end)
  end

  @doc """
  Add a desire.
  POST /api/v1/agents/:name/desires
  Body: {"desire": "Learn user preferences"}
  """
  def add_desire(conn, %{"name" => name} = params) do
    with_agent(conn, name, fn pid ->
      desire = params["desire"] || ""
      Agent.add_desire(pid, desire)
      json(conn, %{status: "added", desires: Agent.desires(pid)})
    end)
  end

  # ============================================================================
  # Peers
  # ============================================================================

  @doc """
  Get agent's peers.
  GET /api/v1/agents/:name/peers
  """
  def peers(conn, %{"name" => name}) do
    with_agent(conn, name, fn pid ->
      info = Agent.info(pid)
      json(conn, %{peers: info.peers, peer_count: info.peer_count})
    end)
  end

  @doc """
  Connect to a peer agent.
  POST /api/v1/agents/:name/peers
  Body: {"peer_name": "research_agent"} or {"peer_id": "abc123"}
  """
  def connect_peer(conn, %{"name" => name} = params) do
    with_agent(conn, name, fn pid ->
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
        json(conn, %{status: "connected", peer: peer})
      else
        conn
        |> put_status(:not_found)
        |> json(%{error: "Peer not found"})
      end
    end)
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp with_agent(conn, name, fun) do
    case Agent.find(name) do
      {:ok, pid} ->
        fun.(pid)
      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Agent not found"})
    end
  end

  defp generate_name do
    :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
  end

  defp trace_to_map(trace) when is_struct(trace, Kudzu.Trace) do
    %{
      id: trace.id,
      purpose: to_string(trace.purpose),
      reconstruction_hint: safe_stringify(trace.reconstruction_hint),
      origin: trace.origin,
      path: trace.path,
      timestamp: safe_stringify(trace.timestamp)
    }
  end

  defp trace_to_map(trace) when is_struct(trace) do
    # Handle other struct types
    trace
    |> Map.from_struct()
    |> safe_stringify()
  end

  defp trace_to_map(trace) when is_map(trace) do
    safe_stringify(trace)
  end

  defp trace_to_map(other) do
    %{raw: inspect(other)}
  end

  defp safe_stringify(nil), do: nil
  defp safe_stringify(map) when is_struct(map) do
    map |> Map.from_struct() |> safe_stringify()
  end
  defp safe_stringify(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), safe_stringify(v)}
      {k, v} when is_binary(k) -> {k, safe_stringify(v)}
      {k, v} -> {inspect(k), safe_stringify(v)}
    end)
  end
  defp safe_stringify(list) when is_list(list), do: Enum.map(list, &safe_stringify/1)
  defp safe_stringify(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp safe_stringify(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp safe_stringify(other), do: other
end
