defmodule KudzuWeb.HealthController do
  use Phoenix.Controller

  @doc """
  Health check endpoint.
  GET /health
  """
  def index(conn, _params) do
    # Count only :id entries to get unique hologram count
    hologram_count = Registry.select(Kudzu.Registry, [{{{:id, :_}, :_, :_}, [], [true]}])
    |> length()

    json(conn, %{
      status: "ok",
      node: Node.self(),
      distributed: Node.alive?(),
      holograms: hologram_count,
      ollama: Kudzu.Cognition.available?(),
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    })
  end
end
