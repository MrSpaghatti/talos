# Research: sqlite-vec + Nim FFI

**Date**: 2026-07-24
**Context**: Scouting how to add vector search to `talos_core/memory.nim`, which
explicitly lists "Vector / embedding search" as deferred. Relates directly to
[task-05-vector-memory.md](task-05-vector-memory.md), which currently plans a
brute-force cosine-similarity approach (load all embeddings into Nim, compute
similarity by hand). This note evaluates using
[sqlite-vec](https://github.com/asg017/sqlite-vec) instead of/alongside that.

Not a plan, not implemented — just findings, to align on before writing a plan.

---

## Summary

No Nim binding for sqlite-vec exists (checked: official bindings cover Python,
Rust, Go, Ruby, Swift; nothing for Nim). It has to be wired up by hand via FFI,
but the surface area needed is tiny — 1-2 `importc` procs — because Talos
already goes through `db_connector/db_sqlite`, and everything past connection
setup is plain SQL against the `vec0` virtual table.

## Why this is easy in Talos specifically

- `talos_core/memory.nim` uses `db_connector/db_sqlite`.
- `db_sqlite` itself is a thin FFI layer: it dynlibs the system
  `libsqlite3.so(|.0)` at runtime (see
  `db_connector/sqlite3.nim`, `{.pragma: mylib, dynlib: Lib.}`).
- `DbConn` is literally `ptr Sqlite3` — the raw `sqlite3*` handle, not an
  opaque wrapper.
- Confirmed on this machine: system `libsqlite3.so.0` (Arch/CachyOS) is built
  with extension-loading support compiled in.

Because of this, you can declare your own `importc` proc against the *same*
dynlib name db_sqlite already uses, and call it directly on a `DbConn`:

```nim
proc sqlite3_enable_load_extension(db: DbConn, onoff: cint): cint
  {.cdecl, importc, dynlib: "libsqlite3.so(|.0)".}
```

Then at connection setup:

```nim
discard sqlite3_enable_load_extension(db, 1)
db.exec(sql"SELECT load_extension(?)", "/path/to/vec0")
```

Extension loading is disabled by default for library consumers of the SQLite
C API (the `sqlite3` CLI enables it for itself internally — a local sanity
check via the CLI succeeded but that doesn't reflect the library default). The
explicit `sqlite3_enable_load_extension` call is required.

After that, everything is normal SQL, no further FFI:

```sql
CREATE VIRTUAL TABLE vec_items USING vec0(embedding float[384]);
INSERT INTO vec_items(rowid, embedding) VALUES (?, ?);   -- packed f32 blob, or vec_f32('[...]') from JSON text
SELECT rowid, distance FROM vec_items WHERE embedding MATCH ? AND k = 10 ORDER BY distance;
```

## Two integration paths

1. **Runtime-loadable extension (recommended fit for Talos)**
   Download the prebuilt `vec0.so` (linux-x86_64) from sqlite-vec's GitHub
   releases, or build it from the amalgamation source. Ship it alongside the
   binary, load it with the two lines above. No build-system changes, matches
   how `memory.nim` already talks to SQLite.

2. **Static linking**
   Vendor `sqlite-vec.c`/`.h` (single-file amalgamation), compile into the
   binary with `{.compile: "sqlite-vec.c".}`, register globally via
   `sqlite3_auto_extension(sqlite3_vec_init)` before any `sqlite3_open` call.
   More portable (no separate `.so` to distribute, sidesteps
   extension-loading permission questions on locked-down systems) but needs a
   C compile step and its own `sqlite3_vec_init` entry point rather than
   riding on the dynlib's export table. This is the pattern Go/Rust bindings
   use when *they* statically link sqlite3 — less natural here since Talos
   depends on the dynamic system lib already.

**Recommendation**: path 1, given Talos's existing dynlib-based setup.

## Version / environment notes

- Latest stable sqlite-vec: **v0.1.9**. v0.1.10-alpha (adds DiskANN support)
  is prerelease, not yet stable.
- Nim 2.2.10 here has no compatibility issues — plain `importc`/`dynlib`.
- System `libsqlite3.so.0` confirmed to support `load_extension` at the C
  level on this machine.

## Relation to task-05-vector-memory.md

Task 5 (Phase 5b/5c) currently plans: store embeddings as raw BLOBs in a
plain table, load them all into Nim, and compute cosine similarity by hand.
sqlite-vec's `vec0` virtual table would replace that with an actual ANN
index inside SQLite — avoids the "load every embedding into memory and loop"
approach, which won't scale past a small number of stored messages. Worth
revisiting Phase 5b/5c against this before implementation starts.

## Open questions for the actual plan

- Which embedding dimensionality/model (ties into Phase 5a's `EmbeddingClient`
  design already sketched in task-05).
- Whether to vendor the `vec0.so` binary in-repo or fetch/build it at setup
  time.
- Whether `sqlite3_enable_load_extension` should be called unconditionally in
  `memory.nim`'s connection setup, or gated behind the same
  `memory.auto_embed` config flag task-05 proposes.
