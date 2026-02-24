defmodule Kudzu.Brain.Budget do
  @moduledoc """
  Tracks Claude API token spend and enforces monthly budget limits.
  """

  # Claude Sonnet pricing (as of 2025)
  @input_cost_per_mtok 3.0
  @output_cost_per_mtok 15.0

  defstruct [
    month: nil,
    input_tokens: 0,
    output_tokens: 0,
    api_calls: 0,
    estimated_cost_usd: 0.0
  ]

  def new do
    %__MODULE__{month: current_month()}
  end

  def record_usage(%__MODULE__{} = budget, usage) do
    input = usage[:input_tokens] || usage["input_tokens"] || 0
    output = usage[:output_tokens] || usage["output_tokens"] || 0

    budget = maybe_reset_month(budget)

    cost = (input / 1_000_000 * @input_cost_per_mtok) +
           (output / 1_000_000 * @output_cost_per_mtok)

    %{budget |
      input_tokens: budget.input_tokens + input,
      output_tokens: budget.output_tokens + output,
      api_calls: budget.api_calls + 1,
      estimated_cost_usd: Float.round(budget.estimated_cost_usd + cost, 4)
    }
  end

  def within_budget?(%__MODULE__{} = budget, limit) do
    budget.estimated_cost_usd < limit
  end

  def summary(%__MODULE__{} = budget) do
    %{
      month: budget.month,
      input_tokens: budget.input_tokens,
      output_tokens: budget.output_tokens,
      api_calls: budget.api_calls,
      estimated_cost_usd: budget.estimated_cost_usd
    }
  end

  defp current_month do
    Date.utc_today() |> Date.to_string() |> String.slice(0, 7)
  end

  defp maybe_reset_month(%__MODULE__{month: month} = budget) do
    current = current_month()
    if month != current do
      %__MODULE__{month: current}
    else
      budget
    end
  end
end
