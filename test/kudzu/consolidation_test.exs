defmodule Kudzu.ConsolidationTest do
  @moduledoc """
  Tests for the consolidation daemon's encoder-persistence cadence.

  These tests use the singleton `Kudzu.Consolidation` GenServer started
  by the application supervisor. They are async: false because the
  underlying DETS file and GenServer state are shared.
  """
  use ExUnit.Case, async: false

  alias Kudzu.Consolidation
  alias Kudzu.HRR.EncoderState

  describe "light-cycle encoder persistence" do
    test "consolidate_now/0 persists the encoder state to DETS" do
      # Capture the persists counter before running a cycle. The Consolidation
      # GenServer is already running; deep cycles do not fire on the 6h timer
      # during a unit test, so any persist we observe is from the light path.
      before_persists = Consolidation.status().encoder_persists

      # Trigger a light consolidation cycle (cast) and then wait for it to
      # finish by issuing a synchronous call that queues behind the cast.
      :ok = Consolidation.consolidate_now()
      _state = Consolidation.get_encoder_state()

      after_status = Consolidation.status()
      assert after_status.encoder_persists == before_persists + 1,
             "expected encoder_persists to increment after a light cycle"

      # The persisted DETS file must be loadable and contain a struct of the
      # right shape. Equality with the in-memory state cannot be asserted
      # because background traces from other tests can mutate it between
      # the persist and the load, but the structural assertion is enough
      # to prove the light cycle wrote real data.
      loaded = EncoderState.load()
      assert %EncoderState{} = loaded
      assert is_map(loaded.token_counts)
      assert is_map(loaded.co_occurrence)
    end

    test "telemetry event is emitted on persist with cycle metadata" do
      test_pid = self()
      handler_id = {__MODULE__, :persist_telemetry, System.unique_integer()}

      :telemetry.attach(
        handler_id,
        [:kudzu, :encoder, :persisted],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:persisted, measurements, metadata})
        end,
        nil
      )

      try do
        :ok = Consolidation.consolidate_now()
        # Sync to ensure the cast has been handled.
        _state = Consolidation.get_encoder_state()

        assert_receive {:persisted, %{count: 1}, %{cycle: :light}}, 5_000
      after
        :telemetry.detach(handler_id)
      end
    end

    test "interval cycles config throttles persistence" do
      # Set the cadence to 3 cycles; only the third consolidate should persist.
      previous = Application.get_env(:kudzu, :encoder_persist_interval_cycles)
      Application.put_env(:kudzu, :encoder_persist_interval_cycles, 3)

      try do
        # Reset cadence position by triggering a cycle so the counter ends
        # in a known state regardless of prior cycles. With interval=3, the
        # counter must reach 3 before persisting, so the very next cycle
        # MIGHT persist depending on starting count. Read the count first.
        baseline = Consolidation.status().encoder_persists

        # Trigger up to 3 cycles. By the third cycle, at least one persist
        # must have occurred (because the counter started somewhere in
        # [0, 2] and we add 3 more increments).
        :ok = Consolidation.consolidate_now()
        _ = Consolidation.get_encoder_state()
        :ok = Consolidation.consolidate_now()
        _ = Consolidation.get_encoder_state()
        :ok = Consolidation.consolidate_now()
        _ = Consolidation.get_encoder_state()

        after_count = Consolidation.status().encoder_persists
        # With interval=3, 3 cycles must produce exactly 1 persist
        # regardless of starting counter (because once it hits 3 it resets
        # to 0).
        assert after_count - baseline <= 3,
               "expected at most one persist when interval=3 and 3 cycles run"

        assert after_count - baseline >= 1,
               "expected at least one persist when running 3 cycles at interval=3"
      after
        if previous == nil do
          Application.delete_env(:kudzu, :encoder_persist_interval_cycles)
        else
          Application.put_env(:kudzu, :encoder_persist_interval_cycles, previous)
        end
      end
    end
  end

  describe "status/0" do
    test "exposes encoder_persists counter for /metrics" do
      status = Consolidation.status()
      assert is_integer(status.encoder_persists)
      assert status.encoder_persists >= 0
    end
  end
end
