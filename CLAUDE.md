# PureGopherAI - Project Context

## Overview
A pure Elixir Gopher server (RFC 1436) with native AI inference via Bumblebee. Optimized for Apple Silicon with Metal GPU acceleration.

## Architecture

### Core Components
- **TCP Server**: `ThousandIsland` on port 7070 (clearnet) and 7071 (Tor)
- **AI Engine**: `Bumblebee` + `Nx.Serving` for batched text generation
- **Supervision**: OTP `one_for_one` strategy

### Key Files
| File | Purpose |
|------|---------|
| `lib/pure_gopher_ai/application.ex` | Supervisor - starts AI serving + TCP listeners |
| `lib/pure_gopher_ai/ai_engine.ex` | Loads model, exposes `generate/1` |
| `lib/pure_gopher_ai/gopher_handler.ex` | RFC 1436 protocol handler |
| `config/config.exs` | Backend detection (Torchx/MPS vs EXLA) |

### Hardware Detection
```elixir
# macOS (Apple Silicon) -> Torchx with Metal MPS
# Linux/Other -> EXLA CPU fallback
case :os.type() do
  {:unix, :darwin} -> {Torchx.Backend, device: :mps}
  _ -> {EXLA.Backend, []}
end
```

## Gopher Protocol

### Selectors
| Selector | Action |
|----------|--------|
| `/` or empty | Root menu |
| `/ask <query>` | AI text generation |
| `/about` | Server stats |

### Response Format
- Info lines: `i<text>\t\t<host>\t<port>`
- Links: `1<text>\t<selector>\t<host>\t<port>`
- Terminator: `.` on its own line

## Tor Integration
The server supports Tor hidden services. Tor must be installed and configured externally. The Elixir app binds to `127.0.0.1:7071` for Tor traffic.

### Tor Config (`/etc/tor/torrc`)
```
HiddenServiceDir /var/lib/tor/pure_gopher_ai/
HiddenServicePort 70 127.0.0.1:7071
```

## Commands

```bash
# Development
iex -S mix

# Production
MIX_ENV=prod mix run --no-halt

# Test connection
echo "" | nc localhost 7070
echo "/ask Hello" | nc localhost 7070

# Get Tor .onion address
sudo cat /var/lib/tor/pure_gopher_ai/hostname
```

## Dependencies
- `thousand_island` - TCP server
- `bumblebee` - Hugging Face model loading
- `nx` - Numerical computing
- `exla` - XLA backend (CPU/GPU)
- `torchx` - PyTorch backend (Metal MPS)
- `jason` - JSON handling

## Model
Default: `openai-community/gpt2` (lightweight)
Production recommendation: Llama 2 or similar for better quality

## Notes
- First model load downloads from Hugging Face (~500MB for GPT-2)
- Nx.Serving provides automatic request batching
- No external API calls - all inference runs locally
