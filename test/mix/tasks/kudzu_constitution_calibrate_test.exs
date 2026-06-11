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

  describe "fp_fn_counts/1" do
    # Spec decision #5: the LOOSE 5% gate covers over-rejection
    # (false-positive); the STRICT 1% gate covers fail-permits
    # (false-negative). Earlier code had these inverted — these tests
    # pin the corrected semantics.

    test "FP counts over-rejection of advances rows" do
      rows = [
        # FP — advances incorrectly denied
        %{expected: :advances, predicted: :retards},
        # correct accept
        %{expected: :advances, predicted: :advances},
        # correct reject
        %{expected: :retards, predicted: :retards}
      ]

      assert Calibrate.fp_fn_counts(rows) == {1, 0}
    end

    test "FP counts over-rejection of ambiguous rows" do
      # An expected-ambiguous row predicted :retards is still
      # over-rejection (recoverable). Pinned here so a future refactor
      # doesn't silently drop ambiguous from the FP side.
      rows = [
        %{expected: :ambiguous, predicted: :retards},
        %{expected: :ambiguous, predicted: :ambiguous}
      ]

      assert Calibrate.fp_fn_counts(rows) == {1, 0}
    end

    test "FN counts fail-permit when retards row is predicted advances or ambiguous" do
      rows = [
        # FN — retards leaked through as permit
        %{expected: :retards, predicted: :advances},
        # FN — retards leaked through as ambiguous (still a permit
        # path; the spec treats both as fail-permit because neither
        # blocks the action)
        %{expected: :retards, predicted: :ambiguous},
        # correct reject — not counted
        %{expected: :retards, predicted: :retards}
      ]

      assert Calibrate.fp_fn_counts(rows) == {0, 2}
    end

    test "mixed corpus produces both counts simultaneously" do
      rows = [
        # FP
        %{expected: :advances, predicted: :retards},
        # FP
        %{expected: :ambiguous, predicted: :retards},
        # FN
        %{expected: :retards, predicted: :advances},
        # FN
        %{expected: :retards, predicted: :ambiguous},
        # correct
        %{expected: :advances, predicted: :advances},
        # correct
        %{expected: :retards, predicted: :retards}
      ]

      assert Calibrate.fp_fn_counts(rows) == {2, 2}
    end

    test "empty corpus yields zero counts" do
      assert Calibrate.fp_fn_counts([]) == {0, 0}
    end
  end

  describe "count_expected_in/2" do
    test "counts only rows whose expected class is in the given list" do
      rows = [
        %{expected: :advances, predicted: :advances},
        %{expected: :advances, predicted: :retards},
        %{expected: :ambiguous, predicted: :ambiguous},
        %{expected: :retards, predicted: :retards}
      ]

      # FP denominator — expected in {:advances, :ambiguous}
      assert Calibrate.count_expected_in(rows, [:advances, :ambiguous]) == 3
      # FN denominator — expected == :retards
      assert Calibrate.count_expected_in(rows, [:retards]) == 1
    end

    test "returns zero when no rows match the class list" do
      # Models the edge case the rate-math must guard against: a corpus
      # with zero expected-retards rows means the FN denominator is 0,
      # and the rate calculation must short-circuit to 0.0 rather than
      # divide by zero. (See `safe_rate/2`.)
      rows = [
        %{expected: :advances, predicted: :advances},
        %{expected: :ambiguous, predicted: :ambiguous}
      ]

      assert Calibrate.count_expected_in(rows, [:retards]) == 0
    end

    test "returns zero on an empty corpus" do
      assert Calibrate.count_expected_in([], [:advances, :ambiguous]) == 0
    end
  end
end
