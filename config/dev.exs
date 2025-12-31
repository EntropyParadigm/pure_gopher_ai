import Config

# Development overrides
# On Linux without setcap, use port 7070
config :pure_gopher_ai,
  clearnet_port: String.to_integer(System.get_env("GOPHER_PORT") || "7070")
