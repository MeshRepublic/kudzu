defmodule Kudzu.Brain do
  @moduledoc """
  Brain GenServer — always-awake autonomous learning with tiered reasoning.

  The Brain is the autonomous executive layer of Kudzu. This module owns
  the GenServer lifecycle and message routing; the actual cognitive work
  lives in focused sub-modules:

  * `Kudzu.Brain.Reasoning` — autonomous-cycle three-tier pipeline
    (reflexes → silo inference → Claude) plus Claude-response
    distillation.
  * `Kudzu.Brain.Chat` — interactive chat: synchronous and streaming
    four-tier escalation (recall → silo inference → web → Claude),
    Thought integration, and directive parsing (`Learn X`, `progress`).
  * `Kudzu.Brain.Learning` — directed learning-goal lifecycle plus
    persistence/restoration through the kudzu_brain hologram.
  * `Kudzu.Brain.Activities` — the always-awake activity tick (health,
    distillation, storage, web learning, curiosity) and the hologram
    pre-check gate.

  ## Wake Cycle

  Every `@activity_tick` (10s) the Brain dispatches one overdue
  activity via `Activities.run_cycle/1`, decays working memory, and
  reschedules itself.

  ## Chat

  `chat/2` and `chat_stream/3` enter the four-tier escalation in
  `Chat.chat_reason/3` / `Chat.chat_reason_stream/4`.

  ## Desires

  The Brain maintains a list of high-level desires that guide its
  reasoning. These are aspirational goals, not tasks — they shape what
  the Brain pays attention to and how it prioritizes anomalies.
  """

  use GenServer
  require Logger

  alias Kudzu.Brain.Activities
  alias Kudzu.Brain.ActivityIndicator
  alias Kudzu.Brain.Budget
  alias Kudzu.Brain.Chat
  alias Kudzu.Brain.Learning
  alias Kudzu.Brain.WorkingMemory

  # Note: Reasoning, Reflexes, Thought, Distiller, etc. are referenced
  # through their fully-qualified names from the GenServer callbacks
  # (handle_info({:trace_stored, …}) → Kudzu.Brain.Distiller.distill/2).
  # All other access lives inside extracted sub-modules.

  @initial_desires [
    "Maintain Kudzu system health and recover from failures",
    "Build accurate self-model of architecture, resources, and capabilities",
    "Learn from every observation — discover patterns in system behavior",
    "Identify knowledge gaps and pursue self-education to fill them",
    "Plan for increased fault tolerance and distributed operation"
  ]

  @default_cycle_interval 300_000
  @init_delay 2_000
  @retry_delay 10_000

  defstruct [
    :hologram_id,
    :hologram_pid,
    :current_session,
    :budget,
    :working_memory,
    desires: @initial_desires,
    status: :active,
    cycle_interval: @default_cycle_interval,
    cycle_count: 0,
    config: %{},
    # Activity tracking (always-awake mode)
    last_health_check: nil,
    last_curiosity: nil,
    last_web_learning: nil,
    last_distillation: nil,
    last_storage_check: nil,
    web_learning_active: false,
    researched_topics: MapSet.new(),
    learning_goals: []
  ]

  @typedoc "Internal Brain GenServer state."
  @type t :: %__MODULE__{}

  # ── Client API ──────────────────────────────────────────────────────

  @doc "Start the Brain GenServer under supervision."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Return the current Brain state (for inspection and testing)."
  @spec get_state() :: %__MODULE__{}
  def get_state do
    GenServer.call(__MODULE__, :get_state)
  end

  @doc "Force an immediate wake cycle outside the normal schedule."
  @spec wake_now() :: :ok
  def wake_now do
    GenServer.cast(__MODULE__, :wake_now)
  end

  @doc """
  Send a chat message to the Brain for three-tier reasoning.

  The message is processed through the same reasoning pipeline as
  autonomous wake cycles, but adapted for interactive conversation:

  1. Tier 1 — Reflexes check for known patterns
  2. Thinking Layer — Thought process with working memory priming
  3. Tier 3 — Claude API for novel questions

  Returns `{:ok, %{response: text, tier: 1|2|3|:thought, tool_calls: list, cost: float}}`

  ## Options

    * `:timeout` — GenServer call timeout in ms (default 120_000)
  """
  @spec chat(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def chat(message, opts \\ []) do
    GenServer.call(__MODULE__, {:chat, message, opts}, 300_000)
  end

  @doc """
  Send a streaming chat message to the Brain.

  Like `chat/2` but asynchronous — the Brain processes the message via
  `GenServer.cast` and sends streaming messages to `stream_to`:

    * `{:thinking, tier, description}` — progress indicator for each tier
    * `{:chunk, text}` — incremental response text (Tier 3 streams from Claude)
    * `{:tool_use, [tool_names]}` — when Claude invokes tools during reasoning
    * `{:done, %{tier: integer, tool_calls: list, cost: float}}` — completion signal

  Tiers 1 and 2 send the full response as a single `{:chunk, text}`.
  Tier 3 streams incrementally via `Claude.reason_stream`.

  ## Options

    * Same as `chat/2`
  """
  @spec chat_stream(String.t(), pid(), keyword()) :: :ok
  def chat_stream(message, stream_to, opts \\ []) do
    GenServer.cast(__MODULE__, {:chat_stream, message, stream_to, opts})
  end

  @doc """
  Return a status snapshot of the Brain for metrics endpoints.

  Returns `%{status: :not_running}` if the Brain GenServer is not
  registered (e.g. application starting up).
  """
  @spec status() :: map()
  def status do
    GenServer.call(__MODULE__, :status, 5_000)
  rescue
    _ -> %{status: :not_running}
  end

  # ── Server Callbacks ────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    api_key = System.get_env("ANTHROPIC_API_KEY")

    config = %{
      model: "claude-sonnet-4-20250514",
      api_key: api_key,
      max_turns: 10,
      budget_limit_monthly: 100.0
    }

    state = %__MODULE__{config: config, budget: Budget.new()}

    # Schedule hologram initialization after a short delay so the rest of
    # the supervision tree has time to start.
    Process.send_after(self(), :init_hologram, @init_delay)

    Logger.info("[Brain] Started — scheduling hologram init in #{@init_delay}ms")
    {:ok, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      status: state.status,
      cycle_count: state.cycle_count,
      hologram_id: state.hologram_id,
      learning_goals: length(state.learning_goals),
      researched_topics: MapSet.size(state.researched_topics),
      web_learning_active: state.web_learning_active,
      last_health_check: state.last_health_check,
      last_curiosity: state.last_curiosity,
      last_web_learning: state.last_web_learning,
      last_distillation: state.last_distillation
    }

    {:reply, status, state}
  end

  def handle_call({:chat, _message, _opts}, _from, %{hologram_id: nil} = state) do
    {:reply, {:error, :not_ready}, state}
  end

  def handle_call({:chat, message, opts}, _from, state) do
    Logger.info("[Brain] Chat message received: #{String.slice(message, 0, 100)}")
    ActivityIndicator.start_activity(:reasoning, "thinking: #{String.slice(message, 0, 60)}")

    # Record user message as a trace
    record_trace(state, :observation, %{
      source: "human_chat",
      content: message
    })

    # Run reasoning pipeline adapted for chat
    {response_text, tier, tool_calls, cost, new_state} = Chat.chat_reason(state, message, opts)
    ActivityIndicator.stop_activity(:reasoning)

    # Record brain response as a trace
    record_trace(new_state, :thought, %{
      source: "brain_chat_response",
      content: String.slice(response_text, 0, 500),
      tier: tier
    })

    result = %{
      response: response_text,
      tier: tier,
      tool_calls: tool_calls,
      cost: cost
    }

    {:reply, {:ok, result}, new_state}
  end

  @impl true
  def handle_cast(:wake_now, state) do
    send(self(), :wake_cycle)
    {:noreply, state}
  end

  def handle_cast({:chat_stream, _message, stream_to, _opts}, %{hologram_id: nil} = state) do
    send(stream_to, {:done, %{tier: 0, tool_calls: [], cost: 0.0, error: "not_ready"}})
    {:noreply, state}
  end

  def handle_cast({:chat_stream, message, stream_to, opts}, state) do
    Logger.info("[Brain] Streaming chat message received: #{String.slice(message, 0, 100)}")

    # Record user message as trace
    record_trace(state, :observation, %{
      source: "human_chat",
      content: message,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    })

    # Run streaming reasoning
    {response_text, tier, tool_calls, cost, new_state} =
      Chat.chat_reason_stream(state, message, stream_to, opts)

    # Record brain response as trace
    record_trace(new_state, :thought, %{
      source: "brain_chat_response",
      content: String.slice(response_text, 0, 2000),
      tier: tier,
      tool_calls: tool_calls,
      user_message: String.slice(message, 0, 500)
    })

    # Signal completion
    send(stream_to, {:done, %{tier: tier, tool_calls: tool_calls, cost: cost}})

    {:noreply, new_state}
  end

  @impl true
  def handle_info(:init_hologram, state) do
    case Activities.init_hologram(state.desires) do
      {:ok, pid, id} ->
        Logger.info("[Brain] Hologram ready — id=#{id}")

        try do
          Kudzu.Brain.SelfModel.init()
          Logger.info("[Brain] Self-model silo initialized")
        catch
          kind, reason ->
            Logger.warning("[Brain] Self-model init failed: #{inspect({kind, reason})}")
        end

        # brain_knowledge silo — destination for triples distilled out of
        # Claude responses (Tier 3 reasoning). Created here at boot so
        # `Kudzu.Brain.Reasoning.distill_claude_response/2` never silently
        # drops triples on a missing-silo path.
        try do
          case Kudzu.Silo.create("brain_knowledge") do
            {:ok, _silo_pid} ->
              Logger.info("[Brain] brain_knowledge silo ready")

            {:error, reason} ->
              Logger.warning("[Brain] brain_knowledge silo init failed: #{inspect(reason)}")
          end
        catch
          kind, reason ->
            Logger.warning(
              "[Brain] brain_knowledge silo init crashed: #{inspect({kind, reason})}"
            )
        end

        new_state = %{state | hologram_pid: pid, hologram_id: id}
        new_state = %{new_state | working_memory: WorkingMemory.new()}
        # Restore persisted learning goals
        goals = Learning.restore_learning_goals(pid)
        new_state = %{new_state | learning_goals: goals}
        topics = Learning.restore_researched_topics(pid)
        new_state = %{new_state | researched_topics: topics}

        if goals != [] do
          active = Enum.find(goals, &(&1.status == :active))

          if active do
            Logger.info(
              "[Brain] Restored learning goal: #{active.topic} (#{active.completed_count}/#{length(active.topics)})"
            )
          end
        end

        Activities.schedule_next()
        Phoenix.PubSub.subscribe(Kudzu.PubSub, "traces:new")
        {:noreply, new_state}

      {:error, reason} ->
        Logger.warning(
          "[Brain] Hologram init failed: #{inspect(reason)} — retrying in #{@retry_delay}ms"
        )

        Process.send_after(self(), :init_hologram, @retry_delay)
        {:noreply, state}
    end
  end

  # Backward compatibility: :wake_cycle forwards to :activity_cycle
  def handle_info(:wake_cycle, state) do
    send(self(), :activity_cycle)
    {:noreply, state}
  end

  def handle_info(:activity_cycle, %{hologram_id: nil} = state) do
    Logger.debug("[Brain] Skipping activity cycle — no hologram attached")
    Activities.schedule_next()
    {:noreply, state}
  end

  def handle_info(:activity_cycle, state) do
    state = Activities.run_cycle(state)
    Activities.schedule_next()
    {:noreply, state}
  end

  def handle_info(:web_learning_done, state) do
    {:noreply, %{state | web_learning_active: false}}
  end

  def handle_info({:learning_progress, goal_id, _topic_index, result}, state) do
    alias Kudzu.Brain.LearningGoal

    goals =
      Enum.map(state.learning_goals, fn goal ->
        if goal.id == goal_id do
          case result do
            :complete -> LearningGoal.complete_current(goal)
            :failed -> LearningGoal.fail_current(goal)
          end
        else
          goal
        end
      end)

    # If the active goal just completed, activate the next queued goal
    goals = Activities.maybe_activate_next_goal(goals)

    # Log progress
    active = Enum.find(goals, &(&1.id == goal_id))

    if active do
      total = length(active.topics)
      done = active.completed_count
      Logger.info("[Brain] Learning progress: #{active.topic} — #{done}/#{total} (#{result})")

      if active.status == :complete do
        Logger.info("[Brain] Learning goal complete: #{active.topic}")

        record_trace(state, :discovery, %{
          source: "learning_goal_complete",
          topic: active.topic,
          goal_id: goal_id,
          completed: active.completed_count,
          failed: active.failed_count,
          total: total
        })
      end
    end

    Learning.persist_learning_goals(state, goals)
    {:noreply, %{state | learning_goals: goals}}
  end

  def handle_info({:web_learning_complete, question}, state) do
    normalized = question |> String.downcase() |> String.replace(~r/[^\w\s]/, "") |> String.trim()
    {:noreply, %{state | researched_topics: MapSet.put(state.researched_topics, normalized)}}
  end

  def handle_info({:thought_result, thought_id, result}, state) do
    Logger.debug("[Brain] Received async thought result: #{thought_id}")
    state = Chat.integrate_thought(state, result)
    {:noreply, state}
  end

  @impl true
  def handle_info({:trace_stored, record}, state) do
    if record.importance in [:critical, :high] do
      Logger.info("[Brain] High-importance trace detected, triggering distillation")

      Task.start(fn ->
        text =
          case record.reconstruction_hint do
            %{content: c} when is_binary(c) -> c
            %{"content" => c} when is_binary(c) -> c
            _ -> nil
          end

        if text && String.length(text) > 20 do
          try do
            # Pass live silo domains so find_knowledge_gaps/2 actually
            # filters against known concepts, and persist extracted
            # chains into brain_knowledge (the silo created for
            # Brain-side distillations — same destination as Tier-3
            # Claude-response distillations).
            silo_domains =
              Kudzu.Silo.list()
              |> Enum.map(fn {domain, _, _} -> domain end)
              |> Enum.reject(&(&1 == nil))

            result = Kudzu.Brain.Distiller.distill(text, silo_domains)

            Enum.each(result.chains, fn {subject, relation, object} ->
              try do
                Kudzu.Silo.store_relationship("brain_knowledge", {subject, relation, object})
              catch
                _, _ -> :ok
              end
            end)
          rescue
            _ -> :ok
          end
        end
      end)
    end

    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.debug("[Brain] Unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # ── Trace Recording ─────────────────────────────────────────────────

  @doc false
  # Internal helper for sub-modules (Reasoning, Chat, Activities, …) that
  # need to record a trace through the Brain's hologram. Best-effort:
  # silently swallows errors so a hologram outage cannot crash the Brain.
  def record_trace(state, purpose, data) do
    if state.hologram_pid do
      try do
        Kudzu.Hologram.record_trace(state.hologram_pid, purpose, data)
      rescue
        _ -> :ok
      end
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────

  @doc false
  # Ensure a value is a plain map (not a struct) for trace serialization.
  # Internal helper used by sub-modules building trace payloads.
  def ensure_map(%_{} = struct), do: Map.from_struct(struct)
  def ensure_map(map) when is_map(map), do: map
  def ensure_map(other), do: %{value: inspect(other)}
end
