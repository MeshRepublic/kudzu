# Kudzu Thinking Layer Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a pure Elixir reasoning engine that wraps all existing tiers, enabling the Kudzu Brain to think through spreading activation, chaining, parallel exploration, self-directed curiosity, and automatic distillation — without depending on external LLMs.

**Architecture:** The Brain GenServer (the Monarch) is the singular persistent self. It spawns ephemeral Thought processes that activate concepts across silos, chain reasoning, fill gaps via web search, and report back. Working Memory holds the monarch's current attention. Curiosity generates questions from desires. The Distiller extracts Claude responses into reflexes and silo knowledge.

**Tech Stack:** Elixir/OTP, HRR vectors, :httpc for web fetch, SearXNG for web search (self-hosted on titan), existing Kudzu silo/consolidation infrastructure.

**Codebase:** `/home/eel/kudzu_src/` on titan (access via `ssh titan`).

**Running tests:** `ssh titan "cd /home/eel/kudzu_src && mix test path/to/test.exs --trace"` (use `--trace` for verbose, `--include integration` for integration-tagged tests).

**Compiling:** `ssh titan "cd /home/eel/kudzu_src && mix compile --warnings-as-errors"`

---

### Task 1: Working Memory Module

The monarch's bounded attention buffer. Pure data structure with helper functions — no GenServer, lives inside Brain state.

**Files:**
- Create: `lib/kudzu/brain/working_memory.ex`
- Test: `test/kudzu/brain/working_memory_test.exs`

**Step 1: Write the failing tests**

```elixir
# test/kudzu/brain/working_memory_test.exs
defmodule Kudzu.Brain.WorkingMemoryTest do
  use ExUnit.Case, async: true

  alias Kudzu.Brain.WorkingMemory

  test "new/0 creates empty working memory" do
    wm = WorkingMemory.new()
    assert wm.active_concepts == %{}
    assert wm.recent_chains == []
    assert wm.pending_questions == []
    assert wm.context == nil
  end

  test "activate/3 adds a concept with score and source" do
    wm = WorkingMemory.new()
    wm = WorkingMemory.activate(wm, "disk_pressure", %{score: 0.8, source: "health_silo"})
    assert Map.has_key?(wm.active_concepts, "disk_pressure")
    assert wm.active_concepts["disk_pressure"].score == 0.8
  end

  test "activate/3 reinforces existing concept (score increases)" do
    wm = WorkingMemory.new()
    wm = WorkingMemory.activate(wm, "disk", %{score: 0.5, source: "silo_a"})
    wm = WorkingMemory.activate(wm, "disk", %{score: 0.7, source: "silo_b"})
    assert wm.active_concepts["disk"].score > 0.5
  end

  test "activate/3 evicts lowest-scored concept when at max capacity" do
    wm = WorkingMemory.new(max_concepts: 3)
    wm = WorkingMemory.activate(wm, "a", %{score: 0.3, source: "s"})
    wm = WorkingMemory.activate(wm, "b", %{score: 0.5, source: "s"})
    wm = WorkingMemory.activate(wm, "c", %{score: 0.7, source: "s"})
    wm = WorkingMemory.activate(wm, "d", %{score: 0.9, source: "s"})
    refute Map.has_key?(wm.active_concepts, "a")
    assert Map.has_key?(wm.active_concepts, "d")
    assert map_size(wm.active_concepts) == 3
  end

  test "decay/2 reduces all concept scores" do
    wm = WorkingMemory.new()
    wm = WorkingMemory.activate(wm, "disk", %{score: 0.8, source: "s"})
    wm = WorkingMemory.decay(wm, 0.1)
    assert wm.active_concepts["disk"].score == 0.7
  end

  test "decay/2 removes concepts that fall below threshold" do
    wm = WorkingMemory.new(eviction_threshold: 0.2)
    wm = WorkingMemory.activate(wm, "fading", %{score: 0.25, source: "s"})
    wm = WorkingMemory.decay(wm, 0.1)
    refute Map.has_key?(wm.active_concepts, "fading")
  end

  test "add_chain/2 records a completed reasoning chain" do
    wm = WorkingMemory.new()
    chain = [%{concept: "disk", score: 0.8}, %{concept: "storage", score: 0.7}]
    wm = WorkingMemory.add_chain(wm, chain)
    assert length(wm.recent_chains) == 1
  end

  test "add_chain/2 evicts oldest chain when at max" do
    wm = WorkingMemory.new(max_chains: 2)
    wm = WorkingMemory.add_chain(wm, [%{concept: "a"}])
    wm = WorkingMemory.add_chain(wm, [%{concept: "b"}])
    wm = WorkingMemory.add_chain(wm, [%{concept: "c"}])
    assert length(wm.recent_chains) == 2
    concepts = wm.recent_chains |> Enum.flat_map(fn chain -> Enum.map(chain, & &1.concept) end)
    refute "a" in concepts
  end

  test "add_question/2 adds a pending question" do
    wm = WorkingMemory.new()
    wm = WorkingMemory.add_question(wm, "Why is disk high?")
    assert "Why is disk high?" in wm.pending_questions
  end

  test "pop_question/1 returns and removes first question" do
    wm = WorkingMemory.new()
    wm = WorkingMemory.add_question(wm, "Q1")
    wm = WorkingMemory.add_question(wm, "Q2")
    {question, wm} = WorkingMemory.pop_question(wm)
    assert question == "Q1"
    assert length(wm.pending_questions) == 1
  end

  test "pop_question/1 returns nil when empty" do
    wm = WorkingMemory.new()
    {question, _wm} = WorkingMemory.pop_question(wm)
    assert question == nil
  end

  test "get_priming_concepts/1 returns top active concepts for thought biasing" do
    wm = WorkingMemory.new()
    wm = WorkingMemory.activate(wm, "disk", %{score: 0.9, source: "s"})
    wm = WorkingMemory.activate(wm, "storage", %{score: 0.3, source: "s"})
    wm = WorkingMemory.activate(wm, "consolidation", %{score: 0.7, source: "s"})
    priming = WorkingMemory.get_priming_concepts(wm, 2)
    assert length(priming) == 2
    assert hd(priming) == "disk"
  end
end
```

**Step 2: Run tests to verify they fail**

Run: `ssh titan "cd /home/eel/kudzu_src && mix test test/kudzu/brain/working_memory_test.exs --trace"`
Expected: FAIL — module `Kudzu.Brain.WorkingMemory` not found

**Step 3: Implement WorkingMemory**

