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
**Status:** 🟢 Complete
**Priority:** Medium
**Description:** Personal homepage system for community members.

**Implementation:**
- [x] Create `UserProfiles` GenServer with DETS persistent storage
- [x] `/users` - User profiles menu with stats
- [x] `/users/create` - Create profile (Type 7 input)
- [x] `/users/list` - Browse all profiles (paginated)
- [x] `/users/search` - Search by username or interests
- [x] `/users/~username` - View user's homepage
- [x] Profile includes bio, links, interests
- [x] Username validation (3-20 chars, alphanumeric + underscore)
- [x] Rate limiting (1 profile per IP per day)
- [x] View count tracking
- [x] Admin delete functionality

**Selectors:**
- `/users` - User profiles menu
- `/users/create` - Create profile
- `/users/list` - Browse all users
- `/users/list/page/<n>` - Paginated user list
- `/users/search` - Search users
- `/users/~<username>` - View user homepage

**Files created/modified:**
- `lib/pure_gopher_ai/user_profiles.ex` (new)
- `lib/pure_gopher_ai/gopher_handler.ex` (user routes)
- `lib/pure_gopher_ai/application.ex` (supervisor)

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

## Notes

- Implement features in order of priority
- Commit after each feature
- Update this file as progress is made
- Test both clearnet and Tor after each feature
