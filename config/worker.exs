import Config

# Worker node configuration — used on radiator (no GPU, no Ollama local)
# Start with: KUDZU_ROLE=worker elixir --name kudzu@100.123.253.17 --cookie kudzu_mesh -S mix run --no-halt

# Point Ollama to titan (radiator has no GPU)
config :kudzu,
  ollama_url: "http://100.70.67.110:11434",
  default_model: "mistral:latest"

# Worker doesn't serve web — but still configure endpoint in case needed
config :kudzu, KudzuWeb.MCP.Endpoint,
  server: false
