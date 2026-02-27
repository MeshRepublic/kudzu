defmodule KudzuWeb.MCP.Handlers.Web do
  @moduledoc "MCP handler for web search and read tools."

  alias Kudzu.Brain.Tools.Web

  def handle("kudzu_web_search", params) do
    case Web.execute("web_search", params) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, -32603, reason}
    end
  end

  def handle("kudzu_web_read", params) do
    case Web.execute("web_read", params) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, -32603, reason}
    end
  end

  def handle(tool, _args), do: {:error, -32602, "Unknown web tool: #{tool}"}
end
