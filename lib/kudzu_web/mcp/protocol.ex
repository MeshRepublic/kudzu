defmodule KudzuWeb.MCP.Protocol do
  @moduledoc "JSON-RPC 2.0 encoding/decoding for MCP Streamable HTTP."

  def encode_response(id, result) do
    %{"jsonrpc" => "2.0", "id" => id, "result" => result}
  end

  def encode_error(id, code, message) do
    %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}}
  end

  def parse_request(body) when is_list(body) do
    {:batch, Enum.map(body, &parse_request/1)}
  end

  def parse_request(%{"jsonrpc" => "2.0", "id" => id, "method" => method} = body) do
    {:request, id, method, Map.get(body, "params", %{})}
  end

  def parse_request(%{"jsonrpc" => "2.0", "method" => method} = body) do
    {:notification, method, Map.get(body, "params", %{})}
  end

  def parse_request(_), do: {:error, :invalid_request}
end
