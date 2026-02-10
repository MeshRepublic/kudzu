defmodule KudzuWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :kudzu

  # WebSocket transport for real-time hologram interaction
  socket "/socket", KudzuWeb.HologramSocket,
    websocket: [timeout: 120_000],
    longpoll: false

  # Serve static files if needed (for potential dashboard)
  plug Plug.Static,
    at: "/",
    from: :kudzu,
    gzip: false,
    only: ~w(assets fonts images favicon.ico robots.txt)

  # Request logging
  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  # Parse request body
  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Jason

  plug Plug.MethodOverride
  plug Plug.Head

  # CORS for cross-origin API access
  plug CORSPlug,
    origin: &KudzuWeb.Endpoint.allowed_origins/0,
    methods: ["GET", "POST", "PUT", "DELETE", "OPTIONS"],
    headers: ["Authorization", "Content-Type", "X-Hologram-ID"]

  plug KudzuWeb.Router

  @doc """
  Get allowed CORS origins from config.
  """
  def allowed_origins do
    Application.get_env(:kudzu, :cors_origins, ["*"])
  end
end
