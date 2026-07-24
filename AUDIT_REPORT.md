# NOTE: This project has been renamed from Mercury Agent to Talos Agent.

# Audit Report — 2026-07-22

Deep-dive audit covering all source modules across 3 packages (479 tests
passing). Five parallel scout agents reviewed: core agent loop/dispatcher/
memory/config, Discord/security modules, agent CLI + coding harness, LLM
client + MCP, and TUI + rename remnants. All findings below were verified
against actual source code.

## Errors (actual bugs)

- [ ] **agent_loop.nim:347 — `resp.toolCalls[^1]` crash on empty toolCalls**
  If `finishReason == "tool_calls"` but `resp.toolCalls.len == 0`, `isToolCallTurn`
  is true, the for loop doesn't execute (no new history entries), but `detectLoop`
  can fire from accumulated history. `resp.toolCalls[^1]` then crashes with
  index out of bounds. Fix: guard with `resp.toolCalls.len > 0` or use a
  generic stop message.

- [ ] **thread_mapping.nim:81,105,114 — `row[0]` on empty seq from db.getRow**
  `db.getRow` returns `@[]` when no rows match. Accessing `row[0]` crashes
  with index out of bounds. Affects `getSessionForThread`,
  `getLatestSessionForChannel`. Fix: check `row.len > 0` before `row[0]`.

- [ ] **talos_agent.nim:312-319 — delegation config not restored on exception**
  `gGlobals.delegationConfig` is swapped to `childCfg.delegation` at line 313
  and restored at line 319, but if `childReg.register(shellTool())` or
  `makeDelegateTool()` throws between those lines, `savedDc` is never
  restored. Corrupts all subsequent delegations. Fix: `defer:
  gGlobals.delegationConfig = savedDc`.

- [ ] **talos_agent.nim:993 — cmdWeb `mem.close()` not protected by defer**
  `mem.close()` at line 1015 is only reached on normal exit. If
  `serveUntilInterrupted()` throws, the SQLite handle leaks. Fix: `defer:
  mem.close()` after line 993.

- [ ] **mcp_tool.nim:121-132 — MCP client closed after partial tool registration**
  If `registerMcpTools` throws after partially registering tools, the error
  handler closes `client.http`, but already-registered tools hold closures
  pointing to the now-closed client. Agent will get errors calling those
  tools. Fix: roll back registered tools on error, or don't close the client
  if any tools were registered.

- [ ] **talos_code.nim:84 — extension list parsing doesn't trim whitespace**
  `extEnv.split(',')` without `.strip()` means `"  .nim , .c  "` produces
  `["  .nim ", " .c  "]` which won't match file extensions. Fix:
  `extEnv.split(',').mapIt(it.strip())`.

- [ ] **llm_client.nim:505 — `parseInt(parsed.port)` not wrapped in try/except**
  Streaming SSE path crashes on non-numeric port. The non-streaming path
  uses `newHttpClient` which handles this internally. Fix: wrap in try/except
  or use `parseInt` with a fallback.

- [ ] **config.nim:529-541 — .env parseFloat/parseInt failures silently discarded**
  Malformed numeric values in `.env` are silently ignored (`discard`), unlike
  OS env vars (`applyEnvVars`) which raise `ConfigError`. Inconsistent and
  confusing. Fix: raise ConfigError on parse failure in .env parsing too.

- [ ] **test_config.nim:1, talos_core/test_simple.nim:1 — stale `mercury_core` imports**
  These standalone test files import `mercury_core/config` and
  `mercury_core/llm_client`, which don't exist after the rename. Not in the
  test suite but will confuse anyone who tries to run them. Fix: update
  imports or delete if unused.

- [ ] **tcli.nim, tintegration.nim — tests use deprecated `MERCURY_*` env vars**
  Tests use `MERCURY_PROVIDER`, `MERCURY_DB_PATH`, `MERCURY_MAX_TOKENS` etc.
  They work via backward-compat fallbacks but trigger deprecation warnings
  on every run. Fix: update to `TALOS_*`.

## Inefficiencies

- [ ] **memory.nim:354 — `listSessions` correlated subquery is O(n²)**
  `(SELECT COUNT(*) FROM messages ms WHERE ms.session_id = s.id)` runs per
  session. Should use `LEFT JOIN messages m ON m.session_id = s.id GROUP BY
  s.id`.

