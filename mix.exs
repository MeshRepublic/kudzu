defmodule Kudzu.MixProject do
  use Mix.Project

  def project do
    [
      app: :kudzu,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      # Enable all schedulers for 128 core usage
      elixirc_options: [warnings_as_errors: false]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto, :inets, :ssl],
      mod: {Kudzu.Application, []}
    ]
  end

  defp deps do
    [
      {:telemetry, "~> 1.0"},
      {:jason, "~> 1.4"}
    ]
  end
end
