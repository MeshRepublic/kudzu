import Config

# Telemetry console logging (set to true for debug output)
config :kudzu, telemetry_console: false

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
