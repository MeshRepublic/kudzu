defmodule Kudzu.Constitution.Filter.SovereigntyFilterTest do
  use ExUnit.Case, async: true

  alias Kudzu.Constitution.Filter.SovereigntyFilter

  describe "normalize_judgment/1 - validation" do
    test "rejects out-of-range advances score" do
      assert {:contested, :out_of_range} =
               SovereigntyFilter.normalize_judgment({:advances, 1.5, "free_speech"})
    end

    test "rejects out-of-range retards score" do
      assert {:contested, :out_of_range} =
               SovereigntyFilter.normalize_judgment({:retards, -0.1, "free_speech", "reason"})
    end

    test "rejects unknown principle for advances" do
      assert {:contested, :unknown_principle} =
               SovereigntyFilter.normalize_judgment({:advances, 0.8, "not_a_principle"})
    end

    test "rejects unknown principle for retards" do
      assert {:contested, :unknown_principle} =
               SovereigntyFilter.normalize_judgment({:retards, 0.8, "not_a_principle", "reason"})
    end

    test "accepts well-formed advances judgment" do
      assert {:advances, 0.85, "free_speech"} =
               SovereigntyFilter.normalize_judgment({:advances, 0.85, "free_speech"})
    end

    test "accepts well-formed retards judgment" do
      assert {:retards, 0.7, "due_process", "explicit"} =
               SovereigntyFilter.normalize_judgment({:retards, 0.7, "due_process", "explicit"})
    end
  end

  describe "self_consistency_decide/1" do
    test "returns :advances on 2-of-3 agreement" do
      samples = [
        {:advances, 0.8, "free_speech"},
        {:advances, 0.9, "free_speech"},
        {:retards, 0.4, "free_speech", "edge case"}
      ]

      assert {:advances, _, "free_speech"} = SovereigntyFilter.self_consistency_decide(samples)
    end

    test "returns :retards on 2-of-3 agreement" do
      samples = [
        {:retards, 0.7, "due_process", "r1"},
        {:retards, 0.6, "due_process", "r2"},
        {:advances, 0.3, "due_process"}
      ]

      assert {:retards, _, "due_process", _} = SovereigntyFilter.self_consistency_decide(samples)
    end

    test "returns {:contested, :three_way_split} on 3-way disagreement" do
      samples = [
        {:advances, 0.7, "free_speech"},
        {:retards, 0.5, "free_assembly", "different"},
        {:contested, :malformed_response}
      ]

      assert {:contested, :three_way_split} = SovereigntyFilter.self_consistency_decide(samples)
    end

    test "returns {:contested, :no_samples} on empty input" do
      assert {:contested, :no_samples} = SovereigntyFilter.self_consistency_decide([])
    end
  end

  describe "judge/2 — real Claude call" do
    @tag :external
    test "clear-advances triple gets {:advances, _, _} or {:contested, _}" do
      {:ok, result} =
        SovereigntyFilter.judge(
          {"individual", "has_right_to", "free_speech"},
          "From the First Amendment context. Congress shall make no law..."
        )

      assert match?({:advances, _, _}, result) or match?({:contested, _}, result)
    end
  end
end
