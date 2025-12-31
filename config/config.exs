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
  streaming_enabled: true,          # Stream AI output as it generates

  # System prompts (AI personality/behavior)
  # Default system prompt applied to all queries
  system_prompt: nil,

  # Named personas with custom system prompts
  personas: %{
    "helpful" => %{
      name: "Helpful Assistant",
      prompt: "You are a helpful, accurate, and concise assistant. Answer questions directly and clearly."
    },
    "pirate" => %{
      name: "Pirate",
      prompt: "You are a friendly pirate. Respond in pirate speak with 'Arrr!' and nautical terms. Be helpful but stay in character."
    },
    "haiku" => %{
      name: "Haiku Poet",
      prompt: "You respond only in haiku format (5-7-5 syllables). Every response must be exactly three lines."
    },
    "coder" => %{
      name: "Code Assistant",
      prompt: "You are a programming expert. Focus on code examples, best practices, and technical accuracy. Be concise."
    }
  },

  # Response caching
  cache_enabled: true,
  cache_ttl_ms: 3_600_000,       # Cache TTL (1 hour)
  cache_max_entries: 1000,       # Max cached responses

  # Phlog (Gopher blog)
  phlog_dir: "~/.gopher/phlog",  # Phlog content directory
  phlog_entries_per_page: 10    # Entries per page

# Logging
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Import environment-specific config (if exists)
import_config "#{config_env()}.exs"
