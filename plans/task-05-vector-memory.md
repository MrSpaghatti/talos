## NOTE: This project has been renamed from Mercury Agent to Talos Agent. All package names (mercury_core, mercury_agent, mercury_code) are now (talos_core, talos_agent, talos_code).

# Task 5: Vector Memory / Semantic Retrieval

**Status**: 🔴 Not Started
**Dependencies**: Task 1 (Agent Loop relocation — soft, for cleaner imports)
**Complexity**: Medium-Large

> **Before implementing:** cross-check the plan below against two 2026-07-25
> notes that postdate it:
> - [feature-adoption-report.md](feature-adoption-report.md) §2.1 — recommends
>   exposing this as three tool-registry entries (`retain` / `recall` /
>   `reflect`) instead of one opaque memory tool. Same backend, same total
>   scope, different API shape — build it in this shape from the start rather
>   than shipping one tool and refactoring later. `retain`/`recall` are pure
>   data operations (build first); `reflect` needs an extra LLM call over
>   retrieved context.
> - [research-sqlite-vec-nim-ffi.md](research-sqlite-vec-nim-ffi.md) —
>   proposes `sqlite-vec`'s `vec0` virtual table (via a two-line `importc`
>   FFI shim on the existing `db_sqlite` dynlib) in place of Phase 5b/5c's
>   brute-force "load every embedding into Nim and loop" approach, which
>   won't scale.
> Also worth scoping the checkpoint/memory boundary (report §2.2,
> [task-14-checkpoints.md](task-14-checkpoints.md)) in the same design pass,
> since both touch "what's kept vs. dropped from context."

---

## Target

- `mercury_core/src/mercury_core/memory.nim`
- `mercury_core/src/mercury_core/embeddings.nim` (new)
- `mercury_core/src/mercury_core/config.nim`

## Current State

- `memory.nim` has SQLite + FTS5 for full-text search.
- No embedding support. No vector storage.
- The agent stores conversations but can only search by keyword match.

## Change

### Phase 5a — Embeddings client
1. Create `embeddings.nim`:
   ```nim
   type
     EmbeddingClient* = object
       baseUrl*: string
       apiKey*: string
       model*: string          # e.g. "text-embedding-3-small"
       timeoutMs*: int

     EmbeddingResult* = object
       vector*: seq[float32]
       tokensUsed*: int

   proc getEmbedding*(client: EmbeddingClient; text: string): EmbeddingResult
   ```
2. Uses the OpenAI `/v1/embeddings` endpoint (same auth as chat completions).
3. Config: add `[embeddings]` section to `MercuryConfig` — `provider`, `model`, `endpoint` (defaults to same as LLM provider).

### Phase 5b — Vector storage in SQLite
1. Extend `memory.nim`:
   - New table: `message_embeddings(message_id INTEGER, embedding BLOB, model TEXT)`.
   - Store embeddings as compact binary blobs (4 bytes per float32).
2. Add `storeEmbedding(db; messageId; embedding; model)` and `clearEmbeddings(db; model)`.
3. Add a `MessageVectorMatch` type:
   ```nim
   type
     MessageVectorMatch* = object
       messageId*: int64
       sessionId*: string
       content*: string
       score*: float32
   ```

### Phase 5c — Cosine similarity search
1. In `memory.nim`, add:
   ```nim
   proc searchByVector*(self: var Memory; query: string; embeddingClient: EmbeddingClient;
                        topK: int = 10; minScore: float32 = 0.7): seq[MessageVectorMatch]
   ```
2. Implementation:
   - Get embedding for query via `embeddingClient.getEmbedding(query)`.
   - Load all stored embeddings from DB.
   - Compute cosine similarity in Nim (avoid SQLite for float math).
   - Return top-K above threshold.
3. Fallback: if no embeddings stored yet (cold start), fall back to FTS5 search.

### Phase 5d — Automatic embedding on message store
1. Add optional `embeddingClient` parameter to `memory.appendMessage`.
2. If provided, compute embedding for the message content and store it.
3. Config flag: `memory.auto_embed = true/false` — embedding costs tokens, make it opt-in.
4. On `newSession`, optionally embed the first user message for session-level search.

### Phase 5e — Hybrid search
1. Add `searchHybrid*(query, topK, ftsWeight, vecWeight)`:
   - Runs FTS5 and vector search in parallel.
   - Merges results by weighted score (FTS5 rank + vector similarity).
   - Returns deduplicated ranked list.
2. Wire into CLI: `./mercury_agent search "concept" --semantic` uses hybrid search.

## Acceptance

- `getEmbedding` returns a valid 1536-dim (or model-appropriate) vector from OpenAI API.
- Unit test: mock embedding endpoint returns known vector; `searchByVector` returns correct matches.
- Integration test: store 3 messages, embed them, search for semantically similar query → correct message returned.
- FTS5 fallback works when embeddings not enabled.
- Hybrid search returns better results than FTS5 alone for semantic queries.
- All 460 existing tests pass.