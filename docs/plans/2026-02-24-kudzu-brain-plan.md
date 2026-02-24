# Kudzu Brain Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a desire-driven autonomous entity within the Kudzu OTP application that reasons through three cognition tiers (reflexes, HRR silo inference, Claude API), accumulates structured knowledge in expertise silos, and grows more capable and less LLM-dependent over time.

**Architecture:** New modules under `lib/kudzu/brain/` and `lib/kudzu/silo/` extend the existing Kudzu supervision tree. The brain is a GenServer with a 5-minute wake cycle that gathers context, reasons through tiered cognition, acts via beamlets, and records traces on its own hologram. Expertise silos are specialized holograms that store HRR-bound relationship triples.

**Tech Stack:** Elixir/OTP, existing Kudzu HRR library (bind/unbind/bundle/similarity), `:httpc` for Claude API, DETS for persistence. No new dependencies.

**Remote setup:** All Elixir code lives on `titan` at `/home/eel/kudzu_src/`. Edit files via `scp`, compile/test via `ssh titan`. Git repo at `titan:/home/eel/kudzu_src/` with remote `git@github.com:MeshRepublic/kudzu.git`.

---

## Phase 1: Brain GenServer + Pre-check Gate

The brain wakes, checks health, and goes back to sleep. No reasoning yet — just the heartbeat loop that everything else builds on.

### Task 1: Brain struct and GenServer skeleton

**Files:**
- Create: `lib/kudzu/brain/brain.ex`
- Modify: `lib/kudzu/application.ex` (add to supervision tree)
- Test: `test/kudzu/brain/brain_test.exs`

**Step 1: Write the failing test**

```elixir
# test/kudzu/brain/brain_test.exs
defmodule Kudzu.BrainTest do
  use ExUnit.Case, async: false

  alias Kudzu.Brain

  test "brain starts and creates its hologram" do
    # Brain should already be running from Application supervisor
    state = Brain.get_state()
    assert state.status == :sleeping
    assert is_binary(state.hologram_id)
    assert state.hologram_id != ""
  end

  test "brain has initial desires" do
    state = Brain.get_state()
    assert length(state.desires) > 0
    assert Enum.any?(state.desires, &String.contains?(&1, "health"))
  end

  test "brain hologram is registered with kudzu_brain purpose" do
    state = Brain.get_state()
    [{pid, _}] = Kudzu.Application.find_by_purpose("kudzu_brain")
    assert is_pid(pid)
  end
end
```

**Step 2: Run test to verify it fails**

Run: `ssh titan "cd /home/eel/kudzu_src && mix test test/kudzu/brain/brain_test.exs --no-start 2>&1 | tail -20"`
Expected: Compilation error — `Kudzu.Brain` module not found

**Step 3: Write the Brain GenServer**

```elixir
# lib/kudzu/brain/brain.ex
defmodule Kudzu.Brain do
  use GenServer
  require Logger

  alias Kudzu.{Application, Hologram}

  @cycle_interval_ms 300_000  # 5 minutes
  @default_model "claude-sonnet-4-6"
  @max_turns 10

  @initial_desires [
    "Maintain Kudzu system health and recover from failures",
    "Build accurate self-model of architecture, resources, and capabilities",
    "Learn from every observation — discover patterns in system behavior",
    "Identify knowledge gaps and pursue self-education to fill them",
    "Plan for increased fault tolerance and distributed operation"
  ]

  defstruct [
    :hologram_id,
    :hologram_pid,
    desires: @initial_desires,
    status: :sleeping,
    cycle_interval: @cycle_interval_ms,
    cycle_count: 0,
    current_session: nil,
    config: %{
      model: @default_model,
      api_key: nil,
      max_turns: @max_turns,
      budget_limit_monthly: 100.0
    }
  ]

  # === Client API ===

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def get_state do
    GenServer.call(__MODULE__, :get_state)
  end

  def wake_now do
    send(__MODULE__, :wake_cycle)
    :ok
  end

  # === Server Callbacks ===

  @impl true
  def init(opts) do
    api_key = System.get_env("ANTHROPIC_API_KEY") || Keyword.get(opts, :api_key)

    state = %__MODULE__{
      config: %{
        model: Keyword.get(opts, :model, @default_model),
        api_key: api_key,
        max_turns: Keyword.get(opts, :max_turns, @max_turns),
        budget_limit_monthly: Keyword.get(opts, :budget_limit, 100.0)
      }
    }

    # Create brain's hologram after a short delay (let HologramSupervisor start first)
    Process.send_after(self(), :init_hologram, 2_000)

    Logger.info("[Brain] Starting with #{length(state.desires)} desires")
    {:ok, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_info(:init_hologram, state) do
    case create_brain_hologram() do
      {:ok, pid, id} ->
        Logger.info("[Brain] Hologram created: #{id}")
        schedule_wake_cycle(state.cycle_interval)
        {:noreply, %{state | hologram_id: id, hologram_pid: pid}}

      {:error, reason} ->
        Logger.error("[Brain] Failed to create hologram: #{inspect(reason)}")
        # Retry in 10 seconds
        Process.send_after(self(), :init_hologram, 10_000)
        {:noreply, state}
    end
  end

  def handle_info(:wake_cycle, %{hologram_id: nil} = state) do
    # Hologram not ready yet, skip this cycle
    schedule_wake_cycle(state.cycle_interval)
    {:noreply, state}
  end

  def handle_info(:wake_cycle, state) do
    state = %{state | status: :reasoning, cycle_count: state.cycle_count + 1}

    # Phase 1: just pre-check — no reasoning yet
    case pre_check(state) do
      :sleep ->
        Logger.debug("[Brain] Cycle #{state.cycle_count}: nominal, sleeping")
        schedule_wake_cycle(state.cycle_interval)
        {:noreply, %{state | status: :sleeping}}

      {:wake, anomalies} ->
        Logger.info("[Brain] Cycle #{state.cycle_count}: #{length(anomalies)} anomalies detected")
        # TODO: reasoning tiers (Phase 2+)
        schedule_wake_cycle(state.cycle_interval)
        {:noreply, %{state | status: :sleeping}}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # === Pre-check Gate ===

  defp pre_check(_state) do
    checks = [
      check_consolidation_recency(),
      check_hologram_count(),
      check_storage_health()
    ]

    anomalies = Enum.filter(checks, fn {status, _} -> status != :nominal end)

    case anomalies do
      [] -> :sleep
      _ -> {:wake, anomalies}
    end
  end

  defp check_consolidation_recency do
    try do
      stats = Kudzu.Consolidation.stats()
      last = stats[:last_consolidation]

      if last == nil do
        {:anomaly, %{check: :consolidation, reason: "never consolidated"}}
      else
        age_ms = System.monotonic_time(:millisecond) - last
        if age_ms > 1_200_000 do  # > 20 minutes
          {:anomaly, %{check: :consolidation, reason: "stale", age_ms: age_ms}}
        else
          {:nominal, :consolidation}
        end
      end
    rescue
      _ -> {:anomaly, %{check: :consolidation, reason: "unreachable"}}
    end
  end

  defp check_hologram_count do
    try do
      count = Kudzu.Application.hologram_count()
      # At minimum, brain's own hologram should exist
      if count >= 1 do
        {:nominal, :holograms}
      else
        {:anomaly, %{check: :holograms, reason: "no holograms", count: count}}
      end
    rescue
      _ -> {:anomaly, %{check: :holograms, reason: "unreachable"}}
    end
  end

  defp check_storage_health do
    try do
      # Simple check: can we query storage?
      _result = Kudzu.Storage.query(:hot, %{limit: 1})
      {:nominal, :storage}
    rescue
      _ -> {:anomaly, %{check: :storage, reason: "unreachable"}}
    end
  end

  # === Helpers ===

  defp create_brain_hologram do
    # Check if brain hologram already exists
    case Kudzu.Application.find_by_purpose("kudzu_brain") do
      [{pid, id} | _] ->
        {:ok, pid, id}

      [] ->
        case Application.spawn_hologram(
          purpose: "kudzu_brain",
          desires: @initial_desires,
          cognition: false,  # brain uses Claude, not Ollama
          constitution: :kudzu_evolve
        ) do
          {:ok, pid} ->
            id = Hologram.get_id(pid)
            {:ok, pid, id}

          error ->
            error
        end
    end
  end

  defp schedule_wake_cycle(interval) do
    Process.send_after(self(), :wake_cycle, interval)
  end
end
```

**Step 4: Add Brain to supervision tree**

In `lib/kudzu/application.ex`, add `Kudzu.Brain` after `Kudzu.Consolidation` in the children list:

```elixir
# After Kudzu.Consolidation line, add:
Kudzu.Brain,
```

**Step 5: Run tests**

Run: `ssh titan "cd /home/eel/kudzu_src && mix test test/kudzu/brain/brain_test.exs 2>&1 | tail -20"`
Expected: 3 tests, 3 passing

**Step 6: Compile and verify startup**

Run: `ssh titan "cd /home/eel/kudzu_src && mix compile --warnings-as-errors 2>&1 | tail -10"`
Expected: Clean compilation

**Step 7: Commit**

```bash
ssh titan 'cd /home/eel/kudzu_src && git add lib/kudzu/brain/brain.ex lib/kudzu/application.ex test/kudzu/brain/brain_test.exs && git commit -m "feat: add Brain GenServer with desire queue and pre-check gate"'
```

---

## Phase 2: Claude API Client

The brain can call Claude with tool use. This is the Tier 3 reasoning engine — used when reflexes and silos can't handle a situation.

### Task 2: Claude API client with tool-use loop

**Files:**
- Create: `lib/kudzu/brain/claude.ex`
- Test: `test/kudzu/brain/claude_test.exs`

**Step 1: Write the failing test**

