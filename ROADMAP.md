# Talos — Project Roadmap

**Last updated**: 2026-07-30
**Current state**: The "Alpha → Prod" plan (Phases 0–7) is complete. See
[STATUS.md](STATUS.md) for what that verification actually consisted of
this session — full test suite re-runs, live daemon check, CI check,
source-level feature verification. 826 tests pass across 3 packages, 0
failed. CI is green on both Nim 2.0.x and 2.2.x matrix legs in **both
repos**. The feature-adoption backlog is now fully closed: every item is
either done or deliberately deferred — the last two stragglers, task-10
(bang commands) and task-14 (checkpoints), shipped 2026-07-30 with
`talos_core` v1.16.0.

---

## ✅ Alpha → Prod plan — Phases 0–7

| Phase | Deliverable | Status |
|---|---|---|
| 0 | Land in-flight TUI sidebar/overlay work | ✅ |
| 1 | Decouple `talos_core` from Discord (in-place) | ✅ |
| 2 | Extract `talos_core` into its own repo | ✅ — `github.com/mrspaghatti/talos_core`, v1.16.0, own CI |
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
| 10 | Bang commands (`!<cmd>`) | [task-10](plans/task-10-bang-commands.md) | ✅ Done (2026-07-30) — `bang.nim` shared by REPL + TUI; output stored as `[!cmd]` system message |
| 11 | `/btw` ephemeral side-question | [task-11](plans/task-11-btw-command.md) | ✅ Done — TUI only, not Discord/CLI `ask` |
| 12 | Preview-then-accept edit workflow | [task-12](plans/task-12-preview-edit.md) | ⏸️ Deferred — `talos_code`-specific, out of scope |
| 13 | Role-based model routing | [task-13](plans/task-13-model-routing.md) | ✅ Done |
| — | URI schemes as tool interface | folded into [task-07](plans/task-07-mcp-streaming.md) | 🔴 Not done — SSE streaming (task-07's core) shipped, this unification did not |
| 14 | Checkpoints (context pruning) | [task-14](plans/task-14-checkpoints.md) | ✅ Done (2026-07-30) — `talos_core` v1.16.0 (`checkpoint.nim`, persistent `context_overrides`), TUI `/checkpoint` + `/rewind`. (Was previously mis-tracked as done once before, when only `/btw` had shipped — this time it's source- and test-verified: `tcheckpoint.nim` asserts the post-rewind LLM request body.) |
| 15 | Session branching (`/tree`) | [task-15](plans/task-15-session-branching.md) | ⏸️ Deferred — no concrete need yet |
| 16 | Advisor role | [task-16](plans/task-16-advisor-role.md) | ✅ Done |
| 17 | Subagent dispatch routing | [task-17](plans/task-17-subagent-dispatch.md) | ✅ Done |
| 18 | Summarized reads | [task-18](plans/task-18-summarized-reads.md) | ✅ Done — `talos_code`'s own read tool deliberately untouched |

## 📊 Test Suite (verified this session, full runs)

| Package | Test files | Checks | Status |
|---------|-----------|-------|--------|
| talos_core | 24 | 510 | ✅ 0 failed |
| talos_agent | 24 | 283 | ✅ 0 failed |
| talos_code | 1 | 33 | ✅ 0 failed |
| **Total** | **49** | **826** | **✅ 0 failed** |

## ⚠️ Open items

- None. task-10 and task-14 shipped 2026-07-30; task-12 (preview-edit) and
  task-15 (session branching) remain deliberately deferred, and the URI-scheme
  tool-addressing unification from task-07's design remains not-done by choice.

## 🩹 Audit findings (2026-07-29) — ✅ all 5 fixed

Source: 7-agent scorched-earth pass, source-verified. Fixed in this order,
shipped in monorepo commit `e2883e3` + `talos_core` v1.14.0 (commit
`b3b1b46`):

1. ✅ `delegate_tool.nim:168-213` — `childMem.close()` wasn't
   `defer`-protected; an exception between `newMemory` and `close()` leaked
   the SQLite handle. Daemon-mode repeated delegations → connection/FD
   exhaustion. Fixed: `close()` moved into a `defer` right after
   `newMemory`.
2. ✅ `mcp_client.nim:504-514` — SSE `run()` retried forever on any error,
   no backoff, no max-retries, no HTTP timeout. Fixed (in `talos_core`
   v1.14.0): connect/read timeouts via `withTimeout`, exponential backoff
   capped at `maxReconnectDelayMs`, gives up after `maxRetries` and logs.
3. ✅ `commands.nim` (551-556, 151-158, 213-218, 332-337, 486-505) —
   `gGlobals` was mutated field-by-field with no save/restore; in daemon
   mode an exception after the setters in one Discord event could poison
   every subsequent event. Fixed: `setAgentGlobals()` in `state.nim`
   atomically replaces `gGlobals` in one assignment; all callers
   consolidated onto it.
4. ✅ `talos_code` write/sandbox hardening — `code_tool.nim:206`'s
   `writeFileTool` used bare `writeFile` (no parent-dir creation, no
   atomic temp+rename); `talos_code.nim:109-111`'s `sandboxRoot` was
   checked for non-empty only. Fixed: `writeFileTool` now creates missing
   parent dirs and writes via temp-file+rename, matching `file_tool.nim`;
   `sandboxRoot` is now validated `isAbsolute()` and `dirExists()`.
5. ✅ LLM/stream truncation handling — `llm_client.nim:355-379` +
   `llm_stream.nim`: a truncated/disconnected body surfaced as a
   non-retryable `ProtocolError`. Fixed (in `talos_core` v1.14.0): the
   EOF-without-`[DONE]` case now raises a retryable `NetworkError`;
   `chatCompletionStream` retries with backoff, but only before the first
   content/tool-call delta has reached the caller (to avoid duplicate
   output on a stream that partially delivered).

Also fixed while closing this list out: `talos_code.nimble`'s stale
`talos_core#v1.5.0` pin. The two "whenever convenient" follow-ups are now
done too (2026-07-30): `gPendingNotes` (`advisor.nim`) is an
`OrderedTable` capped at 256 with oldest-inserted-first eviction
(`talos_core` v1.15.0), and the TUI transcript caps at 2000 entries,
trimming to the newest 1500 with `scrollOffset` clamped (`9517cdb`).
Both consumers are now pinned to `talos_core` v1.16.0 (checkpoints).
v1.15.1 carried a fix for a bug the new core CI caught on its first run:
`newMemory` set `journal_mode=WAL` before `busy_timeout`, so a concurrent
open during a write died instantly with "database is locked". The live
daemon was restarted onto the v1.15.1 build 2026-07-30; it does not need
a restart for v1.16.0 unless checkpoint support in daemon surfaces is
wanted (checkpoints are currently REPL/TUI-only).

### Beyond the 5 findings: CI reconciliation

Pushing the above surfaced a chain of four previously-hidden,
unrelated CI failures — each only became visible once the prior one was
fixed and CI ran further. All four are now fixed; see
[STATUS.md](STATUS.md#ci--repo-state--clean) for the full breakdown
(cache poisoning, a Nim-2.0.x-only process-group bug hit in two
independent files, and a missing D-Bus session for the browser tool's
CI tests). `origin/main` is green on both matrix legs as of commit
`db39637`.
