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
