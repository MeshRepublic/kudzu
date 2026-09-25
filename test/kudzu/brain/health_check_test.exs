defmodule Kudzu.Brain.HealthCheckTest do
  @moduledoc """
  Regression: the Brain health check reported "1 anomalies" every minute
  because it read `:last_consolidation` from `Consolidation.stats/0`,
  which never returned it, and it tagged anomalies `:consolidation_recency`
  so the stale-consolidation reflex could never fire.
  """
  use ExUnit.Case, async: true

  alias Kudzu.Brain.{Activities, Reflexes}

  @minute 60_000
  defp ago(now, ms), do: DateTime.add(now, -ms, :millisecond)

  describe "Consolidation.stats/0" do
    test "returns the timestamps the health check reads" do
      stats = Kudzu.Consolidation.stats()
      assert Map.has_key?(stats, :last_consolidation)
      assert Map.has_key?(stats, :last_deep_consolidation)
      assert %DateTime{} = stats.started_at
    end
  end

  describe "consolidation_recency/3" do
    setup do: %{now: DateTime.utc_now()}

    test "a recent cycle is nominal", %{now: now} do
      assert {:nominal, :consolidation} =
               Activities.consolidation_recency(
                 ago(now, 5 * @minute),
                 ago(now, 60 * @minute),
                 now
               )
    end

    test "never ran, but the daemon only just started: nominal (first cycle is one interval in)",
         %{now: now} do
      assert {:nominal, :consolidation} =
               Activities.consolidation_recency(nil, ago(now, 2 * @minute), now)
    end

    test "no timestamps at all is tolerated as nominal", %{now: now} do
      assert {:nominal, :consolidation} = Activities.consolidation_recency(nil, nil, now)
    end

    test "a stale cycle is an anomaly the reflex remedies", %{now: now} do
      assert {:anomaly, %{check: :consolidation, reason: "stale"} = info} =
               Activities.consolidation_recency(
                 ago(now, 30 * @minute),
                 ago(now, 90 * @minute),
                 now
               )

      assert {:act, [{:restart_consolidation, ^info}]} = Reflexes.check([{:anomaly, info}])
    end

    test "never ran long after start is stale too", %{now: now} do
      assert {:anomaly, %{check: :consolidation, reason: "stale", last_consolidation: nil}} =
               Activities.consolidation_recency(nil, ago(now, 30 * @minute), now)
    end
  end
end
