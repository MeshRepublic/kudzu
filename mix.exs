defmodule Kudzu.MixProject do
  use Mix.Project

  def project do
    [
      app: :kudzu,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      # Enable all schedulers for 128 core usage
      elixirc_options: [warnings_as_errors: true],
      dialyzer: [
        plt_file: {:no_warn, "_build/#{Mix.env()}/dialyxir.plt"},
        plt_add_apps: [:mnesia, :ssl, :inets, :crypto, :ex_unit],
        flags: [
          :unmatched_returns,
          :error_handling,
          :underspecs
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
