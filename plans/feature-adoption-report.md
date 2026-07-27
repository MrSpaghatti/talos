# Talos Feature Adoption Report

**Date**: 2026-07-25
**Status**: Reference document — not itself a task, sourced from a comparative
review of oh-my-pi (omp), OpenCode, and Claude Code. Individual actionable
items are tracked as their own task files (see cross-references throughout
and the summary table at the bottom); two items are folded directly into
existing tasks rather than split out (see 2.1 and 3.1 below).

**Purpose:** Prioritized spec for features to port into Talos, sourced from a comparative review of oh-my-pi (omp), OpenCode, and Claude Code. Written for implementing agents — each item includes rationale, the concrete mechanic, and how it interacts with existing Talos subsystems.

**Context for implementers:** Talos is a self-contained agent framework in Nim (repo: github.com/MrSpaghatti/talos, local path /home/spag/talos). Three packages: `talos_core` (config, LLM client over OpenAI Chat Completions protocol, SQLite+FTS5 memory, tool registry, ReAct + plan-execute loop, MCP client bridge, persona/delegation, Discord bot stack), `talos_agent` (CLI: chat/ask/tui/session/history/search/web/daemon/run), `talos_code` (autonomous coding harness). As of 2026-07-24: all planned phases complete, 557 tests passing across 31 files, CI green, through 3 audit rounds. Two tasks open and unstarted: **Task 5 (Vector Memory)** and **Task 7 (MCP Streaming)**. This report's sequencing assumes those two tasks are the next real work and slots everything else around them.

Sources reviewed: oh-my-pi (can1357/oh-my-pi, omp.sh), OpenCode (opencode.ai) and the oh-my-opencode fork ecosystem, Claude Code (docs.claude.com).

---

## Priority 1 — Cheap, no architecture change

### 1.1 `/btw` — ephemeral side-question
**Source:** omp slash commands.
**What it does:** Asks a question mid-session that the model sees in its current context, but the exchange is never persisted — doesn't get written to session history, doesn't show in branch trees, isn't picked up by memory consolidation.
**Why it's worth it:** Lets the user interrogate the agent's current state (e.g. "what does the regex on line 47 actually match?") without polluting the transcript or getting indexed into FTS5/vector memory later. Near-zero cost relative to value.
**Implementation sketch:** Same LLM call path as a normal turn, but skip the session-write step in `talos_agent`. Needs a way to still feed current context (files read, prior turns) without appending the Q&A itself to that context for future turns. Should be a CLI-level flag/command, not a change to `talos_core`'s loop itself.
**Effort:** ~1 hour.
**Task file:** [task-11-btw-command.md](task-11-btw-command.md)

### 1.2 Preview-then-accept edit workflow
**Source:** omp (`ast_edit` → `resolve` pattern).
**What it does:** A proposed edit is staged and shown as a diff before it's written to disk. Requires an explicit accept/resolve call before the atomic write happens.
**Why it's worth it:** Catches bad edits before they land, cheap insurance for `talos_code`'s autonomous coding harness specifically.
**Implementation sketch:** Add a staged/pending state to whatever edit tool `talos_code` currently exposes. Edit call returns a proposal (diff + replacement count) instead of writing immediately; a follow-up `resolve` call with a reason performs the actual write. Should not require touching `talos_core`'s tool registry contract if edits are already routed through a single tool — just add the intermediate state.
**Effort:** Small, contained to `talos_code`.
**Task file:** [task-12-preview-edit.md](task-12-preview-edit.md)

### 1.3 Role-based model routing
**Source:** omp (`default`/`smol`/`slow`/`plan`/`commit` roles, each mappable to a different model, with per-role fallback chains).
**What it does:** Instead of one model for the whole agent, different roles route to different models — cheap model for subagent fan-out, capable model for the main loop, reasoning model for planning.
**Why it's worth it:** Talos already has an OpenRouter-primary ModelProvider abstraction. This isn't new plumbing, it's a config schema change: `role -> model` map instead of a single global model setting, plus optional fallback chain per role for handling rate limits/outages.
**Implementation sketch:** Extend `talos_core`'s config to support named roles pointing at different model configs. Existing single-model setups become the `default` role with no other roles configured, backward compatible.
**Effort:** Config schema + a role-resolution lookup at call sites. Small.
**Task file:** [task-13-model-routing.md](task-13-model-routing.md)

---

## Priority 2 — Medium, touches session/memory design (sequence with Task 5)

### 2.1 retain/recall/reflect as the shape for Task 5 (Vector Memory)
**Source:** omp's Hindsight memory subsystem.
**What it does:** Splits "memory" into three explicit tool calls instead of one opaque system:
- `retain` — write a durable fact into the memory bank mid-run
- `recall` — raw similarity search over the bank, returns matches
- `reflect` — ask the memory system to synthesize an answer over the bank (an LLM call over retrieved context, not just retrieval)

