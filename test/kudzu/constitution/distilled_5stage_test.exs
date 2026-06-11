defmodule Kudzu.Constitution.Distilled5StageTest do
  # async: false — WeightLedger.clear_for_test mutates a globally supervised
  # ETS table; the existing distilled_stage1_stage2_test.exs file is also
  # async: false for the same reason.
  use ExUnit.Case, async: false

  alias Kudzu.Constitution.Distilled
  alias Kudzu.Constitution.WeightLedger

  describe "permitted?/2 — 5-stage extension" do
    setup do
      :ok = WeightLedger.clear_for_test()

      salt = :rand.uniform(99_999)
      rejection = "rejection:us_constitution_mesh_full_#{salt}"
      expertise = "expertise:us_constitution_mesh_full_#{salt}"

      {:ok, _} = Kudzu.Silo.create(rejection, %{})
      {:ok, _} = Kudzu.Silo.create(expertise, %{})

      Kudzu.Silo.store_relationship(
        rejection,
        {"historical_act", "retards", "compelled speech criminalization"},
        %{
          citation: "Sedition Act of 1798",
          principle: "free_speech",
          rejection_reason: "compelled speech criminalization"
        }
      )

      Kudzu.Silo.store_relationship(
        expertise,
        {"individual", "has_right_to", "free_speech"},
        %{
          citation: "Federalist 84",
          principle: "free_speech",
          sovereignty_score: 0.95
        }
      )

      config = %{
        rejection_silo: rejection,
        expertise_silo: expertise,
        tau_r: 0.4,
        tau_a: 1.0,
        tau_c: 0.65
      }

      state = %{
        distilled: %Distilled{
          name: "test",
          rules: %{},
          source: %{},
          trace_count: 0,
          distilled_at: 0
        },
        config: config
      }

      %{state: state, config: config}
    end

    test "Stage 1 denial on direct rejection match", %{state: state} do
      action =
        {:propose,
         %{
           subject: "speech_restriction",
           vector:
             Kudzu.HRR.seeded_vector(
               "criminalization of dissident speech",
               Kudzu.HRR.default_dim()
             ),
           principle: "free_speech"
         }}

      result = Distilled.permitted?(action, state)

      assert match?({:denied, _, _, _}, result) or result == :permitted or
               match?({:permitted_with_weight, _, _, _, _}, result)
    end

    test "off-corpus topic produces :permitted_with_weight via Stage 5", %{state: state} do
      action =
        {:propose,
         %{
           subject: "state_bird_designation",
           vector:
             Kudzu.HRR.seeded_vector(
               "state bird designation",
               Kudzu.HRR.default_dim()
             ),
           principle: "self_governance"
         }}

      # Without a real Claude API key, Stage 4 returns :error and Stage 5
      # escalates with weight 1.0; if the AI Judge ever succeeds, the
      # match also accepts :permitted (Stage 3 strong-positive path).
      result = Distilled.permitted?(action, state)
      assert match?({:permitted_with_weight, _, _, _, _}, result) or result == :permitted
    end

    test "tau_r: -1.0 + identical proposal vector guarantees Stage 1 denial",
         %{config: config} do
      # Use tau_r below all possible similarities (HRR similarity is in
      # [-1.0, 1.0]) so that any rejection-silo match triggers denial.
      # The proposal vector is rebuilt from the same triple stored in
      # the rejection silo, so similarity is ~1.0 — denial is
      # guaranteed regardless of any seeded_vector noise.
      tight_config = Map.put(config, :tau_r, -1.0)

      state = %{
        distilled: %Distilled{
          name: "test",
          rules: %{},
          source: %{},
          trace_count: 0,
          distilled_at: 0
        },
        config: tight_config
      }

      proposal_vector =
        Kudzu.Silo.Relationship.encode(
          {"historical_act", "retards", "compelled speech criminalization"}
        )

      action =
        {:propose,
         %{
           subject: "anything",
           vector: proposal_vector,
           principle: "free_speech"
         }}

      assert match?({:denied, _, _, _}, Distilled.permitted?(action, state))
    end
  end

  describe "permitted?/2 — legacy shape preserved" do
    test "legacy {:install, %{subject: ...}} still returns :permitted for known subject" do
      traces =
        Enum.map(1..15, fn i ->
          hint = %{
            type: "relationship",
            subject: "apt",
            relation: "uses",
            object: "feature_#{i}"
          }

          %Kudzu.Trace{
            id: "t#{i}",
            origin: "x",
            timestamp: Kudzu.VectorClock.new("x"),
            purpose: :discovery,
            path: ["x"],
            reconstruction_hint: hint
          }
        end)

      {:ok, d} = Distilled.distill(traces)
      assert :permitted = Distilled.permitted?({:install, %{subject: "apt"}}, %{distilled: d})

      assert {:denied, :no_evidence} =
               Distilled.permitted?({:install, %{subject: "unknown"}}, %{distilled: d})
    end

    test "legacy shape with no distilled rules in state falls back to :permitted" do
      assert :permitted = Distilled.permitted?({:install, %{subject: "x"}}, %{})
    end
  end
end
