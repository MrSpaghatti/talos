# Talos — Project Roadmap

**Last updated**: 2026-07-29
**Current state**: The "Alpha → Prod" plan (Phases 0–7) is complete. See
[STATUS.md](STATUS.md) for what that verification actually consisted of
this session — full test suite re-runs, live daemon check, CI check,
source-level feature verification. 792 tests pass across 3 packages, 0
failed. CI on GitHub is currently red and 7 commits behind local `main` —
not yet reconciled.

---

## ✅ Alpha → Prod plan — Phases 0–7

| Phase | Deliverable | Status |
|---|---|---|
| 0 | Land in-flight TUI sidebar/overlay work | ✅ |
| 1 | Decouple `talos_core` from Discord (in-place) | ✅ |
| 2 | Extract `talos_core` into its own repo | ✅ — `github.com/mrspaghatti/talos_core`, v1.13.0 |
| 3 | Stand up the Discord daemon for real | ✅ — live via systemd, confirmed running |
| 4 | Ambience (proactive, personality, continuity, TUI flare, commands) | ✅ mostly — see gaps below |
| 5 | Email + browser tools | ✅ |
| 6 | Task 5 (Vector Memory) + Task 7 (MCP Streaming) | ✅ mostly — see gaps below |
| 7 | Remaining feature-adoption backlog (13/16/17/18) | ✅ |
| 8 | Documentation accuracy pass | ✅ this document |

Phase 4 and Phase 6 shipped their core deliverables but not every sub-item
inside them — see "Feature Adoption Backlog" below for the honest per-item
breakdown rather than a blanket phase checkmark.

## 🗺️ Original 7 long-horizon tasks

| # | Task | Status |
|---|------|--------|
| 1 | Agent Loop + Dispatcher | ✅ Done |
| 2 | Streaming Responses | ✅ Done (CLI streaming; Discord uses a typing indicator, not progressive edits) |
| 3 | Web UI | ✅ Done (non-streaming) |
| 4 | Code Quality | ✅ Done |
| 5 | Vector Memory | ✅ Done — `retain`/`recall`/`reflect` tools, brute-force cosine, hybrid FTS5+semantic search |
| 6 | Plan-Execute Mode | ✅ Done |
| 7 | MCP Streaming | ✅ Done (SSE + streamable-HTTP transport, `tool_list_changed`) — the URI-scheme tool-addressing unification recommended alongside it did **not** land, see below |

## 🔭 Feature Adoption Backlog (sourced 2026-07-25)

Full rationale in [plans/feature-adoption-report.md](plans/feature-adoption-report.md).

| # | Item | Task file | Status |
|---|------|-----------|--------|
| 9 | Slash commands | [task-09](plans/task-09-slash-commands.md) | 🟡 Partial — real, working, but ad hoc inside `chat_tui.nim` (not the standalone module the spec called for), TUI-only |
| 10 | Bang commands (`!<cmd>`) | [task-10](plans/task-10-bang-commands.md) | 🔴 Not started |
| 11 | `/btw` ephemeral side-question | [task-11](plans/task-11-btw-command.md) | ✅ Done — TUI only, not Discord/CLI `ask` |
| 12 | Preview-then-accept edit workflow | [task-12](plans/task-12-preview-edit.md) | ⏸️ Deferred — `talos_code`-specific, out of scope |
| 13 | Role-based model routing | [task-13](plans/task-13-model-routing.md) | ✅ Done |
| — | URI schemes as tool interface | folded into [task-07](plans/task-07-mcp-streaming.md) | 🔴 Not done — SSE streaming (task-07's core) shipped, this unification did not |
| 14 | Checkpoints (context pruning) | [task-14](plans/task-14-checkpoints.md) | 🔴 **Not done** — previously mis-tracked as complete alongside `/btw`; verified absent from `memory.nim`/`agent_loop.nim`/CLI this session |
| 15 | Session branching (`/tree`) | [task-15](plans/task-15-session-branching.md) | ⏸️ Deferred — no concrete need yet |
| 16 | Advisor role | [task-16](plans/task-16-advisor-role.md) | ✅ Done |
| 17 | Subagent dispatch routing | [task-17](plans/task-17-subagent-dispatch.md) | ✅ Done |
| 18 | Summarized reads | [task-18](plans/task-18-summarized-reads.md) | ✅ Done — `talos_code`'s own read tool deliberately untouched |

## 📊 Test Suite (verified this session, full runs)

| Package | Test files | Checks | Status |
|---------|-----------|-------|--------|
| talos_core | 22 | 489 | ✅ 0 failed |
| talos_agent | 23 | 271 | ✅ 0 failed |
| talos_code | 1 | 32 | ✅ 0 failed |
| **Total** | **46** | **792** | **✅ 0 failed** |

## ⚠️ Open items

- **Push the 7 local commits and get CI green on `origin/main`** — currently
  red on the last pushed commit (a `shell.nim` ACL type-mismatch that
  appears already fixed locally but hasn't been reconciled with GitHub).
- **Give `talos_core` its own CI workflow** — it currently has none.
- Decide the fate of task-10 (bang commands) and task-14 (checkpoints):
  pick them back up, or formally defer them the way task-12/task-15 already
  are, instead of leaving them in limbo.

## 🩹 Audit findings (2026-07-29), ranked

Source: 7-agent scorched-earth pass, source-verified. Fix in this order:

1. `delegate_tool.nim:168-213` — `childMem.close()` isn't `defer`-protected;
   an exception between `newMemory` and `close()` leaks the SQLite handle.
   Daemon-mode repeated delegations → connection/FD exhaustion. One-line fix:
   move `close()` into a `defer` right after `newMemory`.
2. `mcp_client.nim:504-514` — SSE `run()` retries forever on any error, no
   backoff, no max-retries, no HTTP timeout. A dead MCP server becomes an
   invisible infinite loop with unbounded connection churn. Needs a
   retry cap, backoff, and a timeout on `newAsyncHttpClient()`.
3. `commands.nim` (551-556, 151-158, 213-218, 332-337, 486-505) — `gGlobals`
   is mutated with no save/restore; in daemon mode an exception after the
   setters in one Discord event poisons every subsequent event (e.g. a
   maxed-out delegation depth or dead LLM client leaks into the next user's
   turn).
4. `talos_code` write/sandbox hardening — `code_tool.nim:206`'s
   `writeFileTool` uses bare `writeFile` (no parent-dir creation, no
   atomic temp+rename, corrupts on partial write) where `file_tool.nim`
   already does this correctly; `talos_code.nim:109-111`'s `sandboxRoot`
   is checked for non-empty only, not `isAbsolute`/`dirExists`, so a
   relative root plus a CWD change can produce a real sandbox escape.
5. LLM/stream truncation handling — `llm_client.nim:355-379` +
   `llm_stream.nim`: a truncated/disconnected body surfaces as a
   non-retryable `ProtocolError` instead of a retryable network error;
   `[DONE]` is matched with exact string equality so trailing bytes after
   it are silently dropped, losing a server-side error.

Also worth doing whenever convenient: `talos_code.nimble` still pins
`talos_core#v1.5.0` (stale — everything actually resolves against
v1.13.0, but a clean install would break on this); and `gPendingNotes`
(`advisor.nim`) plus `transcript.entries` (`chat_tui.nim`'s TUI) both grow
unbounded in long-running processes and want a cap/TTL.
