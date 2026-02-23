defmodule KudzuWeb.MCP.Handlers.System do
  @moduledoc "MCP handler for system tools."

  def handle("kudzu_health", _params) do
    ollama_ok = try do
      case :httpc.request(:get, {~c"http://localhost:11434/api/tags", []}, [timeout: 2000], []) do
        {:ok, {{_, 200, _}, _, _}} -> true
        _ -> false
      end
    rescue
      _ -> false
    end

    {:ok, %{
      status: "ok",
      node: to_string(Node.self()),
      distributed: Node.alive?(),
      holograms: Kudzu.Application.hologram_count(),
      ollama: ollama_ok,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }}
  end
end
