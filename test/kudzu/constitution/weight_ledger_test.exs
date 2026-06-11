defmodule Kudzu.Constitution.WeightLedgerTest do
  use ExUnit.Case, async: false

  alias Kudzu.Constitution.WeightLedger

  setup do
    # Ledger is supervised; we just need to clear it for test isolation.
    :ok = WeightLedger.clear_for_test()
    :ok
  end

  describe "record/5 + accumulated_weight/2" do
    test "single entry: accumulated_weight returns the entry's vector + scalar" do
      v = test_vector("speech_restriction_1")

      :ok = WeightLedger.record("prop_1", v, 0.4, "free_speech", :yes_with_weight)

      {acc_v, acc_scalar} = WeightLedger.accumulated_weight(v, "free_speech")
      assert acc_scalar == 0.4
      assert is_list(acc_v)
    end

    test "two entries on same principle accumulate scalar" do
      v1 = test_vector("speech_restriction_1")
      v2 = test_vector("speech_restriction_2")

      :ok = WeightLedger.record("prop_1", v1, 0.4, "free_speech", :yes_with_weight)
      :ok = WeightLedger.record("prop_2", v2, 0.3, "free_speech", :yes_with_weight)

      probe_vec = test_vector("speech_restriction_probe")
      {_acc_v, acc_scalar} = WeightLedger.accumulated_weight(probe_vec, "free_speech")
      assert_in_delta acc_scalar, 0.7, 1.0e-9
    end

    test "different principles do not cross-accumulate" do
      v_speech = test_vector("speech_thing")
      v_search = test_vector("search_thing")

      :ok = WeightLedger.record("prop_1", v_speech, 0.4, "free_speech", :yes_with_weight)

      :ok =
        WeightLedger.record(
          "prop_2",
          v_search,
          0.5,
          "freedom_from_unreasonable_search",
          :yes_with_weight
        )

      {_, speech_scalar} = WeightLedger.accumulated_weight(v_speech, "free_speech")

      {_, search_scalar} =
        WeightLedger.accumulated_weight(v_search, "freedom_from_unreasonable_search")

      assert speech_scalar == 0.4
      assert search_scalar == 0.5
    end

    test ":no vote outcome does NOT add weight" do
      v = test_vector("noop")
      :ok = WeightLedger.record("prop_1", v, 0.4, "free_speech", :no)

      {_, acc_scalar} = WeightLedger.accumulated_weight(v, "free_speech")
      assert acc_scalar == 0.0
    end
  end

  describe "entries_for_principle/1" do
    test "returns only entries for the requested principle" do
      v1 = test_vector("a")
      v2 = test_vector("b")
      :ok = WeightLedger.record("p1", v1, 0.4, "free_speech", :yes_with_weight)
      :ok = WeightLedger.record("p2", v2, 0.3, "due_process", :yes_with_weight)

      entries = WeightLedger.entries_for_principle("free_speech")
      assert length(entries) == 1
      assert hd(entries).proposal_id == "p1"
    end
  end

  describe "anchor_pending/0" do
    test "returns all yet-unanchored entries" do
      v = test_vector("anchor")
      :ok = WeightLedger.record("p1", v, 0.4, "free_speech", :yes_with_weight)
      pending = WeightLedger.anchor_pending()
      assert "p1" in Enum.map(pending, & &1.proposal_id)
    end
  end

  describe "PubSub broadcast" do
    test "broadcasts {:weight_recorded, proposal_id, principle} on record" do
      Phoenix.PubSub.subscribe(Kudzu.PubSub, "traces:weight_ledger")
      v = test_vector("broadcast")
      :ok = WeightLedger.record("prop_broadcast", v, 0.4, "free_speech", :yes_with_weight)

      assert_receive {:weight_recorded, "prop_broadcast", "free_speech"}, 1_000
    end
  end

  defp test_vector(label), do: Kudzu.HRR.seeded_vector(label, Kudzu.HRR.default_dim())
end
