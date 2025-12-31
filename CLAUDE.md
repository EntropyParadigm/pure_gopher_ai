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
│                   │   │  0.0.0.0:7070     │   │  127.0.0.1:7071   │
│  ┌─────────────┐  │   └─────────┬─────────┘   └─────────┬─────────┘
│  │ Bumblebee   │  │             │                       │
│  │ GPT-2/Llama │  │             │                       │
│  └─────────────┘  │             │                       │
└─────────┬─────────┘             │                       │
          │                       ▼                       ▼
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
TCP Connection
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

## Ports

| Network  | Internal | External | Binding          |
|----------|----------|----------|------------------|
| Clearnet | 7070     | 7070     | 0.0.0.0 (all)    |
| Tor      | 7071     | 70       | 127.0.0.1 (local)|

**Port 70 vs 7070**: Standard Gopher is port 70, but it's privileged (requires root). We use 7070 for clearnet dev. Tor maps external 70 → internal 7071.

## Key Files

| File | Purpose |
|------|---------|
| `lib/pure_gopher_ai/application.ex` | Supervisor - starts AI serving + dual TCP listeners |
| `lib/pure_gopher_ai/ai_engine.ex` | Loads Bumblebee model, exposes `generate/1` |
| `lib/pure_gopher_ai/gopher_handler.ex` | RFC 1436 protocol, network-aware responses |
| `config/config.exs` | Backend detection, port config, onion address |
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
| `/ask <query>` | AI text generation |
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
   sudo systemctl restart tor
   ```

3. Get .onion address:
   ```bash
   sudo cat /var/lib/tor/pure_gopher_ai/hostname
   ```

4. Update `config/config.exs`:
   ```elixir
   onion_address: "abc123.onion"
   ```

## Commands

```bash
# Development
iex -S mix

# Production
MIX_ENV=prod mix run --no-halt

# Test clearnet
echo "" | nc localhost 7070
echo "/ask Hello" | nc localhost 7070

# Test Tor
torsocks nc <onion-address>.onion 70
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