```elixir
# lib/kudzu/brain/working_memory.ex
defmodule Kudzu.Brain.WorkingMemory do
  @moduledoc """
  The Monarch's bounded attention buffer.

  Holds currently active concepts, recent reasoning chains, and pending questions.
  Lives inside the Brain GenServer state — not a separate process.
  Concepts decay over time and get evicted when they fall below threshold
  or when capacity is exceeded. Evicted concepts become traces.
  """

  defstruct [
    active_concepts: %{},     # %{concept => %{score, source, timestamp}}
    recent_chains: [],        # [chain] where chain is [%{concept, score, ...}]
    pending_questions: [],    # [question_string]
    context: nil,             # current focus area atom/string
    max_concepts: 20,
    max_chains: 10,
    max_questions: 5,
    eviction_threshold: 0.1
  ]

  @doc "Create a new empty working memory with optional bounds."
  def new(opts \\ []) do
    %__MODULE__{
      max_concepts: Keyword.get(opts, :max_concepts, 20),
      max_chains: Keyword.get(opts, :max_chains, 10),
      max_questions: Keyword.get(opts, :max_questions, 5),
      eviction_threshold: Keyword.get(opts, :eviction_threshold, 0.1)
    }
  end

  @doc """
  Activate a concept in working memory.

  If the concept exists, reinforces it (takes the max score).
  If at capacity, evicts the lowest-scored concept.
  """
  def activate(%__MODULE__{} = wm, concept, %{score: score, source: source}) do
    entry = %{
      score: score,
      source: source,
      timestamp: System.monotonic_time(:millisecond)
    }

    updated = case Map.get(wm.active_concepts, concept) do
      nil ->
        Map.put(wm.active_concepts, concept, entry)
      existing ->
        Map.put(wm.active_concepts, concept, %{entry | score: max(existing.score, score)})
    end

    wm = %{wm | active_concepts: updated}
    enforce_concept_limit(wm)
  end

  @doc "Decay all concept scores by the given amount. Remove concepts below threshold."
  def decay(%__MODULE__{} = wm, amount) do
    updated = wm.active_concepts
    |> Enum.map(fn {concept, entry} -> {concept, %{entry | score: entry.score - amount}} end)
    |> Enum.filter(fn {_concept, entry} -> entry.score >= wm.eviction_threshold end)
    |> Map.new()

    %{wm | active_concepts: updated}
  end

  @doc "Record a completed reasoning chain."
  def add_chain(%__MODULE__{} = wm, chain) do
    chains = [chain | wm.recent_chains] |> Enum.take(wm.max_chains)
    %{wm | recent_chains: chains}
  end

  @doc "Add a question to the pending queue."
  def add_question(%__MODULE__{} = wm, question) do
    questions = (wm.pending_questions ++ [question]) |> Enum.take(wm.max_questions)
    %{wm | pending_questions: questions}
  end

  @doc "Pop the first pending question. Returns {question | nil, updated_wm}."
  def pop_question(%__MODULE__{pending_questions: []} = wm), do: {nil, wm}
  def pop_question(%__MODULE__{pending_questions: [q | rest]} = wm) do
    {q, %{wm | pending_questions: rest}}
  end

  @doc "Get top N active concepts by score, for biasing future thoughts."
  def get_priming_concepts(%__MODULE__{} = wm, n \\ 5) do
    wm.active_concepts
    |> Enum.sort_by(fn {_concept, entry} -> entry.score end, :desc)
    |> Enum.take(n)
    |> Enum.map(fn {concept, _entry} -> concept end)
  end

  defp enforce_concept_limit(%__MODULE__{} = wm) do
    if map_size(wm.active_concepts) > wm.max_concepts do
      {lowest_concept, _entry} = wm.active_concepts
      |> Enum.min_by(fn {_c, e} -> e.score end)

      %{wm | active_concepts: Map.delete(wm.active_concepts, lowest_concept)}
    else
      wm
    end
  end
end
```

**Step 4: Run tests to verify they pass**

Run: `ssh titan "cd /home/eel/kudzu_src && mix test test/kudzu/brain/working_memory_test.exs --trace"`
Expected: All 13 tests pass

**Step 5: Commit**

```bash
ssh titan "cd /home/eel/kudzu_src && git add lib/kudzu/brain/working_memory.ex test/kudzu/brain/working_memory_test.exs && git commit -m 'feat: add WorkingMemory — monarch attention buffer'"
```

---

### Task 2: Thought Process — Core Structure and Activation

The ephemeral reasoning process. This task implements the struct, spawning, silo activation (step 1 of reasoning), and reporting back to the monarch.

**Files:**
- Create: `lib/kudzu/brain/thought.ex`
- Test: `test/kudzu/brain/thought_test.exs`

**Step 1: Write the failing tests**

```elixir
# test/kudzu/brain/thought_test.exs
defmodule Kudzu.Brain.ThoughtTest do
  use ExUnit.Case, async: false

  alias Kudzu.Brain.Thought

  # Need a silo with some data for activation tests
  setup do
    # Create a test silo with known relationships
    {:ok, _pid} = Kudzu.Silo.create("test_thought_#{:rand.uniform(999999)}")
    domain = "test_thought_#{:rand.uniform(999999)}"
    {:ok, _pid} = Kudzu.Silo.create(domain)
    Kudzu.Silo.store_relationship(domain, {"disk_pressure", "caused_by", "large_files"})
    Kudzu.Silo.store_relationship(domain, {"large_files", "produced_by", "consolidation"})
    Kudzu.Silo.store_relationship(domain, {"consolidation", "creates", "temp_files"})
    Process.sleep(100)
    %{domain: domain}
  end

  test "run/2 returns a result to the caller" do
    result = Thought.run("test concept", monarch_pid: self(), timeout: 5_000)
    assert %Thought.Result{} = result
    assert is_list(result.chain)
    assert is_float(result.confidence)
    assert result.input == "test concept"
  end

  test "run/2 activates concepts from silos", %{domain: _domain} do
    result = Thought.run("disk_pressure", monarch_pid: self(), timeout: 5_000)
    assert length(result.activations) >= 0
    # Activations are [{concept, similarity, domain}]
  end

  test "run/2 respects timeout" do
    result = Thought.run("anything", monarch_pid: self(), timeout: 100)
    assert %Thought.Result{} = result
    # Should return whatever it found within timeout, not crash
  end

  test "run/2 respects max_depth" do
    result = Thought.run("disk_pressure",
      monarch_pid: self(),
      max_depth: 0,
      timeout: 5_000
    )
    assert %Thought.Result{} = result
    # With max_depth 0, no sub-thoughts should be spawned
    assert result.depth == 0
  end

  test "async_run/2 sends {:thought_result, id, result} to monarch" do
    {:ok, thought_id} = Thought.async_run("test concept",
      monarch_pid: self(),
      timeout: 5_000
    )
    assert is_binary(thought_id)

    assert_receive {:thought_result, ^thought_id, %Thought.Result{}}, 6_000
  end
end
```

**Step 2: Run tests to verify they fail**

Run: `ssh titan "cd /home/eel/kudzu_src && mix test test/kudzu/brain/thought_test.exs --trace"`
Expected: FAIL — module `Kudzu.Brain.Thought` not found

**Step 3: Implement Thought — struct, run, activation**

