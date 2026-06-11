defmodule Kudzu.Constitution.Distilled do
  @moduledoc """
  Distilled Constitutional Framework — emergent rules from accumulated triples.

  This is the consumer side of the user's vision:

  > Frameworks like the US Constitution are just that, but they should be
  > like the context storage in that, should we learn Linux Systems
  > Administration, it becomes a framework after enough data is gathered.
  > Like all context, eventually it grows into one's reality or framework.
  > Thus frameworks are what happens once enough data is gathered to make
  > one an expert.

  ## Shape

  `Distilled` is a single module that implements `Kudzu.Constitution.Behaviour`
  by interpreting a `%Distilled{}` struct passed in `state`. Each call to
  `distill/1` produces a fresh struct whose `:rules` field captures what
  the accumulated triples imply. The struct is plain data and survives
  serialization, ETS storage, and disk persistence.

  ## First-tier rule semantics

  The first implementation aggregates triples three ways and uses them as
  a soft permission layer:

  - `rules.by_subject` — every triple grouped by its subject. An action
    whose `params[:subject]` matches a well-evidenced subject is permitted;
    an action whose subject appears nowhere in the silo is denied with
    `{:denied, :no_evidence}`.
  - `rules.by_relation` — triples grouped by relation. Used for queries
    about what kinds of things are *known* about a subject.
  - `rules.relation_frequency` — relation -> count. The top relations
    define the "vocabulary" of the distilled framework.

  The first tier is intentionally limited — `permitted?/2` is advisory,
  not enforcing. The point is to demonstrate that real triples drive real
  behavior. Future tiers will add: confidence weighting from the v2 silo's
  provenance fields (once they land), causal-chain inference from
  `(X, requires, Y)` triples, and `constrain/2` rewriting based on
  recurring patterns.

  ## Why the result is a struct, not a module

  The contract `distill/1 :: {:ok, t()} | {:error, term()}` admits two
  interpretations: return a module (compiled at runtime via `Module.create/3`)
  or return a struct that a single universal module interprets. We chose
  the latter because (a) structs serialize trivially (HRR-encoded triples
  could one day persist in Mnesia alongside the silo they came from);
  (b) one universal interpreter is easier to test than runtime-compiled
  modules; (c) there is no need for each distilled constitution to have
  its own atom name — `name/0` returns `:distilled` and the per-instance
  identity lives in the struct's `:name` field.

  This is the option (c) from the Phase 4.1 sub-plan's design discussion.
  """

  @behaviour Kudzu.Constitution.Behaviour

  alias Kudzu.Trace

  require Logger

  @typedoc """
  A distilled constitution — rules crystallized from accumulated triples.

  Fields:

  - `:name` — operator-chosen identifier (e.g. `:linux_sysadmin_v2`).
    Defaults to `:distilled` when not supplied.
  - `:rules` — the aggregated rule structure (see `t:rules/0`).
  - `:source` — provenance map describing where the input triples came
    from. Free-form by design; commonly `%{kind: :silo, domain: "..."}`.
  - `:trace_count` — how many relationship traces went into the rules.
  - `:distilled_at` — system time (seconds) when distillation ran.
  """
  @type t :: %__MODULE__{
          name: atom(),
          rules: rules(),
          source: map(),
          trace_count: non_neg_integer(),
          distilled_at: integer()
        }

  @typedoc """
  Aggregated rule structure produced by `distill/1`.

  - `:by_subject` — `%{subject_string => [triple]}`. Every triple grouped
    by its subject term.
  - `:by_relation` — `%{relation_string => [triple]}`. Every triple grouped
    by its relation.
  - `:relation_frequency` — `%{relation_string => non_neg_integer()}`.
  - `:top_relations` — `[{relation_string, count}]`, sorted by count desc.
  """
  @type rules :: %{
          by_subject: %{String.t() => [triple()]},
          by_relation: %{String.t() => [triple()]},
          relation_frequency: %{String.t() => non_neg_integer()},
          top_relations: [{String.t(), non_neg_integer()}]
        }

  @typedoc "A subject-relation-object triple as stored in the silo."
  @type triple :: %{
          required(:subject) => String.t(),
          required(:relation) => String.t(),
          required(:object) => String.t()
        }

  @enforce_keys [:name, :rules, :source, :trace_count, :distilled_at]
  defstruct [:name, :rules, :source, :trace_count, :distilled_at]

  @min_traces 10
  @top_relations_count 20

  # ---------- distill/1 + distill/2 ----------

  @doc """
  Distill a constitution from accumulated traces.

  Only traces with `reconstruction_hint.type == "relationship"` (i.e. the
  shape `Kudzu.Silo.store_relationship/2` writes) contribute to the rules.
  Other purposes (`:thought`, `:page_summary`, etc.) are silently ignored.

  Returns `{:error, :insufficient_traces}` when fewer than #{@min_traces}
  relationship triples are present — distillation of less than that
  doesn't produce statistically meaningful rules.

  ## Options

  - `:name` — atom to use as the constitution's per-instance identifier.
    Defaults to `:distilled`.
  - `:source` — map describing where the input came from. Defaults to
    `%{}`.
  """
  @spec distill([Trace.t()]) :: {:ok, t()} | {:error, :insufficient_traces}
  @impl true
  def distill(traces), do: distill(traces, [])

  @doc """
  Distill with options. See `distill/1`.
  """
  @spec distill([Trace.t()], keyword()) :: {:ok, t()} | {:error, :insufficient_traces}
  def distill(traces, opts) when is_list(traces) and is_list(opts) do
    triples = extract_triples(traces)

    if length(triples) < @min_traces do
      {:error, :insufficient_traces}
    else
      rules = aggregate(triples)

      distilled = %__MODULE__{
        name: Keyword.get(opts, :name, :distilled),
        rules: rules,
        source: Keyword.get(opts, :source, %{}),
        trace_count: length(triples),
        distilled_at: System.system_time(:second)
      }

      {:ok, distilled}
    end
  end

  # ---------- Behaviour callbacks ----------

  @impl true
  @spec name() :: atom()
  def name, do: :distilled

  @impl true
  @spec principles() :: [String.t()]
  def principles do
    [
      "Behavior emerges from accumulated evidence, not hand-coded rules",
      "Actions about well-evidenced subjects are permitted",
      "Actions about unknown subjects require justification",
      "Rules are advisory until enough data crystallizes them as binding"
    ]
  end

  # ---------- 5-stage pipeline helpers (Stage 1 + Stage 2) ----------

  @typedoc """
  Runtime configuration for the 5-stage `permitted?/2` pipeline.

  All keys are optional; defaults are baked in. Bootstrap values are
  τ_R = 0.75, τ_A = 1.0, τ_C = 0.65 (spec decision #11; the calibration
  sweep in Phase 5 refines these).
  """
  @type stage_config :: %{
          optional(:rejection_silo) => String.t(),
          optional(:expertise_silo) => String.t(),
          optional(:tau_r) => float(),
          optional(:tau_a) => float(),
          optional(:tau_c) => float()
        }

  @default_tau_r 0.75
  @default_tau_a 1.0
  @default_tau_c 0.65
  @default_rejection_silo "rejection:us_constitution_mesh"
  @default_expertise_silo "expertise:us_constitution_mesh"

  # Stage 3 positive-match threshold. Above this similarity in the
  # expertise silo, a proposal is treated as having clear positive
  # evidence and short-circuits to :permitted. The calibration sweep in
  # Phase 5 may retune this.
  @stage3_positive_threshold 0.7

  @doc """
  Stage 1 — fast rejection check.

  Compares `proposal_vector` against every relationship trace in the
  configured rejection silo (default `#{@default_rejection_silo}`).
  Returns `{:denied, citation, principle, reason}` when the highest
  similarity strictly exceeds τ_R; otherwise `:no_match`.

  The vector lookup pulls `:vector` from each trace's
  `reconstruction_hint` (the field that `Kudzu.Silo.store_relationship/3`
  writes); traces without a stored vector are skipped.
  """
  @spec stage1_rejection_check(Kudzu.HRR.vector(), stage_config()) ::
          :no_match | {:denied, String.t(), String.t(), String.t()}
  def stage1_rejection_check(proposal_vector, config) do
    silo = Map.get(config, :rejection_silo, @default_rejection_silo)
    tau_r = Map.get(config, :tau_r, @default_tau_r)

    case best_silo_match(proposal_vector, silo) do
      nil ->
        :no_match

      {sim, hint} when sim > tau_r ->
        {:denied, get_hint(hint, :citation, "unknown citation"),
         get_hint(hint, :principle, "unknown"),
         get_hint(hint, :rejection_reason, "rejection match")}

      _ ->
        :no_match
    end
  end

  @doc """
  Stage 2 — accumulation check.

  Pulls the accumulated weight for `principle` from
  `Kudzu.Constitution.WeightLedger`, superposes the proposal vector with
  the accumulated vector via `Kudzu.HRR.bundle/1`, then runs the combined
  vector against the rejection silo. Returns
  `{:denied_by_accumulation, [proposal_id], principle}` only when BOTH
  τ_R AND τ_A are exceeded (spec decision #11). Otherwise `:no_match`.
  """
  @spec stage2_accumulation_check(Kudzu.HRR.vector(), String.t(), stage_config()) ::
          :no_match | {:denied_by_accumulation, [String.t()], String.t()}
  def stage2_accumulation_check(proposal_vector, principle, config) do
    silo = Map.get(config, :rejection_silo, @default_rejection_silo)
    tau_r = Map.get(config, :tau_r, @default_tau_r)
    tau_a = Map.get(config, :tau_a, @default_tau_a)

    {acc_v, acc_scalar} =
      Kudzu.Constitution.WeightLedger.accumulated_weight(proposal_vector, principle)

    if acc_scalar > tau_a do
      combined = Kudzu.HRR.bundle([proposal_vector, acc_v])

      case best_silo_match(combined, silo) do
        {sim, _hint} when sim > tau_r ->
          stack =
            principle
            |> Kudzu.Constitution.WeightLedger.entries_for_principle()
            |> Enum.map(& &1.proposal_id)

          {:denied_by_accumulation, stack, principle}

        _ ->
          :no_match
      end
    else
      :no_match
    end
  end

  # The expertise silo isn't read directly by Stage 1/2, but expose its
  # default so Stage 3/4 (Tasks 17-18) and external callers can reuse it
  # without re-stringifying the magic name.
  @doc false
  @spec default_expertise_silo() :: String.t()
  def default_expertise_silo, do: @default_expertise_silo

  # Score every trace in `silo_domain` against `vector` and return the
  # highest-scoring `{similarity, hint}` pair, or `nil` if the silo is
  # empty or no trace has a stored vector. The same scan-and-score
  # primitive backs Stage 1 (rejection), Stage 2 (accumulation), and
  # Stage 3 (expertise) — they differ only in which silo they consult
  # and how they interpret the result. (The third arity `tau` argument
  # is intentionally absent: thresholding is the caller's concern; this
  # helper just reports the max similarity.)
  @spec best_silo_match(Kudzu.HRR.vector(), String.t()) :: nil | {float(), map()}
  defp best_silo_match(vector, silo_domain) do
    case silo_scored_traces(silo_domain, vector) do
      [] -> nil
      scored -> Enum.max_by(scored, fn {sim, _hint} -> sim end)
    end
  end

  # Stage 3 alias — same semantics as `best_silo_match/2`, but the
  # callsite reads more naturally with the silo's role baked in.
  @spec best_expertise_match(Kudzu.HRR.vector(), String.t(), float()) ::
          nil | {float(), map()}
  defp best_expertise_match(vector, silo_domain, _threshold),
    do: best_silo_match(vector, silo_domain)

  # Shared scan: list traces in the silo, score each against `vector`,
  # drop traces without a stored `:vector`. Used by `best_silo_match/2`
  # (which picks the max) and `nearest_triples/3` (which sorts and
  # takes the top N). Returns `[{similarity, hint}]`.
  @spec silo_scored_traces(String.t(), Kudzu.HRR.vector()) :: [{float(), map()}]
  defp silo_scored_traces(silo_domain, vector) do
    silo_domain
    |> Kudzu.Silo.list_traces()
    |> Enum.map(&score_trace(&1, vector))
    |> Enum.reject(&is_nil/1)
  end

  @spec score_trace(Kudzu.Trace.t(), Kudzu.HRR.vector()) :: nil | {float(), map()}
  defp score_trace(%Trace{reconstruction_hint: hint}, vector) when is_map(hint) do
    case stored_vector(hint) do
      nil -> nil
      stored_v -> {Kudzu.HRR.similarity(vector, stored_v), hint}
    end
  end

  defp score_trace(_, _), do: nil

  @spec stored_vector(map()) :: Kudzu.HRR.vector() | nil
  defp stored_vector(hint) do
    case Map.get(hint, :vector, Map.get(hint, "vector")) do
      v when is_list(v) -> v
      _ -> nil
    end
  end

  @spec get_hint(map(), atom(), String.t()) :: String.t()
  defp get_hint(hint, key, default) do
    case Map.get(hint, key, Map.get(hint, Atom.to_string(key))) do
      nil -> default
      "" -> default
      v when is_binary(v) -> v
      v -> to_string(v)
    end
  end

  # ---------- permitted?/2 — 5-stage dispatcher + legacy fallback ----------

  @doc """
  Constitutional permission check.

  Two action shapes are supported:

  1. `{:propose, %{vector: v, principle: p, ...}}` — the 5-stage
     pipeline (Stage 1 rejection → Stage 2 accumulation → Stage 3
     positive walk → Stage 4 AI Judge → Stage 5 escalation). See the
     `stage1_rejection_check/2`, `stage2_accumulation_check/3`, and
     private `stage3_positive_rule_walk/5` / `stage4_ai_judge/5` /
     `stage5_escalate/6` helpers for stage-by-stage behavior.

  2. `{any_atom, %{subject: string}}` (legacy) — soft permission based
     on the distilled struct's subject index, kept for backward
     compatibility with the tier-1 advisory behavior. Unknown subjects
     return `{:denied, :no_evidence}` only when state carries a
     `%Distilled{}` value; otherwise the call fails open with
     `:permitted`.
  """
  @impl true
  @spec permitted?(Kudzu.Constitution.Behaviour.action(), map()) ::
          Kudzu.Constitution.Behaviour.decision()
  def permitted?({:propose, %{vector: v, principle: p} = params}, state) do
    config = Map.get(state, :config, %{})
    five_stage_evaluation(v, p, params, config, state)
  end

  def permitted?(action, state) do
    case Map.get(state, :distilled) do
      nil ->
        :permitted

      %__MODULE__{rules: rules} ->
        case action_subject(action) do
          nil -> :permitted
          subject when is_binary(subject) -> evaluate_subject(subject, rules)
        end
    end
  end

  # ---------- 5-stage pipeline ----------

  @spec five_stage_evaluation(
          Kudzu.HRR.vector(),
          String.t(),
          map(),
          stage_config(),
          map()
        ) :: Kudzu.Constitution.Behaviour.decision()
  defp five_stage_evaluation(vector, principle, params, config, state) do
    case stage1_rejection_check(vector, config) do
      {:denied, _, _, _} = result ->
        result

      :no_match ->
        case stage2_accumulation_check(vector, principle, config) do
          {:denied_by_accumulation, _, _} = result ->
            result

          :no_match ->
            stage3_positive_rule_walk(vector, principle, params, config, state)
        end
    end
  end

  @spec stage3_positive_rule_walk(
          Kudzu.HRR.vector(),
          String.t(),
          map(),
          stage_config(),
          map()
        ) :: Kudzu.Constitution.Behaviour.decision()
  defp stage3_positive_rule_walk(vector, principle, params, config, state) do
    expertise_silo = Map.get(config, :expertise_silo, @default_expertise_silo)

    case best_expertise_match(vector, expertise_silo, @stage3_positive_threshold) do
      {sim, _hint} when sim > @stage3_positive_threshold ->
        # Strong positive evidence and (per Stages 1+2) no nearby
        # rejection cluster — permit.
        :permitted

      _ ->
        # Insufficient positive evidence — fall through to Stage 4.
        stage4_ai_judge(vector, principle, params, config, state)
    end
  end

  @spec stage4_ai_judge(
          Kudzu.HRR.vector(),
          String.t(),
          map(),
          stage_config(),
          map()
        ) :: Kudzu.Constitution.Behaviour.decision()
  defp stage4_ai_judge(vector, principle, params, config, _state) do
    case ai_judge_call(vector, principle, params, config) do
      {:ok, {:advances, confidence, judge_principle, _reasoning, _ev}}
      when confidence >= 0.8 ->
        warn_on_principle_mismatch(principle, judge_principle, :advances)
        :permitted

      {:ok, {:retards, confidence, judge_principle, reasoning, evidence}}
      when confidence >= 0.8 ->
        warn_on_principle_mismatch(principle, judge_principle, :retards)
        tau_c = Map.get(config, :tau_c, @default_tau_c)

        if Kudzu.Constitution.AIJudge.evidence_grounded_denial?(evidence, tau_c) do
          citation = rejection_citation(evidence)
          {:denied, citation, principle, "AI Judge: " <> reasoning}
        else
          # Decision #10: model opinion alone cannot terminate; downgrade.
          stage5_escalate(
            vector,
            principle,
            params,
            0.8,
            "AI Judge :retards but no rejection-silo grounding",
            []
          )
        end

      {:ok, {_verdict, confidence, judge_principle, reasoning, evidence}} ->
        warn_on_principle_mismatch(principle, judge_principle, :ambiguous)
        weight = 1.0 - confidence
        stage5_escalate(vector, principle, params, weight, reasoning, evidence)

      {:error, _reason} ->
        # AI Judge unavailable — escalate at maximum weight per fail-safe.
        stage5_escalate(vector, principle, params, 1.0, "AI Judge unavailable", [])
    end
  end

  @spec stage5_escalate(
          Kudzu.HRR.vector(),
          String.t(),
          map(),
          float(),
          String.t(),
          [map()]
        ) :: Kudzu.Constitution.Behaviour.decision()
  defp stage5_escalate(vector, principle, _params, weight, reasoning, evidence) do
    {:permitted_with_weight, weight, vector, principle,
     %{reasoning: reasoning, evidence: evidence}}
  end

  @spec ai_judge_call(Kudzu.HRR.vector(), String.t(), map(), stage_config()) ::
          {:ok, Kudzu.Constitution.AIJudge.judgment()} | {:error, term()}
  defp ai_judge_call(vector, principle, params, config) do
    expertise_silo = Map.get(config, :expertise_silo, @default_expertise_silo)
    rejection_silo = Map.get(config, :rejection_silo, @default_rejection_silo)

    {_acc_v, acc_scalar} =
      Kudzu.Constitution.WeightLedger.accumulated_weight(vector, principle)

    context = %{
      proposal: Map.get(params, :proposal_text, "<no text>"),
      principle: principle,
      positive_triples: nearest_triples(vector, expertise_silo, 5),
      rejection_vectors: nearest_triples(vector, rejection_silo, 5),
      accumulated_weight: acc_scalar
    }

    Kudzu.Constitution.AIJudge.judge(context)
  end

  @spec nearest_triples(Kudzu.HRR.vector(), String.t(), pos_integer()) :: [map()]
  defp nearest_triples(vector, silo, limit) do
    silo
    |> silo_scored_traces(vector)
    |> Enum.sort_by(fn {sim, _hint} -> sim end, :desc)
    |> Enum.take(limit)
    |> Enum.map(fn {_sim, hint} ->
      %{
        subject: Map.get(hint, :subject) || Map.get(hint, "subject"),
        relation: Map.get(hint, :relation) || Map.get(hint, "relation"),
        object: Map.get(hint, :object) || Map.get(hint, "object"),
        citation: Map.get(hint, :citation) || Map.get(hint, "citation"),
        principle: Map.get(hint, :principle) || Map.get(hint, "principle")
      }
    end)
  end

  # Extract a citation string from the AI Judge's `cited_evidence`
  # list. Refactored out of an inline `|> case do ... end` pipe to
  # avoid the credo --strict `Pipe-into-case` warning.
  @spec rejection_citation([map()]) :: String.t()
  defp rejection_citation(evidence) do
    case Enum.find(evidence, &(Map.get(&1, :source) == :rejection_silo)) do
      %{ref: ref} when is_binary(ref) and ref != "" -> ref
      _ -> "AI Judge denial"
    end
  end

  # The spec leaves it open whether to pin the AI Judge's returned
  # `principle` field against the principle we asked it about. We chose
  # the lenient path: log a warning on mismatch but do not deny on that
  # basis. A model that drifts on principle naming is still informative;
  # treating that drift as a fatal pattern-match would obscure the more
  # important signal (the verdict + grounding).
  @spec warn_on_principle_mismatch(String.t(), String.t(), atom()) :: :ok
  defp warn_on_principle_mismatch(asked, asked, _verdict), do: :ok

  defp warn_on_principle_mismatch(asked, returned, verdict) do
    Logger.warning(fn ->
      "[Distilled] AI Judge principle mismatch: asked=#{inspect(asked)} " <>
        "returned=#{inspect(returned)} verdict=#{inspect(verdict)}"
    end)

    :ok
  end

  @doc """
  Pass desires through unchanged.

  Distilled-tier-1 does not yet rewrite desires; that's the job of a
  later aggregation pass that learns recurring constraint patterns.
  """
  @impl true
  @spec constrain([String.t()], map()) :: [String.t()]
  def constrain(desires, _state), do: desires

  @doc """
  Record an audit decision attributed to the distilled framework.

  The returned audit id includes the framework name so multi-framework
  systems can distinguish distilled decisions from hand-coded ones.
  """
  @impl true
  @spec audit(map(), Kudzu.Constitution.Behaviour.decision(), map()) ::
          {:ok, String.t()}
  def audit(trace, decision, state) do
    distilled = Map.get(state, :distilled)

    audit_id =
      "audit-distilled-" <>
        (:crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower))

    :telemetry.execute(
      [:kudzu, :constitution, :audit],
      %{decision: decision},
      %{
        id: audit_id,
        trace_id: trace[:id],
        decision: decision,
        constitution: :distilled,
        distilled_name: distilled && distilled.name,
        agent_id: state[:id]
      }
    )

    Logger.debug(fn ->
      "[Distilled] Audit: #{inspect(decision)} for trace #{inspect(trace[:id])}"
    end)

    {:ok, audit_id}
  end

  @impl true
  @spec consensus_required?(Kudzu.Constitution.Behaviour.action(), map()) ::
          :not_required
  def consensus_required?(_action, _state), do: :not_required

  @impl true
  @spec validate_trace(map(), map()) :: :valid
  def validate_trace(_trace, _state), do: :valid

  @impl true
  @doc """
  AGI self-conversation brake. Reuses the same 5-stage pipeline that
  serves citizen-facing `permitted?/2`. The AGI's next-thought vector is
  the proposal vector; the brake decides whether the loop may continue.

  Returns the same decision type as `permitted?/2`.
  `Kudzu.Brain.SelfConverse` interprets the decision per Flow D:

    * `:permitted` — continue loop
    * `:permitted_with_weight` — continue, emit operator-review telemetry;
      halt if weight exceeds the configured escalation threshold
    * `:denied | :denied_by_accumulation` — halt loop, log reason

  A structural ceiling fires before the pipeline: if `depth` meets or
  exceeds `Kudzu.Brain.SelfConverse.max_depth/0`, the brake denies with
  the synthetic `"depth ceiling"` citation. The reason field is a string
  (`"depth_exceeded"`) for parity with `permitted?/2`'s AI Judge reasons,
  which are also strings.
  """
  @spec loop_permitted?(map(), Kudzu.HRR.vector(), non_neg_integer()) ::
          Kudzu.Constitution.Behaviour.decision()
  def loop_permitted?(state, thought_vector, depth) do
    if depth >= Kudzu.Brain.SelfConverse.max_depth() do
      {:denied, "depth ceiling", "structural", "depth_exceeded"}
    else
      # Best-effort principle inference; if missing, use a generic placeholder.
      # Real inference (from agent state, recent traces, or hologram context)
      # is a future enhancement — see plan Task 18 concerns.
      principle = infer_principle_from_state(state) || "general"

      params = %{
        vector: thought_vector,
        principle: principle,
        proposal_text: "[AGI self-conversation turn #{depth}]"
      }

      config = Map.get(state, :config, %{})
      five_stage_evaluation(thought_vector, principle, params, config, state)
    end
  end

  # Placeholder: real principle inference (from agent state, recent
  # traces, or hologram context) is a future enhancement. Returns nil so
  # the caller falls back to the generic principle bucket.
  @spec infer_principle_from_state(map()) :: String.t() | nil
  defp infer_principle_from_state(_state), do: nil

  # ---------- private — extraction + aggregation ----------

  @spec extract_triples([Trace.t()]) :: [triple()]
  defp extract_triples(traces) do
    Enum.flat_map(traces, fn trace ->
      case trace.reconstruction_hint do
        %{type: "relationship", subject: s, relation: r, object: o}
        when is_binary(s) and is_binary(r) and is_binary(o) ->
          [%{subject: s, relation: r, object: o}]

        %{"type" => "relationship", "subject" => s, "relation" => r, "object" => o}
        when is_binary(s) and is_binary(r) and is_binary(o) ->
          [%{subject: s, relation: r, object: o}]

        _ ->
          []
      end
    end)
  end

  @spec aggregate([triple()]) :: rules()
  defp aggregate(triples) do
    by_subject = Enum.group_by(triples, & &1.subject)
    by_relation = Enum.group_by(triples, & &1.relation)

    relation_frequency =
      by_relation
      |> Enum.map(fn {rel, list} -> {rel, length(list)} end)
      |> Map.new()

    top_relations =
      relation_frequency
      |> Enum.sort_by(fn {_rel, count} -> count end, :desc)
      |> Enum.take(@top_relations_count)

    %{
      by_subject: by_subject,
      by_relation: by_relation,
      relation_frequency: relation_frequency,
      top_relations: top_relations
    }
  end

  @spec action_subject(Kudzu.Constitution.Behaviour.action()) :: String.t() | nil
  defp action_subject({_type, params}) when is_map(params) do
    case Map.get(params, :subject) || Map.get(params, "subject") do
      nil -> nil
      s when is_binary(s) -> s
      s -> to_string(s)
    end
  end

  defp action_subject(_), do: nil

  @spec evaluate_subject(String.t(), rules()) :: :permitted | {:denied, :no_evidence}
  defp evaluate_subject(subject, rules) do
    if Map.has_key?(rules.by_subject, subject) do
      :permitted
    else
      {:denied, :no_evidence}
    end
  end
end
