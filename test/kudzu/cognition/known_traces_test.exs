defmodule Kudzu.Cognition.KnownTracesTest do
  @moduledoc """
  Tests for the per-`{hologram, model, session}` trace-knowledge tracker.

  KnownTraces is started by the application supervisor as a singleton; these
  tests share the live ETS table and use unique session ids per test to
  avoid cross-test interference.

  Sweeps and TTL eviction are exercised via `KnownTraces.sweep_now/0` and
  the `:known_traces_ttl_ms` application env knob (restored in an
  after-block).
  """
  use ExUnit.Case, async: false

  alias Kudzu.Cognition.KnownTraces

  defp unique_session(suffix) do
    "test-session-#{System.unique_integer([:positive])}-#{suffix}"
  end

  describe "seen? / mark_sent round trip" do
    test "first call returns false; mark_sent + same call returns true" do
      session_id = unique_session("roundtrip")

      refute KnownTraces.seen?("holo", "claude", session_id, "trace-1")

      :ok = KnownTraces.mark_sent("holo", "claude", session_id, ["trace-1"])
      :ok = KnownTraces.sync()

      assert KnownTraces.seen?("holo", "claude", session_id, "trace-1")
    end

    test "mark_sent accepts a single trace_id or a list" do
      session_id = unique_session("shape")

      :ok = KnownTraces.mark_sent("holo", "claude", session_id, "single-trace")
      :ok = KnownTraces.mark_sent("holo", "claude", session_id, ["list-trace-1", "list-trace-2"])
      :ok = KnownTraces.sync()

      assert KnownTraces.seen?("holo", "claude", session_id, "single-trace")
      assert KnownTraces.seen?("holo", "claude", session_id, "list-trace-1")
      assert KnownTraces.seen?("holo", "claude", session_id, "list-trace-2")
    end

    test "model_id can be either atom or string and is normalized" do
      session_id = unique_session("modelnorm")

      :ok = KnownTraces.mark_sent("holo", :claude, session_id, ["trace-x"])
      :ok = KnownTraces.sync()

      assert KnownTraces.seen?("holo", :claude, session_id, "trace-x")
      assert KnownTraces.seen?("holo", "claude", session_id, "trace-x")
    end
  end

  describe "session and model isolation" do
    test "different sessions are independent" do
      session_a = unique_session("iso-a")
      session_b = unique_session("iso-b")

      :ok = KnownTraces.mark_sent("holo", "claude", session_a, ["shared-trace"])
      :ok = KnownTraces.sync()

      assert KnownTraces.seen?("holo", "claude", session_a, "shared-trace")
      refute KnownTraces.seen?("holo", "claude", session_b, "shared-trace")
    end

    test "different models on the same session are independent" do
      session_id = unique_session("modeliso")

      :ok = KnownTraces.mark_sent("holo", "claude", session_id, ["trace-y"])
      :ok = KnownTraces.sync()

      assert KnownTraces.seen?("holo", "claude", session_id, "trace-y")
      refute KnownTraces.seen?("holo", "gpt-4", session_id, "trace-y")
    end

    test "different holograms are independent" do
      session_id = unique_session("holoiso")

      :ok = KnownTraces.mark_sent("holo-a", "claude", session_id, ["trace-z"])
      :ok = KnownTraces.sync()

      assert KnownTraces.seen?("holo-a", "claude", session_id, "trace-z")
      refute KnownTraces.seen?("holo-b", "claude", session_id, "trace-z")
    end
  end

  describe "TTL eviction via sweep" do
    test "rows older than TTL are evicted on sweep" do
      previous_ttl = Application.get_env(:kudzu, :known_traces_ttl_ms)
      # Aggressively short TTL so the next sweep evicts the row immediately.
      Application.put_env(:kudzu, :known_traces_ttl_ms, 1)

      try do
        session_id = unique_session("ttl")

        :ok = KnownTraces.mark_sent("holo", "claude", session_id, ["trace-old"])
        :ok = KnownTraces.sync()
        assert KnownTraces.seen?("holo", "claude", session_id, "trace-old")

        # Let monotonic time advance past the 1 ms TTL.
        Process.sleep(10)
        evicted = KnownTraces.sweep_now()
        assert evicted >= 1

        refute KnownTraces.seen?("holo", "claude", session_id, "trace-old")
      after
        if previous_ttl,
          do: Application.put_env(:kudzu, :known_traces_ttl_ms, previous_ttl),
          else: Application.delete_env(:kudzu, :known_traces_ttl_ms)
      end
    end

    test "active rows survive a sweep that evicts stale ones" do
      previous_ttl = Application.get_env(:kudzu, :known_traces_ttl_ms)
      Application.put_env(:kudzu, :known_traces_ttl_ms, 50)

      try do
        stale_session = unique_session("ttl-stale")
        fresh_session = unique_session("ttl-fresh")

        :ok = KnownTraces.mark_sent("holo", "claude", stale_session, ["t-stale"])
        :ok = KnownTraces.sync()

        # Sleep past TTL so the stale row is eligible for eviction; then
        # touch the fresh session so its last_used is recent.
        Process.sleep(80)
        :ok = KnownTraces.mark_sent("holo", "claude", fresh_session, ["t-fresh"])
        :ok = KnownTraces.sync()

        _ = KnownTraces.sweep_now()

        refute KnownTraces.seen?("holo", "claude", stale_session, "t-stale")
        assert KnownTraces.seen?("holo", "claude", fresh_session, "t-fresh")
      after
        if previous_ttl,
          do: Application.put_env(:kudzu, :known_traces_ttl_ms, previous_ttl),
          else: Application.delete_env(:kudzu, :known_traces_ttl_ms)
      end
    end
  end

  describe "forget_session" do
    test "clears state for that session only" do
      session_a = unique_session("forget-a")
      session_b = unique_session("forget-b")

      :ok = KnownTraces.mark_sent("holo", "claude", session_a, ["t-a"])
      :ok = KnownTraces.mark_sent("holo", "claude", session_b, ["t-b"])
      :ok = KnownTraces.sync()

      assert KnownTraces.seen?("holo", "claude", session_a, "t-a")
      assert KnownTraces.seen?("holo", "claude", session_b, "t-b")

      :ok = KnownTraces.forget_session("holo", "claude", session_a)

      refute KnownTraces.seen?("holo", "claude", session_a, "t-a")
      assert KnownTraces.seen?("holo", "claude", session_b, "t-b")
    end
  end

  describe "stats" do
    test "reports the live counts of sessions and traces_known" do
      # The application-wide table may contain residue from other tests;
      # we only assert that adding new state strictly increases the counts.
      session_id = unique_session("stats")

      before = KnownTraces.stats()
      assert is_integer(before.sessions) and is_integer(before.traces_known)

      :ok = KnownTraces.mark_sent("holo-stats", "claude", session_id, ["t-1", "t-2", "t-3"])
      :ok = KnownTraces.sync()

      after_stats = KnownTraces.stats()
      assert after_stats.sessions >= before.sessions + 1
      assert after_stats.traces_known >= before.traces_known + 3
    end
  end

  describe "concurrency" do
    test "many concurrent readers do not crash and produce consistent results" do
      session_id = unique_session("concurrency")
      :ok = KnownTraces.mark_sent("holo-c", "claude", session_id, ["concurrent-trace"])
      :ok = KnownTraces.sync()

      results =
        1..100
        |> Task.async_stream(
          fn _ -> KnownTraces.seen?("holo-c", "claude", session_id, "concurrent-trace") end,
          max_concurrency: 16,
          timeout: 5_000
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.all?(results, & &1), "all concurrent reads should observe the marked trace"
    end
  end

end
