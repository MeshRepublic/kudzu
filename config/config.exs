import Config

# Telemetry console logging (set to true for debug output)
config :kudzu, telemetry_console: false

# HRR backend: Kudzu.HRR.NxBackend (Nx tensors) or nil (legacy pure-Elixir)
config :kudzu, :hrr_backend, Kudzu.HRR.NxBackend

# Use EXLA (XLA GPU/CPU) as the default Nx backend
# Routes all Nx tensor operations through XLA — uses CUDA GPU when available
config :nx, :default_backend, Nx.BinaryBackend

# Ollama LLM configuration
# Can be overridden per-hologram with :ollama_url option
config :kudzu,
  ollama_url: "http://localhost:11434",
  default_model: "mistral:latest",
  cognition_timeout: 120_000

# Security configuration
# IMPORTANT: Configure these before deploying to production
config :kudzu,
  # Environment (:dev, :test, :prod) - :open constitution blocked in :prod
  env: config_env(),
  # Allowed paths for file IO operations (empty list = no file access)
  # Example: ["/var/kudzu/data", "/tmp/kudzu"]
  allowed_io_paths: []

# Consolidated endpoint (MCP + REST API + WebSocket) — Tailscale IP, port 4001
config :kudzu, KudzuWeb.MCP.Endpoint,
  url: [host: "localhost"],
  http: [ip: {100, 70, 67, 110}, port: 4001],
  server: true,
  secret_key_base: "generate-a-secret-key-with-mix-phx-gen-secret",
  pubsub_server: Kudzu.PubSub

# API authentication
# IMPORTANT: api_keys is populated at runtime from KUDZU_API_KEY in config/runtime.exs.
# The compile-time default below is `nil` so the app refuses to start if runtime.exs
# fails to set it. NEVER add a hardcoded fallback key here.
config :kudzu, :api_auth,
  enabled: true,
  api_keys: nil

# CORS allowed origins (use specific origins in production)
config :kudzu, :cors_origins, ["*"]

# Phoenix JSON library
config :phoenix, :json_library, Jason

# Logger configuration
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

if config_env() == :test do
  config :logger, level: :warning
  # Allow /tmp for test file operations
  config :kudzu, allowed_io_paths: ["/tmp"]
  # Use different port for tests to avoid conflicts
  config :kudzu, KudzuWeb.MCP.Endpoint,
    http: [port: 4003],
    server: false

  import_config "test.exs"
end

if config_env() == :dev do
  config :kudzu, telemetry_console: true
  # Dev-friendly endpoint settings
  config :kudzu, KudzuWeb.MCP.Endpoint,
    debug_errors: true,
    code_reloader: false,
    check_origin: false
end

if config_env() == :prod do
  # Production requires these environment variables (enforced in config/runtime.exs):
  # - SECRET_KEY_BASE: generate with `mix phx.gen.secret`
  # - KUDZU_API_KEY: comma-separated API keys
  config :kudzu, KudzuWeb.MCP.Endpoint,
    secret_key_base: System.get_env("SECRET_KEY_BASE")

  config :kudzu, :cors_origins,
    String.split(System.get_env("KUDZU_CORS_ORIGINS") || "", ",", trim: true)

  # MCP endpoint: use env vars for IP/port
  mcp_ip = System.get_env("KUDZU_MCP_IP", "100.70.67.110")
  |> String.split(".") |> Enum.map(&String.to_integer/1) |> List.to_tuple()
  mcp_port = String.to_integer(System.get_env("KUDZU_MCP_PORT") || "4001")
  config :kudzu, KudzuWeb.MCP.Endpoint,
    http: [ip: mcp_ip, port: mcp_port]
end

# Example distributed configuration (uncomment and modify for your setup)
# config :kudzu,
#   ollama_url: "http://<tailscale-ip>:11434"  # Tailscale IP of Ollama server

# EXLA default defn compiler — routes defn functions through XLA
config :nx, :default_defn_options, []
