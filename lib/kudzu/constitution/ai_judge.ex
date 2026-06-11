defmodule Kudzu.Constitution.AIJudge do
  @moduledoc """
  Evaluation-time Claude call. Input: proposal + N nearest positive
  triples + N nearest rejection vectors + accumulated weight context +
  principle in question. Output: a verdict + confidence + reasoning
  + cited evidence.

  Adaptive sampling (spec decision #12): min 3 samples, escalates to
  5 on any split. Average cost near N=3 because unanimous cases
  dominate by design.

  Evidence-grounded denial rule (spec decision #10): the verdict may
  only result in a `:denied` runtime decision when `cited_evidence`
  includes a rejection-silo vector above the confirmation similarity
  `τ_C`. Otherwise high-confidence `:retards` is downgraded to
  escalation (Stage 5) at weight 0.8.

  Claude integration uses `Kudzu.Brain.Claude.simple_message/3` with the
  `ANTHROPIC_API_KEY` env var. If the env var is absent, `judge/1`
  returns `{:error, :missing_api_key}`.
  """

  alias Kudzu.Brain.Claude

  @min_samples Application.compile_env(:kudzu, :constitution_ai_judge_samples_min, 3)
  @max_samples Application.compile_env(:kudzu, :constitution_ai_judge_samples_max, 5)
  @default_tau_c 0.65

  @type verdict :: :advances | :retards | :ambiguous
  @type judgment :: {verdict(), float(), String.t(), String.t(), [map()]}
  # {verdict, confidence, principle, reasoning, cited_evidence}

  @doc """
  Run the AI Judge with adaptive sampling. Returns the consensus
  judgment.
  """
  @spec judge(map()) :: {:ok, judgment()} | {:error, term()}
  def judge(context) do
    case System.get_env("ANTHROPIC_API_KEY") do
      nil ->
        {:error, :missing_api_key}

      "" ->
        {:error, :missing_api_key}

      api_key ->
        run_adaptive(api_key, context)
    end
  end

  defp run_adaptive(api_key, context) do
    case sample_until_decision(api_key, context, [], @min_samples) do
      {:ok, judgment} ->
        {:ok, judgment}

      {:needs_more, partial} ->
        case sample_until_decision(api_key, context, partial, @max_samples) do
          {:ok, judgment} -> {:ok, judgment}
          {:needs_more, all} -> {:ok, majority_decision(all)}
          {:error, _} = err -> err
        end

      {:error, _} = err ->
        err
    end
  end

  defp sample_until_decision(api_key, context, partial, target_count) do
    needed = max(target_count - length(partial), 0)

    new_samples =
      if needed > 0 do
        1..needed
        |> Stream.map(fn _ -> one_sample(api_key, context) end)
        |> Stream.reject(&match?({:error, _}, &1))
        |> Enum.to_list()
      else
        []
      end

    all = partial ++ new_samples

    case all do
      [] ->
        {:error, :all_samples_failed}

      _ ->
        case adaptive_sampling_decision(all) do
          :needs_more when length(all) >= @max_samples ->
            {:ok, majority_decision(all)}

          :needs_more ->
            {:needs_more, all}

          verdict_tuple ->
            {:ok, verdict_tuple}
        end
    end
  end

  @doc """
  Decide based on current samples. Returns `:needs_more` if split and
  the count is below `@max_samples`; returns a judgment if consensus
  exists.
  """
  @spec adaptive_sampling_decision([judgment()]) :: judgment() | :needs_more
  def adaptive_sampling_decision(samples) do
    by_verdict = Enum.group_by(samples, &elem(&1, 0))
    total = length(samples)
    advances = Map.get(by_verdict, :advances, [])
    retards = Map.get(by_verdict, :retards, [])

    cond do
      total == 0 ->
        :needs_more

      length(advances) == total ->
        median_with_confidence(advances, 1.0)

      length(retards) == total ->
        median_with_confidence(retards, 1.0)

      total < @max_samples ->
        :needs_more

      true ->
        majority_decision(samples)
    end
  end

  defp majority_decision(samples) do
    by_verdict = Enum.group_by(samples, &elem(&1, 0))
    total = length(samples)

    {_verdict, group} =
      Enum.max_by(by_verdict, fn {_v, list} -> length(list) end)

    agreement = length(group) / total
    median_with_confidence(group, agreement)
  end

  defp median_with_confidence(group, agreement_factor) do
    sorted = Enum.sort_by(group, &elem(&1, 1))
    {v, score, principle, reasoning, evidence} = Enum.at(sorted, div(length(sorted), 2))
    final_confidence = score * agreement_factor
    {v, final_confidence, principle, reasoning, evidence}
  end

  @doc """
  Is the Stage 4 denial evidence-grounded? (Spec decision #10.)
  Returns true only if `cited_evidence` includes at least one entry
  with `source: :rejection_silo` and `similarity > tau_c`.
  """
  @spec evidence_grounded_denial?([map()], float()) :: boolean()
  def evidence_grounded_denial?(cited_evidence, tau_c \\ @default_tau_c) do
    Enum.any?(cited_evidence, fn ev ->
      Map.get(ev, :source) == :rejection_silo and Map.get(ev, :similarity, 0.0) > tau_c
    end)
  end

  defp one_sample(api_key, context) do
    prompt = build_prompt(context)

    case Claude.simple_message(api_key, prompt, max_tokens: 2048) do
      {:ok, text, _usage} -> parse_response(text)
      {:error, _} = err -> err
    end
  end

  defp build_prompt(context) do
    """
    Judge a governance proposal against accumulated constitutional context.

    Proposal: #{context.proposal}

    Principle under pressure: #{context.principle}

    Nearest positive evidence (advances self-sovereignty):
    #{Enum.map_join(context.positive_triples, "\n", &"  - #{inspect(&1)}")}

    Nearest rejection evidence (retards self-sovereignty):
    #{Enum.map_join(context.rejection_vectors, "\n", &"  - #{inspect(&1)}")}

    Accumulated weight on this principle: #{context.accumulated_weight}

    Respond in this exact JSON shape (no prose, no markdown fence):
    {
      "verdict": "advances" | "retards" | "ambiguous",
      "confidence": <0.0 to 1.0>,
      "principle": "<principle name>",
      "reasoning": "<one sentence>",
      "cited_evidence": [
        {"source": "expertise_silo" | "rejection_silo", "similarity": <float>, "ref": "<short ref>"}
      ]
    }
    """
  end

  defp parse_response(text) do
    case Jason.decode(text) do
      {:ok,
       %{
         "verdict" => v,
         "confidence" => c,
         "principle" => p,
         "reasoning" => r,
         "cited_evidence" => ev
       }}
      when v in ["advances", "retards", "ambiguous"] ->
        verdict_atom = safe_verdict(v)

        normalized_ev =
          Enum.map(ev, fn e ->
            %{
              source: e |> Map.get("source") |> safe_atom(),
              similarity: e |> Map.get("similarity", 0.0) |> ensure_float(),
              ref: Map.get(e, "ref", "")
            }
          end)

        {verdict_atom, ensure_float(c), p, r, normalized_ev}

      _ ->
        {:error, :malformed_response}
    end
  end

  defp safe_verdict("advances"), do: :advances
  defp safe_verdict("retards"), do: :retards
  defp safe_verdict("ambiguous"), do: :ambiguous

  defp safe_atom("expertise_silo"), do: :expertise_silo
  defp safe_atom("rejection_silo"), do: :rejection_silo
  defp safe_atom(_), do: :unknown

  defp ensure_float(x) when is_float(x), do: x
  defp ensure_float(x) when is_integer(x), do: x * 1.0
  defp ensure_float(_), do: 0.0
end
