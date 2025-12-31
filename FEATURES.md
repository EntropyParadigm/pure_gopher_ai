# PureGopherAI - Feature Implementation Tracker

## Overview
This document tracks the implementation status of all planned features.

---

## Phase 1: Core Server Features

### 1.1 gophermap Support
**Status:** 🔴 Not Started
**Priority:** High
**Description:** Serve static content from configurable directory using standard gophermap format.

**Implementation:**
- [ ] Create `GophermapParser` module
- [ ] Support standard gophermap format (type, display, selector, host, port)
- [ ] Configurable content directory (`~/.gopher/` or custom)
- [ ] Auto-generate directory listings
- [ ] Support for info lines, links, files, subdirectories

**Files to create/modify:**
- `lib/pure_gopher_ai/gophermap.ex`
- `lib/pure_gopher_ai/gopher_handler.ex`
- `config/config.exs`

---

### 1.2 Rate Limiting
**Status:** 🔴 Not Started
**Priority:** High
**Description:** Limit requests per IP to prevent abuse, especially important for Tor exposure.

**Implementation:**
- [ ] Create `RateLimiter` GenServer
- [ ] Track requests per IP with sliding window
- [ ] Configurable limits (requests per minute)
- [ ] Different limits for clearnet vs Tor
- [ ] Return Gopher error on rate limit exceeded

**Files to create/modify:**
- `lib/pure_gopher_ai/rate_limiter.ex`
- `lib/pure_gopher_ai/gopher_handler.ex`
- `config/config.exs`

---

### 1.3 Conversation Memory
**Status:** 🔴 Not Started
**Priority:** High
**Description:** Store chat history per session to enable contextual AI responses.

**Implementation:**
- [ ] Create `ConversationStore` GenServer with ETS
- [ ] Session ID generation (hash of IP + user-agent or random)
- [ ] Store last N messages per session
- [ ] TTL for session expiry
- [ ] Pass conversation context to AI engine
- [ ] New selector: `/chat` for conversational mode
- [ ] `/clear` to reset conversation

**Files to create/modify:**
- `lib/pure_gopher_ai/conversation_store.ex`
- `lib/pure_gopher_ai/ai_engine.ex`
- `lib/pure_gopher_ai/gopher_handler.ex`

---

### 1.4 Streaming Responses
**Status:** 🔴 Not Started
**Priority:** Medium
**Description:** Stream AI output as it generates for better UX with slow models.

**Implementation:**
- [ ] Enable Bumblebee streaming mode
- [ ] Chunk responses over TCP
- [ ] Handle client disconnection gracefully
- [ ] Fallback for non-streaming clients

**Files to create/modify:**
- `lib/pure_gopher_ai/ai_engine.ex`
- `lib/pure_gopher_ai/gopher_handler.ex`

---

## Phase 2: AI Enhancements

### 2.1 Multiple Model Support
**Status:** 🔴 Not Started
**Priority:** Medium
**Description:** Support multiple AI models with different selectors.

**Implementation:**
- [ ] Model registry in config
- [ ] Separate Nx.Serving per model
- [ ] Selectors: `/ask-gpt2`, `/ask-llama`, `/ask-mistral`
- [ ] Model info in `/about`
- [ ] Lazy loading (load on first request)

**Models to support:**
- GPT-2 (default, fast)
- Llama 2/3 (quality)
- Mistral (balanced)
- Phi-2 (small but capable)

**Files to create/modify:**
- `lib/pure_gopher_ai/model_registry.ex`
- `lib/pure_gopher_ai/ai_engine.ex`
- `lib/pure_gopher_ai/application.ex`
- `config/config.exs`

---

### 2.2 System Prompts
**Status:** 🔴 Not Started
**Priority:** Medium
**Description:** Configurable AI personality/behavior via system prompts.

**Implementation:**
- [ ] System prompt in config
- [ ] Prepend to user queries
- [ ] Multiple personas via different selectors
- [ ] `/persona` selector to list available

**Files to create/modify:**
- `lib/pure_gopher_ai/ai_engine.ex`
- `config/config.exs`

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
| - | - | - | - |

---

## Notes

- Implement features in order of priority
- Commit after each feature
- Update this file as progress is made
- Test both clearnet and Tor after each feature
