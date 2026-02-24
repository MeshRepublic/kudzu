defmodule Kudzu.Brain.Tools.IntrospectionTest do
  use ExUnit.Case, async: false

  alias Kudzu.Brain.Tool
  alias Kudzu.Brain.Tools.Introspection
  alias Kudzu.Brain.Tools.Introspection.{CheckHealth, ListHolograms, CheckConsolidation, SemanticRecall}

  # ── all_tools/0 ───────────────────────────────────────────────────

  test "all_tools returns 4 modules" do
    tools = Introspection.all_tools()
    assert length(tools) == 4
    assert CheckHealth in tools
    assert ListHolograms in tools
    assert CheckConsolidation in tools
    assert SemanticRecall in tools
  end

  # ── to_claude_format/0 ───────────────────────────────────────────

  test "to_claude_format produces valid tool definitions" do
    defs = Introspection.to_claude_format()
    assert length(defs) == 4

    for def <- defs do
      assert is_binary(def.name)
      assert is_binary(def.description)
      assert is_map(def.input_schema)
      assert def.input_schema[:type] == "object" or def.input_schema["type"] == "object"
    end
  end

  test "to_claude_format tool names are unique" do
    names = Enum.map(Introspection.to_claude_format(), & &1.name)
    assert names == Enum.uniq(names)
  end

  # ── execute/2 dispatch ───────────────────────────────────────────

  test "execute dispatches check_health by name" do
    assert {:ok, result} = Introspection.execute("check_health", %{})
    assert is_map(result)
    assert Map.has_key?(result, :beam)
  end

  test "execute dispatches list_holograms by name" do
    assert {:ok, result} = Introspection.execute("list_holograms", %{})
    assert is_map(result)
    assert Map.has_key?(result, :holograms)
    assert Map.has_key?(result, :count)
  end

  test "execute dispatches check_consolidation by name" do
    assert {:ok, result} = Introspection.execute("check_consolidation", %{})
    assert is_map(result)
    assert Map.has_key?(result, :stats)
    assert Map.has_key?(result, :encoder)
  end

  test "execute dispatches semantic_recall by name" do
    assert {:ok, result} = Introspection.execute("semantic_recall", %{"query" => "health"})
    assert is_map(result)
    assert Map.has_key?(result, :query)
    assert result.query == "health"
  end

  test "execute returns error for unknown tool name" do
    assert {:error, msg} = Introspection.execute("nonexistent_tool", %{})
    assert is_binary(msg)
    assert msg =~ "unknown tool"
  end

  # ── CheckHealth ──────────────────────────────────────────────────

  test "check_health returns map with beam.process_count > 0" do
    assert {:ok, health} = CheckHealth.execute(%{})
    assert health.beam.process_count > 0
    assert health.beam.memory_mb > 0
    assert health.beam.uptime_seconds >= 0
  end

  test "check_health includes holograms section" do
    assert {:ok, health} = CheckHealth.execute(%{})
    assert is_integer(health.holograms.count)
    assert health.holograms.status == "ok"
  end

  test "check_health includes consolidation section" do
    assert {:ok, health} = CheckHealth.execute(%{})
    assert health.consolidation.status in ["ok", "unreachable"]
  end

  test "check_health includes encoder section" do
    assert {:ok, health} = CheckHealth.execute(%{})
    assert health.encoder.status in ["ok", "unreachable"]
  end

  # ── ListHolograms ────────────────────────────────────────────────

  test "list_holograms returns a list" do
    assert {:ok, result} = ListHolograms.execute(%{})
    assert is_list(result.holograms)
    assert is_integer(result.count)
    assert result.count == length(result.holograms)
  end

  # ── Tool behaviour ───────────────────────────────────────────────

  test "Tool.to_claude_format/1 works for each tool module" do
    for module <- Introspection.all_tools() do
      formatted = Tool.to_claude_format(module)
      assert is_binary(formatted.name)
      assert is_binary(formatted.description)
      assert is_map(formatted.input_schema)
    end
  end

  # ── SemanticRecall parameters ────────────────────────────────────

  test "semantic_recall respects limit parameter" do
    assert {:ok, result} = SemanticRecall.execute(%{"query" => "test", "limit" => 2})
    assert length(result.results) <= 2
  end

  test "semantic_recall uses default limit of 5" do
    assert {:ok, result} = SemanticRecall.execute(%{"query" => "test"})
    assert length(result.results) <= 5
  end
end
