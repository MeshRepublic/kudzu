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
      assert :not_found = Storage.demote_to_cold("trace_that_does_not_exist_#{:rand.uniform(999_999)}")
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

  # --- Helpers ---

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
