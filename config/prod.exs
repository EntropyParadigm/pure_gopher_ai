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
  onion_address: System.get_env("ONION_ADDRESS")
