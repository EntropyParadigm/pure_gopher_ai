# PureGopherAI - Project Context

## Overview
A pure Elixir Gopher server (RFC 1436) with AI inference. Dual-target: macOS Apple Silicon (Ollama + Bumblebee) and Raspberry Pi 3B/3B+ via Nerves (Google Gemini Flash API). Triple-stack: clearnet + Tor hidden service + Gemini protocol (TLS).

### Dual-Target Architecture

| | macOS (host) | Raspberry Pi (rpi3) |
|---|---|---|
| **MIX_TARGET** | unset or `host` | `rpi3` |
| **AI Backend** | Ollama + Bumblebee fallback | Google Gemini Flash 2.5 API |
| **ML Libraries** | Nx, EXLA, Torchx, Bumblebee | None (too heavy for 1GB RAM) |
| **Tor** | System daemon (external) | TorManager GenServer (managed) |
| **Data Path** | `~/.gopher/` | `/data/gopher/` (Nerves writable partition) |
| **Config** | `config.exs` + `{env}.exs` | `config.exs` + `{env}.exs` + `target.exs` |

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
| `OLLAMA_ENABLED` | true | true | Enable Ollama AI backend |
| `OLLAMA_URL` | http://localhost:11434 | http://localhost:11434 | Ollama server URL |
| `OLLAMA_MODEL` | gemma4:e2b | gemma4:e2b | Ollama model to use |
| `AI_MODEL` | openai-community/gpt2 | openai-community/gpt2 | Bumblebee fallback model |
| `HF_TOKEN` | nil | nil | HuggingFace token (for gated models) |
| `GEMINI_API_KEY` | nil | nil | Google Gemini API key (Pi target) |
| `GEMINI_MODEL` | gemini-2.5-flash | gemini-2.5-flash | Gemini model name |
| `WIFI_SSID` | nil | nil | WiFi network name (Pi target, compile-time) |
| `WIFI_PSK` | nil | nil | WiFi password (Pi target, compile-time) |

**Examples:**
```bash
# macOS development (unchanged)
iex -S mix

# Disable Tor
TOR_ENABLED=false iex -S mix

# Set onion address
ONION_ADDRESS="abc123.onion" MIX_ENV=prod mix run --no-halt

# Custom ports
GOPHER_PORT=70 TOR_PORT=7071 iex -S mix

# Pi firmware build + OTA deploy (handles the dev/port/token/validate gotchas)
./scripts/deploy-pi.sh                 # or: ./scripts/deploy-pi.sh 192.168.1.2
```

## Key Files