- [ ] **shell.nim:163 / compile.nim:23 — duplicated `setNonBlocking`/`drainAvailable`**
  Identical POSIX I/O helpers copy-pasted in two files. Maintenance risk if
  one is fixed and the other isn't. Should be shared.

- [ ] **rate_limit.nim:70, llm_client.nim:345 — exponential backoff can overflow**
  `(1 shl (attempt - 1))` overflows at attempt=32 (32-bit) or 64 (64-bit).
  No upper cap on backoff delay. Fix: `min(attempt, 30)` or cap the sleep.

## Not bugs (verified safe)

- `agent_dispatcher.nim:76` — `dbPath` IS expanded: the daemon calls
  `resolveDbPath(cfg)` at line 1130 before passing to the dispatcher.
- `llm_client.nim:635-637` — `toolCallId` overwrite is correct: index is a
  temporary placeholder, real id takes precedence when it arrives.
- `llm_client.nim:361-363` — retry error type is correct: Nim preserves the
  actual object type (`NetworkError`) when raising via a `ref LLMError` variable.
- `mcp_tool.nim:135` — client captured in closures is kept alive by ORC;
  not a use-after-free on the success path.

## Style / Consistency

- [ ] **discord_types.nim:9 — hardcoded deny list duplicates file_path_validator patterns**
  `defaultDiscordConfig` hardcodes a deny list that overlaps with
  `file_path_validator`'s mandatory patterns. Should reference the shared list.
- [ ] **config.nim:144-193 — repetitive MERCURY_* backward-compat code**
  ~20 identical fallback patterns. Could be a macro or table-driven.
- [ ] **.gitignore:49 — stale `mercury_code` entry**
  References old binary name. Already covered by `talos_code` pattern.

## Info (observations, not action items)

- DI design in discord.nim is sound — callback injection avoids dimscord
  generics/async limitations.
- Shell tool pipe handling (incremental drain) correctly prevents deadlock
  on large output (>64 KiB).
- CSRF guard in web_server.nim is correct — Origin header check + loopback binding.
- `withinSandbox` in code_tool.nim is solid — resolvePathSafe + fail-closed.
- TUI terminal cleanup is correct — try/finally with illwillDeinit().
- All SQL queries use parameterized statements (?). No SQL injection.
- No hardcoded secrets detected.

---

# Audit Report — 2026-07-22 Task 6 (Plan-Execute Mode)

Deep-dive audit of the new `plan_executor.nim` module and CLI wiring in
`talos_agent.nim`. All findings verified against source. 7 fixes applied
(Batches 1-3); 1 deferred (Batch 4: streaming test needs mock SSE support).

## Errors (actual bugs) — all fixed

- [x] **plan_executor.nim:193 — `generatePlan` passed OpenAI `tools` parameter**
  `params["tools"] = registry.toOpenAIDefinitions()` could cause real LLMs to
  respond with `tool_calls` instead of JSON plan text, triggering
  `PlanError("LLM returned empty plan response")`. Removed — system prompt
  already lists tool names as text.

- [x] **talos_agent.nim:621 — double-printing final answer in streaming mode**
  `executePlan` streamed synthesis via `streamCallback`, then `cmdAsk` printed
  `planRes.finalAnswer` again. Fixed: only print in `noStream` mode; emit
  trailing newline otherwise.

- [x] **plan_executor.nim:444-446 — synthesis logged zero token usage**
  `memory.appendMessage(..., tokensIn = 0, tokensOut = 0)` hardcoded zeros.
  Fixed: restructured to single `var resp` and use `resp.usage` values.

- [x] **plan_executor.nim:351 — `ToolNotFoundError` uncaught**
  `registry.execute` raises `ToolNotFoundError` for unregistered tools.
  Aborted entire plan instead of marking step failed. Fixed: wrapped in
  try/except `ToolError`, marks step failed and skips dependents.

## Inefficiencies — fixed

- [x] **plan_executor.nim:242 — `topoSort` O(n) queue deletion**
  `queue.delete(0)` shifts all elements. Replaced with index pointer.

## Style / Consistency — fixed

- [x] **plan_executor.nim:230 — `topoSort` raised `KeyError` on invalid deps**
  `idToIdx[dep]` raised `KeyError` for direct callers bypassing `parsePlan`.
  Fixed: `hasKey` guard raises `PlanError` with descriptive message.

## Feature gap — fixed

- [x] **talos_agent.nim — no real-time step status display**
  Task spec required "Show step status in real-time". Added `stepCallback`
  parameter to `executePlan`; CLI prints `formatStepStatus` after each step.