**Why it's worth it:** This is not additional scope beyond what Task 5 already requires (sentence-transformers + numpy cosine similarity backend, per the existing plan) — it's the same backend exposed as three verbs instead of one. The benefit is that the model gets legible control over *what kind* of memory operation it's doing, rather than one tool that tries to guess. Recommend building Task 5 directly in this shape rather than building a single memory tool first and refactoring later.
**Implementation sketch:** Backend unchanged from what's already scoped (SQLite + sentence-transformers + numpy cosine sim, consistent with the existing xMemory subsystem's storage choice). Expose three tool-registry entries instead of one. `reflect` is the only one requiring an extra LLM call — implement `retain`/`recall` first, they're pure data operations.
**Effort:** Same order of magnitude as Task 5 already was; this changes the API shape, not the total scope.
**Not a separate task file** — folded directly into [task-05-vector-memory.md](task-05-vector-memory.md) (see cross-reference note at the top of that file). Also cross-check against [research-sqlite-vec-nim-ffi.md](research-sqlite-vec-nim-ffi.md) before implementing the storage layer.

### 2.2 Checkpoints (context pruning with report)
**Source:** omp (`checkpoint`/`rewind`).
**What it does:** Marks conversation state, later collapses exploratory context back to a concise summary — different from long-term memory. This is short-term, within-session context budget management: "prune this exploratory branch, keep what mattered."
**Why it's worth it:** Orthogonal to vector memory (Task 5) but lives in the same conceptual area (what gets kept vs. dropped from context). Worth scoping the boundary between checkpoints and vector memory now, rather than doing Task 5 in isolation and retrofitting checkpoint logic later against a memory system that wasn't designed to interoperate with it.
**Implementation sketch:** `checkpoint` marks a point in the session log. `rewind` triggers a collapse — summarize everything since the checkpoint into a compact report, discard the raw exploratory turns from active context (they can still be FTS5-searchable/archived, just not in the live context window). Needs coordination with whatever compaction logic `talos_core` already has, if any.
**Effort:** Medium — depends on how session/context-window management currently works in `talos_core`.
**Task file:** [task-14-checkpoints.md](task-14-checkpoints.md)

### 2.3 Session branching (`/tree`)
**Source:** omp.
**What it does:** Session history becomes a tree instead of a linear log — you can branch from any prior point and explore an alternate path without losing the original.
**Why it's worth it:** Useful for branch-and-compare workflows. Given Talos is currently a single-user tool, this is lower priority than 2.1/2.2 — recommend building only if there's an actual use case for it, since it adds real complexity to session/history queries (parent-pointer schema, branch-aware FTS5 search, branch-aware `history`/`search` CLI commands) for a workflow that may not get used solo.
**Implementation sketch (if pursued):** SQLite session schema needs a parent-pointer column instead of assuming one linear ordering per session. `talos_agent`'s `session`/`history` subcommands need branch-awareness.
**Effort:** Medium-to-large, mostly in `talos_agent` CLI surface and session storage schema. **Recommend deferring** until there's a concrete reason to want it.
**Task file:** [task-15-session-branching.md](task-15-session-branching.md) (status: deferred — not scheduled)

---

## Priority 3 — Bigger design decisions (sequence with Task 7 / persona system)

### 3.1 URI schemes as a universal tool interface
**Source:** omp (`pr://`, `issue://`, `agent://`, `skill://`, `conflict://` — all resolve transparently through the same `read`/`search`/`write` tools the agent already uses, instead of each integration getting its own bespoke tool).
**Why it's worth it:** Highest long-term leverage item in this report, but also the most design work. The win is collapsing N bespoke tools into "everything is addressed via `read`/`search`/`write` against a URI scheme." This dovetails directly with **Task 7 (MCP Streaming)** — if MCP resources become addressable through the same URI mechanism as local files and session artifacts, the agent gets one mental model instead of two (local-tool-shaped calls vs. MCP-shaped calls).
**Recommendation:** Scope this as part of Task 7, not as a separate task. MCP resource URIs are already close to primed for this pattern — the work is making Talos's existing `read`/`search`/`write` tools scheme-aware (dispatch on URI prefix) rather than building a new resolution layer from scratch.
**Effort:** Significant — this is a design decision about the shape of the tool registry, not a bolt-on. Do this as part of Task 7 planning, not after.
**Not a separate task file** — folded directly into [task-07-mcp-streaming.md](task-07-mcp-streaming.md) (see cross-reference note at the top of that file).

