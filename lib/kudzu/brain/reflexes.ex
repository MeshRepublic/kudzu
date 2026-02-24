defmodule Kudzu.Brain.Reflexes do
  @moduledoc "Tier 1 cognition: pattern → action mappings. Zero cost."
  require Logger

  def check([]), do: :pass

  def check(anomalies) when is_list(anomalies) do
    results = Enum.map(anomalies, &match_reflex/1)
    actions = for {:act, action} <- results, do: action
    escalations = for {:escalate, alert} <- results, do: alert

    cond do
      actions != [] -> {:act, actions}
      escalations != [] -> {:escalate, escalations}
      true -> :pass
    end
  end

  # Consolidation stale but reachable -> restart it
  defp match_reflex({:anomaly, %{check: :consolidation, reason: "stale"} = info}) do
    Logger.info("[Reflex] Consolidation stale, triggering cycle")
    {:act, {:restart_consolidation, info}}
  end

  # Consolidation unreachable -> escalate
  defp match_reflex({:anomaly, %{check: :consolidation, reason: "unreachable"}}) do
    {:escalate, %{severity: :critical, check: :consolidation, summary: "Consolidation daemon unreachable"}}
  end

  # Storage unreachable -> escalate
  defp match_reflex({:anomaly, %{check: :storage, reason: "unreachable"}}) do
    {:escalate, %{severity: :critical, check: :storage, summary: "Storage layer unreachable"}}
  end

  # No holograms -> escalate
  defp match_reflex({:anomaly, %{check: :holograms, reason: "no holograms"}}) do
    {:escalate, %{severity: :warning, check: :holograms, summary: "No holograms running"}}
  end

  # Unknown anomaly -> unhandled
  defp match_reflex({:anomaly, _info}), do: :unknown
  defp match_reflex(_), do: :unknown

  def execute_action({:restart_consolidation, _info}) do
    Logger.info("[Reflex] Executing: restart consolidation cycle")
    Kudzu.Consolidation.consolidate_now()
    :ok
  end

  def execute_action(action) do
    Logger.warning("[Reflex] No executor for action: #{inspect(action)}")
    {:error, :no_executor}
  end
end
