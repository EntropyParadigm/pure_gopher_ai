# PureGopherAI - Project Context

## Overview
A pure Elixir Gopher server (RFC 1436) with native AI inference via Bumblebee. Optimized for Apple Silicon with Metal GPU acceleration. Dual-stack: clearnet + Tor hidden service.

## Architecture

```
                    ┌─────────────────────────────────────────────┐
                    │           OTP Supervisor                    │
                    │         (one_for_one strategy)              │
                    └─────────────────┬───────────────────────────┘
                                      │
            ┌─────────────────────────┼─────────────────────────┐
            │                         │                         │
            ▼                         ▼                         ▼
┌───────────────────┐   ┌───────────────────┐   ┌───────────────────┐
│   Nx.Serving      │   │  ThousandIsland   │   │  ThousandIsland   │
│   (AI Engine)     │   │  :clearnet        │   │  :tor             │
│                   │   │  0.0.0.0:70       │   │  127.0.0.1:7071   │
│  ┌─────────────┐  │   └─────────┬─────────┘   └─────────┬─────────┘
│  │ Bumblebee   │  │             │                       │
│  │ GPT-2/Llama │  │             │                       │
│  └─────────────┘  │             │    Tor daemon maps    │
└─────────┬─────────┘             │    external :70 ──────┘
          │                       ▼
          │             ┌───────────────────────────────────────┐
          │             │         GopherHandler                 │
          │             │    (network-aware routing)            │
          │             │                                       │
          │             │  Selectors:                           │
          └────────────►│    /        → Root Menu               │
           generate()   │    /ask     → AI Query                │
                        │    /about   → Server Stats            │
                        └───────────────────────────────────────┘
```

### Handler Flow

```
TCP Connection (clearnet :70 or tor :7071)
      │
      ▼
┌─────────────────────────────────────────────────────┐
│ handle_connection/2                                 │
│   - Extract network type from handler_options      │
│   - Store in state: %{network: :clearnet | :tor}   │
└─────────────────────┬───────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────┐
│ handle_data/3                                       │
│   - Parse selector (CRLF terminated)               │
│   - Get host/port based on network type            │
│   - Route to handler function                      │
└─────────────────────┬───────────────────────────────┘
                      │
      ┌───────────────┼───────────────┐
      │               │               │
      ▼               ▼               ▼
 root_menu()    handle_ask()    about_page()
      │               │               │
      │               ▼               │
      │     AiEngine.generate()      │
      │               │               │
      └───────────────┴───────────────┘
                      │
                      ▼
            format_text_response()
                      │
                      ▼
              TCP Response + Close
```

## Ports & Network

| Environment | Clearnet | Tor Internal | Tor External |
|-------------|----------|--------------|--------------|
| prod (macOS) | **70** | 7071 | 70 |
| dev (Linux) | **7070** | 7071 | 70 |

**How Tor works:**
- App listens on `127.0.0.1:7071` (localhost only)
- Tor daemon maps `.onion:70` → `127.0.0.1:7071`
- Users connect to `your-address.onion:70` (standard Gopher port)

## Environment Variables

| Variable | Dev Default | Prod Default | Description |
|----------|-------------|--------------|-------------|
| `GOPHER_PORT` | 7070 | 70 | Clearnet port |
| `TOR_ENABLED` | true | true | Enable Tor listener |
| `TOR_PORT` | 7071 | 7071 | Tor internal port |
| `ONION_ADDRESS` | nil | nil | Your .onion address |

**Examples:**
```bash
# Disable Tor
TOR_ENABLED=false iex -S mix

# Set onion address
ONION_ADDRESS="abc123.onion" MIX_ENV=prod mix run --no-halt

# Custom ports
GOPHER_PORT=70 TOR_PORT=7071 iex -S mix
```

## Key Files

