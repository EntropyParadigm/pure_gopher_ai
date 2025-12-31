import Config

# Production config
# Uses standard port 70 (works on macOS without root)
# Override with GOPHER_PORT env var if needed
config :pure_gopher_ai,
  clearnet_port: String.to_integer(System.get_env("GOPHER_PORT") || "70")
