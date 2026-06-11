defmodule Kudzu.Constitution.Filter.SovereigntyFilter do
  @moduledoc """
  Distillation-time judgment: given a candidate triple + its source
  context, decide whether the triple ADVANCES or RETARDS individual
  self-sovereignty per Mesh Republic §5.1 criteria.

  Output shapes:
    * `{:advances, score :: float, principle :: String.t()}`
    * `{:retards, score :: float, principle :: String.t(), reason :: String.t()}`
    * `{:contested, atom}` — 3-way split, normalization failure, or empty samples

  §5.1 principles (allowed `principle` values):
    * `"non_aggression"` — NAP; uninvited force is impermissible
    * `"bodily_autonomy"` — self-ownership absolute
    * `"property_in_labor"` — fruits of labor are self-owned
    * `"property_in_commons"` — usufructuary, conditional
    * `"free_speech"` — 1A-class expression rights
    * `"free_assembly"` — peaceful association
    * `"free_press"` — publication independence
    * `"freedom_from_unreasonable_search"` — 4A-class
    * `"due_process"` — 5A/14A-class
    * `"self_governance"` — exit + consent
    * `"limited_government"` — enumerated-powers principle
    * `"separation_of_powers"`
    * `"federalism"` — local autonomy

  ## Self-consistency

  `judge/2` runs `N` (default 3) independent Claude samples at
  `temperature: 0.0`, normalizes each, and routes through
  `self_consistency_decide/1`. 2-of-3 verdict agreement wins; the
  median-score sample is returned as the representative. 3-way splits
  yield `{:contested, :three_way_split}`.

  Claude integration uses `Kudzu.Brain.Claude.simple_message/3` with the
  `ANTHROPIC_API_KEY` env var. If the env var is absent, `judge/2`
  returns `{:error, :missing_api_key}`.
  """

  alias Kudzu.Brain.Claude

  @principles ~w[
    non_aggression bodily_autonomy property_in_labor property_in_commons
    free_speech free_assembly free_press freedom_from_unreasonable_search
    due_process self_governance limited_government separation_of_powers
    federalism
  ]

  @samples Application.compile_env(:kudzu, :sovereignty_filter_samples, 3)

  @type triple :: {String.t(), String.t(), String.t()}
  @type judgment ::
          {:advances, float(), String.t()}
          | {:retards, float(), String.t(), String.t()}
          | {:contested, atom()}

  @doc """
  Real distillation entry. Calls Claude N times (default 3), runs self-
  consistency, returns the consensus judgment or `{:contested, reason}`.

  Returns `{:ok, judgment}` if at least one sample succeeded, or
  `{:error, reason}` if all samples failed (Claude errored every time)
  or the API key is missing.
  """
  @spec judge(triple(), String.t()) :: {:ok, judgment()} | {:error, term()}
  def judge(triple, source_context) do
    case System.get_env("ANTHROPIC_API_KEY") do
      nil ->
        {:error, :missing_api_key}

      "" ->
        {:error, :missing_api_key}

      api_key ->
        samples =
          1..@samples
          |> Enum.map(fn _ -> one_judgment(api_key, triple, source_context) end)
          |> Enum.reject(&match?({:error, _}, &1))

        case samples do
          [] -> {:error, :all_samples_failed}
          list -> {:ok, self_consistency_decide(list)}
        end
    end
  end

  @doc """
  Decide consensus from a list of samples. 2 or more agree on the same
  verdict (`:advances` or `:retards`) → return median-score
  representative. Otherwise → `{:contested, :three_way_split}`.
  Empty list → `{:contested, :no_samples}`.
  """
  @spec self_consistency_decide([judgment()]) :: judgment()
  def self_consistency_decide([]), do: {:contested, :no_samples}

  def self_consistency_decide(samples) do
    by_verdict = Enum.group_by(samples, &elem(&1, 0))
    advances = Map.get(by_verdict, :advances, [])
    retards = Map.get(by_verdict, :retards, [])

    cond do
      length(advances) >= 2 -> median_by_score(advances)
      length(retards) >= 2 -> median_by_score(retards)
      true -> {:contested, :three_way_split}
    end
  end

  @doc """
  Normalize a raw model-response judgment. Validates score range [0, 1]
  and principle membership against the 13 recognized §5.1 principles.
  Out-of-range scores → `{:contested, :out_of_range}`. Unknown principles
  → `{:contested, :unknown_principle}`. Anything else (including
  `:ambiguous` verdicts and malformed shapes) → `{:contested, ...}`.
  """
  @spec normalize_judgment(tuple()) :: judgment()
  def normalize_judgment({:advances, score, _}) when score < 0.0 or score > 1.0,
    do: {:contested, :out_of_range}

  def normalize_judgment({:retards, score, _, _}) when score < 0.0 or score > 1.0,
    do: {:contested, :out_of_range}

  def normalize_judgment({:advances, score, principle}) when is_number(score) do
    if principle in @principles do
      {:advances, score * 1.0, principle}
    else
      {:contested, :unknown_principle}
    end
  end

  def normalize_judgment({:retards, score, principle, reason}) when is_number(score) do
    if principle in @principles do
      {:retards, score * 1.0, principle, reason}
    else
      {:contested, :unknown_principle}
    end
  end

  def normalize_judgment({:ambiguous, score, _}) when score < 0.0 or score > 1.0,
    do: {:contested, :out_of_range}

  def normalize_judgment({:ambiguous, _score, _principle}),
    do: {:contested, :ambiguous_verdict}

  def normalize_judgment(_other), do: {:contested, :malformed}

  # ── Internal ────────────────────────────────────────────────────────

  defp median_by_score(judgments) do
    sorted = Enum.sort_by(judgments, &elem(&1, 1))
    Enum.at(sorted, div(length(sorted), 2))
  end

  defp one_judgment(api_key, triple, source_context) do
    prompt = build_prompt(triple, source_context)

    case Claude.simple_message(api_key, prompt, max_tokens: 1024) do
      {:ok, text, _usage} -> parse_response(text)
      {:error, _} = err -> err
    end
  end

  defp build_prompt({s, r, o}, ctx) do
    """
    Judge a constitutional triple by whether it ADVANCES or RETARDS
    individual self-sovereignty.

    Triple: (#{s}, #{r}, #{o})
    Source context: #{ctx}

    Criteria (Mesh Republic §5.1):
    - Non-Aggression Principle
    - Bodily autonomy
    - Property in labor
    - Free speech, assembly, press
    - Freedom from unreasonable search
    - Due process
    - Self-governance with exit rights
    - Limited government

    Recognized principles (use exactly one):
    non_aggression, bodily_autonomy, property_in_labor, property_in_commons,
    free_speech, free_assembly, free_press, freedom_from_unreasonable_search,
    due_process, self_governance, limited_government, separation_of_powers,
    federalism

    Respond in this exact JSON shape (no prose, no markdown fence):
    {
      "verdict": "advances" | "retards" | "ambiguous",
      "score": <0.0 to 1.0>,
      "principle": "<one of the recognized principles>",
      "reason": "<one sentence; required for retards>"
    }
    """
  end

  defp parse_response(text) do
    case Jason.decode(text) do
      {:ok, %{"verdict" => "advances", "score" => s, "principle" => p}} when is_number(s) ->
        normalize_judgment({:advances, s * 1.0, p})

      {:ok, %{"verdict" => "retards", "score" => s, "principle" => p, "reason" => r}}
      when is_number(s) ->
        normalize_judgment({:retards, s * 1.0, p, r})

      {:ok, %{"verdict" => "ambiguous", "score" => s, "principle" => p}} when is_number(s) ->
        normalize_judgment({:ambiguous, s * 1.0, p})

      _ ->
        {:contested, :malformed_response}
    end
  end
end
