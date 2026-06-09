import Config

# API authentication — KUDZU_API_KEY is mandatory.
# The app refuses to start without it. There is no fallback.
# Format: comma-separated list of allowed bearer tokens.
kudzu_api_key =
  System.get_env("KUDZU_API_KEY") ||
    raise """
    KUDZU_API_KEY environment variable is required.

    Set it to a comma-separated list of allowed bearer tokens before starting kudzu.
    Example:
        export KUDZU_API_KEY="prod-key-1,prod-key-2"
    """

if kudzu_api_key == "" do
  raise "KUDZU_API_KEY is set but empty. Provide at least one non-empty bearer token."
end

config :kudzu, :api_auth,
  enabled: true,
  api_keys: String.split(kudzu_api_key, ",", trim: true)

# Runtime data root for DETS warm files and Mnesia cold tier.
# Tests override this in config/test.exs to an isolated /tmp path so they
# never touch production DETS files / Mnesia node directories. For dev /
# prod / worker, default to /home/eel/kudzu_data unless KUDZU_DATA_ROOT
# is set in the environment.
if config_env() != :test do
  data_root = System.get_env("KUDZU_DATA_ROOT") || "/home/eel/kudzu_data"
  File.mkdir_p!(data_root)
  config :kudzu, :data_root, data_root
end

# Worker node configuration — point Ollama to titan, disable web endpoint
if System.get_env("KUDZU_ROLE") == "worker" do
  ollama_host = System.get_env("KUDZU_OLLAMA_HOST", "100.70.67.110")

  config :kudzu,
    ollama_url: "http://#{ollama_host}:11434"

  config :kudzu, KudzuWeb.MCP.Endpoint,
    server: false
end
