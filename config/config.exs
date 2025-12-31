import Config

# Dynamic backend selection based on OS
# macOS (Darwin) -> Torchx with Metal Performance Shaders (MPS)
# Other -> EXLA (CPU fallback)

nx_backend =
  case :os.type() do
    {:unix, :darwin} ->
      # Apple Silicon with Metal GPU acceleration
      {Torchx.Backend, device: :mps}

    _ ->
      # CPU fallback via EXLA
      {EXLA.Backend, []}
  end

config :nx, default_backend: nx_backend

# Server configuration
config :pure_gopher_ai,
  # Clearnet listener - standard Gopher port 70
  # macOS: works without root
  # Linux: requires setcap or GOPHER_PORT=7070 override
  clearnet_port: 70,
  clearnet_host: "localhost",

  # Tor hidden service listener (binds to localhost only)
  tor_enabled: true,
  tor_port: 7071,
  tor_host: "127.0.0.1",
  # Set this after running: sudo cat /var/lib/tor/pure_gopher_ai/hostname
  onion_address: nil,

  # Static content directory for gophermap
  # Supports standard gophermap format
  content_dir: "~/.gopher",

  # Rate limiting (per IP)
  rate_limit_enabled: true,
  rate_limit_requests: 60,       # Max requests per window
  rate_limit_window_ms: 60_000,  # Window size (1 minute)

  # Conversation memory (for /chat)
  conversation_max_messages: 10,    # Max messages per session
  conversation_ttl_ms: 3_600_000,   # Session TTL (1 hour)

  # Streaming AI responses
  streaming_enabled: true           # Stream AI output as it generates

# Logging
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Import environment-specific config (if exists)
import_config "#{config_env()}.exs"
