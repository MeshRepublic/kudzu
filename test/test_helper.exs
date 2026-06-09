# Exclude tags by default:
#   :large    — long-running benchmark / load tests
#   :external — tests that require Ollama, Brain GenServer init, or other
#               external services. Run with `mix test --include external`
#               on a machine where the dependencies are available.
ExUnit.start(exclude: [:large, :external], timeout: 60_000)
