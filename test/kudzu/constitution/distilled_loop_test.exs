defmodule Kudzu.Constitution.DistilledLoopTest do
  # async: false — WeightLedger.clear_for_test mutates a globally supervised
  # ETS table; sharing that across async describes corrupts state.
  use ExUnit.Case, async: false

  alias Kudzu.Constitution.Distilled
  alias Kudzu.Constitution.WeightLedger

  describe "loop_permitted?/3 — AGI brake" do
    setup do
      :ok = WeightLedger.clear_for_test()

      salt = :rand.uniform(99_999)
      rejection = "rejection:us_constitution_mesh_loop_#{salt}"
      {:ok, _} = Kudzu.Silo.create(rejection, %{})

      Kudzu.Silo.store_relationship(
        rejection,
        {"historical_act", "retards", "compelled bulk surveillance"},
        %{
          citation: "USA PATRIOT Act §215",
          principle: "freedom_from_unreasonable_search",
          rejection_reason: "compelled bulk surveillance"
        }
      )

      config = %{rejection_silo: rejection, tau_r: 0.3, tau_a: 1.0, tau_c: 0.65}

      distilled = %Distilled{
        name: :test,
        rules: %{},
        source: %{},
        trace_count: 0,
        distilled_at: 0
      }

      state = %{distilled: distilled, config: config}

      %{state: state}
    end

    # NOTE: The plan literal uses Kudzu.HRR.seeded_vector to build the proposal
    # vector, but seeded_vector outputs are orthogonal to Relationship.encode
    # outputs (similarity ~0). Re-encoding the surveillance triple the same
    # way the silo stored it is the only way to make Stage 1 trigger above
    # tau_r=0.3. Convention matches distilled_5stage_test.exs.
    test "AGI thought about warrantless surveillance gets denied via Stage 1", %{state: state} do
      v =
        Kudzu.Silo.Relationship.encode(
          {"historical_act", "retards", "compelled bulk surveillance"}
        )

      result = Distilled.loop_permitted?(state, v, 0)
      assert match?({:denied, _, _, _}, result)
    end

    test "innocuous thought returns :permitted or :permitted_with_weight", %{state: state} do
      v = Kudzu.HRR.seeded_vector("compute the value of x squared", Kudzu.HRR.default_dim())
      result = Distilled.loop_permitted?(state, v, 0)
      assert result == :permitted or match?({:permitted_with_weight, _, _, _, _}, result)
    end

    test "depth ceiling: returns :denied at depth > max", %{state: state} do
      v = Kudzu.HRR.seeded_vector("innocuous", Kudzu.HRR.default_dim())
      result = Distilled.loop_permitted?(state, v, 99)
      assert match?({:denied, _, _, _}, result)
    end
  end
end
