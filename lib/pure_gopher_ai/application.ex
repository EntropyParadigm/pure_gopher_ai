defmodule PureGopherAi.Application do
  @moduledoc """
  OTP Application for PureGopherAI.
  Supervises the AI Serving and Gopher TCP servers (clearnet + Tor).
  """

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    # Ensure data directories exist (critical for Nerves where /data is writable partition)
    ensure_data_directories()

    # Initialize persistent terms for fast config access
    PureGopherAi.Config.init()

    # Get config from persistent terms (faster than Application.get_env)
    clearnet_port = PureGopherAi.Config.clearnet_port()
    tor_enabled = PureGopherAi.Config.tor_enabled?()
    tor_port = PureGopherAi.Config.tor_port()
    gemini_enabled = PureGopherAi.Config.gemini_enabled?()
    gemini_port = PureGopherAi.Config.gemini_port()
    finger_enabled = PureGopherAi.Config.finger_enabled?()
    finger_port = PureGopherAi.Config.finger_port()
    ai_backend = Application.get_env(:pure_gopher_ai, :ai_backend, :ollama)

    Logger.info("Starting PureGopherAI server...")
    Logger.info("AI Backend: #{ai_backend}")

    if ai_backend == :ollama do
      Logger.info("Nx Backend: #{inspect(Application.get_env(:nx, :default_backend))}")
    end

    # Base children: HTTP client, rate limiter, conversation store, clearnet listener
    children = [
      # HTTP client (used by Gemini API, blocklist fetching, etc.)
      {Finch, name: PureGopherAi.Finch},

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

      # Session Token Management
      PureGopherAi.Session,

      # Audit Logging
      PureGopherAi.AuditLog,

      # CAPTCHA for Tor high-risk actions
      PureGopherAi.Captcha,

      # IP Reputation Scoring
      PureGopherAi.IpReputation,

      # User Notifications
      PureGopherAi.Notifications,

      # Content Reporting
      PureGopherAi.ContentReports,

      # User Blocking
      PureGopherAi.UserBlocks,

      # Scheduled Posts
      PureGopherAi.ScheduledPosts,

      # API Tokens
      PureGopherAi.ApiTokens,

      # Reactions/Voting
      PureGopherAi.Reactions,

      # Tags
      PureGopherAi.Tags,

      # Follows/Subscribe
      PureGopherAi.Follows,

      # Threaded Comments
      PureGopherAi.Comments,

      # Content Versioning
      PureGopherAi.Versioning,

      # Related Content/Recommendations
      PureGopherAi.RelatedContent,

      # Trending/Popular
      PureGopherAi.Trending,

      # User Analytics
      PureGopherAi.UserAnalytics,

      # Federation
      PureGopherAi.Federation,

      # Webhooks
      PureGopherAi.Webhooks,

      # Backup/Restore
      PureGopherAi.Backup,

      # Plugin System
      PureGopherAi.Plugins,

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

      # User Phlog (user-submitted blog posts)
      PureGopherAi.UserPhlog,

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

      # Simple Games (Hangman, Number Guess, Word Scramble)
      PureGopherAi.Games,

      # Terminal Slides (Presentation System)
      PureGopherAi.Slides
    ]

    # Only start ML infrastructure when using local backend (host/macOS)
    children =
      if ai_backend == :ollama do
        serving = PureGopherAi.AiEngine.setup_serving()

        children ++
          [
            # Dynamic supervisor for multiple model servings
            {DynamicSupervisor, strategy: :one_for_one, name: PureGopherAi.ModelSupervisor},

            # Model Registry (manages lazy loading of models)
            PureGopherAi.ModelRegistry,

            # Default AI Inference Engine - Nx.Serving with batching
            {Nx.Serving,
             serving: serving,
             name: PureGopherAi.Serving,
             batch_size: 1,
             batch_timeout: 100}
          ]
      else
        Logger.info("Skipping ML infrastructure (using #{ai_backend} backend)")
        children
      end

    children = children ++ [
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

        children = children ++ [tor_child]

        # On Nerves (non-host targets), start TorManager to manage the Tor process
        # On host/macOS, the system Tor daemon is managed externally
        if ai_backend != :ollama do
          children ++ [PureGopherAi.TorManager]
        else
          children
        end
      else
        children
      end

    # Optionally add Gemini listener (requires TLS certificates)
    children =
      if gemini_enabled do
        cert_file = Application.get_env(:pure_gopher_ai, :gemini_cert_file)
        key_file = Application.get_env(:pure_gopher_ai, :gemini_key_file)

        expanded_cert = expand_path(cert_file)
        expanded_key = expand_path(key_file)

        if cert_file && key_file && File.exists?(expanded_cert) && File.exists?(expanded_key) do
          gemini_child =
            Supervisor.child_spec(
              {ThousandIsland,
               port: gemini_port,
               transport_module: ThousandIsland.Transports.SSL,
               transport_options: [
                 certfile: expanded_cert,
                 keyfile: expanded_key
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

    # Optionally add Burrow tunnel client
    children =
      if PureGopherAi.Tunnel.enabled?() do
        children ++ [PureGopherAi.Tunnel]
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

          if cert_file && key_file && File.exists?(expand_path(cert_file)) do
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

  # Ensure data directories exist.
  # On Nerves, /data is the writable partition that persists across firmware updates.
  # On host/macOS, ~/.gopher directories are created as needed.
  defp ensure_data_directories do
    dirs =
      [
        Application.get_env(:pure_gopher_ai, :data_dir),
        Application.get_env(:pure_gopher_ai, :phlog_dir),
        Application.get_env(:pure_gopher_ai, :rag_docs_dir),
        Application.get_env(:pure_gopher_ai, :content_dir),
        Application.get_env(:pure_gopher_ai, :backup_dir, nil),
        Application.get_env(:pure_gopher_ai, :finger_plan_dir, nil),
        Application.get_env(:pure_gopher_ai, :plugins_dir, nil)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&expand_path/1)

    Enum.each(dirs, fn dir ->
      case File.mkdir_p(dir) do
        :ok -> :ok
        {:error, reason} -> Logger.warning("Failed to create directory #{dir}: #{reason}")
      end
    end)
  end

  # Expand ~ paths but leave absolute paths as-is (for Nerves /data/... paths)
  defp expand_path(path) when is_binary(path) do
    if String.starts_with?(path, "/"), do: path, else: Path.expand(path)
  end

  defp expand_path(nil), do: nil
end
