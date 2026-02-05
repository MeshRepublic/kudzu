import Config

# Telemetry console logging (set to true for debug output)
config :kudzu, telemetry_console: false

# Ollama LLM configuration
# Can be overridden per-hologram with :ollama_url option
config :kudzu,
  ollama_url: "http://localhost:11434",
  default_model: "mistral:latest",
  cognition_timeout: 120_000

# Logger configuration
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

if config_env() == :test do
  config :logger, level: :warning
end

if config_env() == :dev do
  config :kudzu, telemetry_console: true
end

# Example distributed configuration (uncomment and modify for your setup)
# config :kudzu,
#   ollama_url: "http://100.64.0.1:11434"  # Tailscale IP of Ollama server
