defmodule Kudzu.Hologram do
  @moduledoc """
  A Hologram is a self-aware context agent with embedded references to peers.

  Each hologram:
  - Carries a collection of traces (episodic navigation paths)
  - Maintains proximity awareness to peer holograms AND beam-lets
  - Can replay traces to reconstruct context rather than store it
  - Contains compressed representation of the broader context topology
  - Has desires that drive behavior prioritization
  - Can use cognition (LLM) for reasoning about stimuli
  - Delegates IO operations to beam-let execution substrate

  The fractal aspect: the same structural patterns repeat at different scales.
  Any hologram can navigate to relevant context elsewhere in the system.

  ## Beam-let Integration
  Holograms don't perform IO directly. They discover and delegate to beam-lets
  through proximity-based routing. This separates cognition from execution.
  """

  use GenServer
  require Logger

  alias Kudzu.{Trace, VectorClock, Protocol, Cognition, Constitution}
  alias Kudzu.Beamlet.Client, as: Beamlet

  @proximity_decay_rate 0.95
  @proximity_boost 0.2
  @max_proximity 1.0
  @min_proximity 0.01
  @decay_interval_ms 30_000
  @beamlet_discovery_interval 60_000
  @default_constitution :mesh_republic

  @type state :: %{
          id: String.t(),
          purpose: atom() | String.t(),
          traces: %{String.t() => Trace.t()},
          peers: %{String.t() => float()},
          beamlets: %{atom() => %{String.t() => float()}},  # capability => beamlet_id => proximity
          clock: VectorClock.t(),
          desires: [String.t()],
          cognition_enabled: boolean(),
          cognition_model: String.t(),
          constitution: atom(),  # Constitutional framework
          metadata: map()
        }

  # Client API

  @doc """
  Start a new hologram agent.

  ## Options
    - :id - unique identifier (generated if not provided)
    - :purpose - what this hologram is for
    - :desires - list of goal strings
    - :cognition - enable LLM cognition (default false)
    - :model - Ollama model to use (default "mistral:latest")
    - :constitution - constitutional framework (:mesh_republic, :cautious, :open)
    - :name - registration name (optional)
  """
  def start_link(opts \\ []) do
    id = Keyword.get(opts, :id, generate_id())
    name = Keyword.get(opts, :name)

    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts ++ [id: id], gen_opts)
  end

  @doc """
  Record a new trace in this hologram.
  """
  @spec record_trace(GenServer.server(), atom() | String.t(), map()) :: {:ok, Trace.t()}
  def record_trace(hologram, purpose, reconstruction_hint \\ %{}) do
    GenServer.call(hologram, {:record_trace, purpose, reconstruction_hint})
  end

  @doc """
  Recall traces matching a given purpose.
  """
  @spec recall(GenServer.server(), atom() | String.t()) :: [Trace.t()]
  def recall(hologram, purpose) do
    GenServer.call(hologram, {:recall, purpose})
  end

  @doc """
  Recall all traces.
  """
  @spec recall_all(GenServer.server()) :: [Trace.t()]
  def recall_all(hologram) do
    GenServer.call(hologram, :recall_all)
  end

  @doc """
  Introduce a peer hologram. Establishes bidirectional awareness.
  """
  @spec introduce_peer(GenServer.server(), GenServer.server() | String.t()) :: :ok
  def introduce_peer(hologram, peer) do
    GenServer.call(hologram, {:introduce_peer, peer})
  end

  @doc """
  Query a peer for traces matching a purpose.
  Follows the trace path through the network.
  """
  @spec query_peer(GenServer.server(), String.t(), atom() | String.t(), non_neg_integer()) ::
          {:ok, [Trace.t()]} | {:error, term()}
  def query_peer(hologram, peer_id, purpose, max_hops \\ 3) do
    GenServer.call(hologram, {:query_peer, peer_id, purpose, max_hops}, 10_000)
  end

  @doc """
  Get the hologram's current state summary.
  """
  @spec info(GenServer.server()) :: map()
  def info(hologram) do
    GenServer.call(hologram, :info)
  end

  @doc """
  Get the hologram's ID.
  """
  @spec get_id(GenServer.server()) :: String.t()
  def get_id(hologram) do
    GenServer.call(hologram, :get_id)
  end

  @doc """
  Get current peers and their proximity scores.
  """
  @spec get_peers(GenServer.server()) :: %{String.t() => float()}
  def get_peers(hologram) do
    GenServer.call(hologram, :get_peers)
  end

  @doc """
  Receive a shared trace from another hologram.
  """
  @spec receive_trace(GenServer.server(), Trace.t(), String.t()) :: :ok
  def receive_trace(hologram, trace, from_id) do
    GenServer.cast(hologram, {:receive_trace, trace, from_id})
  end

  @doc """
  Handle incoming protocol message.
  """
  @spec handle_message(GenServer.server(), map()) :: map() | nil
  def handle_message(hologram, message) do
    GenServer.call(hologram, {:handle_message, message})
  end

  # Desire Management

  @doc """
  Add a desire/goal to the hologram.
  """
  @spec add_desire(GenServer.server(), String.t()) :: :ok
  def add_desire(hologram, desire) do
    GenServer.call(hologram, {:add_desire, desire})
  end

  @doc """
  Remove a desire by index or content.
  """
  @spec remove_desire(GenServer.server(), non_neg_integer() | String.t()) :: :ok
  def remove_desire(hologram, desire_or_index) do
    GenServer.call(hologram, {:remove_desire, desire_or_index})
  end

  @doc """
  Get current desires.
  """
  @spec get_desires(GenServer.server()) :: [String.t()]
  def get_desires(hologram) do
    GenServer.call(hologram, :get_desires)
  end

  @doc """
  Clear all desires.
  """
  @spec clear_desires(GenServer.server()) :: :ok
  def clear_desires(hologram) do
    GenServer.call(hologram, :clear_desires)
  end

  # Cognition / Stimulus Loop

  @doc """
  Enable or disable cognition for this hologram.
  """
  @spec set_cognition(GenServer.server(), boolean(), keyword()) :: :ok
  def set_cognition(hologram, enabled, opts \\ []) do
    GenServer.call(hologram, {:set_cognition, enabled, opts})
  end

  @doc """
  Send a stimulus to the hologram and get its cognitive response.
  If cognition is disabled, returns {:error, :cognition_disabled}.
  """
  @spec stimulate(GenServer.server(), String.t() | map(), keyword()) ::
          {:ok, String.t(), [term()]} | {:error, term()}
  def stimulate(hologram, stimulus, opts \\ []) do
    GenServer.call(hologram, {:stimulate, stimulus, opts}, 60_000)
  end

  @doc """
  Send a stimulus asynchronously - hologram will process and execute actions.
  """
  @spec stimulate_async(GenServer.server(), String.t() | map()) :: :ok
  def stimulate_async(hologram, stimulus) do
    GenServer.cast(hologram, {:stimulate_async, stimulus})
  end

  @doc """
  Get the full state for cognition (used by prompt builder).
  """
  @spec get_state(GenServer.server()) :: map()
  def get_state(hologram) do
    GenServer.call(hologram, :get_state)
  end

  # Beam-let Delegation

  @doc """
  Request IO operation through beam-let substrate.
  Hologram doesn't perform IO directly - it delegates to nearby beam-lets.
  """
  @spec delegate_io(GenServer.server(), map()) :: {:ok, term()} | {:error, term()}
  def delegate_io(hologram, operation) do
    GenServer.call(hologram, {:delegate_io, operation}, 60_000)
  end

  @doc """
  Read a file through beam-let delegation.
  """
  @spec read_file(GenServer.server(), String.t()) :: {:ok, binary()} | {:error, term()}
  def read_file(hologram, path) do
    delegate_io(hologram, %{op: :file_read, path: path})
  end

  @doc """
  Write a file through beam-let delegation.
  """
  @spec write_file(GenServer.server(), String.t(), binary()) :: {:ok, :written} | {:error, term()}
  def write_file(hologram, path, content) do
    delegate_io(hologram, %{op: :file_write, path: path, content: content})
  end

  @doc """
  HTTP request through beam-let delegation.
  """
  @spec http_request(GenServer.server(), :get | :post, String.t(), map()) :: {:ok, map()} | {:error, term()}
  def http_request(hologram, method, url, opts \\ %{}) do
    op = case method do
      :get -> %{op: :http_get, url: url, headers: Map.get(opts, :headers, [])}
      :post -> %{op: :http_post, url: url, body: Map.get(opts, :body, ""), headers: Map.get(opts, :headers, [])}
    end
    delegate_io(hologram, op)
  end

  @doc """
  Get known beam-lets and their proximity scores.
  """
  @spec get_beamlets(GenServer.server()) :: %{atom() => %{String.t() => float()}}
  def get_beamlets(hologram) do
    GenServer.call(hologram, :get_beamlets)
  end

  @doc """
  Discover and update beam-let awareness.
  """
  @spec discover_beamlets(GenServer.server()) :: :ok
  def discover_beamlets(hologram) do
    GenServer.cast(hologram, :discover_beamlets)
  end

  # Constitutional Framework

  @doc """
  Get the current constitutional framework.
  """
  @spec get_constitution(GenServer.server()) :: atom()
  def get_constitution(hologram) do
    GenServer.call(hologram, :get_constitution)
  end

  @doc """
  Set the constitutional framework (hot-swap).
  """
  @spec set_constitution(GenServer.server(), atom()) :: :ok
  def set_constitution(hologram, constitution) do
    GenServer.call(hologram, {:set_constitution, constitution})
  end

  @doc """
  Check if an action is permitted under the current constitution.
  """
  @spec action_permitted?(GenServer.server(), {atom(), map()}) ::
          :permitted | {:denied, atom()} | {:requires_consensus, float()}
  def action_permitted?(hologram, action) do
    GenServer.call(hologram, {:check_permission, action})
  end

  @doc """
  Get the constitutional principles this hologram operates under.
  """
  @spec get_principles(GenServer.server()) :: [String.t()]
  def get_principles(hologram) do
    GenServer.call(hologram, :get_principles)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    id = Keyword.fetch!(opts, :id)
    purpose = Keyword.get(opts, :purpose, :general)
    desires = Keyword.get(opts, :desires, [])
    cognition_enabled = Keyword.get(opts, :cognition, false)
    model = Keyword.get(opts, :model, "mistral:latest")
    ollama_url = Keyword.get(opts, :ollama_url)  # nil means use default
    constitution = Keyword.get(opts, :constitution, @default_constitution)

    # Constrain initial desires according to constitution
    constrained_desires = Constitution.constrain(constitution, desires, %{id: id})

    state = %{
      id: id,
      purpose: purpose,
      traces: %{},
      peers: %{},
      beamlets: %{},  # capability => %{beamlet_id => proximity_score}
      clock: VectorClock.new(id),
      desires: constrained_desires,
      cognition_enabled: cognition_enabled,
      cognition_model: model,
      ollama_url: ollama_url,  # Custom Ollama endpoint for this hologram
      constitution: constitution,
      metadata: %{}
    }

    # Emit telemetry for hologram start
    :telemetry.execute(
      [:kudzu, :hologram, :start],
      %{system_time: System.system_time()},
      %{id: id, purpose: purpose}
    )

    # Schedule periodic proximity decay
    Process.send_after(self(), :decay_proximity, @decay_interval_ms)

    # Schedule initial beam-let discovery
    Process.send_after(self(), :discover_beamlets, 100)

    # Register with the registry by ID and purpose
    Registry.register(Kudzu.Registry, {:id, id}, purpose)
    Registry.register(Kudzu.Registry, {:purpose, purpose}, id)

    {:ok, state}
  end

  @impl true
  def handle_call({:record_trace, purpose, reconstruction_hint}, _from, state) do
    clock = VectorClock.increment(state.clock, state.id)
    trace = Trace.new_with_clock(state.id, purpose, clock, [state.id], reconstruction_hint)

    new_state = %{state |
      traces: Map.put(state.traces, trace.id, trace),
      clock: clock
    }

    :telemetry.execute(
      [:kudzu, :hologram, :trace_recorded],
      %{trace_count: map_size(new_state.traces)},
      %{id: state.id, purpose: purpose}
    )

    {:reply, {:ok, trace}, new_state}
  end

  @impl true
  def handle_call({:recall, purpose}, _from, state) do
    matching = state.traces
    |> Map.values()
    |> Enum.filter(fn trace -> trace.purpose == purpose end)

    {:reply, matching, state}
  end

  @impl true
  def handle_call(:recall_all, _from, state) do
    {:reply, Map.values(state.traces), state}
  end

  @impl true
  def handle_call({:introduce_peer, peer}, _from, state) when is_pid(peer) do
    peer_id = get_id(peer)
    new_peers = Map.update(state.peers, peer_id, @proximity_boost, fn score ->
      min(score + @proximity_boost, @max_proximity)
    end)

    :telemetry.execute(
      [:kudzu, :hologram, :peer_introduced],
      %{peer_count: map_size(new_peers)},
      %{id: state.id, peer_id: peer_id}
    )

    {:reply, :ok, %{state | peers: new_peers}}
  end

  @impl true
  def handle_call({:introduce_peer, peer_id}, _from, state) when is_binary(peer_id) do
    new_peers = Map.update(state.peers, peer_id, @proximity_boost, fn score ->
      min(score + @proximity_boost, @max_proximity)
    end)

    :telemetry.execute(
      [:kudzu, :hologram, :peer_introduced],
      %{peer_count: map_size(new_peers)},
      %{id: state.id, peer_id: peer_id}
    )

    {:reply, :ok, %{state | peers: new_peers}}
  end

  @impl true
  def handle_call({:query_peer, peer_id, purpose, max_hops}, _from, state) do
    result = do_query_peer(state, peer_id, purpose, max_hops, MapSet.new([state.id]))

    # Boost proximity for successful interactions
    new_peers = if match?({:ok, [_ | _]}, result) do
      Map.update(state.peers, peer_id, @proximity_boost, fn score ->
        min(score + @proximity_boost, @max_proximity)
      end)
    else
      state.peers
    end

    {:reply, result, %{state | peers: new_peers}}
  end

  @impl true
  def handle_call(:info, _from, state) do
    info = %{
      id: state.id,
      purpose: state.purpose,
      trace_count: map_size(state.traces),
      peer_count: map_size(state.peers),
      desires: state.desires,
      cognition_enabled: state.cognition_enabled,
      clock: VectorClock.to_map(state.clock)
    }
    {:reply, info, state}
  end

  @impl true
  def handle_call(:get_id, _from, state) do
    {:reply, state.id, state}
  end

  @impl true
  def handle_call(:get_peers, _from, state) do
    {:reply, state.peers, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_call({:handle_message, message}, _from, state) do
    {response, new_state} = process_message(message, state)
    {:reply, response, new_state}
  end

  # Desire handlers

  @impl true
  def handle_call({:add_desire, desire}, _from, state) do
    {:reply, :ok, %{state | desires: state.desires ++ [desire]}}
  end

  @impl true
  def handle_call({:remove_desire, index}, _from, state) when is_integer(index) do
    new_desires = List.delete_at(state.desires, index)
    {:reply, :ok, %{state | desires: new_desires}}
  end

  @impl true
  def handle_call({:remove_desire, desire}, _from, state) when is_binary(desire) do
    new_desires = List.delete(state.desires, desire)
    {:reply, :ok, %{state | desires: new_desires}}
  end

  @impl true
  def handle_call(:get_desires, _from, state) do
    {:reply, state.desires, state}
  end

  @impl true
  def handle_call(:clear_desires, _from, state) do
    {:reply, :ok, %{state | desires: []}}
  end

  # Cognition handlers

  @impl true
  def handle_call({:set_cognition, enabled, opts}, _from, state) do
    model = Keyword.get(opts, :model, state.cognition_model)
    {:reply, :ok, %{state | cognition_enabled: enabled, cognition_model: model}}
  end

  # Constitution handlers

  @impl true
  def handle_call(:get_constitution, _from, state) do
    {:reply, state.constitution, state}
  end

  @impl true
  def handle_call({:set_constitution, constitution}, _from, state) do
    # SECURITY: Block :open constitution in production environments
    if constitution == :open and production_env?() do
      Logger.warning("[Hologram #{state.id}] Blocked attempt to set :open constitution in production")
      {:reply, {:error, :open_constitution_blocked_in_production}, state}
    else
      set_constitution_impl(constitution, state)
    end
  end

  defp set_constitution_impl(constitution, state) do
    # Hot-swap constitution and re-constrain desires
    new_desires = Constitution.constrain(constitution, state.desires, state)

    # Record constitutional change as trace
    clock = VectorClock.increment(state.clock, state.id)
    trace = Trace.new_with_clock(
      state.id,
      :constitution_change,
      clock,
      [state.id],
      %{from: state.constitution, to: constitution}
    )

    :telemetry.execute(
      [:kudzu, :hologram, :constitution_changed],
      %{},
      %{id: state.id, from: state.constitution, to: constitution}
    )

    new_state = %{state |
      constitution: constitution,
      desires: new_desires,
      traces: Map.put(state.traces, trace.id, trace),
      clock: clock
    }

    {:reply, :ok, new_state}
  end

  defp production_env? do
    # Check if running in production environment
    Application.get_env(:kudzu, :env, :dev) == :prod or
      System.get_env("MIX_ENV") == "prod"
  end

  @impl true
  def handle_call({:check_permission, action}, _from, state) do
    decision = Constitution.permitted?(state.constitution, action, state)
    {:reply, decision, state}
  end

  @impl true
  def handle_call(:get_principles, _from, state) do
    principles = Constitution.principles(state.constitution)
    {:reply, principles, state}
  end

  # Beam-let delegation handlers

  @impl true
  def handle_call(:get_beamlets, _from, state) do
    {:reply, state.beamlets, state}
  end

  @impl true
  def handle_call({:delegate_io, operation}, _from, state) do
    # Use beam-let client with our ID for tracking
    result = Beamlet.io(operation, state.id)

    # Update beam-let proximity on successful interaction
    new_state = case result do
      {:ok, _} ->
        capability = get_io_capability(operation)
        boost_beamlet_proximity(state, capability)
      _ ->
        state
    end

    {:reply, result, new_state}
  end

  @impl true
  def handle_call({:stimulate, stimulus, opts}, _from, state) do
    if state.cognition_enabled do
      model = Keyword.get(opts, :model, state.cognition_model)
      ollama_url = Keyword.get(opts, :ollama_url, state.ollama_url)

      # Constrain desires through constitution before cognition
      constrained_state = %{state |
        desires: Constitution.constrain(state.constitution, state.desires, state)
      }

      case Cognition.think(constrained_state, stimulus, model: model, ollama_url: ollama_url) do
        {:ok, {response, actions, traces}} ->
          # Execute actions (with constitutional checks) and record traces
          new_state = execute_actions(actions, constrained_state)
          new_state = record_cognition_traces(traces, new_state)

          # Record the stimulus itself as a trace
          clock = VectorClock.increment(new_state.clock, new_state.id)
          stimulus_trace = Trace.new_with_clock(
            new_state.id,
            :stimulus,
            clock,
            [new_state.id],
            %{
              stimulus: stimulus,
              response: String.slice(response, 0, 200),
              constitution: state.constitution
            }
          )
          final_state = %{new_state |
            traces: Map.put(new_state.traces, stimulus_trace.id, stimulus_trace),
            clock: clock
          }

          :telemetry.execute(
            [:kudzu, :hologram, :cognition],
            %{actions: length(actions), traces: length(traces), constitution: state.constitution},
            %{id: state.id}
          )

          {:reply, {:ok, response, actions}, final_state}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    else
      {:reply, {:error, :cognition_disabled}, state}
    end
  end

  @impl true
  def handle_cast({:receive_trace, trace, from_id}, state) do
    # Follow the trace (add ourselves to the path)
    followed_trace = Trace.follow(trace, state.id)

    # Merge clocks
    new_clock = VectorClock.merge(state.clock, trace.timestamp)
    |> VectorClock.increment(state.id)

    # Store the trace
    new_traces = Map.put(state.traces, followed_trace.id, followed_trace)

    # Boost proximity with sender
    new_peers = Map.update(state.peers, from_id, @proximity_boost, fn score ->
      min(score + @proximity_boost, @max_proximity)
    end)

    :telemetry.execute(
      [:kudzu, :hologram, :trace_received],
      %{trace_count: map_size(new_traces)},
      %{id: state.id, from_id: from_id, purpose: trace.purpose}
    )

    {:noreply, %{state | traces: new_traces, clock: new_clock, peers: new_peers}}
  end

  @impl true
  def handle_cast({:stimulate_async, stimulus}, state) do
    if state.cognition_enabled do
      # Run cognition in a task to not block
      parent = self()
      Task.start(fn ->
        case Cognition.think(state, stimulus, model: state.cognition_model) do
          {:ok, {_response, actions, traces}} ->
            # Send actions back to be executed
            send(parent, {:cognition_result, actions, traces, stimulus})
          {:error, _reason} ->
            :ok
        end
      end)
    end
    {:noreply, state}
  end

  @impl true
  def handle_info({:cognition_result, actions, traces, stimulus}, state) do
    new_state = execute_actions(actions, state)
    new_state = record_cognition_traces(traces, new_state)

    # Record stimulus trace
    clock = VectorClock.increment(new_state.clock, new_state.id)
    stimulus_trace = Trace.new_with_clock(
      new_state.id,
      :stimulus,
      clock,
      [new_state.id],
      %{stimulus: stimulus, async: true}
    )
    final_state = %{new_state |
      traces: Map.put(new_state.traces, stimulus_trace.id, stimulus_trace),
      clock: clock
    }

    {:noreply, final_state}
  end

  @impl true
  def handle_info(:decay_proximity, state) do
    # Decay peer proximity
    new_peers = state.peers
    |> Enum.map(fn {id, score} -> {id, score * @proximity_decay_rate} end)
    |> Enum.filter(fn {_id, score} -> score >= @min_proximity end)
    |> Map.new()

    # Decay beam-let proximity
    new_beamlets = state.beamlets
    |> Enum.map(fn {cap, beamlets} ->
      decayed = beamlets
      |> Enum.map(fn {id, score} -> {id, score * @proximity_decay_rate} end)
      |> Enum.filter(fn {_id, score} -> score >= @min_proximity end)
      |> Map.new()
      {cap, decayed}
    end)
    |> Enum.reject(fn {_cap, beamlets} -> map_size(beamlets) == 0 end)
    |> Map.new()

    Process.send_after(self(), :decay_proximity, @decay_interval_ms)
    {:noreply, %{state | peers: new_peers, beamlets: new_beamlets}}
  end

  @impl true
  def handle_info(:discover_beamlets, state) do
    new_state = do_discover_beamlets(state)
    Process.send_after(self(), :discover_beamlets, @beamlet_discovery_interval)
    {:noreply, new_state}
  end

  @impl true
  def handle_cast(:discover_beamlets, state) do
    {:noreply, do_discover_beamlets(state)}
  end

  @impl true
  def terminate(reason, state) do
    :telemetry.execute(
      [:kudzu, :hologram, :stop],
      %{system_time: System.system_time()},
      %{id: state.id, reason: reason}
    )
    :ok
  end

  # Private functions

  defp execute_actions(actions, state) do
    Enum.reduce(actions, state, fn action, acc_state ->
      execute_action_with_constitution(action, acc_state)
    end)
  end

  defp execute_action_with_constitution(action, state) do
    # Check constitutional permission
    case Constitution.permitted?(state.constitution, action, state) do
      :permitted ->
        new_state = execute_action(action, state)
        # Audit permitted action
        audit_action(action, :permitted, new_state)
        new_state

      {:denied, reason} = decision ->
        # Log denial and record as trace
        Logger.debug("[Constitution] Action denied: #{inspect(action)} - #{reason}")
        audit_action(action, decision, state)
        record_denial_trace(action, reason, state)

      {:requires_consensus, threshold} = decision ->
        # For now, log that consensus would be required
        # Full implementation would initiate consensus protocol
        Logger.debug("[Constitution] Action requires consensus (#{threshold}): #{inspect(action)}")
        audit_action(action, decision, state)
        # Don't execute without consensus
        state
    end
  end

  defp audit_action(action, decision, state) do
    action_trace = %{
      id: "action-" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)),
      purpose: :action_audit,
      origin: state.id,
      timestamp: state.clock
    }
    Constitution.audit(state.constitution, action_trace, decision, state)
  end

  defp record_denial_trace({action_type, _params}, reason, state) do
    clock = VectorClock.increment(state.clock, state.id)
    trace = Trace.new_with_clock(
      state.id,
      :action_denied,
      clock,
      [state.id],
      %{action: action_type, reason: reason, constitution: state.constitution}
    )
    %{state |
      traces: Map.put(state.traces, trace.id, trace),
      clock: clock
    }
  end

  defp record_denial_trace(action_type, reason, state) when is_atom(action_type) do
    record_denial_trace({action_type, %{}}, reason, state)
  end

  defp execute_action({:record_trace, purpose, hints}, state) do
    clock = VectorClock.increment(state.clock, state.id)
    trace = Trace.new_with_clock(state.id, purpose, clock, [state.id], hints)
    %{state |
      traces: Map.put(state.traces, trace.id, trace),
      clock: clock
    }
  end

  defp execute_action({:query_peer, peer_id, purpose}, state) do
    case lookup_peer(peer_id) do
      {:ok, peer_pid} ->
        case recall(peer_pid, purpose) do
          [] -> state
          traces ->
            # Store received traces
            Enum.reduce(traces, state, fn trace, acc ->
              followed = Trace.follow(trace, acc.id)
              %{acc | traces: Map.put(acc.traces, followed.id, followed)}
            end)
        end
      {:error, _} -> state
    end
  end

  defp execute_action({:share_trace, peer_id, trace_id}, state) do
    case {lookup_peer(peer_id), Map.get(state.traces, trace_id)} do
      {{:ok, peer_pid}, %Trace{} = trace} ->
        receive_trace(peer_pid, trace, state.id)
        # Boost proximity
        new_peers = Map.update(state.peers, peer_id, @proximity_boost, &min(&1 + @proximity_boost, @max_proximity))
        %{state | peers: new_peers}
      _ ->
        state
    end
  end

  defp execute_action({:update_desire, desire}, state) do
    %{state | desires: [desire | state.desires] |> Enum.take(10)}
  end

  defp execute_action({:respond, _message}, state) do
    # Response is returned to caller, nothing to do in state
    state
  end

  defp execute_action(:noop, state), do: state

  defp record_cognition_traces(traces, state) do
    Enum.reduce(traces, state, fn trace_spec, acc ->
      clock = VectorClock.increment(acc.clock, acc.id)
      trace = Trace.new_with_clock(
        acc.id,
        trace_spec.purpose,
        clock,
        [acc.id],
        trace_spec.hints
      )
      %{acc |
        traces: Map.put(acc.traces, trace.id, trace),
        clock: clock
      }
    end)
  end

  defp do_query_peer(state, peer_id, purpose, max_hops, visited) when max_hops > 0 do
    case lookup_peer(peer_id) do
      {:ok, peer_pid} ->
        # Create query message
        message = Protocol.query(state.id, state.clock, purpose, max_hops)
        response = handle_message(peer_pid, message)

        case response do
          %{type: :query_response, traces: traces} when traces != [] ->
            {:ok, traces}

          %{type: :query_response, traces: [], suggested_peers: suggested} ->
            # Try suggested peers with reduced hops
            try_suggested_peers(suggested, purpose, max_hops - 1, visited)

          _ ->
            {:ok, []}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_query_peer(_state, _peer_id, _purpose, _max_hops, _visited) do
    {:ok, []}
  end

  defp try_suggested_peers([], _purpose, _max_hops, _visited), do: {:ok, []}
  defp try_suggested_peers(_peers, _purpose, max_hops, _visited) when max_hops <= 0, do: {:ok, []}
  defp try_suggested_peers([peer_id | rest], purpose, max_hops, visited) do
    if MapSet.member?(visited, peer_id) do
      try_suggested_peers(rest, purpose, max_hops, visited)
    else
      case lookup_peer(peer_id) do
        {:ok, peer_pid} ->
          case recall(peer_pid, purpose) do
            [] -> try_suggested_peers(rest, purpose, max_hops, MapSet.put(visited, peer_id))
            traces -> {:ok, traces}
          end
        {:error, _} ->
          try_suggested_peers(rest, purpose, max_hops, visited)
      end
    end
  end

  defp lookup_peer(peer_id) do
    case Registry.lookup(Kudzu.Registry, {:id, peer_id}) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end

  defp process_message(%{type: :ping, origin: origin, timestamp: ts}, state) do
    new_clock = VectorClock.merge(state.clock, ts) |> VectorClock.increment(state.id)
    new_peers = Map.update(state.peers, origin, @proximity_boost, &min(&1 + @proximity_boost, @max_proximity))
    response = Protocol.pong(state.id, new_clock)
    {response, %{state | clock: new_clock, peers: new_peers}}
  end

  defp process_message(%{type: :query, origin: origin, purpose: purpose, timestamp: ts, max_hops: _hops}, state) do
    new_clock = VectorClock.merge(state.clock, ts) |> VectorClock.increment(state.id)
    matching_traces = state.traces
    |> Map.values()
    |> Enum.filter(&(&1.purpose == purpose))

    # Suggest peers if we don't have matches
    suggested = if matching_traces == [] do
      state.peers
      |> Enum.sort_by(fn {_id, score} -> score end, :desc)
      |> Enum.take(3)
      |> Enum.map(fn {id, _} -> id end)
      |> Enum.reject(&(&1 == origin))
    else
      []
    end

    response = Protocol.query_response(state.id, new_clock, matching_traces, suggested)
    {response, %{state | clock: new_clock}}
  end

  defp process_message(%{type: :trace_share, origin: origin, trace: trace, timestamp: ts}, state) do
    new_clock = VectorClock.merge(state.clock, ts) |> VectorClock.increment(state.id)
    followed = Trace.follow(trace, state.id)
    new_traces = Map.put(state.traces, followed.id, followed)
    new_peers = Map.update(state.peers, origin, @proximity_boost, &min(&1 + @proximity_boost, @max_proximity))
    response = Protocol.ack(state.id, new_clock)
    {response, %{state | traces: new_traces, clock: new_clock, peers: new_peers}}
  end

  defp process_message(%{type: :reconstruction_request, trace_id: trace_id, timestamp: ts}, state) do
    new_clock = VectorClock.merge(state.clock, ts) |> VectorClock.increment(state.id)
    trace = Map.get(state.traces, trace_id)
    response = Protocol.reconstruction_response(state.id, new_clock, trace)
    {response, %{state | clock: new_clock}}
  end

  defp process_message(_unknown, state) do
    {nil, state}
  end

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  # Beam-let helper functions

  defp do_discover_beamlets(state) do
    capabilities = [:file_read, :file_write, :http_get, :http_post, :shell_exec, :scheduling]

    new_beamlets = capabilities
    |> Enum.map(fn cap ->
      beamlets = Beamlet.list_beamlets(cap)
      |> Enum.map(fn {_pid, id} -> {id, @proximity_boost} end)
      |> Map.new()
      {cap, beamlets}
    end)
    |> Enum.reject(fn {_cap, beamlets} -> map_size(beamlets) == 0 end)
    |> Map.new()

    # Merge with existing, keeping higher proximity scores
    merged = Map.merge(state.beamlets, new_beamlets, fn _cap, old, new ->
      Map.merge(old, new, fn _id, old_score, new_score -> max(old_score, new_score) end)
    end)

    %{state | beamlets: merged}
  end

  defp boost_beamlet_proximity(state, capability) do
    # Find the beam-let we just used and boost its proximity
    case Beamlet.find_beamlet(capability) do
      {:ok, pid} ->
        try do
          id = GenServer.call(pid, :get_id, 1000)
          cap_beamlets = Map.get(state.beamlets, capability, %{})
          new_score = min(Map.get(cap_beamlets, id, 0) + @proximity_boost, @max_proximity)
          new_cap_beamlets = Map.put(cap_beamlets, id, new_score)
          %{state | beamlets: Map.put(state.beamlets, capability, new_cap_beamlets)}
        catch
          :exit, _ -> state
        end
      _ ->
        state
    end
  end

  defp get_io_capability(%{op: op}) do
    case op do
      :file_read -> :file_read
      :file_write -> :file_write
      :file_exists -> :file_read
      :file_list -> :file_read
      :http_get -> :http_get
      :http_post -> :http_post
      :shell_exec -> :shell_exec
      _ -> :file_read
    end
  end
end
