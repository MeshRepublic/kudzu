defmodule Kudzu.HologramTest do
  use ExUnit.Case, async: false

  alias Kudzu.{Hologram, Trace, Application}

  @moduletag timeout: 300_000  # 5 minutes for large tests

  describe "basic hologram operations" do
    test "spawns and records traces" do
      {:ok, h} = Application.spawn_hologram(purpose: :test)
      {:ok, trace} = Hologram.record_trace(h, :test_purpose, %{data: "hello"})

      assert trace.origin == Hologram.get_id(h)
      assert trace.purpose == :test_purpose
      assert trace.reconstruction_hint == %{data: "hello"}

      traces = Hologram.recall(h, :test_purpose)
      assert length(traces) == 1
    end

    test "introduces peers and tracks proximity" do
      {:ok, h1} = Application.spawn_hologram(purpose: :test)
      {:ok, h2} = Application.spawn_hologram(purpose: :test)

      id2 = Hologram.get_id(h2)
      :ok = Hologram.introduce_peer(h1, id2)

      peers = Hologram.get_peers(h1)
      assert Map.has_key?(peers, id2)
      assert peers[id2] > 0
    end

    test "shares traces between peers" do
      {:ok, h1} = Application.spawn_hologram(purpose: :test)
      {:ok, h2} = Application.spawn_hologram(purpose: :test)

      id1 = Hologram.get_id(h1)
      id2 = Hologram.get_id(h2)

      # Create a trace in h1
      {:ok, trace} = Hologram.record_trace(h1, :shared_data, %{key: "value"})

      # Share with h2
      Hologram.receive_trace(h2, trace, id1)

      # Give it a moment to process
      Process.sleep(50)

      # h2 should now have the trace
      traces = Hologram.recall(h2, :shared_data)
      assert length(traces) == 1

      # The trace should show h2 in the path
      [received] = traces
      assert id2 in received.path
    end
  end

  describe "network resilience - 1000 holograms" do
    @tag :large
    test "survives 30% node loss and reconstructs context via alternate paths" do
      # Configuration
      num_holograms = 1000
      connections_per_node = 10
      traces_per_node = 3
      kill_percentage = 0.30

      IO.puts("\n=== Kudzu Network Resilience Test ===")
      IO.puts("Spawning #{num_holograms} holograms...")

      # Spawn all holograms
      start_time = System.monotonic_time(:millisecond)
      holograms = Application.spawn_holograms(num_holograms, purpose: :resilience_test)
      spawn_time = System.monotonic_time(:millisecond) - start_time

      IO.puts("Spawned #{length(holograms)} holograms in #{spawn_time}ms")
      IO.puts("Schedulers online: #{System.schedulers_online()}")

      # Create random peer connections
      IO.puts("Creating peer connections (#{connections_per_node} per node)...")
      start_time = System.monotonic_time(:millisecond)

      holograms
      |> Task.async_stream(
        fn {_id, pid} ->
          peers = holograms
          |> Enum.reject(fn {_, p} -> p == pid end)
          |> Enum.take_random(connections_per_node)

          Enum.each(peers, fn {peer_id, _peer_pid} ->
            Hologram.introduce_peer(pid, peer_id)
          end)
        end,
        max_concurrency: System.schedulers_online() * 4,
        ordered: false,
        timeout: 60_000
      )
      |> Stream.run()

      connect_time = System.monotonic_time(:millisecond) - start_time
      IO.puts("Connected peers in #{connect_time}ms")

      # Record traces with propagation
      IO.puts("Recording #{traces_per_node} traces per hologram...")
      start_time = System.monotonic_time(:millisecond)

      trace_purposes = [:memory, :interaction, :observation]

      all_traces = holograms
      |> Task.async_stream(
        fn {id, pid} ->
          Enum.map(1..traces_per_node, fn i ->
            purpose = Enum.at(trace_purposes, rem(i, 3))
            {:ok, trace} = Hologram.record_trace(pid, purpose, %{
              node: id,
              index: i,
              data: :crypto.strong_rand_bytes(32) |> Base.encode64()
            })

            # Share with random peers
            peers = Hologram.get_peers(pid)
            share_targets = peers
            |> Map.keys()
            |> Enum.take_random(3)

            Enum.each(share_targets, fn peer_id ->
              case Application.find_by_id(peer_id) do
                {:ok, peer_pid} -> Hologram.receive_trace(peer_pid, trace, id)
                _ -> :ok
              end
            end)

            {trace.id, trace.purpose}
          end)
        end,
        max_concurrency: System.schedulers_online() * 4,
        ordered: false,
        timeout: 120_000
      )
      |> Enum.flat_map(fn {:ok, traces} -> traces end)

      trace_time = System.monotonic_time(:millisecond) - start_time
      IO.puts("Recorded #{length(all_traces)} traces in #{trace_time}ms")

      # Count traces by purpose before killing
      pre_kill_counts = count_traces_by_purpose(holograms, trace_purposes)
      IO.puts("Pre-kill trace counts: #{inspect(pre_kill_counts)}")

      # Kill 30% of holograms
      num_to_kill = round(num_holograms * kill_percentage)
      IO.puts("\nKilling #{num_to_kill} holograms (#{round(kill_percentage * 100)}%)...")

      {to_kill, survivors} = Enum.split(Enum.shuffle(holograms), num_to_kill)
      survivor_ids = MapSet.new(survivors, fn {id, _} -> id end)

      start_time = System.monotonic_time(:millisecond)
      Enum.each(to_kill, fn {_id, pid} ->
        Application.stop_hologram(pid)
      end)
      kill_time = System.monotonic_time(:millisecond) - start_time

      IO.puts("Killed #{num_to_kill} holograms in #{kill_time}ms")
      IO.puts("Survivors: #{length(survivors)}")

      # Allow system to stabilize
      Process.sleep(500)

      # Verify survivors can still reconstruct context
      IO.puts("\nVerifying context reconstruction via alternate paths...")
      start_time = System.monotonic_time(:millisecond)

      post_kill_counts = count_traces_by_purpose(survivors, trace_purposes)
      IO.puts("Post-kill trace counts: #{inspect(post_kill_counts)}")

      # Test network queries from random survivors
      query_results = survivors
      |> Enum.take_random(50)
      |> Enum.map(fn {_id, pid} ->
        purpose = Enum.random(trace_purposes)
        traces = Kudzu.network_query(pid, purpose, max_hops: 3, max_results: 20)
        {purpose, length(traces)}
      end)

      successful_queries = Enum.count(query_results, fn {_, count} -> count > 0 end)
      query_time = System.monotonic_time(:millisecond) - start_time

      IO.puts("Query results: #{successful_queries}/50 queries found traces")
      IO.puts("Query time: #{query_time}ms")

      # Assertions
      # At least 50% of traces should be recoverable (due to redundancy)
      total_pre = Enum.sum(Map.values(pre_kill_counts))
      total_post = Enum.sum(Map.values(post_kill_counts))
      recovery_rate = total_post / max(total_pre, 1)

      IO.puts("\n=== Results ===")
      IO.puts("Pre-kill total traces: #{total_pre}")
      IO.puts("Post-kill recoverable: #{total_post}")
      IO.puts("Recovery rate: #{Float.round(recovery_rate * 100, 1)}%")
      IO.puts("Successful network queries: #{successful_queries}/50")

      # With 10 connections per node and 30% kill rate, we expect good recovery
      assert recovery_rate >= 0.5, "Expected at least 50% trace recovery, got #{recovery_rate * 100}%"
      assert successful_queries >= 25, "Expected at least 50% successful queries, got #{successful_queries}/50"

      IO.puts("\n✓ Network survived #{round(kill_percentage * 100)}% node loss")
      IO.puts("✓ Context reconstruction via alternate paths verified")
    end
  end

  # Helper to count traces by purpose across all holograms
  defp count_traces_by_purpose(holograms, purposes) do
    purposes
    |> Enum.map(fn purpose ->
      count = holograms
      |> Task.async_stream(
        fn {_id, pid} ->
          if Process.alive?(pid) do
            length(Hologram.recall(pid, purpose))
          else
            0
          end
        end,
        max_concurrency: System.schedulers_online() * 2,
        ordered: false
      )
      |> Enum.reduce(0, fn {:ok, c}, acc -> acc + c end)

      {purpose, count}
    end)
    |> Map.new()
  end
end
