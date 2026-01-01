import Config

# Production configuration
# macOS (Apple Silicon): port 70 works without root
# Tor enabled for anonymous access

config :pure_gopher_ai,
  # Clearnet: standard port 70, override with GOPHER_PORT
  clearnet_port: String.to_integer(System.get_env("GOPHER_PORT") || "70"),

  # Tor: enabled by default
  tor_enabled: System.get_env("TOR_ENABLED") != "false",
  tor_port: String.to_integer(System.get_env("TOR_PORT") || "7071"),
  onion_address: System.get_env("ONION_ADDRESS"),

  # Performance settings
  response_cache_max_size: 10_000,
  response_cache_ttl_seconds: 300,
  conversation_store_max_messages: 20,
  rate_limiter_cleanup_interval: 60_000

# Logger: reduce verbosity in production
config :logger,
  level: :info,
  compile_time_purge_matching: [
    [level_lower_than: :info]
  ]

# Compile-time optimizations: remove debug statements
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]
