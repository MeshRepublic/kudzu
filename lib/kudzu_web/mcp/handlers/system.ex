defmodule KudzuWeb.MCP.Handlers.System do
  @moduledoc "MCP handler for system tools."

  def handle("kudzu_health", _params) do
    # Same probe as GET /health, honouring `config :kudzu, :ollama_url`.
    ollama_ok = Kudzu.Cognition.available?()

    {:ok,
     %{
       status: "ok",
       node: to_string(Node.self()),
       distributed: Node.alive?(),
       holograms: Kudzu.Application.hologram_count(),
       ollama: ollama_ok,
       timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
     }}
  end
end
