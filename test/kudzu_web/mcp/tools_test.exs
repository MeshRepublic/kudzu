defmodule KudzuWeb.MCP.ToolsTest do
  use ExUnit.Case, async: true
  alias KudzuWeb.MCP.Tools

  test "list returns all tool definitions" do
    tools = Tools.list()
    assert is_list(tools)
    assert length(tools) > 40
    assert Enum.all?(tools, fn t -> Map.has_key?(t, :name) end)
    assert Enum.all?(tools, fn t -> Map.has_key?(t, :description) end)
    assert Enum.all?(tools, fn t -> Map.has_key?(t, :inputSchema) end)
  end

  test "all tool names are prefixed with kudzu_" do
    tools = Tools.list()
    assert Enum.all?(tools, fn t -> String.starts_with?(t.name, "kudzu_") end)
  end

  test "all tool names are unique" do
    tools = Tools.list()
    names = Enum.map(tools, & &1.name)
    assert names == Enum.uniq(names)
  end

  test "lookup finds a tool by name" do
    assert {:ok, tool} = Tools.lookup("kudzu_health")
    assert tool.name == "kudzu_health"
  end

  test "lookup returns error for unknown tool" do
    assert {:error, :not_found} = Tools.lookup("unknown_tool")
  end
end
