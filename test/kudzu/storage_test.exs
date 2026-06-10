defmodule Kudzu.StorageTest do
  @moduledoc """
  Tests for tiered storage (ETS hot → DETS warm → Mnesia cold).

  These tests are async: false because Storage is a named singleton
  GenServer and the underlying ETS/DETS/Mnesia tables are shared.
  """
  use ExUnit.Case, async: false

  alias Kudzu.Storage
  alias Kudzu.Storage.{MnesiaSchema, TraceRecord}

  @cold_table :kudzu_cold_traces

  setup do
    # Bring up a local Mnesia cold tier if one is not already initialized.
    # In test, this lands in the per-run /tmp data_root (see config/test.exs)
    # so it never collides with the production node.
    ensure_cold_tier_ready()

    on_exit(fn ->
      # Clear cold-tier table between tests so they remain independent.
      try do
        {:atomic, :ok} = :mnesia.clear_table(@cold_table)
      rescue
        _ -> :ok
      catch
        :exit, _ -> :ok
      end
    end)

    :ok
  end

  describe "demote_to_cold/1" do
    test "moves a warm-tier trace into the Mnesia cold table" do
      trace = build_trace("demote_round_trip_a")

      :ok = Storage.store(trace, "test_hologram")
      # The aging cycle has not run, so the trace is in hot + warm.
      # Force a manual demotion straight to cold.
      assert :ok = Storage.demote_to_cold(trace.id)

      # Read back: must arrive from cold tier.
      assert {:cold, %TraceRecord{id: id}} = Storage.retrieve(trace.id)
      assert id == trace.id
    end

    test "returns :not_found if the trace is not in the warm tier" do
      assert :not_found =
               Storage.demote_to_cold("trace_that_does_not_exist_#{:rand.uniform(999_999)}")
    end
  end

  describe "delete/1 — durable removal from all tiers" do
    test "removes a trace from hot ETS, warm DETS, and the embedding tables" do
      trace = build_trace("delete_round_trip_a")
      :ok = Storage.store(trace, "test_hologram")

      # Confirm baseline: trace is retrievable.
      assert {tier, %TraceRecord{}} = Storage.retrieve(trace.id)
      assert tier in [:hot, :warm]

      assert :ok = Storage.delete(trace.id)

      # All tiers must report not found.
      assert :not_found = Storage.retrieve(trace.id)
    end

    test "is idempotent — deleting a missing trace returns :ok" do
      assert :ok = Storage.delete("trace_that_was_never_stored_#{:rand.uniform(999_999)}")
    end

    test "broadcasts {:trace_deleted, id} on the traces:delete topic" do
      trace = build_trace("delete_broadcasts_a")
      :ok = Storage.store(trace, "test_hologram")
      :ok = Phoenix.PubSub.subscribe(Kudzu.PubSub, "traces:delete")

      :ok = Storage.delete(trace.id)

      assert_receive {:trace_deleted, trace_id}, 1_000
      assert trace_id == trace.id
    end
  end

  describe "age_traces — warm→cold archival" do
    test "stale, non-critical warm traces are demoted into the cold tier" do
      trace = build_trace("warm_to_cold_via_aging")
      :ok = Storage.store(trace, "test_hologram")

      # Backdate the warm-tier record beyond the warm→cold threshold so
      # the aging cycle picks it up. Bypass the GenServer and patch DETS
      # directly so the test stays time-independent.
      backdate_warm_record!(trace.id, -60 * 60 * 24 * 30)

      %{to_cold: to_cold} = Storage.age_traces()
      assert to_cold >= 1

      assert [] = :dets.lookup(warm_dets_file(), trace.id)
      assert {:cold, %TraceRecord{id: id}} = Storage.retrieve(trace.id)
      assert id == trace.id
    end

    test "critical-importance traces are not demoted by aging" do
      trace = build_trace("warm_to_cold_skip_critical")
      :ok = Storage.store(trace, "test_hologram", :critical)

      backdate_warm_record!(trace.id, -60 * 60 * 24 * 30)

      Storage.age_traces()

      # Still in warm; nothing got moved.
      assert [_one] = :dets.lookup(warm_dets_file(), trace.id)
    end
  end

  describe "cold-tier table alignment" do
    test "Storage reads from the same Mnesia table MnesiaSchema writes" do
      # MnesiaSchema writes to :kudzu_cold_traces. Storage's @cold_table
      # must match — otherwise demote-then-read would silently miss.
      trace = build_trace("alignment_check")

      record = %TraceRecord{
        id: trace.id,
        hologram_id: "test_hologram",
        purpose: :memory,
        reconstruction_hint: %{content: "alignment"},
        origin: "test",
        path: [],
        clock: trace.timestamp,
        created_at: DateTime.utc_now(),
        last_accessed: DateTime.utc_now(),
        access_count: 0,
        importance: :normal
      }

      assert {:atomic, :ok} = MnesiaSchema.store(record)

      # If table names diverge, this returns :not_found.
      assert {:cold, %TraceRecord{id: id}} = Storage.retrieve(trace.id)
      assert id == trace.id
    end
  end

  describe "cold tier durability across Storage restart" do
    test "trace survives Storage GenServer restart and is readable from cold" do
      trace = build_trace("durability_round_trip")
      :ok = Storage.store(trace, "test_hologram")
      :ok = Storage.demote_to_cold(trace.id)
      # Sanity: it is reachable now.
      assert {:cold, %TraceRecord{id: id1}} = Storage.retrieve(trace.id)
      assert id1 == trace.id

      # Stop the Storage GenServer (the supervisor will not restart it
      # because we wait for the new PID after starting it ourselves).
      Supervisor.terminate_child(Kudzu.Supervisor, Kudzu.Storage)
      assert is_nil(Process.whereis(Kudzu.Storage))
      # Start a fresh Storage GenServer — its init/1 re-opens the warm
      # DETS file under the per-test :data_root and re-checks Mnesia.
      {:ok, _} = Supervisor.restart_child(Kudzu.Supervisor, Kudzu.Storage)

      # The same trace must now be retrievable from cold, post-restart.
      assert {:cold, %TraceRecord{id: id2}} = Storage.retrieve(trace.id)
      assert id2 == trace.id
    end
  end

  # --- Helpers ---

  defp warm_dets_file do
    String.to_charlist(
      Path.join([
        Application.fetch_env!(:kudzu, :data_root),
        "dets",
        "traces_warm.dets"
      ])
    )
  end

  defp backdate_warm_record!(trace_id, delta_seconds) do
    case :dets.lookup(warm_dets_file(), trace_id) do
      [{^trace_id, record}] ->
        backdated = %{
          record
          | last_accessed: DateTime.add(DateTime.utc_now(), delta_seconds, :second)
        }

        :dets.insert(warm_dets_file(), {trace_id, backdated})
        :ok

      [] ->
        flunk("expected trace #{trace_id} in warm DETS")
    end
  end

  defp build_trace(suffix) do
    %Kudzu.Trace{
      id: "trace_#{suffix}_#{:rand.uniform(999_999_999)}",
      origin: "test_storage",
      timestamp: Kudzu.VectorClock.new("test_storage"),
      purpose: :memory,
      path: [],
      reconstruction_hint: %{content: "test content #{suffix}"}
    }
  end

  defp ensure_cold_tier_ready do
    # Force Mnesia to use the per-test :data_root directory. OTP auto-starts
    # Mnesia (it is in extra_applications) on its default cwd-relative dir
    # before our setup runs; init_node will stop+restart it on the right dir.
    MnesiaSchema.init_node()

    tables = :mnesia.system_info(:tables)

    unless @cold_table in tables do
      MnesiaSchema.create_schema([node()])
    end

    :mnesia.wait_for_tables([@cold_table], 5_000)
    :ok
  end
end