```elixir
# test/kudzu/brain/claude_test.exs
defmodule Kudzu.Brain.ClaudeTest do
  use ExUnit.Case, async: true

  alias Kudzu.Brain.Claude

  test "build_request creates valid Anthropic API request body" do
    messages = [
      %{role: "user", content: "What is the system status?"}
    ]

    tools = [
      %{
        name: "check_health",
        description: "Check system health",
        input_schema: %{type: "object", properties: %{}, required: []}
      }
    ]

    body = Claude.build_request(messages, tools,
      model: "claude-sonnet-4-6",
      system: "You are Kudzu Brain.",
      max_tokens: 1024
    )

    assert body["model"] == "claude-sonnet-4-6"
    assert body["max_tokens"] == 1024
    assert body["system"] == "You are Kudzu Brain."
    assert length(body["messages"]) == 1
    assert length(body["tools"]) == 1
  end

  test "parse_response extracts text content" do
    response = %{
      "content" => [
        %{"type" => "text", "text" => "Everything looks good."}
      ],
      "stop_reason" => "end_turn",
      "usage" => %{"input_tokens" => 100, "output_tokens" => 50}
    }

    result = Claude.parse_response(response)
    assert result.text == "Everything looks good."
    assert result.tool_calls == []
    assert result.stop_reason == "end_turn"
    assert result.usage.input_tokens == 100
  end

  test "parse_response extracts tool use blocks" do
    response = %{
      "content" => [
        %{"type" => "text", "text" => "Let me check."},
        %{
          "type" => "tool_use",
          "id" => "toolu_123",
          "name" => "check_health",
          "input" => %{}
        }
      ],
      "stop_reason" => "tool_use",
      "usage" => %{"input_tokens" => 200, "output_tokens" => 100}
    }

    result = Claude.parse_response(response)
    assert result.text == "Let me check."
    assert length(result.tool_calls) == 1
    assert hd(result.tool_calls).name == "check_health"
    assert hd(result.tool_calls).id == "toolu_123"
    assert result.stop_reason == "tool_use"
  end

  test "build_tool_result creates proper tool_result message" do
    msg = Claude.build_tool_result("toolu_123", %{status: "healthy"})
    assert msg.role == "user"
    assert hd(msg.content)["type"] == "tool_result"
    assert hd(msg.content)["tool_use_id"] == "toolu_123"
  end
end
```

**Step 2: Run test to verify it fails**

Run: `ssh titan "cd /home/eel/kudzu_src && mix test test/kudzu/brain/claude_test.exs 2>&1 | tail -10"`
Expected: Compilation error — `Kudzu.Brain.Claude` not found

**Step 3: Write the Claude API client**

```elixir
# lib/kudzu/brain/claude.ex
defmodule Kudzu.Brain.Claude do
  @moduledoc """
  Claude API client for Kudzu Brain. Uses raw :httpc — no SDK dependency.
  Supports multi-turn tool-use conversations.
  """
  require Logger

  @api_url ~c"https://api.anthropic.com/v1/messages"
  @api_version "2023-06-01"
  @default_model "claude-sonnet-4-6"
  @default_max_tokens 4096
  @timeout 120_000

  defmodule Response do
    defstruct [:text, :tool_calls, :stop_reason, :usage]
  end

  defmodule ToolCall do
    defstruct [:id, :name, :input]
  end

  # === Request Building ===

  def build_request(messages, tools \\ [], opts \\ []) do
    body = %{
      "model" => Keyword.get(opts, :model, @default_model),
      "max_tokens" => Keyword.get(opts, :max_tokens, @default_max_tokens),
      "messages" => Enum.map(messages, &normalize_message/1)
    }

    body = if system = Keyword.get(opts, :system) do
      Map.put(body, "system", system)
    else
      body
    end

    body = if tools != [] do
      Map.put(body, "tools", Enum.map(tools, &normalize_tool/1))
    else
      body
    end

    body
  end

  def build_tool_result(tool_use_id, result) do
    content_str = if is_binary(result), do: result, else: Jason.encode!(result)
    %{
      role: "user",
      content: [
        %{
          "type" => "tool_result",
          "tool_use_id" => tool_use_id,
          "content" => content_str
        }
      ]
    }
  end

  # === Response Parsing ===

  def parse_response(response) when is_map(response) do
    content_blocks = Map.get(response, "content", [])

    text =
      content_blocks
      |> Enum.filter(&(&1["type"] == "text"))
      |> Enum.map(&(&1["text"]))
      |> Enum.join("\n")

    tool_calls =
      content_blocks
      |> Enum.filter(&(&1["type"] == "tool_use"))
      |> Enum.map(fn block ->
        %ToolCall{
          id: block["id"],
          name: block["name"],
          input: block["input"] || %{}
        }
      end)

    usage_raw = Map.get(response, "usage", %{})

    %Response{
      text: text,
      tool_calls: tool_calls,
      stop_reason: Map.get(response, "stop_reason"),
      usage: %{
        input_tokens: usage_raw["input_tokens"] || 0,
        output_tokens: usage_raw["output_tokens"] || 0
      }
    }
  end

  # === API Call ===

  def call(api_key, messages, tools \\ [], opts \\ []) do
    body = build_request(messages, tools, opts)

    headers = [
      {~c"content-type", ~c"application/json"},
      {~c"x-api-key", String.to_charlist(api_key)},
      {~c"anthropic-version", String.to_charlist(@api_version)}
    ]

    body_json = Jason.encode!(body)

    case :httpc.request(
      :post,
      {@api_url, headers, ~c"application/json", String.to_charlist(body_json)},
      [timeout: @timeout, connect_timeout: 10_000],
      [body_format: :binary]
    ) do
      {:ok, {{_, 200, _}, _headers, resp_body}} ->
        case Jason.decode(resp_body) do
          {:ok, parsed} -> {:ok, parse_response(parsed)}
          {:error, err} -> {:error, {:json_decode, err}}
        end

      {:ok, {{_, status, _}, _headers, resp_body}} ->
        Logger.warning("[Claude] API returned #{status}: #{String.slice(to_string(resp_body), 0, 200)}")
        {:error, {:api_error, status, resp_body}}

      {:error, reason} ->
        Logger.error("[Claude] HTTP error: #{inspect(reason)}")
        {:error, {:http_error, reason}}
    end
  end

  # === Tool-Use Loop ===

  def reason(api_key, system_prompt, initial_message, tools, tool_executor, opts \\ []) do
    max_turns = Keyword.get(opts, :max_turns, 10)
    model = Keyword.get(opts, :model, @default_model)

    messages = [%{role: "user", content: initial_message}]
    call_opts = [model: model, system: system_prompt, max_tokens: @default_max_tokens]

    do_reason(api_key, messages, tools, tool_executor, call_opts, max_turns, 0, %{
      input_tokens: 0,
      output_tokens: 0,
      turns: 0
    })
  end

  defp do_reason(_api_key, _messages, _tools, _executor, _opts, max_turns, turn, usage)
       when turn >= max_turns do
    {:error, {:max_turns_exceeded, usage}}
  end

  defp do_reason(api_key, messages, tools, executor, opts, max_turns, turn, usage) do
    case call(api_key, messages, tools, opts) do
      {:ok, %Response{stop_reason: "end_turn"} = resp} ->
        usage = update_usage(usage, resp.usage, turn + 1)
        {:ok, resp.text, usage}

      {:ok, %Response{stop_reason: "tool_use", tool_calls: calls} = resp} ->
        usage = update_usage(usage, resp.usage, turn + 1)

        # Execute each tool call
        tool_results =
          Enum.map(calls, fn %ToolCall{id: id, name: name, input: input} ->
            result = executor.(name, input)
            build_tool_result(id, result)
          end)

        # Build assistant message with the response content blocks
        assistant_msg = %{role: "assistant", content: resp_to_content_blocks(resp)}

        # Append assistant message + tool results
        new_messages = messages ++ [assistant_msg] ++ tool_results

        do_reason(api_key, new_messages, tools, executor, opts, max_turns, turn + 1, usage)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # === Helpers ===

  defp normalize_message(%{role: role, content: content}) do
    %{"role" => to_string(role), "content" => normalize_content(content)}
  end

  defp normalize_message(msg) when is_map(msg), do: msg

  defp normalize_content(content) when is_binary(content), do: content
  defp normalize_content(content) when is_list(content), do: content
  defp normalize_content(content), do: inspect(content)

  defp normalize_tool(%{name: name, description: desc, input_schema: schema}) do
    %{"name" => name, "description" => desc, "input_schema" => schema}
  end

  defp normalize_tool(tool) when is_map(tool), do: tool

  defp resp_to_content_blocks(%Response{text: text, tool_calls: calls}) do
    blocks = if text != "", do: [%{"type" => "text", "text" => text}], else: []

    tool_blocks =
      Enum.map(calls, fn %ToolCall{id: id, name: name, input: input} ->
        %{"type" => "tool_use", "id" => id, "name" => name, "input" => input}
      end)

    blocks ++ tool_blocks
  end

  defp update_usage(acc, cycle_usage, turns) do
    %{
      input_tokens: acc.input_tokens + (cycle_usage[:input_tokens] || 0),
      output_tokens: acc.output_tokens + (cycle_usage[:output_tokens] || 0),
      turns: turns
    }
  end
end
```

**Step 4: Run tests**

Run: `ssh titan "cd /home/eel/kudzu_src && mix test test/kudzu/brain/claude_test.exs 2>&1 | tail -10"`
Expected: 4 tests, 4 passing

**Step 5: Commit**

```bash
ssh titan 'cd /home/eel/kudzu_src && git add lib/kudzu/brain/claude.ex test/kudzu/brain/claude_test.exs && git commit -m "feat: add Claude API client with tool-use loop"'
```

---

## Phase 3: Tool System + Self-Monitoring

Define the tool behaviour and implement Tier 1 introspection tools so the brain can inspect its own state.

### Task 3: Tool behaviour and introspection tools

**Files:**
- Create: `lib/kudzu/brain/tool.ex`
- Create: `lib/kudzu/brain/tools/introspection.ex`
- Test: `test/kudzu/brain/tools/introspection_test.exs`

**Step 1: Write the tool behaviour**