## Test coverage gap — deferred

- [ ] **Streaming synthesis path untested** — Tests use
  `defaultAgentConfig()` with `streamCallback = nil`. The streaming path
  (`chatCompletionStream` for synthesis) is never exercised. Requires mock
  server SSE format support.

---

# Audit Report — 2026-07-24

Full re-audit across all three packages plus the test suite/docs, done via
five parallel scout agents (core loop/config/memory/plan-executor,
Discord/permissions/sandboxing, CLI/TUI/coding-harness, LLM
client/MCP/delegation, and test-suite/docs consistency). All findings
verified against actual source. Documentation only — nothing below has been
fixed. Includes a regression check against every item in the 2026-07-22
report.

## Headline: sandbox confinement is never actually enabled in production

`file_path_validator.nim`'s sandbox-escape check (`sandboxDir`) is correctly
designed — proper `/` boundary handling, no sibling-directory bypass. But the
only production call site that builds `FileRules`,
`talos_agent/src/talos_agent.nim:1095-1096`, hardcodes `sandboxDir: ""`, and
no config key anywhere (checked `config.nim`) ever populates it. So the
sandbox layer is permanently dead code in the shipped daemon — the only
things standing between the LLM agent and the whole filesystem are the small
hardcoded `mandatoryDenyPatterns` list and whatever an admin has put in the
Discord-editable allow-list. This is compounded by two more bugs in the same
validator:

