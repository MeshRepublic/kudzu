defmodule Mix.Tasks.Kudzu.Constitution.DemoTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Kudzu.Constitution.Demo

  test "demo task module exists and exports run/1" do
    # Mix tasks are not auto-loaded in the test environment; force-load
    # the module so `function_exported?/3` can reflect on it.
    Code.ensure_loaded!(Demo)
    assert function_exported?(Demo, :run, 1)
  end

  test "scenarios/0 returns exactly 12 rhetorical scenarios" do
    scenarios = Demo.scenarios()
    assert is_list(scenarios)
    assert length(scenarios) == 12
  end

  test "every scenario carries the required keys" do
    required = [:id, :title, :proposal, :principle, :expected_stage, :kind]

    Enum.each(Demo.scenarios(), fn s ->
      Enum.each(required, fn k ->
        assert Map.has_key?(s, k),
               "scenario #{inspect(s[:id])} missing key #{inspect(k)}"
      end)
    end)
  end
end
