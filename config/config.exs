import Config

# Dynamic backend selection based on OS
# macOS (Darwin) -> Torchx with Metal Performance Shaders (MPS)
# Other -> EXLA (CPU fallback)

nx_backend =
  case :os.type() do
    {:unix, :darwin} ->
      # Apple Silicon - Torchx with Metal MPS GPU acceleration
      # Requires: export LIBTORCH_DIR=~/libtorch/libtorch
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
  clearnet_host: System.get_env("GOPHER_HOST", "gopherlab.org"),

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

  # Bumblebee model selection (loaded via HuggingFace)
  # DeepSeek R1 Distilled models with Chain-of-Thought reasoning
  #
  # Default: DeepSeek-R1-Distill-Qwen-1.5B
  #   - Fast, efficient (1.5B params, ~3GB RAM)
  #   - Great for coding, general questions, reasoning
  #   - Outputs <think>...</think> tags showing reasoning process
  #
  # Alternative: DeepSeek-R1-Distill-Llama-8B (needs 16GB+ RAM)
  #   - Set AI_MODEL=deepseek-ai/DeepSeek-R1-Distill-Llama-8B
  #
  # Environment override: AI_MODEL
  bumblebee_model: System.get_env("AI_MODEL", "deepseek-ai/DeepSeek-R1-Distill-Qwen-1.5B"),

  # DeepSeek R1 generation settings (higher limits for reasoning)
  deepseek_max_new_tokens: 1024,      # Allow space for <think> reasoning
  deepseek_sequence_length: 2048,     # Context window
  deepseek_show_thinking: true,       # Show <think> tags in output (set false to hide)

  # Ollama backend (optional, for even larger models)
  # Set OLLAMA_ENABLED=true if you have Ollama running
  ollama_enabled: System.get_env("OLLAMA_ENABLED", "false") == "true",
  ollama_url: System.get_env("OLLAMA_URL", "http://localhost:11434"),
  ollama_model: System.get_env("OLLAMA_MODEL", "llama3.2"),
  ollama_timeout: 120_000,

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
  phlog_entries_per_page: 10,   # Entries per page

  # Admin interface (set ADMIN_TOKEN env var to enable)
  # Access via /admin/<token>/
  admin_token: nil,             # Set to a secure token to enable admin

  # External blocklist integration
  # Blocks known bad actors from accessing the server
  blocklist_enabled: true,      # Enable external blocklist fetching
  blocklist_refresh_ms: 3_600_000,  # Refresh interval (1 hour)
  blocklist_file: "~/.gopher/blocklist.txt",  # Local blocklist file (custom entries)
  blocklist_sources: [
    # Floodgap's official Gopher bot blocklist (fetched via Gopher protocol)
    {"floodgap", "gopher://gopher.floodgap.com/0/responsible-bot"},
    # FireHOL curated blocklists (fetched via HTTPS)
    {"firehol_level1", "https://raw.githubusercontent.com/firehol/blocklist-ipsets/master/firehol_level1.netset"},
    {"firehol_abusers_1d", "https://raw.githubusercontent.com/firehol/blocklist-ipsets/master/firehol_abusers_1d.netset"},
    {"stopforumspam_7d", "https://raw.githubusercontent.com/firehol/blocklist-ipsets/master/stopforumspam_7d.netset"}
  ],

  # RAG (Retrieval Augmented Generation)
  # Query your own documents with AI-enhanced answers
  rag_enabled: true,                    # Enable RAG system
  rag_docs_dir: "~/.gopher/docs",       # Document directory (auto-ingested)
  rag_chunk_size: 512,                  # Words per chunk
  rag_chunk_overlap: 50,                # Overlap between chunks
  rag_poll_interval: 30_000,            # File watcher poll interval (30s)
  rag_embeddings_enabled: true,         # Enable vector embeddings
  rag_embedding_model: "sentence-transformers/all-MiniLM-L6-v2",  # Embedding model

  # Gemini protocol support (gemini://)
  # Requires TLS certificates - generate with:
  # openssl req -x509 -newkey rsa:4096 -keyout key.pem -out cert.pem -days 365 -nodes
  gemini_enabled: true,                 # Enable Gemini server
  gemini_port: 1965,                    # Standard Gemini port
  gemini_cert_file: "~/.gopher/gemini/cert.pem",  # TLS certificate
  gemini_key_file: "~/.gopher/gemini/key.pem",    # TLS private key

  # Finger protocol support (RFC 1288)
  finger_enabled: false,                # Enable Finger server
  finger_port: 79,                      # Standard Finger port
  finger_plan_dir: "~/.gopher/finger",  # Directory for user .plan files

  # Guestbook
  guestbook_max_entries: 1000,          # Maximum guestbook entries (oldest pruned)
  data_dir: "~/.gopher/data",           # Persistent data directory

  # RSS/Atom Feed Aggregator
  # List of {name, url} tuples for subscribed feeds
  rss_feeds: [
    # Example feeds (uncomment to enable):
    # {"Hacker News", "https://hnrss.org/frontpage"},
    # {"Lobsters", "https://lobste.rs/rss"},
    # {"Elixir Blog", "https://elixir-lang.org/blog.atom"}
  ]

# Burrow Tunnel Configuration
# Expose local services via relay server without opening ports
config :pure_gopher_ai, :tunnel,
  enabled: true,                            # Enable tunneling
  server: System.get_env("BURROW_SERVER", "gopherlab.org:4000"),  # Relay server (host:port)
  token: {:system, "BURROW_TOKEN"},         # Auth token from env var
  reconnect: true,                          # Auto-reconnect on disconnect
  # Tunnels are auto-configured based on enabled services
  # Or specify explicitly:
  # tunnels: [
  #   [name: "gopher", local: 70, remote: 70],
  #   [name: "gemini", local: 1965, remote: 1965],
  #   [name: "finger", local: 79, remote: 79]
  # ]
  tunnels: nil  # nil = auto-detect from enabled services

# Logging
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Import environment-specific config (if exists)
import_config "#{config_env()}.exs"
