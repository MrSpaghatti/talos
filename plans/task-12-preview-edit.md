## NOTE: This project has been renamed from Mercury Agent to Talos Agent. All package names (mercury_core, mercury_agent, mercury_code) are now (talos_core, talos_agent, talos_code).

# Task 12: Preview-Then-Accept Edit Workflow

**Status**: 🔴 Not Started
**Dependencies**: None — independent of Task 5/7. Contained to `talos_code`.
**Complexity**: Small
**Source**: [feature-adoption-report.md](feature-adoption-report.md) §1.2 (omp's `ast_edit` → `resolve` pattern)

---

## Target

- `talos_code/src/talos_code/code_tool.nim` (`writeFileTool`, line ~184 — the
  single write-capable tool `talos_code` currently exposes)

## Current State

`writeFileTool` (and `readFileTool` at line ~134) perform an atomic write
immediately when called — there is no staging step. A bad edit from the
autonomous coding harness lands on disk with no chance to catch it first.

## Design

Split the current single `write_file` call into two tool-registry entries:

1. `write_file` (proposal mode) — computes the diff against the current file
   contents and the replacement count, returns them as the tool result, but
   does **not** write to disk. The proposal (target path, new content, diff)
   is held in memory keyed by a proposal id.
2. `resolve_edit` (new tool) — takes a proposal id and a reason string,
   performs the actual write that `write_file` used to do immediately.

Since `talos_code`'s edit path is already routed through this one tool (per
the report's assumption, confirmed here), this does not require touching
`talos_core`'s `tool_registry.nim` contract — it's a new tool plus a small
pending-state map local to `code_tool.nim` (or a new sibling module if that
gets unwieldy).

## Implementation sketch

```nim
type
  PendingEdit* = object
    path*: string
    newContent*: string
    diff*: string
    replacementCount*: int

var pendingEdits: Table[string, PendingEdit]  # proposal id -> edit

proc writeFileTool*(cfg: CodingHarnessConfig): Tool =
  ## Now stages instead of writing; returns a proposal id + diff.

proc resolveEditTool*(cfg: CodingHarnessConfig): Tool =
  ## Looks up a proposal by id, performs the sandboxed write (reusing the
  ## existing `withinSandbox`/`resolvePathSafe` checks), clears the pending
  ## entry, returns success/failure.
```

Open question to resolve during implementation: should an unresolved
proposal expire (timeout, or get discarded at end of turn) so a forgotten
`resolve_edit` call doesn't silently leave stale state across turns? Given
`talos_code` is single-session/single-run, an in-memory table cleared at
process start is probably sufficient, but confirm against how long a single
`talos_code` invocation actually runs.

## Acceptance

- Calling `write_file` no longer touches disk; it returns a diff and a
  proposal id.
- Calling `resolve_edit` with that id performs the write, identical bytes to
  what the old immediate-write `writeFileTool` would have produced.
- `resolve_edit` with an unknown/expired id returns a clear error, not a
  crash.
- Existing sandbox-escape guards (`withinSandbox`, `resolvePathSafe`) still
  apply at the `resolve_edit` write step, not just at proposal time.
- All existing `tcode_runner` tests updated for the two-step flow; new tests
  cover propose-without-resolve (no disk write) and propose-then-resolve.