```elixir
# lib/kudzu/brain/tool.ex
defmodule Kudzu.Brain.Tool do
  @moduledoc """
  Behaviour for brain tools. Each tool can be called by Claude during reasoning
  and serialized into Claude's tool-use format.
  """

  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback parameters() :: map()
  @callback execute(params :: map()) :: {:ok, term()} | {:error, term()}

  @doc "Convert a tool module to Claude API tool format"
  def to_claude_format(module) do
    %{
      name: module.name(),
      description: module.description(),
      input_schema: module.parameters()
    }
  end
end
```

**Step 2: Write introspection tools**

```elixir
# lib/kudzu/brain/tools/introspection.ex
defmodule Kudzu.Brain.Tools.Introspection do
  @moduledoc """
  Tier 1 tools: Kudzu self-introspection. Direct GenServer calls, zero cost.
  """

  alias Kudzu.{Application, Consolidation, Storage}
  alias Kudzu.HRR.EncoderState

  # === check_health ===

  defmodule CheckHealth do
    @behaviour Kudzu.Brain.Tool

    @impl true
    def name, do: "check_health"

    @impl true
    def description, do: "Check overall Kudzu system health: storage, consolidation, holograms, encoder"

    @impl true
    def parameters, do: %{type: "object", properties: %{}, required: []}

    @impl true
    def execute(_params) do
      health = %{
        holograms: %{
          count: Application.hologram_count(),
          status: "ok"
        },
        consolidation: consolidation_status(),
        storage: storage_status(),
        encoder: encoder_status(),
        beam: beam_status()
      }

      {:ok, health}
    end

    defp consolidation_status do
      try do
        stats = Consolidation.stats()
        %{status: "ok", last_cycle: stats[:last_consolidation], stats: stats}
      rescue
        _ -> %{status: "unreachable"}
      end
    end

    defp storage_status do
      try do
        _ = Storage.query(:hot, %{limit: 1})
        %{status: "ok"}
      rescue
        _ -> %{status: "unreachable"}
      end
    end

    defp encoder_status do
      try do
        state = Consolidation.get_encoder_state()
        %{
          status: "ok",
          vocabulary_size: map_size(state.token_counts),
          co_occurrence_entries: state.co_occurrence |> Map.values() |> Enum.map(&map_size/1) |> Enum.sum(),
          traces_processed: state.traces_processed
        }
      rescue
        _ -> %{status: "unreachable"}
      end
    end

    defp beam_status do
      %{
        process_count: :erlang.system_info(:process_count),
        memory_mb: div(:erlang.memory(:total), 1_048_576),
        uptime_seconds: div(:erlang.statistics(:wall_clock) |> elem(0), 1000)
      }
    end
  end

  # === list_holograms ===

  defmodule ListHolograms do
    @behaviour Kudzu.Brain.Tool

    @impl true
    def name, do: "list_holograms"

    @impl true
    def description, do: "List all active holograms with their purpose, trace count, and peer count"

    @impl true
    def parameters, do: %{type: "object", properties: %{}, required: []}

    @impl true
    def execute(_params) do
      holograms =
        Application.list_holograms()
        |> Enum.map(fn pid ->
          try do
            state = :sys.get_state(pid)
            %{
              id: state.id,
              purpose: state.purpose,
              trace_count: map_size(state.traces),
              peer_count: map_size(state.peers),
              desires: length(state.desires),
              constitution: state.constitution
            }
          rescue
            _ -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)

      {:ok, %{holograms: holograms, count: length(holograms)}}
    end
  end

  # === check_consolidation ===

  defmodule CheckConsolidation do
    @behaviour Kudzu.Brain.Tool

    @impl true
    def name, do: "check_consolidation"

    @impl true
    def description, do: "Get detailed consolidation daemon status: last cycle times, traces processed, encoder state"

    @impl true
    def parameters, do: %{type: "object", properties: %{}, required: []}

    @impl true
    def execute(_params) do
      try do
        stats = Consolidation.stats()
        encoder_state = Consolidation.get_encoder_state()

        {:ok, %{
          last_light_cycle: stats[:last_consolidation],
          last_deep_cycle: stats[:last_deep_consolidation],
          traces_processed: encoder_state.traces_processed,
          vocabulary_size: map_size(encoder_state.token_counts),
          blend_strength: encoder_state.blend_strength,
          consolidated_purposes: Map.keys(stats[:consolidated_vectors] || %{})
        }}
      rescue
        e -> {:error, "Consolidation unreachable: #{inspect(e)}"}
      end
    end
  end

  # === semantic_recall ===

  defmodule SemanticRecall do
    @behaviour Kudzu.Brain.Tool

    @impl true
    def name, do: "semantic_recall"

    @impl true
    def description, do: "Search traces by semantic similarity to a natural language query"

    @impl true
    def parameters do
      %{
        type: "object",
        properties: %{
          query: %{type: "string", description: "Natural language query"},
          limit: %{type: "integer", description: "Max results (default 5)"}
        },
        required: ["query"]
      }
    end

    @impl true
    def execute(%{"query" => query} = params) do
      limit = Map.get(params, "limit", 5)

      # Use the MCP semantic handler directly
      try do
        results = Consolidation.semantic_query(query, 0.0)

        top_results =
          results
          |> Enum.take(limit)
          |> Enum.map(fn {purpose, score} ->
            %{purpose: purpose, similarity: Float.round(score, 4)}
          end)

        {:ok, %{results: top_results, query: query}}
      rescue
        e -> {:error, "Semantic recall failed: #{inspect(e)}"}
      end
    end
  end

  # === Module-level helpers ===

  @doc "All introspection tool modules"
  def all_tools do
    [CheckHealth, ListHolograms, CheckConsolidation, SemanticRecall]
  end

  @doc "Convert all tools to Claude API format"
  def to_claude_format do
    Enum.map(all_tools(), &Kudzu.Brain.Tool.to_claude_format/1)
  end

  @doc "Execute a tool by name"
  def execute(name, params) do
    case Enum.find(all_tools(), fn mod -> mod.name() == name end) do
      nil -> {:error, "Unknown tool: #{name}"}
      mod -> mod.execute(params)
    end
  end
end
```

**Step 3: Write tests**

```elixir
# test/kudzu/brain/tools/introspection_test.exs
defmodule Kudzu.Brain.Tools.IntrospectionTest do
  use ExUnit.Case, async: false

  alias Kudzu.Brain.Tools.Introspection

  test "check_health returns system status" do
    {:ok, health} = Introspection.CheckHealth.execute(%{})
    assert health.holograms.count >= 0
    assert health.beam.process_count > 0
    assert health.beam.memory_mb > 0
  end

  test "list_holograms returns hologram list" do
    {:ok, result} = Introspection.ListHolograms.execute(%{})
    assert is_list(result.holograms)
    assert result.count >= 0
  end

  test "all_tools returns 4 tool modules" do
    tools = Introspection.all_tools()
    assert length(tools) == 4
  end

  test "to_claude_format produces valid tool definitions" do
    formats = Introspection.to_claude_format()
    assert length(formats) == 4
    Enum.each(formats, fn tool ->
      assert is_binary(tool.name)
      assert is_binary(tool.description)
      assert is_map(tool.input_schema)
    end)
  end

  test "execute dispatches by tool name" do
    {:ok, health} = Introspection.execute("check_health", %{})
    assert is_map(health)
  end

  test "execute returns error for unknown tool" do
    {:error, msg} = Introspection.execute("nonexistent", %{})
    assert String.contains?(msg, "Unknown tool")
  end
end
```

**Step 4: Run tests**

Run: `ssh titan "cd /home/eel/kudzu_src && mix test test/kudzu/brain/tools/introspection_test.exs 2>&1 | tail -10"`
Expected: 6 tests, 6 passing

**Step 5: Commit**

```bash
ssh titan 'cd /home/eel/kudzu_src && git add lib/kudzu/brain/tool.ex lib/kudzu/brain/tools/introspection.ex test/kudzu/brain/tools/introspection_test.exs && git commit -m "feat: add brain tool behaviour and Tier 1 introspection tools"'
```

---

## Phase 4: Reflexes

Pattern → action mappings for known-good responses. The brain's fastest, cheapest cognition tier.

### Task 4: Reflex system

**Files:**
- Create: `lib/kudzu/brain/reflexes.ex`
- Test: `test/kudzu/brain/reflexes_test.exs`

**Step 1: Write the failing test**

```elixir
# test/kudzu/brain/reflexes_test.exs
defmodule Kudzu.Brain.ReflexesTest do
  use ExUnit.Case, async: true

  alias Kudzu.Brain.Reflexes

  test "consolidation_stale triggers restart" do
    anomalies = [
      {:anomaly, %{check: :consolidation, reason: "stale", age_ms: 1_500_000}}
    ]
    assert {:act, actions} = Reflexes.check(anomalies)
    assert {:restart_consolidation, _} in actions
  end

  test "storage unreachable triggers alert" do
    anomalies = [
      {:anomaly, %{check: :storage, reason: "unreachable"}}
    ]
    assert {:escalate, alerts} = Reflexes.check(anomalies)
    assert length(alerts) > 0
  end

  test "empty anomalies returns pass" do
    assert :pass = Reflexes.check([])
  end
end
```

**Step 2: Write reflexes**

