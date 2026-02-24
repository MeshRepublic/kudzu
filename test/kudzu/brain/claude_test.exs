defmodule Kudzu.Brain.ClaudeTest do
  use ExUnit.Case, async: true

  alias Kudzu.Brain.Claude
  alias Kudzu.Brain.Claude.{Response, ToolCall}

  test "build_request creates valid request body" do
    body =
      Claude.build_request(
        [%{role: "user", content: "Hello"}],
        [
          %{
            name: "test",
            description: "Test tool",
            input_schema: %{type: "object", properties: %{}, required: []}
          }
        ],
        model: "claude-sonnet-4-6",
        system: "You are helpful.",
        max_tokens: 1024
      )

    assert body["model"] == "claude-sonnet-4-6"
    assert body["max_tokens"] == 1024
    assert body["system"] == "You are helpful."
    assert length(body["messages"]) == 1
    assert length(body["tools"]) == 1
  end

  test "build_request without optional fields" do
    body = Claude.build_request([%{role: "user", content: "Hi"}])
    assert body["model"] == "claude-sonnet-4-6"
    refute Map.has_key?(body, "system")
    refute Map.has_key?(body, "tools")
  end

  test "build_request normalizes atom keys to string keys" do
    body = Claude.build_request([%{role: :user, content: "Hello"}])
    [msg] = body["messages"]
    assert msg["role"] == "user"
    assert msg["content"] == "Hello"
  end

  test "build_request passes through string-keyed messages" do
    body = Claude.build_request([%{"role" => "assistant", "content" => "Hi"}])
    [msg] = body["messages"]
    assert msg["role"] == "assistant"
    assert msg["content"] == "Hi"
  end

  test "build_request preserves list content (multi-block messages)" do
    blocks = [%{"type" => "text", "text" => "Hello"}]
    body = Claude.build_request([%{role: "user", content: blocks}])
    [msg] = body["messages"]
    assert msg["content"] == blocks
  end

  test "parse_response extracts text" do
    resp = %{
      "content" => [%{"type" => "text", "text" => "Hello!"}],
      "stop_reason" => "end_turn",
      "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
    }

    result = Claude.parse_response(resp)
    assert result.text == "Hello!"
    assert result.tool_calls == []
    assert result.stop_reason == "end_turn"
    assert result.usage.input_tokens == 10
    assert result.usage.output_tokens == 5
  end

  test "parse_response joins multiple text blocks" do
    resp = %{
      "content" => [
        %{"type" => "text", "text" => "Hello "},
        %{"type" => "text", "text" => "world!"}
      ],
      "stop_reason" => "end_turn",
      "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
    }

    result = Claude.parse_response(resp)
    assert result.text == "Hello world!"
  end

  test "parse_response extracts tool calls" do
    resp = %{
      "content" => [
        %{"type" => "text", "text" => "Checking..."},
        %{
          "type" => "tool_use",
          "id" => "toolu_1",
          "name" => "check_health",
          "input" => %{"verbose" => true}
        }
      ],
      "stop_reason" => "tool_use",
      "usage" => %{"input_tokens" => 50, "output_tokens" => 30}
    }

    result = Claude.parse_response(resp)
    assert result.text == "Checking..."
    assert length(result.tool_calls) == 1

    tc = hd(result.tool_calls)
    assert %ToolCall{} = tc
    assert tc.id == "toolu_1"
    assert tc.name == "check_health"
    assert tc.input == %{"verbose" => true}
    assert result.stop_reason == "tool_use"
  end

  test "parse_response handles multiple tool calls" do
    resp = %{
      "content" => [
        %{"type" => "tool_use", "id" => "t1", "name" => "foo", "input" => %{}},
        %{"type" => "tool_use", "id" => "t2", "name" => "bar", "input" => %{"x" => 1}}
      ],
      "stop_reason" => "tool_use",
      "usage" => %{"input_tokens" => 20, "output_tokens" => 15}
    }

    result = Claude.parse_response(resp)
    assert result.text == ""
    assert length(result.tool_calls) == 2
    assert Enum.map(result.tool_calls, & &1.name) == ["foo", "bar"]
  end

  test "parse_response handles empty content" do
    resp = %{
      "content" => [],
      "stop_reason" => "end_turn",
      "usage" => %{"input_tokens" => 5, "output_tokens" => 0}
    }

    result = Claude.parse_response(resp)
    assert result.text == ""
    assert result.tool_calls == []
  end

  test "parse_response handles missing usage gracefully" do
    resp = %{
      "content" => [%{"type" => "text", "text" => "Hi"}],
      "stop_reason" => "end_turn"
    }

    result = Claude.parse_response(resp)
    assert result.usage.input_tokens == 0
    assert result.usage.output_tokens == 0
  end

  test "build_tool_result creates proper message from map" do
    msg = Claude.build_tool_result("toolu_1", %{status: "ok"})
    assert msg.role == "user"
    [block] = msg.content
    assert block["type"] == "tool_result"
    assert block["tool_use_id"] == "toolu_1"
    assert is_binary(block["content"])
    # Should be valid JSON
    assert {:ok, decoded} = Jason.decode(block["content"])
    assert decoded["status"] == "ok"
  end

  test "build_tool_result handles string result" do
    msg = Claude.build_tool_result("toolu_2", "raw text result")
    [block] = msg.content
    assert block["content"] == "raw text result"
  end

  test "build_tool_result handles list result" do
    msg = Claude.build_tool_result("toolu_3", [1, 2, 3])
    [block] = msg.content
    assert block["content"] == "[1,2,3]"
  end

  test "Response struct has correct defaults" do
    r = %Response{}
    assert r.text == ""
    assert r.tool_calls == []
    assert r.stop_reason == nil
    assert r.usage == %{}
  end

  test "ToolCall struct fields" do
    tc = %ToolCall{id: "t1", name: "test", input: %{"a" => 1}}
    assert tc.id == "t1"
    assert tc.name == "test"
    assert tc.input == %{"a" => 1}
  end
end
