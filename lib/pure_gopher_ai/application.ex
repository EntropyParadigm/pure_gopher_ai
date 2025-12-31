defmodule PureGopherAi.Application do
  @moduledoc """
  OTP Application for PureGopherAI.
  Supervises the AI Serving and Gopher TCP servers (clearnet + Tor).
  """

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    clearnet_port = Application.get_env(:pure_gopher_ai, :clearnet_port, 7070)
    tor_enabled = Application.get_env(:pure_gopher_ai, :tor_enabled, false)
    tor_port = Application.get_env(:pure_gopher_ai, :tor_port, 7071)

    Logger.info("Starting PureGopherAI server...")
    Logger.info("Backend: #{inspect(Application.get_env(:nx, :default_backend))}")

    # Setup the AI serving
    serving = PureGopherAi.AiEngine.setup_serving()

    # Base children: rate limiter, conversation store, AI engine, clearnet listener
    children = [
      # External Blocklist (optional, for Tor abuse prevention)
      PureGopherAi.Blocklist,

      # Rate Limiter
      PureGopherAi.RateLimiter,

      # Conversation Store
      PureGopherAi.ConversationStore,

      # Response Cache
      PureGopherAi.ResponseCache,

      # Telemetry / Metrics
      PureGopherAi.Telemetry,

      # Dynamic supervisor for multiple model servings
      {DynamicSupervisor, strategy: :one_for_one, name: PureGopherAi.ModelSupervisor},

      # Model Registry (manages lazy loading of models)
      PureGopherAi.ModelRegistry,

      # Default AI Inference Engine - Nx.Serving with batching
      {Nx.Serving,
       serving: serving,
       name: PureGopherAi.Serving,
       batch_size: 1,
       batch_timeout: 100},

      # Clearnet Gopher TCP Server
      Supervisor.child_spec(
        {ThousandIsland,
         port: clearnet_port,
         handler_module: PureGopherAi.GopherHandler,
         handler_options: [network: :clearnet]},
        id: :clearnet_listener
      )
    ]

    # Optionally add Tor listener
    children =
      if tor_enabled do
        tor_child =
          Supervisor.child_spec(
            {ThousandIsland,
             port: tor_port,
             transport_options: [ip: {127, 0, 0, 1}],
             handler_module: PureGopherAi.GopherHandler,
             handler_options: [network: :tor]},
            id: :tor_listener
          )

        children ++ [tor_child]
      else
        children
      end

    opts = [strategy: :one_for_one, name: PureGopherAi.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        Logger.info("Clearnet: Gopher server listening on port #{clearnet_port}")

        if tor_enabled do
          Logger.info("Tor: Hidden service listener on 127.0.0.1:#{tor_port}")
          Logger.info("Tor: Configure torrc with: HiddenServicePort 70 127.0.0.1:#{tor_port}")
        end

        {:ok, pid}

      error ->
        error
    end
  end
end
