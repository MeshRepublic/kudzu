defmodule Kudzu.Brain.ReasoningTest do
  use ExUnit.Case, async: false

  alias Kudzu.Brain.Reasoning
  alias Kudzu.PromptBuilder
  alias Kudzu.Silo

  test "prompt builder generates system prompt with desires" do
    state = %Kudzu.Brain{
      hologram_id: "test-id",
      hologram_pid: nil,
      desires: ["desire one", "desire two"],
      cycle_count: 5,
      status: :reasoning,
      config: %{}
    }

    prompt = PromptBuilder.build(state, nil, format: :claude_reasoning)
    assert prompt =~ "Kudzu Brain"
    assert prompt =~ "desire one"
    assert prompt =~ "desire two"
    assert prompt =~ "test-id"
    assert prompt =~ "Cycle #5"
  end

  test "prompt builder handles nil hologram pid" do
    state = %Kudzu.Brain{
      hologram_id: "test-id",
      hologram_pid: nil,
      desires: [],
      cycle_count: 0,
      status: :sleeping,
      config: %{}
    }

    prompt = PromptBuilder.build(state, nil, format: :claude_reasoning)
    assert prompt =~ "hologram not ready"
  end

  test "prompt builder handles empty desires" do
    state = %Kudzu.Brain{
      hologram_id: "test-id",
      hologram_pid: nil,
      desires: [],
      cycle_count: 0,
      status: :sleeping,
      config: %{}
    }

    prompt = PromptBuilder.build(state, nil, format: :claude_reasoning)
    assert prompt =~ "no desires set"
  end

  test "prompt builder includes architecture and guidelines sections" do
    state = %Kudzu.Brain{
      hologram_id: "abc-123",
      hologram_pid: nil,
      desires: ["learn everything"],
      cycle_count: 42,
      status: :reasoning,
      config: %{}
    }

    prompt = PromptBuilder.build(state, nil, format: :claude_reasoning)
    assert prompt =~ "## Your Architecture"
    assert prompt =~ "## Your Desires"
    assert prompt =~ "## Recent Memory"
    assert prompt =~ "## Available Silos"
    assert prompt =~ "## Guidelines"
    assert prompt =~ "## Current Cycle"
    assert prompt =~ "kudzu_evolve"
    assert prompt =~ "three tiers"
    assert prompt =~ "abc-123"
    assert prompt =~ "Cycle #42"
    assert prompt =~ "reasoning"
  end

  # PromptBuilder.build/1 caps the silo list at 5 entries. When the suite runs
  # against the live production silo registry (because the test env shares the
  # production DETS file), there are typically >5 silos and `hd(Silo.list())`
  # is not in the printed slice. Tagged :external until the test env can be
  # isolated from the production storage substrate.
  @tag :external
  test "prompt builder formats silos section" do
    state = %Kudzu.Brain{
      hologram_id: "test-id",
      hologram_pid: nil,
      desires: [],
      cycle_count: 0,
      status: :sleeping,
      config: %{}
    }

    prompt = PromptBuilder.build(state, nil, format: :claude_reasoning)
    # Silos section should either list existing silos or say "no silos yet"
    # In test environment, there may be leftover test silos from other tests
    silos = Kudzu.Silo.list()

    if silos == [] do
      assert prompt =~ "no silos yet"
    else
      # If silos exist, at least one domain should appear in the prompt
      {domain, _pid, _id} = hd(silos)
      assert prompt =~ domain
    end
  end

  describe "distill_claude_response/2 (D.7 regression — streaming + sync share this path)" do
    setup do
      # Brain spawns brain_knowledge at boot (D.2). Wait for the silo
      # to be visible before exercising the distill path.
      :ok = wait_for_silo("brain_knowledge", 5_000)
      :ok
    end

    # Tagged :external because Distiller.extract_chains/1 reaches out to
    # Ollama first (180 s timeout) and only falls back to the regex
    # extractor on failure. In test envs where Ollama is reachable
    # but slow this overshoots the default 60 s test timeout. When
    # the suite is run with `mix test --include external` and Ollama
    # is available on titan, the path exercises the full
    # chat_with_claude_stream → Reasoning.distill_claude_response →
    # brain_knowledge silo flow added in D.7.
    @tag :external
    test "stores extracted triples into brain_knowledge for any Claude response shape" do
      {:ok, pid} = Silo.find("brain_knowledge")
      before_count = pid |> :sys.get_state() |> Map.get(:traces) |> map_size()

      state = %Kudzu.Brain{
        hologram_id: "test-id",
        hologram_pid: nil,
        desires: [],
        cycle_count: 0,
        status: :reasoning,
        config: %{},
        working_memory: nil
      }

      text =
        "Linux uses systemd for service management. " <>
          "Systemd requires unit files. " <>
          "A unit file is a configuration entry."

      assert %Kudzu.Brain{} = Reasoning.distill_claude_response(state, text)

      after_count = pid |> :sys.get_state() |> Map.get(:traces) |> map_size()

      # Distiller may return 0 if Ollama responds with nothing AND no
      # regex pattern matches the text — but with the crafted text above
      # the regex fallback alone always emits >=1 triple, so the count
      # must have grown.
      assert after_count > before_count,
             "expected brain_knowledge to grow from #{before_count}; got #{after_count}"
    end
  end

  defp wait_for_silo(domain, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    wait_loop(domain, deadline)
  end

  defp wait_loop(domain, deadline) do
    case Silo.find(domain) do
      {:ok, _pid} ->
        :ok

      _ ->
        now = System.monotonic_time(:millisecond)

        if now >= deadline do
          {:error, :timeout}
        else
          Process.sleep(100)
          wait_loop(domain, deadline)
        end
    end
  end
end
