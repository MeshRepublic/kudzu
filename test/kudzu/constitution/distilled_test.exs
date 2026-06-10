defmodule Kudzu.Constitution.DistilledTest do
  use ExUnit.Case, async: true

  alias Kudzu.Constitution.Distilled
  alias Kudzu.Trace
  alias Kudzu.VectorClock

  # Helper: build a trace whose reconstruction_hint matches the silo's
  # relationship schema. This is exactly what Silo.store_relationship/2
  # produces, so the test pins distill/1 against the real input shape.
  defp triple_trace(subject, relation, object, origin \\ "origin0") do
    hint = %{
      type: "relationship",
      subject: subject,
      relation: relation,
      object: object
    }

    %Trace{
      id:
        :crypto.hash(:sha256, "#{subject}-#{relation}-#{object}") |> Base.encode16(case: :lower),
      origin: origin,
      timestamp: VectorClock.new(origin),
      purpose: :discovery,
      path: [origin],
      reconstruction_hint: hint
    }
  end

  describe "Distilled struct" do
    test "has the expected fields" do
      d = %Distilled{
        name: :test_constitution,
        rules: %{},
        source: %{kind: :silo, domain: "linux_sysadmin_test_v2"},
        trace_count: 0,
        distilled_at: System.system_time(:second)
      }

      assert d.name == :test_constitution
      assert d.rules == %{}
      assert d.source.domain == "linux_sysadmin_test_v2"
      assert d.trace_count == 0
      assert is_integer(d.distilled_at)
    end
  end

  describe "distill/1 — aggregation of triples into rules" do
    test "returns {:error, :insufficient_traces} for empty input" do
      assert {:error, :insufficient_traces} = Distilled.distill([])
    end

    test "returns {:error, :insufficient_traces} for too few traces" do
      traces = [triple_trace("apt", "is", "package_manager")]
      assert {:error, :insufficient_traces} = Distilled.distill(traces)
    end

    test "ignores non-relationship traces silently" do
      bad_traces =
        for i <- 1..10 do
          %Trace{
            id: "no#{i}",
            origin: "x",
            timestamp: VectorClock.new("x"),
            purpose: :observation,
            path: ["x"],
            reconstruction_hint: %{type: "page_summary", content: "noise"}
          }
        end

      # No relationship triples -> insufficient
      assert {:error, :insufficient_traces} = Distilled.distill(bad_traces)
    end

    test "succeeds on >= @min_traces relationship traces" do
      traces =
        for i <- 1..15 do
          triple_trace("apt", "provides", "feature_#{i}")
        end

      assert {:ok, %Distilled{} = c} = Distilled.distill(traces)
      assert c.trace_count == 15
      # Rules keyed by subject
      assert Map.has_key?(c.rules.by_subject, "apt")
      # All 15 triples were about apt
      assert length(c.rules.by_subject["apt"]) == 15
    end

    test "groups triples by subject" do
      traces = [
        triple_trace("apt", "is", "package_manager"),
        triple_trace("apt", "provides", "dependency_resolution"),
        triple_trace("systemctl", "controls", "systemd"),
        triple_trace("systemctl", "shows", "unit_status"),
        triple_trace("lvm", "manages", "volume_groups")
      ]

      # Pad to clear the min-traces threshold
      padded = traces ++ Enum.map(1..10, fn i -> triple_trace("apt", "uses", "tool_#{i}") end)

      {:ok, c} = Distilled.distill(padded)

      assert length(c.rules.by_subject["apt"]) == 12
      assert length(c.rules.by_subject["systemctl"]) == 2
      assert length(c.rules.by_subject["lvm"]) == 1
    end

    test "indexes triples by relation" do
      traces = [
        triple_trace("apt", "provides", "x"),
        triple_trace("apt", "provides", "y"),
        triple_trace("systemctl", "provides", "z"),
        triple_trace("apt", "requires", "perl")
      ]

      padded = traces ++ Enum.map(1..10, fn i -> triple_trace("foo_#{i}", "is", "bar") end)
      {:ok, c} = Distilled.distill(padded)

      assert length(c.rules.by_relation["provides"]) == 3
      assert length(c.rules.by_relation["requires"]) == 1
      assert length(c.rules.by_relation["is"]) == 10
    end

    test "records the relation frequency table" do
      traces =
        for i <- 1..20 do
          if rem(i, 2) == 0 do
            triple_trace("apt", "provides", "feature_#{i}")
          else
            triple_trace("apt", "is", "thing_#{i}")
          end
        end

      {:ok, c} = Distilled.distill(traces)

      # 10 each
      assert c.rules.relation_frequency["provides"] == 10
      assert c.rules.relation_frequency["is"] == 10
    end

    test "exposes the top relations sorted by frequency" do
      traces =
        Enum.map(1..10, fn i -> triple_trace("x_#{i}", "provides", "y") end) ++
          Enum.map(1..5, fn i -> triple_trace("x_#{i}", "requires", "y") end) ++
          Enum.map(1..3, fn i -> triple_trace("x_#{i}", "rare", "y") end)

      {:ok, c} = Distilled.distill(traces)

      assert hd(c.rules.top_relations) == {"provides", 10}
      assert "rare" in Enum.map(c.rules.top_relations, &elem(&1, 0))
    end

    test "accepts :name and :source options to label the constitution" do
      traces = Enum.map(1..15, fn i -> triple_trace("x", "is", "y_#{i}") end)

      {:ok, c} =
        Distilled.distill(traces,
          name: :linux_sysadmin_v2,
          source: %{kind: :silo, domain: "linux_sysadmin_test_v2"}
        )

      assert c.name == :linux_sysadmin_v2
      assert c.source.domain == "linux_sysadmin_test_v2"
    end

    test "name defaults to :distilled when not provided" do
      traces = Enum.map(1..15, fn i -> triple_trace("x", "is", "y_#{i}") end)
      {:ok, c} = Distilled.distill(traces)
      assert c.name == :distilled
    end
  end

  describe "Distilled implements the Constitution behaviour" do
    setup do
      # Sysadmin-shaped triples — actions involving "apt" are well-evidenced.
      traces =
        [
          triple_trace("apt", "is", "command-line_interface"),
          triple_trace("apt", "provides", "dependency_resolution"),
          triple_trace("apt", "requires", "root"),
          triple_trace("apt", "manages", "packages"),
          triple_trace("systemctl", "controls", "systemd"),
          triple_trace("systemctl", "requires", "root"),
          triple_trace("nginx", "is", "web_server")
        ] ++ Enum.map(1..10, fn i -> triple_trace("apt", "uses", "feature_#{i}") end)

      {:ok, distilled} =
        Distilled.distill(traces, name: :sysadmin_test, source: %{kind: :test})

      {:ok, distilled: distilled}
    end

    test "implements all required callbacks", %{distilled: _} do
      Code.ensure_loaded!(Distilled)
      assert function_exported?(Distilled, :permitted?, 2)
      assert function_exported?(Distilled, :constrain, 2)
      assert function_exported?(Distilled, :audit, 3)
      assert function_exported?(Distilled, :name, 0)
      assert function_exported?(Distilled, :distill, 1)
    end

    test "name/0 returns :distilled (the module-level name)" do
      assert Distilled.name() == :distilled
    end

    test "permitted? consults the rules for actions about well-evidenced subjects",
         %{distilled: d} do
      state = %{distilled: d}
      action = {:install, %{subject: "apt"}}
      # apt has many supporting triples — permitted
      assert Distilled.permitted?(action, state) == :permitted
    end

    test "permitted? denies actions about unknown subjects when state has distilled rules",
         %{distilled: d} do
      state = %{distilled: d}
      action = {:install, %{subject: "totally_unheard_of_tool"}}
      assert {:denied, :no_evidence} = Distilled.permitted?(action, state)
    end

    test "permitted? falls back to :permitted when state has no distilled rules" do
      # If a caller passes an action through a Distilled framework but
      # forgets to supply the rules in state, fail open (don't crash) —
      # the rules are a soft guidance layer not a hard gate.
      action = {:install, %{subject: "anything"}}
      assert :permitted = Distilled.permitted?(action, %{})
    end

    test "constrain/2 passes through desires unchanged (distilled defaults to advisory)",
         %{distilled: d} do
      desires = ["learn more about systemctl", "set up an nginx server"]
      assert Distilled.constrain(desires, %{distilled: d}) == desires
    end

    test "audit/3 returns {:ok, audit_id} including the constitution name", %{distilled: d} do
      state = %{distilled: d, id: "agent42"}
      trace = %{id: "t1", purpose: :observation, origin: "agent42"}
      assert {:ok, audit_id} = Distilled.audit(trace, :permitted, state)
      assert is_binary(audit_id)
      assert String.starts_with?(audit_id, "audit-distilled-")
    end
  end

  describe "Distilled.permitted? rule semantics" do
    test "actions with no subject field cannot be denied (no rule to consult)" do
      traces = Enum.map(1..15, fn i -> triple_trace("x", "is", "y_#{i}") end)
      {:ok, d} = Distilled.distill(traces)
      action = {:think, %{}}
      assert :permitted = Distilled.permitted?(action, %{distilled: d})
    end

    test "high-evidence subjects are permitted; never-seen subjects denied" do
      # 20 triples about "apt"
      apt_traces = Enum.map(1..20, fn i -> triple_trace("apt", "uses", "feature_#{i}") end)
      {:ok, d} = Distilled.distill(apt_traces)

      state = %{distilled: d}

      assert :permitted = Distilled.permitted?({:install, %{subject: "apt"}}, state)
      assert {:denied, :no_evidence} = Distilled.permitted?({:run, %{subject: "obscure"}}, state)
    end
  end

  describe "Distilled integrates with Constitution dispatcher" do
    # The top-level Kudzu.Constitution dispatcher's get_framework/1 accepts
    # any module-atom that exports the behaviour callbacks. This means
    # Distilled is callable through the dispatcher even though it's not in
    # the hand-coded @frameworks map — the design recognizes that
    # distilled constitutions are per-instance, not per-name.

    test "Kudzu.Constitution.get_framework/1 returns Distilled module by atom" do
      assert Kudzu.Constitution.get_framework(Distilled) == Distilled
    end

    test "Kudzu.Constitution.permitted?/3 dispatches to Distilled" do
      traces = Enum.map(1..15, fn i -> triple_trace("apt", "is", "x_#{i}") end)
      {:ok, d} = Distilled.distill(traces)

      assert :permitted =
               Kudzu.Constitution.permitted?(
                 Distilled,
                 {:install, %{subject: "apt"}},
                 %{distilled: d}
               )

      assert {:denied, :no_evidence} =
               Kudzu.Constitution.permitted?(
                 Distilled,
                 {:install, %{subject: "unknown"}},
                 %{distilled: d}
               )
    end

    test "Kudzu.Constitution.distill/2 dispatches to Distilled.distill/1" do
      traces = Enum.map(1..15, fn i -> triple_trace("apt", "is", "x_#{i}") end)

      assert {:ok, %Distilled{trace_count: 15}} =
               Kudzu.Constitution.distill(Distilled, traces)
    end
  end
end
