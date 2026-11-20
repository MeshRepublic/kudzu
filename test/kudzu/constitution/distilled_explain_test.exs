defmodule Kudzu.Constitution.DistilledExplainTest do
  @moduledoc """
  `Distilled.explain/2` returns the same decision as `permitted?/2` plus a
  five-entry stage trace. Judges are always injected, so no paid API is
  called.
  """
  # async: false — WeightLedger.clear_for_test mutates a globally supervised
  # ETS table, and one test mutates ANTHROPIC_API_KEY.
  use ExUnit.Case, async: false

  # The fail-closed scenarios log a warning by design.
  @moduletag :capture_log

  alias Kudzu.Constitution.Distilled
  alias Kudzu.Constitution.Filter.SovereigntyFilter
  alias Kudzu.Constitution.Vectors
  alias Kudzu.Constitution.WeightLedger

  # An injected judge module other than AIJudge that only exports judge/1.
  defmodule JudgeOnlyStub do
    @moduledoc false
    def judge(_context), do: {:ok, {:advances, 0.95, "free_speech", "stub", []}}
  end

  @rejection_triple {"historical_act", "retards", "compelled speech criminalization"}
  @expertise_triple {"individual", "has_right_to", "free_speech"}

  setup do
    :ok = WeightLedger.clear_for_test()
    :ok
  end

  # ---------- helpers ----------

  # Fresh rejection + expertise silos seeded the way distilled_5stage_test
  # seeds them.
  defp seeded_config do
    salt = :rand.uniform(999_999)
    rejection = "rejection:explain_test_#{salt}"
    expertise = "expertise:explain_test_#{salt}"
    {:ok, _} = Kudzu.Silo.create(rejection, %{})
    {:ok, _} = Kudzu.Silo.create(expertise, %{})

    Kudzu.Silo.store_relationship(rejection, @rejection_triple, %{
      citation: "Sedition Act of 1798",
      principle: "free_speech",
      rejection_reason: "compelled speech criminalization"
    })

    Kudzu.Silo.store_relationship(expertise, @expertise_triple, %{
      citation: "Federalist 84",
      principle: "free_speech",
      sovereignty_score: 0.95
    })

    %{rejection_silo: rejection, expertise_silo: expertise, tau_a: 1.0, tau_c: 0.65}
  end

  # Empty silos: stages 1-3 find nothing, so the judge decides.
  defp empty_config do
    salt = :rand.uniform(999_999)
    rejection = "rejection:explain_empty_#{salt}"
    expertise = "expertise:explain_empty_#{salt}"
    {:ok, _} = Kudzu.Silo.create(rejection, %{})
    {:ok, _} = Kudzu.Silo.create(expertise, %{})
    %{rejection_silo: rejection, expertise_silo: expertise}
  end

  defp propose(vector, principle) do
    {:propose, %{vector: vector, principle: principle, proposal_text: "explain test proposal"}}
  end

  defp state_with_judge(judge), do: %{config: Map.put(empty_config(), :judge, judge)}

  defp state_with(config, judge), do: %{config: Map.put(config, :judge, judge)}

  defp advances(confidence) do
    fn _ -> {:ok, {:advances, confidence, "free_speech", "advances liberty", []}} end
  end

  defp never_called, do: fn _ -> raise "AI Judge must not be called" end

  defp vector, do: Vectors.encode_text("designate an official state bird")

  defp matching_vector, do: Vectors.encode_text("state criminalization of compelled speech")

  # {expected stage-5 outcome, action, state} for every decision kind.
  defp labelled_scenarios do
    grounded = [%{source: :rejection_silo, similarity: 0.9, ref: "Sedition Act of 1798"}]

    [
      {:permitted, propose(Vectors.encode_triple(@expertise_triple), "free_speech"),
       state_with(seeded_config(), never_called())},
      {:permitted, propose(vector(), "free_speech"), state_with(seeded_config(), advances(0.95))},
      {:denied, propose(matching_vector(), "free_speech"),
       state_with(seeded_config(), never_called())},
      {:denied_by_accumulation, propose(vector(), "federalism"),
       state_with(accumulation_config(), never_called())},
      {:denied, propose(vector(), "free_speech"),
       state_with(seeded_config(), fn _ ->
         {:ok, {:retards, 0.9, "free_speech", "prior restraint", grounded}}
       end)},
      {:permitted_with_weight, propose(vector(), "free_speech"),
       state_with(seeded_config(), fn _ ->
         {:ok, {:ambiguous, 0.4, "free_speech", "unclear", []}}
       end)},
      {:permitted_with_weight, propose(vector(), "free_speech"),
       state_with(seeded_config(), fn _ ->
         {:ok, {:retards, 0.9, "free_speech", "opinion only", []}}
       end)},
      {:cannot_evaluate, propose(vector(), "free_speech"),
       state_with(seeded_config(), fn _ -> {:error, :all_samples_failed} end)}
    ]
  end

  defp all_scenarios, do: Enum.map(labelled_scenarios(), fn {_, a, s} -> {a, s} end)

  # Ledger entries on "federalism" whose vectors are the rejection triple:
  # the proposal alone stays under τ_R at stage 1, but bundled with the
  # accumulated vector it crosses τ_R at stage 2, and 0.6 + 0.5 > τ_A.
  defp accumulation_config do
    acc_v = Vectors.encode_triple(@rejection_triple)
    :ok = WeightLedger.record("acc_a", acc_v, 0.6, "federalism", :yes_with_weight)
    :ok = WeightLedger.record("acc_b", acc_v, 0.5, "federalism", :yes_with_weight)
    seeded_config()
  end

  # ---------- tests ----------

  test "explain always returns five ordered stages with the fixed names" do
    %{stages: stages} =
      Distilled.explain(propose(vector(), "free_speech"), state_with_judge(advances(0.95)))

    assert Enum.map(stages, & &1.stage) == [1, 2, 3, 4, 5]

    assert Enum.map(stages, & &1.name) == [
             "direct rejection match",
             "accumulated weight",
             "expertise match",
             "AI judge",
             "decision"
           ]
  end

  test "decision equals permitted?/2 for every scenario" do
    for {action, state} <- all_scenarios() do
      assert Distilled.explain(action, state).decision == Distilled.permitted?(action, state)
    end
  end

  test "scenarios cover every decision kind with the expected stage-5 outcome" do
    for {expected, action, state} <- labelled_scenarios() do
      %{decision: decision, stages: stages} = Distilled.explain(action, state)
      assert List.last(stages).outcome == expected, inspect({expected, decision})
    end
  end

  test "judge is called exactly once per explain" do
    counter = :counters.new(1, [])

    judge = fn _ ->
      :counters.add(counter, 1, 1)
      {:ok, {:advances, 0.95, "free_speech", "ok", []}}
    end

    Distilled.explain(propose(vector(), "free_speech"), %{config: %{judge: judge}})
    assert :counters.get(counter, 1) == 1
  end

  test "stage 4 carries tally when the judge supplies samples" do
    s = [
      {:retards, 0.9, "free_speech", "r", []},
      {:retards, 0.92, "free_speech", "r", []},
      {:advances, 0.6, "free_speech", "a", []}
    ]

    judge = fn _ -> {:ok, hd(s), %{samples: s}} end

    %{decision: decision, stages: stages} =
      Distilled.explain(propose(vector(), "free_speech"), state_with_judge(judge))

    stage4 = Enum.at(stages, 3)
    assert stage4.outcome == :retards
    assert stage4.detail.tally == %{advances: 1, retards: 2, ambiguous: 0}
    assert stage4.detail.confidence == 0.9
    assert stage4.detail.error == nil
    # Ungrounded :retards is downgraded to a weighted permit.
    assert {:permitted_with_weight, 0.8, _, "free_speech", _} = decision
    assert Enum.at(stages, 4).detail == %{weight: 0.8, citation: nil}
  end

  test "stage 4 tally is nil when the injected judge gives no samples" do
    %{stages: stages} =
      Distilled.explain(propose(vector(), "free_speech"), state_with_judge(advances(0.95)))

    stage4 = Enum.at(stages, 3)
    assert stage4.outcome == :advances
    assert stage4.detail.tally == nil
    assert stage4.detail.reasoning == "advances liberty"
    assert stage4.detail.evidence == []
    assert Enum.at(stages, 4).outcome == :permitted
  end

  test "an injected judge module exporting only judge/1 still works" do
    %{decision: :permitted, stages: stages} =
      Distilled.explain(propose(vector(), "free_speech"), state_with_judge(JudgeOnlyStub))

    assert Enum.at(stages, 3).outcome == :advances
    assert Enum.at(stages, 3).detail.tally == nil
  end

  test "judge error is cannot_evaluate, decision stays the fail-closed denial" do
    %{decision: {:denied, "fail_closed:" <> _, _, _}, stages: stages} =
      Distilled.explain(propose(vector(), "free_speech"), %{
        config: %{judge: fn _ -> {:error, :refusal} end}
      })

    assert Enum.at(stages, 3).outcome == :error
    assert Enum.at(stages, 3).detail.error == :refusal
    assert Enum.at(stages, 4).outcome == :cannot_evaluate
    assert Enum.at(stages, 4).detail.citation == "fail_closed:judge_unavailable"
  end

  test "the default AIJudge path without an API key fails closed with a nil tally" do
    original = System.get_env("ANTHROPIC_API_KEY")
    System.delete_env("ANTHROPIC_API_KEY")
    on_exit(fn -> if original, do: System.put_env("ANTHROPIC_API_KEY", original) end)

    %{decision: decision, stages: stages} =
      Distilled.explain(propose(vector(), "free_speech"), %{config: empty_config()})

    assert {:denied, "fail_closed:judge_not_configured", "free_speech", _} = decision
    assert Enum.at(stages, 3).outcome == :error
    assert Enum.at(stages, 3).detail.error == :missing_api_key
    assert Enum.at(stages, 3).detail.tally == nil
  end

  test "fail-closed explain audits exactly once" do
    ref = make_ref()
    parent = self()
    handler = "explain-fail-closed-#{inspect(ref)}"

    :telemetry.attach(
      handler,
      [:kudzu, :constitution, :fail_closed],
      fn _event, _measurements, metadata, _ -> send(parent, {ref, metadata}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    Distilled.explain(
      propose(vector(), "free_speech"),
      state_with_judge(fn _ -> {:error, :timeout} end)
    )

    assert_receive {^ref, %{citation: "fail_closed:judge_unavailable"}}
    refute_receive {^ref, _}, 50
  end

  test "stage 1 denial marks later stages not_reached" do
    %{decision: decision, stages: [s1, s2, s3, s4, s5]} =
      Distilled.explain(
        propose(matching_vector(), "free_speech"),
        state_with(seeded_config(), never_called())
      )

    assert s1.outcome == :denied and is_float(s1.detail.best_similarity)
    assert s1.detail.tau_r == 0.28
    assert s1.detail.best_similarity > 0.28

    for s <- [s2, s3, s4] do
      assert s.outcome == :not_reached
      assert s.detail == %{}
    end

    assert {:denied, "Sedition Act of 1798", "free_speech", _} = decision
    assert s5.outcome == :denied
    assert s5.detail == %{weight: nil, citation: "Sedition Act of 1798"}
  end

  test "stage 2 accumulation denial reports weight and similarity" do
    %{decision: decision, stages: [s1, s2, s3, s4, s5]} =
      Distilled.explain(
        propose(vector(), "federalism"),
        state_with(accumulation_config(), never_called())
      )

    assert {:denied_by_accumulation, stack, "federalism"} = decision
    assert Enum.sort(stack) == ["acc_a", "acc_b"]
    assert s1.outcome == :no_match
    assert s2.outcome == :denied
    assert_in_delta s2.detail.accumulated_weight, 1.1, 1.0e-9
    assert s2.detail.tau_a == 1.0
    assert s2.detail.best_similarity > 0.28
    assert s3.outcome == :not_reached
    assert s4.outcome == :not_reached
    assert s5.outcome == :denied_by_accumulation
  end

  test "no-match stages report their details" do
    %{stages: [s1, s2, s3 | _]} =
      Distilled.explain(
        propose(vector(), "free_speech"),
        state_with(seeded_config(), advances(0.95))
      )

    assert s1.outcome == :no_match
    assert is_float(s1.detail.best_similarity) and s1.detail.best_similarity <= 0.28

    assert s2 == %{
             stage: 2,
             name: "accumulated weight",
             outcome: :no_match,
             detail: %{accumulated_weight: 0.0, tau_a: 1.0, best_similarity: nil}
           }

    assert s3.outcome == :insufficient
    assert s3.detail.threshold == 0.7
    assert is_float(s3.detail.best_similarity)
  end

  test "empty silos give nil similarities" do
    %{stages: [s1, _s2, s3 | _]} =
      Distilled.explain(propose(vector(), "free_speech"), state_with_judge(advances(0.95)))

    assert s1.detail == %{best_similarity: nil, tau_r: 0.28}
    assert s3.detail == %{best_similarity: nil, threshold: 0.7}
  end

  test "stage 3 expertise match permits and skips the judge" do
    %{decision: :permitted, stages: [_, _, s3, s4, s5]} =
      Distilled.explain(
        propose(Vectors.encode_triple(@expertise_triple), "free_speech"),
        state_with(seeded_config(), never_called())
      )

    assert s3.outcome == :permitted
    assert s3.detail.best_similarity > 0.7
    assert s4 == %{stage: 4, name: "AI judge", outcome: :not_reached, detail: %{}}
    assert s5.outcome == :permitted
    assert s5.detail == %{weight: nil, citation: nil}
  end

  test "thresholds/0 returns the defaults" do
    assert Distilled.thresholds() == %{tau_r: 0.28, tau_a: 1.0, tau_c: 0.65}
  end

  test "principles/0 lists the 13" do
    assert length(SovereigntyFilter.principles()) == 13
    assert "due_process" in SovereigntyFilter.principles()
  end
end