```elixir
# lib/kudzu/brain/thought.ex
defmodule Kudzu.Brain.Thought do
  @moduledoc """
  The universal unit of reasoning. Ephemeral process.

  Spawned by the Monarch, activates concepts across silos via HRR similarity,
  chains reasoning, spawns sub-thoughts if needed, and reports back.
  Same shape at every depth — fractal self-similarity.
  """

  require Logger

  alias Kudzu.Brain.InferenceEngine
  alias Kudzu.Silo

  @default_max_depth 3
  @default_max_breadth 5
  @default_timeout 5_000
  @activation_threshold 0.3

  defmodule Result do
    @moduledoc "The result of a thought process."
    defstruct [
      :id,
      :input,
      :depth,
      chain: [],           # [{concept, similarity, source_domain}]
      activations: [],     # [{concept, similarity, domain}]
      confidence: 0.0,     # overall confidence in the result
      resolution: nil,     # :found | :partial | :no_match | :timeout
      sub_results: []      # results from sub-thoughts
    ]
  end

  @doc """
  Run a thought synchronously. Returns a Result.

  Options:
    - :monarch_pid — PID to report to (required for async, optional for sync)
    - :max_depth — max sub-thought nesting (default 3)
    - :max_breadth — max activations per step (default 5)
    - :timeout — ms before giving up (default 5000)
    - :depth — current depth in fractal (default 0, set by sub-thoughts)
    - :priming — list of concepts from working memory to bias activation
  """
  def run(input, opts \\ []) do
    id = generate_id()
    depth = Keyword.get(opts, :depth, 0)
    max_depth = Keyword.get(opts, :max_depth, @default_max_depth)
    max_breadth = Keyword.get(opts, :max_breadth, @default_max_breadth)
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    priming = Keyword.get(opts, :priming, [])

    task = Task.async(fn ->
      think(id, input, depth, max_depth, max_breadth, priming)
    end)

    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, result} -> result
      nil ->
        Logger.debug("[Thought #{id}] Timed out at depth #{depth}")
        %Result{id: id, input: input, depth: depth, resolution: :timeout}
    end
  end

  @doc """
  Run a thought asynchronously. Sends {:thought_result, id, Result} to monarch_pid.
  Returns {:ok, thought_id}.
  """
  def async_run(input, opts \\ []) do
    monarch_pid = Keyword.fetch!(opts, :monarch_pid)
    id = generate_id()

    Task.start(fn ->
      result = run(input, Keyword.put(opts, :depth, 0))
      result = %{result | id: id}
      send(monarch_pid, {:thought_result, id, result})
    end)

    {:ok, id}
  end

  # --- Private: The thinking process ---

  defp think(id, input, depth, max_depth, max_breadth, priming) do
    # Step 1: Activate — find related concepts across all silos
    activations = activate(input, priming, max_breadth)

    # Step 2: Chain — follow activation trail
    chain = build_chain(input, activations, depth, max_depth, max_breadth)

    # Step 3: Evaluate
    confidence = evaluate_chain(chain)
    resolution = cond do
      confidence > 0.6 -> :found
      confidence > 0.3 -> :partial
      true -> :no_match
    end

    %Result{
      id: id,
      input: input,
      depth: depth,
      chain: chain,
      activations: activations,
      confidence: confidence,
      resolution: resolution
    }
  end

  defp activate(input, priming, max_breadth) do
    # Extract key terms from input
    terms = extract_terms(input)

    # Cross-query all silos for each term
    all_activations = (terms ++ priming)
    |> Enum.flat_map(fn term ->
      InferenceEngine.cross_query(term)
      |> Enum.map(fn {domain, hint, score} ->
        concept = hint[:subject] || hint["subject"] || to_string(term)
        {concept, score, domain}
      end)
    end)
    |> Enum.uniq_by(fn {concept, _score, _domain} -> concept end)
    |> Enum.filter(fn {_concept, score, _domain} -> score >= @activation_threshold end)
    |> Enum.sort_by(fn {_concept, score, _domain} -> score end, :desc)
    |> Enum.take(max_breadth)

    all_activations
  end

  defp build_chain(input, activations, depth, max_depth, max_breadth) do
    # Start chain with the input concept
    initial = [{input, 1.0, "query"}]

    # Add each activation to the chain, following links
    chain = Enum.reduce(activations, initial, fn {concept, score, domain}, chain ->
      link = %{concept: concept, similarity: score, source: domain}
      chain ++ [link]
    end)

    # If depth allows, spawn sub-thoughts for the strongest activation
    chain = if depth < max_depth and length(activations) > 0 do
      {top_concept, _score, _domain} = hd(activations)
      sub_result = run(top_concept,
        depth: depth + 1,
        max_depth: max_depth,
        max_breadth: max(max_breadth - 1, 2),
        timeout: 2_000
      )

      if sub_result.resolution in [:found, :partial] do
        chain ++ Enum.map(sub_result.chain, fn
          {concept, score, source} -> %{concept: concept, similarity: score, source: source}
          %{} = link -> link
          other -> %{concept: to_string(other), similarity: 0.0, source: "sub_thought"}
        end)
      else
        chain
      end
    else
      chain
    end

    chain
  end

  defp evaluate_chain(chain) do
    if length(chain) <= 1 do
      0.0
    else
      scores = chain
      |> Enum.map(fn
        {_concept, score, _source} -> score
        %{similarity: score} -> score
        _ -> 0.0
      end)
      |> Enum.filter(& &1 > 0)

      if length(scores) == 0 do
        0.0
      else
        # Average similarity, weighted by chain length (longer chains = more confident if all links are strong)
        avg = Enum.sum(scores) / length(scores)
        length_bonus = min(length(scores) / 5.0, 0.2)
        min(avg + length_bonus, 1.0)
      end
    end
  end

  defp extract_terms(input) when is_binary(input) do
    input
    |> String.downcase()
    |> String.replace(~r/[^\w\s]/, "")
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reject(fn term -> term in ~w(the a an is are was were be been being have has had do does did will would shall should may might can could what why how when where who which that this these those) end)
    |> Enum.uniq()
  end

  defp extract_terms(input), do: [to_string(input)]

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
```

**Step 4: Run tests to verify they pass**

Run: `ssh titan "cd /home/eel/kudzu_src && mix test test/kudzu/brain/thought_test.exs --trace"`
Expected: All 5 tests pass

**Step 5: Commit**

```bash
ssh titan "cd /home/eel/kudzu_src && git add lib/kudzu/brain/thought.ex test/kudzu/brain/thought_test.exs && git commit -m 'feat: add Thought process — ephemeral fractal reasoning'"
```

---

### Task 3: Curiosity Engine

Generates questions from desires and knowledge gaps when the external query queue is empty.

**Files:**
- Create: `lib/kudzu/brain/curiosity.ex`
- Test: `test/kudzu/brain/curiosity_test.exs`

**Step 1: Write the failing tests**

