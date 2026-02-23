defmodule KudzuWeb.MCP.ProtocolTest do
  use ExUnit.Case, async: true
  alias KudzuWeb.MCP.Protocol

  describe "encode_response/2" do
    test "encodes a successful result" do
      result = Protocol.encode_response("req-1", %{tools: []})
      assert result == %{"jsonrpc" => "2.0", "id" => "req-1", "result" => %{tools: []}}
    end
  end

  describe "encode_error/3" do
    test "encodes a JSON-RPC error" do
      result = Protocol.encode_error("req-1", -32601, "Method not found")
      assert result == %{
        "jsonrpc" => "2.0",
        "id" => "req-1",
        "error" => %{"code" => -32601, "message" => "Method not found"}
      }
    end
  end

  describe "parse_request/1" do
    test "parses a valid JSON-RPC request" do
      body = %{"jsonrpc" => "2.0", "id" => "r1", "method" => "tools/list", "params" => %{}}
      assert {:request, "r1", "tools/list", %{}} = Protocol.parse_request(body)
    end

    test "parses a notification (no id)" do
      body = %{"jsonrpc" => "2.0", "method" => "initialized"}
      assert {:notification, "initialized", %{}} = Protocol.parse_request(body)
    end

    test "returns error for invalid request" do
      assert {:error, :invalid_request} = Protocol.parse_request(%{"foo" => "bar"})
    end

    test "parses a batch of requests" do
      batch = [
        %{"jsonrpc" => "2.0", "id" => "1", "method" => "ping"},
        %{"jsonrpc" => "2.0", "method" => "initialized"}
      ]
      assert {:batch, parsed} = Protocol.parse_request(batch)
      assert length(parsed) == 2
    end
  end
end
