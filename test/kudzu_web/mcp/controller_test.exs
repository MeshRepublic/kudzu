defmodule KudzuWeb.MCP.ControllerTest do
  use ExUnit.Case, async: false

  alias KudzuWeb.MCP.Controller

  test "dispatch initialize returns capabilities" do
    {:response, result} = Controller.dispatch(
      {:request, "1", "initialize", %{"protocolVersion" => "2025-03-26"}}
    )
    assert result["result"]["protocolVersion"] == "2025-03-26"
    assert result["result"]["capabilities"]["tools"]
    assert result["result"]["serverInfo"]["name"] == "kudzu"
  end

  test "dispatch tools/list returns tools" do
    {:response, result} = Controller.dispatch(
      {:request, "2", "tools/list", %{}}
    )
    assert is_list(result["result"]["tools"])
    assert length(result["result"]["tools"]) > 40
  end

  test "dispatch tools/call for kudzu_health" do
    {:response, result} = Controller.dispatch(
      {:request, "3", "tools/call", %{"name" => "kudzu_health", "arguments" => %{}}}
    )
    assert result["result"]["content"]
    [content | _] = result["result"]["content"]
    assert content["type"] == "text"
  end

  test "dispatch initialized returns :accepted" do
    assert :accepted = Controller.dispatch({:notification, "initialized", %{}})
  end

  test "dispatch ping returns pong" do
    {:response, result} = Controller.dispatch({:request, "4", "ping", %{}})
    assert result["result"] == %{}
  end
end
