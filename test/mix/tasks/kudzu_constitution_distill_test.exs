defmodule Mix.Tasks.Kudzu.Constitution.DistillTest do
  use ExUnit.Case, async: false

  test "distill task module exists and exports run/1" do
    # Mix tasks are not auto-loaded in the test environment; force-load
    # the module so `function_exported?/3` can reflect on it.
    Code.ensure_loaded!(Mix.Tasks.Kudzu.Constitution.Distill)
    assert function_exported?(Mix.Tasks.Kudzu.Constitution.Distill, :run, 1)
  end

  # Adapted from plan: the original test asserted `assert_raise SystemExit`,
  # but Elixir has no built-in `SystemExit` exception and `System.halt/1`
  # terminates the BEAM rather than raising a catchable exception. Per the
  # Task 19 adaptation note, --help now exits via `Mix.raise/1`, which raises
  # the catchable `Mix.Error` and emits usage on the same path.
  test "--help flag aborts with usage info via Mix.raise" do
    assert_raise Mix.Error, fn ->
      Mix.Tasks.Kudzu.Constitution.Distill.run(["--help"])
    end
  end

  test "parse_args/1 honors --budget-cap-usd and --per-source" do
    {opts, _} =
      Mix.Tasks.Kudzu.Constitution.Distill.parse_args([
        "--budget-cap-usd",
        "100",
        "--per-source",
        "5"
      ])

    assert opts[:budget_cap_usd] == 100.0
    assert opts[:per_source] == 5
  end
end
