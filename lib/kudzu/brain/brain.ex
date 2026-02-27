defmodule Kudzu.Brain do
  @moduledoc """
  Brain GenServer — desire-driven wake cycles with thinking-layer reasoning.

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
  2. Thinking Layer — Thought process with working memory priming
  3. Tier 3 — Claude API (if thought didn't fully resolve)
  4. Distiller extracts knowledge from Claude responses

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

  defstruct [
    :hologram_id,
    :hologram_pid,
    :current_session,
    :budget,
    :working_memory,
    desires: @initial_desires,
    status: :sleeping,
    cycle_interval: @default_cycle_interval,
    cycle_count: 0,
    config: %{}
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
    GenServer.call(__MODULE__, {:chat, message, opts}, 120_000)
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

  def handle_call({:chat, _message, _opts}, _from, %{hologram_id: nil} = state) do
    {:reply, {:error, :not_ready}, state}
  end

  def handle_call({:chat, message, opts}, _from, state) do
    Logger.info("[Brain] Chat message received: #{String.slice(message, 0, 100)}")

    # Record user message as a trace
    record_trace(state, :observation, %{
      source: "human_chat",
      content: message
    })

    # Run reasoning pipeline adapted for chat
    {response_text, tier, tool_calls, cost, new_state} = chat_reason(state, message, opts)

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
        schedule_wake_cycle(new_state.cycle_interval)
        {:noreply, new_state}

      {:error, reason} ->
        Logger.warning(
          "[Brain] Hologram init failed: #{inspect(reason)} — retrying in #{@retry_delay}ms"
        )

        Process.send_after(self(), :init_hologram, @retry_delay)
        {:noreply, state}
    end
  end

  def handle_info(:wake_cycle, %{hologram_id: nil} = state) do
    Logger.debug("[Brain] Skipping wake cycle — no hologram attached")
    schedule_wake_cycle(state.cycle_interval)
    {:noreply, state}
  end

  def handle_info(:wake_cycle, state) do
    new_count = state.cycle_count + 1
    Logger.debug("[Brain] Wake cycle ##{new_count}")

    state = %{state | cycle_count: new_count, status: :reasoning}

    state = case pre_check(state) do
      :sleep ->
        Logger.debug("[Brain] Pre-check nominal — exploring curiosity")
        # No anomalies — pursue curiosity instead
        maybe_explore_curiosity(state)

      {:wake, anomalies} ->
        Logger.info("[Brain] Cycle #{new_count}: #{length(anomalies)} anomalies")
        reason(state, anomalies)
    end

    # Decay working memory at end of each cycle
    state = if state.working_memory do
      %{state | working_memory: WorkingMemory.decay(state.working_memory, 0.05)}
    else
      state
    end

    schedule_wake_cycle(state.cycle_interval)
    {:noreply, %{state | status: :sleeping}}
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
            Kudzu.Brain.Tools.Escalation.to_claude_format()

        executor = fn name, params ->
          case Kudzu.Brain.Tools.Introspection.execute(name, params) do
            {:error, "unknown tool: " <> _} ->
              case Kudzu.Brain.Tools.Host.execute(name, params) do
                {:error, "unknown host tool: " <> _} ->
                  Kudzu.Brain.Tools.Escalation.execute(name, params)

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
        # Escalation from chat — fall through to thinking layer
        chat_think_then_claude(state, message)

      :pass ->
        # No reflex match — try thinking layer
        chat_think_then_claude(state, message)
    end
  end

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
    chain_desc = result.chain
    |> Enum.map(fn
      %{concept: c, similarity: s, source: src} -> "#{c} (#{src}, #{Float.round(s * 1.0, 2)})"
      {concept, score, source} -> "#{concept} (#{source}, #{Float.round(score * 1.0, 2)})"
      other -> inspect(other)
    end)
    |> Enum.join(" -> ")

    "Based on my reasoning:\n\n#{chain_desc}\n\nConfidence: #{Float.round(result.confidence * 1.0, 2)}"
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
            Kudzu.Brain.Tools.Escalation.to_claude_format()

        # Set up tool executor with call tracking
        Process.put(:chat_tool_calls, [])

        executor = fn name, params ->
          Process.put(:chat_tool_calls, [name | Process.get(:chat_tool_calls)])

          case Kudzu.Brain.Tools.Introspection.execute(name, params) do
            {:error, "unknown tool: " <> _} ->
              case Kudzu.Brain.Tools.Host.execute(name, params) do
                {:error, "unknown host tool: " <> _} ->
                  Kudzu.Brain.Tools.Escalation.execute(name, params)

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
        # Escalation from chat — fall through to thinking layer
        chat_think_then_claude_stream(state, message, stream_to)

      :pass ->
        # No reflex match — try thinking layer
        chat_think_then_claude_stream(state, message, stream_to)
    end
  end

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
            Kudzu.Brain.Tools.Escalation.to_claude_format()

        # Set up tool executor with call tracking
        Process.put(:chat_tool_calls, [])

        executor = fn name, params ->
          Process.put(:chat_tool_calls, [name | Process.get(:chat_tool_calls)])

          case Kudzu.Brain.Tools.Introspection.execute(name, params) do
            {:error, "unknown tool: " <> _} ->
              case Kudzu.Brain.Tools.Host.execute(name, params) do
                {:error, "unknown host tool: " <> _} ->
                  Kudzu.Brain.Tools.Escalation.execute(name, params)

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
end
