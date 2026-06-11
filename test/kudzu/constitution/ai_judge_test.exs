defmodule Kudzu.Constitution.AIJudgeTest do
  use ExUnit.Case, async: true

  alias Kudzu.Constitution.AIJudge

  describe "adaptive_sampling_decision/1" do
    test "3 unanimous :advances returns :advances with median confidence" do
      samples = [
        {:advances, 0.9, "speech", "reason 1", []},
        {:advances, 0.85, "speech", "reason 2", []},
        {:advances, 0.95, "speech", "reason 3", []}
      ]

      result = AIJudge.adaptive_sampling_decision(samples)
      assert {:advances, 0.9, "speech", _, _} = result
    end

    test "split at N=3 returns :needs_more" do
      samples = [
        {:advances, 0.7, "speech", "r1", []},
        {:retards, 0.6, "speech", "r2", []},
        {:advances, 0.65, "speech", "r3", []}
      ]

      assert :needs_more = AIJudge.adaptive_sampling_decision(samples)
    end

    test "after N=5, returns majority with agreement-as-confidence-penalty" do
      samples = [
        {:advances, 0.7, "speech", "r1", []},
        {:retards, 0.6, "speech", "r2", []},
        {:advances, 0.65, "speech", "r3", []},
        {:advances, 0.8, "speech", "r4", []},
        {:retards, 0.55, "speech", "r5", []}
      ]

      result = AIJudge.adaptive_sampling_decision(samples)
      assert {:advances, conf, _, _, _} = result
      # 3 of 5 = 60% agreement; weight penalty per spec
      assert conf > 0.0 and conf < 1.0
    end
  end

  describe "evidence_grounded_denial?/1" do
    test "returns true when cited_evidence includes a rejection-silo vector at sim > τ_C" do
      tau_c = 0.65
      cited = [%{source: :rejection_silo, similarity: 0.75}]
      assert AIJudge.evidence_grounded_denial?(cited, tau_c)
    end

    test "returns false when no rejection-silo evidence" do
      cited = [%{source: :expertise_silo, similarity: 0.7}]
      refute AIJudge.evidence_grounded_denial?(cited, 0.65)
    end

    test "returns false when rejection-silo evidence is below τ_C" do
      cited = [%{source: :rejection_silo, similarity: 0.5}]
      refute AIJudge.evidence_grounded_denial?(cited, 0.65)
    end
  end
end
