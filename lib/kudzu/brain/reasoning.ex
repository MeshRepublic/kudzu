defmodule Kudzu.Brain.Reasoning do
  @moduledoc """
  Autonomous-cycle reasoning pipeline for `Kudzu.Brain`.

  Owns Tiers 1–3 of the wake-cycle response to anomalies: reflexes,
  silo inference, and Claude. Also handles distillation of Claude
  responses back into silos (shared with `Kudzu.Brain.Chat` once
  extracted).
  """

  require Logger

  alias Kudzu.Brain
  alias Kudzu.Brain.Budget
  alias Kudzu.Brain.Distiller
  alias Kudzu.Brain.InferenceEngine
  alias Kudzu.Brain.PromptBuilder
  alias Kudzu.Brain.Reflexes
  alias Kudzu.Brain.WorkingMemory

  @doc """
  Run the three-tier reasoning pipeline against a list of anomaly maps.

  Returns the (possibly updated) Brain state. Expects each anomaly to
  expose at least `:check` and `:reason` keys; tier-1 reflexes wrap the
  anomalies in `{:anomaly, _}` tuples internally.
  """
  @spec reason(Brain.t(), [map()]) :: Brain.t()
  def reason(state, anomalies) do
    tagged = Enum.map(anomalies, &{:anomaly, &1})

    # Tier 1: Reflexes — pattern → action, zero cost
    case Reflexes.check(tagged) do
      {:act, actions} ->
        Logger.info("[Brain] Tier 1: executing #{length(actions)} reflex actions")
        Enum.each(actions, &Reflexes.execute_action/1)

        Brain.record_trace(state, :decision, %{
          tier: "reflex",
          actions: Enum.map(actions, &inspect/1)
        })

        state

      {:escalate, alerts} ->
        Brain.record_trace(state, :observation, %{
          alert: true,
          severity: alert_severity(alerts),
          alerts: Enum.map(alerts, &Brain.ensure_map/1)
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

  @doc """
  Distill knowledge from a Claude response into silos and update
  curiosity questions in the Brain's working memory.

  Returns the (possibly updated) Brain state. Exceptions inside the
  Distiller pipeline are swallowed — distillation is a best-effort
  enhancement, not a correctness requirement.
  """
  @spec distill_claude_response(Brain.t(), String.t()) :: Brain.t()
  def distill_claude_response(state, response_text) do
    try do
      silo_domains =
        Kudzu.Silo.list()
        |> Enum.map(fn {domain, _, _} -> domain end)
        |> Enum.reject(&(&1 == nil))

      available_actions =
        if function_exported?(Reflexes, :known_actions, 0) do
          try do
            # apply/3 used here because the function is dynamically gated by
            # function_exported?/3 above; a direct call would emit a compile-time
            # warning when Reflexes.known_actions/0 is removed.
            # credo:disable-for-next-line Credo.Check.Refactor.Apply
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
      state =
        if result.chains != [] do
          Logger.info(
            "[Brain] Distiller extracted #{length(result.chains)} relationships from Claude response"
          )

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

        wm =
          if wm do
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

  # ── Internals ───────────────────────────────────────────────────────

  defp maybe_tier2_3(state, anomalies) do
    # Tier 2: Silo inference — check if any expertise silo has relevant knowledge
    silo_results = try_silo_inference(anomalies)

    case silo_results do
      {:found, findings} ->
        Logger.info("[Brain] Tier 2: silo inference found #{length(findings)} relevant facts")

        Brain.record_trace(state, :thought, %{
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
            hint: Brain.ensure_map(hint),
            score: score,
            confidence: InferenceEngine.confidence(score)
          }
        end)

      {:found, Enum.take(findings, 10)}
    else
      :no_match
    end
  end

  # — Tool dispatch chain inside Claude executor — same fall-through pattern as chat.ex
  # credo:disable-for-next-line Credo.Check.Refactor.Nesting
  defp maybe_call_claude(state, anomalies) do
    api_key = state.config[:api_key] || state.config["api_key"]

    budget_limit =
      state.config[:budget_limit_monthly] || state.config["budget_limit_monthly"] || 100.0

    cond do
      is_nil(api_key) or api_key == "" ->
        Logger.debug("[Brain] No API key configured, skipping Tier 3")
        state

      not Budget.within_budget?(state.budget, budget_limit) ->
        Logger.warning(
          "[Brain] Monthly budget exceeded ($#{state.budget.estimated_cost_usd}), skipping Tier 3"
        )

        state

      true ->
        system_prompt = PromptBuilder.build(state)

        anomaly_desc =
          Enum.map_join(anomalies, "; ", fn a ->
            "#{a.check}: #{a.reason}"
          end)

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
                # — tool fall-through chain inside maybe_call_claude/2.
                {:error, "unknown host tool: " <> _} ->
                  # credo:disable-for-next-line Credo.Check.Refactor.Nesting
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

            Brain.record_trace(state, :thought, %{
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

            Brain.record_trace(state, :observation, %{
              error: "claude_api_failure",
              reason: inspect(reason)
            })

            state
        end
    end
  end

  # Extract severity from the first alert in the list, defaulting to :unknown
  defp alert_severity([%{severity: sev} | _]), do: sev
  defp alert_severity(_), do: :unknown
end
