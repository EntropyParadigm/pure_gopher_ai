import Config

# Test configuration
# High ports to avoid conflicts, Tor disabled

config :pure_gopher_ai,
  clearnet_port: 17070,
  tor_enabled: false,
  tor_port: 17071,
  onion_address: nil,
  gemini_enabled: false,
  gemini_port: 11965,
  finger_enabled: false,
  finger_port: 10079
