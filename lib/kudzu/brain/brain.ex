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

  alias Kudzu.Brain.Budget
  alias Kudzu.Brain.Reflexes
  alias Kudzu.Brain.InferenceEngine
  alias Kudzu.Brain.PromptBuilder
  alias Kudzu.Brain.WorkingMemory
  alias Kudzu.Brain.Thought
  alias Kudzu.Brain.Curiosity
  alias Kudzu.Brain.Distiller
  alias Kudzu.Brain.WebLearner
  alias Kudzu.Brain.Vectors.Router, as: VectorRouter
  alias Kudzu.Brain.CurriculumGenerator
  alias Kudzu.Brain.ActivityIndicator

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
    {response_text, tier, tool_calls, cost, new_state} = chat_reason(state, message, opts)
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
      chat_reason_stream(state, message, stream_to, opts)

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
        goals = restore_learning_goals(pid)
        new_state = %{new_state | learning_goals: goals}
        if goals != [] do
          active = Enum.find(goals, &(&1.status == :active))
          if active do
            Logger.info("[Brain] Restored learning goal: #{active.topic} (#{active.completed_count}/#{length(active.topics)})")
          end
        end
        schedule_activity_cycle()
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

    persist_learning_goals(state, goals)
    {:noreply, %{state | learning_goals: goals}}
  end

  def handle_info({:web_learning_complete, question}, state) do
    normalized = question |> String.downcase() |> String.replace(~r/[^\w\s]/, "") |> String.trim()
    {:noreply, %{state | researched_topics: MapSet.put(state.researched_topics, normalized)}}
  end

  def handle_info({:thought_result, thought_id, result}, state) do
    Logger.debug("[Brain] Received async thought result: #{thought_id}")
    state = integrate_thought(state, result)
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.debug("[Brain] Unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # ── Three-Tier Reasoning Pipeline (Autonomous Wake Cycle) ──────────

  defp reason(state, anomalies) do
    tagged = Enum.map(anomalies, &{:anomaly, &1})

    # Tier 1: Reflexes — pattern → action, zero cost
    case Reflexes.check(tagged) do
      {:act, actions} ->
        Logger.info("[Brain] Tier 1: executing #{length(actions)} reflex actions")
        Enum.each(actions, &Reflexes.execute_action/1)

        record_trace(state, :decision, %{
          tier: "reflex",
          actions: Enum.map(actions, &inspect/1)
        })

        state

      {:escalate, alerts} ->
        record_trace(state, :observation, %{
          alert: true,
          severity: alert_severity(alerts),
          alerts: Enum.map(alerts, &ensure_map/1)
        })

        Logger.warning("[Brain] Escalation: #{inspect(alerts)}")
        # After escalation, try Tier 2/3 for resolution
        maybe_tier2_3(state, anomalies)

      :pass ->
        Logger.debug("[Brain] Reflexes passed — no pattern match")
        # Reflexes didn't match — try Tier 2 silo inference, then Tier 3 Claude
        maybe_tier2_3(state, anomalies)
    end
  end

  defp maybe_tier2_3(state, anomalies) do
    # Tier 2: Silo inference — check if any expertise silo has relevant knowledge
    silo_results = try_silo_inference(anomalies)

    case silo_results do
      {:found, findings} ->
        Logger.info("[Brain] Tier 2: silo inference found #{length(findings)} relevant facts")

        record_trace(state, :thought, %{
          tier: "silo_inference",
          findings: findings
        })

        state

      :no_match ->
        # Tier 3: Claude API — novel situation, needs LLM reasoning
        maybe_call_claude(state, anomalies)
    end
  end

  defp try_silo_inference(anomalies) do
    # Extract key terms from anomalies and probe silos
    terms =
      anomalies
      |> Enum.flat_map(fn anomaly ->
        reason = to_string(Map.get(anomaly, :reason, ""))
        check = to_string(Map.get(anomaly, :check, ""))
        [check | String.split(reason)]
      end)
      |> Enum.uniq()

    results =
      Enum.flat_map(terms, fn term ->
        InferenceEngine.cross_query(term)
      end)

    high_confidence =
      Enum.filter(results, fn {_domain, _hint, score} ->
        InferenceEngine.confidence(score) in [:high, :moderate]
      end)

    if high_confidence != [] do
      findings =
        Enum.map(high_confidence, fn {domain, hint, score} ->
          %{
            domain: domain,
            hint: ensure_map(hint),
            score: score,
            confidence: InferenceEngine.confidence(score)
          }
        end)

      {:found, Enum.take(findings, 10)}
    else
      :no_match
    end
  end

  defp maybe_call_claude(state, anomalies) do
    api_key = state.config[:api_key] || state.config["api_key"]
    budget_limit = state.config[:budget_limit_monthly] || state.config["budget_limit_monthly"] || 100.0

    cond do
      is_nil(api_key) or api_key == "" ->
        Logger.debug("[Brain] No API key configured, skipping Tier 3")
        state

      not Budget.within_budget?(state.budget, budget_limit) ->
        Logger.warning("[Brain] Monthly budget exceeded ($#{state.budget.estimated_cost_usd}), skipping Tier 3")
        state

      true ->
        system_prompt = PromptBuilder.build(state)

        anomaly_desc =
          Enum.map(anomalies, fn a ->
            "#{a.check}: #{a.reason}"
          end)
          |> Enum.join("; ")

        message =
          "Anomalies detected that I couldn't handle with reflexes or silo inference:\n" <>
            anomaly_desc <>
            "\n\nWhat should I do?"

        tools =
          Kudzu.Brain.Tools.Introspection.to_claude_format() ++
            Kudzu.Brain.Tools.Host.to_claude_format() ++
            Kudzu.Brain.Tools.Escalation.to_claude_format() ++
            Kudzu.Brain.Tools.Web.to_claude_format()

        executor = fn name, params ->
          case Kudzu.Brain.Tools.Introspection.execute(name, params) do
            {:error, "unknown tool: " <> _} ->
              case Kudzu.Brain.Tools.Host.execute(name, params) do
                {:error, "unknown host tool: " <> _} ->
                  case Kudzu.Brain.Tools.Escalation.execute(name, params) do
                    {:error, "unknown escalation tool: " <> _} ->
                      Kudzu.Brain.Tools.Web.execute(name, params)

                    result ->
                      result
                  end

                result ->
                  result
              end

            result ->
              result
          end
        end

        case Kudzu.Brain.Claude.reason(
               api_key,
               system_prompt,
               message,
               tools,
               executor,
               max_turns: state.config[:max_turns] || 10,
               model: state.config[:model] || "claude-sonnet-4-20250514"
             ) do
          {:ok, response_text, usage} ->
            Logger.info(
              "[Brain] Tier 3 (#{usage.input_tokens}+#{usage.output_tokens} tokens): " <>
                String.slice(response_text, 0, 200)
            )

            record_trace(state, :thought, %{
              tier: "claude",
              response: String.slice(response_text, 0, 500),
              usage: usage
            })

            budget = Budget.record_usage(state.budget, usage)
            new_state = %{state | budget: budget}

            # Distill knowledge from Claude's response
            distill_claude_response(new_state, response_text)

          {:error, reason} ->
            Logger.error("[Brain] Claude API error: #{inspect(reason)}")

            record_trace(state, :observation, %{
              error: "claude_api_failure",
              reason: inspect(reason)
            })

            state
        end
    end
  end

  # ── Chat Reasoning Pipeline ─────────────────────────────────────────

  defp chat_reason(state, message, _opts) do
    # Package message as an anomaly for the reflexes pipeline
    tagged = [{:anomaly, %{check: :human_chat, reason: message}}]

    # Tier 1: Reflexes
    case Reflexes.check(tagged) do
      {:act, actions} ->
        Logger.info("[Brain] Chat Tier 1: #{length(actions)} reflex actions")
        Enum.each(actions, &Reflexes.execute_action/1)

        response =
          actions
          |> Enum.map(&inspect/1)
          |> Enum.join("; ")

        {response, 1, [], 0.0, state}

      {:escalate, _alerts} ->
        # Escalation from chat — fall through to directive check then escalation
        handle_directive_or_escalate(state, message)

      :pass ->
        # No reflex match — try directive check then escalation
        handle_directive_or_escalate(state, message)
    end
  end

  # ── Directive Parsing (Learn X, progress) ───────────────────────────

  defp handle_directive_or_escalate(state, message) do
    case parse_directive(message) do
      {:learn, topic} ->
        start_learning_goal(state, topic)

      :progress ->
        report_learning_progress(state)

      :not_directive ->
        chat_escalate(state, message)
    end
  end

  defp handle_directive_or_escalate_stream(state, message, stream_to) do
    case parse_directive(message) do
      {:learn, topic} ->
        {response, tier, tool_calls, cost, state} = start_learning_goal(state, topic)
        send(stream_to, {:chunk, response})
        {response, tier, tool_calls, cost, state}

      :progress ->
        {response, tier, tool_calls, cost, state} = report_learning_progress(state)
        send(stream_to, {:chunk, response})
        {response, tier, tool_calls, cost, state}

      :not_directive ->
        chat_escalate_stream(state, message, stream_to)
    end
  end

    defp parse_directive(message) do
    trimmed = String.trim(message)
    cond do
      Regex.match?(~r/^learn\s+/i, trimmed) ->
        topic = Regex.replace(~r/^learn\s+/i, trimmed, "") |> String.trim() |> String.trim(".")
        if String.length(topic) > 2, do: {:learn, topic}, else: :not_directive

      Regex.match?(~r/^(learning\s+)?progress\??$/i, trimmed) ->
        :progress

      Regex.match?(~r/^what have you learned/i, trimmed) ->
        :progress

      Regex.match?(~r/^learning\s+goals?\??$/i, trimmed) ->
        :progress

      true ->
        :not_directive
    end
  end

  defp report_learning_progress(state) do
    alias Kudzu.Brain.LearningGoal

    case state.learning_goals do
      [] ->
        {"No active learning goals. Say 'Learn <topic>' to start one.", :reflex, [], 0.0, state}

      goals ->
        active = Enum.find(goals, &(&1.status == :active))
        queued = Enum.filter(goals, &(&1.status == :queued))
        completed = Enum.filter(goals, &(&1.status == :complete))

        parts = []

        parts = if active do
          [LearningGoal.progress_report(active) | parts]
        else
          ["No active learning goal." | parts]
        end

        parts = if queued != [] do
          queued_list = Enum.map_join(queued, "\n", &("  - #{&1.topic}"))
          ["Queued:\n#{queued_list}" | parts]
        else
          parts
        end

        parts = if completed != [] do
          done_list = Enum.map_join(completed, "\n", &("  - #{&1.topic} (#{&1.completed_count} topics)"))
          ["Completed goals:\n#{done_list}" | parts]
        else
          parts
        end

        response = parts |> Enum.reverse() |> Enum.join("\n\n")
        {response, :reflex, [], 0.0, state}
    end
  end

  defp start_learning_goal(state, topic) do
    alias Kudzu.Brain.LearningGoal

    normalized = String.downcase(topic)
    existing = Enum.find(state.learning_goals, fn g ->
      g.status in [:active, :queued] and String.downcase(g.topic) == normalized
    end)

    if existing do
      {"Already learning '#{topic}'. Say 'progress' to check status.", :reflex, [], 0.0, state}
    else
      Logger.info("[Brain] Generating curriculum for: #{topic}")
      ActivityIndicator.start_activity(:curriculum, "generating curriculum: #{String.slice(topic, 0, 40)}")

      result = generate_curriculum(state, topic)
      ActivityIndicator.stop_activity(:curriculum)

      case result do
        {:ok, items, cost} ->
          goal = LearningGoal.new(topic, items)

          goal = if Enum.any?(state.learning_goals, &(&1.status == :active)) do
            %{goal | status: :queued}
          else
            goal
          end

          goals = state.learning_goals ++ [goal]
          state = %{state | learning_goals: goals}

          persist_learning_goals(state, goals)

          record_trace(state, :memory, %{
            source: "learning_goal_created",
            topic: topic,
            curriculum_size: length(items),
            status: goal.status,
            goal_id: goal.id
          })

          status_word = if goal.status == :active, do: "Started", else: "Queued"
          response = "#{status_word} learning '#{topic}' — #{length(items)} topics to cover.\n\n" <>
            "First 5 topics:\n" <>
            (items |> Enum.take(5) |> Enum.map_join("\n", &("  - #{&1}")))

          {response, :reflex, [], cost, state}

        {:error, reason} ->
          {"Failed to generate curriculum: #{inspect(reason)}", :reflex, [], 0.0, state}
      end
    end
  end

  defp generate_curriculum(_state, topic) do
    case CurriculumGenerator.generate(topic) do
      {:ok, items} -> {:ok, items, 0.0}
      {:error, reason} -> {:error, reason}
    end
  end

  # ── Tiered Query Escalation Pipeline (Phase 5) ──────────────────────
  #
  # Tier 1: Semantic Recall  — search stored traces (free)
  # Tier 2: Silo Inference   — Thought reasoning chain (free, instant)
  # Tier 3: Web Search       — research on the web (free, slow)
  # Tier 4: Claude API       — LLM reasoning (paid, last resort)
  #
  # Each tier enriches context for the next. Claude only fires if all
  # free tiers fail to produce a confident answer.

  # Tier 1: Semantic Recall  — search stored traces (free)
  # Tier 2: Silo Inference   — Thought reasoning chain (free, instant)
  # Tier 3: Web Search       — research on the web (free, slow)
  # Tier 4: Claude API       — LLM reasoning (paid, last resort)
  #
  # Each tier enriches context for the next. Claude only fires if all
  # free tiers fail to produce a confident answer.

  defp chat_escalate(state, message) do
    # Accumulate context from each tier for potential Claude enrichment
    context = %{recall_results: [], web_findings: nil, thought_result: nil}

    # ── Tier 1: Semantic Recall (free) ──
    Logger.info("[Brain] Escalation Tier 1: Semantic Recall")
    recall_results = try do
      Kudzu.Consolidation.semantic_query(message, 0.0)
    catch
      _, _ -> []
    end

    top_score = case recall_results do
      [%{similarity: score} | _] -> score
      [{_purpose, score} | _] -> score  # fallback format
      _ -> 0.0
    end

    context = %{context | recall_results: recall_results}

    if top_score > 0.6 do
      # Strong recall match — synthesize response from stored knowledge
      response = format_recall_response(message, recall_results)

      record_trace(state, :thought, %{
        source: "chat_escalation",
        tier: "recall",
        top_score: top_score,
        matches: length(recall_results),
        message: String.slice(message, 0, 200)
      })

      Logger.info("[Brain] Escalation resolved at Tier 1 (recall, score=#{Float.round(top_score, 3)})")
      {response, :recall, [], 0.0, state}
    else
      # ── Tier 2: Silo Inference (free, instant) ──
      Logger.info("[Brain] Escalation Tier 2: Silo Inference (Thought)")
      priming = if state.working_memory do
        WorkingMemory.get_priming_concepts(state.working_memory, 5)
      else
        []
      end

      thought_result = Thought.run(message,
        monarch_pid: self(),
        timeout: 10_000,
        priming: priming
      )

      state = integrate_thought(state, thought_result)
      context = %{context | thought_result: thought_result}

      if thought_result.resolution == :found and thought_result.confidence > 0.5 do
        response = format_thought_result(message, thought_result)

        record_trace(state, :thought, %{
          source: "chat_escalation",
          tier: "synthesis",
          resolution: thought_result.resolution,
          confidence: thought_result.confidence,
          chain_length: length(thought_result.chain),
          message: String.slice(message, 0, 200)
        })

        Logger.info("[Brain] Escalation resolved at Tier 2 (synthesis, confidence=#{Float.round(thought_result.confidence, 3)})")
        {response, :synthesis, [], 0.0, state}
      else
        # ── Tier 3: Web Search (free, slow) ──
        Logger.info("[Brain] Escalation Tier 3: Web Search")
        web_result = try do
          WebLearner.research(message)
        catch
          _, _ -> {:error, :crashed}
        end

        context = case web_result do
          {:ok, findings} -> %{context | web_findings: findings}
          _ -> context
        end

        web_found = match?({:ok, %{chains_stored: n}} when n > 0, web_result)

        if web_found do
          {:ok, findings} = web_result
          response = format_web_response(message, findings)

          record_trace(state, :thought, %{
            source: "chat_escalation",
            tier: "web",
            pages_read: findings.pages_read,
            chains_stored: findings.chains_stored,
            message: String.slice(message, 0, 200)
          })

          Logger.info("[Brain] Escalation resolved at Tier 3 (web, #{findings.chains_stored} chains)")
          {response, :web, [], 0.0, state}
        else
          # ── Tier 4: Claude API (paid, last resort) ──
          Logger.info("[Brain] Escalation Tier 4: Claude API (all free tiers exhausted)")
          enhanced_message = build_enriched_message(message, context)

          record_trace(state, :thought, %{
            source: "chat_escalation",
            tier: "claude",
            reason: "free_tiers_exhausted",
            recall_top_score: top_score,
            thought_resolution: thought_result.resolution,
            thought_confidence: thought_result.confidence,
            message: String.slice(message, 0, 200)
          })

          {response_text, tier, tool_calls, cost, new_state} =
            chat_with_claude(state, enhanced_message)

          # Distill knowledge from Claude's response
          new_state = if tier == 3 and response_text != "" do
            distill_claude_response(new_state, response_text)
          else
            new_state
          end

          {response_text, tier, tool_calls, cost, new_state}
        end
      end
    end
  end

  defp format_recall_response(_message, recall_results) do
    snippets = recall_results
    |> Enum.take(5)
    |> Enum.map(fn
      %{similarity: sim, record: record} when is_map(record) ->
        hint = record.reconstruction_hint || %{}
        content = Map.get(hint, "content") || Map.get(hint, :content) ||
                  Map.get(hint, "text") || Map.get(hint, :text) ||
                  Map.get(hint, "summary") || Map.get(hint, :summary) ||
                  Map.get(hint, "message") || Map.get(hint, :message) || ""
        # Build a triple description if available
        subj = Map.get(hint, "subject") || Map.get(hint, :subject)
        rel = Map.get(hint, "relation") || Map.get(hint, :relation)
        obj = Map.get(hint, "object") || Map.get(hint, :object)
        triple_text = if subj && rel && obj, do: "#{subj} #{rel} #{obj}", else: nil

        text = cond do
          content != "" -> String.slice(to_string(content), 0, 300)
          triple_text -> triple_text
          true -> inspect(hint) |> String.slice(0, 200)
        end

        purpose = if is_struct(record) and Map.has_key?(record, :purpose),
          do: "(#{record.purpose}) ", else: ""
        "- #{purpose}#{text} [#{Float.round(sim, 3)}]"

      {purpose, similarity} ->
        "- #{purpose} (relevance: #{Float.round(similarity, 3)})"
    end)
    |> Enum.join("\n")

    "Based on my stored knowledge:\n\n#{snippets}"
  end

  defp format_web_response(_message, findings) do
    "I researched this on the web and found relevant information.\n\n" <>
      "Pages read: #{findings.pages_read}\n" <>
      "Knowledge chains extracted: #{findings.chains_stored}\n\n" <>
      "The findings have been stored in my knowledge base for future reference."
  end

  defp build_enriched_message(message, context) do
    parts = [message]

    # Add recall context
    parts = if context.recall_results != [] do
      recall_summary = context.recall_results
      |> Enum.take(5)
      |> Enum.map(fn {purpose, sim} -> "#{purpose} (#{Float.round(sim, 3)})" end)
      |> Enum.join(", ")

      parts ++ ["\n\n[Memory recall found related purposes: #{recall_summary}]"]
    else
      parts
    end

    # Add web findings context
    parts = case context.web_findings do
      %{pages_read: pages, chains_stored: chains} when chains > 0 ->
        parts ++ ["\n[Web research: #{pages} pages read, #{chains} knowledge chains extracted]"]
      _ -> parts
    end

    # Add thought context
    parts = case context.thought_result do
      %Thought.Result{chain: chain} when chain != [] ->
        chain_summary = chain
        |> Enum.map(fn
          %{concept: c, source: src} -> "#{c} (from #{src})"
          {concept, _score, source} -> "#{concept} (from #{source})"
          _ -> ""
        end)
        |> Enum.reject(&(&1 == ""))
        |> Enum.join(", ")

        parts ++ ["\n[Silo reasoning found related concepts: #{chain_summary}]"]
      _ -> parts
    end

    Enum.join(parts)
  end

  # Original chat_think_then_claude kept as fallback
  defp chat_think_then_claude(state, message) do
    # Get priming concepts from working memory
    priming = if state.working_memory do
      WorkingMemory.get_priming_concepts(state.working_memory, 5)
    else
      []
    end

    # Run a Thought process
    thought_result = Thought.run(message,
      monarch_pid: self(),
      timeout: 10_000,
      priming: priming
    )

    # Integrate thought results into working memory
    state = integrate_thought(state, thought_result)

    if thought_result.resolution == :found and thought_result.confidence > 0.5 do
      # Thought resolved — format the chain as a response
      response = format_thought_result(message, thought_result)
      {response, :thought, [], 0.0, state}
    else
      # Thought didn't fully resolve — escalate to Claude
      # But provide thought context to Claude for better reasoning
      chat_with_claude_with_context(state, message, thought_result)
    end
  end

  defp integrate_thought(%{working_memory: nil} = state, _result), do: state
  defp integrate_thought(state, %Thought.Result{} = result) do
    wm = state.working_memory

    # Activate concepts from the thought
    wm = Enum.reduce(result.activations, wm, fn
      {concept, score, source}, acc ->
        WorkingMemory.activate(acc, concept, %{score: score, source: source})
      _, acc -> acc
    end)

    # Add the chain
    wm = if result.chain != [] do
      WorkingMemory.add_chain(wm, result.chain)
    else
      wm
    end

    %{state | working_memory: wm}
  end
  defp integrate_thought(state, _result), do: state

  defp format_thought_result(_message, %Thought.Result{} = result) do
    chain_parts = result.chain
    |> Enum.map(fn
      %{concept: c, similarity: s, source: src} ->
        "- #{c} (#{src}, score: #{Float.round(s * 1.0, 2)})"
      {concept, score, source} ->
        "- #{concept} (#{source}, score: #{Float.round(score * 1.0, 2)})"
      other -> "- #{inspect(other)}"
    end)

    chain_text = if chain_parts != [] do
      "Reasoning chain:\n" <> Enum.join(chain_parts, "\n")
    else
      "No reasoning chain available."
    end

    "Based on my reasoning:\n\n#{chain_text}\n\nConfidence: #{Float.round(result.confidence * 1.0, 2)}"
  end

  defp chat_with_claude_with_context(state, message, thought_result) do
    # Add thought context to enhance the Claude message
    thought_context = if thought_result.chain != [] do
      chain_summary = thought_result.chain
      |> Enum.map(fn
        %{concept: c, source: src} -> "#{c} (from #{src})"
        {concept, _score, source} -> "#{concept} (from #{source})"
        _ -> ""
      end)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join(", ")

      "\n\n[Thinking context: my silo reasoning found these related concepts: #{chain_summary}]"
    else
      ""
    end

    enhanced_message = message <> thought_context

    # Use the existing chat_with_claude but with the enhanced message
    {response_text, tier, tool_calls, cost, new_state} = chat_with_claude(state, enhanced_message)

    # Run Distiller on Claude's response if we got one
    new_state = if tier == 3 and response_text != "" do
      distill_claude_response(new_state, response_text)
    else
      new_state
    end

    {response_text, tier, tool_calls, cost, new_state}
  end

  defp distill_claude_response(state, response_text) do
    try do
      silo_domains = case Kudzu.Silo.list() do
        domains when is_list(domains) ->
          Enum.map(domains, fn
            {domain, _, _} -> domain
            domain when is_binary(domain) -> domain
            _ -> nil
          end) |> Enum.reject(&is_nil/1)
        _ -> []
      end

      available_actions =
        if function_exported?(Reflexes, :known_actions, 0) do
          try do
            apply(Reflexes, :known_actions, [])
          catch
            _, _ -> []
          end
        else
          []
        end

      context = %{available_actions: available_actions}
      result = Distiller.distill(response_text, silo_domains, context)

      # Store extracted chains in silos
      state = if result.chains != [] do
        Logger.info("[Brain] Distiller extracted #{length(result.chains)} relationships from Claude response")
        Enum.each(result.chains, fn {subject, relation, object} ->
          try do
            Kudzu.Silo.store_relationship("brain_knowledge", {subject, relation, object})
          catch
            _, _ -> :ok
          end
        end)
        state
      else
        state
      end

      # Log knowledge gaps for curiosity
      if result.knowledge_gaps != [] do
        wm = state.working_memory
        wm = if wm do
          Enum.reduce(Enum.take(result.knowledge_gaps, 3), wm, fn gap, acc ->
            WorkingMemory.add_question(acc, "What is #{gap}?")
          end)
        else
          wm
        end
        %{state | working_memory: wm}
      else
        state
      end
    catch
      _, _ -> state
    end
  end

  defp chat_with_claude(state, message) do
    api_key = state.config[:api_key] || state.config["api_key"]
    budget_limit = state.config[:budget_limit_monthly] || state.config["budget_limit_monthly"] || 100.0

    cond do
      is_nil(api_key) or api_key == "" ->
        Logger.debug("[Brain] Chat: No API key configured, skipping Tier 3")
        {"I don't have an API key configured for Claude, so I can't process this with Tier 3 reasoning. " <>
           "My reflexes and silo inference didn't find a match for your message either.", 3, [], 0.0, state}

      not Budget.within_budget?(state.budget, budget_limit) ->
        Logger.warning("[Brain] Chat: Monthly budget exceeded ($#{state.budget.estimated_cost_usd})")
        {"I've exceeded my monthly API budget, so I can't use Tier 3 reasoning right now. " <>
           "My reflexes and silo inference didn't find a match for your message.", 3, [], 0.0, state}

      true ->
        system_prompt = PromptBuilder.build_chat(state)

        tools =
          Kudzu.Brain.Tools.Introspection.to_claude_format() ++
            Kudzu.Brain.Tools.Host.to_claude_format() ++
            Kudzu.Brain.Tools.Escalation.to_claude_format() ++
            Kudzu.Brain.Tools.Web.to_claude_format()

        # Set up tool executor with call tracking
        Process.put(:chat_tool_calls, [])

        executor = fn name, params ->
          Process.put(:chat_tool_calls, [name | Process.get(:chat_tool_calls)])

          case Kudzu.Brain.Tools.Introspection.execute(name, params) do
            {:error, "unknown tool: " <> _} ->
              case Kudzu.Brain.Tools.Host.execute(name, params) do
                {:error, "unknown host tool: " <> _} ->
                  case Kudzu.Brain.Tools.Escalation.execute(name, params) do
                    {:error, "unknown escalation tool: " <> _} ->
                      Kudzu.Brain.Tools.Web.execute(name, params)

                    result ->
                      result
                  end

                result ->
                  result
              end

            result ->
              result
          end
        end

        case Kudzu.Brain.Claude.reason(
               api_key,
               system_prompt,
               message,
               tools,
               executor,
               max_turns: state.config[:max_turns] || 10,
               model: state.config[:model] || "claude-sonnet-4-20250514"
             ) do
          {:ok, response_text, usage} ->
            tool_calls = Process.get(:chat_tool_calls) |> Enum.reverse()
            Process.delete(:chat_tool_calls)

            Logger.info(
              "[Brain] Chat Tier 3 (#{usage.input_tokens}+#{usage.output_tokens} tokens): " <>
                String.slice(response_text, 0, 200)
            )

            cost =
              (Map.get(usage, :input_tokens, 0) / 1_000_000 * 3.0) +
                (Map.get(usage, :output_tokens, 0) / 1_000_000 * 15.0)

            budget = Budget.record_usage(state.budget, usage)
            new_state = %{state | budget: budget}

            {response_text, 3, tool_calls, Float.round(cost, 6), new_state}

          {:error, reason} ->
            tool_calls = Process.get(:chat_tool_calls) |> Enum.reverse()
            Process.delete(:chat_tool_calls)

            Logger.error("[Brain] Chat Claude API error: #{inspect(reason)}")
            {"I encountered an error while processing your message with Claude: #{inspect(reason)}",
             3, tool_calls, 0.0, state}
        end
    end
  end

  # ── Streaming Chat Reasoning Pipeline ─────────────────────────────────

  defp chat_reason_stream(state, message, stream_to, _opts) do
    # Package message as an anomaly for the reflexes pipeline
    tagged = [{:anomaly, %{check: :human_chat, reason: message}}]

    # Tier 1: Reflexes
    send(stream_to, {:thinking, 1, "Checking reflexes..."})

    case Reflexes.check(tagged) do
      {:act, actions} ->
        Logger.info("[Brain] Stream Chat Tier 1: #{length(actions)} reflex actions")
        Enum.each(actions, &Reflexes.execute_action/1)

        response =
          actions
          |> Enum.map(&inspect/1)
          |> Enum.join("; ")

        send(stream_to, {:chunk, response})
        {response, 1, [], 0.0, state}

      {:escalate, _alerts} ->
        handle_directive_or_escalate_stream(state, message, stream_to)

      :pass ->
        handle_directive_or_escalate_stream(state, message, stream_to)
    end
  end

  defp chat_escalate_stream(state, message, stream_to) do
    context = %{recall_results: [], web_findings: nil, thought_result: nil}

    # Tier 1: Semantic Recall
    send(stream_to, {:thinking, :recall, "Searching stored knowledge..."})
    recall_results = try do
      Kudzu.Consolidation.semantic_query(message, 0.0)
    catch
      _, _ -> []
    end

    top_score = case recall_results do
      [%{similarity: score} | _] -> score
      [{_purpose, score} | _] -> score  # fallback format
      _ -> 0.0
    end

    context = %{context | recall_results: recall_results}

    if top_score > 0.6 do
      response = format_recall_response(message, recall_results)
      record_trace(state, :thought, %{source: "chat_escalation", tier: "recall", top_score: top_score})
      send(stream_to, {:chunk, response})
      {response, :recall, [], 0.0, state}
    else
      # Tier 2: Silo Inference
      send(stream_to, {:thinking, :synthesis, "Running silo inference..."})
      priming = if state.working_memory do
        WorkingMemory.get_priming_concepts(state.working_memory, 5)
      else
        []
      end

      thought_result = Thought.run(message, monarch_pid: self(), timeout: 10_000, priming: priming)
      state = integrate_thought(state, thought_result)
      context = %{context | thought_result: thought_result}

      if thought_result.resolution == :found and thought_result.confidence > 0.5 do
        response = format_thought_result(message, thought_result)
        record_trace(state, :thought, %{source: "chat_escalation", tier: "synthesis", confidence: thought_result.confidence})
        send(stream_to, {:chunk, response})
        {response, :synthesis, [], 0.0, state}
      else
        # Tier 3: Web Search
        send(stream_to, {:thinking, :web, "Searching the web..."})
        web_result = try do
          WebLearner.research(message)
        catch
          _, _ -> {:error, :crashed}
        end

        context = case web_result do
          {:ok, findings} -> %{context | web_findings: findings}
          _ -> context
        end

        web_found = match?({:ok, %{chains_stored: n}} when n > 0, web_result)

        if web_found do
          {:ok, findings} = web_result
          response = format_web_response(message, findings)
          record_trace(state, :thought, %{source: "chat_escalation", tier: "web", chains_stored: findings.chains_stored})
          send(stream_to, {:chunk, response})
          {response, :web, [], 0.0, state}
        else
          # Tier 4: Claude API
          send(stream_to, {:thinking, :claude, "Consulting Claude API..."})
          enhanced_message = build_enriched_message(message, context)
          record_trace(state, :thought, %{source: "chat_escalation", tier: "claude", reason: "free_tiers_exhausted"})
          chat_with_claude_stream(state, enhanced_message, stream_to)
        end
      end
    end
  end

  # Original chat_think_then_claude_stream kept as fallback
  defp chat_think_then_claude_stream(state, message, stream_to) do
    send(stream_to, {:thinking, :thought, "Running thought process..."})

    # Get priming concepts from working memory
    priming = if state.working_memory do
      WorkingMemory.get_priming_concepts(state.working_memory, 5)
    else
      []
    end

    # Run a synchronous Thought process
    thought_result = Thought.run(message,
      monarch_pid: self(),
      timeout: 10_000,
      priming: priming
    )

    # Integrate thought results into working memory
    state = integrate_thought(state, thought_result)

    if thought_result.resolution == :found and thought_result.confidence > 0.5 do
      # Thought resolved — send result as chunk
      response = format_thought_result(message, thought_result)
      send(stream_to, {:chunk, response})
      {response, :thought, [], 0.0, state}
    else
      # Thought didn't fully resolve — proceed to Claude streaming
      thought_context = if thought_result.chain != [] do
        chain_summary = thought_result.chain
        |> Enum.map(fn
          %{concept: c, source: src} -> "#{c} (from #{src})"
          {concept, _score, source} -> "#{concept} (from #{source})"
          _ -> ""
        end)
        |> Enum.reject(&(&1 == ""))
        |> Enum.join(", ")

        "\n\n[Thinking context: my silo reasoning found these related concepts: #{chain_summary}]"
      else
        ""
      end

      enhanced_message = message <> thought_context

      send(stream_to, {:thinking, 3, "Thinking..."})
      {response_text, tier, tool_calls, cost, new_state} =
        chat_with_claude_stream(state, enhanced_message, stream_to)

      # Run Distiller on Claude's response
      new_state = if tier == 3 and response_text != "" do
        distill_claude_response(new_state, response_text)
      else
        new_state
      end

      {response_text, tier, tool_calls, cost, new_state}
    end
  end

  defp chat_with_claude_stream(state, message, stream_to) do
    api_key = state.config[:api_key] || state.config["api_key"]
    budget_limit = state.config[:budget_limit_monthly] || state.config["budget_limit_monthly"] || 100.0

    cond do
      is_nil(api_key) or api_key == "" ->
        Logger.debug("[Brain] Stream Chat: No API key configured, skipping Tier 3")
        error_msg =
          "I don't have an API key configured for Claude, so I can't process this with Tier 3 reasoning. " <>
            "My reflexes and silo inference didn't find a match for your message either."
        send(stream_to, {:chunk, error_msg})
        {error_msg, 3, [], 0.0, state}

      not Budget.within_budget?(state.budget, budget_limit) ->
        Logger.warning("[Brain] Stream Chat: Monthly budget exceeded ($#{state.budget.estimated_cost_usd})")
        error_msg =
          "I've exceeded my monthly API budget, so I can't use Tier 3 reasoning right now. " <>
            "My reflexes and silo inference didn't find a match for your message."
        send(stream_to, {:chunk, error_msg})
        {error_msg, 3, [], 0.0, state}

      true ->
        system_prompt = PromptBuilder.build_chat(state)

        tools =
          Kudzu.Brain.Tools.Introspection.to_claude_format() ++
            Kudzu.Brain.Tools.Host.to_claude_format() ++
            Kudzu.Brain.Tools.Escalation.to_claude_format() ++
            Kudzu.Brain.Tools.Web.to_claude_format()

        # Set up tool executor with call tracking
        Process.put(:chat_tool_calls, [])

        executor = fn name, params ->
          Process.put(:chat_tool_calls, [name | Process.get(:chat_tool_calls)])

          case Kudzu.Brain.Tools.Introspection.execute(name, params) do
            {:error, "unknown tool: " <> _} ->
              case Kudzu.Brain.Tools.Host.execute(name, params) do
                {:error, "unknown host tool: " <> _} ->
                  case Kudzu.Brain.Tools.Escalation.execute(name, params) do
                    {:error, "unknown escalation tool: " <> _} ->
                      Kudzu.Brain.Tools.Web.execute(name, params)

                    result ->
                      result
                  end

                result ->
                  result
              end

            result ->
              result
          end
        end

        case Kudzu.Brain.Claude.reason_stream(
               api_key,
               system_prompt,
               message,
               tools,
               executor,
               stream_to: stream_to,
               max_turns: state.config[:max_turns] || 10,
               model: state.config[:model] || "claude-sonnet-4-20250514"
             ) do
          {:ok, response_text, usage} ->
            tool_calls = Process.get(:chat_tool_calls) |> Enum.reverse()
            Process.delete(:chat_tool_calls)

            Logger.info(
              "[Brain] Stream Chat Tier 3 (#{usage.input_tokens}+#{usage.output_tokens} tokens): " <>
                String.slice(response_text, 0, 200)
            )

            cost =
              (Map.get(usage, :input_tokens, 0) / 1_000_000 * 3.0) +
                (Map.get(usage, :output_tokens, 0) / 1_000_000 * 15.0)

            budget = Budget.record_usage(state.budget, usage)
            new_state = %{state | budget: budget}

            {response_text, 3, tool_calls, Float.round(cost, 6), new_state}

          {:error, reason} ->
            tool_calls = Process.get(:chat_tool_calls) |> Enum.reverse()
            Process.delete(:chat_tool_calls)

            Logger.error("[Brain] Stream Chat Claude API error: #{inspect(reason)}")
            error_msg = "I encountered an error while processing your message with Claude: #{inspect(reason)}"
            send(stream_to, {:chunk, error_msg})
            {error_msg, 3, tool_calls, 0.0, state}
        end
    end
  end

  # ── Curiosity-Driven Exploration ────────────────────────────────────

  defp maybe_explore_curiosity(%{working_memory: nil} = state), do: state
  defp maybe_explore_curiosity(state) do
    # Check if there are pending questions from previous thoughts
    {question, wm} = WorkingMemory.pop_question(state.working_memory)
    state = %{state | working_memory: wm}

    question = if is_nil(question) do
      # Generate a new curiosity question
      silo_domains = try do
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

      questions = Curiosity.generate(state.desires, state.working_memory, silo_domains)
      List.first(questions)
    else
      question
    end

    if question do
      Logger.info("[Brain] Curiosity exploring: #{String.slice(question, 0, 100)}")

      # Run a thought on the curiosity question
      thought_result = Thought.run(question,
        monarch_pid: self(),
        timeout: 8_000,
        priming: WorkingMemory.get_priming_concepts(state.working_memory, 3)
      )

      state = integrate_thought(state, thought_result)

      record_trace(state, :thought, %{
        source: "curiosity",
        question: question,
        resolution: thought_result.resolution,
        confidence: thought_result.confidence,
        chain_length: length(thought_result.chain)
      })

      state
    else
      state
    end
  end

  # ── Trace Recording ─────────────────────────────────────────────────

  defp record_trace(state, purpose, data) do
    if state.hologram_pid do
      try do
        Kudzu.Hologram.record_trace(state.hologram_pid, purpose, data)
      rescue
        _ -> :ok
      end
    end
  end

  # ── Learning Goal Persistence ──────────────────────────────────────

  defp persist_learning_goals(state, goals) do
    if state.hologram_pid do
      serialized = Enum.map(goals, fn g ->
        %{
          id: g.id,
          topic: g.topic,
          status: to_string(g.status),
          created_at: DateTime.to_iso8601(g.created_at),
          topics: Enum.map(g.topics, fn {t, s} -> %{topic: t, status: to_string(s)} end),
          current_index: g.current_index,
          completed_count: g.completed_count,
          failed_count: g.failed_count
        }
      end)

      try do
        Kudzu.Hologram.record_trace(state.hologram_pid, :session_context, %{
          source: "learning_goals_state",
          goals: serialized
        })
      rescue
        _ -> :ok
      end
    end
  end

  defp restore_learning_goals(hologram_pid) do
    alias Kudzu.Brain.LearningGoal

    # Find the most recent learning_goals_state trace
    traces = try do
      Kudzu.Hologram.recall(hologram_pid, :session_context)
    catch
      _, _ -> []
    end

    goal_trace = traces
    |> Enum.filter(fn t ->
      hint = Map.get(t, :reconstruction_hint, %{})
      source = Map.get(hint, :source, Map.get(hint, "source", nil))
      source == "learning_goals_state"
    end)
    |> List.last()  # most recent (traces are typically in chronological order)

    case goal_trace do
      %{reconstruction_hint: %{goals: serialized}} when is_list(serialized) ->
        deserialize_goals(serialized)

      %{reconstruction_hint: %{"goals" => serialized}} when is_list(serialized) ->
        deserialize_goals(serialized)

      _ ->
        []
    end
  end

  defp deserialize_goals(serialized) do
    alias Kudzu.Brain.LearningGoal

    Enum.map(serialized, fn g ->
      topics = (g["topics"] || g[:topics] || [])
      |> Enum.map(fn t ->
        topic = t["topic"] || t[:topic] || ""
        status = case t["status"] || t[:status] do
          "complete" -> :complete
          "failed" -> :failed
          _ -> :pending
        end
        {topic, status}
      end)

      %LearningGoal{
        id: g["id"] || g[:id],
        topic: g["topic"] || g[:topic],
        status: case g["status"] || g[:status] do
          "active" -> :active
          "queued" -> :queued
          "complete" -> :complete
          _ -> :active
        end,
        created_at: case DateTime.from_iso8601(to_string(g["created_at"] || g[:created_at] || "")) do
          {:ok, dt, _} -> dt
          _ -> DateTime.utc_now()
        end,
        topics: topics,
        current_index: g["current_index"] || g[:current_index] || 0,
        completed_count: g["completed_count"] || g[:completed_count] || 0,
        failed_count: g["failed_count"] || g[:failed_count] || 0
      }
    end)
  end

  # ── Helpers ─────────────────────────────────────────────────────────

  # Extract severity from the first alert in the list, defaulting to :unknown
  defp alert_severity([%{severity: sev} | _]), do: sev
  defp alert_severity(_), do: :unknown

  # Ensure a value is a plain map (not a struct) for trace serialization
  defp ensure_map(%_{} = struct), do: Map.from_struct(struct)
  defp ensure_map(map) when is_map(map), do: map
  defp ensure_map(other), do: %{value: inspect(other)}

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

  defp schedule_wake_cycle(interval) do
    Process.send_after(self(), :wake_cycle, interval)
  end

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
        reason(state, anomalies)
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
