# PureGopherAI

A pure Elixir Gopher server (RFC 1436) with native AI inference via Bumblebee. Optimized for Apple Silicon with Metal GPU acceleration. Supports both clearnet and Tor hidden services.

## Features

### Core
- **Pure Elixir** - No external runtime dependencies (Python, Go, etc.)
- **Native AI** - Bumblebee + Nx for local GPU-accelerated inference
- **Apple Silicon Optimized** - Torchx backend with Metal MPS
- **Tor Support** - Built-in hidden service listener
- **Gemini Protocol** - Optional TLS on port 1965
- **OTP Supervision** - Fault-tolerant architecture

### AI Capabilities
- **AI Chat** - Conversational AI with session memory
- **Multi-Model Support** - Switch between AI models
- **AI Personas** - Character-based AI responses
- **RAG** - Query your documents with AI-enhanced answers
- **Summarization** - TL;DR for phlog posts and documents
- **Translation** - 25+ language support
- **Content Discovery** - AI-powered recommendations

### Content & Community
- **Phlog** - Gopher blog with Atom feed
- **Phlog Formatting** - AI-powered Markdown to Gopher conversion with medieval manuscript decorations
- **ANSI Color Art** - 16-color terminal art for supporting clients
- **User Profiles** - Personal homepages with passphrase auth
- **User Phlog** - User-submitted blog posts
- **Comments** - Phlog comment system
- **Mailbox** - Internal messaging
- **Guestbook** - Visitor signatures

### Interactive Features
- **Polls** - Voting and surveys
- **Trivia** - Quiz game with leaderboard
- **Games** - Hangman, Number Guess, Word Scramble
- **Text Adventure** - RPG-style game engine
- **ASCII Art** - Text-to-art generation

### Utilities
- **Search** - Full-text search with ranking
- **Pastebin** - Text sharing
- **URL Shortener** - Link shortening
- **Calculator** - Math expression evaluator
- **Unit Converter** - Length, weight, temperature, etc.
- **Bookmarks** - User favorites
- **Calendar** - Community events

### Security
- **Rate Limiting** - Per-IP with auto-ban
- **Prompt Injection Defense** - AI input sanitization
- **Output Sanitization** - Sensitive data redaction
- **Request Validation** - Size limits, pattern blocking
- **Passphrase Auth** - Secure user authentication

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

## Ports

| Environment | Clearnet Port | Tor Internal | Tor External |
|-------------|---------------|--------------|--------------|
| Production (macOS) | **70** | 7071 | 70 |
| Development (Linux) | **7070** | 7071 | 70 |

- **macOS**: Port 70 works without root - standard clients just work
- **Linux dev**: Uses 7070 by default (override with `GOPHER_PORT=70`)
- **Tor**: Always maps external port 70 → internal 7071

## Quick Start

```bash
# Clone
git clone https://github.com/EntropyParadigm/pure_gopher_ai.git
cd pure_gopher_ai

# Install dependencies
mix deps.get

# Run (first run downloads AI model ~500MB)
iex -S mix

# Test with netcat
echo "" | nc localhost 7070
echo "/ask What is Elixir?" | nc localhost 7070
```

## Connecting with Gopher Clients

### Production (port 70) - Standard Clients Just Work

```bash
# Lynx
lynx gopher://your-server.com/

# Bombadillo
bombadillo gopher://your-server.com

# sacc
sacc your-server.com

# gopher command
gopher your-server.com

# curl
curl gopher://your-server.com/
curl "gopher://your-server.com/0/ask What is Elixir"
```

### Development (port 7070)

```bash
# Lynx
lynx gopher://localhost:7070/

# Bombadillo
bombadillo gopher://localhost:7070

# sacc
sacc localhost 7070

# netcat
echo "" | nc localhost 7070
echo "/ask Hello" | nc localhost 7070
```

### Tor (.onion)

```bash
# Lynx via torsocks
torsocks lynx gopher://abc123.onion/

# Bombadillo (configure SOCKS proxy)
bombadillo gopher://abc123.onion

# sacc via torsocks
torsocks sacc abc123.onion

# netcat via torsocks
torsocks sh -c 'echo "" | nc abc123.onion 70'
```

### Linux: Enabling Port 70

On Linux, port 70 requires elevated privileges. Options:

```bash
# Option 1: setcap (recommended)
sudo setcap 'cap_net_bind_service=+ep' $(which erl)
GOPHER_PORT=70 iex -S mix

# Option 2: Environment variable (use dev port)
GOPHER_PORT=7070 MIX_ENV=prod mix run --no-halt

# Option 3: iptables redirect
sudo iptables -t nat -A PREROUTING -p tcp --dport 70 -j REDIRECT --to-port 7070
```

## Tor Hidden Service Setup

### Automated Setup

```bash
sudo ./scripts/setup-tor.sh
```

### Manual Setup

1. Install Tor:
   ```bash
   # Arch Linux
   sudo pacman -S tor

   # macOS
   brew install tor

   # Debian/Ubuntu
   sudo apt install tor
   ```

2. Configure hidden service in `/etc/tor/torrc`:
   ```
   HiddenServiceDir /var/lib/tor/pure_gopher_ai/
   HiddenServicePort 70 127.0.0.1:7071
   ```

3. Restart Tor:
   ```bash
   sudo systemctl restart tor
   ```

4. Get your .onion address:
   ```bash
   sudo cat /var/lib/tor/pure_gopher_ai/hostname
   # Example: abc123xyz456.onion
   ```

5. Update `config/config.exs`:
   ```elixir
   config :pure_gopher_ai,
     onion_address: "abc123xyz456.onion"
   ```

6. Test via Tor:
   ```bash
   torsocks nc abc123xyz456.onion 70
   ```

## Configuration

### Environment Variables

| Variable | Default (dev) | Default (prod) | Description |
|----------|---------------|----------------|-------------|
| `GOPHER_PORT` | 7070 | 70 | Clearnet listening port |
| `TOR_ENABLED` | true | true | Enable Tor listener (set to "false" to disable) |
| `TOR_PORT` | 7071 | 7071 | Tor internal listening port |
| `ONION_ADDRESS` | nil | nil | Your .onion address for Gopher responses |

### Example Usage

```bash
# Development with custom port
GOPHER_PORT=7070 iex -S mix

# Production with Tor disabled
TOR_ENABLED=false MIX_ENV=prod mix run --no-halt

# Production with onion address
ONION_ADDRESS="abc123.onion" MIX_ENV=prod mix run --no-halt
```

### Config Files

| File | Purpose |
|------|---------|
| `config/config.exs` | Base configuration |
| `config/dev.exs` | Development (port 7070) |
| `config/prod.exs` | Production (port 70) |
| `config/test.exs` | Testing (port 17070, Tor disabled) |

## Hardware Detection

The server automatically selects the optimal compute backend:

| Platform | Backend | Acceleration |
|----------|---------|--------------|
| macOS (Apple Silicon) | Torchx | Metal MPS GPU |
| Linux/Other | EXLA | CPU |

## Gopher Protocol

### Key Selectors

| Selector | Description |
|----------|-------------|
| `/` | Root menu |
| `/ask <query>` | AI text generation |
| `/chat <msg>` | AI chat with memory |
| `/phlog` | Gopher blog index |
| `/phlog/format` | Phlog formatting tools |
| `/phlog/format/color` | ANSI color art |
| `/docs` | Document knowledge base |
| `/docs/ask <query>` | RAG document query |
| `/search <query>` | Full-text search |
| `/users` | User profiles |
| `/mail` | Private messaging |
| `/games` | Interactive games |
| `/trivia` | Quiz game |
| `/polls` | Polls and voting |
| `/paste` | Pastebin |
| `/art` | ASCII art generator |
| `/utils` | Quick utilities |
| `/sitemap` | Full server sitemap |

See `CLAUDE.md` for the complete selector reference.

### Response Types

- `i` - Info text (non-selectable)
- `0` - Text file
- `1` - Directory/Menu
- `3` - Error
- `7` - Search/Query input

## Dependencies

- `thousand_island` - TCP server
- `bumblebee` - Hugging Face model loading
- `nx` - Numerical computing
- `exla` - XLA backend (CPU/CUDA)
- `torchx` - PyTorch backend (Metal MPS)

## Production

```bash
# Build release
MIX_ENV=prod mix release

# Run
_build/prod/rel/pure_gopher_ai/bin/pure_gopher_ai start
```

## License

MIT
