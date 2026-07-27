## NOTE: This project has been renamed from Mercury Agent to Talos Agent. All package names (mercury_core, mercury_agent, mercury_code) are now (talos_core, talos_agent, talos_code).

# Task 15: Session Branching (`/tree`)

**Status**: ⏸️ Deferred — not scheduled. Recommend building only if a concrete
use case shows up; see rationale below. Do not pick this up speculatively.
**Dependencies**: None technically, but touches the same session schema Task
5/Task 14 will touch — if this ever gets picked up, sequence it after those
land, not before.
**Complexity**: Medium-to-large
**Source**: [feature-adoption-report.md](feature-adoption-report.md) §2.3 (omp's session tree)

---

## Why this is deferred

Talos is currently a single-user tool. Session branching (explore an
alternate path from any prior point without losing the original) is a real
feature in multi-analyst or comparison-heavy workflows, but for a solo user
it adds schema and CLI complexity — parent-pointer session schema,
branch-aware FTS5 search, branch-aware `talos_agent session`/`history`
subcommands — for a workflow pattern that may never actually get used. The
source report explicitly recommends deferring this one; this file exists so
the idea isn't lost, not as a green light to build it.

## Target (if picked up)

- `talos_core/src/talos_core/memory.nim` — `sessions` table needs a
  parent-pointer column (nullable `parent_session_id` + a `branch_point`
  message id) instead of the current flat one-row-per-session model.
- `talos_agent/src/talos_agent/commands.nim` — `cmdSession`/`cmdSessions`/
  `cmdSearch` all assume a linear session; each needs branch-awareness.
- New CLI-level `/tree` command to visualize/switch branches.

## Implementation sketch (if pursued)

```sql
ALTER TABLE sessions ADD COLUMN parent_session_id TEXT;
ALTER TABLE sessions ADD COLUMN branch_point_msg_id INTEGER;
```

A branch is a new `sessions` row whose messages up to `branch_point_msg_id`
are logically inherited from `parent_session_id` (read-through, not copied)
and diverge after that point. `history`/`search` need to walk the parent
chain when reconstructing a branch's full context; FTS5 search results need
to indicate which branch(es) a match belongs to.

## Acceptance (if pursued)

- `/tree` shows the current session's branch structure.
- Branching from an earlier point in the session preserves the original
  session's subsequent messages untouched.
- `talos_agent search` results indicate which branch a match came from.
- All existing single-branch session tests still pass unmodified (a session
  with no branches is indistinguishable from today's behavior).
