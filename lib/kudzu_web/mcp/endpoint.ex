defmodule KudzuWeb.MCP.Endpoint do
  @moduledoc """
  Consolidated Phoenix endpoint — serves both MCP JSON-RPC and the
  full REST/WebSocket API.  Listens on Tailscale IP, port 4001.

  Route priority: MCP routes (Plug.Router) match first, then
  unmatched requests fall through to KudzuWeb.Router (Phoenix).
  """
  use Phoenix.Endpoint, otp_app: :kudzu

  # WebSocket transport for real-time hologram interaction
  socket "/socket", KudzuWeb.HologramSocket,
    websocket: [timeout: 120_000],
    longpoll: false

  # Serve static files (for potential dashboard)
  plug Plug.Static,
    at: "/",
    from: :kudzu,
    gzip: false,
    only: ~w(assets fonts images favicon.ico robots.txt)

  # Request logging
  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :mcp_endpoint]

  # Parse request body
  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Jason

  plug Plug.MethodOverride
  plug Plug.Head

  # CORS for cross-origin API access
  plug CORSPlug,
    origin: &KudzuWeb.MCP.Endpoint.allowed_origins/0,
    methods: ["GET", "POST", "PUT", "DELETE", "OPTIONS"],
    headers: ["Authorization", "Content-Type", "X-Hologram-ID"]

  # MCP routes match first, unmatched fall through to Phoenix router
  plug KudzuWeb.MCP.Router

  @doc """
  Get allowed CORS origins from config.
  """
  def allowed_origins do
    Application.get_env(:kudzu, :cors_origins, ["*"])
  end
end
