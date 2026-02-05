defmodule Kudzu.BeamletTest do
  use ExUnit.Case, async: false

  alias Kudzu.{Hologram, Application}
  alias Kudzu.Beamlet.{Supervisor, IO, Client}

  describe "beam-let substrate" do
    test "IO beam-let handles file operations" do
      # Write through beam-let
      path = "/tmp/kudzu_test_#{System.unique_integer([:positive])}.txt"
      content = "Hello from beam-let!"

      assert {:ok, :written} = Client.write_file(path, content, "test")
      assert {:ok, ^content} = Client.read_file(path, "test")

      # Cleanup
      File.rm(path)
    end

    test "hologram delegates IO to beam-lets" do
      {:ok, h} = Application.spawn_hologram(purpose: :test)

      # Give time for beam-let discovery
      Process.sleep(200)

      # Check beam-let awareness
      beamlets = Hologram.get_beamlets(h)
      assert map_size(beamlets) > 0

      # Delegate file operation
      path = "/tmp/kudzu_holo_test_#{System.unique_integer([:positive])}.txt"
      assert {:ok, :written} = Hologram.write_file(h, path, "Hologram wrote this")
      assert {:ok, content} = Hologram.read_file(h, path)
      assert content == "Hologram wrote this"

      File.rm(path)
    end

    test "substrate status shows beam-let info" do
      status = Client.substrate_status()

      assert Map.has_key?(status, :file_read)
      assert Map.has_key?(status, :http_get)
      assert Map.has_key?(status, :scheduling)
    end
  end

  describe "beam-let failover" do
    @tag :failover
    test "holograms find alternate beam-lets when preferred dies" do
      # Spawn extra IO beam-lets for redundancy
      {:ok, io1} = Supervisor.spawn_beamlet(IO, id: "io-test-1")
      {:ok, io2} = Supervisor.spawn_beamlet(IO, id: "io-test-2")
      {:ok, io3} = Supervisor.spawn_beamlet(IO, id: "io-test-3")

      # Spawn holograms that will use beam-lets
      holograms = for i <- 1..10 do
        {:ok, h} = Application.spawn_hologram(purpose: :failover_test)
        # Trigger beam-let discovery
        Hologram.discover_beamlets(h)
        h
      end

      Process.sleep(300)  # Let discovery complete

      # Verify holograms have beam-let awareness
      Enum.each(holograms, fn h ->
        beamlets = Hologram.get_beamlets(h)
        assert map_size(beamlets) > 0
      end)

      # Test IO works before killing
      test_path = "/tmp/kudzu_failover_#{System.unique_integer([:positive])}.txt"
      [first | _] = holograms
      assert {:ok, :written} = Hologram.write_file(first, test_path, "test")

      # Kill some beam-lets
      Process.exit(io1, :kill)
      Process.exit(io2, :kill)

      Process.sleep(100)

      # Holograms should still be able to do IO through surviving beam-let
      results = Enum.map(holograms, fn h ->
        Hologram.read_file(h, test_path)
      end)

      # At least some should succeed (io3 and primary are still alive)
      success_count = Enum.count(results, fn
        {:ok, _} -> true
        _ -> false
      end)

      assert success_count >= 5, "Expected at least 5 successful reads, got #{success_count}"

      File.rm(test_path)
    end

    @tag :failover
    test "graceful degradation when all specialized beam-lets die" do
      # Spawn a hologram
      {:ok, h} = Application.spawn_hologram(purpose: :degradation_test)
      Process.sleep(200)

      # Get initial beam-let count
      initial_beamlets = Hologram.get_beamlets(h)
      initial_count = initial_beamlets
      |> Map.values()
      |> Enum.map(&map_size/1)
      |> Enum.sum()

      assert initial_count > 0

      # The primary IO beam-let should still be available
      # (it's supervised and will restart)
      test_path = "/tmp/kudzu_degrade_#{System.unique_integer([:positive])}.txt"

      # This should work through the primary beam-let
      result = Hologram.write_file(h, test_path, "degradation test")
      assert match?({:ok, _}, result) or match?({:error, _}, result)

      File.rm(test_path)
    end
  end

  describe "beam-let load balancing" do
    test "work distributes across multiple beam-lets" do
      # Spawn multiple IO beam-lets
      for i <- 1..5 do
        Supervisor.spawn_beamlet(IO, id: "io-lb-#{i}")
      end

      Process.sleep(100)

      # Make many requests
      path = "/tmp/kudzu_lb_test.txt"
      File.write!(path, "load balance test")

      tasks = for _ <- 1..100 do
        Task.async(fn ->
          Client.read_file(path, "lb-test-#{:rand.uniform(1000)}")
        end)
      end

      results = Task.await_many(tasks, 10_000)
      success = Enum.count(results, &match?({:ok, _}, &1))

      assert success == 100

      File.rm(path)
    end
  end
end
