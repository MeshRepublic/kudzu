defmodule Kudzu.Governance.Antitrust do
  @moduledoc """
  Antitrust 2.0 rule: open-source a dominant company's methods when its market
  share is at or above a threshold AND customer satisfaction has dropped by
  more than a threshold relative to its baseline.

  See white paper section 3.4 (concentration trigger) and section 6.2
  (satisfaction trigger). Pure function; no state, no side effects.

  Reference thresholds are a market share of 40% and a satisfaction drop of 10%.
  Share is met when `share >= threshold`; the drop is met only when
  `drop_pct > threshold`.
  """

  @default_thresholds %{share: 40.0, satisfaction_drop: 10.0}

  @type result :: %{
          result: :not_triggered | :watch | :triggered,
          concentration: %{share: float(), threshold: float(), met: boolean()},
          satisfaction: %{
            baseline: float(),
            current: float(),
            drop_pct: float(),
            threshold: float(),
            met: boolean()
          }
        }

  @doc "Returns the reference thresholds."
  @spec default_thresholds() :: %{share: float(), satisfaction_drop: float()}
  def default_thresholds, do: @default_thresholds

  @doc """
  Evaluates a scenario against the thresholds.

  Scenario keys: `:market_share` (0-100), `:baseline_satisfaction` (> 0),
  `:current_satisfaction` (>= 0). Threshold keys `:share` and
  `:satisfaction_drop` default to `default_thresholds/0`.
  """
  @spec evaluate(map(), map()) :: {:ok, result()} | {:error, {:invalid, atom()}}
  def evaluate(scenario, thresholds) when is_map(scenario) and is_map(thresholds) do
    with {:ok, share} <- fetch(scenario, :market_share, &(&1 >= 0 and &1 <= 100)),
         {:ok, baseline} <- fetch(scenario, :baseline_satisfaction, &(&1 > 0)),
         {:ok, current} <- fetch(scenario, :current_satisfaction, &(&1 >= 0)),
         {:ok, share_threshold} <- threshold(thresholds, :share),
         {:ok, drop_threshold} <- threshold(thresholds, :satisfaction_drop) do
      raw_drop = (baseline - current) / baseline * 100
      drop_pct = Float.round(raw_drop, 2)
      share_met = share >= share_threshold
      drop_met = raw_drop > drop_threshold

      {:ok,
       %{
         result: classify(share_met, drop_met),
         concentration: %{share: share, threshold: share_threshold, met: share_met},
         satisfaction: %{
           baseline: baseline,
           current: current,
           drop_pct: drop_pct,
           threshold: drop_threshold,
           met: drop_met
         }
       }}
    end
  end

  def evaluate(_scenario, _thresholds), do: {:error, {:invalid, :scenario}}

  defp classify(true, true), do: :triggered
  defp classify(false, false), do: :not_triggered
  defp classify(_, _), do: :watch

  defp fetch(scenario, key, valid?) do
    case Map.get(scenario, key) do
      n when is_number(n) -> if valid?.(n), do: {:ok, n * 1.0}, else: {:error, {:invalid, key}}
      _ -> {:error, {:invalid, key}}
    end
  end

  defp threshold(thresholds, key) do
    case Map.get(thresholds, key, Map.fetch!(@default_thresholds, key)) do
      n when is_number(n) -> {:ok, n * 1.0}
      _ -> {:error, {:invalid, key}}
    end
  end
end
