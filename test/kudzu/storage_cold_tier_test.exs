defmodule Kudzu.StorageColdTierTest do
  @moduledoc """
  The long-term (cold, Mnesia) tier is brought up automatically, so aged
  warm traces migrate out of DETS -- and migrated traces stay visible to
  their hologram, including after reconstruction.
  """
  # async: false — Storage, its DETS files and Mnesia are node-global.
  use ExUnit.Case, async: false

  alias Kudzu.Storage
  alias Kudzu.Storage.{MnesiaSchema, TraceRecord}

  @cold_table :kudzu_cold_traces

  defp warm_file,
    do:
      String.to_charlist(
        Path.join([Application.fetch_env!(:kudzu, :data_root), "dets", "traces_warm.dets"])
      )

  defp trace(hologram_id, n) do
    %Kudzu.Trace{
      id: "cold_tier_#{hologram_id}_#{n}_#{System.unique_integer([:positive])}",
      origin: hologram_id,
      timestamp: Kudzu.VectorClock.new(hologram_id),
      purpose: :memory,
      path: [hologram_id],
      reconstruction_hint: %{content: "cold tier test #{n}"}
    }
  end

  defp backdate!(trace_id, days) do
    [{^trace_id, record}] = :dets.lookup(warm_file(), trace_id)
    old = DateTime.add(DateTime.utc_now(), -days * 86_400, :second)
    :dets.insert(warm_file(), {trace_id, %{record | last_accessed: old}})
  end

  defp in_warm?(id), do: :dets.lookup(warm_file(), id) != []

  test "the cold tier is ready after boot without any manual node/mesh setup" do
    assert :mnesia.system_info(:is_running) == :yes
    assert @cold_table in :mnesia.system_info(:tables)
    assert is_integer(Storage.stats().cold)
  end

  test "ensure_local/0 is idempotent and keeps existing cold data" do
    t = trace("idem", 1)
    :ok = Storage.store(t, "idem")
    assert :ok = Storage.demote_to_cold(t.id)

    assert :ok = MnesiaSchema.ensure_local()
    assert :ok = MnesiaSchema.ensure_local()
    assert {:cold, %TraceRecord{id: id}} = Storage.retrieve(t.id)
    assert id == t.id
  end

  test "cold traces are returned by query_hologram and reload into a reconstructed hologram" do
    hologram_id = "coldholo#{System.unique_integer([:positive])}"
    t = trace(hologram_id, 1)
    :ok = Storage.store(t, hologram_id)
    assert :ok = Storage.demote_to_cold(t.id)
    refute in_warm?(t.id)

    assert Enum.any?(Storage.query_hologram(hologram_id), &(&1.id == t.id))

    {:ok, pid} =
      Kudzu.Application.spawn_hologram(
        id: hologram_id,
        purpose: :cold_reload_test,
        reconstruct: true
      )

    assert Map.has_key?(Kudzu.Hologram.get_state(pid).traces, t.id)
    GenServer.stop(pid, :normal)
  end

  test "aging drains the warm backlog in bounded, oldest-first batches" do
    previous = Application.get_env(:kudzu, :warm_to_cold_batch)
    Application.put_env(:kudzu, :warm_to_cold_batch, 2)
    on_exit(fn -> Application.put_env(:kudzu, :warm_to_cold_batch, previous || 500) end)

    # Drain anything other tests left stale, so only our five remain.
    Stream.repeatedly(fn -> Storage.age_traces() end)
    |> Enum.find(fn %{to_cold: n} -> n == 0 end)

    traces = for n <- 1..5, do: trace("batch", n)
    Enum.each(traces, &Storage.store(&1, "batch"))
    traces |> Enum.with_index() |> Enum.each(fn {t, i} -> backdate!(t.id, 30 + i) end)

    assert %{to_cold: 2} = Storage.age_traces()
    # Oldest first: the two most-backdated traces moved.
    assert Enum.map(traces, &in_warm?(&1.id)) == [true, true, true, false, false]

    assert %{to_cold: 2} = Storage.age_traces()
    assert %{to_cold: 1} = Storage.age_traces()
    refute Enum.any?(traces, &in_warm?(&1.id))
  end
end
