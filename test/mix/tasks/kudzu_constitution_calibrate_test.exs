defmodule Mix.Tasks.Kudzu.Constitution.CalibrateTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Kudzu.Constitution.Calibrate

  test "calibrate task module exists and exports run/1" do
    # Mix tasks are not auto-loaded in the test environment; force-load
    # the module so `function_exported?/3` can reflect on it.
    Code.ensure_loaded!(Calibrate)
    assert function_exported?(Calibrate, :run, 1)
  end

  # Per Task 19 / Task 21 adaptation note: `--help` raises Mix.Error
  # rather than calling System.halt/1. Tests assert on Mix.Error.
  test "--help flag aborts with usage info via Mix.raise" do
    assert_raise Mix.Error, fn ->
      Calibrate.run(["--help"])
    end
  end

  describe "brier_score/2" do
    test "returns 0.0 when forecast assigns probability 1.0 to the actual outcome" do
      # Perfectly confident, perfectly correct: Brier = 0
      forecasts = [
        {%{advances: 1.0, retards: 0.0, ambiguous: 0.0}, :advances}
      ]

      assert Calibrate.brier_score(forecasts, [:advances, :retards, :ambiguous]) == 0.0
    end

    test "returns mean squared error across classes for a confident wrong forecast" do
      # Predicted advances=1.0, actual was retards.
      # Per-row squared error = (1-0)^2 + (0-1)^2 + (0-0)^2 = 2.0
      # Mean across 1 row = 2.0
      forecasts = [
        {%{advances: 1.0, retards: 0.0, ambiguous: 0.0}, :retards}
      ]

      assert Calibrate.brier_score(forecasts, [:advances, :retards, :ambiguous]) == 2.0
    end
  end

  describe "confusion_matrix/1" do
    test "builds a nested counter map keyed by expected then predicted class" do
      rows = [
        %{expected: :advances, predicted: :advances},
        %{expected: :advances, predicted: :retards},
        %{expected: :retards, predicted: :retards},
        %{expected: :retards, predicted: :retards}
      ]

      cm = Calibrate.confusion_matrix(rows)
      assert get_in(cm, [:advances, :advances]) == 1
      assert get_in(cm, [:advances, :retards]) == 1
      assert get_in(cm, [:retards, :retards]) == 2
    end
  end
end
