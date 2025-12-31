import Config

# Development configuration
# Linux uses port 7070 by default (no root needed)
# Tor enabled for testing hidden service locally

config :pure_gopher_ai,
  # Clearnet: 7070 default, override with GOPHER_PORT
  clearnet_port: String.to_integer(System.get_env("GOPHER_PORT") || "7070"),

  # Tor: enabled by default for dev testing
  tor_enabled: System.get_env("TOR_ENABLED") != "false",
  tor_port: String.to_integer(System.get_env("TOR_PORT") || "7071"),
  onion_address: System.get_env("ONION_ADDRESS")