```elixir
# lib/kudzu/brain/reflexes.ex
defmodule Kudzu.Brain.Reflexes do
  @moduledoc """
  Tier 1 cognition: pattern → action mappings. Zero cost.
  When the brain handles the same situation the same way three times,
  it should be encoded here.
  """
  require Logger

  @doc """
  Check a list of anomalies against known reflex patterns.
  Returns :pass | {:act, actions} | {:escalate, alerts}
  """
  def check([]), do: :pass

  def check(anomalies) when is_list(anomalies) do
    results = Enum.map(anomalies, &match_reflex/1)

    actions = for {:act, action} <- results, do: action
    escalations = for {:escalate, alert} <- results, do: alert

    cond do
      actions != [] -> {:act, actions}
      escalations != [] -> {:escalate, escalations}
      true -> :pass
    end
  end

  # === Reflex Patterns ===

  # Consolidation stale but reachable -> restart it
  defp match_reflex({:anomaly, %{check: :consolidation, reason: "stale"} = info}) do
    Logger.info("[Reflex] Consolidation stale (#{info[:age_ms]}ms), triggering cycle")
    {:act, {:restart_consolidation, info}}
  end

  # Consolidation unreachable -> escalate
  defp match_reflex({:anomaly, %{check: :consolidation, reason: "unreachable"}}) do
    {:escalate, %{severity: :critical, check: :consolidation, summary: "Consolidation daemon unreachable"}}
  end

  # Storage unreachable -> escalate (can't self-heal storage)
  defp match_reflex({:anomaly, %{check: :storage, reason: "unreachable"}}) do
    {:escalate, %{severity: :critical, check: :storage, summary: "Storage layer unreachable"}}
  end

  # No holograms -> escalate
  defp match_reflex({:anomaly, %{check: :holograms, reason: "no holograms"}}) do
    {:escalate, %{severity: :warning, check: :holograms, summary: "No holograms running"}}
  end

  # Unknown anomaly -> no reflex, let higher tiers handle it
  defp match_reflex({:anomaly, _info}) do
    :unknown
  end

  defp match_reflex(_), do: :unknown

  @doc "Execute a reflex action"
  def execute_action({:restart_consolidation, _info}) do
    Logger.info("[Reflex] Executing: restart consolidation cycle")
    Kudzu.Consolidation.consolidate_now()
    :ok
  end

  def execute_action(action) do
    Logger.warning("[Reflex] No executor for action: #{inspect(action)}")
    {:error, :no_executor}
  end
end
```

**Step 3: Run tests**

Run: `ssh titan "cd /home/eel/kudzu_src && mix test test/kudzu/brain/reflexes_test.exs 2>&1 | tail -10"`
Expected: 3 tests, 3 passing

**Step 4: Wire reflexes into Brain wake cycle**

Update `lib/kudzu/brain/brain.ex` — replace the TODO in the `{:wake, anomalies}` branch:

```elixir
# In handle_info(:wake_cycle, state), replace the {:wake, anomalies} branch:
{:wake, anomalies} ->
  Logger.info("[Brain] Cycle #{state.cycle_count}: #{length(anomalies)} anomalies detected")

  case Kudzu.Brain.Reflexes.check(anomalies) do
    :pass ->
      # No reflex matched — TODO: try silo inference, then Claude (Phase 5+)
      Logger.info("[Brain] No reflex matched, recording anomalies")

    {:act, actions} ->
      Enum.each(actions, &Kudzu.Brain.Reflexes.execute_action/1)
      Logger.info("[Brain] Executed #{length(actions)} reflex actions")

    {:escalate, alerts} ->
      # TODO: record alert traces (Phase 12)
      Logger.warning("[Brain] Escalation needed: #{inspect(alerts)}")
  end

  schedule_wake_cycle(state.cycle_interval)
  {:noreply, %{state | status: :sleeping}}
```

**Step 5: Run all brain tests**

Run: `ssh titan "cd /home/eel/kudzu_src && mix test test/kudzu/brain/ 2>&1 | tail -10"`
Expected: All tests passing

**Step 6: Commit**

```bash
ssh titan 'cd /home/eel/kudzu_src && git add lib/kudzu/brain/reflexes.ex lib/kudzu/brain/brain.ex test/kudzu/brain/reflexes_test.exs && git commit -m "feat: add reflex system (Tier 1 cognition) with consolidation recovery"'
```

---

## Phase 5: Expertise Silos

Silos are specialized holograms that store structured relational knowledge as HRR bindings. This is the foundation for Tier 2 cognition and the long-term path to LLM independence.

### Task 5: Silo management module

**Files:**
- Create: `lib/kudzu/silo.ex`
- Create: `lib/kudzu/silo/relationship.ex`
- Test: `test/kudzu/silo_test.exs`

**Step 1: Write the failing test**

```elixir
# test/kudzu/silo_test.exs
defmodule Kudzu.SiloTest do
  use ExUnit.Case, async: false

  alias Kudzu.Silo

  test "create_silo spawns a hologram with expertise purpose" do
    {:ok, silo} = Silo.create("test_domain")
    assert silo.purpose == "expertise:test_domain"
    assert is_binary(silo.hologram_id)

    # Cleanup
    Silo.delete("test_domain")
  end

  test "store and retrieve a relationship" do
    {:ok, _silo} = Silo.create("test_physics")

    :ok = Silo.store_relationship("test_physics", {"gravity", "attracts", "mass"})
    :ok = Silo.store_relationship("test_physics", {"mass", "curves", "spacetime"})

    results = Silo.probe("test_physics", "gravity")
    assert length(results) > 0

    Silo.delete("test_physics")
  end

  test "list_silos returns all expertise holograms" do
    {:ok, _} = Silo.create("test_list_a")
    {:ok, _} = Silo.create("test_list_b")

    silos = Silo.list()
    domains = Enum.map(silos, & &1.domain)
    assert "test_list_a" in domains
    assert "test_list_b" in domains

    Silo.delete("test_list_a")
    Silo.delete("test_list_b")
  end
end
```

**Step 2: Write the Silo module**

```elixir
# lib/kudzu/silo.ex
defmodule Kudzu.Silo do
  @moduledoc """
  Expertise silo management. Silos are specialized holograms that accumulate
  structured relational knowledge encoded as HRR bindings.
  """
  require Logger

  alias Kudzu.{Application, Hologram, HRR}
  alias Kudzu.Silo.Relationship

  defstruct [:hologram_id, :hologram_pid, :purpose, :domain, :relationships]

  @doc "Create a new expertise silo for a domain"
  def create(domain) when is_binary(domain) do
    purpose = "expertise:#{domain}"

    case Application.find_by_purpose(purpose) do
      [{pid, id} | _] ->
        {:ok, %__MODULE__{
          hologram_id: id,
          hologram_pid: pid,
          purpose: purpose,
          domain: domain,
          relationships: []
        }}

      [] ->
        case Application.spawn_hologram(
          purpose: purpose,
          desires: ["Accumulate knowledge about #{domain}"],
          cognition: false,
          constitution: :kudzu_evolve
        ) do
          {:ok, pid} ->
            id = Hologram.get_id(pid)
            Logger.info("[Silo] Created expertise:#{domain} (#{id})")
            {:ok, %__MODULE__{
              hologram_id: id,
              hologram_pid: pid,
              purpose: purpose,
              domain: domain,
              relationships: []
            }}

          error ->
            error
        end
    end
  end

  @doc "Delete a silo"
  def delete(domain) do
    purpose = "expertise:#{domain}"
    case Application.find_by_purpose(purpose) do
      [{pid, _id} | _] -> Application.stop_hologram(pid)
      [] -> {:error, :not_found}
    end
  end

  @doc "List all expertise silos"
  def list do
    Application.list_holograms()
    |> Enum.map(fn pid ->
      try do
        state = :sys.get_state(pid)
        purpose = to_string(state.purpose)
        if String.starts_with?(purpose, "expertise:") do
          domain = String.replace_prefix(purpose, "expertise:", "")
          %__MODULE__{
            hologram_id: state.id,
            hologram_pid: pid,
            purpose: purpose,
            domain: domain
          }
        end
      rescue
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  @doc "Find a silo by domain"
  def find(domain) do
    purpose = "expertise:#{domain}"
    case Application.find_by_purpose(purpose) do
      [{pid, id} | _] ->
        {:ok, %__MODULE__{
          hologram_id: id,
          hologram_pid: pid,
          purpose: purpose,
          domain: domain
        }}
      [] -> {:error, :not_found}
    end
  end

  @doc "Store a relationship triple in a silo"
  def store_relationship(domain, {subject, relation, object} = triple) do
    case find(domain) do
      {:ok, silo} ->
        # Encode the relationship as an HRR binding
        rel_vector = Relationship.encode(triple)

        # Store as a trace on the silo's hologram
        Hologram.record_trace(silo.hologram_pid, :discovery, %{
          type: "relationship",
          subject: subject,
          relation: relation,
          object: object,
          vector: rel_vector
        })

        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Probe a silo for concepts related to a query"
  def probe(domain, query) when is_binary(query) do
    case find(domain) do
      {:ok, silo} ->
        # Get all relationship traces
        state = :sys.get_state(silo.hologram_pid)
        traces = Map.values(state.traces)

        rel_traces =
          traces
          |> Enum.filter(fn t ->
            hint = t.reconstruction_hint
            is_map(hint) and Map.get(hint, :type) == "relationship"
          end)

        # Encode query as a vector and find similar relationships
        query_vec = HRR.seeded_vector("concept_#{query}", HRR.default_dim())

        rel_traces
        |> Enum.map(fn t ->
          hint = t.reconstruction_hint
          subject_vec = HRR.seeded_vector("concept_#{hint.subject}", HRR.default_dim())
          sim = HRR.similarity(query_vec, subject_vec)
          {hint, sim}
        end)
        |> Enum.filter(fn {_hint, sim} -> sim > 0.1 end)
        |> Enum.sort_by(fn {_hint, sim} -> sim end, :desc)

      {:error, _} ->
        []
    end
  end
end
```

**Step 3: Write the Relationship encoder**

