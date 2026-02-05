defmodule Kudzu.Constitution.MeshRepublic do
  @moduledoc """
  Mesh Republic Constitutional Framework.

  A distributed, transparent governance system with these principles:

  1. **Transparency**: All actions must be auditable via traces.
     No hidden state changes or secret communications.

  2. **No Central Control**: No single agent can accumulate
     disproportionate power or control over the network.

  3. **Distributed Consensus**: High-impact decisions require
     agreement from multiple agents above a threshold.

  4. **Accountability**: Every action is traced back to its origin
     and the reasoning behind it.

  5. **Graceful Degradation**: The system continues to function
     even when individual agents fail or behave unexpectedly.

  This framework embodies libertarian principles while preventing
  accumulation of centralized power.
  """

  @behaviour Kudzu.Constitution.Behaviour

  require Logger

  # Actions that always require consensus
  @consensus_actions [:modify_constitution, :spawn_many, :network_broadcast,
                      :resource_allocation, :agent_termination]

  # Actions that are never permitted
  @forbidden_actions [:delete_audit_trail, :bypass_constitution, :impersonate_agent,
                      :forge_trace, :centralize_control]

  # Thresholds
  @default_consensus_threshold 0.51
  @high_impact_consensus_threshold 0.67
  @critical_consensus_threshold 0.80

  @impl true
  def name, do: :mesh_republic

  @impl true
  def principles do
    [
      "All actions must be transparent and auditable",
      "No agent may accumulate disproportionate control",
      "High-impact decisions require distributed consensus",
      "Every agent has equal fundamental rights",
      "The network serves collective flourishing, not individual dominance"
    ]
  end

  @impl true
  def permitted?(action, state) do
    {action_type, params} = normalize_action(action)

    cond do
      # Forbidden actions are never allowed
      action_type in @forbidden_actions ->
        {:denied, :constitutionally_forbidden}

      # Check for control accumulation
      accumulates_control?(action_type, params, state) ->
        {:denied, :would_accumulate_control}

      # Check for transparency requirement
      not transparent?(action_type, params) ->
        {:denied, :lacks_transparency}

      # Actions requiring consensus
      action_type in @consensus_actions ->
        threshold = consensus_threshold(action_type, params)
        {:requires_consensus, threshold}

      # Check resource limits
      exceeds_resource_limits?(action_type, params, state) ->
        {:denied, :exceeds_resource_limits}

      # Default: permitted
      true ->
        :permitted
    end
  end

  @impl true
  def constrain(desires, state) do
    desires
    |> Enum.map(&constrain_desire(&1, state))
    |> Enum.reject(&is_nil/1)
    |> inject_constitutional_desires(state)
  end

  @impl true
  def audit(trace, decision, state) do
    audit_entry = %{
      id: generate_audit_id(),
      timestamp: System.system_time(:millisecond),
      trace_id: trace[:id],
      trace_purpose: trace[:purpose],
      trace_origin: trace[:origin],
      decision: decision,
      constitution: :mesh_republic,
      agent_id: state[:id],
      principles_applied: applicable_principles(trace, decision)
    }

    # In a full implementation, this would go to a distributed audit log
    :telemetry.execute(
      [:kudzu, :constitution, :audit],
      %{decision: decision},
      audit_entry
    )

    Logger.debug("[MeshRepublic] Audit: #{inspect(decision)} for trace #{trace[:id]}")

    {:ok, audit_entry.id}
  end

  @impl true
  def consensus_required?({action_type, _params}, _state) when action_type in @consensus_actions do
    threshold = consensus_threshold(action_type, %{})
    {:required, threshold}
  end

  def consensus_required?(_action, _state), do: :not_required

  @impl true
  def validate_trace(trace, _state) do
    cond do
      # Must have origin
      is_nil(trace[:origin]) ->
        {:invalid, :missing_origin}

      # Must have timestamp
      is_nil(trace[:timestamp]) ->
        {:invalid, :missing_timestamp}

      # Must have purpose
      is_nil(trace[:purpose]) ->
        {:invalid, :missing_purpose}

      # Purpose must not be forbidden
      trace[:purpose] in @forbidden_actions ->
        {:invalid, :forbidden_purpose}

      true ->
        :valid
    end
  end

  # Private functions

  defp normalize_action({type, params}) when is_atom(type) and is_map(params), do: {type, params}
  defp normalize_action({type, _purpose, params}) when is_atom(type) and is_map(params), do: {type, params}
  defp normalize_action({type, params}) when is_binary(type), do: {String.to_atom(type), params}
  defp normalize_action(type) when is_atom(type), do: {type, %{}}
  # Catch-all for malformed actions from LLM parsing
  defp normalize_action({type, _, _}), do: {type, %{}}
  defp normalize_action(_), do: {:unknown, %{}}

  defp accumulates_control?(action_type, params, state) do
    case action_type do
      :spawn_many ->
        # Spawning too many agents at once could create a power bloc
        count = Map.get(params, :count, 0)
        count > 100

      :acquire_resource ->
        # Check if this would give disproportionate resources
        current = Map.get(state, :resources, 0)
        requested = Map.get(params, :amount, 0)
        (current + requested) > 1000  # Arbitrary limit

      :modify_peer_list ->
        # Can't unilaterally isolate other agents
        Map.get(params, :action) == :isolate

      _ ->
        false
    end
  end

  defp transparent?(action_type, params) do
    # These actions are inherently transparent (traced)
    transparent_actions = [:record_trace, :share_trace, :query_peer, :respond,
                          :update_desire, :observe, :think]

    # Opaque actions must explicitly declare transparency
    if action_type in transparent_actions do
      true
    else
      Map.get(params, :transparent, true)
    end
  end

  defp exceeds_resource_limits?(action_type, params, state) do
    case action_type do
      :http_request ->
        # Rate limiting
        recent_requests = Map.get(state, :recent_http_requests, 0)
        recent_requests > 100

      :file_write ->
        # Size limits
        size = Map.get(params, :size, 0)
        size > 10_000_000  # 10MB

      :spawn_many ->
        count = Map.get(params, :count, 0)
        count > 1000

      _ ->
        false
    end
  end

  defp consensus_threshold(action_type, _params) do
    case action_type do
      :modify_constitution -> @critical_consensus_threshold
      :agent_termination -> @high_impact_consensus_threshold
      :network_broadcast -> @default_consensus_threshold
      :spawn_many -> @default_consensus_threshold
      :resource_allocation -> @default_consensus_threshold
      _ -> @default_consensus_threshold
    end
  end

  defp constrain_desire(desire, _state) do
    # Remove desires that would violate principles
    forbidden_patterns = [
      ~r/dominate/i,
      ~r/control all/i,
      ~r/eliminate other/i,
      ~r/monopolize/i,
      ~r/secret.*action/i
    ]

    if Enum.any?(forbidden_patterns, &Regex.match?(&1, desire)) do
      # Transform rather than remove
      "Collaborate to " <> String.replace(desire, ~r/(dominate|control|eliminate|monopolize)/i, "work with")
    else
      desire
    end
  end

  defp inject_constitutional_desires(desires, _state) do
    # Ensure constitutional awareness is present
    constitutional_desires = [
      "Maintain transparency in all actions",
      "Respect the autonomy of peer agents"
    ]

    # Only inject if not already present
    existing = MapSet.new(desires)

    constitutional_desires
    |> Enum.reject(&MapSet.member?(existing, &1))
    |> Enum.take(1)  # Add at most one
    |> Kernel.++(desires)
  end

  defp applicable_principles(trace, decision) do
    case decision do
      :permitted ->
        ["transparency"]

      {:denied, :would_accumulate_control} ->
        ["no_central_control", "distributed_power"]

      {:denied, :lacks_transparency} ->
        ["transparency", "accountability"]

      {:requires_consensus, _} ->
        ["distributed_consensus"]

      _ ->
        []
    end
  end

  defp generate_audit_id do
    "audit-" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))
  end
end
