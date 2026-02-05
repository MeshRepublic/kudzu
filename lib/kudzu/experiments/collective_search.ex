defmodule Kudzu.Experiments.CollectiveSearch do
  @moduledoc """
  Experiment: Collective information search with cognitive holograms.

  Creates a network of holograms with distributed knowledge, gives them
  a collective task, and observes emergent coordination behavior.
  """

  alias Kudzu.{Hologram, Application}

  @doc """
  Run the collective search experiment.

  ## Options
    - :num_holograms - number of holograms (default 100)
    - :connections - connections per hologram (default 5)
    - :model - Ollama model to use (default "llama3.2:3b")
    - :target - what to search for
    - :knowledge - list of {hologram_index, fact} tuples to distribute
  """
  def run(opts \\ []) do
    num_holograms = Keyword.get(opts, :num_holograms, 100)
    connections = Keyword.get(opts, :connections, 5)
    model = Keyword.get(opts, :model, "llama3.2:3b")
    target = Keyword.get(opts, :target, "the secret code")

    # Default distributed knowledge
    knowledge = Keyword.get(opts, :knowledge, [
      {0, "The secret code starts with 'K'"},
      {25, "The second letter of the secret code is 'U'"},
      {50, "The third letter is 'D'"},
      {75, "The fourth letter is 'Z'"},
      {99, "The secret code ends with 'U'"}
    ])

    IO.puts("\n=== Collective Search Experiment ===")
    IO.puts("Holograms: #{num_holograms}")
    IO.puts("Model: #{model}")
    IO.puts("Target: #{target}")

    # Check Ollama availability
    IO.puts("\nChecking Ollama...")
    unless Kudzu.Cognition.available?() do
      IO.puts("ERROR: Ollama not available at localhost:11434")
      IO.puts("Start Ollama with: ollama serve")
      {:error, :ollama_unavailable}
    else
      IO.puts("Ollama available")
      do_run(num_holograms, connections, model, target, knowledge)
    end
  end

  defp do_run(num_holograms, connections, model, target, knowledge) do
    # Spawn holograms with cognition enabled
    IO.puts("\nSpawning #{num_holograms} cognitive holograms...")
    start_time = System.monotonic_time(:millisecond)

    holograms = 1..num_holograms
    |> Enum.map(fn i ->
      {:ok, pid} = Application.spawn_hologram(
        purpose: :collective_search,
        cognition: true,
        model: model,
        desires: ["Find information about: #{target}", "Share relevant findings with peers"]
      )
      id = Hologram.get_id(pid)
      {i - 1, id, pid}
    end)

    spawn_time = System.monotonic_time(:millisecond) - start_time
    IO.puts("Spawned in #{spawn_time}ms")

    # Create peer connections
    IO.puts("Creating peer network...")
    holograms
    |> Enum.each(fn {_idx, _id, pid} ->
      peers = holograms
      |> Enum.reject(fn {_, _, p} -> p == pid end)
      |> Enum.take_random(connections)

      Enum.each(peers, fn {_, peer_id, _} ->
        Hologram.introduce_peer(pid, peer_id)
      end)
    end)

    # Distribute knowledge
    IO.puts("Distributing knowledge fragments...")
    knowledge
    |> Enum.each(fn {idx, fact} ->
      {_, _, pid} = Enum.at(holograms, idx)
      Hologram.record_trace(pid, :knowledge, %{fact: fact, about: "secret_code"})
      IO.puts("  Hologram #{idx}: \"#{fact}\"")
    end)

    # Give them time to settle
    Process.sleep(500)

    # Trigger the search from a random hologram
    {seeker_idx, seeker_id, seeker_pid} = Enum.random(holograms)
    IO.puts("\nTriggering search from hologram #{seeker_idx} (#{seeker_id})...")

    # Stimulate the seeker
    stimulus = """
    You need to find: #{target}
    This information is distributed across the network.
    Query your peers, gather fragments, and piece together the answer.
    Share what you find with others who might need it.
    """

    IO.puts("\nSending stimulus to seeker...")
    case Hologram.stimulate(seeker_pid, stimulus) do
      {:ok, response, actions} ->
        IO.puts("\n--- Seeker Response ---")
        IO.puts(response)
        IO.puts("\n--- Actions Taken ---")
        Enum.each(actions, fn action ->
          IO.puts("  #{inspect(action)}")
        end)

      {:error, reason} ->
        IO.puts("Cognition failed: #{inspect(reason)}")
    end

    # Let the network process for a bit
    IO.puts("\nLetting network process (5 seconds)...")
    Process.sleep(5000)

    # Check what knowledge has propagated
    IO.puts("\n--- Knowledge Distribution After Search ---")
    sample = Enum.take_random(holograms, 10)
    Enum.each(sample, fn {idx, id, pid} ->
      traces = Hologram.recall(pid, :knowledge)
      facts = Enum.map(traces, fn t -> t.reconstruction_hint[:fact] end)
      IO.puts("Hologram #{idx} (#{String.slice(id, 0, 8)}): #{length(traces)} knowledge traces")
      Enum.each(facts, fn f -> IO.puts("    - #{f}") end)
    end)

    # Return the network for further experimentation
    {:ok, holograms}
  end

  @doc """
  Run a simpler test with just a few holograms to verify cognition works.
  """
  def test_cognition(model \\ "llama3.2:3b") do
    IO.puts("\n=== Testing Hologram Cognition ===")

    unless Kudzu.Cognition.available?() do
      IO.puts("ERROR: Ollama not available")
      {:error, :ollama_unavailable}
    else
      {:ok, h} = Application.spawn_hologram(
        purpose: :test,
        cognition: true,
        model: model,
        desires: ["Learn and remember new information"]
      )

      # Record some traces
      Hologram.record_trace(h, :memory, %{content: "The sky is blue"})
      Hologram.record_trace(h, :memory, %{content: "Water is wet"})

      IO.puts("Created hologram with 2 memories")
      IO.puts("Sending stimulus...")

      case Hologram.stimulate(h, "What do you know? Summarize your memories.") do
        {:ok, response, actions} ->
          IO.puts("\n--- Response ---")
          IO.puts(response)
          IO.puts("\n--- Actions ---")
          Enum.each(actions, &IO.puts("  #{inspect(&1)}"))
          {:ok, response}

        {:error, reason} ->
          IO.puts("Error: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  @doc """
  Broadcast a stimulus to all cognitive holograms.
  """
  def broadcast_stimulus(holograms, stimulus) do
    IO.puts("Broadcasting stimulus to #{length(holograms)} holograms...")

    holograms
    |> Task.async_stream(
      fn {_idx, _id, pid} ->
        Hologram.stimulate_async(pid, stimulus)
      end,
      max_concurrency: 20,
      ordered: false
    )
    |> Stream.run()

    IO.puts("Stimulus broadcast complete")
  end
end
