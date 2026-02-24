import Config

# API authentication - read KUDZU_API_KEY at runtime
# Supports comma-separated keys for key rotation
kudzu_api_key = System.get_env("KUDZU_API_KEY")

if kudzu_api_key && kudzu_api_key != "" do
  config :kudzu, :api_auth,
    enabled: true,
    api_keys: String.split(kudzu_api_key, ",", trim: true)
end
