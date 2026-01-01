# PureGopherAI - Feature Implementation Tracker

## Overview
This document tracks the implementation status of all planned features.

---

## Phase 1: Core Server Features

### 1.1 gophermap Support
**Status:** 🟢 Complete
**Priority:** High
**Description:** Serve static content from configurable directory using standard gophermap format.

**Implementation:**
- [x] Create `Gophermap` module
- [x] Support standard gophermap format (type, display, selector, host, port)
- [x] Configurable content directory (`~/.gopher/` or custom via `content_dir`)
- [x] Auto-generate directory listings when no gophermap exists
- [x] Support for info lines, links, files, subdirectories
- [x] File type detection by extension
- [x] Directory traversal protection
- [x] Sample content in `priv/gopher/`

**Files created/modified:**
- `lib/pure_gopher_ai/gophermap.ex` (new)
- `lib/pure_gopher_ai/gopher_handler.ex` (updated)
- `config/config.exs` (added content_dir)
- `config/dev.exs` (uses priv/gopher)
- `priv/gopher/*` (sample content)

---

### 1.2 Rate Limiting
**Status:** 🟢 Complete
**Priority:** High
**Description:** Limit requests per IP to prevent abuse, especially important for Tor exposure.

**Implementation:**
- [x] Create `RateLimiter` GenServer with ETS
- [x] Track requests per IP with sliding window algorithm
- [x] Configurable limits (requests per window)
- [x] Configurable window size
- [x] Return Gopher error (Type 3) on rate limit exceeded
- [x] Automatic cleanup of old entries
- [x] Client IP extraction from socket

**Config options:**
- `rate_limit_enabled` - Enable/disable (default: true)
- `rate_limit_requests` - Max requests per window (default: 60)
- `rate_limit_window_ms` - Window size in ms (default: 60000)

**Files created/modified:**
- `lib/pure_gopher_ai/rate_limiter.ex` (new)
- `lib/pure_gopher_ai/application.ex` (added to supervisor)
- `lib/pure_gopher_ai/gopher_handler.ex` (rate limit check)
- `config/config.exs` (added rate limit options)

---

### 1.3 Conversation Memory
**Status:** 🟢 Complete
**Priority:** High
**Description:** Store chat history per session to enable contextual AI responses.

**Implementation:**
- [x] Create `ConversationStore` GenServer with ETS
- [x] Session ID generation (SHA256 hash of client IP)
- [x] Store last N messages per session (configurable)
- [x] TTL for session expiry with automatic cleanup
- [x] Pass conversation context to AI engine
- [x] New selector: `/chat` for conversational mode
- [x] `/clear` to reset conversation
- [x] Updated root menu with chat options

**Config options:**
- `conversation_max_messages` - Max messages per session (default: 10)
- `conversation_ttl_ms` - Session TTL in ms (default: 3600000 = 1 hour)

**Files created/modified:**
- `lib/pure_gopher_ai/conversation_store.ex` (new)
- `lib/pure_gopher_ai/ai_engine.ex` (added context support)
- `lib/pure_gopher_ai/gopher_handler.ex` (added /chat, /clear routes)
- `lib/pure_gopher_ai/application.ex` (added ConversationStore to supervisor)
- `config/config.exs` (added conversation options)

---

### 1.4 Streaming Responses
**Status:** 🟢 Complete
**Priority:** Medium
**Description:** Stream AI output as it generates for better UX with slow models.

**Implementation:**
- [x] Enable Bumblebee streaming mode (`stream: true`, `stream_done: true`)
- [x] Chunk responses over TCP as tokens are generated
- [x] Add `generate_stream/3` function with callback for real-time output
- [x] Fallback for non-streaming mode (configurable via `streaming_enabled`)
- [x] Collect streamed chunks for conversation history storage

**Config options:**
- `streaming_enabled` - Enable/disable streaming (default: true)

**Files modified:**
- `lib/pure_gopher_ai/ai_engine.ex` (streaming support)
- `lib/pure_gopher_ai/gopher_handler.ex` (socket streaming)
- `config/config.exs` (streaming_enabled option)

---

## Phase 2: AI Enhancements

### 2.1 Multiple Model Support
**Status:** 🟢 Complete
**Priority:** Medium
**Description:** Support multiple AI models with different selectors.

**Implementation:**
- [x] Model registry with lazy loading
- [x] DynamicSupervisor for model Nx.Servings
- [x] Selectors: `/ask-<model>`, `/chat-<model>`
- [x] Model listing page: `/models`
- [x] Lazy loading (load on first request)
- [x] Streaming support per model

**Models supported:**
- GPT-2 (default, fast) - 124M params
- GPT-2 Medium (balanced) - 355M params
- GPT-2 Large (quality) - 774M params
- (Llama/Mistral can be added with tokenizer config)

**Selectors:**
- `/models` - List all available models
- `/ask-gpt2`, `/ask-gpt2-medium`, `/ask-gpt2-large` - Model-specific queries
- `/chat-gpt2`, `/chat-gpt2-medium`, `/chat-gpt2-large` - Model-specific chat

**Files created/modified:**
- `lib/pure_gopher_ai/model_registry.ex` (new)
- `lib/pure_gopher_ai/gopher_handler.ex` (model routes)
- `lib/pure_gopher_ai/application.ex` (DynamicSupervisor)

---

### 2.2 System Prompts
**Status:** 🟢 Complete
**Priority:** Medium
**Description:** Configurable AI personality/behavior via system prompts.

**Implementation:**
- [x] Default system prompt in config (optional)
- [x] Prepend system prompts to AI queries
- [x] Multiple named personas with custom prompts
- [x] `/personas` selector to list available personas
- [x] `/persona-<name>` for persona-specific queries
- [x] `/chat-persona-<name>` for persona-specific chat
- [x] Streaming support for personas

**Default personas:**
- `helpful` - Helpful, accurate assistant
- `pirate` - Responds in pirate speak
- `haiku` - Responds only in haiku format
- `coder` - Programming expert

**Config options:**
- `system_prompt` - Default system prompt for all queries
- `personas` - Map of persona_id => {name, prompt}

**Files modified:**
- `lib/pure_gopher_ai/ai_engine.ex` (persona functions)
- `lib/pure_gopher_ai/gopher_handler.ex` (persona routes)
- `config/config.exs` (personas config)

---

### 2.3 Response Caching
**Status:** 🟢 Complete
**Priority:** Medium
**Description:** Cache repeated AI queries to reduce GPU load.

**Implementation:**
- [x] Create `ResponseCache` GenServer with ETS
- [x] Hash-based cache keys (SHA256 of query + model + context)
- [x] Configurable TTL with automatic cleanup
- [x] Cache hit/miss/write metrics with hit rate calculation
- [x] Max cache size with LRU eviction
- [x] Cache stats displayed in /about page
- [x] Only stateless queries cached (queries with context not cached)

**Config options:**
- `cache_enabled` - Enable/disable caching (default: true)
- `cache_ttl_ms` - Cache TTL in ms (default: 3600000 = 1 hour)
- `cache_max_entries` - Max entries before LRU eviction (default: 1000)

**Files created/modified:**
- `lib/pure_gopher_ai/response_cache.ex` (new)
- `lib/pure_gopher_ai/ai_engine.ex` (cache integration)
- `lib/pure_gopher_ai/gopher_handler.ex` (about page stats)
- `lib/pure_gopher_ai/application.ex` (supervisor)
- `config/config.exs` (cache options)

---

## Phase 3: Gopher Protocol Features

### 3.1 Search (Type 7)
**Status:** 🟢 Complete
**Priority:** Medium
**Description:** Implement Gopher search protocol for interactive queries.

**Implementation:**
- [x] Type 7 selector handling (`/search`)
- [x] Search input prompt
- [x] Search across gophermap content
- [x] Search across phlog entries
- [x] Full-text search with relevance ranking
- [x] Snippet extraction around matches
- [x] Parallel search across content types
- [x] Title boost in ranking

**Selectors:**
- `/search` - Search prompt (Type 7)
- `/search <query>` - Execute search

**Files created/modified:**
- `lib/pure_gopher_ai/search.ex` (new)
- `lib/pure_gopher_ai/gopher_handler.ex` (search routes)

---

### 3.2 Phlog Support
**Status:** 🟢 Complete
**Priority:** Low
**Description:** Gopher blog with dated entries.

**Implementation:**
- [x] Phlog directory structure (`phlog/YYYY/MM/DD-title.txt`)
- [x] Auto-generated index by date
- [x] RSS/Atom feed generation (`/phlog/feed`)
- [x] `/phlog` selector with pagination
- [x] Browse by year (`/phlog/year/<YYYY>`)
- [x] Browse by month (`/phlog/month/<YYYY>/<MM>`)
- [x] Individual entries (`/phlog/entry/<path>`)
- [x] Sample phlog content in `priv/phlog/`

**Config options:**
- `phlog_dir` - Phlog content directory (default: ~/.gopher/phlog)
- `phlog_entries_per_page` - Entries per page (default: 10)

**Selectors:**
- `/phlog` - Main phlog index
- `/phlog/page/<n>` - Paginated index
- `/phlog/feed` - Atom feed
- `/phlog/year/<YYYY>` - Entries by year
- `/phlog/month/<YYYY>/<MM>` - Entries by month
- `/phlog/entry/<path>` - Single entry

**Files created/modified:**
- `lib/pure_gopher_ai/phlog.ex` (new)
- `lib/pure_gopher_ai/gopher_handler.ex` (phlog routes)
- `config/config.exs` (phlog options)
- `config/dev.exs` (dev phlog dir)
- `priv/phlog/*` (sample content)

---

## Phase 4: Operations

### 4.1 Metrics/Telemetry
**Status:** 🟢 Complete
**Priority:** Medium
**Description:** Request counts, latency, model usage tracking.

**Implementation:**
- [x] Custom telemetry module with ETS storage
- [x] Track: requests, latency, errors
- [x] Per-selector type metrics (ask, chat, static)
- [x] Per-network (clearnet/tor) metrics
- [x] `/stats` selector for public metrics
- [x] Average and max latency tracking
- [x] Request rate calculation (requests/hour)
- [x] Error rate tracking
- [x] Daily automatic reset

**Metrics tracked:**
- Total requests, requests by network, requests by type
- Average/max latency
- Error count and rate
- Cache stats integration

**Files created/modified:**
- `lib/pure_gopher_ai/telemetry.ex` (new)
- `lib/pure_gopher_ai/gopher_handler.ex` (/stats route)
- `lib/pure_gopher_ai/application.ex` (supervisor)

---

### 4.2 Admin Gopherhole
**Status:** 🟢 Complete
**Priority:** Low
**Description:** Admin interface accessible via Gopher.

**Implementation:**
- [x] Auth via selector token (`/admin/<token>/...`)
- [x] View system stats (memory, processes, uptime)
- [x] View cache status and clear cache
- [x] View request metrics and reset
- [x] IP banning/unbanning
- [x] Clear all sessions
- [x] Secure token comparison

**Config options:**
- `admin_token` - Token for admin access (or `ADMIN_TOKEN` env var)

**Selectors:**
- `/admin/<token>` - Admin menu
- `/admin/<token>/clear-cache` - Clear response cache
- `/admin/<token>/clear-sessions` - Clear all sessions
- `/admin/<token>/reset-metrics` - Reset telemetry
- `/admin/<token>/bans` - View/manage banned IPs
- `/admin/<token>/ban <ip>` - Ban an IP
- `/admin/<token>/unban/<ip>` - Unban an IP

