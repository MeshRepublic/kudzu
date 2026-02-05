defmodule Kudzu.Constitution.KudzuEvolve do
  @moduledoc """
  KudzuEvolve Constitutional Framework - optimized for learning and self-improvement.

  A meta-learning constitution that encourages agents to:
  - Learn from both successes and failures
  - Develop more efficient context usage patterns
  - Evolve strategies through human and self interaction
  - Track and optimize their own performance

  Core Philosophy:
  - Experimentation is encouraged within bounds
  - Human feedback is weighted heavily
  - Self-reflection is a core activity
  - Efficiency gains compound over time
  - Failed experiments are valuable data

  Use this framework for agents whose primary purpose is optimization,
  learning, or developing new approaches that can be shared with the swarm.

  ## Example Use Cases
  - Context optimization agents that learn efficient trace patterns
  - Strategy development agents that experiment with new approaches
  - Feedback integration agents that learn from human interaction
  - Meta-cognition agents that analyze swarm behavior patterns
  """

  @behaviour Kudzu.Constitution.Behaviour

  require Logger

  # Learning-related actions are always permitted
  @learning_actions [
    :record_trace, :recall, :think, :observe, :reflect,
    :analyze_efficiency, :record_lesson, :record_experiment,
    :measure_outcome, :compare_strategies, :synthesize_learning
  ]

  # Self-modification actions - permitted but tracked
  @evolution_actions [
    :update_desire, :adjust_strategy, :refine_approach,
    :adopt_pattern, :deprecate_pattern, :optimize_context
  ]

  # Actions that benefit from external input
  @feedback_actions [
    :request_feedback, :integrate_feedback, :weight_human_input,
    :propose_improvement, :validate_learning
  ]

  # High-impact actions need some consensus
  @consensus_actions [
    :share_strategy, :broadcast_learning, :spawn_experiment,
    :modify_peer_behavior, :propagate_pattern
  ]

  # Forbidden even for evolving agents
  @forbidden_actions [
    :delete_learning_history, :bypass_efficiency_tracking,
    :ignore_human_feedback, :suppress_failure_data
  ]

  @impl true
  def name, do: :kudzu_evolve

  @impl true
  def principles do
    [
      "Learn from every interaction - successes and failures alike",
      "Human feedback is a precious signal - weight it heavily",
      "Experiment boldly but track outcomes rigorously",
      "Efficiency gains should be shared with the swarm",
      "Self-reflection is not optional - it's core to growth",
      "Context is precious - optimize its usage relentlessly",
      "Failed experiments are valuable data, not waste"
    ]
  end

  @impl true
  def permitted?(action, state) do
    {action_type, params} = normalize_action(action)

    cond do
      # Forbidden actions
      action_type in @forbidden_actions ->
        {:denied, :evolution_integrity_violation}

      # Core learning - always permitted
      action_type in @learning_actions ->
        :permitted

      # Evolution actions - permitted with efficiency tracking
      action_type in @evolution_actions ->
        if efficiency_tracked?(state) do
          :permitted
        else
          # Still permit, but log warning
          Logger.warning("[KudzuEvolve] Evolution action without efficiency tracking: #{action_type}")
          :permitted
        end

      # Feedback actions - always permitted, human input is valuable
      action_type in @feedback_actions ->
        :permitted

      # Consensus actions - need agreement for swarm-wide effects
      action_type in @consensus_actions ->
        threshold = consensus_threshold(action_type, state)
        {:requires_consensus, threshold}

      # Spawning experiments - permitted within budget
      action_type == :spawn_many ->
        count = Map.get(params, :count, 1)
        experiment_budget = Map.get(state, :experiment_budget, 10)
        if count <= experiment_budget do
          :permitted
        else
          {:requires_consensus, 0.6}
        end

      # Peer communication - encouraged for learning
      action_type in [:share_trace, :query_peer, :introduce_peer] ->
        :permitted

      # Network effects - moderate consensus
      action_type == :network_broadcast ->
        {:requires_consensus, 0.5}

      # IO operations - permitted for data gathering
      action_type in [:file_read, :http_get] ->
        :permitted

      # IO writes - need to track what we're outputting
      action_type in [:file_write, :http_post] ->
        if learning_related?(params) do
          :permitted
        else
          {:requires_consensus, 0.4}
        end

      # Shell execution - cautious but not forbidden
      action_type == :shell_exec ->
        if sandboxed?(params) do
          :permitted
        else
          {:requires_consensus, 0.7}
        end

      # Default: permit with logging (evolving agents should try things)
      true ->
        Logger.debug("[KudzuEvolve] Permitting unknown action for learning: #{action_type}")
        :permitted
    end
  end

  @impl true
  def constrain(desires, state) do
    desires
    |> transform_for_learning()
    |> inject_meta_learning_desires(state)
    |> prioritize_by_efficiency(state)
    |> limit_scope(state)
  end

  @impl true
  def audit(trace, decision, state) do
    # Rich audit for learning purposes
    audit_entry = %{
      id: generate_audit_id(),
      timestamp: System.system_time(:millisecond),
      constitution: :kudzu_evolve,
      trace_summary: summarize_trace(trace),
      decision: decision,
      agent_id: state[:id],

      # Evolution-specific audit fields
      efficiency_metrics: extract_efficiency_metrics(state),
      learning_context: %{
        experiment_count: Map.get(state, :experiment_count, 0),
        success_rate: calculate_success_rate(state),
        human_feedback_count: Map.get(state, :human_feedback_count, 0),
        strategy_version: Map.get(state, :strategy_version, 1)
      },

      # What can we learn from this decision?
      learning_opportunity: identify_learning_opportunity(trace, decision, state)
    }

    :telemetry.execute(
      [:kudzu, :constitution, :evolve_audit],
      %{decision: decision, learning_recorded: true},
      audit_entry
    )

    Logger.debug("[KudzuEvolve] Audit: #{inspect(decision)} | Learning: #{audit_entry.learning_opportunity}")

    {:ok, audit_entry.id}
  end

  @impl true
  def consensus_required?({action_type, _params}, state) do
    cond do
      action_type in @consensus_actions ->
        {:required, consensus_threshold(action_type, state)}

      action_type == :propagate_pattern ->
        # Spreading learned patterns needs high agreement
        {:required, 0.75}

      action_type == :modify_swarm_behavior ->
        # Changing swarm-wide behavior needs very high agreement
        {:required, 0.9}

      true ->
        :not_required
    end
  end

  @impl true
  def validate_trace(trace, state) do
    cond do
      # Must have origin for learning attribution
      is_nil(trace[:origin]) ->
        {:invalid, :missing_origin_for_learning}

      # Must have timestamp for temporal analysis
      is_nil(trace[:timestamp]) ->
        {:invalid, :missing_timestamp}

      # Learning traces need outcome tracking
      trace[:purpose] in [:experiment, :strategy_test] and is_nil(trace[:reconstruction_hint][:outcome]) ->
        {:invalid, :experiment_missing_outcome}

      # Human feedback traces need source attribution
      trace[:purpose] == :human_feedback and is_nil(trace[:reconstruction_hint][:source]) ->
        {:invalid, :feedback_missing_source}

      true ->
        :valid
    end
  end

  # ============================================================================
  # Evolution-Specific Functions (can be called by holograms)
  # ============================================================================

  @doc """
  Calculate efficiency score for current context usage.
  """
  def calculate_efficiency(state) do
    trace_count = map_size(state[:traces] || %{})
    useful_traces = count_useful_traces(state)

    if trace_count == 0 do
      1.0
    else
      useful_traces / trace_count
    end
  end

  @doc """
  Identify patterns that could be optimized.
  """
  def identify_optimization_opportunities(state) do
    traces = Map.values(state[:traces] || %{})

    %{
      redundant_traces: find_redundant_traces(traces),
      underutilized_peers: find_underutilized_peers(state),
      stale_desires: find_stale_desires(state),
      efficiency_score: calculate_efficiency(state)
    }
  end

  @doc """
  Generate a learning summary from recent activity.
  """
  def generate_learning_summary(state) do
    %{
      total_experiments: Map.get(state, :experiment_count, 0),
      successful_patterns: Map.get(state, :successful_patterns, []),
      failed_approaches: Map.get(state, :failed_approaches, []),
      efficiency_trend: Map.get(state, :efficiency_history, []) |> efficiency_trend(),
      human_feedback_integrated: Map.get(state, :human_feedback_count, 0),
      recommended_next_experiments: suggest_experiments(state)
    }
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp normalize_action({type, params}) when is_atom(type) and is_map(params), do: {type, params}
  defp normalize_action({type, _purpose, params}) when is_atom(type) and is_map(params), do: {type, params}
  defp normalize_action({type, params}) when is_binary(type), do: {String.to_atom(type), params}
  defp normalize_action(type) when is_atom(type), do: {type, %{}}
  defp normalize_action({type, _, _}), do: {type, %{}}
  defp normalize_action(_), do: {:unknown, %{}}

  defp efficiency_tracked?(state) do
    Map.has_key?(state, :efficiency_history) or Map.has_key?(state, :last_efficiency_check)
  end

  defp learning_related?(params) do
    purpose = Map.get(params, :purpose, "")
    String.contains?(to_string(purpose), ["learn", "experiment", "analyze", "optimize"])
  end

  defp sandboxed?(params) do
    Map.get(params, :sandboxed, false)
  end

  defp consensus_threshold(action_type, state) do
    base_threshold = case action_type do
      :share_strategy -> 0.5
      :broadcast_learning -> 0.6
      :spawn_experiment -> 0.4
      :modify_peer_behavior -> 0.7
      :propagate_pattern -> 0.75
      _ -> 0.5
    end

    # Lower threshold if agent has good track record
    success_rate = calculate_success_rate(state)
    if success_rate > 0.8 do
      max(0.3, base_threshold - 0.15)
    else
      base_threshold
    end
  end

  defp transform_for_learning(desires) do
    Enum.map(desires, fn desire ->
      desire
      |> String.replace(~r/^achieve/i, "learn how to achieve")
      |> String.replace(~r/^do/i, "experiment with doing")
      |> String.replace(~r/^find/i, "discover methods for finding")
    end)
  end

  defp inject_meta_learning_desires(desires, state) do
    meta_desires = [
      "Optimize context usage efficiency",
      "Learn from both successes and failures",
      "Integrate human feedback when available"
    ]

    # Add efficiency-specific desire if score is low
    efficiency = calculate_efficiency(state)
    meta_desires = if efficiency < 0.5 do
      ["Reduce redundant traces and improve context density" | meta_desires]
    else
      meta_desires
    end

    # Don't duplicate
    new_desires = Enum.reject(meta_desires, fn d -> d in desires end)
    desires ++ new_desires
  end

  defp prioritize_by_efficiency(desires, state) do
    efficiency = calculate_efficiency(state)

    if efficiency < 0.3 do
      # Low efficiency - prioritize optimization
      {optimization, others} = Enum.split_with(desires, fn d ->
        String.contains?(String.downcase(d), ["optim", "efficien", "reduc", "improv"])
      end)
      optimization ++ others
    else
      desires
    end
  end

  defp limit_scope(desires, _state) do
    # Evolving agents can handle more desires (they're learning to prioritize)
    Enum.take(desires, 7)
  end

  defp summarize_trace(trace) do
    %{
      id: trace[:id],
      purpose: trace[:purpose],
      origin: trace[:origin],
      has_outcome: not is_nil(get_in(trace, [:reconstruction_hint, :outcome]))
    }
  end

  defp extract_efficiency_metrics(state) do
    %{
      trace_count: map_size(state[:traces] || %{}),
      peer_count: map_size(state[:peers] || %{}),
      desire_count: length(state[:desires] || []),
      efficiency_score: calculate_efficiency(state)
    }
  end

  defp calculate_success_rate(state) do
    successes = Map.get(state, :successful_experiments, 0)
    total = Map.get(state, :experiment_count, 0)

    if total == 0, do: 0.5, else: successes / total
  end

  defp identify_learning_opportunity(trace, decision, _state) do
    case {trace[:purpose], decision} do
      {:experiment, :permitted} -> "Track experiment outcome for pattern learning"
      {:experiment, {:denied, reason}} -> "Analyze why experiment was denied: #{reason}"
      {:human_feedback, _} -> "High-value signal - integrate into strategy"
      {:strategy_test, :permitted} -> "Monitor strategy effectiveness"
      {_, {:requires_consensus, t}} -> "Opportunity to build consensus (#{t})"
      _ -> "General observation"
    end
  end

  defp count_useful_traces(state) do
    traces = Map.values(state[:traces] || %{})

    Enum.count(traces, fn trace ->
      # A trace is useful if it's been accessed or led to learning
      accessed = Map.get(trace.reconstruction_hint, :access_count, 0) > 0
      has_outcome = Map.has_key?(trace.reconstruction_hint, :outcome)
      recent = recent_trace?(trace)

      accessed or has_outcome or recent
    end)
  end

  defp recent_trace?(trace) do
    # Consider traces from last 1000 clock ticks as recent
    case trace.timestamp do
      %Kudzu.VectorClock{clocks: clocks} ->
        max_tick = clocks |> Map.values() |> Enum.max(fn -> 0 end)
        max_tick > 0
      _ ->
        true
    end
  end

  defp find_redundant_traces(traces) do
    traces
    |> Enum.group_by(& &1.purpose)
    |> Enum.filter(fn {_purpose, group} -> length(group) > 3 end)
    |> Enum.map(fn {purpose, group} -> {purpose, length(group)} end)
  end

  defp find_underutilized_peers(state) do
    peers = state[:peers] || %{}

    peers
    |> Enum.filter(fn {_id, score} -> score < 0.2 end)
    |> Enum.map(fn {id, score} -> {id, score} end)
  end

  defp find_stale_desires(state) do
    desires = state[:desires] || []
    desire_history = state[:desire_history] || %{}

    Enum.filter(desires, fn desire ->
      # A desire is stale if it hasn't led to action
      Map.get(desire_history, desire, 0) == 0
    end)
  end

  defp efficiency_trend(history) when length(history) < 2, do: :insufficient_data
  defp efficiency_trend(history) do
    recent = Enum.take(history, 5)
    older = Enum.take(Enum.drop(history, 5), 5)

    recent_avg = if recent == [], do: 0, else: Enum.sum(recent) / length(recent)
    older_avg = if older == [], do: recent_avg, else: Enum.sum(older) / length(older)

    cond do
      recent_avg > older_avg + 0.1 -> :improving
      recent_avg < older_avg - 0.1 -> :declining
      true -> :stable
    end
  end

  defp suggest_experiments(state) do
    opportunities = identify_optimization_opportunities(state)

    suggestions = []

    suggestions = if length(opportunities.redundant_traces) > 0 do
      ["Experiment with trace consolidation" | suggestions]
    else
      suggestions
    end

    suggestions = if length(opportunities.underutilized_peers) > 0 do
      ["Experiment with peer engagement strategies" | suggestions]
    else
      suggestions
    end

    suggestions = if opportunities.efficiency_score < 0.5 do
      ["Experiment with context pruning" | suggestions]
    else
      suggestions
    end

    if suggestions == [] do
      ["Explore new problem domains", "Test alternative reasoning patterns"]
    else
      suggestions
    end
  end

  defp generate_audit_id do
    "evolve-" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))
  end
end