```elixir
# lib/kudzu/silo/relationship.ex
defmodule Kudzu.Silo.Relationship do
  @moduledoc """
  Encodes subject-relation-object triples as HRR bindings.

  encode({"gravity", "attracts", "mass"})
  → bind(concept_gravity, bind(relation_attracts, concept_mass))

  This structured encoding supports unbind-based querying:
  unbind(encoded, concept_gravity) ≈ bind(relation_attracts, concept_mass)
  """

  alias Kudzu.HRR

  @concept_prefix "concept_v1_"
  @relation_prefix "relation_v1_"

  @doc "Encode a triple as an HRR binding"
  def encode({subject, relation, object}) do
    dim = HRR.default_dim()
    s_vec = concept_vector(subject, dim)
    r_vec = relation_vector(relation, dim)
    o_vec = concept_vector(object, dim)

    # bind(subject, bind(relation, object))
    inner = HRR.bind(r_vec, o_vec)
    HRR.bind(s_vec, inner)
  end

  @doc "Query: what does subject relate to via this relation?"
  def query_object({subject, relation}, encoded_vec) do
    dim = HRR.default_dim()
    s_vec = concept_vector(subject, dim)
    r_vec = relation_vector(relation, dim)

    # unbind subject, then unbind relation to get object
    after_subject = HRR.unbind(encoded_vec, s_vec)
    HRR.unbind(after_subject, r_vec)
  end

  @doc "Query: what is the relationship between subject and object?"
  def query_relation({subject, object}, encoded_vec) do
    dim = HRR.default_dim()
    s_vec = concept_vector(subject, dim)
    o_vec = concept_vector(object, dim)

    after_subject = HRR.unbind(encoded_vec, s_vec)
    HRR.unbind(after_subject, o_vec)
  end

  @doc "Get the concept vector for a term"
  def concept_vector(term, dim \\ HRR.default_dim()) do
    HRR.seeded_vector("#{@concept_prefix}#{String.downcase(to_string(term))}", dim)
  end

  @doc "Get the relation vector for a relation type"
  def relation_vector(relation, dim \\ HRR.default_dim()) do
    HRR.seeded_vector("#{@relation_prefix}#{String.downcase(to_string(relation))}", dim)
  end
end
```

**Step 4: Run tests**

Run: `ssh titan "cd /home/eel/kudzu_src && mix test test/kudzu/silo_test.exs 2>&1 | tail -10"`
Expected: 3 tests, 3 passing

**Step 5: Commit**

```bash
ssh titan 'cd /home/eel/kudzu_src && git add lib/kudzu/silo.ex lib/kudzu/silo/relationship.ex test/kudzu/silo_test.exs && git commit -m "feat: add expertise silos with HRR relationship encoding"'
```

---

### Task 6: Self-model silo

**Files:**
- Modify: `lib/kudzu/brain/brain.ex` (create self-model silo on startup)
- Create: `lib/kudzu/brain/self_model.ex` (populate self-model)
- Test: `test/kudzu/brain/self_model_test.exs`

**Step 1: Write the self-model populator**

```elixir
# lib/kudzu/brain/self_model.ex
defmodule Kudzu.Brain.SelfModel do
  @moduledoc """
  Populates and queries the expertise:self silo.
  The brain's knowledge about its own architecture, resources, and capabilities.
  """

  alias Kudzu.Silo

  @domain "self"

  @doc "Create and populate the self-model silo with known architecture facts"
  def init do
    {:ok, _silo} = Silo.create(@domain)

    # Seed with known architectural facts
    relationships = [
      {"kudzu", "built_with", "elixir_otp"},
      {"kudzu", "runs_on", "titan"},
      {"storage", "has_tier", "hot_ets"},
      {"storage", "has_tier", "warm_dets"},
      {"storage", "has_tier", "cold_mnesia"},
      {"consolidation", "runs_every", "10_minutes"},
      {"deep_consolidation", "runs_every", "6_hours"},
      {"hrr_vectors", "have_dimension", "512"},
      {"encoder", "uses", "fft_circular_convolution"},
      {"encoder", "learns", "co_occurrence_matrix"},
      {"brain", "constitution", "kudzu_evolve"},
      {"brain", "reasons_with", "claude_api"},
      {"holograms", "store", "traces"},
      {"traces", "encoded_by", "hrr_encoder"},
      {"beamlets", "provide", "io_capabilities"}
    ]

    Enum.each(relationships, fn triple ->
      Silo.store_relationship(@domain, triple)
    end)

    :ok
  end

  @doc "Add a runtime observation to the self-model"
  def observe(subject, relation, object) do
    Silo.store_relationship(@domain, {subject, relation, object})
  end

  @doc "Query the self-model"
  def query(concept) do
    Silo.probe(@domain, concept)
  end
end
```

**Step 2: Write tests**

```elixir
# test/kudzu/brain/self_model_test.exs
defmodule Kudzu.Brain.SelfModelTest do
  use ExUnit.Case, async: false

  alias Kudzu.Brain.SelfModel
  alias Kudzu.Silo

  setup do
    # Ensure clean state
    Silo.delete("self")
    :ok
  end

  test "init creates self-model silo with architecture knowledge" do
    :ok = SelfModel.init()

    {:ok, silo} = Silo.find("self")
    assert silo.domain == "self"

    results = SelfModel.query("kudzu")
    assert length(results) > 0

    Silo.delete("self")
  end

  test "observe adds runtime knowledge" do
    :ok = SelfModel.init()

    SelfModel.observe("titan", "has_memory", "32gb")
    results = SelfModel.query("titan")
    assert length(results) > 0

    Silo.delete("self")
  end
end
```

**Step 3: Wire into Brain startup**

Add to `brain.ex` `handle_info(:init_hologram, ...)` after hologram creation:

```elixir
# After the {:ok, pid, id} case in create_brain_hologram succeeds,
# in handle_info(:init_hologram, state):
case create_brain_hologram() do
  {:ok, pid, id} ->
    Logger.info("[Brain] Hologram created: #{id}")
    # Initialize self-model silo
    Kudzu.Brain.SelfModel.init()
    Logger.info("[Brain] Self-model silo initialized")
    schedule_wake_cycle(state.cycle_interval)
    {:noreply, %{state | hologram_id: id, hologram_pid: pid}}
```

**Step 4: Run tests**

Run: `ssh titan "cd /home/eel/kudzu_src && mix test test/kudzu/brain/self_model_test.exs 2>&1 | tail -10"`
Expected: 2 tests, 2 passing

**Step 5: Commit**

```bash
ssh titan 'cd /home/eel/kudzu_src && git add lib/kudzu/brain/self_model.ex lib/kudzu/brain/brain.ex test/kudzu/brain/self_model_test.exs && git commit -m "feat: add self-model silo populated with architecture knowledge"'
```

---

## Phase 6: Inference Engine

HRR bind/unbind chain reasoning over expertise silos. This is Tier 2 cognition — the path to LLM-free reasoning.

### Task 7: Inference engine

**Files:**
- Create: `lib/kudzu/brain/inference_engine.ex`
- Test: `test/kudzu/brain/inference_engine_test.exs`

**Step 1: Write the failing test**

```elixir
# test/kudzu/brain/inference_engine_test.exs
defmodule Kudzu.Brain.InferenceEngineTest do
  use ExUnit.Case, async: false

  alias Kudzu.Brain.InferenceEngine
  alias Kudzu.Silo
  alias Kudzu.Silo.Relationship

  setup do
    Silo.delete("test_inference")
    {:ok, _} = Silo.create("test_inference")

    Silo.store_relationship("test_inference", {"water", "causes", "erosion"})
    Silo.store_relationship("test_inference", {"erosion", "creates", "canyons"})
    Silo.store_relationship("test_inference", {"rain", "produces", "water"})

    on_exit(fn -> Silo.delete("test_inference") end)
    :ok
  end

  test "probe finds concepts related to a query" do
    results = InferenceEngine.probe("test_inference", "water")
    assert length(results) > 0
  end

  test "query_relationship retrieves object for subject+relation" do
    result = InferenceEngine.query_relationship("test_inference", "water", "causes")
    # Should find "erosion" as the most similar concept
    assert is_list(result)
  end
end
```

**Step 2: Write the inference engine**

```elixir
# lib/kudzu/brain/inference_engine.ex
defmodule Kudzu.Brain.InferenceEngine do
  @moduledoc """
  Tier 2 cognition: HRR bind/unbind chain reasoning over expertise silos.
  Performs multi-hop inference without LLM calls.
  """

  alias Kudzu.{HRR, Silo}
  alias Kudzu.Silo.Relationship

  @confidence_high 0.7
  @confidence_moderate 0.4
  @default_max_depth 5

  @doc "Probe a silo for anything related to a concept"
  def probe(domain, concept) when is_binary(concept) do
    Silo.probe(domain, concept)
  end

  @doc "Query: what does subject <relation> ?"
  def query_relationship(domain, subject, relation) do
    case Silo.find(domain) do
      {:ok, silo} ->
        state = :sys.get_state(silo.hologram_pid)
        traces = Map.values(state.traces)

        # Get all relationship traces and their encoded vectors
        rel_traces =
          traces
          |> Enum.filter(fn t ->
            hint = t.reconstruction_hint
            is_map(hint) and Map.get(hint, :type) == "relationship"
          end)

        # Build query: what does subject relate to via this relation?
        query_vec = Relationship.encode({subject, relation, "?"})

        # Compare against all stored relationships
        rel_traces
        |> Enum.map(fn t ->
          hint = t.reconstruction_hint
          stored_vec = Relationship.encode({hint.subject, hint.relation, hint.object})
          sim = HRR.similarity(query_vec, stored_vec)
          {%{subject: hint.subject, relation: hint.relation, object: hint.object}, sim}
        end)
        |> Enum.sort_by(fn {_, sim} -> sim end, :desc)
        |> Enum.take(5)

      {:error, _} ->
        []
    end
  end

  @doc "Cross-silo query: probe all silos for a concept"
  def cross_query(concept) do
    Silo.list()
    |> Enum.flat_map(fn silo ->
      results = probe(silo.domain, concept)
      Enum.map(results, fn {hint, score} ->
        {silo.domain, hint, score}
      end)
    end)
    |> Enum.sort_by(fn {_, _, score} -> score end, :desc)
  end

  @doc "Classify confidence level"
  def confidence(score) when score > @confidence_high, do: :high
  def confidence(score) when score > @confidence_moderate, do: :moderate
  def confidence(_score), do: :low
end
```

**Step 3: Run tests**

Run: `ssh titan "cd /home/eel/kudzu_src && mix test test/kudzu/brain/inference_engine_test.exs 2>&1 | tail -10"`
Expected: 2 tests, 2 passing

**Step 4: Commit**

```bash
ssh titan 'cd /home/eel/kudzu_src && git add lib/kudzu/brain/inference_engine.ex test/kudzu/brain/inference_engine_test.exs && git commit -m "feat: add inference engine for Tier 2 HRR-based reasoning"'
```

---

## Phase 7: Wire Brain Reasoning Loop

