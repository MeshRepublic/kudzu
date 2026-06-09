defmodule Kudzu.MixProject do
  use Mix.Project

  def project do
    [
      app: :kudzu,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      # Enable all schedulers for 128 core usage
      elixirc_options: [warnings_as_errors: true],
      dialyzer: [
        plt_file: {:no_warn, "_build/#{Mix.env()}/dialyxir.plt"},
        plt_add_apps: [:mnesia, :ssl, :inets, :crypto, :ex_unit],
        # NOTE: :unmatched_returns intentionally NOT enabled. It surfaces 115
        # warnings on legitimate fire-and-forget calls (Task.start, Logger.X,
        # GenServer.cast, telemetry.execute, supervisor.start_link result in
        # Application start). Each would need a leading _ = which adds noise
        # without catching bugs. Re-enable per-module when a module has a
        # documented "every return must be checked" contract.
        # :underspecs intentionally NOT enabled. Many functions have
        # @spec [module()] or similar broader-than-success-typing specs that
        # are correct contract-wise but trigger contract_supertype warnings.
        # Re-enable when stricter specs are valuable per-module.
        flags: [
          :error_handling
        ],
        ignore_warnings: ".dialyzer_ignore.exs"
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto, :inets, :ssl, :mnesia],
      mod: {Kudzu.Application, []}
    ]
  end

  defp aliases do
    [
      #  runs the full static-analysis gate (format, credo,
      # dialyzer). Wire into CI; in dev run individually for faster feedback.
      quality: [
        "format --check-formatted",
        "credo --strict",
        "dialyzer --halt-exit-status"
      ]
    ]
  end

  defp deps do
    [
      {:telemetry, "~> 1.0"},
      {:jason, "~> 1.4"},
      # Phoenix for API layer
      {:phoenix, "~> 1.7"},
      {:phoenix_pubsub, "~> 2.1"},
      {:plug_cowboy, "~> 2.6"},
      {:cors_plug, "~> 3.0"},
      {:nx, "~> 0.9"},
      {:exla, "~> 0.9", runtime: false},
      # Type discipline / static analysis (dev/test only)
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end
end
