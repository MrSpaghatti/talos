## NOTE: This project has been renamed from Mercury Agent to Talos Agent. All package names (mercury_core, mercury_agent, mercury_code) are now (talos_core, talos_agent, talos_code).

# Task 17: Task-Type-Specialized Subagent Dispatch

**Status**: 🔴 Not Started
**Dependencies**: Persona/delegation system (`talos_core/src/talos_core/persona.nim`,
`delegate.nim`) — already exists, this is purely a routing-layer addition on
top of it.
**Complexity**: Small (if delegation infra is solid, per source report)
**Source**: [feature-adoption-report.md](feature-adoption-report.md) §3.3 (oh-my-opencode fork — explorer/reviewer/designer-style auto-dispatched subagents)

---

## Target

- `talos_core/src/talos_core/delegate.nim` — the `delegate` tool call path
  currently requires the caller (the primary agent, via a tool call) to name
  which persona to delegate to explicitly.
- `talos_core/src/talos_core/persona.nim` — persona registry lookup, unchanged
  in shape, just gains a router in front of it.

## Current State

**First step of this task is verification, not implementation**: confirm
whether `delegate` currently requires the LLM to explicitly name a target
persona in its tool call arguments, or whether there's already some inference
happening. (Per the report: "check whether delegation currently requires
manually specifying which persona to use, or whether it can infer task type
and route automatically. If manual selection is the current state, the value
here is purely in the routing layer.") Grep `delegate.nim`'s tool schema /
`makeDelegateTool`'s argument definition to confirm before scoping further.

## Design (assuming manual selection is confirmed as current state)

Add a routing step ahead of persona dispatch: given the delegation request's
task description, either

- a cheap/fast model call (reuse Task 13's role-routing, if that lands first
  — route this classification call through a `smol`-style cheap role), or
- a rules-based classifier if the task types in use are well-defined and
  stable (e.g. keyword/pattern matching against task description text)

...to pick which registered persona should actually handle the delegation,
rather than requiring the primary agent's own tool call to name one. The
primary agent's tool call can still optionally specify a persona explicitly
(manual override) — the router only kicks in when it doesn't.

## Implementation sketch

```nim
proc routeToDelegate*(reg: PersonaRegistry; taskDescription: string;
                      explicitPersona: string = ""): string =
  ## Returns the persona name to delegate to. If `explicitPersona` is set,
  ## returns it unchanged (manual override always wins). Otherwise classifies
  ## `taskDescription` against the registered personas' declared specialties
  ## and returns the best match, falling back to a configured default
  ## persona if no match clears some confidence threshold.
```

This requires personas to declare what task types they're suited for —
check whether `PersonaConfig` has anything like this already (a
description/specialty field) or whether that's new surface area on the
config schema.

## Acceptance

- A `delegate` call with no explicit persona specified gets routed to a
  sensible persona based on task description (test with a few representative
  task descriptions against a small set of registered personas: explorer-
  style, reviewer-style, generic).
- A `delegate` call with an explicit persona specified still uses exactly
  that persona — the router never overrides an explicit choice.
- No match above the confidence threshold falls back to a configured default
  persona (or an error, if no default is configured — decide which during
  implementation and document it).
- Existing delegation tests (`tdelegate_tool.nim`, `test_persona.nim`) pass
  unmodified for callers that always specify a persona explicitly.
