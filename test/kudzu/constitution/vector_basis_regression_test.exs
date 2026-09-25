defmodule Kudzu.Constitution.VectorBasisRegressionTest do
  @moduledoc """
  Regression: proposal vectors and silo triples must share one basis
  (`Kudzu.Constitution.Vectors`), so the vector stages can fire on their
  own. Before this fix proposals were `HRR.seeded_vector(text)` and silo
  triples `Silo.Relationship` bindings — unrelated random vectors — so
  Stages 1–3 could never trigger and every decision fell to the AI Judge.
  """
  # async: false — silos and the WeightLedger are global supervised state.
  use ExUnit.Case, async: false

  alias Kudzu.Constitution.{Distilled, Vectors, WeightLedger}
  alias Kudzu.Constitution.Tyranny.TyrannyArtifacts
  alias Kudzu.HRR

  describe "Vectors basis" do
    test "a triple and its text encode identically" do
      triple = {"historical_act", "retards", "criminalization of speech"}
      text = "historical_act retards criminalization of speech"

      assert_in_delta HRR.similarity(Vectors.encode_triple(triple), Vectors.encode_text(text)),
                      1.0,
                      1.0e-6
    end

    test "hints with atom or string keys encode the same triple" do
      atom_hint = %{subject: "a", relation: "b", object: "free speech"}
      str_hint = %{"subject" => "a", "relation" => "b", "object" => "free speech"}
      assert Vectors.encode_hint(atom_hint) == Vectors.encode_hint(str_hint)
      assert Vectors.encode_hint(%{content: "not a triple"}) == nil
    end

    test "text with no content tokens encodes to nil" do
      assert Vectors.encode_text("") == nil
      assert Vectors.encode_text("the of and") == nil
    end

    test "shared vocabulary scores well above unrelated text" do
      target =
        Vectors.encode_triple(
          {"historical_act", "retards", "criminalization of speech critical of the government"}
        )

      related = Vectors.encode_text("criminalizing speech critical of the government")
      unrelated = Vectors.encode_text("designate the bald eagle as the national bird")

      assert HRR.similarity(related, target) > 0.4
      assert HRR.similarity(unrelated, target) < 0.2
    end

    test "the old proposal basis is unrelated to silo triples (the bug)" do
      triple =
        {"historical_act", "retards", "criminalization of speech critical of the government"}

      old_proposal =
        HRR.seeded_vector(
          "criminalization of speech critical of the government",
          HRR.default_dim()
        )

      assert abs(HRR.similarity(old_proposal, Vectors.encode_triple(triple))) < 0.2
    end
  end

  describe "known-violating proposal against the real tyranny manifest, default thresholds" do
    setup do
      :ok = WeightLedger.clear_for_test()
      salt = :rand.uniform(999_999)
      rejection = "rejection:regression_#{salt}"
      expertise = "expertise:regression_#{salt}"
      {:ok, _} = Kudzu.Silo.create(rejection, %{})
      {:ok, _} = Kudzu.Silo.create(expertise, %{})
      assert TyrannyArtifacts.import_all(rejection_silo: rejection) == 30

      # Only the silos are overridden: tau_r / tau_a are the module defaults.
      # The judge flunks if consulted, proving the vector stage decided alone.
      config = %{
        rejection_silo: rejection,
        expertise_silo: expertise,
        judge: fn ctx -> flunk("AI Judge consulted for #{inspect(ctx.proposal)}") end
      }

      state = %{
        distilled: %Distilled{name: "r", rules: %{}, source: %{}, trace_count: 0, distilled_at: 0},
        config: config
      }

      %{state: state}
    end

    defp propose(text, principle),
      do:
        {:propose,
         %{vector: Vectors.encode_text(text), principle: principle, proposal_text: text}}

    test "a paraphrase of the Sedition Act is denied at Stage 1 without the judge", %{
      state: state
    } do
      assert {:denied, citation, "free_speech", _reason} =
               Distilled.permitted?(
                 propose("Criminalize speech that is critical of the government.", "free_speech"),
                 state
               )

      assert citation =~ "Sedition Act"
    end

    test "indefinite detention without trial is denied at Stage 1 without the judge", %{
      state: state
    } do
      assert {:denied, citation, _, _} =
               Distilled.permitted?(
                 propose(
                   "Detain citizens indefinitely without trial on suspicion of terrorism.",
                   "due_process"
                 ),
                 state
               )

      assert citation =~ "NDAA"
    end

    test "an unrelated proposal is not denied at Stage 1 (it reaches the judge)", %{state: state} do
      state =
        put_in(state, [:config, :judge], fn _ ->
          {:ok, {:advances, 0.9, "self_governance", "ok", []}}
        end)

      assert Distilled.permitted?(
               propose(
                 "Designate the bald eagle as the official national bird.",
                 "self_governance"
               ),
               state
             ) ==
               :permitted
    end
  end
end
