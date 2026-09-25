import Config

# API authentication — KUDZU_API_KEY is mandatory.
# The app refuses to start without it. There is no fallback.
# Format: comma-separated list of allowed bearer tokens.
#
# Keys are scoped (see KudzuWeb.Plugs.APIAuth):
#   KUDZU_API_KEY      — mutate keys: full access (read + state changes)
#   KUDZU_API_READ_KEY — optional read-only keys: list/get/check operations
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

split_keys = fn csv ->
  (csv || "")
  |> String.split(",", trim: true)
  |> Enum.map(&String.trim/1)
  |> Enum.reject(&(&1 == ""))
end

mutate_keys = split_keys.(kudzu_api_key)
read_keys = split_keys.(System.get_env("KUDZU_API_READ_KEY"))

if mutate_keys == [] do
  raise "KUDZU_API_KEY is set but contains no usable keys."
end

if Enum.any?(read_keys, &(&1 in mutate_keys)) do
  raise "A key appears in both KUDZU_API_KEY and KUDZU_API_READ_KEY; each key must have exactly one scope."
end

config :kudzu, :api_auth,
  keys: Map.merge(Map.new(read_keys, &{&1, :read}), Map.new(mutate_keys, &{&1, :mutate}))

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

  config :kudzu, KudzuWeb.MCP.Endpoint, server: false
end

# Distiller extractor selection — when true, Distiller.extract_chains/1 calls
# Kudzu.Silo.Extractor.extract_claude/3 (Claude API, costs tokens, higher quality)
# instead of the local Ollama llama4:scout path. Defaults to false; enable per-run
# via KUDZU_DISTILLER_CLAUDE=true. Requires ANTHROPIC_API_KEY to be set.
config :kudzu, :distiller_use_claude, System.get_env("KUDZU_DISTILLER_CLAUDE") == "true"
