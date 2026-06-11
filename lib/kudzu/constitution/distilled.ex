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

  @doc """
  Soft permission check based on distilled rules.

  - `:permitted` if the action has no rule-relevant subject, or if its
    `params[:subject]` matches a subject the distilled silo has evidence
    for.
  - `{:denied, :no_evidence}` if the action's subject is unknown and the
    distilled rules are present.
  - `:permitted` if `state` carries no distilled rules at all (fail open
    — the framework is advisory, not enforcing, in this first tier).
  """
  @impl true
  @spec permitted?(Kudzu.Constitution.Behaviour.action(), map()) ::
          :permitted | {:denied, :no_evidence}
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
  Stub. Tasks 16-18 will wire `loop_permitted?/3` into the 5-stage
  `permitted?/2` pipeline so distilled constitutions can govern AGI
  self-conversation. Until then, the brake is inactive.
  """
  @spec loop_permitted?(map(), Kudzu.HRR.vector(), non_neg_integer()) ::
          {:error, :not_implemented}
  def loop_permitted?(_state, _thought_vector, _depth), do: {:error, :not_implemented}

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
