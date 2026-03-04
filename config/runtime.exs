import Config

# API authentication - read KUDZU_API_KEY at runtime
kudzu_api_key = System.get_env("KUDZU_API_KEY")

if kudzu_api_key && kudzu_api_key != "" do
  config :kudzu, :api_auth,
    enabled: true,
    api_keys: String.split(kudzu_api_key, ",", trim: true)
end

# Worker node configuration — point Ollama to titan, disable web endpoint
if System.get_env("KUDZU_ROLE") == "worker" do
  ollama_host = System.get_env("KUDZU_OLLAMA_HOST", "100.70.67.110")

  config :kudzu,
    ollama_url: "http://#{ollama_host}:11434"

  config :kudzu, KudzuWeb.MCP.Endpoint,
    server: false
end
