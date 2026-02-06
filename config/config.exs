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

# Logger configuration
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

if config_env() == :test do
  config :logger, level: :warning
  # Allow /tmp for test file operations
  config :kudzu, allowed_io_paths: ["/tmp"]
end

if config_env() == :dev do
  config :kudzu, telemetry_console: true
end

# Example distributed configuration (uncomment and modify for your setup)
# config :kudzu,
#   ollama_url: "http://100.64.0.1:11434"  # Tailscale IP of Ollama server
