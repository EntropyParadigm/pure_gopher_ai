defmodule PureGopherAi.MixProject do
  use Mix.Project

  def project do
    [
      app: :pure_gopher_ai,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),

      # Performance optimizations
      consolidate_protocols: Mix.env() != :dev,

      # Compiler options
      elixirc_options: [
        warnings_as_errors: Mix.env() == :prod
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto, :inets, :ssl, :runtime_tools],
      mod: {PureGopherAi.Application, []}
    ]
  end

  defp deps do
    [
      # TCP Server
      {:thousand_island, "~> 1.0"},

      # AI/ML Stack
      {:bumblebee, "~> 0.6"},
      {:nx, "~> 0.9"},
      {:exla, "~> 0.9"},
      {:torchx, "~> 0.9"},  # Re-enabled with manual libtorch download

      # Utilities
      {:jason, "~> 1.4"},

      # Performance & Monitoring
      {:telemetry, "~> 1.2"},
      {:telemetry_metrics, "~> 0.6"},
      {:telemetry_poller, "~> 1.0"},

      # Tunneling (expose services without opening ports)
      {:burrow, github: "EntropyParadigm/burrow"}
    ]
  end
end
