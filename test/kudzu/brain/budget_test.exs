defmodule Kudzu.Brain.BudgetTest do
  use ExUnit.Case, async: true

  alias Kudzu.Brain.Budget

  test "new budget starts at zero" do
    budget = Budget.new()
    assert budget.estimated_cost_usd == 0.0
    assert budget.api_calls == 0
    assert budget.month != nil
  end

  test "record_usage accumulates tokens and cost" do
    budget = Budget.new()
    budget = Budget.record_usage(budget, %{input_tokens: 1_000_000, output_tokens: 100_000})

    assert budget.input_tokens == 1_000_000
    assert budget.output_tokens == 100_000
    assert budget.api_calls == 1
    # 1M input * $3/M + 0.1M output * $15/M = $3 + $1.5 = $4.5
    assert budget.estimated_cost_usd == 4.5
  end

  test "within_budget? checks limit" do
    budget = Budget.new()
    assert Budget.within_budget?(budget, 100.0)

    budget = Budget.record_usage(budget, %{input_tokens: 30_000_000, output_tokens: 2_000_000})
    # 30M * $3 + 2M * $15 = $90 + $30 = $120
    refute Budget.within_budget?(budget, 100.0)
  end

  test "summary returns plain map" do
    budget = Budget.new()
    summary = Budget.summary(budget)
    assert is_map(summary)
    assert Map.has_key?(summary, :month)
    assert Map.has_key?(summary, :estimated_cost_usd)
  end

  test "multiple usages accumulate" do
    budget = Budget.new()
    budget = Budget.record_usage(budget, %{input_tokens: 500_000, output_tokens: 50_000})
    budget = Budget.record_usage(budget, %{input_tokens: 500_000, output_tokens: 50_000})

    assert budget.api_calls == 2
    assert budget.input_tokens == 1_000_000
    assert budget.output_tokens == 100_000
  end
end