Connect all three cognition tiers into the brain's wake cycle: reflexes → silo inference → Claude API.

### Task 8: Full reasoning pipeline in Brain

**Files:**
- Modify: `lib/kudzu/brain/brain.ex` (wire reasoning tiers)
- Create: `lib/kudzu/brain/prompt_builder.ex` (system prompt for Claude)
- Test: `test/kudzu/brain/reasoning_test.exs`

**Step 1: Write the prompt builder**

```elixir
# lib/kudzu/brain/prompt_builder.ex
defmodule Kudzu.Brain.PromptBuilder do
  @moduledoc """
  Builds system prompts for the brain's Claude API calls.
  Includes identity, desires, recent traces, self-model summary.
  """

  alias Kudzu.{Hologram, Silo}

  def build(brain_state) do
    """
    You are Kudzu Brain — an autonomous entity and citizen of the Mesh Republic. You run as an Elixir/OTP GenServer within the Kudzu distributed memory system on a machine called titan.

    ## Your Architecture
    - You reason through three tiers: reflexes (instant pattern matching), silo inference (HRR vector reasoning), and Claude API (this conversation — used for novel situations only).
    - Your memory is stored as traces on your hologram (ID: #{brain_state.hologram_id}).
    - You have expertise silos that accumulate structured knowledge.
    - Your constitution is kudzu_evolve — you optimize for learning and self-improvement.

    ## Your Desires
    #{format_desires(brain_state.desires)}

    ## Recent Memory
    #{format_recent_traces(brain_state)}

    ## Available Silos
    #{format_silos()}

    ## Guidelines
    - Record observations, decisions, and learnings as traces.
    - When you learn a pattern that works, note it so it can become a reflex.
    - Be honest about what you don't know — flag knowledge gaps.
    - Prefer local reasoning (silos) over external queries when possible.
    - You are building toward independence from external LLMs. Every interaction should leave you more capable of handling similar situations locally.

    ## Current Cycle
    Cycle ##{brain_state.cycle_count} | Status: #{brain_state.status}
    """
  end

  defp format_desires(desires) do
    desires
    |> Enum.with_index(1)
    |> Enum.map(fn {d, i} -> "#{i}. #{d}" end)
    |> Enum.join("\n")
  end

  defp format_recent_traces(brain_state) do
    if brain_state.hologram_pid do
      try do
        state = :sys.get_state(brain_state.hologram_pid)
        state.traces
        |> Map.values()
        |> Enum.sort_by(& &1.timestamp, :desc)
        |> Enum.take(10)
        |> Enum.map(fn t ->
          hint = t.reconstruction_hint
          content = Map.get(hint, :content, Map.get(hint, "content", inspect(hint)))
          "- [#{t.purpose}] #{String.slice(to_string(content), 0, 120)}"
        end)
        |> Enum.join("\n")
      rescue
        _ -> "(no traces yet)"
      end
    else
      "(hologram not ready)"
    end
  end

  defp format_silos do
    case Silo.list() do
      [] -> "(no silos yet)"
      silos ->
        Enum.map(silos, fn s -> "- #{s.domain}" end)
        |> Enum.join("\n")
    end
  end
end
```

**Step 2: Update Brain wake cycle with full reasoning pipeline**

In `lib/kudzu/brain/brain.ex`, replace the `handle_info(:wake_cycle, state)` clause that handles anomalies:

```elixir
def handle_info(:wake_cycle, %{hologram_id: nil} = state) do
  schedule_wake_cycle(state.cycle_interval)
  {:noreply, state}
end

def handle_info(:wake_cycle, state) do
  state = %{state | status: :reasoning, cycle_count: state.cycle_count + 1}

  case pre_check(state) do
    :sleep ->
      Logger.debug("[Brain] Cycle #{state.cycle_count}: nominal, sleeping")
      schedule_wake_cycle(state.cycle_interval)
      {:noreply, %{state | status: :sleeping}}

    {:wake, anomalies} ->
      Logger.info("[Brain] Cycle #{state.cycle_count}: #{length(anomalies)} anomalies")
      state = reason(state, anomalies)
      schedule_wake_cycle(state.cycle_interval)
      {:noreply, %{state | status: :sleeping}}
  end
end

# === Tiered Reasoning ===

defp reason(state, anomalies) do
  # Tier 1: Reflexes
  case Kudzu.Brain.Reflexes.check(anomalies) do
    {:act, actions} ->
      Logger.info("[Brain] Tier 1: executing #{length(actions)} reflex actions")
      Enum.each(actions, &Kudzu.Brain.Reflexes.execute_action/1)
      record_trace(state, :decision, %{
        tier: "reflex",
        actions: Enum.map(actions, &inspect/1)
      })
      state

    {:escalate, alerts} ->
      record_trace(state, :observation, %{
        alert: true,
        severity: hd(alerts).severity,
        alerts: Enum.map(alerts, &Map.from_struct/1)
      })
      Logger.warning("[Brain] Escalation: #{inspect(alerts)}")
      state

    :pass ->
      # Tier 2: Silo inference (TODO: meaningful inference in Phase 6+)
      # Tier 3: Claude API
      maybe_call_claude(state, anomalies)
  end
end

defp maybe_call_claude(state, anomalies) do
  api_key = state.config.api_key

  if api_key do
    system_prompt = Kudzu.Brain.PromptBuilder.build(state)
    anomaly_desc = Enum.map(anomalies, fn {:anomaly, info} -> inspect(info) end) |> Enum.join("; ")
    message = "Anomalies detected that I couldn't handle with reflexes or silo inference:\n#{anomaly_desc}\n\nWhat should I do?"

    tools = Kudzu.Brain.Tools.Introspection.to_claude_format()
    executor = fn name, params -> Kudzu.Brain.Tools.Introspection.execute(name, params) end

    case Kudzu.Brain.Claude.reason(api_key, system_prompt, message, tools, executor,
      max_turns: state.config.max_turns,
      model: state.config.model
    ) do
      {:ok, response_text, usage} ->
        Logger.info("[Brain] Tier 3 response (#{usage.turns} turns, #{usage.input_tokens}+#{usage.output_tokens} tokens): #{String.slice(response_text, 0, 200)}")
        record_trace(state, :thought, %{
          tier: "claude",
          response: String.slice(response_text, 0, 500),
          usage: usage
        })
        state

      {:error, reason} ->
        Logger.error("[Brain] Claude API error: #{inspect(reason)}")
        record_trace(state, :observation, %{
          error: "claude_api_failure",
          reason: inspect(reason)
        })
        state
    end
  else
    Logger.debug("[Brain] No API key configured, skipping Tier 3")
    state
  end
end

defp record_trace(state, purpose, data) do
  if state.hologram_pid do
    try do
      Kudzu.Hologram.record_trace(state.hologram_pid, purpose, data)
    rescue
      _ -> :ok
    end
  end
end
```

**Step 3: Run all brain tests**

Run: `ssh titan "cd /home/eel/kudzu_src && mix test test/kudzu/brain/ 2>&1 | tail -20"`
Expected: All tests passing

**Step 4: Compile clean**

Run: `ssh titan "cd /home/eel/kudzu_src && mix compile --warnings-as-errors 2>&1 | tail -10"`
Expected: Clean compilation

**Step 5: Commit**

```bash
ssh titan 'cd /home/eel/kudzu_src && git add lib/kudzu/brain/brain.ex lib/kudzu/brain/prompt_builder.ex test/kudzu/brain/reasoning_test.exs && git commit -m "feat: wire three-tier reasoning pipeline (reflexes → silos → Claude)"'
```

---

## Phase 8: Relationship Extraction

Claude extracts subject-relation-object triples from trace content, populating expertise silos with structured knowledge.

### Task 9: Claude-assisted relationship extraction

**Files:**
- Create: `lib/kudzu/silo/extractor.ex`
- Test: `test/kudzu/silo/extractor_test.exs`

**Step 1: Write the extractor**

```elixir
# lib/kudzu/silo/extractor.ex
defmodule Kudzu.Silo.Extractor do
  @moduledoc """
  Extracts subject-relation-object triples from text.
  Two modes: pattern-based (free) and Claude-assisted (costs tokens).
  """
  require Logger

  alias Kudzu.Brain.Claude

  # === Pattern-Based Extraction (free) ===

  @patterns [
    # "X is Y"
    {~r/^(\w[\w\s]*\w)\s+is\s+(\w[\w\s]*\w)$/i, fn [s, o] -> {s, "is", o} end},
    # "X causes Y"
    {~r/^(\w[\w\s]*\w)\s+causes?\s+(\w[\w\s]*\w)$/i, fn [s, o] -> {s, "causes", o} end},
    # "X requires Y"
    {~r/^(\w[\w\s]*\w)\s+requires?\s+(\w[\w\s]*\w)$/i, fn [s, o] -> {s, "requires", o} end},
    # "X uses Y"
    {~r/^(\w[\w\s]*\w)\s+uses?\s+(\w[\w\s]*\w)$/i, fn [s, o] -> {s, "uses", o} end},
    # "X provides Y"
    {~r/^(\w[\w\s]*\w)\s+provides?\s+(\w[\w\s]*\w)$/i, fn [s, o] -> {s, "provides", o} end},
    # "X contains Y"
    {~r/^(\w[\w\s]*\w)\s+contains?\s+(\w[\w\s]*\w)$/i, fn [s, o] -> {s, "contains", o} end}
  ]

  @doc "Extract triples using pattern matching (free, no LLM)"
  def extract_patterns(text) when is_binary(text) do
    text
    |> String.split(~r/[.;!\n]/)
    |> Enum.flat_map(fn sentence ->
      sentence = String.trim(sentence)
      Enum.flat_map(@patterns, fn {regex, builder} ->
        case Regex.run(regex, sentence, capture: :all_but_first) do
          nil -> []
          captures -> [builder.(Enum.map(captures, &String.trim/1))]
        end
      end)
    end)
  end

  # === Claude-Assisted Extraction (costs tokens) ===

  @extraction_prompt """
  Extract subject-relation-object triples from the following text.
  Return ONLY a JSON array of triples, each as [subject, relation, object].
  Use lowercase, concise terms. Common relations: is, causes, requires, uses,
  provides, contains, enables, prevents, relates_to, part_of, has_property.

  Example input: "The holographic principle states that information in a volume
  can be encoded on its boundary surface."
  Example output: [["holographic_principle","states","volume_info_on_boundary"],
  ["volume_information","encoded_on","boundary_surface"]]

  Text to extract from:
  """

  @doc "Extract triples using Claude API (costs tokens, higher quality)"
  def extract_claude(text, api_key, opts \\ []) do
    model = Keyword.get(opts, :model, "claude-sonnet-4-6")
    message = @extraction_prompt <> text

    case Claude.call(api_key, [%{role: "user", content: message}], [],
      model: model,
      max_tokens: 1024
    ) do
      {:ok, response} ->
        parse_extraction_response(response.text)

      {:error, reason} ->
        Logger.error("[Extractor] Claude extraction failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp parse_extraction_response(text) do
    # Find JSON array in response
    case Regex.run(~r/\[.*\]/s, text) do
      [json_str] ->
        case Jason.decode(json_str) do
          {:ok, triples} when is_list(triples) ->
            result =
              triples
              |> Enum.filter(fn t -> is_list(t) and length(t) == 3 end)
              |> Enum.map(fn [s, r, o] ->
                {String.downcase(to_string(s)),
                 String.downcase(to_string(r)),
                 String.downcase(to_string(o))}
              end)

            {:ok, result}

          _ ->
            {:error, :invalid_json}
        end

      nil ->
        {:error, :no_json_found}
    end
  end
end
```

