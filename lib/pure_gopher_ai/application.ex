defmodule PureGopherAi.Application do
  @moduledoc """
  OTP Application for PureGopherAI.
  Supervises the AI Serving and Gopher TCP server.
  """

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    port = Application.get_env(:pure_gopher_ai, :port, 7070)

    Logger.info("Starting PureGopherAI server...")
    Logger.info("Backend: #{inspect(Application.get_env(:nx, :default_backend))}")

    # Setup the AI serving
    serving = PureGopherAi.AiEngine.setup_serving()

    children = [
      # AI Inference Engine - Nx.Serving with batching
      {Nx.Serving,
       serving: serving,
       name: PureGopherAi.Serving,
       batch_size: 4,
       batch_timeout: 100},

      # Gopher TCP Server
      {ThousandIsland,
       port: port,
       handler_module: PureGopherAi.GopherHandler,
       handler_options: []}
    ]

    opts = [strategy: :one_for_one, name: PureGopherAi.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        Logger.info("Gopher server listening on port #{port}")
        Logger.info("Connect with: gopher localhost #{port}")
        {:ok, pid}

      error ->
        error
    end
  end
end