```elixir
# test/kudzu/brain/curiosity_test.exs
defmodule Kudzu.Brain.CuriosityTest do
  use ExUnit.Case, async: true

  alias Kudzu.Brain.Curiosity
  alias Kudzu.Brain.WorkingMemory

  @desires [
    "Maintain Kudzu system health and recover from failures",
    "Build accurate self-model of architecture, resources, and capabilities",
    "Learn from every observation — discover patterns in system behavior"
  ]

  test "generate_from_desires/2 produces questions from desires" do
    silos = ["self", "health"]
    questions = Curiosity.generate_from_desires(@desires, silos)
    assert is_list(questions)
    assert length(questions) > 0
    assert Enum.all?(questions, &is_binary/1)
  end

  test "generate_from_desires/2 produces different questions for different silo states" do
    q1 = Curiosity.generate_from_desires(@desires, [])
    q2 = Curiosity.generate_from_desires(@desires, ["self", "health", "architecture"])
    # With more silos, questions should be more specific or different
    assert q1 != q2
  end

  test "generate_from_gaps/1 produces questions from working memory dead ends" do
    wm = WorkingMemory.new()
    # Simulate a chain that ended with no_match
    wm = WorkingMemory.add_chain(wm, [
      %{concept: "disk_pressure", similarity: 0.8, source: "health"},
      %{concept: "unknown_cause", similarity: 0.0, source: "dead_end"}
    ])
    questions = Curiosity.generate_from_gaps(wm)
    assert is_list(questions)
  end

  test "generate_from_salience/1 produces questions from unexplored high-salience traces" do
    # This queries real traces, so just test the interface
    questions = Curiosity.generate_from_salience(5)
    assert is_list(questions)
  end

  test "generate/3 combines all sources and returns prioritized questions" do
    wm = WorkingMemory.new()
    silos = ["self"]
    questions = Curiosity.generate(@desires, wm, silos)
    assert is_list(questions)
    assert length(questions) <= 5
  end
end
```

**Step 2: Run tests to verify they fail**

Run: `ssh titan "cd /home/eel/kudzu_src && mix test test/kudzu/brain/curiosity_test.exs --trace"`
Expected: FAIL — module not found

**Step 3: Implement Curiosity**

```elixir
# lib/kudzu/brain/curiosity.ex
defmodule Kudzu.Brain.Curiosity do
  @moduledoc """
  Generates questions when no one is asking.

  Three sources of curiosity:
  1. Desire-driven — desires imply knowledge gaps
  2. Gap-driven — working memory dead ends become questions
  3. Salience-driven — unexplored high-salience traces
  """

  alias Kudzu.Brain.WorkingMemory

  @max_questions 5

  # Maps desire themes to question templates.
  # Each desire gets decomposed into exploratory questions
  # based on what silos exist (what's already known).
  @desire_themes %{
    "health" => [
      "What is the current system health status?",
      "What failures have occurred recently?",
      "What recovery actions are available?"
    ],
    "self-model" => [
      "What components make up my architecture?",
      "What are my resource limits?",
      "What capabilities do I have?"
    ],
    "learn" => [
      "What patterns have I observed recently?",
      "What recurring events should I understand better?",
      "What knowledge domains am I weakest in?"
    ],
    "fault tolerance" => [
      "How can I recover from failures automatically?",
      "What single points of failure exist?",
      "What redundancy do I have?"
    ],
    "knowledge gaps" => [
      "What concepts have I encountered but don't understand?",
      "What domains have no expertise silo yet?",
      "What questions have I failed to answer?"
    ]
  }

  @doc """
  Generate questions from all sources, prioritized and deduplicated.
  Returns up to max_questions.
  """
  def generate(desires, %WorkingMemory{} = wm, silo_domains) do
    desire_qs = generate_from_desires(desires, silo_domains)
    gap_qs = generate_from_gaps(wm)
    salience_qs = generate_from_salience(@max_questions)

    (gap_qs ++ desire_qs ++ salience_qs)
    |> Enum.uniq()
    |> Enum.take(@max_questions)
  end

  @doc """
  Generate questions from desires based on what silos exist.
  Desires that map to existing silos get more specific questions;
  desires with no silo coverage get broad exploratory questions.
  """
  def generate_from_desires(desires, silo_domains) do
    desires
    |> Enum.flat_map(fn desire ->
      theme = classify_desire(desire)
      templates = Map.get(@desire_themes, theme, [])

      if has_silo_coverage?(theme, silo_domains) do
        # Already have some knowledge — ask deeper questions
        templates
        |> Enum.drop(1)
        |> Enum.take(1)
      else
        # No coverage — ask basic questions
        Enum.take(templates, 1)
      end
    end)
    |> Enum.uniq()
  end

  @doc """
  Generate questions from working memory dead ends.
  Chains that ended with low-confidence or unresolved concepts become questions.
  """
  def generate_from_gaps(%WorkingMemory{recent_chains: chains}) do
    chains
    |> Enum.flat_map(fn chain ->
      chain
      |> Enum.filter(fn
        %{similarity: score} when score < 0.2 -> true
        %{source: "dead_end"} -> true
        _ -> false
      end)
      |> Enum.map(fn
        %{concept: concept} -> "What is #{concept}?"
        _ -> nil
      end)
      |> Enum.reject(&is_nil/1)
    end)
    |> Enum.uniq()
  end

  @doc """
  Generate questions from high-salience unexplored traces.
  """
  def generate_from_salience(limit) do
    try do
      state = Kudzu.Consolidation.stats()
      if state[:traces_processed] && state[:traces_processed] > 0 do
        # Query recent observation traces that haven't been reasoned about
        Kudzu.Consolidation.semantic_query("important unresolved", 0.3)
        |> Enum.take(limit)
        |> Enum.map(fn {purpose, _score} -> "What does #{purpose} tell me?" end)
      else
        []
      end
    rescue
      _ -> []
    catch
      :exit, _ -> []
    end
  end

  defp classify_desire(desire) do
    desire_lower = String.downcase(desire)
    cond do
      String.contains?(desire_lower, "health") or String.contains?(desire_lower, "recover") ->
        "health"
      String.contains?(desire_lower, "self-model") or String.contains?(desire_lower, "architecture") ->
        "self-model"
      String.contains?(desire_lower, "learn") or String.contains?(desire_lower, "pattern") ->
        "learn"
      String.contains?(desire_lower, "fault") or String.contains?(desire_lower, "distributed") ->
        "fault tolerance"
      true ->
        "knowledge gaps"
    end
  end

  defp has_silo_coverage?(theme, silo_domains) do
    domain_set = MapSet.new(silo_domains |> Enum.map(&String.downcase/1))
    case theme do
      "health" -> MapSet.member?(domain_set, "health")
      "self-model" -> MapSet.member?(domain_set, "self")
      "learn" -> MapSet.member?(domain_set, "learning") or MapSet.member?(domain_set, "patterns")
      "fault tolerance" -> MapSet.member?(domain_set, "fault_tolerance")
      _ -> false
    end
  end
end
```

**Step 4: Run tests to verify they pass**

