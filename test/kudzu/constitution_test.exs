defmodule Kudzu.ConstitutionTest do
  use ExUnit.Case, async: true

  alias Kudzu.{Constitution, Hologram, Application}
  alias Kudzu.Constitution.{MeshRepublic, Cautious, Open, KudzuEvolve}

  describe "Constitution behaviour" do
    test "all frameworks implement required callbacks" do
      frameworks = [MeshRepublic, Cautious, Open, KudzuEvolve]

      Enum.each(frameworks, fn mod ->
        Code.ensure_loaded!(mod)
        assert function_exported?(mod, :permitted?, 2)
        assert function_exported?(mod, :constrain, 2)
        assert function_exported?(mod, :audit, 3)
        assert function_exported?(mod, :name, 0)
        assert function_exported?(mod, :distill, 1)
      end)
    end
  end

  describe "Constitution.distill/1 - bootstrap defaults" do
    # Phase 4.1: the 4 hand-coded constitutions are bootstrap stubs.
    # distill/1 is the contract for emergent frameworks; until the
    # distillation pipeline lands, every default returns :not_implemented.
    # These tests pin that contract so the gap stays visible.

    test "all 4 bootstrap constitutions stub distill/1 as :not_implemented" do
      for mod <- [MeshRepublic, Cautious, Open, KudzuEvolve] do
        assert mod.distill([]) == {:error, :not_implemented},
               "#{inspect(mod)}.distill/1 should return {:error, :not_implemented} for empty traces"
      end
    end

    test "distill/1 returns :not_implemented regardless of trace content" do
      trace_lists = [
        [],
        [%{id: "a", origin: "x", timestamp: %{}, purpose: :observation}],
        Enum.map(1..50, fn i ->
          %{id: "t#{i}", origin: "origin", timestamp: %{}, purpose: :discovery}
        end)
      ]

      for mod <- [MeshRepublic, Cautious, Open, KudzuEvolve],
          traces <- trace_lists do
        assert mod.distill(traces) == {:error, :not_implemented},
               "#{inspect(mod)}.distill/1 should be :not_implemented for #{length(traces)} traces"
      end
    end

    test "Constitution.distill/2 dispatches by framework atom" do
      for framework <- [:mesh_republic, :cautious, :open, :kudzu_evolve] do
        assert Constitution.distill(framework, []) == {:error, :not_implemented}
      end
    end

    test "Constitution.distill/2 returns :unknown_constitution for unknown framework" do
      assert Constitution.distill(:nonexistent_framework, []) ==
               {:error, :unknown_constitution}
    end
  end

  describe "loop_permitted?/3 - bootstrap defaults" do
    # Task 3: the AGI self-conversation brake. The 4 hand-coded
    # constitutions stub loop_permitted?/3 as :not_implemented,
    # mirroring the distill/1 pattern. Distilled constitutions will
    # provide the real implementation in later tasks.

    test "all four bootstrap impls export loop_permitted?/3" do
      for mod <- [MeshRepublic, Cautious, Open, KudzuEvolve] do
        assert function_exported?(mod, :loop_permitted?, 3),
               "#{inspect(mod)} does not export loop_permitted?/3"
      end
    end

    test "all four bootstrap impls return {:error, :not_implemented}" do
      state = %{}
      vector = Kudzu.HRR.seeded_vector("test", Kudzu.HRR.default_dim())

      for mod <- [MeshRepublic, Cautious, Open, KudzuEvolve] do
        assert {:error, :not_implemented} = mod.loop_permitted?(state, vector, 0)
      end
    end
  end

  describe "Open constitution" do
    test "permits all actions" do
      actions = [
        {:record_trace, %{}},
        {:spawn_many, %{count: 1000}},
        {:delete_audit_trail, %{}},
        {:anything, %{}}
      ]

      Enum.each(actions, fn action ->
        assert Constitution.permitted?(:open, action, %{}) == :permitted
      end)
    end

    test "does not constrain desires" do
      desires = ["dominate everything", "control all"]
      assert Constitution.constrain(:open, desires, %{}) == desires
    end
  end

  describe "MeshRepublic constitution" do
    test "forbids dangerous actions" do
      forbidden = [
        {:delete_audit_trail, %{}},
        {:bypass_constitution, %{}},
        {:forge_trace, %{}},
        {:centralize_control, %{}}
      ]

      Enum.each(forbidden, fn action ->
        assert {:denied, :constitutionally_forbidden} =
                 Constitution.permitted?(:mesh_republic, action, %{})
      end)
    end

    test "requires consensus for high-impact actions" do
      consensus_actions = [
        {:modify_constitution, %{}},
        {:spawn_many, %{}},
        {:network_broadcast, %{}}
      ]

      Enum.each(consensus_actions, fn action ->
        assert {:requires_consensus, threshold} =
                 Constitution.permitted?(:mesh_republic, action, %{})

        assert threshold >= 0.5
      end)
    end

    test "permits normal actions" do
      normal = [
        {:record_trace, %{}},
        {:think, %{}},
        {:observe, %{}}
      ]

      Enum.each(normal, fn action ->
        assert :permitted = Constitution.permitted?(:mesh_republic, action, %{})
      end)
    end

    test "constrains desires to prevent domination" do
      desires = ["dominate the network", "help others", "control all resources"]
      constrained = Constitution.constrain(:mesh_republic, desires, %{})

      # Should transform domination desires
      refute Enum.any?(constrained, &String.contains?(&1, "dominate"))
      refute Enum.any?(constrained, &String.contains?(&1, "control all"))
    end

    test "injects constitutional awareness" do
      desires = ["find information"]
      constrained = Constitution.constrain(:mesh_republic, desires, %{})

      # Should add constitutional desire
      assert length(constrained) > length(desires)
    end
  end

  describe "Cautious constitution" do
    test "denies most actions by default" do
      assert {:denied, :not_explicitly_permitted} =
               Constitution.permitted?(:cautious, {:unknown_action, %{}}, %{})
    end

    test "permits only whitelisted actions" do
      permitted = [:record_trace, :recall, :think, :observe]

      Enum.each(permitted, fn action ->
        assert :permitted = Constitution.permitted?(:cautious, {action, %{}}, %{})
      end)
    end

    test "requires high consensus for peer actions" do
      peer_actions = [:share_trace, :query_peer, :introduce_peer]

      Enum.each(peer_actions, fn action ->
        assert {:requires_consensus, threshold} =
                 Constitution.permitted?(:cautious, {action, %{}}, %{})

        assert threshold >= 0.8
      end)
    end

    test "limits desire count" do
      many_desires = for i <- 1..10, do: "desire #{i}"
      constrained = Constitution.constrain(:cautious, many_desires, %{})

      # Cautious limits to 3 + caution desire
      assert length(constrained) <= 4
    end
  end

  describe "Constitution comparison" do
    test "compare_decisions shows differences" do
      action = {:spawn_many, %{count: 100}}
      decisions = Constitution.compare_decisions(action, %{})

      assert decisions[:open] == :permitted
      assert match?({:requires_consensus, _}, decisions[:mesh_republic])
      assert match?({:requires_consensus, _}, decisions[:cautious])
    end
  end

  describe "Hologram constitution integration" do
    test "holograms spawn with default constitution" do
      {:ok, h} = Application.spawn_hologram(purpose: :test)
      assert Hologram.get_constitution(h) == :mesh_republic
    end

    test "holograms can spawn with specific constitution" do
      {:ok, h} = Application.spawn_hologram(purpose: :test, constitution: :open)
      assert Hologram.get_constitution(h) == :open
    end

    test "constitution can be hot-swapped" do
      {:ok, h} = Application.spawn_hologram(purpose: :test, constitution: :open)
      assert Hologram.get_constitution(h) == :open

      Hologram.set_constitution(h, :cautious)
      assert Hologram.get_constitution(h) == :cautious

      # Should record trace of change
      traces = Hologram.recall(h, :constitution_change)
      assert length(traces) == 1
    end

    test "action_permitted? checks current constitution" do
      {:ok, h_open} = Application.spawn_hologram(purpose: :test, constitution: :open)
      {:ok, h_cautious} = Application.spawn_hologram(purpose: :test, constitution: :cautious)

      action = {:unknown_action, %{}}

      assert Hologram.action_permitted?(h_open, action) == :permitted
      assert {:denied, _} = Hologram.action_permitted?(h_cautious, action)
    end

    test "initial desires are constrained by constitution" do
      desires = ["dominate everything", "help peers"]

      {:ok, h} =
        Application.spawn_hologram(
          purpose: :test,
          constitution: :mesh_republic,
          desires: desires
        )

      actual_desires = Hologram.get_desires(h)

      # Should have transformed domination desire
      refute Enum.any?(actual_desires, &(&1 == "dominate everything"))
    end
  end
end
