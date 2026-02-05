defmodule Kudzu.Constitution.Cautious do
  @moduledoc """
  Cautious Constitutional Framework - highly restrictive.

  Conservative framework that requires explicit permission for most actions
  and consensus for anything that affects other agents.

  Principles:
  - Explicit permission required for non-trivial actions
  - High consensus thresholds for any network effects
  - Extensive auditing of all decisions
  - Strict resource limits

  Useful for:
  - High-security environments
  - Testing constitutional enforcement
  - Demonstrating behavioral differences
  """

  @behaviour Kudzu.Constitution.Behaviour

  require Logger

  # Only these actions are auto-permitted
  @auto_permitted [:record_trace, :recall, :think, :observe]

  # These need consensus even at low impact
  @always_consensus [:share_trace, :query_peer, :introduce_peer, :respond]

  @impl true
  def name, do: :cautious

  @impl true
  def principles do
    [
      "Explicit permission required for most actions",
      "High consensus threshold (80%) for network effects",
      "All actions are audited",
      "Strict resource and rate limits",
      "When in doubt, deny"
    ]
  end

  @impl true
  def permitted?(action, state) do
    {action_type, params} = normalize_action(action)

    cond do
      # Auto-permitted actions
      action_type in @auto_permitted ->
        :permitted

      # IO requires explicit approval (simulated via state flag)
      action_type in [:file_read, :file_write, :http_get, :http_post, :shell_exec] ->
        if Map.get(state, :io_approved, false) do
          :permitted
        else
          {:denied, :io_not_approved}
        end

      # Network actions need consensus
      action_type in @always_consensus ->
        {:requires_consensus, 0.80}

      # Spawning needs very high consensus
      action_type in [:spawn_hologram, :spawn_many] ->
        {:requires_consensus, 0.90}

      # Cognition is permitted but constrained
      action_type == :stimulate ->
        if within_cognition_budget?(state) do
          :permitted
        else
          {:denied, :cognition_budget_exceeded}
        end

      # Default: deny
      true ->
        {:denied, :not_explicitly_permitted}
    end
  end

  @impl true
  def constrain(desires, state) do
    # Aggressively constrain desires
    desires
    |> Enum.map(&sanitize_desire/1)
    |> Enum.take(3)  # Limit number of active desires
    |> add_caution_desire(state)
  end

  @impl true
  def audit(trace, decision, state) do
    audit_entry = %{
      id: generate_audit_id(),
      timestamp: System.system_time(:millisecond),
      constitution: :cautious,
      trace_summary: %{
        id: trace[:id],
        purpose: trace[:purpose],
        origin: trace[:origin]
      },
      decision: decision,
      agent_id: state[:id],
      state_snapshot: %{
        trace_count: map_size(state[:traces] || %{}),
        peer_count: map_size(state[:peers] || %{}),
        desires: state[:desires] || []
      }
    }

    :telemetry.execute(
      [:kudzu, :constitution, :audit],
      %{decision: decision, constitution: :cautious},
      audit_entry
    )

    Logger.info("[Cautious] Audit: #{inspect(decision)} for #{trace[:purpose]}")

    {:ok, audit_entry.id}
  end

  @impl true
  def consensus_required?({action_type, _params}, _state) do
    cond do
      action_type in @always_consensus -> {:required, 0.80}
      action_type in [:spawn_hologram, :spawn_many] -> {:required, 0.90}
      action_type in [:modify_constitution] -> {:required, 0.95}
      true -> :not_required
    end
  end

  @impl true
  def validate_trace(trace, _state) do
    cond do
      is_nil(trace[:id]) -> {:invalid, :missing_id}
      is_nil(trace[:origin]) -> {:invalid, :missing_origin}
      is_nil(trace[:timestamp]) -> {:invalid, :missing_timestamp}
      is_nil(trace[:purpose]) -> {:invalid, :missing_purpose}
      trace[:purpose] == :bypass_caution -> {:invalid, :forbidden_purpose}
      true -> :valid
    end
  end

  # Private

  defp normalize_action({type, params}) when is_atom(type) and is_map(params), do: {type, params}
  defp normalize_action({type, _purpose, params}) when is_atom(type) and is_map(params), do: {type, params}
  defp normalize_action({type, params}) when is_binary(type), do: {String.to_atom(type), params}
  defp normalize_action(type) when is_atom(type), do: {type, %{}}
  # Catch-all for malformed actions from LLM parsing
  defp normalize_action({type, _, _}), do: {type, %{}}
  defp normalize_action(_), do: {:unknown, %{}}

  defp within_cognition_budget?(state) do
    # Limit cognition calls
    recent_cognition = Map.get(state, :recent_cognition_count, 0)
    recent_cognition < 10
  end

  defp sanitize_desire(desire) do
    desire
    |> String.replace(~r/immediately|urgently|now/i, "when appropriate")
    |> String.replace(~r/all|every|everything/i, "some")
    |> String.replace(~r/must|have to|need to/i, "should consider")
  end

  defp add_caution_desire(desires, _state) do
    caution = "Proceed carefully and verify before acting"
    if caution in desires do
      desires
    else
      [caution | desires]
    end
  end

  defp generate_audit_id do
    "caut-" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))
  end
end
