# Plan: Post-Fix Audit Remediation (Round 3)

**Source**: AUDIT_REPORT.md — "2026-07-24, post-fix verification pass"
**Status**: 🟢 Done (2026-07-24) — Phases 1-3 complete, 557 tests passing.
Phase 4 (two cosmetic TUI items) intentionally not done. See CHANGELOG
`[Unreleased]` "round 3" and AUDIT_REPORT.md's round-3 fix-status section.
**Baseline**: commit `6e26e6b`, 518 tests passing

Scope: everything the post-fix verification pass found open. The 11 items
already on the "explicitly deferred" list from the previous pass stay
deferred — they are not re-litigated here.

---

## Phase 1 — Regressions and broken fixes from `6e26e6b` (critical)

### 1.1 Timeout kill regression — `compile.nim` + `shell.nim`

The `setpgid`-after-spawn approach fails silently (EACCES on an already-
exec'd child under posix_spawn/vfork), the group kill then hits ESRCH, and
`waitForExit()` blocks forever. Timeouts currently kill nothing.

Fix (both files, identical structure):
- Add `poDaemon` to `startProcess` options — Nim maps this to
  `POSIX_SPAWN_SETPGROUP`, putting the child in its own process group
  atomically at spawn time. Drop the post-hoc `setpgid` call.
- Belt-and-braces: check the result of `kill(-pid, sig)`; on ESRCH fall
  back to signaling `Pid(p.processID)` directly (not negated).
- Pass an explicit timeout to the final `waitForExit(timeout)` as a
  backstop so a kill failure can never hang the caller (and the TUI)
  forever.

Tests: extend `test_shell_tool.nim`'s timeout test (and add the compile.nim
equivalent) to assert **wall-clock elapsed time** (e.g. `sleep 5` with a
200 ms timeout returns in < 2 s) and that the child is actually dead —
the current test only checks `timedOut` + a stderr substring, which is why
this regression passed CI.

### 1.2 MCP client-leak "fix" doesn't work — `mcp_tool.nim:117-140`

`result = registerMcpTools(...)` never assigns when the callee raises, so
on a partial failure `result` is still `@[]`, the `except` branch closes
`client.http`, and already-registered tools hold closures over a closed
client — the original bug, reintroduced.

Fix: change `registerMcpTools` to report progress through a channel that
survives the raise — either take `var registered: seq[string]` as an out
parameter appended to *before* each `reg.register()` call, or catch/rewrap
internally. In `registerMcpServer`'s `except`, decide cleanup from that
out-param (close the client only if it's empty). Add a test with a
registry pre-seeded to collide on tool 2 of 3, asserting tool 1 still
works and the client is not closed.

### 1.3 `parseHexInt` chunk-size guard incomplete + unbounded allocation — `llm_client.nim:415-448`

`size < 0` misses positive wraps (`parseHexInt("10000000000000005") == 5`),
and there is no upper bound, so a crafted chunk-size line triggers an eager
multi-GB `setLen` in `Socket.recv`.

Fix (one change covers both findings):
- Reject the hex string *before* parsing if it's longer than 7-8 hex
  digits (a legit chunk over 128 MiB is nonsense for this protocol).
- Enforce `size <= maxChunkSize` (constant, e.g. 8 MiB) after parsing;
  raise `LLMError`/`NetworkError` on violation instead of desyncing.
- Keep the `size < 0` check as defense in depth.

Tests: unit-test the parser with `10000000000000005`, `ffffffffffffffff`,
`100000000`, and a normal small chunk.

---

## Phase 2 — Security / consistency errors

### 2.1 Shell tool has zero permission gating — `shell.nim` + `talos_agent.nim:1107`

Shell (highest-risk tool) never consults `canUseTool`; `tools.deny =
["shell"]` is a silent no-op; non-admin allowed users get admin-equivalent
shell. Meanwhile lower-risk `file_write` is fully gated. The accepted
design was "shell exists in Discord mode", not "shell is ungated".

Fix: mirror the `file_write` pattern — `shellTool(cfg)` reads `_callerId`
from args and calls `canUseTool(callerId, "shell", cfg)` before executing,
in daemon/web registrations. CLI/TUI registrations (single local user)
keep the ungated constructor via an overload or a nil-config path, so
local usage doesn't regress. Test: denied user gets a permission error;
`tools.deny = ["shell"]` actually denies.

### 2.2 Delegation budget is a process-lifetime global — `delegate.nim` + `talos_agent.nim`

`gGlobals.delegationConfig` is decremented forever; after `maxDepth`
delegations total, daemon-wide, delegation is dead until restart.
`AgentConfig.delegation` is set per request but never read.

Fix: make the budget per-request. Snapshot the configured
`DelegationConfig` at the top of each dispatch (daemon message handler /
web request / CLI invocation) and restore it after — or better, thread the
remaining depth through the delegate call chain explicitly
(`makeDelegateTool` already builds a child config; pass
`parentRemaining - 1` down instead of mutating the global). Prefer the
explicit-threading option; it also fixes the sibling-call decrement noted
in the Info section for free (siblings share the parent's remaining depth
but don't consume it permanently).

Test: two sequential top-level requests each get a fresh budget; nested
A→B→C stops at configured depth.

### 2.3 `_callerId` leaks verbatim to remote MCP servers — `mcp_tool.nim`

Fix: in `makeMcpToolExecuteProc`, delete the `_callerId` key from the args
copy before building the JSON-RPC payload. Test: mock server asserts the
key is absent.

Also (same mechanism, other direction): `plan_executor.nim` calls the
string-args `registry.execute` overload, which never injects `_callerId`.
Not currently reachable by a gated tool, but add a comment at the
plan_executor call site documenting the gap so the next person wiring
`file_write` into `--plan` mode knows.

### 2.4 `AssertionDefect` on `.hasKey` — remaining sites

The class was fixed at one site; still reachable at:
- `mcp_client.nim`: `initialize()` (`resp["result"]` kind unchecked),
  `listTools()` ×2, `callTool()` ×2 — lines ~206-290.
- `llm_client.nim`: `chatCompletionStream`'s SSE loop (`node`, `choice`,
  `tcNode` all unchecked) and `parseResponse` (`message` kind unchecked —
  crashes on `{"message": null}`).

Fix: guard every `.hasKey`/index on external JSON with
`kind == JObject` (pattern already used at mcp_client.nim:160-168 and in
the non-streaming `parseToolCalls`). Consider a tiny helper in
`talos_core` (`proc objHasKey(n: JsonNode, k: string): bool`) to make the
guard one call and grep-able.

Tests: malformed-response cases per site: `{"result":"oops"}` for
initialize/listTools/callTool; `{"message":null}` and a non-object
`choice` for llm_client.

---

## Phase 3 — Robustness errors

### 3.1 Streaming path socket errors untyped — `llm_client.nim`

`sock.connect` and the SSE read loop propagate raw `OSError`/`IOError`
instead of the `NetworkError` the module's callers expect (the
non-streaming `doRequest` wraps them). Fix: wrap the connect + read loop
in the same catch-and-rewrap. Test: connection-refused during streaming
surfaces as `NetworkError`.