### 3.2 Advisor role
**Source:** omp. (Logan doesn't currently use this in omp but flagged it as something he probably should.)
**What it does:** A second model runs on its own context, watching every turn the primary agent takes, injecting notes (a quiet aside, a concern, or a hard blocker) inline. The primary agent sees the note and either course-corrects or explains why it won't. Runs concurrently, not as a blocking review step.
**Why it's worth it:** Catches things the primary agent rushed past, without the review model's own reasoning polluting the primary agent's context.
**Implementation sketch:** Architecturally this is a second concurrent agent session reading the same transcript, on its own context, via Talos's existing persona/delegation system — the delegation plumbing likely already covers "spin up a second agent with a role." The genuinely new part is the injection-without-persistence mechanic: the primary agent needs to see the advisor's note, but the note shouldn't become part of the primary agent's own persisted history (same problem shape as `/btw` in 1.1 — content that's visible in-context but not written to the log).
**Effort:** Medium. Mostly reuses existing persona/delegation infra; the injection mechanic is the new piece, and it's shared machinery with `/btw`, so consider building them together.
**Task file:** [task-16-advisor-role.md](task-16-advisor-role.md)

### 3.3 Task-type-specialized subagent dispatch
**Source:** oh-my-opencode fork (specialized subagents per task type — e.g. explorer, reviewer, designer — auto-dispatched rather than manually selected).
**What it does:** Automatic routing to a specialized persona based on task type, rather than the user manually picking which subagent/persona to invoke.
**Why it's worth it:** Talos already has subagents wired via the persona/delegation system. This item is specifically about *dispatch logic* — check whether delegation currently requires manually specifying which persona to use, or whether it can infer task type and route automatically. If manual selection is the current state, the value here is purely in the routing layer; no new personas or infra required, just a classifier/router step before delegation.
**Implementation sketch:** Add a lightweight routing step (could be a fast/cheap model call, or a rules-based classifier if task types are well-defined) ahead of persona dispatch in `talos_core`'s delegation system.
**Effort:** Small if delegation infra is already solid — this is a routing layer, not new capability.
**Task file:** [task-17-subagent-dispatch.md](task-17-subagent-dispatch.md)

### 3.4 Summarized reads instead of raw dumps
**Source:** omp's Rust-native tooling (structural/tree-sitter-based file summarization on `read`, rather than dumping full file contents).
**Note on framing:** The "reduce tool token spend via native Rust core" framing from omp doesn't directly transfer — Talos is already compiled Nim, not paying a fork-exec/interpreted-language tax the way TS/Python harnesses do. The actual transferable lesson is narrower: **omp's `read` tool returns summarized snippets instead of full file dumps**, and that behavior is language-independent.
**Why it's worth it:** Likely the highest-value item in this report if `talos_core`'s current `read` tool just returns raw file contents — this directly reduces context consumption on every file read, which compounds across a session.
**Implementation sketch:** Structural summarization (function/class signatures, docstrings, elision of implementation bodies beyond a relevance threshold) requires either a lightweight parser per supported language or a tree-sitter binding in Nim. Scope depends on how many languages need support — Talos's own languages (Nim, Python, Rust, C/C++) are the practical minimum.
**Effort:** Medium-large — this is the one item in this report that requires new infrastructure (a parser/summarizer) rather than reshaping existing plumbing.
**Task file:** [task-18-summarized-reads.md](task-18-summarized-reads.md)

---

## Recommended sequencing

1. **Now, in parallel with anything else:** 1.1 (`/btw`), 1.2 (preview-edits), 1.3 (model routing config) — all cheap, independent, no dependency on Task 5/7.
2. **Task 5 (Vector Memory):** build directly in the retain/recall/reflect shape (2.1). Decide the checkpoint/memory boundary (2.2) as part of the same design pass, even if checkpoints are implemented afterward.
3. **Task 7 (MCP Streaming):** fold in URI-scheme tool addressing (3.1) as part of the same design work, not as a follow-on.
4. **Whenever, no blocking dependency:** advisor role (3.2) and task-dispatch routing (3.3), both persona-system extensions.
5. **Defer unless a concrete need shows up:** session branching (2.3) — real complexity cost for a workflow that may not get used solo.
6. **Standalone infra investment, do whenever bandwidth allows:** summarized reads (3.4) — no dependency on anything else in this list, but nontrivial to build.

**Explicitly out of scope, per source review:**
- OpenCode's multi-provider breadth — not relevant, OpenRouter already covers this.
- Claude Code's plugin/distribution system — not relevant for a single-developer, single-user project; new capability gets added directly rather than packaged for distribution.

---

## Task file cross-reference

| # | Item | Task file | Status |
|---|------|-----------|--------|
| 1.1 | `/btw` ephemeral side-question | [task-11-btw-command.md](task-11-btw-command.md) | 🔴 Not started |
| 1.2 | Preview-then-accept edit workflow | [task-12-preview-edit.md](task-12-preview-edit.md) | 🔴 Not started |
| 1.3 | Role-based model routing | [task-13-model-routing.md](task-13-model-routing.md) | 🔴 Not started |
| 2.1 | retain/recall/reflect shape | folded into [task-05-vector-memory.md](task-05-vector-memory.md) | 🔴 Not started |
| 2.2 | Checkpoints | [task-14-checkpoints.md](task-14-checkpoints.md) | 🔴 Not started |
| 2.3 | Session branching | [task-15-session-branching.md](task-15-session-branching.md) | ⏸️ Deferred |
| 3.1 | URI schemes | folded into [task-07-mcp-streaming.md](task-07-mcp-streaming.md) | 🔴 Not started |
| 3.2 | Advisor role | [task-16-advisor-role.md](task-16-advisor-role.md) | 🔴 Not started |
| 3.3 | Subagent dispatch routing | [task-17-subagent-dispatch.md](task-17-subagent-dispatch.md) | 🔴 Not started |
| 3.4 | Summarized reads | [task-18-summarized-reads.md](task-18-summarized-reads.md) | 🔴 Not started |
