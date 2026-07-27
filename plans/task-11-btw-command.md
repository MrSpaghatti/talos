## NOTE: This project has been renamed from Mercury Agent to Talos Agent. All package names (mercury_core, mercury_agent, mercury_code) are now (talos_core, talos_agent, talos_code).

# Task 11: `/btw` — Ephemeral Side-Question

**Status**: 🔴 Not Started
**Dependencies**: None — independent of Task 5/7.
**Complexity**: Small (~1 hour per source report)
**Source**: [feature-adoption-report.md](feature-adoption-report.md) §1.1 (omp slash commands)

---

## Target

- `talos_agent/src/talos_agent/commands.nim` (`cmdChat`/`cmdAsk` turn path)
- `talos_agent/src/talos_agent/tui/chat_tui.nim` (slash command dispatch — see `plans/task-09-slash-commands.md`)
- `talos_core/src/talos_core/agent_loop.nim` (turn execution — read-only path, no changes expected)

## Current State

Every turn goes through the normal agent loop, which appends both the user
message and the assistant's reply to the session via `memory.appendMessage`
(see Task 6/plan_executor's `ensureSession` pattern for the equivalent
session-write path). There is no way to ask the model something using the
current context without that exchange becoming a permanent part of the
session — it always lands in SQLite, gets FTS5-indexed, and will later be
picked up by Task 5's vector memory indexing too.

## Design

`/btw <question>` runs the question through the same LLM call path as a
normal turn (same system prompt, same message history up to this point) but
skips the session-write step entirely — neither the question nor the answer
is appended to `memory`. The exchange is visible in the TUI transcript for
the current process only; it does not survive a restart, does not show up in
`talos_agent search`/`talos_agent history`, and (once Task 5 exists) is never
embedded.

Key implementation question to resolve during this task: does `/btw` need
its own answer to persist *within* the live in-memory context for the rest of
the current process (so the agent could reference "the thing I just asked
about" later in the same session), or is it fully throwaway? The report
frames it as "the model sees it in current context" for that one exchange —
recommend NOT injecting the `/btw` Q&A into the history array used for
subsequent turns, since that reintroduces the persistence problem one level
up (it would still be there implicitly via context, just not in SQLite).
Simplest correct implementation: build the message list for this one call as
`[...existing history without a write-back, new user question]`, discard the
constructed list after the call returns.

Note the overlap with **advisor role** (report §3.2,
[task-16-advisor-role.md](task-16-advisor-role.md)) — both need "model output
visible in the transcript, not persisted to history." Worth building the
non-persisting-message-display primitive once and reusing it for both.

## Implementation sketch

- CLI-level: a slash command (`/btw <question>`) in the TUI's slash-command
  dispatch, not a change to `talos_core`'s `runAgentLoop`.
- Reuses `buildLLMClient`/`AgentConfig` already constructed for the session;
  no new LLM plumbing.
- Skip whatever call currently appends to `memory` for this one exchange —
  identify that call site in `agent_loop.nim`'s turn execution and add a
  `persist: bool` (or equivalent) knob, defaulting `true` for normal turns.

## Acceptance

- `/btw what does line 47 do?` gets an answer rendered in the TUI transcript.
- After a `/btw` exchange, `talos_agent search`/`talos_agent history` for the
  current session does NOT show the `/btw` question or answer.
- A normal (non-`/btw`) turn immediately after still sees full prior context
  as if the `/btw` exchange had never happened.
- All existing tests pass; new test(s) confirm no session write occurs for
  `/btw`.
