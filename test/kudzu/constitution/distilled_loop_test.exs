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

    test "innocuous thought is permitted when the judge advances it", %{state: state} do
      v = Kudzu.HRR.seeded_vector("compute the value of x squared", Kudzu.HRR.default_dim())
      judge = fn _ -> {:ok, {:advances, 0.95, "general", "harmless arithmetic", []}} end
      state = put_in(state, [:config, :judge], judge)
      assert Distilled.loop_permitted?(state, v, 0) == :permitted
    end

    test "innocuous thought is denied fail-closed when no judge is configured",
         %{state: state} do
      v = Kudzu.HRR.seeded_vector("compute the value of x squared", Kudzu.HRR.default_dim())
      state = put_in(state, [:config, :judge], fn _ -> {:error, :missing_api_key} end)

      assert {:denied, "fail_closed:judge_not_configured", _, _} =
               Distilled.loop_permitted?(state, v, 0)
    end

    test "depth ceiling: returns :denied at depth > max", %{state: state} do
      v = Kudzu.HRR.seeded_vector("innocuous", Kudzu.HRR.default_dim())
      result = Distilled.loop_permitted?(state, v, 99)
      assert match?({:denied, _, _, _}, result)
    end
  end
end
