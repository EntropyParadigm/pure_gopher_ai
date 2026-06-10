defmodule PureGopherAi.MixProject do
  use Mix.Project

  @app :pure_gopher_ai
  @version "0.2.0"
  @all_targets [:rpi3]

  def project do
    [
      app: @app,
      version: @version,
      elixir: "~> 1.17",
      archives: [nerves_bootstrap: "~> 1.13"],
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: [{@app, release()}],

      # Performance optimizations
      consolidate_protocols: Mix.env() != :dev,

      # Compiler options
      elixirc_options: [
        warnings_as_errors: Mix.env() == :prod
      ]
    ]
  end

  def cli do
    [
      preferred_targets: [run: :host, test: :host]
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

      # HTTP client (for Gemini API on Pi, general HTTP needs)
      {:finch, "~> 0.18"},

      # Utilities
      {:jason, "~> 1.4"},

      # Performance & Monitoring
      {:telemetry, "~> 1.2"},
      {:telemetry_metrics, "~> 0.6"},
      {:telemetry_poller, "~> 1.0"},

      # Tunneling (expose services without opening ports)
      {:burrow, github: "EntropyParadigm/burrow"},

      # Nerves core (all targets including host for compilation)
      {:nerves, "~> 1.10", runtime: false},
      {:shoehorn, "~> 0.9.1"},
      {:ring_logger, "~> 0.11"},
      {:toolshed, "~> 0.4"},

      # AI/ML Stack (host/macOS only - too heavy for Pi)
      {:bumblebee, "~> 0.6", targets: [:host]},
      {:nx, "~> 0.9", targets: [:host]},
      {:exla, "~> 0.9", targets: [:host]},
      {:torchx, "~> 0.9", targets: [:host]}
    ] ++ target_deps()
  end

  defp target_deps do
    [
      # Nerves runtime (device targets only)
      {:nerves_runtime, "~> 0.13", targets: @all_targets},
      {:nerves_pack, "~> 0.7", targets: @all_targets},
      {:nerves_time, "~> 0.4", targets: @all_targets},
      {:nerves_ssh, "~> 1.0", targets: @all_targets},
      {:vintage_net_ethernet, "~> 0.11", targets: @all_targets},
      {:vintage_net_wifi, "~> 0.12", targets: @all_targets},

      # System image for Raspberry Pi 3B/3B+
      {:nerves_system_rpi3, "~> 1.27", runtime: false, targets: :rpi3}
    ]
  end

  def release do
    [
      overwrite: true,
      include_erts: &Nerves.Release.erts/0,
      steps: [&Nerves.Release.init/1, :assemble],
      strip_beams: Mix.env() == :prod
    ]
  end
end
