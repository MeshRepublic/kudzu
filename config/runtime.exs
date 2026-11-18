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

# Endpoint secret. Read from SECRET_KEY_BASE; never a fixed string. :prod
# refuses to boot without it. Elsewhere (dev/test, including the `mix run`
# node on titan, which runs in :dev) a missing value is replaced by a random
# one generated at boot, so anything signed with it is invalidated by a
# restart: set SECRET_KEY_BASE wherever that matters.
secret_key_base =
  case System.get_env("SECRET_KEY_BASE") do
    blank when blank in [nil, ""] ->
      if config_env() == :prod do
        raise """
        SECRET_KEY_BASE environment variable is required in production.

        Generate one with `mix phx.gen.secret` and export it before starting kudzu.
        """
      end

      Base.encode64(:crypto.strong_rand_bytes(48))

    secret when byte_size(secret) < 64 ->
      raise "SECRET_KEY_BASE is set but shorter than 64 bytes. Generate one with `mix phx.gen.secret`."

    secret ->
      secret
  end

config :kudzu, KudzuWeb.MCP.Endpoint, secret_key_base: secret_key_base

# Endpoint bind address / port. Applies to dev and prod alike (the production
# node runs `mix run --no-halt` in :dev); tests keep the compile-time
# defaults (port 4003, server: false).
#
# The default is titan's Tailscale address, kept so the existing deployment
# starts unchanged with no extra environment. It is a private tailnet
# address, not a secret. Any other host must set KUDZU_MCP_IP.
if config_env() != :test do
  mcp_ip =
    case System.get_env("KUDZU_MCP_IP", "100.70.67.110")
         |> String.to_charlist()
         |> :inet.parse_address() do
      {:ok, ip} -> ip
      {:error, _} -> raise "KUDZU_MCP_IP is not a valid IP address."
    end

  mcp_port = String.to_integer(System.get_env("KUDZU_MCP_PORT") || "4001")
  config :kudzu, KudzuWeb.MCP.Endpoint, http: [ip: mcp_ip, port: mcp_port]

  if cors = System.get_env("KUDZU_CORS_ORIGINS") do
    config :kudzu, :cors_origins, String.split(cors, ",", trim: true)
  end
end

# Ollama endpoint. OLLAMA_URL (a full base URL) overrides everything. Without
# it, a worker node uses KUDZU_OLLAMA_HOST on port 11434 (default: titan, as
# before) and every other node keeps the compile-time default (local Ollama).
worker? = System.get_env("KUDZU_ROLE") == "worker"

ollama_url =
  case System.get_env("OLLAMA_URL") do
    blank when blank in [nil, ""] ->
      if worker?, do: "http://#{System.get_env("KUDZU_OLLAMA_HOST", "100.70.67.110")}:11434"

    url ->
      url
  end

if ollama_url do
  config :kudzu, ollama_url: ollama_url
end

# Worker node configuration — disable the web endpoint
if worker? do
  config :kudzu, KudzuWeb.MCP.Endpoint, server: false
end

# Distiller extractor selection — when true, Distiller.extract_chains/1 calls
# Kudzu.Silo.Extractor.extract_claude/3 (Claude API, costs tokens, higher quality)
# instead of the local Ollama llama4:scout path. Defaults to false; enable per-run
# via KUDZU_DISTILLER_CLAUDE=true. Requires ANTHROPIC_API_KEY to be set.
config :kudzu, :distiller_use_claude, System.get_env("KUDZU_DISTILLER_CLAUDE") == "true"
