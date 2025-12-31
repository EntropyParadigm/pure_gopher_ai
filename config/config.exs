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
  port: 7070,
  host: "localhost"

# Logging
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]
