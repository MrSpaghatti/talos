## NOTE: This project has been renamed from Mercury Agent to Talos Agent. All package names (mercury_core, mercury_agent, mercury_code) are now (talos_core, talos_agent, talos_code).

# Task 14: Checkpoints (Context Pruning with Report)

**Status**: ✅ Done (2026-07-30) — shipped in `talos_core` v1.16.0
(`memory.nim` checkpoint/override primitives + new `checkpoint.nim` with
`rewindToCheckpoint`; `agent_loop.nim` builds context via `getContext`) and
wired into the TUI as `/checkpoint` and `/rewind` (`tui/chat_tui.nim`).
The "key open question" below was resolved in favor of the **persistent
representation**: collapses are `context_overrides` rows in SQLite, so
resuming a session after a rewind (same process or not, any surface)
keeps the pruned view. Raw turns are never deleted — `getHistory`/
`searchHistory` and the summary message itself stay fully searchable.
Tests: `talos_core/tests/tcheckpoint.nim` (14 checks incl. an end-to-end
assertion on the post-rewind LLM request body).
**Dependencies**: Soft dependency on Task 5 (Vector Memory) — not blocking, but
scope the checkpoint/memory boundary in the same design pass; see note below.
**Complexity**: Medium
**Source**: [feature-adoption-report.md](feature-adoption-report.md) §2.2 (omp's `checkpoint`/`rewind`)

---

## Target

- `talos_core/src/talos_core/memory.nim` (session log — needs a checkpoint
  marker concept)
- `talos_core/src/talos_core/agent_loop.nim` (context window construction —
  needs to consult checkpoint state when building the message list sent to
  the LLM)
- New CLI-level `/checkpoint` and `/rewind` commands (`talos_agent`, per the
  slash-command pattern from `plans/task-09-slash-commands.md`)

## Current State

Talos has no short-term context-budget management beyond whatever
`token_counter.nim` reports for display purposes (the TUI sidebar's `~N
tokens` estimate). There is no existing compaction/pruning logic to
coordinate with — this is new territory, not a retrofit onto something that
already trims context.

## Design

`checkpoint` marks a point in the current session's message log (just a
row/message-id reference, cheap). `rewind` (back to the most recent
checkpoint, or a named one if checkpoints get labels) triggers:

1. Summarize everything since the checkpoint into a compact report (one LLM
   call over the exploratory turns).
2. Replace those raw turns in the *active context window* sent to the LLM
   with the summary.
3. Do NOT delete the raw turns from SQLite — they stay FTS5-searchable via
   `talos_agent search`/`history`, and (once Task 5 exists) still get
   embedded for vector search. Only the live context window sent to the
   LLM on the next turn is affected.

This is explicitly orthogonal to Task 5: checkpoints are about *this
session's* live context budget, vector memory is about *cross-session*
semantic recall. The boundary: a checkpoint's summary is itself just another
message in the log, so once Task 5 lands, that summary message gets embedded
like anything else — no special-casing needed there. Confirm this holds once
Task 5's `retain`/`recall`/`reflect` shape (task-05, report §2.1) is actually
built.

## Implementation sketch

```nim
# memory.nim
proc markCheckpoint*(self: var Memory; sessionId: string): int64
  ## Returns the message id the checkpoint anchors to.

proc getMessagesSince*(self: var Memory; sessionId: string; checkpointMsgId: int64): seq[ChatMessage]
```

```nim
# agent_loop.nim (or a new checkpoint.nim in talos_core)
proc rewindToCheckpoint*(mem: var Memory; llm: LLMClient; sessionId: string;
                          checkpointMsgId: int64): ChatMessage
  ## Summarizes messages since the checkpoint via one LLM call, returns a
  ## single crSystem (or similar) summary message. Caller is responsible for
  ## using this summary message in place of the raw range when building the
  ## next turn's context — the raw messages stay in SQLite untouched.
```

Key open question: does "active context window" need a persistent
representation (e.g. a `context_overrides` table recording "messages X..Y
are collapsed, use this summary instead"), or is it purely an in-memory
concern for the current process that gets rebuilt from scratch each time
`agent_loop.nim` assembles the message list? A persistent representation
survives a restart/resume; an in-memory one is much simpler but means
resuming a session after a rewind re-includes the raw turns. Given Task 6's
`resumeSessionId` pattern already exists, lean toward persistent if the
resume path matters to this project's actual usage.

## Acceptance

- `/checkpoint` marks the current point without affecting anything yet.
- `/rewind` after some exploratory turns collapses them into one summary
  message; the next LLM call's context reflects the collapse (verify via
  token count dropping, and via a mock-server test asserting the actual
  message list sent).
- `talos_agent search`/`history` for the session still shows the raw
  (pre-collapse) turns — nothing is deleted from SQLite.
- Resuming the session (via `resumeSessionId`) after a rewind behaves
  according to whatever persistence decision was made above — documented
  explicitly, not left implicit.
