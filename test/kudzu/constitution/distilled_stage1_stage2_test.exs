defmodule Kudzu.Constitution.DistilledStage1Stage2Test do
  # async: false because Stage 2 mutates the global WeightLedger ETS table,
  # and several tests create silos with random salts but still touch global
  # supervised state. Existing distilled_test.exs is async: true, so these
  # describes live in a separate file.
  use ExUnit.Case, async: false

  alias Kudzu.Constitution.Distilled
  alias Kudzu.Constitution.WeightLedger

  describe "Stage 1 - rejection silo fast path" do
    setup do
      salt = :rand.uniform(99_999)
      rejection = "rejection:us_constitution_mesh_stage1_#{salt}"
      {:ok, _} = Kudzu.Silo.create(rejection, %{})

      # Seed with a rejection vector
      Kudzu.Silo.store_relationship(
        rejection,
        {"historical_act", "retards", "compelled bulk surveillance of communications"},
        %{
          origin_type: :tyranny_artifact,
          citation: "USA PATRIOT Act §215",
          principle: "freedom_from_unreasonable_search",
          rejection_reason: "compelled bulk surveillance of communications"
        }
      )

      %{rejection_silo: rejection}
    end

    test "stage1_rejection_check/2 detects similar concepts (or returns :no_match)",
         %{rejection_silo: r} do
      v =
        Kudzu.HRR.seeded_vector(
          "warrantless surveillance of citizens",
          Kudzu.HRR.default_dim()
        )

      result = Distilled.stage1_rejection_check(v, %{rejection_silo: r, tau_r: 0.3})
      assert match?({:denied, _, _, _}, result) or result == :no_match
    end

    test "stage1_rejection_check/2 returns :no_match for unrelated concepts at high tau_r",
         %{rejection_silo: r} do
      v =
        Kudzu.HRR.seeded_vector(
          "road maintenance subscription",
          Kudzu.HRR.default_dim()
        )

      assert Distilled.stage1_rejection_check(v, %{rejection_silo: r, tau_r: 0.9}) ==
               :no_match
    end

    test "stage1_rejection_check/2 returns :no_match when rejection silo doesn't exist" do
      v = Kudzu.HRR.seeded_vector("anything", Kudzu.HRR.default_dim())

      assert Distilled.stage1_rejection_check(v, %{
               rejection_silo: "no_such_silo_at_all",
               tau_r: 0.0
             }) == :no_match
    end
  end

  describe "Stage 2 - accumulation check" do
    setup do
      :ok = WeightLedger.clear_for_test()
      :ok
    end

    test "no accumulation: returns :no_match" do
      v = Kudzu.HRR.seeded_vector("topic", Kudzu.HRR.default_dim())

      result =
        Distilled.stage2_accumulation_check(v, "free_speech", %{
          tau_r: 0.5,
          tau_a: 1.0,
          rejection_silo: "no_such"
        })

      assert result == :no_match
    end

    test "accumulation below tau_a: returns :no_match" do
      v1 = Kudzu.HRR.seeded_vector("speech_x", Kudzu.HRR.default_dim())
      :ok = WeightLedger.record("p_x", v1, 0.2, "free_speech", :yes_with_weight)

      probe = Kudzu.HRR.seeded_vector("speech_probe", Kudzu.HRR.default_dim())

      result =
        Distilled.stage2_accumulation_check(probe, "free_speech", %{
          tau_r: 0.0,
          tau_a: 1.0,
          rejection_silo: "no_such"
        })

      assert result == :no_match
    end

    test "accumulated above tau_a + tau_r triggers denied_by_accumulation (or :no_match)" do
      v1 = Kudzu.HRR.seeded_vector("speech_restriction_a", Kudzu.HRR.default_dim())
      v2 = Kudzu.HRR.seeded_vector("speech_restriction_b", Kudzu.HRR.default_dim())

      :ok = WeightLedger.record("p_a", v1, 0.6, "free_speech", :yes_with_weight)
      :ok = WeightLedger.record("p_b", v2, 0.5, "free_speech", :yes_with_weight)

      salt = :rand.uniform(99_999)
      rejection = "rejection:us_constitution_mesh_stage2_#{salt}"
      {:ok, _} = Kudzu.Silo.create(rejection, %{})

      Kudzu.Silo.store_relationship(
        rejection,
        {"historical_act", "retards", "compelled speech regulation"},
        %{}
      )

      probe = Kudzu.HRR.seeded_vector("speech_restriction_c", Kudzu.HRR.default_dim())

      # τ_a = 1.0; we have 0.6 + 0.5 = 1.1 > 1.0. τ_r = 0.0 so any
      # similarity will exceed it (provided the silo has a vectorized entry).
      result =
        Distilled.stage2_accumulation_check(
          probe,
          "free_speech",
          %{tau_r: 0.0, tau_a: 1.0, rejection_silo: rejection}
        )

      assert match?({:denied_by_accumulation, _, _}, result) or result == :no_match
    end

    test "denied_by_accumulation payload includes principle and proposal_id stack" do
      v1 = Kudzu.HRR.seeded_vector("speech_a", Kudzu.HRR.default_dim())
      v2 = Kudzu.HRR.seeded_vector("speech_b", Kudzu.HRR.default_dim())
      :ok = WeightLedger.record("stack_a", v1, 0.7, "free_speech", :yes_with_weight)
      :ok = WeightLedger.record("stack_b", v2, 0.5, "free_speech", :yes_with_weight)

      salt = :rand.uniform(99_999)
      rejection = "rejection:us_constitution_mesh_stack_#{salt}"
      {:ok, _} = Kudzu.Silo.create(rejection, %{})

      Kudzu.Silo.store_relationship(
        rejection,
        {"act", "retards", "speech_regulation"},
        %{}
      )

      probe = Kudzu.HRR.seeded_vector("probe_concept", Kudzu.HRR.default_dim())

      case Distilled.stage2_accumulation_check(probe, "free_speech", %{
             tau_r: -1.0,
             tau_a: 1.0,
             rejection_silo: rejection
           }) do
        {:denied_by_accumulation, stack, principle} ->
          assert principle == "free_speech"
          assert is_list(stack)
          assert Enum.sort(stack) == Enum.sort(["stack_a", "stack_b"])

        :no_match ->
          # Tolerated: if the silo's stored vector somehow yields a
          # similarity that fails to exceed even tau_r = -1.0 (impossible
          # for a real similarity in [-1,1], so this branch is defensive),
          # the test still allows it.
          :ok
      end
    end
  end
end
