defmodule KudzuWeb.MCP.IntegrationTest do
  use ExUnit.Case, async: false

  alias KudzuWeb.MCP.Controller

  test "full MCP lifecycle: initialize, list tools, call tool" do
    # 1. Initialize
    {:response, init_resp} = Controller.dispatch(
      {:request, "1", "initialize", %{
        "protocolVersion" => "2025-03-26",
        "capabilities" => %{},
        "clientInfo" => %{"name" => "test", "version" => "1.0"}
      }}
    )
    assert init_resp["result"]["serverInfo"]["name"] == "kudzu"

    # 2. Initialized notification
    assert :accepted = Controller.dispatch({:notification, "initialized", %{}})

    # 3. List tools
    {:response, tools_resp} = Controller.dispatch({:request, "2", "tools/list", %{}})
    tools = tools_resp["result"]["tools"]
    assert length(tools) > 40
    names = Enum.map(tools, & &1["name"])
    assert "kudzu_health" in names
    assert "kudzu_create_agent" in names

    # 4. Call health tool
    {:response, health_resp} = Controller.dispatch(
      {:request, "3", "tools/call", %{"name" => "kudzu_health", "arguments" => %{}}}
    )
    [content | _] = health_resp["result"]["content"]
    assert content["type"] == "text"
    parsed = Jason.decode!(content["text"])
    assert parsed["status"] == "ok"

    # 5. Create and use an agent
    {:response, create_resp} = Controller.dispatch(
      {:request, "4", "tools/call", %{
        "name" => "kudzu_create_agent",
        "arguments" => %{"name" => "mcp_test_agent"}
      }}
    )
    [c | _] = create_resp["result"]["content"]
    agent_result = Jason.decode!(c["text"])
    assert agent_result["status"] == "created"

    # 6. Remember something
    {:response, _} = Controller.dispatch(
      {:request, "5", "tools/call", %{
        "name" => "kudzu_agent_remember",
        "arguments" => %{"name" => "mcp_test_agent", "content" => "MCP integration works"}
      }}
    )

    # 7. Recall
    {:response, recall_resp} = Controller.dispatch(
      {:request, "6", "tools/call", %{
        "name" => "kudzu_agent_recall",
        "arguments" => %{"name" => "mcp_test_agent"}
      }}
    )
    [rc | _] = recall_resp["result"]["content"]
    recall_result = Jason.decode!(rc["text"])
    assert recall_result["count"] >= 1

    # 8. Cleanup
    Controller.dispatch(
      {:request, "7", "tools/call", %{
        "name" => "kudzu_delete_agent",
        "arguments" => %{"name" => "mcp_test_agent"}
      }}
    )
  end
end