Run: `ssh titan "cd /home/eel/kudzu_src && mix test test/kudzu/brain/curiosity_test.exs --trace"`
Expected: All 5 tests pass

**Step 5: Commit**

```bash
ssh titan "cd /home/eel/kudzu_src && git add lib/kudzu/brain/curiosity.ex test/kudzu/brain/curiosity_test.exs && git commit -m 'feat: add Curiosity engine — self-directed question generation'"
```

---

### Task 4: Distiller — Claude Response Extraction

Extracts Claude reasoning into silo knowledge and reflex candidates.

**Files:**
- Create: `lib/kudzu/brain/distiller.ex`
- Test: `test/kudzu/brain/distiller_test.exs`

**Step 1: Write the failing tests**

```elixir
# test/kudzu/brain/distiller_test.exs
defmodule Kudzu.Brain.DistillerTest do
  use ExUnit.Case, async: true

  alias Kudzu.Brain.Distiller

  test "extract_chains/1 extracts causal relationships from text" do
    text = "The disk pressure is high because consolidation produces temporary files."
    chains = Distiller.extract_chains(text)
    assert is_list(chains)
    assert length(chains) >= 1
    assert Enum.any?(chains, fn {_s, r, _o} -> r in ["causes", "caused_by", "because"] end)
  end

  test "extract_chains/1 handles multiple sentences" do
    text = """
    Storage is running low because of large log files.
    The log rotation requires a cron job.
    Consolidation uses temporary disk space.
    """
    chains = Distiller.extract_chains(text)
    assert length(chains) >= 2
  end

  test "extract_chains/1 returns empty list for unstructured text" do
    text = "Hello, how are you today?"
    chains = Distiller.extract_chains(text)
    assert chains == []
  end

  test "extract_reflex_candidates/2 identifies simple cause-action patterns" do
    chains = [
      {"disk_pressure", "caused_by", "temp_files"},
      {"temp_files", "produced_by", "consolidation"}
    ]
    context = %{available_actions: [:restart_consolidation, :cleanup_temps]}
    candidates = Distiller.extract_reflex_candidates(chains, context)
    assert is_list(candidates)
  end

  test "find_knowledge_gaps/2 finds concepts not in any silo" do
    text = "Kubernetes orchestrates containers using pods and services."
    silo_domains = ["self", "health"]
    gaps = Distiller.find_knowledge_gaps(text, silo_domains)
    assert is_list(gaps)
    assert length(gaps) > 0
    # kubernetes, containers, pods, services should be gaps
  end

  test "distill/3 runs full distillation pipeline" do
    text = "The problem was caused by high memory usage. Memory requires monitoring."
    silo_domains = ["self"]
    context = %{available_actions: []}
    result = Distiller.distill(text, silo_domains, context)
    assert is_map(result)
    assert is_list(result.chains)
    assert is_list(result.reflex_candidates)
    assert is_list(result.knowledge_gaps)
  end
end
```

**Step 2: Run tests to verify they fail**

Run: `ssh titan "cd /home/eel/kudzu_src && mix test test/kudzu/brain/distiller_test.exs --trace"`
Expected: FAIL — module not found

**Step 3: Implement Distiller**

```elixir
# lib/kudzu/brain/distiller.ex
defmodule Kudzu.Brain.Distiller do
  @moduledoc """
  Extracts Claude's reasoning into permanent knowledge.

  After any Claude (Tier 3) interaction, the Distiller:
  1. Extracts reasoning chains as relationship triples → silo storage
  2. Identifies simple cause→action patterns → reflex candidates
  3. Finds concepts not in any silo → curiosity targets

  Uses pattern matching, not LLMs. Deliberately simple — catches common
  relational patterns. Improves as the framework level evolves.
  """

  @relational_patterns [
    {~r/(.+?)\s+(?:is caused by|caused by|because of)\s+(.+)/i, "caused_by"},
    {~r/(.+?)\s+because\s+(.+)/i, "because"},
    {~r/(.+?)\s+(?:leads to|results in|causes)\s+(.+)/i, "causes"},
    {~r/(.+?)\s+requires?\s+(.+)/i, "requires"},
    {~r/(.+?)\s+uses?\s+(.+)/i, "uses"},
    {~r/(.+?)\s+(?:is a|is an)\s+(.+)/i, "is_a"},
    {~r/(.+?)\s+(?:consists of|contains|includes)\s+(.+)/i, "contains"},
    {~r/(.+?)\s+(?:relates to|connects to|depends on)\s+(.+)/i, "relates_to"},
    {~r/(.+?)\s+(?:produces?|generates?|creates?)\s+(.+)/i, "produces"},
    {~r/(.+?)\s+(?:provides?|enables?|supports?)\s+(.+)/i, "provides"}
  ]

  @stop_words ~w(the a an is are was were be been being have has had do does did will would shall should may might can could i you we they it this that these those my your our their its some any)

  @doc "Run full distillation pipeline on Claude response text."
  def distill(text, silo_domains, context \\ %{}) do
    chains = extract_chains(text)
    reflex_candidates = extract_reflex_candidates(chains, context)
    knowledge_gaps = find_knowledge_gaps(text, silo_domains)

    %{
      chains: chains,
      reflex_candidates: reflex_candidates,
      knowledge_gaps: knowledge_gaps
    }
  end

  @doc """
  Extract relationship triples from natural language text.
  Returns [{subject, relation, object}].
  """
  def extract_chains(text) when is_binary(text) do
    text
    |> split_sentences()
    |> Enum.flat_map(&extract_from_sentence/1)
    |> Enum.uniq()
  end

  @doc """
  Identify simple cause→action patterns that could become reflexes.
  Returns [%{pattern: {cause, condition}, action: atom}].
  """
  def extract_reflex_candidates(chains, context) do
    available_actions = Map.get(context, :available_actions, [])

    chains
    |> Enum.filter(fn {_s, rel, _o} -> rel in ["caused_by", "because", "causes"] end)
    |> Enum.map(fn {subject, relation, object} ->
      # Try to map to a known action
      action = find_matching_action(subject, object, relation, available_actions)
      if action do
        %{
          pattern: normalize_term(subject),
          condition: normalize_term(object),
          relation: relation,
          action: action
        }
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Find concepts in text that don't exist in any silo.
  Returns list of concept strings that are curiosity targets.
  """
  def find_knowledge_gaps(text, silo_domains) do
    # Extract significant terms from text
    terms = text
    |> String.downcase()
    |> String.replace(~r/[^\w\s]/, "")
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reject(fn term -> term in @stop_words end)
    |> Enum.reject(fn term -> String.length(term) < 3 end)
    |> Enum.frequencies()
    |> Enum.filter(fn {_term, count} -> count >= 1 end)
    |> Enum.map(fn {term, _count} -> term end)

    # Check which terms have no silo coverage
    silo_set = MapSet.new(silo_domains |> Enum.map(&String.downcase/1))

    terms
    |> Enum.reject(fn term -> MapSet.member?(silo_set, term) end)
    |> Enum.reject(fn term ->
      # Also check if term appears as a concept in any silo via probe
      try do
        results = Kudzu.Brain.InferenceEngine.cross_query(term)
        Enum.any?(results, fn {_domain, _hint, score} -> score > 0.5 end)
      rescue
        _ -> false
      catch
        :exit, _ -> false
      end
    end)
  end

  # --- Private ---

  defp split_sentences(text) do
    text
    |> String.split(~r/[.!?\n]+/, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(fn s -> String.length(s) < 5 end)
  end

  defp extract_from_sentence(sentence) do
    @relational_patterns
    |> Enum.flat_map(fn {regex, relation} ->
      case Regex.run(regex, sentence, capture: :all_but_first) do
        [subject, object] ->
          s = normalize_term(subject)
          o = normalize_term(object)
          if String.length(s) > 1 and String.length(o) > 1 do
            [{s, relation, o}]
          else
            []
          end
        _ -> []
      end
    end)
  end

  defp normalize_term(term) do
    term
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/\s+/, "_")
    |> String.replace(~r/[^\w_]/, "")
  end

  defp find_matching_action(subject, object, _relation, available_actions) do
    terms = [normalize_term(subject), normalize_term(object)]
    Enum.find(available_actions, fn action ->
      action_str = to_string(action) |> String.downcase()
      Enum.any?(terms, fn term ->
        String.contains?(action_str, term) or String.contains?(term, action_str)
      end)
    end)
  end
end
```