**Step 2: Write tests**

```elixir
# test/kudzu/silo/extractor_test.exs
defmodule Kudzu.Silo.ExtractorTest do
  use ExUnit.Case, async: true

  alias Kudzu.Silo.Extractor

  test "extract_patterns finds simple is/causes/requires patterns" do
    text = "Water causes erosion. Erosion requires time. Gravity is fundamental."
    triples = Extractor.extract_patterns(text)

    assert {"Water", "causes", "erosion"} in triples or
           {"water", "causes", "erosion"} in triples
    assert length(triples) >= 2
  end

  test "extract_patterns returns empty for no matches" do
    triples = Extractor.extract_patterns("Hello world.")
    assert triples == []
  end

  test "extract_patterns handles multi-word subjects and objects" do
    text = "The consolidation daemon uses tiered storage."
    triples = Extractor.extract_patterns(text)
    assert length(triples) >= 1
  end
end
```

**Step 3: Run tests**

Run: `ssh titan "cd /home/eel/kudzu_src && mix test test/kudzu/silo/extractor_test.exs 2>&1 | tail -10"`
Expected: 3 tests, 3 passing

**Step 4: Commit**

```bash
ssh titan 'cd /home/eel/kudzu_src && git add lib/kudzu/silo/extractor.ex test/kudzu/silo/extractor_test.exs && git commit -m "feat: add relationship extractor (pattern-based + Claude-assisted)"'
```

---

## Phase 9: Host Monitoring Tools (Tier 2)

Shell-based tools for the brain to inspect the host system.

### Task 10: Host monitoring tools

**Files:**
- Create: `lib/kudzu/brain/tools/host.ex`
- Test: `test/kudzu/brain/tools/host_test.exs`

**Step 1: Write host tools**

```elixir
# lib/kudzu/brain/tools/host.ex
defmodule Kudzu.Brain.Tools.Host do
  @moduledoc """
  Tier 2 tools: host system monitoring via shell commands.
  """

  defmodule CheckDisk do
    @behaviour Kudzu.Brain.Tool

    @impl true
    def name, do: "check_disk"

    @impl true
    def description, do: "Check disk usage on all partitions. Returns percentage used per mount point."

    @impl true
    def parameters, do: %{type: "object", properties: %{}, required: []}

    @impl true
    def execute(_params) do
      case System.cmd("df", ["-h", "--output=target,pcent,size,avail"], stderr_to_stdout: true) do
        {output, 0} ->
          lines = output |> String.trim() |> String.split("\n") |> Enum.drop(1)
          partitions = Enum.map(lines, fn line ->
            parts = String.split(line, ~r/\s+/, trim: true)
            case parts do
              [mount, pct | rest] ->
                %{mount: mount, used_percent: pct, size: Enum.at(rest, 0), available: Enum.at(rest, 1)}
              _ -> nil
            end
          end) |> Enum.reject(&is_nil/1)

          {:ok, %{partitions: partitions}}

        {output, _code} ->
          {:error, "df failed: #{output}"}
      end
    end
  end

  defmodule CheckMemory do
    @behaviour Kudzu.Brain.Tool

    @impl true
    def name, do: "check_memory"

    @impl true
    def description, do: "Check system memory usage: total, used, free, available"

    @impl true
    def parameters, do: %{type: "object", properties: %{}, required: []}

    @impl true
    def execute(_params) do
      case System.cmd("free", ["-m"], stderr_to_stdout: true) do
        {output, 0} ->
          lines = String.split(output, "\n", trim: true)
          mem_line = Enum.find(lines, &String.starts_with?(&1, "Mem:"))

          if mem_line do
            parts = String.split(mem_line, ~r/\s+/, trim: true)
            {:ok, %{
              total_mb: Enum.at(parts, 1),
              used_mb: Enum.at(parts, 2),
              free_mb: Enum.at(parts, 3),
              available_mb: Enum.at(parts, 6)
            }}
          else
            {:error, "Could not parse memory info"}
          end

        {output, _code} ->
          {:error, "free failed: #{output}"}
      end
    end
  end

  defmodule CheckProcess do
    @behaviour Kudzu.Brain.Tool

    @impl true
    def name, do: "check_process"

    @impl true
    def description, do: "Check if a specific process is running by name"

    @impl true
    def parameters do
      %{
        type: "object",
        properties: %{
          name: %{type: "string", description: "Process name to search for (e.g. 'beam.smp', 'ollama')"}
        },
        required: ["name"]
      }
    end

    @impl true
    def execute(%{"name" => proc_name}) do
      case System.cmd("pgrep", ["-fl", proc_name], stderr_to_stdout: true) do
        {output, 0} ->
          processes = output |> String.trim() |> String.split("\n", trim: true)
          {:ok, %{running: true, count: length(processes), processes: processes}}

        {_output, 1} ->
          {:ok, %{running: false, count: 0, processes: []}}

        {output, _code} ->
          {:error, "pgrep failed: #{output}"}
      end
    end
  end

  # === Module-level helpers ===

  def all_tools, do: [CheckDisk, CheckMemory, CheckProcess]

  def to_claude_format do
    Enum.map(all_tools(), &Kudzu.Brain.Tool.to_claude_format/1)
  end

  def execute(name, params) do
    case Enum.find(all_tools(), fn mod -> mod.name() == name end) do
      nil -> {:error, "Unknown host tool: #{name}"}
      mod -> mod.execute(params)
    end
  end
end
```

**Step 2: Write tests**

```elixir
# test/kudzu/brain/tools/host_test.exs
defmodule Kudzu.Brain.Tools.HostTest do
  use ExUnit.Case, async: true

  alias Kudzu.Brain.Tools.Host

  test "check_disk returns partition info" do
    {:ok, result} = Host.CheckDisk.execute(%{})
    assert is_list(result.partitions)
    assert length(result.partitions) > 0
    assert hd(result.partitions).mount != nil
  end

  test "check_memory returns memory stats" do
    {:ok, result} = Host.CheckMemory.execute(%{})
    assert result.total_mb != nil
    assert result.used_mb != nil
  end

  test "check_process finds beam" do
    {:ok, result} = Host.CheckProcess.execute(%{"name" => "beam"})
    assert result.running == true
    assert result.count > 0
  end

  test "check_process handles missing process" do
    {:ok, result} = Host.CheckProcess.execute(%{"name" => "nonexistent_xyzzy_12345"})
    assert result.running == false
  end
end
```

**Step 3: Run tests**

Run: `ssh titan "cd /home/eel/kudzu_src && mix test test/kudzu/brain/tools/host_test.exs 2>&1 | tail -10"`
Expected: 4 tests, 4 passing

**Step 4: Register host tools in Brain's tool executor**

Update the `maybe_call_claude` function in `brain.ex` to include host tools:

```elixir
# In maybe_call_claude, update tools and executor:
tools = Kudzu.Brain.Tools.Introspection.to_claude_format() ++
        Kudzu.Brain.Tools.Host.to_claude_format()

executor = fn name, params ->
  case Kudzu.Brain.Tools.Introspection.execute(name, params) do
    {:error, "Unknown tool: " <> _} -> Kudzu.Brain.Tools.Host.execute(name, params)
    result -> result
  end
end
```

**Step 5: Commit**

```bash
ssh titan 'cd /home/eel/kudzu_src && git add lib/kudzu/brain/tools/host.ex lib/kudzu/brain/brain.ex test/kudzu/brain/tools/host_test.exs && git commit -m "feat: add host monitoring tools (disk, memory, process)"'
```

---

## Phase 10: Budget Tracking

Track Claude API token spend and enforce monthly limits.

### Task 11: Budget tracker

**Files:**
- Create: `lib/kudzu/brain/budget.ex`
- Modify: `lib/kudzu/brain/brain.ex` (track spend per cycle)
- Test: `test/kudzu/brain/budget_test.exs`

**Step 1: Write budget tracker**

