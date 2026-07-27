## NOTE: This project has been renamed from Mercury Agent to Talos Agent. All package names (mercury_core, mercury_agent, mercury_code) are now (talos_core, talos_agent, talos_code).

# Task 16: Advisor Role

**Status**: 🔴 Not Started
**Dependencies**: Persona/delegation system (`talos_core/src/talos_core/persona.nim`,
`delegate.nim`) — already exists, this is an extension. Shares the
injection-without-persistence mechanic with Task 11 (`/btw`) — consider
building together.
**Complexity**: Medium
**Source**: [feature-adoption-report.md](feature-adoption-report.md) §3.2 (omp; flagged by its own author as something he "probably should" use but doesn't yet)

---

## Target

- `talos_core/src/talos_core/delegate.nim` — spinning up a second concurrent
  agent session already has a path here (`applyPersonaDelegation`,
  `useDelegationSlot`)
- `talos_core/src/talos_core/agent_loop.nim` — the primary loop needs a slot
  to receive and surface an advisor note inline, without writing it to the
  primary agent's own persisted history
- `talos_core/src/talos_core/persona.nim` — advisor is plausibly just another
  `PersonaConfig` entry (a role, in the Task 13 sense) rather than a new
  subsystem

## Current State

Persona/delegation already supports spinning up a child agent with its own
context (`makeDelegateExecuteProc` in `talos_agent.nim`, per
`AUDIT_REPORT.md`'s notes on the delegation budget/depth system). What
doesn't exist: a way for a second agent to watch the *primary* agent's
transcript turn-by-turn (rather than being explicitly invoked by the primary
agent via a `delegate` tool call) and inject a note back into the primary's
context without that note becoming part of the primary's own persisted
message history.

## Design

The advisor runs as a second agent session, concurrently, reading the same
transcript the primary agent is producing (not synchronously blocking each
primary turn — the report is explicit this should not be a blocking review
step). After each primary turn (or some other cadence — see open question
below), the advisor gets the recent transcript slice, and if it has
something to say, that note is surfaced to the primary agent as context for
its *next* turn — visible in-context, not written to `memory` as a
persisted message for the primary agent's own session.

This is the same problem shape as `/btw` (Task 11): "content the model sees
in context but that isn't part of the persisted history." Recommend
extracting whatever primitive Task 11 builds for that (skip-session-write
message injection) and reusing it here rather than building two independent
mechanisms.

## Implementation sketch

```nim
type
  AdvisorNote* = object
    turnIndex*: int
    note*: string
    severity*: enum { anAside, anConcern, anBlocker }

proc runAdvisor*(persona: PersonaConfig; transcript: seq[ChatMessage]): Option[AdvisorNote]
  ## One LLM call over the transcript slice since the last note. Runs on the
  ## advisor's own context — the advisor's reasoning never enters the
  ## primary agent's context, only the resulting note (if any) does.
```

Open questions to resolve during implementation:
- **Cadence**: every primary turn, or only when the advisor's own judgment
  says something's worth flagging (requires a first, cheap "is this worth a
  note" pass to avoid an LLM call every single turn)?
- **Concurrency model**: Talos's agent loop is currently single-threaded per
  the TUI's documented design (`chat_tui.nim`'s module doc: "single-threaded
  — the agent loop blocks during LLM calls"). A truly concurrent advisor call
  needs either a second OS thread or async scheduling — confirm which fits
  the existing threading model before committing to "concurrent, not
  blocking" as a hard requirement.
- **Where the note surfaces**: TUI-only (a visible aside in the transcript),
  or does the primary agent also need to explicitly acknowledge/respond to
  it before continuing (the report says "the primary agent sees the note and
  either course-corrects or explains why it won't" — that implies the note
  needs to actually enter the primary's *next-turn* input, not just be
  displayed to the human user).

## Acceptance

- An advisor persona can be configured and enabled for a session.
- A primary-agent turn that the advisor flags produces a visible note in the
  TUI, and the primary agent's next turn's LLM call includes that note in
  its input.
- The advisor's own reasoning/context never appears in the primary agent's
  persisted session history (verify via `talos_agent history`/`search`).
- Advisor is fully optional — sessions without an advisor persona configured
  behave identically to today.
