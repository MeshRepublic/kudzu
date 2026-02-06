defmodule Kudzu.ConstitutionTest do
  use ExUnit.Case, async: true

  alias Kudzu.{Constitution, Hologram, Application}
  alias Kudzu.Constitution.{MeshRepublic, Cautious, Open}

  describe "Constitution behaviour" do
    test "all frameworks implement required callbacks" do
      frameworks = [MeshRepublic, Cautious, Open]

      Enum.each(frameworks, fn mod ->
        Code.ensure_loaded!(mod)
        assert function_exported?(mod, :permitted?, 2)
        assert function_exported?(mod, :constrain, 2)
        assert function_exported?(mod, :audit, 3)
        assert function_exported?(mod, :name, 0)
      end)
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

      {:ok, h} = Application.spawn_hologram(
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
