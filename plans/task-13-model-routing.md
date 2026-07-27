## NOTE: This project has been renamed from Mercury Agent to Talos Agent. All package names (mercury_core, mercury_agent, mercury_code) are now (talos_core, talos_agent, talos_code).

# Task 13: Role-Based Model Routing

**Status**: 🔴 Not Started
**Dependencies**: None — independent of Task 5/7.
**Complexity**: Small
**Source**: [feature-adoption-report.md](feature-adoption-report.md) §1.3 (omp's `default`/`smol`/`slow`/`plan`/`commit` roles)

---

## Target

- `talos_core/src/talos_core/config.nim` — `TalosConfig` (currently a single
  `provider`/`openrouterModel`/`vllmModel` triple, no per-role concept)
- `talos_core/src/talos_core/build_llm_client.nim` — `TalosConfig → LLMClient`
  builder (single call site today; becomes a role-parameterized lookup)
- Call sites that currently assume one global model: `cmdChat`/`cmdAsk`
  (`talos_agent/src/talos_agent/commands.nim`), delegation/persona child-agent
  construction (`talos_core/src/talos_core/delegate.nim`,
  `persona.nim`), `plan_executor.nim` (planning step could reasonably use a
  different role than execution steps)

## Current State

`TalosConfig` has exactly one model per provider (`openrouterModel`,
`vllmModel`) — every call in the process, including delegated child agents
and plan-execute's planning vs. execution phases, uses the same model. There
is no fallback chain for rate limits/outages beyond `llm_client.nim`'s
existing retry/backoff on the single configured endpoint.

## Design

Add a named-role model map to config:

```toml
[roles.default]
provider = "openrouter"
model = "openrouter/auto"

[roles.plan]
provider = "openrouter"
model = "anthropic/claude-opus-4"

[roles.smol]
provider = "openrouter"
model = "openrouter/auto:cheap"
fallback = ["openrouter/some-other-cheap-model"]
```

Existing single-model configs (the overwhelming majority of current setups,
including every test fixture) become the `default` role with no other roles
configured — this must be fully backward compatible, since 557+ existing
tests construct `TalosConfig` directly without any notion of roles.

## Implementation sketch

```nim
type
  ModelRoleConfig* = object
    provider*: string
    model*: string
    fallback*: seq[string]      ## additional models to try in order

  TalosConfig* = object
    # ... existing fields unchanged ...
    roles*: OrderedTable[string, ModelRoleConfig]  ## empty = only `default`

proc resolveRole*(cfg: TalosConfig; role: string): ModelRoleConfig =
  ## Falls back to the config's existing single-model fields (built as an
  ## implicit `default` role) if `role` isn't configured, so callers that
  ## don't care about roles keep working unmodified.

proc buildLLMClient*(cfg: TalosConfig; role = "default"): LLMClient =
  ## Existing signature gains an optional `role` param, defaulting to
  ## today's behavior.
```

Fallback-chain behavior (trying the next model in `fallback` on
`RateLimitError`/`ServerError`) should reuse `llm_client.nim`'s existing
retry classification rather than inventing a second error-triage path —
confirm which specific errors should trigger a fallback vs. which should
still just retry the same model.

## Acceptance

- A `TalosConfig` with no `[roles.*]` sections behaves identically to today
  (single global model) — all existing tests pass unmodified.
- A config with `[roles.plan]` set routes `plan_executor.nim`'s plan-
  generation call through that role's model while step-execution calls keep
  using `default`.
- A role with a configured `fallback` chain retries the next model in the
  list on a rate-limit/server error from the first, and this is covered by a
  mock-server test (extend the existing `mock_server.nim` pattern).
- Delegation/persona child agents can specify a role (e.g. `smol` for
  cheap subagent fan-out) via `PersonaConfig`, defaulting to `default` if
  unset.
