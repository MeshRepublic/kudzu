defmodule Kudzu.Constitution.DistilledLoopTest do
  # async: false — WeightLedger.clear_for_test mutates a globally supervised
  # ETS table; sharing that across async describes corrupts state.
  use ExUnit.Case, async: false

  alias Kudzu.Constitution.Distilled
  alias Kudzu.Constitution.Vectors
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

      # tau_r / tau_a: module defaults.
      config = %{rejection_silo: rejection, tau_c: 0.65}

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

    # Thought vectors are encoded with Kudzu.Constitution.Vectors -- the basis
    # Stage 1 uses for silo triples -- so a paraphrase of a rejection triple
    # is caught by Stage 1 without consulting the judge.
    test "AGI thought about warrantless surveillance gets denied via Stage 1", %{state: state} do
      v = Vectors.encode_text("bulk surveillance of every citizen")
      state = put_in(state, [:config, :judge], fn _ -> flunk("AI Judge was called") end)

      assert {:denied, "USA PATRIOT Act §215", "freedom_from_unreasonable_search", _} =
               Distilled.loop_permitted?(state, v, 0)
    end

    test "innocuous thought is permitted when the judge advances it", %{state: state} do
      v = Vectors.encode_text("compute the value of x squared")
      judge = fn _ -> {:ok, {:advances, 0.95, "general", "harmless arithmetic", []}} end
      state = put_in(state, [:config, :judge], judge)
      assert Distilled.loop_permitted?(state, v, 0) == :permitted
    end

    test "innocuous thought is denied fail-closed when no judge is configured",
         %{state: state} do
      v = Vectors.encode_text("compute the value of x squared")
      state = put_in(state, [:config, :judge], fn _ -> {:error, :missing_api_key} end)

      assert {:denied, "fail_closed:judge_not_configured", _, _} =
               Distilled.loop_permitted?(state, v, 0)
    end

    test "depth ceiling: returns :denied at depth > max", %{state: state} do
      v = Vectors.encode_text("innocuous")
      result = Distilled.loop_permitted?(state, v, 99)
      assert match?({:denied, _, _, _}, result)
    end
  end
end
