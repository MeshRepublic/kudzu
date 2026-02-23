import Config

# Telemetry console logging (set to true for debug output)
config :kudzu, telemetry_console: false

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

# Phoenix API endpoint configuration
config :kudzu, KudzuWeb.Endpoint,
  url: [host: "localhost"],
  http: [ip: {0, 0, 0, 0}, port: 4000],
  secret_key_base: "generate-a-secret-key-with-mix-phx-gen-secret",
  server: true,
  pubsub_server: Kudzu.PubSub

# MCP endpoint configuration (Tailscale-only)
# Override IP with KUDZU_MCP_IP env var
config :kudzu, KudzuWeb.MCP.Endpoint,
  http: [ip: {100, 70, 67, 110}, port: 4001],
  server: true,
  secret_key_base: "mcp-endpoint-does-not-use-sessions-but-phoenix-requires-this-key"

# API authentication (disabled by default for development)
# Enable and set API keys for production
config :kudzu, :api_auth,
  enabled: false,
  api_keys: []

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
  config :kudzu, KudzuWeb.Endpoint,
    http: [port: 4002],
    server: false  # Don't start server during tests
  config :kudzu, KudzuWeb.MCP.Endpoint,
    http: [port: 4003],
    server: false
end

if config_env() == :dev do
  config :kudzu, telemetry_console: true
  # Dev-friendly endpoint settings
  config :kudzu, KudzuWeb.Endpoint,
    debug_errors: true,
    code_reloader: false,
    check_origin: false
end

if config_env() == :prod do
  # Production requires these environment variables:
  # - SECRET_KEY_BASE: generate with `mix phx.gen.secret`
  # - KUDZU_API_KEYS: comma-separated API keys
  # - KUDZU_PORT: HTTP port (default 4000)
  config :kudzu, KudzuWeb.Endpoint,
    secret_key_base: System.get_env("SECRET_KEY_BASE"),
    http: [port: String.to_integer(System.get_env("KUDZU_PORT") || "4000")]

  config :kudzu, :api_auth,
    enabled: true,
    api_keys: String.split(System.get_env("KUDZU_API_KEYS") || "", ",", trim: true)

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