| File | Purpose |
|------|---------|
| `lib/pure_gopher_ai/application.ex` | Supervisor - starts AI serving + TCP/TLS listeners |
| `lib/pure_gopher_ai/ai_engine.ex` | Loads Bumblebee model, exposes `generate/1,2` |
| `lib/pure_gopher_ai/gopher_handler.ex` | RFC 1436 protocol, network-aware responses |
| `lib/pure_gopher_ai/gemini_handler.ex` | Gemini protocol handler (TLS on port 1965) |
| `lib/pure_gopher_ai/conversation_store.ex` | Session-based chat history storage (ETS) |
| `lib/pure_gopher_ai/rate_limiter.ex` | Per-IP rate limiting with sliding window |
| `lib/pure_gopher_ai/blocklist.ex` | External blocklist integration (FireHOL, Floodgap) |
| `lib/pure_gopher_ai/gophermap.ex` | Static content serving with gophermap format |
| `lib/pure_gopher_ai/model_registry.ex` | Multi-model support with lazy loading |
| `lib/pure_gopher_ai/response_cache.ex` | Response caching with LRU eviction |
| `lib/pure_gopher_ai/telemetry.ex` | Metrics and request tracking |
| `lib/pure_gopher_ai/phlog.ex` | Gopher blog with Atom feed |
| `lib/pure_gopher_ai/search.ex` | Full-text search with ranking |
| `lib/pure_gopher_ai/ascii_art.ex` | Text-to-ASCII art generation |
| `lib/pure_gopher_ai/admin.ex` | Admin interface with token auth |
| `lib/pure_gopher_ai/rag.ex` | RAG main module - document queries |
| `lib/pure_gopher_ai/rag/document_store.ex` | Document storage, chunking, extraction |
| `lib/pure_gopher_ai/rag/embeddings.ex` | Vector embeddings with sentence-transformers |
| `lib/pure_gopher_ai/rag/file_watcher.ex` | Auto-ingestion from watch directory |
| `lib/pure_gopher_ai/summarizer.ex` | AI summarization, translation, digests |
| `lib/pure_gopher_ai/gopher_proxy.ex` | Fetch external Gopher content |
| `lib/pure_gopher_ai/pastebin.ex` | Pastebin for text sharing |
| `lib/pure_gopher_ai/polls.ex` | Polling/voting system |
| `lib/pure_gopher_ai/phlog_comments.ex` | Phlog comment system |
| `lib/pure_gopher_ai/user_profiles.ex` | User profile/homepage system |
| `lib/pure_gopher_ai/calendar.ex` | Community event calendar |
| `lib/pure_gopher_ai/url_shortener.ex` | URL shortener service |
| `lib/pure_gopher_ai/utilities.ex` | Quick utilities (dice, 8ball, hash, etc) |
| `lib/pure_gopher_ai/sitemap.ex` | Full server sitemap and endpoint registry |
| `lib/pure_gopher_ai/mailbox.ex` | Internal messaging system |
| `lib/pure_gopher_ai/trivia.ex` | Trivia quiz game with leaderboard |
| `lib/pure_gopher_ai/bookmarks.ex` | User bookmarks and favorites |
| `lib/pure_gopher_ai/unit_converter.ex` | Unit conversion (length, weight, temp, etc) |
| `lib/pure_gopher_ai/calculator.ex` | Mathematical expression evaluator |
| `lib/pure_gopher_ai/games.ex` | Simple games (Hangman, Number Guess, Word Scramble) |
| `lib/pure_gopher_ai/phlog_formatter.ex` | AI-powered Markdown to Gopher conversion |
| `lib/pure_gopher_ai/phlog_art.ex` | Thematic ASCII art library (15+ themes) |
| `lib/pure_gopher_ai/ansi_art.ex` | 16-color ANSI art for terminal clients |
| `lib/pure_gopher_ai/input_sanitizer.ex` | Prompt injection defense, input sanitization |
| `lib/pure_gopher_ai/output_sanitizer.ex` | AI output sanitization, sensitive data redaction |
| `lib/pure_gopher_ai/request_validator.ex` | Request validation, size limits, pattern blocking |
| `lib/pure_gopher_ai/gemini_api.ex` | Google Gemini Flash API client (Pi AI backend) |
| `lib/pure_gopher_ai/tor_manager.ex` | Tor process manager for Nerves (writes torrc, starts/monitors Tor) |
| `config/config.exs` | Base config (port 70, Tor enabled) |
| `config/dev.exs` | Dev overrides (port 7070) |
| `config/prod.exs` | Production (port 70) |
| `config/test.exs` | Test (port 17070, Tor disabled) |
| `config/target.exs` | Nerves target config (paths, networking, Gemini API backend) |
| `scripts/setup-tor.sh` | Automated Tor hidden service setup |
| `scripts/build-tor-arm.sh` | Cross-compile static Tor binary for Pi |
| `rootfs_overlay/usr/bin/` | Nerves firmware overlay (place static Tor binary here) |
| `scripts/setup-gopher-user.sh` | Create dedicated gopher user for production |
| `scripts/gopher-service.sh` | Service management helper (start/stop/status) |

## Hardware Detection

```elixir
# macOS (Apple Silicon) -> Torchx with Metal MPS
# Linux/Other -> EXLA CPU fallback
case :os.type() do
  {:unix, :darwin} -> {Torchx.Backend, device: :mps}
  _ -> {EXLA.Backend, []}
end
```

## Apple Silicon Setup (M1/M2/M3/M4)