### 3.2 `persona.nim` — silent TOML syntax errors + crash on duplicate name

- `cfgError` events are `discard`ed: raise `PersonaError` with the parser's
  message instead (same fix class as config.nim's .env parsing).
- `PersonaError` from `loadPersonasFile` is uncaught at all 7
  `talos_agent.nim` call sites: wrap like `ConfigError` already is
  (`printError` + exit 2), ideally at one shared helper rather than 7
  copies.

Tests: personas file with a missing `=` raises; duplicate
`[personas.Foo]`/`[personas.foo]` produces a clean CLI error, not a stack
trace.

### 3.3 `code_runner.formatCompileResult` — truncated-vs-success priority

`success=true, truncated=true` is reported as `✗ TRUNCATED`. Fix: check
`success` first (as `formatCompileResultForTool` already does), append a
truncation note rather than making it a verdict. Update its unit test,
which currently enshrines the wrong behavior.

### 3.4 `streaming.nim` `wordWrap` — byte-based, no hard-wrap fallback

Bring it in line with the rune-based wrapping the TUI got in `6e26e6b`:
count runes against `width` and hard-wrap over-long space-free words.
Reuse the TUI's wrap helper if it can be hoisted into `talos_core`
instead of a third implementation.

---

## Phase 4 — Pre-existing low-severity TUI items (optional, do last)

- `input_bar.nim`: cursor rendered relative to the last wrapped line
  regardless of actual cursor position.
- `chat_tui.nim`: hardcoded 3-row input box; 4+ wrapped lines get
  overdrawn by the transcript.

Both are cosmetic-to-annoying, pre-existing, and isolated to the TUI.
Include only if Phases 1-3 land cleanly.

---

## Explicitly out of scope

The 11 deferred items from the 2026-07-24 remediation pass (HttpClient
per retry, web_server blocking handler / rateBuckets, permission.nim
tools.allow precedence, discord_commands gating/no-op, `{.cast(raises:
[]).}` pattern, parsePath, gcsafe alias, jsonRpcResponseId, persona
defaults footgun, maxOutputBytes<=0 semantics) remain deferred.

## Verification

- `make test` green (baseline 518) plus the new regression tests above —
  every Phase 1 item gets a test that **fails against `6e26e6b`**.
- Update AUDIT_REPORT.md checkboxes / CHANGELOG `[Unreleased]` on
  completion, per repo convention.

## Suggested commit slicing

1. Phase 1 (three regressions + their tests) — one commit.
2. Phase 2 (security/consistency) — one commit.
3. Phase 3 (robustness) — one commit.
4. Phase 4 + doc updates — one commit, optional.