**Step 4: Run tests to verify they pass**

Run: `ssh titan "cd /home/eel/kudzu_src && mix test test/kudzu/brain/distiller_test.exs --trace"`
Expected: All 6 tests pass

**Step 5: Commit**

```bash
ssh titan "cd /home/eel/kudzu_src && git add lib/kudzu/brain/distiller.ex test/kudzu/brain/distiller_test.exs && git commit -m 'feat: add Distiller — extract Claude reasoning into silos and reflexes'"
```

---

### Task 5: Web Tools — Search and Read

Internet access for the thinking layer. Two tools: web_search and web_read.

**Files:**
- Create: `lib/kudzu/brain/tools/web.ex`
- Test: `test/kudzu/brain/tools/web_test.exs`

**Prerequisites:** SearXNG should be installed on titan. If not available, fall back to DuckDuckGo HTML scraping.

**Step 1: Write the failing tests**

```elixir
# test/kudzu/brain/tools/web_test.exs
defmodule Kudzu.Brain.Tools.WebTest do
  use ExUnit.Case, async: false

  alias Kudzu.Brain.Tools.Web

  @tag :integration
  test "web_search returns results for a query" do
    {:ok, results} = Web.execute("web_search", %{"query" => "Elixir programming language"})
    assert is_list(results.results)
    # May be empty if SearXNG is not running, but should not error
  end

  @tag :integration
  test "web_read fetches and extracts text from a URL" do
    {:ok, result} = Web.execute("web_read", %{"url" => "https://elixir-lang.org"})
    assert is_binary(result.text)
    assert result.word_count > 0
  end

  test "web_read rejects non-http URLs" do
    {:error, reason} = Web.execute("web_read", %{"url" => "file:///etc/passwd"})
    assert reason =~ "http"
  end

  test "web_search returns error for empty query" do
    {:error, _reason} = Web.execute("web_search", %{"query" => ""})
  end

  test "extract_knowledge/1 extracts relationship triples from text" do
    text = "Elixir is a functional programming language. Elixir uses the BEAM virtual machine."
    triples = Web.extract_knowledge(text)
    assert is_list(triples)
    assert length(triples) >= 1
  end

  test "all_tools/0 returns tool definitions" do
    tools = Web.all_tools()
    assert length(tools) == 2
    names = Enum.map(tools, & &1.name)
    assert "web_search" in names
    assert "web_read" in names
  end
end
```

**Step 2: Run tests to verify they fail**

Run: `ssh titan "cd /home/eel/kudzu_src && mix test test/kudzu/brain/tools/web_test.exs --trace"`
Expected: FAIL — module not found

**Step 3: Implement Web tools**