Torchx requires native ARM64 tooling and a manual libtorch download (PyTorch's official macOS downloads currently return 403 errors).

### Prerequisites

Install ARM-native tools via Homebrew:
```bash
# Ensure Homebrew is ARM native (should be in /opt/homebrew)
/opt/homebrew/bin/brew install cmake libomp node elixir
```

### Libtorch Setup

Download the ARM64 nightly build:
```bash
mkdir -p ~/libtorch && cd ~/libtorch
curl -LO https://download.pytorch.org/libtorch/nightly/cpu/libtorch-macos-arm64-latest.zip
unzip libtorch-macos-arm64-latest.zip
```

### Environment Variables

Add to `~/.zshrc` (or `~/.bashrc`):
```bash
# ARM Homebrew (must be first to use ARM tools over x86)
export PATH="/opt/homebrew/bin:$PATH"

# Torchx / libtorch
export LIBTORCH_DIR=~/libtorch/libtorch
```

### Verification

```bash
# Verify ARM mode
uname -m                    # Should show: arm64
arch                        # Should show: arm64

# Verify tools are ARM
file $(which cmake)         # Should show: arm64
file $(which node)          # Should show: arm64
file ~/libtorch/libtorch/lib/libtorch.dylib  # Should show: arm64

# After building, verify torchx.so
file _build/dev/lib/torchx/priv/torchx.so    # Should show: arm64
```

### Common Issues

| Issue | Cause | Fix |
|-------|-------|-----|
| `ld: found architecture 'arm64', required architecture 'x86_64'` | x86 cmake in PATH | Ensure `/opt/homebrew/bin` is first in PATH |
| `Library not loaded: libomp.dylib` | Missing OpenMP | `brew install libomp` |
| Torchx downloads fail (403) | PyTorch CDN blocks macOS | Use manual libtorch download above |
| Running under Rosetta | x86 Node.js | Install ARM Node via Homebrew |

### Clean Rebuild

If switching architectures or fixing build issues:
```bash
rm -rf _build deps
mix deps.get
mix compile
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
| `/docs` | Document knowledge base |
| `/docs/list` | List ingested documents |
| `/docs/ask <query>` | Query documents with RAG |
| `/docs/search <query>` | Search documents |
| `/docs/view/<id>` | View document details |
| `/summary/phlog/<path>` | TL;DR summary of phlog entry |
| `/summary/doc/<id>` | Summarize document |
| `/translate` | Translation service menu |
| `/translate/<lang>/phlog/<path>` | Translate phlog entry |
| `/translate/<lang>/doc/<id>` | Translate document |
| `/digest` | AI daily digest |
| `/topics` | Discover content themes |
| `/discover <interest>` | AI content recommendations |
| `/explain <term>` | AI explanation of term |
| `/fetch <url>` | Fetch external Gopher content |
| `/fetch-summary <url>` | Fetch and summarize |
| `/phlog` | Gopher blog index |
| `/phlog/page/<n>` | Paginated phlog index |
| `/phlog/feed` | Atom feed |
| `/phlog/year/<YYYY>` | Entries by year |
| `/phlog/month/<YYYY>/<MM>` | Entries by month |
| `/phlog/entry/<path>` | Single phlog entry |
| `/search` | Search content (Type 7) |
| `/search <query>` | Execute search |
| `/art` | ASCII art menu |
| `/art/text <text>` | Large block letters |
| `/art/small <text>` | Compact letters |
| `/art/banner <text>` | Text with border |
| `/admin/<token>` | Admin panel (token-protected) |
| `/files` | Browse static content |
| `/about` | Server info |
| `/stats` | Detailed metrics |
| `/paste` | Pastebin menu |
| `/paste/new` | Create new paste |
| `/paste/recent` | Recent pastes |
| `/paste/<id>` | View paste |
| `/paste/raw/<id>` | Raw paste content |
| `/polls` | Polls menu |
| `/polls/new` | Create new poll |
| `/polls/active` | Active polls |
| `/polls/closed` | Closed polls |
| `/polls/<id>` | View poll results |
| `/polls/vote/<id>/<n>` | Vote on poll |
| `/phlog/comments/<path>` | View comments for phlog entry |
| `/phlog/comments/<path>/comment` | Add comment to entry |
| `/phlog/comments/recent` | Recent comments across all entries |
| `/users` | User profiles menu |
| `/users/create` | Create profile |
| `/users/list` | Browse all users |
| `/users/search` | Search users |
| `/users/~<username>` | View user homepage |
| `/calendar` | Calendar menu |
| `/calendar/create` | Create event |
| `/calendar/upcoming` | Upcoming events |
| `/calendar/month/YYYY/MM` | View month |
| `/calendar/event/<id>` | View event |
| `/short` | URL shortener menu |
| `/short/create` | Create short URL |
| `/short/recent` | Recent short URLs |
| `/short/<code>` | Redirect to URL |
| `/utils` | Quick utilities menu |
| `/utils/dice` | Roll dice (NdM format) |
| `/utils/8ball` | Magic 8-Ball |
| `/utils/coin` | Flip a coin |
| `/utils/random` | Random number |
| `/utils/pick` | Random item picker |
| `/utils/uuid` | Generate UUID v4 |
| `/utils/password` | Generate password |
| `/utils/hash` | Calculate hashes |
| `/utils/base64/encode` | Base64 encode |
| `/utils/base64/decode` | Base64 decode |
| `/utils/rot13` | ROT13 cipher |
| `/utils/timestamp` | Convert timestamp |
| `/utils/now` | Current timestamp |
| `/utils/count` | Count text |
| `/sitemap` | Full server sitemap |
| `/sitemap/category/<name>` | Browse category |
| `/sitemap/search` | Search endpoints |
| `/sitemap/text` | Plain text sitemap |
| `/mail` | Mailbox / Private messaging |
| `/mail/inbox/<user>` | View inbox |
| `/mail/sent/<user>` | View sent messages |
| `/mail/compose/<user>` | Compose message |
| `/trivia` | Trivia quiz game |
| `/trivia/play` | Play random question |
| `/trivia/play/<category>` | Play from category |
| `/trivia/score` | View session score |
| `/trivia/leaderboard` | High scores |
| `/bookmarks` | Bookmarks / Favorites |
| `/bookmarks/user/<username>` | View user's bookmarks |
| `/bookmarks/add/<username>` | Add bookmark |
| `/bookmarks/folders/<username>` | Manage folders |
| `/convert` | Unit converter |
| `/convert <query>` | Convert units (e.g., "100 km to mi") |
| `/calc` | Calculator |
| `/calc <expression>` | Evaluate expression (e.g., "2 + 2") |
| `/games` | Simple games (Hangman, Number Guess, Word Scramble) |
| `/games/hangman` | Start Hangman game |
| `/games/hangman/guess` | Guess a letter |
| `/games/number` | Start Number Guess |
| `/games/number/guess` | Guess a number |
| `/games/scramble` | Start Word Scramble |
| `/games/scramble/guess` | Guess the word |
| `/phlog/format` | Phlog formatting tools menu |
| `/phlog/format/preview` | Preview formatted content |
| `/phlog/format/styles` | View formatting styles |
| `/phlog/format/art` | ASCII art gallery |
| `/phlog/format/art/<theme>` | View theme art |
| `/phlog/format/color` | ANSI color art menu |
| `/phlog/format/color/gallery` | Color art gallery |
| `/phlog/format/color/gallery/<theme>` | View theme color art |
| `/phlog/format/color/preview` | Preview color formatting |
| `/phlog/format/color/borders` | View color border styles |

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
# macOS development (port 7070)
iex -S mix

# macOS production (port 70)
MIX_ENV=prod mix run --no-halt

# With onion address
ONION_ADDRESS="abc123.onion" MIX_ENV=prod mix run --no-halt

# Sync and deploy to gopher user (macOS production)
sudo ./scripts/sync-gopher.sh

# EXLA compile fix for Xcode 16.3+
CFLAGS="-Wno-error=invalid-specialization" mix deps.compile exla --force

# Pi firmware build + OTA deploy (recommended: does everything correctly)
./scripts/deploy-pi.sh                 # build, stream via fwup, reboot, validate

# Pi first deploy (burn SD card) — build first, see "Build Firmware" below
mix burn

# Cross-compile static Tor for Pi
./scripts/build-tor-arm.sh
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

### Shared (both targets)
- `thousand_island` - TCP server
- `finch` - HTTP client (Gemini API, general HTTP)
- `jason` - JSON handling
- `burrow` - TCP/UDP tunneling (expose services without opening ports)
- `nerves` - Embedded framework (runtime: false on host)
- `shoehorn` - Boot management
- `ring_logger` - In-memory logging
- `toolshed` - IEx helpers
- Ollama - Local LLM server (primary AI, external dependency, host only)

### Host-only (macOS, `targets: [:host]`)
- `bumblebee` - Hugging Face model loading (fallback AI)
- `nx` - Numerical computing
- `exla` - XLA backend (CPU/GPU)
- `torchx` - PyTorch backend (Metal MPS)

### Device-only (Pi, `targets: @all_targets`)
- `nerves_runtime` - Nerves system runtime
- `nerves_pack` - Network, SSH, NTP bundle
- `nerves_system_rpi3` - Pi 3B/3B+ system image
- `vintage_net_ethernet` / `vintage_net_wifi` - Network config

## Burrow Tunneling

Expose your PureGopherAI services to the internet without opening router ports using Burrow.

### Architecture
```
┌─────────────┐         Internet          ┌─────────────┐
│ PureGopher  │◄════════════════════════►│   Burrow    │◄──── Public Users
│   (Home)    │    Encrypted Tunnel       │   Server    │      gopher://relay.com
└─────────────┘                           │   (VPS)     │
  localhost:70                            └─────────────┘
                                            relay.com:70
```

### Setup

1. **Deploy Burrow Server on VPS:**
   ```bash
   # On your VPS
   ./burrow server --port 4000 --token YOUR_SECRET_TOKEN
   ```

2. **Configure PureGopherAI:**
   ```bash
   # Set environment variables
   export BURROW_SERVER="your-vps.com:4000"
   export BURROW_TOKEN="YOUR_SECRET_TOKEN"
   ```

3. **Enable in config:**
   ```elixir
   # config/config.exs or config/prod.exs
   config :pure_gopher_ai, :tunnel,
     enabled: true,
     server: System.get_env("BURROW_SERVER"),
     token: {:system, "BURROW_TOKEN"},
     tunnels: [
       [name: "gopher", local: 70, remote: 70],
       [name: "gemini", local: 1965, remote: 1965]
     ]
   ```

4. **Start PureGopherAI:**
   ```bash
   MIX_ENV=prod mix run --no-halt
   # Tunnel connects automatically
   ```

### Tunnel Status

Check tunnel status via admin interface or:
```elixir
PureGopherAi.Tunnel.status()
# => %{enabled: true, status: :connected, tunnels: [...]}
```

## Model

### AI Backend Selection

Set via `config :pure_gopher_ai, ai_backend:` (`:ollama` default, `:gemini_api` for Pi):

```elixir
# ai_engine.ex routes based on backend:
case ai_backend() do
  :gemini_api -> GeminiApi.generate(prompt, system: system_prompt)
  _           -> Ollama -> Bumblebee fallback chain
end
```

### Host: Ollama (default)
- **Default model:** `gemma4:e2b` (Google Gemma 4, instruction-tuned, ~7.2GB)
- Ollama enabled by default (`OLLAMA_ENABLED=true`)
- Supports streaming, chat, and tool use
- Override model: `OLLAMA_MODEL=gemma4:e4b` (larger) or any Ollama model

### Host Fallback: Bumblebee
- **Fallback model:** `openai-community/gpt2` (lightweight, ~500MB)
- Used automatically if Ollama is unavailable
- Bumblebee 0.6.3 supports: GPT-2, Gemma 1, Llama (not Gemma 2/3/4)
- Note: Bumblebee always loads at startup (consumes memory for fallback)

### Pi: Google Gemini Flash 2.5 API
- **Default model:** `gemini-2.5-flash` (cloud, via `GEMINI_API_KEY`)
- Requires internet access (API calls to Google)
- Supports streaming, chat, multi-turn conversations
- Override model: `GEMINI_MODEL=gemini-2.5-pro`
- Module: `lib/pure_gopher_ai/gemini_api.ex` (Finch HTTP client)

## Gemini Protocol

PureGopherAI also supports the Gemini protocol (gemini://) on port 1965 with TLS.

### Setup
```bash
# Generate TLS certificates
mkdir -p ~/.gopher/gemini
openssl req -x509 -newkey rsa:4096 -keyout ~/.gopher/gemini/key.pem -out ~/.gopher/gemini/cert.pem -days 365 -nodes

# Enable in config/config.exs
config :pure_gopher_ai,
  gemini_enabled: true,
  gemini_port: 1965,
  gemini_cert_file: "~/.gopher/gemini/cert.pem",
  gemini_key_file: "~/.gopher/gemini/key.pem"
```

### Gemini Response Codes
- 10: Input required (meta = prompt)
- 20: Success (meta = MIME type)
- 30: Redirect (meta = new URL)
- 40: Temporary failure
- 50: Permanent failure
- 60: Client certificate required

## RAG (Retrieval Augmented Generation)

Query your own documents with AI-enhanced answers.

### Setup
```bash
# Create docs directory
mkdir -p ~/.gopher/docs

# Drop documents into the directory (auto-ingested)
cp mydoc.pdf ~/.gopher/docs/
cp notes.md ~/.gopher/docs/
```

### Supported Formats
- Plain text (.txt, .text)
- Markdown (.md, .markdown)
- PDF (.pdf) - requires `pdftotext` for best results

### Configuration
```elixir
config :pure_gopher_ai,
  rag_enabled: true,
  rag_docs_dir: "~/.gopher/docs",
  rag_chunk_size: 512,          # Words per chunk
  rag_chunk_overlap: 50,        # Overlap between chunks
  rag_embeddings_enabled: true,
  rag_embedding_model: "sentence-transformers/all-MiniLM-L6-v2"
```

## AI Tools

### Summarization
- `/summary/phlog/<path>` - TL;DR for blog posts
- `/summary/doc/<id>` - Document summaries

### Translation (25+ languages)
- `/translate` - List supported languages
- `/translate/<lang>/phlog/<path>` - Translate blog post
- `/translate/<lang>/doc/<id>` - Translate document

Supported: en, es, fr, de, it, pt, ja, ko, zh, ru, ar, hi, nl, pl, tr, vi, th, sv, da, fi, no, el, he, uk, cs

### Dynamic Content
- `/digest` - AI-generated daily digest
- `/topics` - Discover themes in your content
- `/discover <interest>` - Content recommendations
- `/explain <term>` - AI explanations

### Gopher Proxy
- `/fetch <url>` - Fetch external Gopher content
- `/fetch-summary <url>` - Fetch and AI summarize

## Phlog Formatting & Creative Tools

AI-powered content formatting with medieval manuscript-inspired decorations.

### PhlogFormatter Module
Converts Markdown to Gopher format with decorative elements:
- Headers, links, images, lists, code blocks, blockquotes
- Auto URL detection (HTTP, Gopher, email)
- Illuminated drop caps (decorative first letters)
- Medieval-style borders and ornaments
- Thematic ASCII art based on content

### Formatting Styles
- `:minimal` - Simple borders, clean text
- `:ornate` - Box frames with ornaments
- `:medieval` - Full medieval manuscript style

### ASCII Art Themes (PhlogArt)
technology, nature, adventure, knowledge, music, space, fantasy, food, home, time, love, animals, weather, celebration, default

### ANSI Color Art (AnsiArt)
16-color ANSI escape codes for terminals that support it:
- Basic colors: black, red, green, yellow, blue, magenta, cyan, white
- Bright colors: bright_black, bright_red, bright_green, etc.
- Rainbow, fire, ocean, forest, gold, magic dividers
- Colorful illuminated drop caps
- `strip_ansi/1` for fallback to plain text

### Usage
```elixir
# Plain ASCII formatting
PhlogFormatter.format(title, body, host: "localhost", port: 70, style: :medieval)

# With ANSI color output
PhlogFormatter.format(title, body, host: "localhost", port: 70, style: :medieval, color: true)

# Get themed art
PhlogArt.get_art(:technology)     # Plain ASCII
AnsiArt.get_art(:technology)      # With ANSI colors

# Illuminated drop cap
PhlogArt.illuminated_letter("A")  # Plain
AnsiArt.get_drop_cap("A")         # Colored
```

## Notes

### General
- Tor listener only binds to localhost for security
- Gemini protocol requires TLS certificates (self-signed OK)
- RAG auto-ingests documents from watch directory every 30s

### macOS (host)
- Primary AI uses Ollama (must be running locally); Bumblebee is fallback
- First Ollama request may be slow (model loading into GPU memory)
- Bumblebee model downloads from Hugging Face on first run
- Nx.Serving provides automatic request batching for Bumblebee
- All inference runs locally - no external API calls
- macOS allows port 70 without root; Linux requires setcap
- EXLA on macOS with Xcode 16.3+ requires `CFLAGS="-Wno-error=invalid-specialization"` to compile

### Raspberry Pi (rpi3)
- AI uses Google Gemini Flash API (requires internet + `GEMINI_API_KEY`)
- ML libraries (Nx, EXLA, Torchx, Bumblebee) are excluded from firmware
- RAG embeddings are disabled (keyword search fallback only)
- Data persists on `/data/gopher/` (Nerves writable partition, survives firmware updates)
- TorManager manages Tor process lifecycle (no system daemon)
- Static Tor binary must be cross-compiled and placed in `rootfs_overlay/usr/bin/tor`
- Memory-constrained: cache limited to 100 entries, conversations to 5 messages
- VM args tuned for 1GB RAM: 4 schedulers, 16 async threads, aggressive GC

## Security

### Prompt Injection Defense
All AI queries are protected against prompt injection:

```elixir
# InputSanitizer detects and blocks injection patterns:
# - "ignore previous instructions"
# - "you are now", "pretend to be"
# - "[SYSTEM]", "<<SYS>>"
# - Jailbreak attempts

# Use safe generation functions:
AiEngine.generate_safe(user_input)           # Blocks if injection detected
AiEngine.generate_stream_safe(input, ctx, cb) # Streaming with protection
```

### Request Validation
```elixir
# RequestValidator limits:
# - Max selector length: 1024 chars
# - Max query length: 4000 chars
# - Blocks: path traversal, command injection, null bytes
# - Limits special character ratio
```

### Output Sanitization
```elixir
# OutputSanitizer redacts:
# - API keys (OpenAI, Anthropic, AWS, GitHub)
# - Passwords and secrets
# - Private IP addresses
# - System prompt leakage
```

### Abuse Detection
```elixir
# RateLimiter includes:
# - Sliding window rate limiting (default: 60 req/min)
# - Burst detection (>20 req in 5 seconds)
# - Automatic violation tracking
# - Auto-ban after 5 violations (configurable)

# Config options:
config :pure_gopher_ai,
  rate_limit_enabled: true,
  rate_limit_requests: 60,
  rate_limit_window_ms: 60_000,
  rate_limit_auto_ban: true,
  rate_limit_ban_threshold: 5
```

### Protocol-Level Protections
- Gopher output escaping (lone dots, tabs, CRLF normalization)
- Gemini output escaping
- Path traversal prevention in file serving
- Admin token authentication

### Blocklist Whitelist
The blocklist automatically exempts localhost and private IP ranges to allow local development and testing:
- `127.0.0.0/8` - IPv4 loopback
- `10.0.0.0/8` - Private network
- `172.16.0.0/12` - Private network
- `192.168.0.0/16` - Private network
- `::1` - IPv6 loopback

## Production Deployment (Dedicated User)

For production deployments, run PureGopherAI as a dedicated unprivileged user for security isolation while preserving Metal GPU access.

### Quick Setup
```bash
sudo ./scripts/setup-gopher-user.sh
```

This script:
1. Creates a `gopher` user (UID 599)
2. Sets up directory structure at `/Users/gopher/.gopher/`
3. Migrates existing data from your home directory
4. Copies project files and libtorch
5. Compiles dependencies
6. Creates launchd service (not loaded automatically)

### Service Management
```bash
# Load service (enables auto-start on boot)
sudo launchctl load /Library/LaunchDaemons/com.puregopherai.server.plist

# Start the service
sudo launchctl start com.puregopherai.server

# Or use the helper script:
sudo ./scripts/gopher-service.sh load
sudo ./scripts/gopher-service.sh start
```

### Service Commands
```bash
sudo ./scripts/gopher-service.sh status   # Show status and test connection
sudo ./scripts/gopher-service.sh start    # Start the service
sudo ./scripts/gopher-service.sh stop     # Stop the service
sudo ./scripts/gopher-service.sh restart  # Restart the service
sudo ./scripts/gopher-service.sh logs     # Follow server logs
sudo ./scripts/gopher-service.sh errors   # Follow error logs
sudo ./scripts/gopher-service.sh test     # Test Gopher response
sudo ./scripts/gopher-service.sh load     # Enable auto-start
sudo ./scripts/gopher-service.sh unload   # Disable auto-start
```

### Directory Structure
```
/Users/gopher/
├── .gopher/
│   ├── data/           # Server data (700)
│   ├── backups/        # Backups (700)
│   ├── phlog/          # Blog posts
│   ├── docs/           # RAG documents
│   ├── gemini/         # TLS certs (700)
│   ├── finger/         # Finger protocol data
│   ├── plugins/        # Plugin storage
│   ├── server.log      # Application logs
│   └── server-error.log
├── .cache/huggingface/ # Model cache
├── libtorch/           # Metal GPU support
├── pure_gopher_ai/     # Application
├── run-gopher.sh       # Launch script
└── .zshrc              # Environment variables
```

### Security Benefits
- Process runs with minimal privileges
- Cannot access files outside `/Users/gopher/`
- If compromised, attacker is confined to the gopher user
- Metal GPU acceleration preserved (no container overhead)

### Verification
```bash
# Verify user isolation
sudo -u gopher whoami                    # Should print: gopher
sudo -u gopher ls /Users/anthonyramirez  # Should fail: permission denied

# Verify service
sudo launchctl list | grep puregopher
echo "" | nc localhost 70
tail -f /Users/gopher/.gopher/server.log
```

### Updating the Application
```bash
# Stop service
sudo ./scripts/gopher-service.sh stop

# Copy updated files
sudo cp -R /path/to/updated/pure_gopher_ai /Users/gopher/pure_gopher_ai
sudo chown -R gopher:staff /Users/gopher/pure_gopher_ai

# Recompile as gopher user
sudo -u gopher -i bash -c 'cd ~/pure_gopher_ai && mix deps.get && mix compile'

# Restart service
sudo ./scripts/gopher-service.sh start
```

### Tor Integration
```bash
# Add to launchd plist EnvironmentVariables:
# <key>ONION_ADDRESS</key>
# <string>your-address.onion</string>
# <key>TOR_ENABLED</key>
# <string>true</string>
# <key>TOR_PORT</key>
# <string>7071</string>

# Or edit /Users/gopher/.zshrc:
export ONION_ADDRESS="your-address.onion"
export TOR_ENABLED=true
```

## Raspberry Pi 3B/3B+ Deployment (Nerves)

Run PureGopherAI as embedded firmware on a Raspberry Pi via Nerves. AI uses Google Gemini Flash API (cloud) since the Pi's 1GB RAM cannot run local models.

### Prerequisites

1. **Nerves bootstrap:** `mix archive.install hex nerves_bootstrap`
2. **Google Gemini API key:** Get from [Google AI Studio](https://aistudio.google.com/apikey)
3. **Static Tor binary** (for hidden service): `./scripts/build-tor-arm.sh`

### Build + Deploy Firmware

**Use `./scripts/deploy-pi.sh` for OTA updates** — it builds and deploys correctly.
Doing it by hand is error-prone because of four non-obvious traps (all handled by
the script):

1. **Build in dev, NOT prod.** `MIX_ENV=prod` fails `--warnings-as-errors` in the
   Bumblebee code (`model_registry.ex`). The default dev env is required.
2. **Force `GOPHER_PORT=70`.** dev defaults the gopher port to 7070, so the server
   refuses `:70` and the public tunnel serves nothing.
3. **`BURROW_TOKEN` must be set at build time.** `config/target.exs` bakes it with
   no default; without it `PureGopherAi.Tunnel` logs "No token configured" and
   never connects to the relay. Keep it in `.env`.
4. **Don't use `mix upload`** — it needs a TTY and hangs when scripted. Stream the
   `.fw` to the device's fwup subsystem, then `Nerves.Runtime.validate_firmware()`
   on the new boot or Nerves auto-reverts on the next reboot.

Credentials live in `.env` (`GEMINI_API_KEY`, `GEMINI_MODEL`, `BURROW_TOKEN`);
`.env` is NOT committed. WiFi is optional and baked at compile time
(`WIFI_SSID` / `WIFI_PSK`).

```bash
# OTA update (recommended) — builds, streams via fwup, reboots, validates
./scripts/deploy-pi.sh                 # or: ./scripts/deploy-pi.sh 192.168.1.2

# First deploy only: build then burn to an SD card inserted in the Mac
source .env && MIX_TARGET=rpi3 GOPHER_PORT=70 mix deps.get && mix firmware
mix burn

# Manual OTA equivalent of the script (if you can't use it)
source .env && MIX_TARGET=rpi3 GOPHER_PORT=70 mix firmware
cat _build/rpi3_dev/nerves/images/pure_gopher_ai.fw \
  | ssh -i ~/.ssh/id_ed25519 nerves@nerves.local -s fwup
# then, on the new boot: ssh nerves@nerves.local ->  Nerves.Runtime.validate_firmware()

# Provision data to Pi after first boot
scp -r priv/phlog/* nerves.local:/data/gopher/phlog/
scp ~/.gopher/gemini/cert.pem nerves.local:/data/gopher/gemini/
scp ~/.gopher/gemini/key.pem nerves.local:/data/gopher/gemini/
```

### Pi Directory Structure (Nerves)

```
/data/                     # Writable partition (persists across firmware updates)
├── gopher/
│   ├── data/              # DETS persistent data
│   ├── phlog/             # Blog posts
│   ├── docs/              # RAG documents (keyword search only)
│   ├── backups/           # Backups
│   ├── gemini/            # TLS certificates
│   │   ├── cert.pem
│   │   └── key.pem
│   ├── finger/            # Finger protocol data
│   ├── plugins/           # Plugin storage
│   └── blocklist.txt      # Custom blocklist
└── tor/
    ├── torrc              # Auto-generated by TorManager
    ├── hidden_service/    # Created by Tor
    │   ├── hostname       # .onion address (auto-discovered)
    │   └── private_key
    └── logs/
        └── tor.log
```

### Verification

```bash
# SSH into Pi
ssh nerves.local

# Check AI backend
iex> PureGopherAi.AiEngine.ai_backend()
:gemini_api

# Check Tor status
iex> PureGopherAi.TorManager.status()
%{status: :running, onion_address: "abc123.onion", ...}

# Test from another machine
echo "" | nc <pi-ip> 70                              # Gopher root menu
echo "ask What is Elixir?" | nc <pi-ip> 70           # AI query via Gemini
openssl s_client -connect <pi-ip>:1965               # Gemini protocol
torsocks sh -c 'echo "" | nc <onion-address> 70'     # Tor access
```

### Tor on Nerves

On Nerves, there is no system Tor daemon. `TorManager` (a GenServer) manages the entire lifecycle:

1. Writes `/data/tor/torrc` with hidden service config
2. Starts static Tor binary via `Port.open/2`
3. Monitors process, auto-restarts on crash
4. Polls for `.onion` hostname and updates app config

**Requires:** A statically compiled Tor binary for armv7l at `rootfs_overlay/usr/bin/tor`. Build it with:

```bash
./scripts/build-tor-arm.sh
# Produces: rootfs_overlay/usr/bin/tor (~5-8 MB static binary)
# Then rebuild + deploy firmware: ./scripts/deploy-pi.sh
```

### Pi-Specific Config (config/target.exs)

Automatically loaded when `MIX_TARGET=rpi3`. Key overrides:
- `ai_backend: :gemini_api` (cloud AI instead of local ML)
- `rag_embeddings_enabled: false` (keyword search only)
- `cache_max_entries: 100` (reduced from 1000)
- `conversation_max_messages: 5` (reduced from 10)
- All paths point to `/data/gopher/` (Nerves writable partition)
- Logger uses `RingLogger` (in-memory, no console on embedded)
- VintageNet for Ethernet DHCP + optional WiFi