| File | Purpose |
|------|---------|
| `lib/pure_gopher_ai/application.ex` | Supervisor - starts AI serving + dual TCP listeners |
| `lib/pure_gopher_ai/ai_engine.ex` | Loads Bumblebee model, exposes `generate/1,2` |
| `lib/pure_gopher_ai/gopher_handler.ex` | RFC 1436 protocol, network-aware responses |
| `lib/pure_gopher_ai/conversation_store.ex` | Session-based chat history storage (ETS) |
| `lib/pure_gopher_ai/rate_limiter.ex` | Per-IP rate limiting with sliding window |
| `lib/pure_gopher_ai/gophermap.ex` | Static content serving with gophermap format |
| `lib/pure_gopher_ai/model_registry.ex` | Multi-model support with lazy loading |
| `config/config.exs` | Base config (port 70, Tor enabled) |
| `config/dev.exs` | Dev overrides (port 7070) |
| `config/prod.exs` | Production (port 70) |
| `config/test.exs` | Test (port 17070, Tor disabled) |
| `scripts/setup-tor.sh` | Automated Tor hidden service setup |

## Hardware Detection

```elixir
# macOS (Apple Silicon) -> Torchx with Metal MPS
# Linux/Other -> EXLA CPU fallback
case :os.type() do
  {:unix, :darwin} -> {Torchx.Backend, device: :mps}
  _ -> {EXLA.Backend, []}
end
```

## Gopher Protocol (RFC 1436)

### Selectors
| Selector | Action |
|----------|--------|
| `/` or empty | Root menu |
| `/ask <query>` | AI text generation (stateless) |
| `/chat <msg>` | Chat with conversation memory |
| `/clear` | Clear conversation history |
| `/models` | List available AI models |
| `/ask-<model> <query>` | Query with specific model |
| `/chat-<model> <msg>` | Chat with specific model |
| `/personas` | List available AI personas |
| `/persona-<name> <query>` | Query with specific persona |
| `/chat-persona-<name> <msg>` | Chat with specific persona |
| `/files` | Browse static content |
| `/about` | Server stats |

### Response Format
```
<type><text>\t<selector>\t<host>\t<port>\r\n
```

Types:
- `i` - Info line (non-selectable)
- `0` - Text file
- `1` - Directory/Menu
- `3` - Error
- `7` - Search/Query (for /ask, /chat)

Terminator: `.` on its own line

## Tor Setup

### Quick (Automated)
```bash
sudo ./scripts/setup-tor.sh
```

### Manual
1. Add to `/etc/tor/torrc`:
   ```
   HiddenServiceDir /var/lib/tor/pure_gopher_ai/
   HiddenServicePort 70 127.0.0.1:7071
   ```

2. Restart Tor:
   ```bash
   sudo systemctl restart tor   # Linux
   brew services restart tor    # macOS
   ```

3. Get .onion address:
   ```bash
   sudo cat /var/lib/tor/pure_gopher_ai/hostname
   ```

4. Set environment variable or update config:
   ```bash
   export ONION_ADDRESS="abc123.onion"
   ```

## Commands

```bash
# Development (Linux, port 7070)
iex -S mix

# Production (macOS, port 70)
MIX_ENV=prod mix run --no-halt

# With onion address
ONION_ADDRESS="abc123.onion" MIX_ENV=prod mix run --no-halt
```

## Client Connections

### Clearnet (standard clients)
```bash
# Production (port 70) - no port needed
lynx gopher://your-server.com/
bombadillo gopher://your-server.com
sacc your-server.com

# Development (port 7070)
lynx gopher://localhost:7070/
sacc localhost 7070
echo "" | nc localhost 7070
```

### Tor (anonymous)
```bash
torsocks lynx gopher://abc123.onion/
torsocks bombadillo gopher://abc123.onion
torsocks sacc abc123.onion
torsocks sh -c 'echo "" | nc abc123.onion 70'
```

### Linux Port 70
```bash
# setcap (recommended - no root at runtime)
sudo setcap 'cap_net_bind_service=+ep' $(which erl)
GOPHER_PORT=70 MIX_ENV=prod mix run --no-halt
```

## Dependencies
- `thousand_island` - TCP server
- `bumblebee` - Hugging Face model loading
- `nx` - Numerical computing
- `exla` - XLA backend (CPU/GPU)
- `torchx` - PyTorch backend (Metal MPS)
- `jason` - JSON handling

## Model
Default: `openai-community/gpt2` (lightweight, ~500MB)
Production: Consider Llama 2/3 or Mistral for better quality

## Notes
- First model load downloads from Hugging Face
- Nx.Serving provides automatic request batching
- All inference runs locally - no external API calls
- Tor listener only binds to localhost for security
- macOS allows port 70 without root; Linux requires setcap