```elixir
# lib/kudzu/brain/tools/web.ex
defmodule Kudzu.Brain.Tools.Web do
  @moduledoc """
  Internet access tools for the thinking layer.

  web_search — search the internet via SearXNG (self-hosted) or DuckDuckGo fallback
  web_read — fetch and extract readable text from a URL

  These are capabilities the Thought process can use to fill knowledge gaps.
  """

  require Logger

  alias Kudzu.Silo.Extractor

  @searxng_url "http://localhost:8888"  # SearXNG on titan
  @max_content_bytes 100_000            # 100KB max page content
  @http_timeout 10_000                  # 10s timeout
  @user_agent ~c"Kudzu/1.0 (Mesh Republic Knowledge Agent)"

  # --- Tool Interface ---

  defmodule WebSearch do
    @behaviour Kudzu.Brain.Tool
    def name, do: "web_search"
    def description, do: "Search the internet for information. Returns titles, URLs, and snippets."
    def parameters do
      %{
        type: "object",
        properties: %{
          query: %{type: "string", description: "Search query"},
          limit: %{type: "integer", description: "Max results (default 5)"}
        },
        required: ["query"]
      }
    end
    def execute(params), do: Kudzu.Brain.Tools.Web.execute("web_search", params)
  end

  defmodule WebRead do
    @behaviour Kudzu.Brain.Tool
    def name, do: "web_read"
    def description, do: "Fetch a web page and extract its readable text content."
    def parameters do
      %{
        type: "object",
        properties: %{
          url: %{type: "string", description: "URL to fetch"}
        },
        required: ["url"]
      }
    end
    def execute(params), do: Kudzu.Brain.Tools.Web.execute("web_read", params)
  end

  def all_tools do
    [
      %{name: "web_search", description: WebSearch.description(), parameters: WebSearch.parameters()},
      %{name: "web_read", description: WebRead.description(), parameters: WebRead.parameters()}
    ]
  end

  def to_claude_format do
    [
      Kudzu.Brain.Tool.to_claude_format(WebSearch),
      Kudzu.Brain.Tool.to_claude_format(WebRead)
    ]
  end

  # --- Execute ---

  def execute("web_search", %{"query" => query}) when byte_size(query) > 0 do
    limit = Map.get(%{}, "limit", 5)
    do_search(query, limit)
  end

  def execute("web_search", %{"query" => ""}), do: {:error, "Query cannot be empty"}
  def execute("web_search", _), do: {:error, "Missing required parameter: query"}

  def execute("web_read", %{"url" => url}) do
    if valid_url?(url) do
      do_read(url)
    else
      {:error, "URL must start with http:// or https://"}
    end
  end

  def execute("web_read", _), do: {:error, "Missing required parameter: url"}
  def execute(name, _), do: {:error, "Unknown web tool: #{name}"}

  # --- Search ---

  defp do_search(query, limit) do
    # Try SearXNG first, fall back to DuckDuckGo HTML
    case searxng_search(query, limit) do
      {:ok, results} -> {:ok, %{results: results, source: "searxng"}}
      {:error, _} ->
        case duckduckgo_search(query, limit) do
          {:ok, results} -> {:ok, %{results: results, source: "duckduckgo"}}
          {:error, reason} -> {:error, "Search failed: #{reason}"}
        end
    end
  end

  defp searxng_search(query, limit) do
    url = "#{@searxng_url}/search?q=#{URI.encode(query)}&format=json&categories=general"
    |> String.to_charlist()

    case :httpc.request(:get, {url, []}, [{:timeout, @http_timeout}], []) do
      {:ok, {{_, 200, _}, _headers, body}} ->
        case Jason.decode(to_string(body)) do
          {:ok, %{"results" => results}} ->
            parsed = results
            |> Enum.take(limit)
            |> Enum.map(fn r ->
              %{title: r["title"], url: r["url"], snippet: r["content"]}
            end)
            {:ok, parsed}
          _ -> {:error, :parse_failed}
        end
      _ -> {:error, :searxng_unavailable}
    end
  rescue
    _ -> {:error, :searxng_unavailable}
  end

  defp duckduckgo_search(query, limit) do
    url = "https://html.duckduckgo.com/html/?q=#{URI.encode(query)}"
    |> String.to_charlist()

    headers = [{~c"User-Agent", @user_agent}]

    case :httpc.request(:get, {url, headers}, [{:timeout, @http_timeout}], []) do
      {:ok, {{_, 200, _}, _headers, body}} ->
        html = to_string(body)
        results = parse_ddg_html(html, limit)
        {:ok, results}
      {:ok, {{_, status, _}, _, _}} ->
        {:error, "DuckDuckGo returned #{status}"}
      {:error, reason} ->
        {:error, "HTTP error: #{inspect(reason)}"}
    end
  rescue
    e -> {:error, "DuckDuckGo error: #{inspect(e)}"}
  end

  defp parse_ddg_html(html, limit) do
    # Simple regex extraction from DuckDuckGo HTML results
    ~r/<a rel="nofollow" class="result__a" href="([^"]+)"[^>]*>(.+?)<\/a>.*?<a class="result__snippet"[^>]*>(.+?)<\/a>/s
    |> Regex.scan(html, capture: :all_but_first)
    |> Enum.take(limit)
    |> Enum.map(fn
      [url, title, snippet] ->
        %{
          title: strip_html(title),
          url: decode_ddg_url(url),
          snippet: strip_html(snippet)
        }
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  # --- Read ---

  defp do_read(url) do
    headers = [{~c"User-Agent", @user_agent}]
    url_charlist = String.to_charlist(url)

    case :httpc.request(:get, {url_charlist, headers}, [{:timeout, @http_timeout}], []) do
      {:ok, {{_, 200, _}, _headers, body}} ->
        text = body
        |> to_string()
        |> String.slice(0, @max_content_bytes)
        |> strip_html()
        |> clean_whitespace()

        word_count = text |> String.split(~r/\s+/, trim: true) |> length()
        {:ok, %{text: text, title: extract_title(to_string(body)), word_count: word_count}}

      {:ok, {{_, status, _}, _, _}} ->
        {:error, "HTTP #{status}"}

      {:error, reason} ->
        {:error, "Fetch failed: #{inspect(reason)}"}
    end
  rescue
    e -> {:error, "Fetch error: #{inspect(e)}"}
  end

  # --- Knowledge Extraction ---

  @doc "Extract relationship triples from web text. Delegates to Silo.Extractor."
  def extract_knowledge(text) do
    Extractor.extract_patterns(text)
  end

  # --- Helpers ---

  defp valid_url?(url) do
    String.starts_with?(url, "http://") or String.starts_with?(url, "https://")
  end

  defp strip_html(text) do
    text
    |> String.replace(~r/<script[^>]*>.*?<\/script>/s, "")
    |> String.replace(~r/<style[^>]*>.*?<\/style>/s, "")
    |> String.replace(~r/<[^>]+>/, " ")
    |> String.replace(~r/&[a-z]+;/, " ")
    |> String.replace(~r/&#\d+;/, " ")
  end

  defp clean_whitespace(text) do
    text
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp extract_title(html) do
    case Regex.run(~r/<title[^>]*>(.+?)<\/title>/s, html) do
      [_, title] -> strip_html(title) |> String.trim()
      _ -> ""
    end
  end

  defp decode_ddg_url(url) do
    case URI.decode(url) do
      decoded when is_binary(decoded) ->
        case Regex.run(~r/uddg=([^&]+)/, decoded) do
          [_, actual_url] -> URI.decode(actual_url)
          _ -> decoded
        end
      _ -> url
    end
  end
end
```

**Step 4: Run tests to verify they pass**

Run: `ssh titan "cd /home/eel/kudzu_src && mix test test/kudzu/brain/tools/web_test.exs --trace --exclude integration"`
Expected: Non-integration tests pass. Integration tests may need SearXNG.

**Step 5: Commit**

```bash
ssh titan "cd /home/eel/kudzu_src && git add lib/kudzu/brain/tools/web.ex test/kudzu/brain/tools/web_test.exs && git commit -m 'feat: add Web tools — search and read for thinking layer'"
```

---

### Task 6: Brain Integration — Wire Everything Together

Modify the Brain GenServer to use WorkingMemory, Thought, Curiosity, and Distiller. Replace the rigid tier pipeline with the thinking layer.

**Files:**
- Modify: `lib/kudzu/brain/brain.ex`
- Test: `test/kudzu/brain/thinking_integration_test.exs`

**Step 1: Write the integration tests**

```elixir
# test/kudzu/brain/thinking_integration_test.exs
defmodule Kudzu.Brain.ThinkingIntegrationTest do
  use ExUnit.Case, async: false

  alias Kudzu.Brain

  setup do
    # Wait for brain to be ready
    wait_for_brain(50)
    :ok
  end

  defp wait_for_brain(0), do: :ok
  defp wait_for_brain(n) do
    state = Brain.get_state()
    if state.hologram_id, do: :ok, else: (Process.sleep(100); wait_for_brain(n - 1))
  end

  @tag :integration
  test "brain state includes working_memory" do
    state = Brain.get_state()
    assert %Kudzu.Brain.WorkingMemory{} = state.working_memory
  end

  @tag :integration
  test "chat processes through thinking layer" do
    result = Brain.chat("What is your status?")
    assert {:ok, response} = result
    assert is_binary(response.response)
    assert response.tier in [1, 2, 3, :thought]
  end

  @tag :integration
  test "working memory gets updated after chat" do
    Brain.chat("Tell me about disk usage")
    Process.sleep(500)
    state = Brain.get_state()
    # Working memory should have some active concepts
    assert is_map(state.working_memory.active_concepts)
  end

  @tag :integration
  test "curiosity generates questions when idle" do
    state = Brain.get_state()
    questions = Kudzu.Brain.Curiosity.generate(
      state.desires,
      state.working_memory,
      Kudzu.Silo.list() |> Enum.map(fn {domain, _, _} -> domain end)
    )
    assert is_list(questions)
    assert length(questions) > 0
  end
end
```

