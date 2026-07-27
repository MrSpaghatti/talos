## NOTE: This project has been renamed from Mercury Agent to Talos Agent. All package names (mercury_core, mercury_agent, mercury_code) are now (talos_core, talos_agent, talos_code).

# Task 18: Summarized Reads Instead of Raw Dumps

**Status**: 🔴 Not Started
**Dependencies**: None. Standalone infrastructure investment — no dependency
on Task 5/7 or anything else in the feature-adoption backlog.
**Complexity**: Medium-large (the one item in the report requiring genuinely
new infrastructure — a parser/summarizer — rather than reshaping existing
plumbing)
**Source**: [feature-adoption-report.md](feature-adoption-report.md) §3.4 (omp's tree-sitter-based structural file summarization)

---

## Target

- `talos_core/src/talos_core/file_tool.nim` (`read_file`-equivalent tool for
  the Discord/general-agent path — verify exact proc name before starting)
- `talos_code/src/talos_code/code_tool.nim` — `readFileTool` (line ~134)

## Current State

**Verify before scoping further**: confirm both read tools currently return
full raw file contents with no summarization or truncation beyond whatever
size caps already exist (`code_tool.nim`'s sandbox/size guards, per
`AUDIT_REPORT.md`'s notes on `withinSandbox`). If that's confirmed, this is
the highest-value item in the whole report per the source review — every
file read the agent does currently spends full-file tokens, and that
compounds across a session.

## Framing note (from the source report)

The omp framing ("native Rust core reduces token spend vs. TS/Python
harnesses") doesn't transfer — Talos is already compiled Nim, not paying an
interpreted-language tax. The actual transferable lesson is narrower and
language-independent: **the `read` tool itself returns summarized snippets
instead of full dumps**, regardless of what language implements the tool.

## Design

Structural summarization: for a file above some size/line threshold, `read`
returns function/class signatures, docstrings, and top-level structure, with
implementation bodies elided beyond a relevance threshold, rather than the
full file. A full-content mode should remain available (either as a
parameter on the same tool, or the model can follow up with a more targeted
read) for when the agent genuinely needs to see an elided body.

## Implementation sketch

Two paths, in increasing order of investment:

1. **Tree-sitter binding in Nim** — most correct, handles multiple languages
   uniformly, but tree-sitter has no first-class Nim binding today (same gap
   `research-sqlite-vec-nim-ffi.md` found for sqlite-vec) — would need a
   similar FFI-shim investigation before committing to this path. Scope
   depends on how many languages need support; Talos's own languages (Nim,
   Python, Rust, C/C++) are the practical minimum, not "every language."
2. **Lightweight per-language heuristic parser** — regex/indentation-based
   signature extraction per supported language (much cheaper to build, less
   robust, but avoids the FFI investigation). Reasonable starting point given
   only ~4 languages need covering.

Recommend a short research pass (mirroring
[research-sqlite-vec-nim-ffi.md](research-sqlite-vec-nim-ffi.md)'s format) to
decide between these two before writing the actual implementation plan —
this task file intentionally stops short of committing to one, since that
decision has real long-term maintenance implications (a tree-sitter FFI shim
vs. N hand-rolled heuristic parsers).

## Acceptance

- Reading a large source file (above the size threshold) returns a
  structural summary — signatures/docstrings, not full bodies — and the
  summary is meaningfully smaller in token count than the raw file.
- A full-content read is still available when needed (explicit parameter or
  follow-up call).
- Summarization threshold is configurable (files below it are still returned
  in full — no point summarizing a 20-line file).
- Covers Nim at minimum (Talos's own primary language); document which other
  languages are covered vs. deferred.
- All existing `code_tool`/`file_tool` tests pass for files under the
  threshold (behavior unchanged for small files).
