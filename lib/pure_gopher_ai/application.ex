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
    gemini_enabled = Application.get_env(:pure_gopher_ai, :gemini_enabled, false)
    gemini_port = Application.get_env(:pure_gopher_ai, :gemini_port, 1965)
    finger_enabled = Application.get_env(:pure_gopher_ai, :finger_enabled, false)
    finger_port = Application.get_env(:pure_gopher_ai, :finger_port, 79)

    # Record start time for uptime tracking
    Application.put_env(:pure_gopher_ai, :start_time, System.system_time(:second))

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

      # RAG (Retrieval Augmented Generation)
      PureGopherAi.Rag.DocumentStore,
      PureGopherAi.Rag.Embeddings,
      PureGopherAi.Rag.FileWatcher,

      # Guestbook
      PureGopherAi.Guestbook,

      # Text Adventure
      PureGopherAi.Adventure,

      # Feed Aggregator
      PureGopherAi.FeedAggregator,

      # Fortune/Quote Service
      PureGopherAi.Fortune,

      # Link Directory
      PureGopherAi.LinkDirectory,

      # Bulletin Board
      PureGopherAi.BulletinBoard,

      # Pastebin
      PureGopherAi.Pastebin,

      # Polls / Voting
      PureGopherAi.Polls,

      # Phlog Comments
      PureGopherAi.PhlogComments,

      # User Profiles
      PureGopherAi.UserProfiles,

      # Calendar / Events
      PureGopherAi.Calendar,

      # URL Shortener
      PureGopherAi.UrlShortener,

      # Mailbox / Messaging
      PureGopherAi.Mailbox,

      # Trivia / Quiz Game
      PureGopherAi.Trivia,

      # Bookmarks / Favorites
      PureGopherAi.Bookmarks,

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

    # Optionally add Gemini listener (requires TLS certificates)
    children =
      if gemini_enabled do
        cert_file = Application.get_env(:pure_gopher_ai, :gemini_cert_file)
        key_file = Application.get_env(:pure_gopher_ai, :gemini_key_file)

        if cert_file && key_file && File.exists?(Path.expand(cert_file)) && File.exists?(Path.expand(key_file)) do
          gemini_child =
            Supervisor.child_spec(
              {ThousandIsland,
               port: gemini_port,
               transport_module: ThousandIsland.Transports.SSL,
               transport_options: [
                 certfile: Path.expand(cert_file),
                 keyfile: Path.expand(key_file)
               ],
               handler_module: PureGopherAi.GeminiHandler},
              id: :gemini_listener
            )

          children ++ [gemini_child]
        else
          Logger.warning("Gemini: Disabled - certificate files not found")
          Logger.warning("Gemini: Set gemini_cert_file and gemini_key_file in config")
          children
        end
      else
        children
      end

    # Optionally add Finger listener (RFC 1288)
    children =
      if finger_enabled do
        finger_child =
          Supervisor.child_spec(
            {ThousandIsland,
             port: finger_port,
             handler_module: PureGopherAi.FingerHandler},
            id: :finger_listener
          )

        children ++ [finger_child]
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

        if gemini_enabled do
          cert_file = Application.get_env(:pure_gopher_ai, :gemini_cert_file)
          key_file = Application.get_env(:pure_gopher_ai, :gemini_key_file)

          if cert_file && key_file && File.exists?(Path.expand(cert_file)) do
            Logger.info("Gemini: Server listening on port #{gemini_port} (TLS)")
          end
        end

        if finger_enabled do
          Logger.info("Finger: Server listening on port #{finger_port} (RFC 1288)")
        end

        {:ok, pid}

      error ->
        error
    end
  end
end
