defmodule KudzuWeb.MCP.HandlersTest do
  use ExUnit.Case, async: false

  alias KudzuWeb.MCP.Handlers.{System, Hologram, Trace}

  test "system health returns status ok" do
    {:ok, result} = System.handle("kudzu_health", %{})
    assert result.status == "ok"
  end

  test "hologram list returns list" do
    {:ok, result} = Hologram.handle("kudzu_list_holograms", %{})
    assert is_list(result.holograms)
  end

  test "hologram create and get" do
    {:ok, created} = Hologram.handle("kudzu_create_hologram", %{"purpose" => "test_mcp"})
    assert created.id
    {:ok, got} = Hologram.handle("kudzu_get_hologram", %{"id" => created.id})
    assert got.id == created.id
  end

  test "trace list returns list" do
    {:ok, result} = Trace.handle("kudzu_list_traces", %{})
    assert is_list(result.traces)
  end
end