- **file_path_validator.nim:51-60 — glob-to-regex conversion doesn't escape
  regex metacharacters.** Only `.` is escaped; `+ ^ $ [ ] ( ) | \` pass
  through to `re()` raw. Verified: a deny pattern `id+rsa.txt` (meant to
  block the literal file `id+rsa.txt`) lets that exact file through
  (`pathAllow`) because the unescaped `+` is read as a regex quantifier,
  while it wrongly denies the unrelated file `idrsa.txt`. Same function
  backs allow/ask/deny, so allow-list entries have the identical defect.
- **file_path_validator.nim:69-74 — directory allow-patterns match
  anywhere on disk, not just the intended location.** The `/*`-suffix
  special case does a substring-containment check
  (`path.contains("/" & prefix & "/")`) in addition to prefix matching.
  Verified: `allowPatterns = @["logs/*"]` (admin scoping access to one
  project's `logs/` dir) makes `/var/some/other/service/logs/secret.txt`
  resolve to `pathAllow` — any allow pattern of this shape grants
  filesystem-wide access to every directory sharing that name.

Net effect: `!config allowlist add <name>/*` — completely normal, expected
admin usage — grants far broader access than intended, with no independent
sandbox root to fall back on. The mechanism to prevent this exists and is
well-written; it's simply never wired on.

## Headline: `delegate` tool defeats the Discord "no shell" invariant

`talos_agent.nim`'s `cmdDaemon` explicitly avoids registering the shell tool
in Discord mode ("Never include the shell tool in Discord mode for
security," talos_agent.nim:1104-1106). But `makeDelegateExecuteProc`
(talos_agent.nim:317) unconditionally does `childReg.register(shellTool())`
for any child agent spawned via delegation. The result passes through
`scopedRegistry(childReg, persona)`, which only strips tools if the
persona's `toolsAllow`/`toolsDeny` are non-empty — and
`PersonaConfig.toolsAllow`/`toolsDeny` are never defaulted
(`persona.nim:58-76`), staying empty unless an operator explicitly sets them
in `personas.toml`. So for any persona without an explicit tool
allow/deny list, a Discord user who can trigger `delegate` (gated only by
`cfg.discord.daemonDelegation`) gets a child agent with full, unrestricted
shell execution — exactly the thing the code comment says must never
happen in Discord mode.

## Errors (actual bugs)

- **file_tool.nim:52 / talos_agent.nim:1102 — `fileWriteTool` checks the
  permissions of a hardcoded empty-string user, not the real Discord
  author.** `fileWriteTool(rules, cfg, userId)` bakes `userId` into the
  closure at tool-construction time; the one production call site passes
  `""`. `canUseTool("", "file_write", cfg)` → `isUserAllowed("", cfg)` →
  `false` for any sane config, so `file_write` is unconditionally denied for
  every real user. Fails closed (not a bypass) but the tool is effectively
  dead — nobody, including admins, can ever use it, because the permission
  check has no way to see the actual caller's ID (`Tool.execute`'s signature
  carries no identity parameter at all).

- **message_chunker.nim:37-61 — `chunkMessage` can hang forever, reachable
  at the default settings both real call sites use.** If a freshly-reopened
  fenced chunk is already too long to leave room before hitting `maxLen`,
  `flushCurrent()` re-emits the same fence-only chunk and resets `current`
  to the same value every iteration — `remaining` is never consumed, so the
  loop never terminates. Verified by execution (not just reasoning): hangs
  on `maxLen &le; 3`, and — more importantly — hangs at the **default
  `maxLen = 1900`** used by both `discord.nim:85` and `talos_agent.nim:1150`
  when a fence-opening line is itself long (~1897+ chars, e.g. a code fence
  with a long info-string/filename) followed by a couple of short lines.
  Confirmed via `timeout 5 nim c -r` (exit 124).

- **mcp_client.nim:157-163 — uncatchable `AssertionDefect` crash on a
  malformed (non-object) JSON-RPC `error` field.** `respNode["error"]` is
  indexed and `.hasKey()` called without checking it's a `JObject` first.
  Verified `hasKey()` on a non-object node raises `AssertionDefect`, which is
  not a `CatchableError` subtype — `except CatchableError`/`except McpError`
  (used by every caller in this file, and by `mcp_tool.nim`'s
  `registerMcpServer`/`registerMcpServers`) does not catch it. A malformed or
  malicious MCP server sending `{"error":"boom"}` instead of
  `{"error":{"message":"boom"}}` crashes the whole daemon process during
  server registration (`registerMcpServers` callers have no exception
  handling at all).

- **mcp_client.nim:415-438 (`fillMore`) — `parseHexInt` overflow silently
  desyncs the chunked-transfer parser instead of raising.** Verified
  `parseHexInt("ffffffffffffffff")` returns `-1` (no overflow check). A
  negative `chunkRemaining` skips the read loop entirely, then the code
  unconditionally consumes the *next* real line of the stream as if it were
  a trailing CRLF — silently dropping/corrupting streamed LLM content with
  no exception raised.

- **mcp_tool.nim:117-132 (`registerMcpServer`) — client leak and inflated
  tool count on partial registration failure (replaces, rather than fully
  fixes, the 2026-07-22 finding at this location).** `result` is set to the
  *entire discovered tool list* before `registerMcpTools` is attempted, so
  if registration throws after registering zero tools, `result.len > 0`
  still skips the `client.http.close()` cleanup — the `HttpClient` leaks
  with nothing holding a reference to it. Separately, callers are told more
  tools were registered than actually were, since `result` tracks "tools
  discovered" rather than "tools actually registered."

- **llm_client.nim:571 — streaming path requires exactly HTTP 200; the
  non-streaming path (line 349) accepts the full 2xx range.** A legitimate
  201/202/204 from an OpenAI-compatible proxy would be misclassified as a
  failure only in the streaming path.

- **delegate.nim / persona.nim — delegation depth is not inherited across
  the actual call chain, so `maxDepth` is a per-hop reset, not a real
  chain-wide bound.** `applyPersonaDelegation` derives a child's delegation
  budget purely from that persona's own configured limits
  (`persona.maxDelegationDepth`), never taking the parent's *remaining*
  depth as an input. Two compliant personas that delegate back and forth
  (A → B → A → …) each get a freshly-granted budget every hop; a cyclic or
  deep chain can recurse far beyond what any single `maxDepth` setting
  implies, bounded only by each agent's `maxIterations` and the native call
  stack.

- **plan_executor.nim:312-320 — `executePlan` never calls
  `memory.ensureSession(sid)` for a resumed session, unlike `agent_loop.nim`
  (which does at line 240).** If a caller passes a `resumeSessionId` for a
  session row that doesn't exist yet — the exact scenario the parameter
  exists to support — the first `appendMessage` raises an uncaught
  `DbError: FOREIGN KEY constraint failed` (verified by direct
  reproduction). Currently dormant: the only call site
  (`talos_agent.nim:616`) never passes `resumeSessionId`, but it's part of
  the public API and a future Discord-thread-style caller would hit this.

- **plan_executor.nim:356 — `registry.execute()` called with no nil-guard,
  unlike `agent_loop.executeToolCall`'s explicit `if reg.isNil` check.**
  Verified calling `execute` on a `nil` `ToolRegistry` segfaults the process
  (`SIGSEGV`, not a catchable exception) rather than failing the step
  gracefully — the `except ToolError` wrapper added in the current
  uncommitted diff can't catch a segfault.

- **memory.nim:117-122 — `newSession` has no collision handling if
  `generateSessionId()` repeats.** ID uniqueness relies on two independent
  clock reads with no dedupe/retry; `sessions.id` is a bare `TEXT PRIMARY
  KEY` insert. Verified a duplicate-PK insert raises an uncaught
  `DbError: UNIQUE constraint failed`. Timing-dependent and not
  force-reproduced from the real generator, but the gap is real, especially
  on systems with coarse clock resolution (common in containers/VMs).

- **talos_agent.nim:1180-1191 — `cmdDaemon`'s cleanup double-closes SQLite
  handles on a normal (non-shutdown-flag) crash.** The `except` branch
  closes `threadDb`/`mem`, then the `finally` block (which only skips
  closing when `daemonShutdownRequested` is true) closes them again — any
  Discord network/API exception while running normally hits this.
  `db_sqlite.close()`/`memory.close()` have no idempotency guard; a second
  `sqlite3_close()` on an already-closed handle is undefined behavior.

- **compile.nim:161-167 — `CompileResult.timedOut`/`.truncated` are declared
  but never populated by `runCompile`.** The result-literal constructor
  never sets either field, so they silently default to `false` regardless
  of what happened. `code_runner.formatCompileResult` (the exported
  formatter) branches on these fields first, so a real timeout/truncation
  never shows as "TIMEOUT"/"TRUNCATED" through that path — masked in the
  one currently-wired LLM-facing path only because `code_tool.nim` shadows
  it with its own local formatter that checks `exitCode == -1` instead.

- **compile.nim:99-146 (and the still-duplicated shell.nim:237-280) —
  timeout only kills the direct child process, not its process tree.** No
  process group is created; `p.kill()`/`p.terminate()` only signal that one
  PID. A compiled-and-run binary (`nim c -r ...`) that hangs is reparented
  to init and keeps running indefinitely after the harness reports
  "TIMEOUT," undermining the documented "hard kill deadline."

- **code_tool.nim:31-39 — `sandboxPath` is a broken, unused sandbox check
  sitting next to the correct one.** Raw string-prefix check, no
  symlink/`..` resolution, no directory-boundary requirement — verified
  `sandboxPath("/sandbox/../etc/passwd", "/sandbox")` returns the traversal
  path unchanged, and a sibling directory like `/sandbox-evil/x` also
  incorrectly passes. Confirmed via grep that it's never called anywhere
  (including tests), so not currently exploitable, but it's exported and
  documented as "a last-ditch guard," inviting a future caller to reach for
  the wrong function.

- **chat_tui.nim:68 — status bar crashes (range-check Defect) when the
  status text is wider than the terminal.** `repeat(' ', w -
  statusMsg.len)` goes negative once the joined "model │ session │ hint"
  string (easily 70+ chars) exceeds a narrow terminal's width (60-70
  columns, common in split panes).

- **chat_tui.nim:83-87 — streaming region can crash the same way** when a
  moderately long streamed response has more wrapped lines than remaining
  vertical space; `transcriptHeight - streamHeight` isn't clamped before
  being used as a `Natural` row offset.

- **input_bar.nim:181-184 — cursor positioning mixes a rune count with a
  byte count**, diverging on any multi-byte UTF-8 input (accents, CJK,
  emoji) once the input wraps to multiple lines, and can drive the cursor
  column negative — crashing on `setCursorPos`'s `Natural` parameter.

- **input_bar.nim:142-154 and transcript.nim:38-51 — line wrapping slices
  raw bytes, not runes.** Multi-byte UTF-8 characters straddling a
  byte-offset wrap boundary get split mid-sequence, and wrap width is
  systematically wrong for any non-ASCII text (common: em dashes, curly
  quotes, non-English text from either the user or the LLM).

## Inefficiencies

- **plan_executor.nim:258-268 (`markDependentsSkipped`) — still uses
  `toProcess.delete(0)`**, the exact O(n) pattern the current diff just
  fixed in the sibling `topoSort` two functions away; now inconsistent with
  its neighbor.
- **rate_limit.nim:70,76 — exponential backoff overflow, no cap —
  CONFIRMED STILL PRESENT** (see regression section).
- **llm_client.nim:292-293 — a brand-new `HttpClient` (full TCP/TLS
  handshake) is created for every retry attempt within a single
  `chatCompletion` call**, never reused even across retries of the same
  logical request.
- **compile.nim:103-110 (and shell.nim) — kill-then-terminate escalation
  order is backwards.** SIGKILL fires first, with SIGTERM only as a
  500ms-later fallback — SIGTERM can't help a process that already
  survived SIGKILL, so the "grace period" doesn't actually grace anything.
- **compile.nim:42-43 — `maxOutputBytes &le; 0` silently means "unlimited"
  output buffering**, not "no output" — a misconfiguration risk for
  unbounded memory growth.
- **web_server.nim:147-162 — `runAgentLoop` runs synchronously inside an
  async handler**, blocking the whole loopback server (including static
  asset/session lookups) for the duration of one chat turn. Likely an
  accepted tradeoff for a single-user local tool, but worth knowing.
- **web_server.nim:130-141 — `rateBuckets` never evicts stale entries**,
  unbounded growth per distinct client IP (low impact given loopback-only
  binding today).

## Style / Consistency

- **config.nim:460-479 — `validate()` never range-checks `cfg.webPort`**,
  unlike every other numeric field; a garbage/negative port only fails
  later when the socket actually opens.
- **discord_types.nim:23 (shifted from :9) — hardcoded deny list still
  duplicates and diverges from `file_path_validator.nim`'s mandatory
  patterns — CONFIRMED STILL PRESENT**, and additionally uses weaker glob
  syntax (bare `.ssh`/`.aws`/`.gnupg` instead of `.ssh/*` etc.), masked
  today only because the mandatory list is always checked independently
  first.
- **permission.nim:53 — `risk == riskNone` branch is unreachable**;
  `getToolRisk` never returns `riskNone`.
- **permission.nim:46-48 — an explicit `cfg.tools.allow` entry bypasses the
  risk/admin gate entirely for any allowed user**, not just admins; easy to
  misread the medium-risk `isAdmin` check as the effective gate when it can
  be silently overridden.
- **discord_commands.nim:26-36, 91-94 — `!config show` /
  `!config allowlist list` are available to any allowed (non-admin) user**,
  exposing the full allow/deny lists and admin ID list; inconsistent with
  the file's own "admin-only commands" framing (may be intentional/
  read-only by design, but undocumented as such).
- **discord_commands.nim:50-52 — `!config set token_env` is a no-op in
  practice**; the Discord token is only read once at daemon startup, so
  changing this at runtime has no observable effect.
- **code_runner.nim vs code_tool.nim — two different, inconsistent
  `formatCompileResult` functions**, the local one in `code_tool.nim`
  shadowing the exported one; this shadowing is exactly how the
  `timedOut`/`truncated` field bug above went unnoticed.
- **talos_agent.nim — pervasive `{.cast(raises: []).}:` around
  `stdout.write`/`writeLine`/`flushFile`** in stream/step callbacks; this
  only suppresses the compile-time effect check, not runtime exceptions —
  an `IOError` (e.g. `EPIPE` from a closed pipe) still propagates out of a
  proc declared `raises: []`.
- **web_server.nim:274 — `parsePath` re-parses an already-parsed `Uri`**;
  `req.url.path` is already the raw path, so `parseUri(req.url.path)` is a
  redundant round-trip.
- **tool_registry.nim — `ToolExecuteProc` alias declared `{.gcsafe.}` but
  never actually used** for the `Tool.execute` field or `newTool`/`register`
  parameter types.
- **mcp_client.nim — `jsonRpcResponseId` defined and unit-tested but never
  called in production**; JSON-RPC response ids are never validated
  against the request that produced them (harmless today given strictly
  synchronous HTTP request/response pairing).
- **persona.nim:58-77 — `applyPersonaDefaults`'s documented default
  (`delegateEnabled`) only actually applies through the TOML-loader
  construction path**; a future direct `PersonaConfig(...)` construction
  elsewhere would silently get the wrong default. Not exploited today.
- **.gitignore:49 — stale `mercury_code` entry — CONFIRMED STILL PRESENT**,
  redundant (already covered by the `talos_code` pattern), harmless.
- **shell.nim / compile.nim — duplicated `setNonBlocking`/`drainAvailable`
  POSIX helpers — CONFIRMED STILL PRESENT**, now at
  `talos_agent/src/tools/shell.nim:163,170` and
  `talos_code/src/talos_code/compile.nim:24,29`; compounds the timeout/
  process-tree bug above since both copies share it.
- **README.md is stale relative to actual functionality.** Its Roadmap
  table still marks MCP support, sub-agent delegation, and the Web UI as
  "🔜 Planned," though all three are fully implemented and tested; it never
  mentions the TUI at all; its Architecture table omits `mcp_client.nim`,
  `mcp_tool.nim`, `delegate.nim`, `persona.nim`; its test-file listing for
  `talos_agent/tests/` omits `tdelegate_tool.nim`, `tweb_server.nim`,
  `tbench.nim`; and it understates `tcode_runner`'s test count (23 vs. the
  actual 29).
- **ROADMAP.md:4 and STATUS.md:71 — stale "479 tests" header, each
  self-contradicting its own detailed test-count table further down in the
  same file** (which correctly says 514). Actual verified count: **514
  tests, all passing.**

## Test suite status

`make test` (root Makefile, runs `nimble test -y` per package): **514
`[OK]` assertions across 31 test binaries, 0 failures**, full run in ~15s
wall clock with warm cache. Only expected warnings observed (14 intentional
`MERCURY_*` deprecation-fallback warnings from `tconfig.nim`'s own
backward-compat tests, one deliberate MCP-connection-refused test, and an
unrelated nimble dependency-version notice from dimscord's `etf` dep).

## Regression check against 2026-07-22 report

**Fixed:**
- agent_loop.nim:347 (`toolCalls[^1]` crash) — now guards `toolCalls.len > 0`.
- thread_mapping.nim:81,105,114 (`row[0]` on empty seq) — now guards `row.len`.
- config.nim:529-541 (.env parse failures discarded) — now raises `ConfigError`.
- memory.nim:354 (`listSessions` O(n²) subquery) — now a `LEFT JOIN`.
- talos_agent.nim:312-319 (delegation config not restored on exception) —
  now `defer: gGlobals.delegationConfig = savedDc`.
- talos_agent.nim:993 (`cmdWeb` `mem.close()` not deferred) — now
  `defer: mem.close()`.
- talos_code.nim:84 (extension list not `.strip()`ed) — now
  `.mapIt(it.strip())`.
- llm_client.nim:505 (`parseInt(parsed.port)` unwrapped) — now wrapped in
  `try/except ValueError`.
- mcp_tool.nim:121-132 (client closed after partial registration, original
  symptom) — that specific symptom no longer reproduces, but see the fresh
  finding above: the fix introduced a different leak/inflated-count bug at
  the same location.
- test_config.nim:1 / talos_core/test_simple.nim:1 (stale `mercury_core`
  imports) — both now import the real current modules.
- tcli.nim / tintegration.nim (deprecated `MERCURY_*` env vars in tests) —
  now exclusively use `TALOS_*`.
- All "Task 6 Plan-Execute Mode" items — confirmed still fixed; the current
  uncommitted `plan_executor.nim` diff matches those fixes line-for-line and
  introduces no regression in the code it actually touches (the two new
  plan_executor.nim bugs above predate this diff and are in code the diff
  didn't change).

**Still present:**
- rate_limit.nim:70 (and :76) — exponential backoff overflow, no cap.
- discord_types.nim (now :23, was :9) — hardcoded deny list duplicates
  file_path_validator.nim's patterns, and is weaker.
- shell.nim / compile.nim — duplicated POSIX I/O helpers.
- .gitignore:49 — stale `mercury_code` entry (harmless).

**Re-verified and confirmed still safe** (previously marked "not a bug" —
actually re-checked this time, not just trusted):
- llm_client.nim:635-637 — `toolCallId` overwrite logic is correct.
- llm_client.nim:361-363 — retry error type preserved via `ref LLMError`.
- mcp_tool.nim:135 — client kept alive by ORC through closure capture; no
  use-after-free.
- CSRF guard in web_server.nim — Origin check + loopback binding still sound.
- `withinSandbox`/`resolvePathSafe` in code_tool.nim — sound against
  symlinks/`..`, including a fresh null-byte-injection test (correctly
  truncated consistently before validation and before use). One residual
  caveat newly noted: `readFileTool`/`writeFileTool` validate the
  *resolved* path but perform I/O on the *original* path string — a
  TOCTOU gap only under true concurrent symlink repointing, not exploitable
  under the current sequential/synchronous execution model.
- TUI terminal cleanup — `try/finally` with `illwillDeinit()` still present.

## Info (observations, not action items)

- Classic `../` traversal and null-byte path injection were both actively
  tested (not just reasoned about) against `resolvePathSafe` and correctly
  neutralized before validation runs.
- `isAdmin`/`isUserAllowed` deny-overrides-allow ordering is correct and
  consistent at both user and tool levels.
- All SQL across every reviewed file remains fully parameterized; no
  injection surface found anywhere.
- No hardcoded secrets found; Discord token only ever referenced by env-var
  name, masked in `!config show`.
- Percent-encoded path traversal against `web_server`'s static asset
  serving was specifically tested and doesn't work — `std/uri.parseUri`
  never percent-decodes `.path`.
- `compile`/`test` tool definitions take no LLM-controlled arguments
  (`buildCmd`/`testCmd` are operator-set env vars only), so no direct
  command-injection surface from the LLM into `runCompile`'s shell
  invocation via those specific tools.
- The exponential backoff in `llm_client.chatCompletion` already caps its
  shift (`min(attempt - 1, 30)`), avoiding the overflow the 2026-07-22
  report flagged more generally — only `rate_limit.nim` still has the
  unbounded version.

---

## Fix status — 2026-07-24 same-day remediation

Discussed with the user before fixing: they run agentic workflows without
sandboxing, deliberately. The two headline findings above were rescoped
accordingly rather than "fixed" as originally framed — see CHANGELOG.md
`[Unreleased]` "Fixed — 2026-07-24 audit remediation" for full details.
All items below were implemented same-day; 518 tests pass, 0 failures.

**Rescoped (not a straight fix):**
- [x] Sandbox never enabled — now a fully opt-in knob (`TALOS_FILE_SANDBOX_DIR`),
  never defaulted or nagged about, per the user's operating model.
- [x] `delegate` Discord-mode shell inconsistency — resolved by removing
  the top-level restriction (shell is now openly available in Discord mode
  too) rather than closing the gap, since the restriction no longer
  reflected how the daemon is actually meant to be used.

**Fixed as originally scoped** (all Errors from this report, all Phase 2/3
items): file_write dead permission check; regex-metacharacter escaping;
directory allow-pattern matching; discord_types.nim deny-list duplication;
chunkMessage hang; MCP AssertionDefect; parseHexInt overflow desync;
plan_executor nil-registry segfault; plan_executor missing ensureSession;
cmdDaemon double-close; memory.newSession collision handling; four TUI
crash bugs; mcp_tool client leak/inflated count; llm_client streaming
status check; delegation depth inheritance; CompileResult timedOut/truncated
fields; process-tree kill + kill-order fix (compile.nim and shell.nim);
sandboxPath dead-code removal; rate_limit backoff overflow cap;
markDependentsSkipped O(n) delete.

**Cleanup, also done:** config.nim webPort validation; permission.nim dead
riskNone branch; code_tool.nim/code_runner.nim formatCompileResult rename +
fix; setNonBlocking/drainAvailable deduplicated into `talos_core/posix_io`;
.gitignore stale entry; README/ROADMAP/STATUS test-count and
feature-status refresh.

**Explicitly deferred, not part of this pass** (lower-priority
Inefficiencies/Style items from this report that weren't included in the
approved fix plan — still open):
- [ ] `llm_client.nim` — new `HttpClient` per retry attempt (no connection reuse).
- [ ] `compile.nim` — `maxOutputBytes <= 0` silently means "unlimited" rather than "no output".
- [ ] `web_server.nim` — `runAgentLoop` blocks the async handler during a chat turn.
- [ ] `web_server.nim` — `rateBuckets` never evicts stale entries.
- [ ] `permission.nim` — explicit `cfg.tools.allow` silently bypasses the risk/admin gate (undocumented precedence).
- [ ] `discord_commands.nim` — `!config show`/`allowlist list` not admin-gated; `!config set token_env` is a no-op.
- [ ] `talos_agent.nim` — pervasive `{.cast(raises: []).}` around stdout writes suppresses the static check without handling the runtime `IOError`.
- [ ] `web_server.nim` — `parsePath` re-parses an already-parsed `Uri`.
- [ ] `tool_registry.nim` — `ToolExecuteProc`'s `{.gcsafe.}` alias isn't actually used by the types it's meant to describe.
- [ ] `mcp_client.nim` — `jsonRpcResponseId` defined and tested but never called in production.
- [ ] `persona.nim` — `applyPersonaDefaults`'s documented default only applies through the TOML-loader construction path.
