defmodule PureGopherAi.MixProject do
  use Mix.Project

  def project do
    [
      app: :pure_gopher_ai,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
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
      {:torchx, "~> 0.9"},

      # Utilities
      {:jason, "~> 1.4"}
    ]
  end
end
