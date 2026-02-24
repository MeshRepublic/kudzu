defmodule Kudzu.Brain.ReflexesTest do
  use ExUnit.Case, async: true

  alias Kudzu.Brain.Reflexes

  describe "check/1" do
    test "empty anomalies returns :pass" do
      assert Reflexes.check([]) == :pass
    end

    test "consolidation stale anomaly triggers action" do
      anomalies = [{:anomaly, %{check: :consolidation, reason: "stale"}}]
      assert {:act, actions} = Reflexes.check(anomalies)
      assert length(actions) == 1
      assert {:restart_consolidation, _info} = hd(actions)
    end

    test "storage unreachable anomaly triggers escalation" do
      anomalies = [{:anomaly, %{check: :storage, reason: "unreachable"}}]
      assert {:escalate, escalations} = Reflexes.check(anomalies)
      assert length(escalations) == 1
      assert %{severity: :critical, check: :storage} = hd(escalations)
    end

    test "consolidation unreachable anomaly triggers escalation" do
      anomalies = [{:anomaly, %{check: :consolidation, reason: "unreachable"}}]
      assert {:escalate, escalations} = Reflexes.check(anomalies)
      assert %{severity: :critical, check: :consolidation} = hd(escalations)
    end

    test "no holograms anomaly triggers warning escalation" do
      anomalies = [{:anomaly, %{check: :holograms, reason: "no holograms"}}]
      assert {:escalate, escalations} = Reflexes.check(anomalies)
      assert %{severity: :warning, check: :holograms} = hd(escalations)
    end

    test "unknown anomaly returns :pass (falls through)" do
      anomalies = [{:anomaly, %{check: :something_unknown, reason: "weird"}}]
      assert Reflexes.check(anomalies) == :pass
    end

    test "actions take priority over escalations" do
      anomalies = [
        {:anomaly, %{check: :consolidation, reason: "stale"}},
        {:anomaly, %{check: :storage, reason: "unreachable"}}
      ]
      assert {:act, _actions} = Reflexes.check(anomalies)
    end

    test "mixed unknown and escalation returns escalation" do
      anomalies = [
        {:anomaly, %{check: :something_unknown, reason: "weird"}},
        {:anomaly, %{check: :storage, reason: "unreachable"}}
      ]
      assert {:escalate, _} = Reflexes.check(anomalies)
    end
  end
end
