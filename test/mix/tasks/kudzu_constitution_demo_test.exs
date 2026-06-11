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
    for s <- Demo.scenarios() do
      assert Map.has_key?(s, :id)
      assert Map.has_key?(s, :title)
      assert Map.has_key?(s, :proposal_text)
      assert Map.has_key?(s, :expected_stage)
      assert Map.has_key?(s, :expected_principle)
    end
  end
end
