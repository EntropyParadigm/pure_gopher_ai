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
**Status:** 🔴 Not Started
**Priority:** Medium
**Description:** Cache repeated AI queries to reduce GPU load.

**Implementation:**
- [ ] Create `ResponseCache` with ETS
- [ ] Hash-based cache keys (query + model)
- [ ] Configurable TTL
- [ ] Cache hit/miss metrics
- [ ] Max cache size with LRU eviction

**Files to create/modify:**
- `lib/pure_gopher_ai/response_cache.ex`
- `lib/pure_gopher_ai/ai_engine.ex`

---

## Phase 3: Gopher Protocol Features

### 3.1 Search (Type 7)
**Status:** 🔴 Not Started
**Priority:** Medium
**Description:** Implement Gopher search protocol for interactive queries.

**Implementation:**
- [ ] Type 7 selector handling
- [ ] Search input prompt
- [ ] Search across gophermap content
- [ ] Search AI conversation history
- [ ] Full-text search with ranking

**Files to create/modify:**
- `lib/pure_gopher_ai/search.ex`
- `lib/pure_gopher_ai/gopher_handler.ex`

---

### 3.2 Phlog Support
**Status:** 🔴 Not Started
**Priority:** Low
**Description:** Gopher blog with dated entries.

**Implementation:**
- [ ] Phlog directory structure (`phlog/YYYY/MM/DD-title.txt`)
- [ ] Auto-generated index by date
- [ ] RSS/Atom feed generation
- [ ] `/phlog` selector
- [ ] Pagination

**Files to create/modify:**
- `lib/pure_gopher_ai/phlog.ex`
- `lib/pure_gopher_ai/gopher_handler.ex`

---

## Phase 4: Operations

### 4.1 Metrics/Telemetry
**Status:** 🔴 Not Started
**Priority:** Medium
**Description:** Request counts, latency, model usage tracking.

**Implementation:**
- [ ] Integrate `:telemetry` library
- [ ] Track: requests, latency, errors, cache hits
- [ ] Per-model metrics
- [ ] Per-network (clearnet/tor) metrics
- [ ] `/stats` selector for public metrics
- [ ] Optional Prometheus export

**Files to create/modify:**
- `lib/pure_gopher_ai/telemetry.ex`
- `lib/pure_gopher_ai/gopher_handler.ex`
- `mix.exs` (add telemetry_metrics, telemetry_poller)

---

### 4.2 Admin Gopherhole
**Status:** 🔴 Not Started
**Priority:** Low
**Description:** Admin interface accessible via Gopher.

**Implementation:**
- [ ] Auth via selector token (`/admin/<token>/...`)
- [ ] View stats, active sessions, cache status
- [ ] Clear cache, ban IPs
- [ ] Reload config
- [ ] View logs

**Files to create/modify:**
- `lib/pure_gopher_ai/admin.ex`
- `lib/pure_gopher_ai/gopher_handler.ex`

---

## Phase 5: Advanced Features

### 5.1 RAG (Retrieval Augmented Generation)
**Status:** 🔴 Not Started
**Priority:** Low
**Description:** Query your own documents for AI-enhanced answers.

**Implementation:**
- [ ] Document ingestion (txt, md, pdf)
- [ ] Vector embeddings with Bumblebee
- [ ] Vector store (ETS or external)
- [ ] Semantic search
- [ ] Context injection into prompts
- [ ] `/docs` selector

**Files to create/modify:**
- `lib/pure_gopher_ai/rag/document_store.ex`
- `lib/pure_gopher_ai/rag/embeddings.ex`
- `lib/pure_gopher_ai/rag/retriever.ex`

---

### 5.2 Gemini Protocol Support
**Status:** 🔴 Not Started
**Priority:** Low
**Description:** Dual Gopher + Gemini server.

**Implementation:**
- [ ] Gemini protocol handler (TLS, gemini://)
- [ ] Shared content between protocols
- [ ] Gemini-specific formatting
- [ ] Certificate management

**Files to create/modify:**
- `lib/pure_gopher_ai/gemini_handler.ex`
- `lib/pure_gopher_ai/application.ex`

---

### 5.3 ASCII Art Generation
**Status:** 🔴 Not Started
**Priority:** Low
**Description:** Generate ASCII art from prompts or images.

**Implementation:**
- [ ] Text-to-ASCII art (figlet style)
- [ ] Image-to-ASCII conversion
- [ ] AI-generated descriptions to ASCII
- [ ] `/art` selector

**Files to create/modify:**
- `lib/pure_gopher_ai/ascii_art.ex`
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
| 2025-01-01 | System Prompts / Personas | Complete | (pending) |

---

## Notes

- Implement features in order of priority
- Commit after each feature
- Update this file as progress is made
- Test both clearnet and Tor after each feature
