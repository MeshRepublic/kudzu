defmodule Kudzu.Brain.Chat do
  @moduledoc """
  Interactive chat pipeline for `Kudzu.Brain`.

  Owns the four-tier escalation used for `chat/2` and `chat_stream/3`:
  reflexes → semantic recall → silo inference → web search → Claude API,
  plus directive parsing (`Learn <topic>`, `progress`) and Thought-result
  integration into working memory.

  Depends on `Kudzu.Brain.Learning` for directive routing and
  `Kudzu.Brain.Reasoning` for Claude-response distillation.
  """

  require Logger

  alias Kudzu.Brain
  alias Kudzu.Brain.Budget
  alias Kudzu.Brain.Learning
  alias Kudzu.Brain.PromptBuilder
  alias Kudzu.Brain.Reasoning
  alias Kudzu.Brain.Reflexes
  alias Kudzu.Brain.Thought
  alias Kudzu.Brain.WebLearner
  alias Kudzu.Brain.WorkingMemory

  @doc """
  Run the synchronous chat pipeline against a user message.

  Returns `{response_text, tier, tool_calls, cost, new_state}`. The tier
  atom indicates which escalation level produced the answer (1/`:recall`/
  `:synthesis`/`:web`/3). Expects `state.hologram_id` non-nil — the
  caller checks this before invoking.
  """
  @spec chat_reason(Brain.t(), String.t(), keyword()) ::
          {String.t(), atom() | integer(), list(), float(), Brain.t()}
  def chat_reason(state, message, _opts) do
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

  @doc """
  Streaming variant of `chat_reason/3`.

  Sends progress events (`{:thinking, tier, label}`, `{:chunk, text}`)
  to `stream_to` as the pipeline progresses, and returns the same tuple
  shape as `chat_reason/3` once finished.
  """
  @spec chat_reason_stream(Brain.t(), String.t(), pid(), keyword()) ::
          {String.t(), atom() | integer(), list(), float(), Brain.t()}
  def chat_reason_stream(state, message, stream_to, _opts) do
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

  @doc """
  Integrate the activations + chain from a `Thought.Result` into the
  Brain's working memory.

  Returns the updated state. No-op if `state.working_memory` is nil or
  the result is not a recognized `Thought.Result`.
  """
  @spec integrate_thought(Brain.t(), Thought.Result.t() | any()) :: Brain.t()
  def integrate_thought(%{working_memory: nil} = state, _result), do: state
  def integrate_thought(state, %Thought.Result{} = result) do
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
  def integrate_thought(state, _result), do: state

  # ── Directive Parsing (Learn X, progress) ───────────────────────────

  defp handle_directive_or_escalate(state, message) do
    case parse_directive(message) do
      {:learn, topic} ->
        Learning.start_learning_goal(state, topic)

      :progress ->
        Learning.report_learning_progress(state)

      :not_directive ->
        chat_escalate(state, message)
    end
  end

  defp handle_directive_or_escalate_stream(state, message, stream_to) do
    case parse_directive(message) do
      {:learn, topic} ->
        {response, tier, tool_calls, cost, state} = Learning.start_learning_goal(state, topic)
        send(stream_to, {:chunk, response})
        {response, tier, tool_calls, cost, state}

      :progress ->
        {response, tier, tool_calls, cost, state} = Learning.report_learning_progress(state)
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

  # ── Tiered Query Escalation Pipeline (Phase 5) ──────────────────────
  #
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

      Brain.record_trace(state, :thought, %{
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

        Brain.record_trace(state, :thought, %{
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

          Brain.record_trace(state, :thought, %{
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

          Brain.record_trace(state, :thought, %{
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
            Reasoning.distill_claude_response(new_state, response_text)
          else
            new_state
          end

          {response_text, tier, tool_calls, cost, new_state}
        end
      end
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
      Brain.record_trace(state, :thought, %{source: "chat_escalation", tier: "recall", top_score: top_score})
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
        Brain.record_trace(state, :thought, %{source: "chat_escalation", tier: "synthesis", confidence: thought_result.confidence})
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
          Brain.record_trace(state, :thought, %{source: "chat_escalation", tier: "web", chains_stored: findings.chains_stored})
          send(stream_to, {:chunk, response})
          {response, :web, [], 0.0, state}
        else
          # Tier 4: Claude API
          send(stream_to, {:thinking, :claude, "Consulting Claude API..."})
          enhanced_message = build_enriched_message(message, context)
          Brain.record_trace(state, :thought, %{source: "chat_escalation", tier: "claude", reason: "free_tiers_exhausted"})

          {response_text, tier, tool_calls, cost, new_state} =
            chat_with_claude_stream(state, enhanced_message, stream_to)

          # Distill knowledge from Claude's streamed response — mirrors
          # the non-streaming chat_escalate path so streaming clients do
          # not silently bypass brain_knowledge ingestion.
          new_state =
            if tier == 3 and is_binary(response_text) and response_text != "" do
              Reasoning.distill_claude_response(new_state, response_text)
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
end
