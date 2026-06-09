defmodule Kudzu.Brain do
  @moduledoc """
  Brain GenServer — always-awake autonomous learning with tiered reasoning.

  The Brain is the autonomous executive layer of Kudzu. It wakes periodically,
  runs health checks (the "pre-check gate"), and when anomalies are detected,
  reasons about them through a multi-tier pipeline enhanced by a thinking layer:

  1. **Tier 1 — Reflexes**: Instant pattern → action mappings, zero cost.
  2. **Thinking Layer — Thought**: Ephemeral reasoning via silo HRR activation,
     chain building, and working memory integration.
  3. **Tier 3 — Claude API**: LLM-driven reasoning for novel situations,
     followed by Distiller extraction of knowledge back into silos.

  ## Wake Cycle

  Every `cycle_interval` milliseconds (default 5 minutes), the Brain:

  1. Runs `pre_check/1` — a battery of health checks
  2. If all nominal → explores curiosity-driven questions
  3. If anomalies detected → enters the reasoning pipeline
  4. Decays working memory and schedules the next wake cycle

  ## Chat

  The Brain supports interactive chat via `chat/2`. Messages flow through:

  1. Tier 1 — Reflexes check for known patterns
  2. Tier 2 — Semantic Recall from stored traces (free)
  3. Tier 3 — Web Search for external knowledge (free)
  4. Tier 4 — Silo Inference via Thought reasoning (free)
  5. Tier 5 — Claude API as absolute last resort (paid)
  6. Distiller extracts knowledge from Claude responses

  ## Desires

  The Brain maintains a list of high-level desires that guide its reasoning.
  These are aspirational goals, not tasks — they shape what the Brain pays
  attention to and how it prioritizes anomalies.
  """

  use GenServer
  require Logger

  alias Kudzu.Brain.ActivityIndicator
  alias Kudzu.Brain.Budget
  alias Kudzu.Brain.Chat
  alias Kudzu.Brain.Curiosity
  alias Kudzu.Brain.Distiller
  alias Kudzu.Brain.Learning
  alias Kudzu.Brain.Reasoning
  alias Kudzu.Brain.Thought
  alias Kudzu.Brain.Vectors.Router, as: VectorRouter
  alias Kudzu.Brain.WorkingMemory

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
  @consolidation_staleness_ms 1_200_000

  # Activity loop intervals (always-awake mode)
  @activity_tick 10_000          # Check for overdue activities every 10s
  @health_interval 60_000        # Health checks: every 1 minute
  @curiosity_interval 120_000    # Curiosity exploration: every 2 minutes
  @web_learning_interval 300_000 # Web research: every 5 minutes
  @distillation_interval 600_000 # Knowledge distillation: every 10 minutes
  @storage_interval 1_800_000    # Storage monitoring: every 30 minutes

  # Curriculum prompt moved to CurriculumGenerator module

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

  @doc "Get Brain status for metrics"
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
    case init_hologram() do
      {:ok, pid, id} ->
        Logger.info("[Brain] Hologram ready — id=#{id}")
        try do
          Kudzu.Brain.SelfModel.init()
          Logger.info("[Brain] Self-model silo initialized")
        catch
          kind, reason ->
            Logger.warning("[Brain] Self-model init failed: #{inspect({kind, reason})}")
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
            Logger.info("[Brain] Restored learning goal: #{active.topic} (#{active.completed_count}/#{length(active.topics)})")
          end
        end
        schedule_activity_cycle()
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
    schedule_activity_cycle()
    {:noreply, state}
  end

  def handle_info(:activity_cycle, state) do
    now = System.monotonic_time(:millisecond)
    state = %{state | status: :active}

    # Run the most overdue activity (wrapped in trap_exit + try/catch for resilience)
    # Trap exits temporarily so linked Task.async crashes don't kill the Brain
    old_trap = Process.flag(:trap_exit, true)
    state =
      try do
        cond do
          overdue?(state.last_health_check, @health_interval, now) ->
            Logger.debug("[Brain] Activity: health check")
            ActivityIndicator.start_activity(:health_check, "health check")
            result = run_health_check(%{state | last_health_check: now})
            ActivityIndicator.stop_activity(:health_check)
            result

          overdue?(state.last_distillation, @distillation_interval, now) ->
            Logger.debug("[Brain] Activity: distillation")
            ActivityIndicator.start_activity(:distilling, "distilling knowledge")
            result = run_distillation_cycle(%{state | last_distillation: now})
            ActivityIndicator.stop_activity(:distilling)
            result

          overdue?(state.last_storage_check, @storage_interval, now) ->
            Logger.debug("[Brain] Activity: storage check")
            ActivityIndicator.start_activity(:storage, "checking storage")
            result = run_storage_check(%{state | last_storage_check: now})
            ActivityIndicator.stop_activity(:storage)
            result

          overdue?(state.last_web_learning, @web_learning_interval, now) and not state.web_learning_active ->
            Logger.debug("[Brain] Activity: web learning")
            run_web_learning(%{state | last_web_learning: now, web_learning_active: true})

          overdue?(state.last_curiosity, @curiosity_interval, now) ->
            Logger.debug("[Brain] Activity: curiosity")
            run_curiosity(%{state | last_curiosity: now})

          true ->
            state  # Nothing overdue — idle tick
        end
      catch
        kind, reason ->
          Logger.warning("[Brain] Activity crashed: #{inspect(kind)}: #{inspect(reason)}")
          state  # Return unchanged state on crash
      after
        Process.flag(:trap_exit, old_trap)
        # Flush any trapped EXIT messages so they don't pile up
        receive do
          {:EXIT, _pid, _reason} -> :ok
        after
          0 -> :ok
        end
      end

    # Decay working memory periodically
    state = if state.working_memory do
      %{state | working_memory: WorkingMemory.decay(state.working_memory, 0.01)}
    else
      state
    end

    schedule_activity_cycle()
    {:noreply, state}
  end

  def handle_info(:web_learning_done, state) do
    {:noreply, %{state | web_learning_active: false}}
  end

  def handle_info({:learning_progress, goal_id, _topic_index, result}, state) do
    alias Kudzu.Brain.LearningGoal

    goals = Enum.map(state.learning_goals, fn goal ->
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
    goals = maybe_activate_next_goal(goals)

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
        text = case record.reconstruction_hint do
          %{content: c} when is_binary(c) -> c
          %{"content" => c} when is_binary(c) -> c
          _ -> nil
        end
        if text && String.length(text) > 20 do
          try do
            Kudzu.Brain.Distiller.distill(text, [])
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

  # ── Pre-Check Gate ──────────────────────────────────────────────────

  defp pre_check(_state) do
    checks = [
      check_consolidation_recency(),
      check_hologram_count(),
      check_storage_health()
    ]

    anomalies =
      checks
      |> Enum.filter(fn
        {:anomaly, _} -> true
        _ -> false
      end)
      |> Enum.map(fn {:anomaly, detail} -> detail end)

    case anomalies do
      [] -> :sleep
      list -> {:wake, list}
    end
  end

  defp check_consolidation_recency do
    stats = Kudzu.Consolidation.stats()
    last = Map.get(stats, :last_consolidation)

    cond do
      is_nil(last) ->
        {:anomaly,
         %{check: :consolidation_recency, reason: "No consolidation has ever run"}}

      is_struct(last, DateTime) ->
        age_ms = DateTime.diff(DateTime.utc_now(), last, :millisecond)

        if age_ms > @consolidation_staleness_ms do
          {:anomaly,
           %{
             check: :consolidation_recency,
             reason:
               "Last consolidation was #{div(age_ms, 1_000)}s ago " <>
                 "(threshold: #{div(@consolidation_staleness_ms, 1_000)}s)",
             age_ms: age_ms
           }}
        else
          {:nominal, :consolidation_recency}
        end

      true ->
        # last_consolidation is a non-nil, non-DateTime value — treat as nominal
        # (could be a monotonic timestamp or other internal representation)
        {:nominal, :consolidation_recency}
    end
  rescue
    e ->
      {:anomaly,
       %{
         check: :consolidation_recency,
         reason: "Consolidation stats failed: #{Exception.message(e)}"
       }}
  end

  defp check_hologram_count do
    count = Kudzu.Application.hologram_count()

    if count >= 1 do
      {:nominal, :hologram_count}
    else
      {:anomaly,
       %{
         check: :hologram_count,
         reason: "No active holograms (count: #{count})",
         count: count
       }}
    end
  rescue
    e ->
      {:anomaly,
       %{
         check: :hologram_count,
         reason: "Hologram count check failed: #{Exception.message(e)}"
       }}
  end

  defp check_storage_health do
    # Query for any observation traces with limit 1 as a liveness check.
    # We don't care about the result — only that Storage responds without crashing.
    _result = Kudzu.Storage.query(:observation, limit: 1)
    {:nominal, :storage_health}
  rescue
    e ->
      {:anomaly,
       %{
         check: :storage_health,
         reason: "Storage query failed: #{Exception.message(e)}"
       }}
  end

  # ── Hologram Init ───────────────────────────────────────────────────

  defp init_hologram do
    case Kudzu.Application.find_by_purpose("kudzu_brain") do
      [{pid, id} | _] ->
        Logger.info("[Brain] Found existing kudzu_brain hologram: #{id}")
        {:ok, pid, id}

      [] ->
        Logger.info("[Brain] Spawning new kudzu_brain hologram")

        case Kudzu.Application.spawn_hologram(
               purpose: "kudzu_brain",
               desires: @initial_desires,
               cognition: false,
               constitution: :kudzu_evolve
             ) do
          {:ok, pid} ->
            id = Kudzu.Hologram.get_id(pid)
            {:ok, pid, id}

          {:error, reason} ->
            {:error, reason}
        end
    end
  rescue
    e ->
      {:error, {:exception, Exception.message(e)}}
  end

  # ── Scheduling ──────────────────────────────────────────────────────

  defp schedule_activity_cycle do
    Process.send_after(self(), :activity_cycle, @activity_tick)
  end

  defp overdue?(nil, _interval, _now), do: true
  defp overdue?(last, interval, now) do
    (now - last) >= interval
  end

  # ── Activity Handlers ────────────────────────────────────────────

  defp run_health_check(state) do
    new_count = state.cycle_count + 1
    state = %{state | cycle_count: new_count}

    case pre_check(state) do
      :sleep ->
        state

      {:wake, anomalies} ->
        Logger.info("[Brain] Health check: #{length(anomalies)} anomalies")
        Reasoning.reason(state, anomalies)
    end
  end

  defp run_curiosity(state) do
    # Run curiosity asynchronously to avoid blocking the Brain
    brain_pid = self()
    hologram_pid = state.hologram_pid
    desires = state.desires
    wm = state.working_memory || WorkingMemory.new()
    silo_domains = get_silo_domains_for_activity()

    Task.start(fn ->
      try do
        questions = Curiosity.generate(desires, wm, silo_domains)

        if question = List.first(questions) do
          thought_result = Thought.run(question,
            monarch_pid: brain_pid,
            timeout: 8_000,
            priming: []
          )

          if hologram_pid do
            Kudzu.Hologram.record_trace(hologram_pid, :thought, %{
              source: "curiosity",
              question: question,
              resolution: thought_result.resolution,
              confidence: thought_result.confidence
            })
          end
        end
      catch
        kind, reason ->
          Logger.warning("[Brain] Async curiosity crashed: #{inspect(kind)}: #{inspect(reason)}")
      end
    end)

    state
  end

  defp run_web_learning(state) do
    alias Kudzu.Brain.LearningGoal

    # Priority: active learning goal topics over curiosity questions
    case get_learning_topic(state) do
      {:learning, topic, goal_id, topic_index} ->
        Logger.info("[Brain] Web learning: curriculum topic '#{topic}' (goal=#{goal_id})")
        brain_pid = self()
        hologram_pid = state.hologram_pid

        Task.start(fn ->
          ActivityIndicator.start_activity(:learning, "learning: #{String.slice(topic, 0, 50)}")
          try do
            result = VectorRouter.learn(topic)

            case result do
              {:ok, findings} ->
                vector_name = Map.get(findings, :vector, "unknown")
                ActivityIndicator.stop_activity(:learning)
                if hologram_pid do
                  Kudzu.Hologram.record_trace(hologram_pid, :learning, %{
                    source: "directed_learning",
                    goal_id: goal_id,
                    topic: topic,
                    vector: vector_name,
                    content_preview: findings.content |> String.slice(0, 200)
                  })
                end
                send(brain_pid, {:learning_progress, goal_id, topic_index, :complete})
                send(brain_pid, :web_learning_done)

              {:error, reason} ->
                ActivityIndicator.stop_activity(:learning)
                Logger.warning("[Brain] Learning topic failed: #{topic} — #{inspect(reason)}")
                send(brain_pid, {:learning_progress, goal_id, topic_index, :failed})
                send(brain_pid, :web_learning_done)
            end
          catch
            kind, reason ->
              ActivityIndicator.stop_activity(:learning)
              Logger.warning("[Brain] Learning topic crashed: #{inspect(kind)}: #{inspect(reason)}")
              send(brain_pid, {:learning_progress, goal_id, topic_index, :failed})
          end
        end)

        state

      :no_learning_topic ->
        # Fall back to curiosity-driven web learning (existing behavior)
        run_curiosity_web_learning(state)
    end
  end

  defp get_learning_topic(state) do
    alias Kudzu.Brain.LearningGoal

    case Enum.find(state.learning_goals, &(&1.status == :active)) do
      %LearningGoal{id: goal_id} = goal ->
        case LearningGoal.next_topic(goal) do
          {topic, index} -> {:learning, topic, goal_id, index}
          nil -> :no_learning_topic
        end
      nil ->
        :no_learning_topic
    end
  end


  defp run_curiosity_web_learning(state) do
    # Generate a curiosity question, then research it on the web
    # Run asynchronously so we don't block the Brain GenServer
    silo_domains = get_silo_domains_for_activity()
    wm = state.working_memory || WorkingMemory.new()
    questions = Curiosity.generate(state.desires, wm, silo_domains)

    # Filter out already-researched topics
    question =
      questions
      |> Enum.reject(fn q ->
        normalized = q |> String.downcase() |> String.replace(~r/[^\w\s]/, "") |> String.trim()
        MapSet.member?(state.researched_topics, normalized)
      end)
      |> List.first()

    if question do
      brain_pid = self()
      hologram_pid = state.hologram_pid

      # Fire-and-forget: run web learning in a separate unlinked process
      Task.start(fn ->
        ActivityIndicator.start_activity(:curiosity_learn, "curious: #{String.slice(question, 0, 50)}")
        try do
          # First try Thought
          thought_result = Thought.run(question,
            monarch_pid: brain_pid,
            timeout: 8_000,
            priming: []
          )

          if thought_result.resolution in [:no_match, :partial] do
            # Thought didn't know — research via vectors
            case VectorRouter.learn(question) do
              {:ok, result} ->
                ActivityIndicator.stop_activity(:curiosity_learn)
                # Record trace directly on the hologram
                if hologram_pid do
                  Kudzu.Hologram.record_trace(hologram_pid, :discovery, %{
                    source: "vector_learning",
                    question: question,
                    vector: Map.get(result, :vector, "unknown"),
                    content_preview: result.content |> String.slice(0, 200)
                  })
                end

                # Notify brain to track as researched
                send(brain_pid, {:web_learning_complete, question})

              {:error, reason} ->
                ActivityIndicator.stop_activity(:curiosity_learn)
                Logger.warning("[Brain] Vector learning failed: #{inspect(reason)}")
            end
          else
            ActivityIndicator.stop_activity(:curiosity_learn)
            Logger.debug("[Brain] Web learning skipped — Thought resolved: #{question}")
          end
        catch
          kind, reason ->
            ActivityIndicator.stop_activity(:curiosity_learn)
            Logger.warning("[Brain] Async web learning crashed: #{inspect(kind)}: #{inspect(reason)}")
        end
      end)

      state
    else
      state
    end
  end


  defp run_distillation_cycle(state) do
    Logger.info("[Brain] Running distillation cycle (Phase 3)")

    try do
      result = Distiller.review_knowledge()

      record_trace(state, :observation, %{
        source: "distillation_cycle",
        action: "knowledge_review",
        reviewed: result.reviewed,
        merged: result.merged,
        pruned: result.pruned
      })

      Logger.info(
        "[Brain] Distillation complete: " <>
        "#{result.reviewed} reviewed, #{result.merged} merged, #{result.pruned} pruned"
      )
    rescue
      e ->
        Logger.warning("[Brain] Distillation cycle failed: #{inspect(e)}")
    catch
      kind, reason ->
        Logger.warning("[Brain] Distillation cycle crashed: #{inspect(kind)}: #{inspect(reason)}")
    end

    state
  end

  defp run_storage_check(state) do
    try do
      stats = Kudzu.Storage.detailed_stats()

      Logger.info(
        "[Brain] Storage: hot=#{stats.hot_count} entries (#{div(stats.hot_bytes, 1024)}KB), " <>
        "warm=#{div(stats.warm_bytes, 1024)}KB, " <>
        "total=#{div(stats.total_bytes, 1048576)}MB, " <>
        "utilization=#{stats.utilization}%"
      )

      # Embed unembedded traces (batch of 3 per cycle)
      embedded = try do
        Kudzu.Storage.embed_batch(3)
      catch
        _, _ -> 0
      end
      if embedded > 0 do
        Logger.debug("[Brain] Embedded #{embedded} traces")
      end

      # Evict if utilization exceeds 80%
      evicted =
        if stats.utilization > 80.0 do
          count = Kudzu.Storage.evict_lowest(100)
          Logger.warning("[Brain] Storage utilization #{stats.utilization}% > 80% — evicted #{count} traces")
          count
        else
          0
        end

      # Record metrics as a trace
      record_trace(state, :observation, %{
        type: "storage_check",
        hot_count: stats.hot_count,
        hot_bytes: stats.hot_bytes,
        warm_bytes: stats.warm_bytes,
        total_bytes: stats.total_bytes,
        utilization: stats.utilization,
        evicted: evicted
      })

      state
    catch
      kind, reason ->
        Logger.warning("[Brain] Storage check failed: #{inspect(kind)}: #{inspect(reason)}")
        state
    end
  end

  defp get_silo_domains_for_activity do
    try do
      case Kudzu.Silo.list() do
        domains when is_list(domains) ->
          Enum.map(domains, fn
            {domain, _, _} -> domain
            domain when is_binary(domain) -> domain
            _ -> nil
          end) |> Enum.reject(&is_nil/1)
        _ -> []
      end
    catch
      _, _ -> []
    end
  end

  defp maybe_activate_next_goal(goals) do
    has_active = Enum.any?(goals, &(&1.status == :active))

    if has_active do
      goals
    else
      case Enum.find_index(goals, &(&1.status == :queued)) do
        nil -> goals
        idx ->
          List.update_at(goals, idx, &(%{&1 | status: :active}))
      end
    end
  end

end