**Step 2: Run tests to verify they fail**

Run: `ssh titan "cd /home/eel/kudzu_src && mix test test/kudzu/brain/thinking_integration_test.exs --trace --include integration"`
Expected: FAIL — `working_memory` not in state

**Step 3: Modify Brain GenServer**

The key changes to `brain.ex`:

1. Add `working_memory` to the struct
2. Initialize working memory in `init/1`
3. Modify `chat_reason/3` to use Thought process instead of rigid tiers
4. Add working memory integration after thoughts complete
5. Add curiosity to wake cycle
6. Add distillation after Claude calls
7. Add working memory decay at end of cycle

**Changes to the struct (near line 30):**
Add `:working_memory` to the defstruct.

**Changes to init (handle_info :init_hologram, ~line 237):**
Initialize `working_memory: WorkingMemory.new()` in the state.

**Changes to chat_reason/3 (~line 475):**
Replace the rigid tier pipeline with:
1. Run Thought.run(message) with working memory priming
2. If thought resolves → return result
3. If thought partially resolves → try Claude with thought context
4. Integrate thought results into working memory
5. If Claude was used → run Distiller

**Changes to handle_info :wake_cycle (~line 268):**
After existing pre_check logic, add:
1. If no anomalies, generate curiosity question
2. Run thought on curiosity question
3. Decay working memory

These are significant changes. The implementer should:
- Read the full current brain.ex first
- Make changes incrementally
- Compile after each change
- The existing three-tier pipeline should still work as fallback

**Step 4: Run all tests**

Run: `ssh titan "cd /home/eel/kudzu_src && mix test --trace --include integration"`
Expected: All tests pass including new integration tests

**Step 5: Commit**

```bash
ssh titan "cd /home/eel/kudzu_src && git add lib/kudzu/brain/brain.ex test/kudzu/brain/thinking_integration_test.exs && git commit -m 'feat: integrate thinking layer into Brain — working memory, curiosity, distillation'"
```

---

### Task 7: Register Web Tools and MCP Exposure

Make web tools available to the Brain's tool executor and expose them via MCP.

**Files:**
- Modify: `lib/kudzu/brain/brain.ex` (tool executor function)
- Modify: `lib/kudzu_web/mcp/tools.ex` (add web tool definitions)
- Modify: `lib/kudzu_web/mcp/controller.ex` (add Web handler)
- Create: `lib/kudzu_web/mcp/handlers/web.ex` (MCP handler for web tools)

**Step 1: Create MCP handler for web tools**

```elixir
# lib/kudzu_web/mcp/handlers/web.ex
defmodule KudzuWeb.MCP.Handlers.Web do
  @moduledoc "MCP handler for web search and read tools."

  alias Kudzu.Brain.Tools.Web

  def handle("kudzu_web_search", params) do
    case Web.execute("web_search", params) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  def handle("kudzu_web_read", params) do
    case Web.execute("web_read", params) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end
end
```

**Step 2: Add tool definitions to `lib/kudzu_web/mcp/tools.ex`**

Add to the tools list:
```elixir
# === Web Tools ===
%{
  name: "kudzu_web_search",
  description: "Search the internet for information. Returns titles, URLs, and snippets.",
  inputSchema: %{type: "object", properties: %{
    query: %{type: "string", description: "Search query"},
    limit: %{type: "integer", description: "Max results (default 5)"}
  }, required: ["query"]}
},
%{
  name: "kudzu_web_read",
  description: "Fetch a web page and extract its readable text content.",
  inputSchema: %{type: "object", properties: %{
    url: %{type: "string", description: "URL to fetch"}
  }, required: ["url"]}
}
```

**Step 3: Add handler mapping to `lib/kudzu_web/mcp/controller.ex`**

Add `Web` to the alias line and add to `@handler_map`:
```elixir
"kudzu_web_search" => Web,
"kudzu_web_read" => Web
```

**Step 4: Add web tools to Brain's tool executor**

In `brain.ex`, update the tool executor function that gets passed to `Claude.reason/6` to include web tool dispatch.

**Step 5: Compile and verify**

Run: `ssh titan "cd /home/eel/kudzu_src && mix compile --warnings-as-errors"`

**Step 6: Commit**

```bash
ssh titan "cd /home/eel/kudzu_src && git add lib/kudzu_web/mcp/handlers/web.ex lib/kudzu_web/mcp/tools.ex lib/kudzu_web/mcp/controller.ex lib/kudzu/brain/brain.ex && git commit -m 'feat: register web tools in Brain executor and MCP'"
```

---

### Task 8: End-to-End Testing and Polish

Manual integration testing, fix any issues, verify the complete thinking pipeline works.

**Steps:**

1. **Restart Kudzu on titan:**
   ```bash
   ssh titan 'source ~/.profile && kill $(lsof -ti :4001) 2>/dev/null; sleep 2; cd /home/eel/kudzu_src && ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" KUDZU_API_KEY="$KUDZU_API_KEY" elixir --erl "-detached" -S mix run --no-halt'
   ```

2. **Wait for brain to initialize, then test thinking:**
   ```bash
   ssh titan 'source ~/.profile && sleep 10 && curl -s -X POST http://100.70.67.110:4001/brain/chat -H "Content-Type: application/json" -H "Authorization: Bearer $KUDZU_API_KEY" -d '"'"'{"message":"What do you know about yourself?"}'"'"' --max-time 60'
   ```

3. **Test curiosity (check brain state for working memory):**
   ```bash
   ssh titan 'source ~/.profile && curl -s http://100.70.67.110:4001/brain/status -H "Authorization: Bearer $KUDZU_API_KEY"'
   ```

4. **Test web search (if SearXNG available):**
   ```bash
   ssh titan 'curl -s "http://localhost:8888/search?q=test&format=json" | head -c 200'
   ```

5. **Test via MCP tools:**
   Use the Kudzu MCP tools to verify web tools are exposed.

6. **Fix any issues found.**

7. **Push to GitHub:**
   ```bash
   ssh titan "cd /home/eel/kudzu_src && git push origin main"
   ```

---

### Task Summary

| Task | Component | Description |
|------|-----------|-------------|
| 1 | WorkingMemory | Bounded attention buffer for the Monarch |
| 2 | Thought | Ephemeral reasoning process with activation and chaining |
| 3 | Curiosity | Self-directed question generation from desires and gaps |
| 4 | Distiller | Extract Claude responses into silos and reflexes |
| 5 | Web Tools | Internet search and read capabilities |
| 6 | Brain Integration | Wire thinking layer into Brain GenServer |
| 7 | MCP + Tool Registration | Expose web tools via MCP and Brain tool executor |
| 8 | End-to-End Testing | Integration test, fix issues, push |
