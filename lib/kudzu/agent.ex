defmodule Kudzu.Agent do
  @moduledoc """
  Universal Agent Interface for Kudzu.

  Any AI agent (Claude, Ollama, LLaMA, GPT, custom) can use this interface
  for persistent, distributed memory. The agent doesn't need to know about
  storage tiers or mesh topology - Kudzu handles it transparently.

  ## Quick Start

  ```elixir
  # Create an agent context
  {:ok, agent} = Kudzu.Agent.create("my_assistant", desires: ["Help users", "Learn patterns"])

  # Remember something
  Kudzu.Agent.remember(agent, "User prefers dark mode")

  # Learn a pattern
  Kudzu.Agent.learn(agent, "Users often ask about auth after login issues")

  # Recall relevant memories
  memories = Kudzu.Agent.recall(agent, "user preferences")

  # Think through a problem (records thought trace)
  Kudzu.Agent.think(agent, "Analyzing the authentication flow...")

  # Share with other agents
  Kudzu.Agent.share(agent, trace, :research_agents)
  ```

  ## Memory Types

  | Type | Purpose | Aging |
  |------|---------|-------|
  | memory | Facts, preferences, context | Normal |
  | learning | Patterns, meta-knowledge | Slow (valuable) |
  | thought | Reasoning chains | Fast |
  | observation | Noticed facts | Normal |
  | decision | Choices and rationale | Slow |

  ## Mesh Integration

  When connected to the mesh, agents can:
  - Query memories from other nodes
  - Share traces with peer agents
  - Access collective knowledge
  """

  alias Kudzu.{Hologram, Node, Application}

  @type agent :: pid()
  @type trace_id :: String.t()

  # ============================================================================
  # Agent Lifecycle
  # ============================================================================

  @doc """
  Create a new agent with optional initial configuration.

  ## Options
    - :desires - List of agent goals/desires
    - :constitution - Constitutional framework (:mesh_republic, :kudzu_evolve, :cautious)
    - :cognition - Enable LLM cognition (default: false)
    - :cognition_model - LLM model for cognition
  """
  @spec create(String.t(), keyword()) :: {:ok, agent()} | {:error, term()}
  def create(name, opts \\ []) do
    purpose = String.to_atom("agent_#{name}")

    hologram_opts = [
      purpose: purpose,
      constitution: Keyword.get(opts, :constitution, :mesh_republic),
      cognition: Keyword.get(opts, :cognition, false),
      cognition_model: Keyword.get(opts, :cognition_model, "llama4:scout"),
      desires: Keyword.get(opts, :desires, [])
    ]

    Application.spawn_hologram(hologram_opts)
  end

  @doc """
  Find an existing agent by name.
  """
  @spec find(String.t()) :: {:ok, agent()} | {:error, :not_found}
  def find(name) do
    purpose = String.to_atom("agent_#{name}")
    case Application.find_by_purpose(purpose) do
      [{pid, _id} | _] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Get or create an agent (idempotent).
  """
  @spec ensure(String.t(), keyword()) :: {:ok, agent()}
  def ensure(name, opts \\ []) do
    case find(name) do
      {:ok, pid} -> {:ok, pid}
      {:error, :not_found} -> create(name, opts)
    end
  end

  @doc """
  Destroy an agent.
  """
  @spec destroy(agent()) :: :ok
  def destroy(agent) do
    Application.stop_hologram(agent)
  end

  # ============================================================================
  # Memory Operations
  # ============================================================================

  @doc """
  Remember something - stores in memory with normal aging.
  """
  @spec remember(agent(), String.t(), keyword()) :: {:ok, trace_id()}
  def remember(agent, content, opts \\ []) do
    record_trace(agent, :memory, %{
      content: content,
      context: Keyword.get(opts, :context),
      importance: Keyword.get(opts, :importance, :normal)
    })
  end

  @doc """
  Learn a pattern - stores with slow aging (valuable knowledge).
  """
  @spec learn(agent(), String.t(), keyword()) :: {:ok, trace_id()}
  def learn(agent, pattern, opts \\ []) do
    record_trace(agent, :learning, %{
      pattern: pattern,
      examples: Keyword.get(opts, :examples, []),
      confidence: Keyword.get(opts, :confidence, 1.0)
    })
  end

  @doc """
  Record a thought - stores reasoning chain with fast aging.
  """
  @spec think(agent(), String.t()) :: {:ok, trace_id()}
  def think(agent, thought) do
    record_trace(agent, :thought, %{content: thought, timestamp: DateTime.utc_now()})
  end

  @doc """
  Record an observation - something noticed.
  """
  @spec observe(agent(), String.t(), keyword()) :: {:ok, trace_id()}
  def observe(agent, observation, opts \\ []) do
    record_trace(agent, :observation, %{
      content: observation,
      source: Keyword.get(opts, :source),
      confidence: Keyword.get(opts, :confidence, 1.0)
    })
  end

  @doc """
  Record a decision with rationale.
  """
  @spec decide(agent(), String.t(), String.t(), keyword()) :: {:ok, trace_id()}
  def decide(agent, decision, rationale, opts \\ []) do
    record_trace(agent, :decision, %{
      decision: decision,
      rationale: rationale,
      alternatives: Keyword.get(opts, :alternatives, []),
      context: Keyword.get(opts, :context)
    })
  end

  @doc """
  Recall memories matching a query.
  Searches local tiers first, then mesh if connected.
  """
  @spec recall(agent(), String.t() | atom(), keyword()) :: [map()]
  def recall(agent, purpose_or_query, opts \\ [])

  def recall(agent, purpose, opts) when is_atom(purpose) do
    # Recall by purpose
    traces = Hologram.recall(agent, purpose)
    traces = if is_list(traces), do: traces, else: []

    traces
    |> maybe_include_mesh(purpose, opts)
    |> Enum.take(Keyword.get(opts, :limit, 50))
  end

  def recall(agent, query, opts) when is_binary(query) do
    # Recall all and filter by content match
    traces = Hologram.recall_all(agent)
    traces = if is_list(traces), do: traces, else: []

    traces
    |> Enum.filter(fn trace ->
      hint = trace.reconstruction_hint || %{}
      content = to_string(Map.get(hint, :content, "")) <> to_string(Map.get(hint, :pattern, ""))
      String.contains?(String.downcase(content), String.downcase(query))
    end)
    |> maybe_include_mesh(:all, opts)
    |> Enum.take(Keyword.get(opts, :limit, 50))
  end

  @doc """
  Recall all memories for this agent.
  """
  @spec recall_all(agent()) :: [map()]
  def recall_all(agent) do
    Hologram.recall_all(agent)
  end

  # ============================================================================
  # Agent Cognition
  # ============================================================================

  @doc """
  Stimulate the agent with a prompt and get a response.
  Requires cognition to be enabled.
  """
  @spec stimulate(agent(), String.t()) :: {:ok, map()} | {:error, term()}
  def stimulate(agent, prompt) do
    Hologram.stimulate(agent, prompt)
  end

  @doc """
  Add a desire/goal to the agent.
  """
  @spec add_desire(agent(), String.t()) :: :ok
  def add_desire(agent, desire) do
    Hologram.add_desire(agent, desire)
  end

  @doc """
  Get agent's current desires.
  """
  @spec desires(agent()) :: [String.t()]
  def desires(agent) do
    Hologram.get_desires(agent)
  end

  # ============================================================================
  # Peer Interaction
  # ============================================================================

  @doc """
  Connect this agent to a peer agent.
  """
  @spec connect(agent(), agent() | String.t()) :: :ok
  def connect(agent, peer) do
    Hologram.introduce_peer(agent, peer)
  end

  @doc """
  Share a trace with peer agents.
  """
  @spec share(agent(), map(), atom()) :: :ok
  def share(agent, trace, target_purpose) do
    # Find agents with matching purpose and share
    peers = Hologram.get_peers(agent)

    Enum.each(peers, fn {peer_id, _proximity} ->
      case Application.find_by_id(peer_id) do
        {:ok, peer_pid} ->
          Hologram.receive_trace(peer_pid, trace, Hologram.get_id(agent))
        _ ->
          :ok
      end
    end)
  end

  @doc """
  Query a specific peer for memories.
  """
  @spec query_peer(agent(), String.t(), atom()) :: [map()]
  def query_peer(agent, peer_id, purpose) do
    Hologram.query_peer(agent, peer_id, purpose, 3)
  end

  # ============================================================================
  # Agent Info
  # ============================================================================

  @doc """
  Get agent info.
  """
  @spec info(agent()) :: map()
  def info(agent) do
    Hologram.info(agent)
  end

  @doc """
  Get agent's unique ID.
  """
  @spec id(agent()) :: String.t()
  def id(agent) do
    Hologram.get_id(agent)
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp record_trace(agent, purpose, data) do
    case Hologram.record_trace(agent, purpose, data) do
      {:ok, trace} ->
        # Also persist to tiered storage
        hologram_id = Hologram.get_id(agent)
        importance = Map.get(data, :importance, :normal)
        Node.store(trace, hologram_id, importance: importance)
        {:ok, trace.id}
      error ->
        error
    end
  end

  defp maybe_include_mesh(local_results, purpose, opts) do
    if Keyword.get(opts, :include_mesh, false) and Node.mesh_connected?() do
      mesh_results = Node.query(purpose, limit: Keyword.get(opts, :limit, 50))
      # Deduplicate
      all_ids = MapSet.new(Enum.map(local_results, & &1.id))
      new_mesh = Enum.reject(mesh_results, fn r -> MapSet.member?(all_ids, r.id) end)
      local_results ++ new_mesh
    else
      local_results
    end
  end
end
