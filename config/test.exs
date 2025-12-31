import Config

# Test configuration
# High ports to avoid conflicts, Tor disabled

config :pure_gopher_ai,
  clearnet_port: 17070,
  tor_enabled: false,
  tor_port: 17071,
  onion_address: nil