**Files created/modified:**
- `lib/pure_gopher_ai/admin.ex`
- `lib/pure_gopher_ai/gopher_handler.ex`

---

### 4.3 External Blocklist Integration
**Status:** 🟢 Complete
**Priority:** Medium
**Description:** Fetch and cache IP blocklists from external sources for abuse prevention.

**Implementation:**
- [x] GenServer for blocklist management
- [x] Support HTTP/HTTPS blocklist sources (FireHOL)
- [x] Support Gopher protocol blocklist sources (floodgap)
- [x] Full CIDR notation support with bitmask matching
- [x] Separate ETS tables for individual IPs and CIDR blocks
- [x] IPv4 and IPv6 address support
- [x] Configurable refresh interval (hourly by default)
- [x] Local blocklist file support (~/.gopher/blocklist.txt)
- [x] Integration with rate limiter
- [x] Blocklist stats in admin panel

**Blocklist Sources:**
- Floodgap responsible-bot list (gopher://gopher.floodgap.com/0/responsible-bot)
- FireHOL Level 1 (firehol_level1.netset)
- FireHOL Abusers 1d (firehol_abusers_1d.netset)
- StopForumSpam 7d (stopforumspam_7d.netset)

**Config options:**
- `blocklist_enabled` - Enable/disable blocklist (default: true)
- `blocklist_refresh_ms` - Refresh interval (default: 3600000 = 1 hour)
- `blocklist_file` - Local blocklist file path
- `blocklist_sources` - List of {name, url} tuples

**Files created/modified:**
- `lib/pure_gopher_ai/blocklist.ex` (new)
- `lib/pure_gopher_ai/rate_limiter.ex` (blocklist check integration)
- `lib/pure_gopher_ai/application.ex` (supervisor)
- `config/config.exs` (blocklist options)

---

## Phase 5: Advanced Features

### 5.1 RAG (Retrieval Augmented Generation)
**Status:** 🟢 Complete
**Priority:** Low
**Description:** Query your own documents for AI-enhanced answers.

**Implementation:**
- [x] Document store with chunking (ETS)
- [x] Text extraction (txt, md, pdf)
- [x] Vector embeddings with Bumblebee (sentence-transformers)
- [x] Semantic search with cosine similarity
- [x] Keyword search fallback
- [x] Context injection into AI prompts
- [x] File watcher for auto-ingestion
- [x] Admin ingest commands

**Selectors:**
- `/docs` - Document knowledge base menu
- `/docs/list` - List all ingested documents
- `/docs/ask <query>` - Query documents with AI
- `/docs/search <query>` - Search documents
- `/docs/view/<id>` - View document details
- `/admin/<token>/docs` - Admin document management
- `/admin/<token>/ingest <path>` - Ingest local file
- `/admin/<token>/ingest-url <url>` - Ingest from URL

**Config options:**
- `rag_enabled` - Enable RAG system (default: true)
- `rag_docs_dir` - Document directory (default: ~/.gopher/docs)
- `rag_chunk_size` - Words per chunk (default: 512)
- `rag_chunk_overlap` - Overlap between chunks (default: 50)
- `rag_embeddings_enabled` - Enable vector embeddings (default: true)
- `rag_embedding_model` - Bumblebee embedding model

**Files created/modified:**
- `lib/pure_gopher_ai/rag.ex` (new)
- `lib/pure_gopher_ai/rag/document_store.ex` (new)
- `lib/pure_gopher_ai/rag/embeddings.ex` (new)
- `lib/pure_gopher_ai/rag/file_watcher.ex` (new)
- `lib/pure_gopher_ai/gopher_handler.ex` (docs routes)
- `lib/pure_gopher_ai/application.ex` (supervisor)
- `config/config.exs` (RAG options)

---

### 5.2 Gemini Protocol Support
**Status:** 🟢 Complete
**Priority:** Low
**Description:** Dual Gopher + Gemini server.

**Implementation:**
- [x] Gemini protocol handler (TLS on port 1965)
- [x] Standard Gemini response codes (10, 20, 30, etc.)
- [x] Shared content with Gopher (AI, RAG, phlog)
- [x] Input prompts for queries
- [x] TLS certificate configuration
- [x] Rate limiting and blocklist integration

**Selectors:**
- `/` - Home page
- `/ask` - AI query (input prompt)
- `/docs` - Document knowledge base
- `/docs/ask` - Query documents
- `/phlog` - Blog entries
- `/about` - Server info
- `/stats` - Statistics

**Config options:**
- `gemini_enabled` - Enable Gemini server (default: false)
- `gemini_port` - Port number (default: 1965)
- `gemini_cert_file` - TLS certificate path
- `gemini_key_file` - TLS private key path

**Certificate generation:**
```bash
openssl req -x509 -newkey rsa:4096 -keyout key.pem -out cert.pem -days 365 -nodes
```

**Files created/modified:**
- `lib/pure_gopher_ai/gemini_handler.ex` (new)
- `lib/pure_gopher_ai/application.ex` (Gemini listener)
- `config/config.exs` (Gemini options)

---

### 5.3 ASCII Art Generation
**Status:** 🟢 Complete
**Priority:** Low
**Description:** Generate ASCII art from text.

**Implementation:**
- [x] Text-to-ASCII art with block font (7 rows)
- [x] Compact small font (3 rows)
- [x] Banner generation with decorative border
- [x] Support for letters, numbers, punctuation
- [x] `/art` menu selector
- [x] `/art/text`, `/art/small`, `/art/banner` routes

**Selectors:**
- `/art` - ASCII art menu
- `/art/text <text>` - Large block letters
- `/art/small <text>` - Compact letters
- `/art/banner <text>` - Text with border

**Files created/modified:**
- `lib/pure_gopher_ai/ascii_art.ex` (new)
- `lib/pure_gopher_ai/gopher_handler.ex` (art routes)

---

## Phase 6: AI Tools & Services

### 6.1 Summarization & Translation
**Status:** 🟢 Complete
**Priority:** Medium
**Description:** AI-powered content summarization and translation services.

**Implementation:**
- [x] Create `Summarizer` module
- [x] Phlog entry summarization (TL;DR)
- [x] RAG document summarization
- [x] Translation support (25+ languages)
- [x] Streaming output support
- [x] Routes for Gopher and Gemini protocols

**Selectors:**
- `/summary/phlog/<path>` - Summarize phlog entry
- `/summary/doc/<id>` - Summarize document
- `/translate` - Translation service menu
- `/translate/<lang>/phlog/<path>` - Translate phlog
- `/translate/<lang>/doc/<id>` - Translate document

**Supported languages:**
en, es, fr, de, it, pt, ja, ko, zh, ru, ar, hi, nl, pl, tr, vi, th, sv, da, fi, no, el, he, uk, cs

**Files created/modified:**
- `lib/pure_gopher_ai/summarizer.ex` (new)
- `lib/pure_gopher_ai/gopher_handler.ex` (routes)
- `lib/pure_gopher_ai/gemini_handler.ex` (routes)

---

### 6.2 Dynamic Content Generation
**Status:** 🟢 Complete
**Priority:** Medium
**Description:** AI-generated dynamic content and recommendations.

**Implementation:**
- [x] Daily digest generation from recent phlog entries
- [x] Topic discovery across all content
- [x] Content recommendations based on interests
- [x] Term explanations
- [x] Streaming output support

**Selectors:**
- `/digest` - AI daily digest of recent activity
- `/topics` - Discover themes in content
- `/discover <interest>` - Content recommendations
- `/explain <term>` - AI explanations

**Files modified:**
- `lib/pure_gopher_ai/summarizer.ex`
- `lib/pure_gopher_ai/gopher_handler.ex`
- `lib/pure_gopher_ai/gemini_handler.ex`

---

### 6.3 Gopher Proxy
**Status:** 🟢 Complete
**Priority:** Low
**Description:** Fetch and optionally summarize external Gopher content.

**Implementation:**
- [x] Create `GopherProxy` module
- [x] Fetch content from external Gopher servers
- [x] Parse gopher:// URLs
- [x] Timeout and size limits for safety
- [x] Optional AI summarization of fetched content
- [x] Routes for Gopher and Gemini protocols

**Selectors:**
- `/fetch` - Gopher proxy menu
- `/fetch <url>` - Fetch external content
- `/fetch-summary <url>` - Fetch and summarize

**Files created/modified:**
- `lib/pure_gopher_ai/gopher_proxy.ex` (new)
- `lib/pure_gopher_ai/gopher_handler.ex` (routes)
- `lib/pure_gopher_ai/gemini_handler.ex` (routes)

---

## Phase 7: Community & Utility Features

### 7.1 Guestbook
**Status:** 🟢 Complete
**Priority:** High
**Description:** Classic Gopher guestbook for visitor messages.

**Implementation:**
- [x] Create `Guestbook` GenServer with DETS persistent storage
- [x] `/guestbook` - View all entries (newest first)
- [x] `/guestbook/sign` - Sign the guestbook (Type 7 input)
- [x] Rate limiting per IP (5 minute cooldown)
- [x] Configurable max entries with auto-pruning
- [x] Entry format: Name | Message
- [x] Timestamps with human-readable dates
- [x] Admin moderation via `/admin/<token>/guestbook`

**Selectors:**
- `/guestbook` - View guestbook entries
- `/guestbook/sign` - Leave a message
- `/guestbook/page/<n>` - Paginated view

**Files created/modified:**
- `lib/pure_gopher_ai/guestbook.ex` (new)
- `lib/pure_gopher_ai/gopher_handler.ex` (routes)
- `lib/pure_gopher_ai/gemini_handler.ex` (routes)
- `lib/pure_gopher_ai/application.ex` (supervisor)
- `config/config.exs` (guestbook options)

---

### 7.2 Code Assistant
**Status:** 🟢 Complete
**Priority:** High
**Description:** AI-powered code generation and explanation.

**Implementation:**
- [x] Create `CodeAssistant` module with 24 programming languages
- [x] `/code` - Code assistant menu
- [x] `/code/generate` - Generate code (input: lang | description)
- [x] `/code/explain` - Explain code (input: code)
- [x] `/code/review` - Review code for issues (input: code)
- [x] `/code/convert` - Convert between languages (input: from | to | code)
- [x] `/code/fix` - Fix code based on error (input: error | code)
- [x] `/code/optimize` - Optimize for performance (input: code)
- [x] `/code/regex` - Generate regex from description
- [x] Streaming output for all AI operations
- [x] Preformatted blocks for Gemini output

**Supported Languages:**
Elixir, Python, JavaScript, TypeScript, Ruby, Go, Rust, C, C++, Java, Kotlin, Swift, PHP, Shell/Bash, SQL, HTML, CSS, Lua, Perl, R, Scala, Haskell, Clojure, Erlang

**Selectors:**
- `/code` - Code assistant menu
- `/code/generate` - Generate code snippet
- `/code/explain` - Explain code
- `/code/review` - Code review
- `/code/convert` - Convert between languages
- `/code/fix` - Fix code with error
- `/code/optimize` - Optimize code
- `/code/regex` - Generate regex
- `/code/languages` - List supported languages

**Files created/modified:**
- `lib/pure_gopher_ai/code_assistant.ex` (new)
- `lib/pure_gopher_ai/gopher_handler.ex` (routes)
- `lib/pure_gopher_ai/gemini_handler.ex` (routes)

---

### 7.3 Interactive Text Adventure
**Status:** 🟢 Complete
**Priority:** Medium
**Description:** AI-powered text adventure game with persistent state.

**Implementation:**
- [x] Create `Adventure` GenServer with ETS session storage
- [x] Session-based game state per IP (2 hour TTL)
- [x] AI-generated story and choices
- [x] `/adventure` - Start/continue game
- [x] `/adventure/new` - Start new game with genre selection
- [x] `/adventure/save` - Save game state (base64 encoded)
- [x] `/adventure/load` - Load saved game
- [x] 8 genre options: fantasy, sci-fi, mystery, horror, cyberpunk, western, pirate, survival
- [x] Inventory system (find items, 20 item limit)
- [x] Stats system (health, strength, intelligence, luck)
- [x] Health tracking with damage/healing detection
- [x] Game over detection
- [x] Streaming output for Gopher

**Selectors:**
- `/adventure` - Adventure menu (shows current game or start)
- `/adventure/new` - Genre selection
- `/adventure/new/<genre>` - Start new game in genre
- `/adventure/action` - Take action (input prompt)
- `/adventure/look` - View current scene
- `/adventure/inventory` - Check inventory
- `/adventure/stats` - View character stats
- `/adventure/save` - Get save code
- `/adventure/load` - Load from save code

**Files created/modified:**
- `lib/pure_gopher_ai/adventure.ex` (new)
- `lib/pure_gopher_ai/gopher_handler.ex` (routes)
- `lib/pure_gopher_ai/gemini_handler.ex` (routes)
- `lib/pure_gopher_ai/application.ex` (supervisor)

---

### 7.4 RSS/Atom Feed Aggregator
**Status:** 🟢 Complete
**Priority:** Medium
**Description:** Subscribe to and read external RSS/Atom feeds.

**Implementation:**
- [x] Create `FeedAggregator` GenServer with ETS storage
- [x] Feed parsing (RSS 2.0, Atom)
- [x] Configurable feed list in config.exs
- [x] Auto-refresh every 30 minutes
- [x] `/feeds` - List subscribed feeds
- [x] `/feeds/<id>` - View feed entries
- [x] `/feeds/<id>/entry/<entry_id>` - View single entry
- [x] `/feeds/digest` - AI-summarized digest of all feeds
- [x] `/feeds/opml` - OPML export
- [x] `/feeds/stats` - Feed statistics
- [x] Date parsing (ISO 8601, RFC 2822)
- [x] HTML entity unescaping

**Selectors:**
- `/feeds` - Feed list
- `/feeds/<id>` - View feed entries
- `/feeds/<id>/entry/<entry_id>` - View entry
- `/feeds/digest` - AI digest of all feeds
- `/feeds/opml` - Export as OPML
- `/feeds/stats` - Feed statistics

**Files created/modified:**
- `lib/pure_gopher_ai/feed_aggregator.ex` (new)
- `lib/pure_gopher_ai/gopher_handler.ex` (routes)
- `lib/pure_gopher_ai/gemini_handler.ex` (routes)
- `lib/pure_gopher_ai/application.ex` (supervisor)
- `config/config.exs` (rss_feeds config)

---

### 7.5 Weather Service
**Status:** 🟢 Complete
**Priority:** Low
**Description:** Weather information formatted for Gopher/Gemini.

**Implementation:**
- [x] Create `Weather` module using Open-Meteo API (free, no API key)
- [x] Geocoding API for location search
- [x] `/weather` - Weather input prompt
- [x] `/weather <location>` - Get current weather
- [x] `/weather/forecast <location>` - 5-day forecast
- [x] ASCII weather icons for all conditions
- [x] Weather code descriptions with emoji
- [x] Temperature, humidity, wind speed/direction
- [x] AI-enhanced weather descriptions (optional)

**Selectors:**
- `/weather` - Weather input prompt
- `/weather <location>` - Current weather
- `/weather/forecast <location>` - 5-day forecast

**Files created/modified:**
- `lib/pure_gopher_ai/weather.ex` (new)
- `lib/pure_gopher_ai/gopher_handler.ex` (routes)
- `lib/pure_gopher_ai/gemini_handler.ex` (routes)

---

### 7.6 Fortune/Quote Service
**Status:** 🟢 Complete
**Priority:** Low
**Description:** Random fortunes and quotes with AI-enhanced interpretations.

**Implementation:**
- [x] Create `Fortune` GenServer module
- [x] Curated quote database with 70+ quotes
- [x] Multiple categories: wisdom, programming, funny, philosophy, motivation, unix
- [x] `/fortune` - Main menu with categories
- [x] `/fortune/random` - Random quote from any category
- [x] `/fortune/today` - Quote of the day (consistent per day)
- [x] `/fortune/cookie` - Fortune cookie with lucky numbers
- [x] `/fortune/category/<id>` - Category-specific quotes
- [x] `/fortune/interpret` - AI oracle-style interpretation
- [x] `/fortune/search` - Search quotes by keyword
- [x] ASCII art fortune cookie display
- [x] Gemini protocol support

**Quote Categories:**
- `wisdom` - Ancient Wisdom (philosophers, sages)
- `programming` - Programming Wisdom (software development)
- `funny` - Humorous Quotes
- `philosophy` - Philosophical Thoughts
- `motivation` - Motivational Quotes
- `unix` - Unix Fortune file style

**Files created/modified:**
- `lib/pure_gopher_ai/fortune.ex` (new)
- `lib/pure_gopher_ai/gopher_handler.ex` (routes, handlers)
- `lib/pure_gopher_ai/gemini_handler.ex` (routes, handlers)
- `lib/pure_gopher_ai/application.ex` (supervisor)

---

### 7.7 Link Directory
**Status:** 🟢 Complete
**Priority:** Medium
**Description:** Curated directory of Gopher/Gemini links.

**Implementation:**
- [x] Create `LinkDirectory` GenServer module with DETS storage
- [x] `/links` - Browse categories with link counts
- [x] `/links/category/<id>` - Links in category
- [x] `/links/submit` - User link submission
- [x] `/links/search` - Search links by keyword
- [x] Admin approval workflow (pending table)
- [x] AI-generated descriptions support
- [x] 12 seed links to well-known servers
- [x] Gemini protocol support

**Categories:**
- `gopher` - Gopher Servers
- `gemini` - Gemini Capsules
- `tech` - Technology
- `retro` - Retro Computing
- `programming` - Programming
- `art` - ASCII Art & Culture
- `writing` - Writing & Literature
- `games` - Games & Fun
- `misc` - Miscellaneous

**Files created/modified:**
- `lib/pure_gopher_ai/link_directory.ex` (new)
- `lib/pure_gopher_ai/gopher_handler.ex` (routes, handlers)
- `lib/pure_gopher_ai/gemini_handler.ex` (routes, handlers)
- `lib/pure_gopher_ai/application.ex` (supervisor)

---

### 7.8 Bulletin Board
**Status:** 🟢 Complete
**Priority:** Medium
**Description:** Simple message board for discussions.

**Implementation:**
- [x] Create `BulletinBoard` GenServer with DETS persistent storage
- [x] `/board` - List all boards with thread counts
- [x] `/board/<id>` - View threads in a board
- [x] `/board/<id>/new` - Create new thread
- [x] `/board/<id>/thread/<tid>` - View thread with replies
- [x] `/board/<id>/reply/<tid>` - Reply to thread
- [x] `/board/recent` - Recent posts across all boards
- [x] Rate limiting per IP
- [x] Input sanitization (HTML stripping)
- [x] Post pruning (max 500 posts per board)
- [x] Basic moderation (admin delete)

**Default Boards:**
- General Discussion, Tech Talk, Gopher Protocol
- Gemini Protocol, Retro Computing, Creative Corner, Help & Support

**Selectors:**
- `/board` - Board index
- `/board/<id>` - View board threads
- `/board/<id>/page/<n>` - Paginated threads
- `/board/<id>/new` - New thread prompt
- `/board/<id>/thread/<tid>` - View thread
- `/board/<id>/reply/<tid>` - Reply prompt
- `/board/recent` - Recent activity

**Files created/modified:**
- `lib/pure_gopher_ai/bulletin_board.ex` (new)
- `lib/pure_gopher_ai/gopher_handler.ex` (board routes)
- `lib/pure_gopher_ai/gemini_handler.ex` (board routes)
- `lib/pure_gopher_ai/application.ex` (supervisor)

---

### 7.9 Finger Protocol Support
**Status:** 🟢 Complete
**Priority:** Low
**Description:** Classic finger protocol (RFC 1288) support.

**Implementation:**
- [x] Create `FingerHandler` for ThousandIsland
- [x] Port 79 listener (7979 in dev)
- [x] `.plan` file serving from user directories
- [x] Server info display (when no username)
- [x] User info with .plan file content
- [x] `/W` verbose mode support
- [x] Rate limiting integration
- [x] ASCII art decorated output
- [x] Sample .plan files (admin, gopher)

**Config:**
- `finger_enabled` - Enable finger protocol (default: false)
- `finger_port` - Port (default: 79, dev uses 7979)
- `finger_plan_dir` - User .plan directory

**Files created/modified:**
- `lib/pure_gopher_ai/finger_handler.ex` (new)
- `lib/pure_gopher_ai/application.ex` (finger listener)
- `config/config.exs` (finger options)
- `config/dev.exs` (dev finger options)
- `priv/finger/*.plan` (sample files)

---

### 7.10 Health/Status API
**Status:** 🟢 Complete
**Priority:** High
**Description:** Health checks and metrics endpoints.

**Implementation:**
- [x] Create `HealthCheck` module
- [x] `/health` - Full health status with system metrics
- [x] `/health/live` - Liveness probe (simple OK check)
- [x] `/health/ready` - Readiness probe (component checks)
- [x] `/health/json` - JSON formatted status
- [x] Uptime tracking with formatted display
- [x] Memory metrics (total, processes, atoms, binary, ETS)
- [x] Process and port count metrics
- [x] Component status checks (AI, cache, RAG, etc.)
- [x] Kubernetes/Docker compatible probes

**Selectors (Gopher + Gemini):**
- `/health` - Full health status page
- `/health/live` - Simple liveness check ("OK")
- `/health/ready` - Readiness check with component status
- `/health/json` - JSON formatted health status

**Files created/modified:**
- `lib/pure_gopher_ai/health_check.ex` (new)
- `lib/pure_gopher_ai/gopher_handler.ex` (health routes)
- `lib/pure_gopher_ai/gemini_handler.ex` (health routes)
- `lib/pure_gopher_ai/application.ex` (start time tracking)

---

## Phase 8: Security Hardening

### 8.1 Input Sanitization & Prompt Injection Defense
**Status:** 🟢 Complete
**Priority:** High
**Description:** Comprehensive input sanitization and prompt injection protection.

**Implementation:**
- [x] Create `InputSanitizer` module
- [x] Prompt injection pattern detection (instruction override, role manipulation, jailbreaks)
- [x] Control character and null byte removal
- [x] Unicode normalization (prevents homoglyph attacks)
- [x] Gopher protocol escape character handling
- [x] Gemini protocol escape handling
- [x] Configurable max length limits

**Injection Patterns Detected:**
- Instruction override attempts ("ignore previous instructions")
- Role manipulation ("you are now", "pretend to be")
- System prompt injection (`[SYSTEM]`, `<<SYS>>`, etc.)
- Template/variable injection (`{{}}`, `${}`)
- Jailbreak keywords (DAN mode, developer mode)

**Files created/modified:**
- `lib/pure_gopher_ai/input_sanitizer.ex` (new)
- `lib/pure_gopher_ai/gopher_handler.ex` (integration)
- `lib/pure_gopher_ai/gemini_handler.ex` (integration)

---

### 8.2 Request Validation
**Status:** 🟢 Complete
**Priority:** High
**Description:** Validate all incoming requests for size, complexity, and malicious patterns.

**Implementation:**
- [x] Create `RequestValidator` module
- [x] Selector/path length limits
- [x] Query length limits
- [x] Blocked pattern detection (path traversal, command injection)
- [x] Special character ratio limits
- [x] Unicode complexity limits
- [x] Path traversal prevention

**Files created/modified:**
- `lib/pure_gopher_ai/request_validator.ex` (new)
- `lib/pure_gopher_ai/gopher_handler.ex` (integration)

---

### 8.3 AI Engine Security
**Status:** 🟢 Complete
**Priority:** High
**Description:** Secure AI generation with prompt sandboxing.

**Implementation:**
- [x] Prompt sandboxing with `<user_input>` delimiters
- [x] Defensive instructions to ignore override attempts
- [x] `generate_safe/2` function with injection detection
- [x] `generate_stream_safe/3` for streaming with protection
- [x] Automatic input sanitization before prompt construction

**Files modified:**
- `lib/pure_gopher_ai/ai_engine.ex`

---

### 8.4 Output Sanitization
**Status:** 🟢 Complete
**Priority:** Medium
**Description:** Sanitize AI outputs to prevent sensitive data leakage.

**Implementation:**
- [x] Create `OutputSanitizer` module
- [x] API key redaction (OpenAI, Anthropic, AWS, GitHub)
- [x] Password and secret pattern redaction
- [x] System prompt leakage detection
- [x] Email address redaction
- [x] Private IP address redaction
- [x] Analysis function for monitoring

**Files created/modified:**
- `lib/pure_gopher_ai/output_sanitizer.ex` (new)
- `lib/pure_gopher_ai/gopher_handler.ex` (integration)

---

### 8.5 Abuse Detection & Auto-Ban
**Status:** 🟢 Complete
**Priority:** High
**Description:** Detect abuse patterns and automatically ban repeat offenders.

**Implementation:**
- [x] Violation tracking per IP in dedicated ETS table
- [x] Burst detection (>20 requests in 5 seconds)
- [x] Auto-ban after configurable violation threshold (default: 5)
- [x] `check_abuse/1` for pattern detection
- [x] `get_abuse_stats/1` for monitoring
- [x] Automatic cleanup of old abuse records (1 hour TTL)

**Config options:**
- `rate_limit_auto_ban` - Enable auto-ban (default: true)
- `rate_limit_ban_threshold` - Violations before ban (default: 5)

**Files modified:**
- `lib/pure_gopher_ai/rate_limiter.ex`
- `lib/pure_gopher_ai/gopher_handler.ex`

---

## Implementation Log

| Date | Feature | Status | Commit |
|------|---------|--------|--------|
| 2025-01-01 | gophermap Support | Complete | 4d9a795 |
| 2025-01-01 | Rate Limiting | Complete | (pending) |
| 2025-01-01 | Conversation Memory | Complete | c250c19 |
| 2025-01-01 | Streaming Responses | Complete | e9fff3b |
| 2025-01-01 | Multiple Model Support | Complete | 4f64be9 |
| 2025-01-01 | System Prompts / Personas | Complete | 27170b6 |
| 2025-01-01 | Response Caching | Complete | 1b4767c |
| 2025-01-01 | Metrics/Telemetry | Complete | (pending) |
| 2025-12-31 | Phlog Support | Complete | 8998365 |
| 2025-12-31 | Search (Type 7) | Complete | 35d915b |
| 2025-12-31 | ASCII Art Generation | Complete | 1e8809d |
| 2025-12-31 | Admin Gopherhole | Complete | 1217bca |
| 2025-12-31 | External Blocklist (basic) | Complete | c024a95 |
| 2025-12-31 | Blocklist + Floodgap + CIDR | Complete | a08f73f |
| 2025-12-31 | RAG (Retrieval Augmented Generation) | Complete | a4ac1b4 |
| 2025-12-31 | Gemini Protocol Support | Complete | 22c09ed |
| 2025-12-31 | Summarizer + GopherProxy modules | Complete | 1a1c530 |
| 2025-12-31 | AI Tools routes (Gopher) | Complete | a91a814 |
| 2025-12-31 | AI Tools routes (Gemini) | Complete | 8bed5e0 |
| 2025-12-31 | Guestbook | Complete | c884591 |
| 2025-12-31 | Code Assistant | Complete | e1f7309 |
| 2025-12-31 | Interactive Text Adventure | Complete | 460b2d3 |
| 2025-12-31 | RSS/Atom Feed Aggregator | Complete | 860c18c |
| 2025-12-31 | Weather Service | Complete | 7269e06 |
| 2025-12-31 | Fortune/Quote Service | Complete | 60aa632 |
| 2025-12-31 | Link Directory | Complete | 39e1f85 |
| 2025-12-31 | Bulletin Board | Complete | 0a8c90b |
| 2025-12-31 | Finger Protocol | Complete | b20defc |
| 2025-12-31 | Health/Status API | Complete | d766273 |
| 2025-12-31 | Input Sanitization & Prompt Injection Defense | Complete | f0d4029 |
| 2025-12-31 | Gopher/Gemini Escape Handling | Complete | ec58798 |
| 2025-12-31 | Request Validation | Complete | be9da52 |
| 2025-12-31 | AI Engine Prompt Sandboxing | Complete | 541d215 |
| 2025-12-31 | Output Sanitization | Complete | 05a5d2c |
| 2025-12-31 | Abuse Detection & Auto-Ban | Complete | 6f72496 |
| 2025-12-31 | Security Module Integration | Complete | 12bdf68 |
| 2025-12-31 | Pastebin / Text Sharing | Complete | (pending) |
| 2025-12-31 | Polls / Voting System | Complete | (pending) |
| 2025-12-31 | Phlog Comments | Complete | (pending) |
| 2025-12-31 | User Profiles / Homepages | Complete | (pending) |
| 2025-12-31 | Calendar / Events | Complete | (pending) |
| 2025-12-31 | URL Shortener | Complete | (pending) |

---

## Phase 9: Enhanced Community Features

### 9.1 Pastebin / Text Sharing
**Status:** 🟢 Complete
**Priority:** Medium
**Description:** Simple pastebin for sharing text snippets via Gopher.

**Implementation:**
- [x] Create `Pastebin` GenServer with DETS persistent storage
- [x] `/paste` - Pastebin menu
- [x] `/paste/new` - Create new paste (Type 7 input)
- [x] `/paste/recent` - List recent pastes
- [x] `/paste/<id>` - View paste with metadata
- [x] `/paste/raw/<id>` - Raw paste content only
- [x] Optional titles and syntax hints
- [x] Automatic expiration (1 week default)
- [x] View count tracking
- [x] Unlisted paste option
- [x] Rate limiting per IP
- [x] Automatic cleanup of expired pastes

**Supported Syntax Types:**
text, elixir, python, javascript, ruby, go, rust, c, cpp, java, html, css, sql, bash, shell, markdown, json, xml, yaml

**Selectors:**
- `/paste` - Pastebin menu
- `/paste/new` - Create new paste
- `/paste/recent` - Recent pastes
- `/paste/<id>` - View paste
- `/paste/raw/<id>` - Raw paste content

**Files created/modified:**
- `lib/pure_gopher_ai/pastebin.ex` (new)
- `lib/pure_gopher_ai/gopher_handler.ex` (paste routes)
- `lib/pure_gopher_ai/application.ex` (supervisor)

---

### 9.2 Polls / Voting System
**Status:** 🟢 Complete
**Priority:** Medium
**Description:** Simple polling/voting system for community engagement.

**Implementation:**
- [x] Create `Polls` GenServer with DETS persistent storage
- [x] `/polls` - Polls menu
- [x] `/polls/new` - Create new poll (Type 7 input)
- [x] `/polls/active` - List active polls
- [x] `/polls/closed` - List closed polls
- [x] `/polls/<id>` - View poll with results
- [x] `/polls/vote/<id>/<option>` - Vote on poll
- [x] IP-based duplicate vote prevention (hashed for privacy)
- [x] Automatic expiration (1 week default)
- [x] Multiple option support (2-10 options)
- [x] Vote counts and percentages display
- [x] Admin close/delete functionality
- [x] Question and option length limits

**Selectors:**
- `/polls` - Polls menu
- `/polls/new` - Create new poll
- `/polls/active` - Active polls
- `/polls/closed` - Closed polls
- `/polls/<id>` - View poll and results
- `/polls/vote/<id>/<option_index>` - Cast vote

**Files created/modified:**
- `lib/pure_gopher_ai/polls.ex` (new)
- `lib/pure_gopher_ai/gopher_handler.ex` (poll routes)
- `lib/pure_gopher_ai/application.ex` (supervisor)

---

### 9.3 Phlog Comments
**Status:** 🟢 Complete
**Priority:** Medium
**Description:** Comment system for phlog (blog) entries.

**Implementation:**
- [x] Create `PhlogComments` GenServer with DETS persistent storage
- [x] `/phlog/comments/<path>` - View comments for an entry
- [x] `/phlog/comments/<path>/comment` - Add comment (Type 7 input)
- [x] `/phlog/comments/recent` - Recent comments across all entries
- [x] Rate limiting per IP (1 minute cooldown)
- [x] Author name and message input (Name | Message format)
- [x] Max 100 comments per entry
- [x] Input sanitization (HTML stripping, control char removal)
- [x] Admin delete functionality
- [x] Comment count display on phlog entries

**Selectors:**
- `/phlog/comments/<path>` - View comments for entry
- `/phlog/comments/<path>/comment` - Add comment
- `/phlog/comments/recent` - Recent comments

**Files created/modified:**
- `lib/pure_gopher_ai/phlog_comments.ex` (new)
- `lib/pure_gopher_ai/gopher_handler.ex` (comment routes)
- `lib/pure_gopher_ai/application.ex` (supervisor)

---

### 9.4 User Profiles / Homepages
**Status:** 🟢 Complete (Updated: Passphrase Auth)
**Priority:** Medium
**Description:** Personal homepage system for community members with passphrase-based authentication.

**Implementation:**
- [x] Create `UserProfiles` GenServer with DETS persistent storage
- [x] `/users` - User profiles menu with stats
- [x] `/users/create` - Create profile with passphrase (format: username:passphrase)
- [x] `/users/list` - Browse all profiles (paginated)
- [x] `/users/search` - Search by username or interests
- [x] `/users/~username` - View user's homepage
- [x] Profile includes bio, links, interests
- [x] Username validation (3-20 chars, alphanumeric + underscore)
- [x] **Passphrase-based authentication** (PBKDF2 with 100k iterations)
- [x] Passphrase minimum 8 characters
- [x] Timing-safe comparison for password verification
- [x] Brute force protection (5 attempts per minute per IP)
- [x] Rate limiting (1 profile per IP per day)
- [x] View count tracking
- [x] Admin delete functionality

**Authentication:**
- Passphrase is required when creating profile
- Passphrase is required for editing profile, writing phlogs, sending messages, managing bookmarks
- Works correctly over Tor, VPN, and NAT (no IP-based ownership)
- Never stored in plaintext - only salted hash

**Selectors:**
- `/users` - User profiles menu
- `/users/create` - Create profile (input: username:passphrase)
- `/users/list` - Browse all users
- `/users/list/page/<n>` - Paginated user list
- `/users/search` - Search users
- `/users/~<username>` - View user homepage

**Files created/modified:**
- `lib/pure_gopher_ai/user_profiles.ex` (passphrase auth)
- `lib/pure_gopher_ai/gopher_handler.ex` (user routes)
- `lib/pure_gopher_ai/application.ex` (supervisor)

---

### 9.4.1 User Phlog (User Blog Posts)
**Status:** 🟢 Complete
**Priority:** Medium
**Description:** Allow registered users to write their own blog posts.

**Implementation:**
- [x] Create `UserPhlog` GenServer with DETS persistent storage
- [x] Create `ContentModerator` module for AI safety checks
- [x] `/phlog/users` - List all users with phlogs
- [x] `/phlog/recent` - Recent posts across all users
- [x] `/phlog/user/<username>` - List user's posts
- [x] `/phlog/user/<username>/<post_id>` - View single post
- [x] `/phlog/user/<username>/write` - Write new post (requires passphrase)
- [x] `/phlog/user/<username>/edit/<post_id>` - Edit post (requires passphrase)
- [x] `/phlog/user/<username>/delete/<post_id>` - Delete post (requires passphrase)
- [x] Passphrase authentication required for all write operations
- [x] AI content moderation (blocks only highly illegal content)
- [x] Rate limiting (1 post per hour)
- [x] Content limits: title 100 chars, body 10,000 chars
- [x] Maximum 100 posts per user
- [x] View count tracking

**Content Moderation:**
- AI-powered check for highly illegal content (CSAM, terrorism, violence instructions)
- "Fail open" approach - allows content if AI check fails
- Does NOT moderate opinions, politics, legal adult content
- Quick pattern check + AI classification

**Selectors:**
- `/phlog/users` - List phlog authors
- `/phlog/recent` - Recent user posts
- `/phlog/user/<username>` - User's phlog
- `/phlog/user/<username>/<post_id>` - View post
- `/phlog/user/<username>/write` - Write post (input: passphrase|title|body)
- `/phlog/user/<username>/edit/<post_id>` - Edit post
- `/phlog/user/<username>/delete/<post_id>` - Delete post

**Files created/modified:**
- `lib/pure_gopher_ai/user_phlog.ex` (new)
- `lib/pure_gopher_ai/content_moderator.ex` (new)
- `lib/pure_gopher_ai/gopher_handler.ex` (phlog routes)
- `lib/pure_gopher_ai/application.ex` (supervisor)
- `lib/pure_gopher_ai/sitemap.ex` (new selectors)

---

### 9.5 Calendar / Events
**Status:** 🟢 Complete
**Priority:** Medium
**Description:** Community event calendar for meetups, deadlines, and announcements.

**Implementation:**
- [x] Create `Calendar` GenServer with DETS persistent storage
- [x] `/calendar` - Calendar menu with stats
- [x] `/calendar/create` - Create event (Type 7 input)
- [x] `/calendar/upcoming` - List upcoming events
- [x] `/calendar/month/YYYY/MM` - View events by month with navigation
- [x] `/calendar/date/YYYY-MM-DD` - View events on specific date
- [x] `/calendar/event/<id>` - View event details
- [x] Event fields: title, date, time (optional), description, location
- [x] Rate limiting (5 min cooldown per IP)
- [x] Date validation (YYYY-MM-DD format)
- [x] Admin delete functionality

**Selectors:**
- `/calendar` - Calendar menu
- `/calendar/create` - Create event
- `/calendar/upcoming` - Upcoming events
- `/calendar/month/YYYY/MM` - Month view
- `/calendar/date/YYYY-MM-DD` - Date view
- `/calendar/event/<id>` - Event details

**Files created/modified:**
- `lib/pure_gopher_ai/calendar.ex` (new)
- `lib/pure_gopher_ai/gopher_handler.ex` (calendar routes)
- `lib/pure_gopher_ai/application.ex` (supervisor)

---

### 9.6 URL Shortener
**Status:** 🟢 Complete
**Priority:** Medium
**Description:** Simple URL shortener for sharing links.

**Implementation:**
- [x] Create `UrlShortener` GenServer with DETS persistent storage
- [x] `/short` - URL shortener menu with stats
- [x] `/short/create` - Create short URL (Type 7 input)
- [x] `/short/recent` - List recent short URLs
- [x] `/short/info/<code>` - View link info and stats
- [x] `/short/<code>` - Redirect to original URL
- [x] Support for http, https, gopher, gemini URLs
- [x] Click tracking
- [x] Rate limiting (1 min cooldown per IP)
- [x] 6-character short codes

**Selectors:**
- `/short` - URL shortener menu
- `/short/create` - Create short URL
- `/short/recent` - Recent short URLs
- `/short/info/<code>` - Link info
- `/short/<code>` - Redirect

**Files created/modified:**
- `lib/pure_gopher_ai/url_shortener.ex` (new)
- `lib/pure_gopher_ai/gopher_handler.ex` (short routes)
- `lib/pure_gopher_ai/application.ex` (supervisor)

---

### 9.7 Quick Utilities
**Status:** 🟢 Complete
**Priority:** Medium
**Description:** Handy tools and fun utilities for the Gopher community.

**Implementation:**
- [x] Create `Utilities` module with pure functions
- [x] `/utils` - Utilities menu
- [x] `/utils/dice` - Dice roller (NdM format: 2d6, 1d20+5)
- [x] `/utils/8ball` - Magic 8-Ball fortune teller
- [x] `/utils/coin` - Coin flip (heads/tails)
- [x] `/utils/random` - Random number generator (range input)
- [x] `/utils/pick` - Random item picker (comma-separated list)
- [x] `/utils/uuid` - UUID v4 generator
- [x] `/utils/password` - Random password generator (8-64 chars)
- [x] `/utils/hash` - Hash calculator (MD5, SHA1, SHA256, SHA512)
- [x] `/utils/base64/encode` - Base64 encoder
- [x] `/utils/base64/decode` - Base64 decoder
- [x] `/utils/rot13` - ROT13 cipher
- [x] `/utils/timestamp` - Unix timestamp to date converter
- [x] `/utils/now` - Current timestamp display
- [x] `/utils/count` - Text counter (chars, words, lines)

**Utilities Included:**
- Dice roller with modifier support (e.g., 2d6+5, 3d10-2)
- Magic 8-Ball with 20 classic responses
- Coin flip with visual display
- Random number in custom range
- Random picker from comma-separated list
- UUID v4 generation
- Secure password generation (8-64 chars, mixed case + symbols)
- Multiple hash algorithms
- Base64 encoding/decoding
- ROT13 cipher (self-inverse)
- Unix timestamp conversion
- Text statistics (characters, words, lines)

**Selectors:**
- `/utils` - Utilities menu
- `/utils/dice` - Roll dice
- `/utils/8ball` - Magic 8-Ball
- `/utils/coin` - Flip coin
- `/utils/random` - Random number
- `/utils/pick` - Random picker
- `/utils/uuid` - Generate UUID
- `/utils/password` - Generate password (default 16)
- `/utils/password/<length>` - Generate password with length
- `/utils/hash` - Calculate hash
- `/utils/base64/encode` - Base64 encode
- `/utils/base64/decode` - Base64 decode
- `/utils/rot13` - ROT13 cipher
- `/utils/timestamp` - Convert timestamp
- `/utils/now` - Current time
- `/utils/count` - Count text

**Files created/modified:**
- `lib/pure_gopher_ai/utilities.ex` (new)
- `lib/pure_gopher_ai/gopher_handler.ex` (utils routes)

---

### 9.8 Sitemap / Full Index
**Status:** 🟢 Complete
**Priority:** Medium
**Description:** Complete index of all server endpoints for navigation and discovery.

**Implementation:**
- [x] Create `Sitemap` module with endpoint registry
- [x] `/sitemap` - Full sitemap with categories
- [x] `/sitemap/category/<name>` - Category-specific endpoints
- [x] `/sitemap/search` - Search endpoints
- [x] `/sitemap/text` - Plain text version
- [x] Statistics (total endpoints, menus, documents, queries)
- [x] Organized by category (AI Services, AI Tools, Content, Community, Utilities, Server)
- [x] Type indicators (menu, document, query)

**Features:**
- Complete listing of 50+ endpoints
- 6 categories for easy navigation
- Search functionality across descriptions and selectors
- Statistics display
- Plain text export

**Selectors:**
- `/sitemap` - Full sitemap menu
- `/sitemap/category/<name>` - Browse category
- `/sitemap/search` - Search endpoints
- `/sitemap/text` - Plain text version

**Files created/modified:**
- `lib/pure_gopher_ai/sitemap.ex` (new)
- `lib/pure_gopher_ai/gopher_handler.ex` (sitemap routes)

---

### 9.9 Internal Messaging / Mailbox
**Status:** 🟢 Complete
**Priority:** Medium
**Description:** Private messaging system for registered users.

**Implementation:**
- [x] Create `Mailbox` GenServer with DETS persistent storage
- [x] `/mail` - Mailbox menu with stats
- [x] `/mail/login` - Login with username
- [x] `/mail/inbox/<username>` - View inbox messages
- [x] `/mail/sent/<username>` - View sent messages
- [x] `/mail/read/<username>/<id>` - Read message (marks as read)
- [x] `/mail/compose/<username>` - Compose new message
- [x] `/mail/send/<from>/<to>` - Send message
- [x] `/mail/delete/<username>/<id>` - Delete message
- [x] Unread message tracking with indicators
- [x] Recipient must have user profile
- [x] Rate limiting (1 min between messages)
- [x] Message expiration (30 days)
- [x] 100 message inbox limit per user

**Selectors:**
- `/mail` - Mailbox menu
- `/mail/login` - Login prompt
- `/mail/inbox/<username>` - Inbox
- `/mail/sent/<username>` - Sent messages
- `/mail/read/<username>/<id>` - Read message
- `/mail/compose/<username>` - Compose
- `/mail/delete/<username>/<id>` - Delete

**Files created/modified:**
- `lib/pure_gopher_ai/mailbox.ex` (new)
- `lib/pure_gopher_ai/gopher_handler.ex` (mail routes)
- `lib/pure_gopher_ai/application.ex` (supervisor)
- `lib/pure_gopher_ai/sitemap.ex` (updated)

---

### 9.10 Trivia / Quiz Game
**Status:** 🟢 Complete
**Priority:** Medium
**Description:** Interactive trivia quiz game with categories and leaderboard.

**Implementation:**
- [x] Create `Trivia` GenServer with DETS for leaderboard
- [x] 25 questions across 5 categories
- [x] `/trivia` - Main trivia menu
- [x] `/trivia/play` - Random question from all categories
- [x] `/trivia/play/<category>` - Question from specific category
- [x] `/trivia/answer/<id>/<answer>` - Submit answer
- [x] `/trivia/score` - View current session score
- [x] `/trivia/reset` - Reset session score
- [x] `/trivia/leaderboard` - High scores
- [x] `/trivia/save/<nickname>` - Save score to leaderboard
- [x] Session-based scoring with ETS
- [x] Score persistence in DETS
- [x] Categories: science, technology, history, geography, entertainment

**Categories:**
- Science (5 questions)
- Technology (5 questions)
- History (5 questions)
- Geography (5 questions)
- Entertainment (5 questions)

**Selectors:**
- `/trivia` - Main menu
- `/trivia/play` - Play (random)
- `/trivia/play/<category>` - Play category
- `/trivia/answer/<id>/<answer>` - Answer
- `/trivia/score` - Current score
- `/trivia/reset` - Reset score
- `/trivia/leaderboard` - High scores
- `/trivia/save` - Save to leaderboard

**Files created/modified:**
- `lib/pure_gopher_ai/trivia.ex` (new)
- `lib/pure_gopher_ai/gopher_handler.ex` (trivia routes)
- `lib/pure_gopher_ai/application.ex` (supervisor)
- `lib/pure_gopher_ai/sitemap.ex` (updated)

---

### 9.11 Bookmarks / Favorites
**Status:** 🟢 Complete
**Priority:** Medium
**Description:** User-based bookmark system for saving favorite selectors.

**Implementation:**
- [x] Create `Bookmarks` GenServer with DETS storage
- [x] `/bookmarks` - Main menu
- [x] `/bookmarks/login` - Enter username
- [x] `/bookmarks/user/<username>` - View bookmarks
- [x] `/bookmarks/user/<username>/<folder>` - View folder
- [x] `/bookmarks/add/<username>/<selector>/<title>` - Add bookmark
- [x] `/bookmarks/remove/<username>/<id>` - Remove bookmark
- [x] `/bookmarks/folders/<username>` - Manage folders
- [x] `/bookmarks/newfolder/<username>/<name>` - Create folder
- [x] `/bookmarks/export/<username>` - Export bookmarks
- [x] Folder organization (default + custom)
- [x] 100 bookmark limit per user
- [x] 10 folder limit per user

**Selectors:**
- `/bookmarks` - Main menu
- `/bookmarks/login` - Login prompt
- `/bookmarks/user/<username>` - View bookmarks
- `/bookmarks/add/<username>` - Add bookmark
- `/bookmarks/remove/<username>/<id>` - Remove
- `/bookmarks/folders/<username>` - Manage folders
- `/bookmarks/export/<username>` - Export

**Files created/modified:**
- `lib/pure_gopher_ai/bookmarks.ex` (new)
- `lib/pure_gopher_ai/gopher_handler.ex` (bookmark routes)
- `lib/pure_gopher_ai/application.ex` (supervisor)
- `lib/pure_gopher_ai/sitemap.ex` (updated)

---

### 9.12 Unit Converter
**Status:** 🟢 Complete
**Priority:** Medium
**Description:** Convert between various units of measurement.

**Implementation:**
- [x] Create `UnitConverter` module with conversion logic
- [x] `/convert` - Main menu with categories
- [x] `/convert <query>` - Quick conversion (e.g., "100 km to mi")
- [x] `/convert/<category>` - View category-specific units
- [x] Support for 8 categories: length, weight, temperature, volume, area, speed, data, time
- [x] Temperature special case (non-linear conversion)
- [x] Parse natural language queries

**Categories:**
- Length (m, cm, mm, km, in, ft, yd, mi)
- Weight (g, kg, mg, lb, oz, ton, stone)
- Temperature (c, f, k)
- Volume (l, ml, gal, qt, pt, cup, floz)
- Area (sqm, sqft, acre, hectare, sqkm)
- Speed (m/s, km/h, mph, knots)
- Data (b, kb, mb, gb, tb)
- Time (s, min, h, d, wk, mo, yr)

**Selectors:**
- `/convert` - Main menu
- `/convert <query>` - Quick convert
- `/convert/<category>` - Category details

**Files created/modified:**
- `lib/pure_gopher_ai/unit_converter.ex` (new)
- `lib/pure_gopher_ai/gopher_handler.ex` (convert routes)
- `lib/pure_gopher_ai/sitemap.ex` (updated)

---

### 9.13 Calculator
**Status:** 🟢 Complete
**Priority:** Medium
**Description:** Evaluate mathematical expressions.

**Implementation:**
- [x] Create `Calculator` module with expression parser
- [x] `/calc` - Calculator menu with examples
- [x] `/calc <expression>` - Evaluate expression
- [x] Support basic operators: +, -, *, /, ^, %
- [x] Support parentheses for grouping
- [x] Support functions: sqrt, abs, sin, cos, tan, log, exp, pow, floor, ceil, round
- [x] Support constants: pi, e
- [x] Shunting-yard algorithm for operator precedence

**Operators:**
- `+` `-` `*` `/` (basic math)
- `^` or `**` (power)
- `%` or `mod` (modulo)
- `( )` (grouping)

**Selectors:**
- `/calc` - Calculator menu
- `/calc <expression>` - Evaluate

**Files created/modified:**
- `lib/pure_gopher_ai/calculator.ex` (new)
- `lib/pure_gopher_ai/gopher_handler.ex` (calc routes)
- `lib/pure_gopher_ai/sitemap.ex` (updated)

---

### 9.14 Simple Games
**Status:** 🟢 Complete
**Priority:** Medium
**Description:** Simple games for the Gopher community - Hangman, Number Guess, Word Scramble.

**Implementation:**
- [x] Create `Games` GenServer with ETS session storage
- [x] `/games` - Games menu
- [x] Hangman - guess letters to reveal a word
- [x] Number Guess - guess a random number with hints
- [x] Word Scramble - unscramble a word
- [x] Session-based game state with 1-hour TTL
- [x] Automatic cleanup of expired sessions

**Games:**
1. **Hangman** - Classic word guessing game
   - Random word from curated list (tech, animals, objects, abstract)
   - 6 wrong guesses allowed
   - Visual display with masked letters

2. **Number Guess** - Guess the secret number
   - Range 1-100 (configurable)
   - Hints: higher/lower
   - Track number of attempts

3. **Word Scramble** - Unscramble the letters
   - Word scrambled randomly
   - Unlimited attempts

**Selectors:**
- `/games` - Games menu
- `/games/hangman` - Start Hangman
- `/games/hangman/guess` - Guess a letter
- `/games/hangman/status` - View game status
- `/games/number` - Start Number Guess
- `/games/number/guess` - Make a guess
- `/games/number/status` - View game status
- `/games/scramble` - Start Word Scramble
- `/games/scramble/guess` - Guess the word
- `/games/scramble/status` - View game status

**Files created/modified:**
- `lib/pure_gopher_ai/games.ex` (new)
- `lib/pure_gopher_ai/application.ex` (added to supervisor)
- `lib/pure_gopher_ai/gopher_handler.ex` (games routes)
- `lib/pure_gopher_ai/sitemap.ex` (updated)

---

---

## Performance Optimizations TODO

### P1. Handler Module Split
**Status:** Completed
**Priority:** High
**Description:** Split the 9000+ line gopher_handler.ex into focused modules for faster compilation and better maintainability.

**Implementation:**
- [x] Create `lib/pure_gopher_ai/handlers/` directory structure
- [x] Create `handlers/shared.ex` with common utilities (iodata formatting, error handling, streaming)
- [x] Extract AI handlers (`/ask`, `/chat`, `/models`, `/personas`) to `handlers/ai.ex`
- [x] Extract community handlers (`/guestbook`, `/paste`, `/polls`, `/users`) to `handlers/community.ex`
- [x] Extract tool handlers (`/docs`, `/search`, `/art`, `/code`, summarizer, translate) to `handlers/tools.ex`
- [x] Extract admin handlers (`/admin/*`) to `handlers/admin.ex`
- [x] Create thin routing dispatcher in main gopher_handler.ex
- [x] Verify compilation succeeds

**Handler Module Structure:**
```
lib/pure_gopher_ai/handlers/
  shared.ex      - Common utilities (iodata formatting, error responses)
  ai.ex          - AI query/chat handlers (700+ lines)
  community.ex   - Community features (paste, polls, users, guestbook)
  tools.ex       - Tool handlers (docs, search, art, code, translate)
  admin.ex       - Admin interface handlers
```

**Benefits:**
- Faster incremental compilation (only changed modules recompile)
- Better code organization and readability
- Easier testing of individual handlers
- Parallel compilation across modules

---

### P2. IOData Optimization
**Status:** Partially Complete (in handlers/shared.ex)
**Priority:** Medium
**Description:** Replace string concatenation in response formatting with iodata lists for zero-copy operations.

**Implementation:**
- [x] Update `format_gopher_lines/3` to return iodata instead of strings (in shared.ex)
- [x] Update `format_text_response/1` to use iodata (in shared.ex)
- [x] Update `menu_item/5`, `info_line/3`, `link_line/4` to use iodata
- [x] Ensure socket sends accept iodata (ThousandIsland supports this)
- [ ] Migrate remaining handler functions in gopher_handler.ex
- [ ] Benchmark before/after to measure improvement

**Benefits:**
- Reduced memory allocations
- Faster response generation
- Lower GC pressure under load

---

### P3. Persistent Terms for Config
**Status:** Completed
**Priority:** Medium
**Description:** Move frequently-accessed read-only configuration to `:persistent_term` for faster access than Application.get_env.

**Implementation:**
- [x] Identify hot-path config reads (port, host, feature flags)
- [x] Create `PureGopherAi.Config` module to manage persistent terms
- [x] Initialize persistent terms on application start
- [x] Replace `Application.get_env` calls with `Config.get` for hot paths
- [x] Keep Application.get_env for rarely-accessed config

**Config Module Features:**
```elixir
# Fast accessor functions
PureGopherAi.Config.clearnet_host()
PureGopherAi.Config.clearnet_port()
PureGopherAi.Config.onion_address()
PureGopherAi.Config.host_port(:tor | :clearnet)
PureGopherAi.Config.streaming_enabled?()
PureGopherAi.Config.content_dir()
PureGopherAi.Config.admin_token()
# ... and more
```

**Benefits:**
- ~10x faster config reads on hot paths
- No ETS lookup overhead for read-only data
- Automatic sharing across all processes

---

---

## Phase 10: Security Enhancements & Advanced Features

### 10.1 Session Token System
**Status:** 🟢 Complete
**Priority:** High
**Description:** Token-based authentication to reduce passphrase exposure.

**Implementation:**
- [x] Create `Session` GenServer with ETS storage
- [x] 30-minute token TTL with automatic expiry
- [x] Token creation on login
- [x] Token refresh functionality
- [x] Token invalidation (logout)
- [x] Session statistics

**Selectors:**
- `/auth` - Session menu
- `/auth/login` - Get session token
- `/auth/logout/<token>` - Invalidate session
- `/auth/validate/<token>` - Check token validity
- `/auth/refresh/<token>` - Extend session

**Files created/modified:**
- `lib/pure_gopher_ai/session.ex` (new)
- `lib/pure_gopher_ai/handlers/security.ex` (new)
- `lib/pure_gopher_ai/gopher_handler.ex` (auth routes)
- `lib/pure_gopher_ai/application.ex` (supervisor)

---

### 10.2 Audit Logging
**Status:** 🟢 Complete
**Priority:** High
**Description:** Comprehensive audit logging for security and admin events.

**Implementation:**
- [x] Create `AuditLog` GenServer with DETS storage
- [x] Event categories: auth, admin, security, content, system
- [x] Event severities: info, warning, error, critical
- [x] 30-day retention with automatic cleanup
- [x] Query functions with filters
- [x] Admin viewing via `/admin/<token>/audit`

**Events Logged:**
- Authentication success/failure
- Session creation/invalidation
- Admin actions (bans, cache clears)
- Security events (rate limits, injection attempts)
- Content moderation blocks

**Files created/modified:**
- `lib/pure_gopher_ai/audit_log.ex` (new)
- `lib/pure_gopher_ai/handlers/admin.ex` (audit routes)
- `lib/pure_gopher_ai/application.ex` (supervisor)

---

### 10.3 Private Message Encryption
**Status:** 🟢 Complete
**Priority:** High
**Description:** AES-256-GCM encryption at rest for private messages.

**Implementation:**
- [x] Create `Crypto` module with encryption utilities
- [x] AES-256-GCM symmetric encryption
- [x] Auto-generated server encryption key
- [x] Encrypt message subject and body on storage
- [x] Transparent decryption on read
- [x] Backward compatibility with unencrypted messages

**Files created/modified:**
- `lib/pure_gopher_ai/crypto.ex` (new)
- `lib/pure_gopher_ai/mailbox.ex` (encryption integration)

---

### 10.4 CAPTCHA for Tor
**Status:** 🟢 Complete
**Priority:** High
**Description:** Text-based CAPTCHA challenges for high-risk actions on Tor.

**Implementation:**
- [x] Create `Captcha` GenServer with ETS storage
- [x] 15 text-based challenges (math, text, trivia)
- [x] 5-minute challenge TTL
- [x] Automatic cleanup of expired challenges
- [x] Integration with high-risk actions (registration, messaging)

**Selectors:**
- `/captcha/verify/<action>/<id>/<return>` - Verify challenge
- `/captcha/new/<action>/<return>` - Get new challenge

**Files created/modified:**
- `lib/pure_gopher_ai/captcha.ex` (new)
- `lib/pure_gopher_ai/handlers/security.ex` (CAPTCHA handlers)
- `lib/pure_gopher_ai/gopher_handler.ex` (CAPTCHA routes)
- `lib/pure_gopher_ai/application.ex` (supervisor)

---

### 10.5 Password Strength Validation
**Status:** 🟢 Complete
**Priority:** Medium
**Description:** Passphrase strength validation with common password detection.

**Implementation:**
- [x] Create `PasswordValidator` module
- [x] Minimum 8 character requirement
- [x] Common password dictionary (40+ entries)
- [x] Sequential character detection (abc, 123)
- [x] Repeated pattern detection
- [x] Strength scoring (0-100)
- [x] Human-readable strength labels

**Validation Checks:**
- Minimum/maximum length
- Common password list
- All same character
- Sequential patterns
- Repeated patterns

**Files created/modified:**
- `lib/pure_gopher_ai/password_validator.ex` (new)
- `lib/pure_gopher_ai/user_profiles.ex` (validation integration)

---

### 10.6 Account Recovery
**Status:** 🟢 Complete
**Priority:** Medium
**Description:** 12-word mnemonic recovery phrases for account recovery.

**Implementation:**
- [x] Create `Recovery` module
- [x] BIP39-style 256-word dictionary
- [x] 12-word recovery phrase generation
- [x] Phrase hashing with SHA256
- [x] Phrase verification
- [x] New recovery phrase on each recovery
- [x] Recovery generates new passphrase and phrase

**Recovery Flow:**
1. User provides username + recovery phrase + new passphrase
2. System verifies recovery phrase hash
3. System updates passphrase and generates new recovery phrase
4. User receives new recovery phrase (one-time display)

**Files created/modified:**
- `lib/pure_gopher_ai/recovery.ex` (new)
- `lib/pure_gopher_ai/user_profiles.ex` (recovery integration)

---

### 10.7 IP Reputation Scoring
**Status:** 🟢 Complete
**Priority:** Medium
**Description:** Behavioral IP scoring with decay over time.

**Implementation:**
- [x] Create `IpReputation` GenServer with DETS storage
- [x] Score range 0-100 (higher = more risky)
- [x] Default score: 25
- [x] Automatic score decay toward default
- [x] Thresholds: 50 suspicious, 75 high-risk, 90 auto-block
- [x] 30-day cleanup of old entries

**Score Adjustments:**
- Auth failure: +5
- Rate limit: +10
- Content block: +15
- Spam behavior: +20
- Successful auth: -2
- Successful post: -1

**Files created/modified:**
- `lib/pure_gopher_ai/ip_reputation.ex` (new)
- `lib/pure_gopher_ai/application.ex` (supervisor)

---

### 10.8 User Notifications
**Status:** 🟢 Complete
**Priority:** Medium
**Description:** In-app notification system for user events.

**Implementation:**
- [x] Create `Notifications` GenServer with DETS storage
- [x] Notification types: message, reply, mention, comment, system, announcement
- [x] 100 notifications per user limit
- [x] 30-day TTL with automatic cleanup
- [x] Read/unread tracking
- [x] Mark all read functionality
- [x] Announcement broadcast to all users

**Files created/modified:**
- `lib/pure_gopher_ai/notifications.ex` (new)
- `lib/pure_gopher_ai/application.ex` (supervisor)

---

### 10.9 Content Reporting
**Status:** 🟢 Complete
**Priority:** Medium
**Description:** User reporting system for inappropriate content.

**Implementation:**
- [x] Create `ContentReports` GenServer with DETS storage
- [x] Content types: guestbook, message, phlog, comment, profile, bulletin, poll, paste
- [x] Report reasons: spam, harassment, illegal, inappropriate, copyright, other
- [x] Priority scoring based on severity
- [x] Pending/resolved status workflow
- [x] Rate limiting (10 reports per IP per day)
- [x] Duplicate report prevention
- [x] Admin escalate/resolve functions

**Files created/modified:**
- `lib/pure_gopher_ai/content_reports.ex` (new)
- `lib/pure_gopher_ai/application.ex` (supervisor)

---

### 10.10 User Blocking
**Status:** 🟢 Complete
**Priority:** Medium
**Description:** Block/mute users for messaging and interactions.

**Implementation:**
- [x] Create `UserBlocks` GenServer with DETS storage
- [x] Block users from messaging
- [x] Mute users (hide content without blocking)
- [x] 100 blocks per user limit
- [x] `can_message?/2` check function
- [x] `can_comment?/2` check function
- [x] List blocked/muted users
- [x] View who has blocked a user

**Files created/modified:**
- `lib/pure_gopher_ai/user_blocks.ex` (new)
- `lib/pure_gopher_ai/application.ex` (supervisor)

---

### 10.11 Scheduled Posts
**Status:** 🟢 Complete
**Priority:** Medium
**Description:** Schedule phlog posts for future publication.

**Implementation:**
- [x] Create `ScheduledPosts` GenServer with DETS storage
- [x] 10 scheduled posts per user limit
- [x] Minimum 5 minutes ahead scheduling
- [x] Automatic publication when scheduled time arrives
- [x] Cancel/reschedule functionality
- [x] Status tracking: pending, published, cancelled, failed
- [x] 1-minute check interval

**Selectors:**
- Schedule, list, cancel, reschedule via UserPhlog integration

**Files created/modified:**
- `lib/pure_gopher_ai/scheduled_posts.ex` (new)
- `lib/pure_gopher_ai/user_phlog.ex` (internal post creation)
- `lib/pure_gopher_ai/application.ex` (supervisor)

---

### 10.12 User Data Export
**Status:** 🟢 Complete
**Priority:** Medium
**Description:** Export all user data in portable format.

**Implementation:**
- [x] Create `UserExport` module
- [x] Export profile, phlog posts, messages, bookmarks, notifications
- [x] Text format for Gopher viewing
- [x] JSON format for data portability
- [x] Passphrase authentication required
- [x] Formatted sections with headers

**Export Includes:**
- Profile (bio, links, interests)
- All phlog posts
- Inbox and sent messages
- Bookmarks with folders
- Notifications

**Files created/modified:**
- `lib/pure_gopher_ai/user_export.ex` (new)

---

### 10.13 Enhanced Search
**Status:** 🟢 Complete
**Priority:** Medium
**Description:** Fuzzy matching, filters, and advanced query syntax.

**Implementation:**
- [x] Create `SearchEnhanced` module
- [x] Fuzzy/typo-tolerant matching with edit distance
- [x] Content type filters: all, phlog, files, users, guestbook, bulletin
- [x] Phrase search with quotes ("exact phrase")
- [x] Exclude terms with minus (-exclude)
- [x] Author/username filter
- [x] Date range filters (since/until)
- [x] Common typo substitutions

**Advanced Query Syntax:**
- `"exact phrase"` - Match exact phrase
- `-exclude` - Exclude term
- Automatic typo variants

**Files created/modified:**
- `lib/pure_gopher_ai/search_enhanced.ex` (new)

---

### 10.14 User Phlog RSS/Atom Feeds
**Status:** 🟢 Complete
**Priority:** Low
**Description:** Individual RSS/Atom feeds for user phlogs.

**Implementation:**
- [x] Create `UserPhlogFeed` module
- [x] Atom feed generation per user
- [x] RSS 2.0 feed generation per user
- [x] Combined feed for all user phlogs
- [x] Proper XML escaping
- [x] Author attribution

**Feed Endpoints:**
- Per-user Atom feed
- Per-user RSS feed
- Combined all-users feed

**Files created/modified:**
- `lib/pure_gopher_ai/user_phlog_feed.ex` (new)

---

## Phase 11: Community & Infrastructure Enhancements

### 11.1 Two-Factor Authentication (TOTP)
**Status:** 🟢 Complete
**Priority:** High
**Description:** Time-based one-time passwords for additional security.

**Implementation:**
- [x] Create `Totp` module with RFC 6238 implementation
- [x] Compatible with Google Authenticator, Authy, etc.
- [x] Base32 secret generation
- [x] Backup codes (8 codes) with hashing
- [x] Clock drift tolerance (±1 window)
- [x] Setup text display for Gopher clients
- [x] Enable/disable/verify TOTP in UserProfiles

**Files created/modified:**
- `lib/pure_gopher_ai/totp.ex` (new)
- `lib/pure_gopher_ai/user_profiles.ex` (TOTP integration)

---

### 11.2 API Tokens
**Status:** 🟢 Complete
**Priority:** High
**Description:** Programmatic access tokens for scripts and bots.

**Implementation:**
- [x] Create `ApiTokens` GenServer with DETS storage
- [x] Named tokens with permissions (read, write, phlog, mail, etc.)
- [x] Token expiration (default 365 days)
- [x] Usage tracking (last_used, use_count)
- [x] Max 10 tokens per user
- [x] Revoke individual or all tokens
- [x] Tokens hashed before storage

**Permissions:** read, write, phlog, mail, bookmarks, search

**Files created/modified:**
- `lib/pure_gopher_ai/api_tokens.ex` (new)
- `lib/pure_gopher_ai/application.ex` (supervisor)

---

### 11.3 Reactions/Voting
**Status:** 🟢 Complete
**Priority:** Medium
**Description:** Upvote/downvote system for content.

**Implementation:**
- [x] Create `Reactions` GenServer with DETS storage
- [x] Upvote/downvote on phlog, bulletin, guestbook, comments
- [x] One vote per user per item
- [x] Change or remove votes
- [x] Aggregate score calculation
- [x] ETS cache for scores
- [x] Top content by score

**Files created/modified:**
- `lib/pure_gopher_ai/reactions.ex` (new)
- `lib/pure_gopher_ai/application.ex` (supervisor)

---

### 11.4 Tagging System
**Status:** 🟢 Complete
**Priority:** Medium
**Description:** User-defined tags for content discovery.

**Implementation:**
- [x] Create `Tags` GenServer with DETS storage
- [x] Add/remove/set tags on content
- [x] Max 10 tags per item, 30 chars per tag
- [x] Tag cloud with popularity counts
- [x] Browse content by tag
- [x] Related tags (co-occurrence)
- [x] Tag search by prefix

**Files created/modified:**
- `lib/pure_gopher_ai/tags.ex` (new)
- `lib/pure_gopher_ai/application.ex` (supervisor)

---

### 11.5 Follow/Subscribe
**Status:** 🟢 Complete
**Priority:** Medium
**Description:** Follow users and get notifications of new posts.

**Implementation:**
- [x] Create `Follows` GenServer with DETS storage
- [x] Follow/unfollow users
- [x] Max 500 following per user
- [x] Followers/following lists
- [x] Follow counts
- [x] Suggested users based on mutual follows
- [x] Notify followers on new content
- [x] Follow notification to target user

**Files created/modified:**
- `lib/pure_gopher_ai/follows.ex` (new)
- `lib/pure_gopher_ai/application.ex` (supervisor)

---

### 11.6 Threaded Comments
**Status:** 🟢 Complete
**Priority:** Medium
**Description:** Reply to comments on phlog posts.

**Implementation:**
- [x] Create `Comments` GenServer with DETS storage
- [x] Add/edit/delete comments
- [x] Threaded replies (max depth 5)
- [x] Max 500 comments per item
- [x] Content moderation integration
- [x] Soft delete (preserve thread structure)
- [x] Tree building for display
- [x] Reply notifications

**Files created/modified:**
- `lib/pure_gopher_ai/comments.ex` (new)
- `lib/pure_gopher_ai/application.ex` (supervisor)

---

### 11.7 Content Versioning
**Status:** 🟢 Complete
**Priority:** Medium
**Description:** Edit history for posts.

**Implementation:**
- [x] Create `Versioning` GenServer with DETS storage
- [x] Save version on edit
- [x] Max 50 versions per item
- [x] View version history
- [x] Get specific version
- [x] Diff between versions
- [x] Content hash for change detection
- [x] Word/character change stats

**Files created/modified:**
- `lib/pure_gopher_ai/versioning.ex` (new)
- `lib/pure_gopher_ai/application.ex` (supervisor)

---

### 11.8 Related Content (AI-Powered)
**Status:** 🟢 Complete
**Priority:** Medium
**Description:** AI-powered "you might also like" recommendations.

**Implementation:**
- [x] Create `RelatedContent` GenServer
- [x] Related posts based on tags and keywords
- [x] Personalized recommendations based on reaction history
- [x] AI-powered theme extraction
- [x] Caching with 1-hour TTL
- [x] Similarity scoring (tags, keywords, author, reactions)

**Files created/modified:**
- `lib/pure_gopher_ai/related_content.ex` (new)
- `lib/pure_gopher_ai/application.ex` (supervisor)

---

### 11.9 Trending/Popular
**Status:** 🟢 Complete
**Priority:** Medium
**Description:** Surface active and popular content.

**Implementation:**
- [x] Create `Trending` GenServer
- [x] Trending posts (recency + engagement weighted)
- [x] All-time popular posts
- [x] Trending tags
- [x] Hot discussions (most commented)
- [x] Rising posts (new posts gaining traction)
- [x] Activity stats (posts, comments, users per period)
- [x] Caching with 5-minute TTL

**Files created/modified:**
- `lib/pure_gopher_ai/trending.ex` (new)
- `lib/pure_gopher_ai/application.ex` (supervisor)

---

### 11.10 User Analytics
**Status:** 🟢 Complete
**Priority:** Medium
**Description:** Views and engagement stats for authors.

**Implementation:**
- [x] Create `UserAnalytics` GenServer with DETS storage
- [x] Event recording (views, upvotes, comments, follows)
- [x] Summary stats (total views, upvotes, comments, followers)
- [x] Post analytics (per-post engagement)
- [x] Engagement over time (daily breakdown)
- [x] Top performing content
- [x] Audience insights (top engagers, frequent commenters)
- [x] Engagement rate calculation

**Files created/modified:**
- `lib/pure_gopher_ai/user_analytics.ex` (new)
- `lib/pure_gopher_ai/application.ex` (supervisor)

---

### 11.11 Federation
**Status:** 🟢 Complete
**Priority:** Medium
**Description:** Connect to and aggregate content from other Gopher servers.

**Implementation:**
- [x] Create `Federation` GenServer with DETS storage
- [x] Add/remove peer servers
- [x] Peer health monitoring (ping, status tracking)
- [x] Fetch content from peers
- [x] Aggregated feed from all healthy peers
- [x] Federated search across peers
- [x] Periodic sync (hourly)
- [x] Content caching

**Files created/modified:**
- `lib/pure_gopher_ai/federation.ex` (new)
- `lib/pure_gopher_ai/application.ex` (supervisor)

---

### 11.12 Webhooks
**Status:** 🟢 Complete
**Priority:** Medium
**Description:** Notify external services (Discord, Matrix, etc.) of events.

**Implementation:**
- [x] Create `Webhooks` GenServer with DETS storage
- [x] Register webhooks with URL and events
- [x] Event types: new_post, new_comment, new_user, new_follow, etc.
- [x] HMAC-SHA256 signature for verification
- [x] Retry with exponential backoff (3 attempts)
- [x] Delivery logging
- [x] Test webhook functionality
- [x] Enable/disable webhooks

**Files created/modified:**
- `lib/pure_gopher_ai/webhooks.ex` (new)
- `lib/pure_gopher_ai/application.ex` (supervisor)

---

### 11.13 Full Backup/Restore
**Status:** 🟢 Complete
**Priority:** High
**Description:** Admin-level server snapshots.

**Implementation:**
- [x] Create `Backup` GenServer
- [x] Full backup of all DETS files
- [x] Manifest with metadata (files, sizes, timestamp)
- [x] Restore from backup (with confirmation)
- [x] Scheduled automatic backups
- [x] Max 10 backups (auto-cleanup)
- [x] Export as tar.gz archive
- [x] Delete old backups

**Files created/modified:**
- `lib/pure_gopher_ai/backup.ex` (new)
- `lib/pure_gopher_ai/application.ex` (supervisor)

---

### 11.14 Plugin System
**Status:** 🟢 Complete
**Priority:** Medium
**Description:** Extensible architecture for custom functionality.

**Implementation:**
- [x] Create `Plugins` GenServer with DETS storage
- [x] Load/unload plugins at runtime
- [x] Plugin hooks for various events
- [x] Plugin configuration storage
- [x] Sandboxed execution
- [x] Enable/disable plugins
- [x] Plugin metadata (name, version, author)

**Hook Points:** before_request, after_request, on_new_post, on_new_user, on_login, on_ai_query, content_filter, custom_selector

**Files created/modified:**
- `lib/pure_gopher_ai/plugins.ex` (new)
- `lib/pure_gopher_ai/application.ex` (supervisor)

---

### 11.15 Gopher+ Support
**Status:** 🟢 Complete
**Priority:** Low
**Description:** Extended metadata and attributes.

**Implementation:**
- [x] Create `GopherPlus` module
- [x] Gopher+ request detection
- [x] +INFO block generation
- [x] +ADMIN block (admin email, mod date)
- [x] +VIEWS block (alternative representations)
- [x] +ABSTRACT block (summary text)
- [x] +ASK block (form fields)
- [x] Item attributes inline
- [x] Directory+ listings

**Files created/modified:**
- `lib/pure_gopher_ai/gopher_plus.ex` (new)

---

### 11.16 CAPS.txt (Capability Discovery)
**Status:** 🟢 Complete
**Priority:** Low
**Description:** Machine-readable server capabilities.

**Implementation:**
- [x] Create `Caps` module
- [x] Server info section
- [x] Protocol support (Gopher, Gopher+, Gemini, Tor)
- [x] Feature list (all enabled features)
- [x] API endpoints
- [x] Rate limits
- [x] Content types and selectors
- [x] Programmatic access via capabilities/0

**Served at:** /caps.txt

**Files created/modified:**
- `lib/pure_gopher_ai/caps.ex` (new)

---

### 11.17 Gopherspace Server Directory
**Status:** 🟢 Complete
**Priority:** Medium
**Description:** Directory of major Gopherspace servers and hubs for community discovery.

**Implementation:**
- [x] Create `ServerDirectory` module
- [x] Major hubs (Floodgap, SDF, Quux.org, Circumlunar)
- [x] Search engines (Veronica-2, GopherVR)
- [x] Phlog communities (Gopher Club, Zaibatsu, Cosmic Voyage)
- [x] Public access Unix systems (RTC, tilde.town, Ctrl-C)
- [x] Documentation resources (RFC 1436, Gopher+, Overbite)
- [x] Gophermap generation with category sections
- [x] Getting listed instructions
- [x] Added /servers route to handler
- [x] Added to root menu

**Served at:** /servers

**Files created/modified:**
- `lib/pure_gopher_ai/server_directory.ex` (new)
- `lib/pure_gopher_ai/gopher_handler.ex` (routes, menu)

---

### 11.18 Crawler Optimization
**Status:** 🟢 Complete
**Priority:** Low
**Description:** Optimize for Gopher search engine crawlers (Veronica-2) and indexing.

**Implementation:**
- [x] Create `CrawlerHints` module
- [x] robots.txt equivalent for Gopher crawlers
- [x] Allow/Disallow directives for public/private content
- [x] Crawl-delay recommendation
- [x] Sitemap generation (text and gophermap formats)
- [x] Dynamic content inclusion (user phlogs, bulletin boards)
- [x] Meta block generation for page metadata
- [x] Root hints for crawler discovery
- [x] Added /robots.txt route
- [x] Integration with existing /caps.txt

**Served at:** /robots.txt, integrated with /sitemap

**Files created/modified:**
- `lib/pure_gopher_ai/crawler_hints.ex` (new)
- `lib/pure_gopher_ai/gopher_handler.ex` (routes)
- `lib/pure_gopher_ai/config.ex` (admin_email)

---

### 11.19 Phlog Formatter & Creative Tools
**Status:** 🟢 Complete
**Priority:** Medium
**Description:** AI-powered phlog content formatter with medieval manuscript-inspired decorations.

**Implementation:**
- [x] Create `PhlogFormatter` module - Markdown to Gopher conversion
- [x] Create `PhlogArt` module - Thematic ASCII art library
- [x] Markdown conversion: headers, links, images, lists, code, quotes
- [x] Auto URL detection (HTTP, Gopher, email)
- [x] Illuminated drop caps (decorative first letters)
- [x] Medieval-style borders and ornaments
- [x] Thematic ASCII art based on content (13+ themes)
- [x] Multiple formatting styles: minimal, ornate, medieval
- [x] Preview endpoint for testing formatted content
- [x] Art gallery for browsing available themes
- [x] AI-generated custom illustrations (optional)

**New Routes:**
- `/phlog/format` - Formatting tools menu
- `/phlog/format/preview` - Preview formatted content
- `/phlog/format/styles` - View available styles
- `/phlog/format/art` - ASCII art gallery
- `/phlog/format/art/<theme>` - View theme art

**Themes Available:**
technology, nature, adventure, knowledge, music, space, fantasy, food, home, time, love, animals, weather, celebration, default

**Files created/modified:**
- `lib/pure_gopher_ai/phlog_formatter.ex` (new)
- `lib/pure_gopher_ai/phlog_art.ex` (new)
- `lib/pure_gopher_ai/gopher_handler.ex` (routes, handlers)

---

## Notes

- Implement features in order of priority
- Commit after each feature
- Update this file as progress is made
- Test both clearnet and Tor after each feature
