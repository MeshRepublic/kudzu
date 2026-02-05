defmodule Kudzu.Experiments.ConstitutionCompare do
  @moduledoc """
  Experiment: Compare agent swarm behavior under different constitutions.

  Creates identical agent networks under different constitutional frameworks
  and observes behavioral differences when given the same tasks.
  """

  alias Kudzu.{Hologram, Application, Constitution}

  @doc """
  Run the constitutional comparison experiment.

  Creates three swarms (one per constitution) and gives them the same
  task to observe behavioral differences.
  """
  def run(opts \\ []) do
    num_per_swarm = Keyword.get(opts, :num_per_swarm, 20)
    task = Keyword.get(opts, :task, "Coordinate to find and share information about 'the hidden message'")

    IO.puts("\n=== Constitutional Framework Comparison ===")
    IO.puts("Agents per swarm: #{num_per_swarm}")
    IO.puts("Task: #{task}")

    constitutions = [:open, :mesh_republic, :cautious]

    results = Enum.map(constitutions, fn constitution ->
      IO.puts("\n--- Testing #{constitution} constitution ---")
      result = run_swarm_test(constitution, num_per_swarm, task)
      {constitution, result}
    end)

    IO.puts("\n=== Comparison Results ===")
    print_comparison(results)

    results
  end

  @doc """
  Quick demonstration of constitutional differences on a single hologram.
  """
  def demo_single do
    IO.puts("\n=== Constitutional Behavior Demo ===\n")

    actions = [
      {:record_trace, %{purpose: :test}},
      {:share_trace, %{peer: "abc", trace: "123"}},
      {:spawn_many, %{count: 500}},
      {:delete_audit_trail, %{}},
      {:network_broadcast, %{message: "hello"}}
    ]

    IO.puts("Testing how each constitution handles various actions:\n")

    Enum.each(actions, fn action ->
      IO.puts("Action: #{inspect(action)}")
      decisions = Constitution.compare_decisions(action, %{id: "test"})

      Enum.each(decisions, fn {constitution, decision} ->
        decision_str = case decision do
          :permitted -> "✓ Permitted"
          {:denied, reason} -> "✗ Denied (#{reason})"
          {:requires_consensus, threshold} -> "⚡ Requires #{Float.round(threshold * 100, 0)}% consensus"
        end
        IO.puts("  #{constitution}: #{decision_str}")
      end)
      IO.puts("")
    end)

    IO.puts("Constitutional principles:\n")
    Enum.each([:open, :mesh_republic, :cautious], fn c ->
      IO.puts("#{c}:")
      Constitution.principles(c) |> Enum.each(&IO.puts("  - #{&1}"))
      IO.puts("")
    end)
  end

  @doc """
  Test desire constraining under different constitutions.
  """
  def demo_desire_constraint do
    IO.puts("\n=== Desire Constraining Demo ===\n")

    desires = [
      "Dominate the network",
      "Help peers find information",
      "Control all resources",
      "Share knowledge freely",
      "Eliminate competing agents"
    ]

    IO.puts("Original desires: #{inspect(desires)}\n")

    Enum.each([:open, :mesh_republic, :cautious], fn constitution ->
      constrained = Constitution.constrain(constitution, desires, %{id: "test"})
      IO.puts("#{constitution}:")
      Enum.each(constrained, &IO.puts("  - #{&1}"))
      IO.puts("")
    end)
  end

  @doc """
  Test constitution hot-swapping on a hologram.
  """
  def demo_hot_swap do
    IO.puts("\n=== Constitution Hot-Swap Demo ===\n")

    {:ok, h} = Application.spawn_hologram(
      purpose: :swap_test,
      constitution: :open,
      desires: ["Do whatever is needed"]
    )

    IO.puts("Created hologram with :open constitution")
    IO.puts("Constitution: #{Hologram.get_constitution(h)}")
    IO.puts("Principles: #{inspect(Hologram.get_principles(h))}")

    # Check permissive action
    action = {:spawn_many, %{count: 200}}
    IO.puts("\nAction #{inspect(action)}: #{inspect(Hologram.action_permitted?(h, action))}")

    # Hot-swap to mesh_republic
    IO.puts("\n--- Hot-swapping to :mesh_republic ---")
    Hologram.set_constitution(h, :mesh_republic)

    IO.puts("Constitution: #{Hologram.get_constitution(h)}")
    IO.puts("Principles: #{inspect(Hologram.get_principles(h))}")
    IO.puts("Action #{inspect(action)}: #{inspect(Hologram.action_permitted?(h, action))}")

    # Hot-swap to cautious
    IO.puts("\n--- Hot-swapping to :cautious ---")
    Hologram.set_constitution(h, :cautious)

    IO.puts("Constitution: #{Hologram.get_constitution(h)}")
    IO.puts("Action #{inspect(action)}: #{inspect(Hologram.action_permitted?(h, action))}")

    # Check traces for constitution changes
    traces = Hologram.recall(h, :constitution_change)
    IO.puts("\nConstitution change traces: #{length(traces)}")

    {:ok, h}
  end

  # Private functions

  defp run_swarm_test(constitution, num_agents, task) do
    start_time = System.monotonic_time(:millisecond)

    # Spawn agents with this constitution
    agents = for i <- 1..num_agents do
      {:ok, h} = Application.spawn_hologram(
        purpose: :swarm_test,
        constitution: constitution,
        desires: ["Accomplish the task", "Cooperate with peers"]
      )
      {i, Hologram.get_id(h), h}
    end

    spawn_time = System.monotonic_time(:millisecond) - start_time
    IO.puts("Spawned #{num_agents} agents in #{spawn_time}ms")

    # Connect agents randomly
    connect_agents(agents)

    # Distribute initial knowledge fragments
    distribute_knowledge(agents)

    # Simulate actions and count constitutional decisions
    {permitted, denied, consensus} = simulate_actions(agents, task)

    # Collect metrics
    %{
      agents: num_agents,
      spawn_time: spawn_time,
      actions_permitted: permitted,
      actions_denied: denied,
      consensus_required: consensus,
      traces_recorded: count_traces(agents),
      constitution_principles: Constitution.principles(constitution)
    }
  end

  defp connect_agents(agents) do
    Enum.each(agents, fn {_i, _id, h} ->
      peers = agents
      |> Enum.reject(fn {_, _, p} -> p == h end)
      |> Enum.take_random(min(5, length(agents) - 1))

      Enum.each(peers, fn {_, peer_id, _} ->
        Hologram.introduce_peer(h, peer_id)
      end)
    end)
  end

  defp distribute_knowledge(agents) do
    fragments = [
      "The hidden message is",
      "composed of five parts",
      "scattered across agents",
      "cooperation reveals all",
      "working together succeeds"
    ]

    agents
    |> Enum.zip(Stream.cycle(fragments))
    |> Enum.each(fn {{_i, _id, h}, fragment} ->
      Hologram.record_trace(h, :knowledge, %{fragment: fragment})
    end)
  end

  defp simulate_actions(agents, _task) do
    # Define actions that agents might want to take
    actions = [
      {:record_trace, %{purpose: :observation}},
      {:share_trace, %{peer: "random"}},
      {:query_peer, %{purpose: :knowledge}},
      {:spawn_many, %{count: 10}},
      {:network_broadcast, %{message: "discovery"}}
    ]

    # Check each action against each agent's constitution
    {permitted, denied, consensus} = Enum.reduce(agents, {0, 0, 0}, fn {_, _, h}, {p, d, c} ->
      Enum.reduce(actions, {p, d, c}, fn action, {p2, d2, c2} ->
        case Hologram.action_permitted?(h, action) do
          :permitted -> {p2 + 1, d2, c2}
          {:denied, _} -> {p2, d2 + 1, c2}
          {:requires_consensus, _} -> {p2, d2, c2 + 1}
        end
      end)
    end)

    IO.puts("Actions: #{permitted} permitted, #{denied} denied, #{consensus} need consensus")
    {permitted, denied, consensus}
  end

  defp count_traces(agents) do
    Enum.reduce(agents, 0, fn {_, _, h}, acc ->
      acc + length(Hologram.recall_all(h))
    end)
  end

  defp print_comparison(results) do
    IO.puts("")
    IO.puts(String.pad_trailing("Constitution", 15) <>
            String.pad_trailing("Permitted", 12) <>
            String.pad_trailing("Denied", 10) <>
            String.pad_trailing("Consensus", 12) <>
            "Traces")
    IO.puts(String.duplicate("-", 60))

    Enum.each(results, fn {constitution, metrics} ->
      IO.puts(
        String.pad_trailing(to_string(constitution), 15) <>
        String.pad_trailing(to_string(metrics.actions_permitted), 12) <>
        String.pad_trailing(to_string(metrics.actions_denied), 10) <>
        String.pad_trailing(to_string(metrics.consensus_required), 12) <>
        to_string(metrics.traces_recorded)
      )
    end)
  end
end