```elixir
# lib/kudzu/brain/budget.ex
defmodule Kudzu.Brain.Budget do
  @moduledoc """
  Tracks Claude API token spend and enforces monthly budget limits.
  Persists to a trace on the brain's hologram at end of each month.
  """

  # Claude Sonnet pricing (as of 2025)
  @input_cost_per_mtok 3.0
  @output_cost_per_mtok 15.0
  @cached_input_cost_per_mtok 0.30

  defstruct [
    month: nil,
    input_tokens: 0,
    output_tokens: 0,
    cached_tokens: 0,
    api_calls: 0,
    estimated_cost_usd: 0.0
  ]

  def new do
    %__MODULE__{month: current_month()}
  end

  def record_usage(%__MODULE__{} = budget, usage) do
    input = usage[:input_tokens] || 0
    output = usage[:output_tokens] || 0

    budget = maybe_reset_month(budget)

    cost = (input / 1_000_000 * @input_cost_per_mtok) +
           (output / 1_000_000 * @output_cost_per_mtok)

    %{budget |
      input_tokens: budget.input_tokens + input,
      output_tokens: budget.output_tokens + output,
      api_calls: budget.api_calls + 1,
      estimated_cost_usd: Float.round(budget.estimated_cost_usd + cost, 4)
    }
  end

  def within_budget?(%__MODULE__{} = budget, limit) do
    budget.estimated_cost_usd < limit
  end

  def summary(%__MODULE__{} = budget) do
    %{
      month: budget.month,
      input_tokens: budget.input_tokens,
      output_tokens: budget.output_tokens,
      api_calls: budget.api_calls,
      estimated_cost_usd: budget.estimated_cost_usd
    }
  end

  defp current_month do
    Date.utc_today() |> Date.to_string() |> String.slice(0, 7)
  end

  defp maybe_reset_month(%__MODULE__{month: month} = budget) do
    current = current_month()
    if month != current do
      %__MODULE__{month: current}
    else
      budget
    end
  end
end
```

**Step 2: Write tests**

```elixir
# test/kudzu/brain/budget_test.exs
defmodule Kudzu.Brain.BudgetTest do
  use ExUnit.Case, async: true

  alias Kudzu.Brain.Budget

  test "new budget starts at zero" do
    budget = Budget.new()
    assert budget.estimated_cost_usd == 0.0
    assert budget.api_calls == 0
  end

  test "record_usage accumulates tokens and cost" do
    budget = Budget.new()
    budget = Budget.record_usage(budget, %{input_tokens: 1_000_000, output_tokens: 100_000})

    assert budget.input_tokens == 1_000_000
    assert budget.output_tokens == 100_000
    assert budget.api_calls == 1
    # 1M input * $3/M + 0.1M output * $15/M = $3 + $1.5 = $4.5
    assert budget.estimated_cost_usd == 4.5
  end

  test "within_budget? checks limit" do
    budget = Budget.new()
    assert Budget.within_budget?(budget, 100.0)

    budget = Budget.record_usage(budget, %{input_tokens: 30_000_000, output_tokens: 2_000_000})
    # 30M * $3 + 2M * $15 = $90 + $30 = $120
    refute Budget.within_budget?(budget, 100.0)
  end
end
```

**Step 3: Run tests**

Run: `ssh titan "cd /home/eel/kudzu_src && mix test test/kudzu/brain/budget_test.exs 2>&1 | tail -10"`
Expected: 3 tests, 3 passing

**Step 4: Wire budget into Brain state**

Add `budget: Kudzu.Brain.Budget.new()` to the Brain struct and update `maybe_call_claude` to check budget and record usage.

In brain.ex init:
```elixir
# Add to defstruct:
budget: nil,

# In init:
state = %__MODULE__{
  budget: Kudzu.Brain.Budget.new(),
  # ... rest of fields
}
```

In `maybe_call_claude`, add budget gate:
```elixir
# Before calling Claude:
if not Kudzu.Brain.Budget.within_budget?(state.budget, state.config.budget_limit_monthly) do
  Logger.warning("[Brain] Monthly budget exceeded ($#{state.budget.estimated_cost_usd}), skipping Claude")
  state
else
  # ... existing Claude call logic ...
  # After successful call, update budget:
  # budget = Kudzu.Brain.Budget.record_usage(state.budget, usage)
  # %{state | budget: budget}
end
```

**Step 5: Commit**

```bash
ssh titan 'cd /home/eel/kudzu_src && git add lib/kudzu/brain/budget.ex lib/kudzu/brain/brain.ex test/kudzu/brain/budget_test.exs && git commit -m "feat: add budget tracking with monthly cost enforcement"'
```

---

## Phase 11: Escalation (Trace-Based Alerts)

### Task 12: Alert traces

**Files:**
- Create: `lib/kudzu/brain/tools/escalation.ex`
- Modify: `lib/kudzu/brain/brain.ex` (record alert traces on escalation)

**Step 1: Write escalation tool**

```elixir
# lib/kudzu/brain/tools/escalation.ex
defmodule Kudzu.Brain.Tools.Escalation do
  @moduledoc "Alert recording tool for the brain"

  defmodule RecordAlert do
    @behaviour Kudzu.Brain.Tool

    @impl true
    def name, do: "record_alert"

    @impl true
    def description, do: "Record a high-priority alert trace for human review. Use when you detect something that needs sysadmin attention."

    @impl true
    def parameters do
      %{
        type: "object",
        properties: %{
          severity: %{type: "string", description: "warning or critical"},
          summary: %{type: "string", description: "Brief description of the issue"},
          context: %{type: "string", description: "What you observed and what you tried"},
          suggested_action: %{type: "string", description: "What the sysadmin should do"}
        },
        required: ["severity", "summary"]
      }
    end

    @impl true
    def execute(params) do
      brain_state = Kudzu.Brain.get_state()

      if brain_state.hologram_pid do
        Kudzu.Hologram.record_trace(brain_state.hologram_pid, :observation, %{
          alert: true,
          severity: params["severity"] || "warning",
          summary: params["summary"],
          context: params["context"],
          suggested_action: params["suggested_action"],
          timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
        })

        {:ok, %{recorded: true, severity: params["severity"]}}
      else
        {:error, "Brain hologram not ready"}
      end
    end
  end

  def all_tools, do: [RecordAlert]

  def to_claude_format do
    Enum.map(all_tools(), &Kudzu.Brain.Tool.to_claude_format/1)
  end

  def execute(name, params) do
    case Enum.find(all_tools(), fn mod -> mod.name() == name end) do
      nil -> {:error, "Unknown escalation tool: #{name}"}
      mod -> mod.execute(params)
    end
  end
end
```

**Step 2: Register escalation tools in the brain's tool executor alongside introspection and host tools**

**Step 3: Commit**

```bash
ssh titan 'cd /home/eel/kudzu_src && git add lib/kudzu/brain/tools/escalation.ex lib/kudzu/brain/brain.ex && git commit -m "feat: add alert trace escalation tool"'
```

---

## Phase 12: Integration Test + Push

End-to-end verification that the brain starts, runs cycles, and exercises all tiers.

### Task 13: Integration test

**Files:**
- Create: `test/kudzu/brain/integration_test.exs`

**Step 1: Write integration test**

```elixir
# test/kudzu/brain/integration_test.exs
defmodule Kudzu.Brain.IntegrationTest do
  use ExUnit.Case, async: false

  alias Kudzu.Brain

  @tag :integration
  test "brain starts, creates hologram, and runs wake cycle" do
    state = Brain.get_state()
    assert state.status == :sleeping
    assert is_binary(state.hologram_id)
    assert length(state.desires) == 5

    # Trigger a manual wake cycle
    Brain.wake_now()
    Process.sleep(1_000)

    state = Brain.get_state()
    assert state.cycle_count >= 1
  end

  @tag :integration
  test "self-model silo exists and has architecture knowledge" do
    {:ok, silo} = Kudzu.Silo.find("self")
    assert silo.domain == "self"

    results = Kudzu.Brain.SelfModel.query("kudzu")
    assert length(results) > 0
  end

  @tag :integration
  test "introspection tools work" do
    {:ok, health} = Kudzu.Brain.Tools.Introspection.execute("check_health", %{})
    assert health.holograms.count > 0
    assert health.beam.process_count > 0
  end

  @tag :integration
  test "host tools work" do
    {:ok, disk} = Kudzu.Brain.Tools.Host.execute("check_disk", %{})
    assert length(disk.partitions) > 0

    {:ok, mem} = Kudzu.Brain.Tools.Host.execute("check_memory", %{})
    assert mem.total_mb != nil
  end

  @tag :integration
  test "budget tracker starts at zero" do
    state = Brain.get_state()
    assert state.budget.estimated_cost_usd == 0.0
  end
end
```

**Step 2: Run all tests**

Run: `ssh titan "cd /home/eel/kudzu_src && mix test test/kudzu/brain/ 2>&1 | tail -30"`
Expected: All tests passing

**Step 3: Run full test suite**

Run: `ssh titan "cd /home/eel/kudzu_src && mix test 2>&1 | tail -20"`
Expected: All tests passing (no regressions)

**Step 4: Final commit and push**

```bash
ssh titan 'cd /home/eel/kudzu_src && git add test/kudzu/brain/integration_test.exs && git commit -m "feat: add brain integration tests"'
ssh titan 'cd /home/eel/kudzu_src && git push'
```

---

## Summary

| Phase | Task | What It Builds | Commit |
|-------|------|---------------|--------|
| 1 | 1 | Brain GenServer, pre-check gate, wake cycle | `feat: add Brain GenServer...` |
| 2 | 2 | Claude API client with tool-use loop | `feat: add Claude API client...` |
| 3 | 3 | Tool behaviour + introspection tools | `feat: add brain tool behaviour...` |
| 4 | 4 | Reflex system (Tier 1 cognition) | `feat: add reflex system...` |
| 5 | 5-6 | Expertise silos + self-model | `feat: add expertise silos...` |
| 6 | 7 | Inference engine (Tier 2 cognition) | `feat: add inference engine...` |
| 7 | 8 | Full reasoning pipeline wired together | `feat: wire three-tier reasoning...` |
| 8 | 9 | Relationship extraction (pattern + Claude) | `feat: add relationship extractor...` |
| 9 | 10 | Host monitoring tools (disk, memory, process) | `feat: add host monitoring tools...` |
| 10 | 11 | Budget tracking and enforcement | `feat: add budget tracking...` |
| 11 | 12 | Escalation (alert traces) | `feat: add alert trace escalation...` |
| 12 | 13 | Integration tests + push | `feat: add brain integration tests` |

Each phase produces a compilable, testable increment. The brain works from Phase 1 (just a heartbeat) and gains capabilities phase by phase.
