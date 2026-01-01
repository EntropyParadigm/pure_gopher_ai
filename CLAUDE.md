# PureGopherAI - Project Context

## Overview
A pure Elixir Gopher server (RFC 1436) with native AI inference via Bumblebee. Optimized for Apple Silicon with Metal GPU acceleration. Triple-stack: clearnet + Tor hidden service + Gemini protocol (TLS).

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
| `lib/pure_gopher_ai/input_sanitizer.ex` | Prompt injection defense, input sanitization |
| `lib/pure_gopher_ai/output_sanitizer.ex` | AI output sanitization, sensitive data redaction |
| `lib/pure_gopher_ai/request_validator.ex` | Request validation, size limits, pattern blocking |
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

## Notes
- First model load downloads from Hugging Face
- Nx.Serving provides automatic request batching
- All inference runs locally - no external API calls
- Tor listener only binds to localhost for security
- macOS allows port 70 without root; Linux requires setcap
- Gemini requires TLS certificates (self-signed OK)
- RAG auto-ingests documents from watch directory every 30s

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
