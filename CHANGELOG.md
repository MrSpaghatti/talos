# NOTE: This project has been renamed from Mercury Agent to Talos Agent.

# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]
### Added — 2026-07-22 Task 6: Plan-Execute Mode

- **`plan_executor.nim`** (new module in `talos_core`). An alternative to
  the flat ReAct loop: asks the LLM to produce a structured JSON plan up
  front, then executes steps in dependency order (topological sort via
  Kahn's algorithm), and synthesises a final answer from all step results.
  Tool steps execute via the tool registry; reasoning steps (empty
  `toolName`) call the LLM with prior step context. On step failure,
  dependent steps are marked skipped and independent remaining steps still
  execute. All results are logged to memory.
- **`--plan` flag on `talos_agent ask`.** Switches from ReAct to
  Plan-Execute mode. The plan is displayed before execution, then the
  final answer is printed. Works with `--no-stream` and streaming.
- **35 new tests** in `test_plan_executor.nim` covering plan parsing,
  topological sort (chains, diamonds, cycles), plan generation via mock
  LLM, plan execution with tool calls and reasoning steps, failure
  handling, statistics tracking, and formatting. Total: 514 tests.

### Fixed — 2026-07-22 onboarding + deep-dive audit

- **`agent_loop.nim` crash on empty tool_calls with loop detection.**
  If `finishReason == "tool_calls"` but `resp.toolCalls` was empty,
  `resp.toolCalls[^1]` crashed with index out of bounds. Now guarded
  with a `len > 0` check.
- **`thread_mapping.nim` crash on empty db.getRow result.**
  `getSessionForThread` and `getLatestSessionForChannel` accessed `row[0]`
  without checking `row.len`, crashing when no rows matched. Added bounds
  checks.
- **Delegation config not restored on exception.** The parent's
  `delegationConfig` was manually swapped and restored, but an exception
  between swap and restore left it corrupted. Now uses `defer`.
- **SQLite handle leak in `cmdWeb`.** `mem.close()` was only reached on
  normal exit; if `serveUntilInterrupted` threw, the handle leaked.
  Moved to `defer`.
- **MCP client closed after partial tool registration.** If
  `registerMcpTools` threw after registering some tools, the error handler
  closed the client, leaving registered tool closures pointing to a dead
  HttpClient. Now only closes if no tools were registered.
- **`talos_code` extension list didn't trim whitespace.** `TALOS_ALLOWED_EXTENSIONS`
  values like `" .nim , .c "` produced entries with spaces that never matched.
  Added `.mapIt(it.strip())`.
- **Streaming SSE crash on non-numeric port.** `parseInt(parsed.port)` in
  `chatCompletionStream` wasn't wrapped in try/except, unlike the
  non-streaming path.
- **Exponential backoff integer overflow.** `(1 shl (attempt - 1))` could
  overflow at attempt=32. Capped with `min(attempt - 1, 30)`.
- **`.env` parse failures silently discarded.** Malformed numbers in `.env`
  (e.g. `TALOS_MAX_TOKENS=abc`) were silently ignored with `discard`,
  unlike OS env vars which raise `ConfigError`. Now consistent.
- **`listSessions` O(n²) query.** Correlated subquery replaced with
  `LEFT JOIN + GROUP BY`.
- **Stale `mercury_core` imports and `MERCURY_*` env vars.** Updated
  `test_config.nim`, `test_simple.nim`, and all `MERCURY_*` references in
  `tcli.nim` and `tintegration.nim` to `TALOS_*`.

### Fixed — build/CI infrastructure

- **`talos_agent.nimble` missing `dimscord` dependency.** `nimble build`
  failed because the transitive dep wasn't declared. Added
  `requires "dimscord >= 1.0.0"`.
- **CI workflow missing `run: nimble test` for core.** The "Test core"
  step had no `run` command, so CI never ran core tests.
- **`Makefile` didn't build/test `talos_code`.** Added `talos_code` to
  both `build` and `test` targets.
- **Stale `mercury_agent.out` and `mercury_code` binaries.** Removed
  pre-rename build artifacts and added to `.gitignore`.
- **`CHANGELOG.md` `[Unreleased]` referenced `mercury_*` paths.** Updated
  all module/path references to `talos_*`.


### Testing

- **Full test-suite quality pass.** Reviewed every test in the suite (not
  just ones touched by recent fixes) against three criteria: does it earn
  its place (not redundant/tautological), does it verify the actual
  behavior at stake (not a shallow proxy like "something non-empty was
  returned"), and does the feature it covers have at least one real
  end-to-end test through its actual entry point, not just unit/mock-level
  coverage. Net result: 30 low-value tests cut (exact duplicates, and
  checks that can't fail short of a compiler bug), ~15 weak assertions
  strengthened to check real content/values, and real coverage added for
  gaps that had none — most notably: `mcp_client.nim`'s `initialize`/
  `listTools`/`callTool` had zero test coverage of their actual JSON
  parsing (every existing test drove the mock server directly, bypassing
  the real client entirely); `code_tool.nim`'s `compileTool`/`testTool`
  wrappers (what the coding-harness agent actually calls) were completely
  untested despite `runCompile` itself being well covered; `persona.nim`'s
  `scopedRegistry` (used by both the delegate and persona-task spawn
  paths) had a test with its name on it that never actually called it;
  and the Discord bot had no test proving DMs and non-mentioning channel
  chatter are correctly ignored. Deleted `test_agent_dispatcher.nim`
  (fully subsumed by `test_daemon_delegation.nim`'s placeholder-path
  suite, with weaker assertions). Net: 488 → 479 tests — fewer, but each
  one now pulling real weight.

### Fixed

- **Discord thread continuity was completely non-functional.** `runAgentLoop`
  unconditionally called `memory.newSession()` on every invocation, so
  `agent_dispatcher.dispatchAgent` never actually resumed the session ID
  that `discord.nim` resolves via `thread_mapping.nim` for an existing
  thread — every message in a Discord thread started a brand-new,
  historyless conversation, even though the bot told users "Continuing from
  previous session." `runAgentLoop` now takes an optional
  `resumeSessionId`: when set, it loads that session's prior history via
  `memory.getHistory()` before appending the new turn, and creates the
  session row on first use if it doesn't exist yet
  (`memory.ensureSession()`). `dispatchAgent` passes `request.sessionId`
  through. Regression tests added in `tagent_loop.nim` (resume-with-history
  and cross-thread isolation at the `runAgentLoop` level),
  `test_daemon_delegation.nim` (resume across two real dispatches through a
  file-backed DB), and `test_e2e_discord.nim` (a full user-facing scenario:
  two real messages through `bot.onMessageCreate` in the same thread against
  a mock LLM, asserting the second reply and the second outbound LLM request
  both reflect what the user said in the first message).

- **`PersonaConfig.delegateEnabled` was dead.** Its TOML defaulting logic
  couldn't distinguish "not set" from "explicitly `false`" (both are a
  `bool`'s Nim zero-value), so any persona that didn't set
  `delegate_enabled` silently ended up with delegation *disabled* — the
  opposite of the documented default. The flag was also never read
  anywhere to actually gate delegation. Fixed: `loadPersonasFromStream`
  now seeds each persona with `DefaultDelegateEnabled` (true) before
  parsing, and the delegate-tool spawn path in `talos_agent.nim` only
  registers a `delegate` tool for a child agent when its persona's
  `delegateEnabled` is true. The gating decision was pulled into a small
  pure `childGetsDelegateTool` proc so it's directly unit-testable; new
  tests in `test_persona.nim` (TOML default/explicit-true/explicit-false)
  and `tdelegate_tool.nim` (the gating decision itself) cover it.

### Added

- **Streaming responses (SSE).** `chatCompletionStream` proc added to
  `talos_core/llm_client.nim` with raw-socket SSE parsing. `AgentConfig`
  accepts an optional `streamCallback`; when set, the ReAct loop streams
  token-by-token deltas to the callback. CLI (`chat`, `ask`, `session`)
  defaults to streaming output with a `--no-stream` flag to disable.
  Discord daemon does not yet support progressive edits (blocked on
  dimscord `--threads:on`).

- **Web UI (`talos_agent web`).** New `web_server.nim` module serves a
  single-page chat interface from Nim's stdlib `asynchttpserver`. Routes:
  `GET /` (index.html), `GET /assets/*` (CSS/JS), `POST /api/chat` (agent
  loop, JSON response), `GET /api/sessions`, `GET /api/sessions/:id`,
  `GET /api/search?q=`. Binds loopback-only (`127.0.0.1`) and has no CORS
  headers — the API has no auth and the agent has shell/file tools, so it
  must not be reachable off-host. Static assets served from `web_assets/`
  directory (embedded at compile time via `staticRead` when
  `-d:embedAssets` is set; the filesystem-read fallback validates asset
  paths to prevent traversal). Configurable via `webPort` in TOML,
  `TALOS_WEB_PORT` env var, or `--port` CLI flag (default 8080).
  SSE streaming deferred — `asynchttpserver` closes the connection after
  `respond()`, making long-lived streams impractical.

- **`TalosConfig.webPort`** field added to `config.nim` (default 8080),
  loaded from TOML key `web_port` and env var `TALOS_WEB_PORT`.

- **`listSessions`** proc added to `talos_core/memory.nim` with
  `SessionSummary` type for listing recent sessions.

### Changed
- **Agent loop relocated to `talos_core`.** `agent_loop.nim` moved from
  `talos_agent/src/` to `talos_core/src/talos_core/`, eliminating the
  cross-package injection hack. `agent_dispatcher` now imports `AgentResult`
  directly from `agent_loop`. All callers (`talos_agent`, `talos_code`,
  test files) updated to `import talos_core/agent_loop`.
- **SQLite busy_timeout added to memory.nim.** `PRAGMA busy_timeout=5000`
  prevents `SQLITE_BUSY` under concurrent read/write access (WAL mode was
  already enabled).

### Fixed

- **`defaultConfig()` dropped `maxLoopIterations`** when `webPort` was added
  to the same object literal, leaving it at Nim's zero value; `validate()`
  then rejected every config that didn't explicitly set
  `max_loop_iterations`, breaking `history`/`search`/`session` and other
  commands relying on the default. Restored.
- **`chatCompletionStream` never actually worked.** `Socket.recvLine` pads
  a genuine blank line to `"\r\n"` specifically to distinguish it from a
  real disconnect (`""`); the header-read loop and the SSE blank-line
  check both tested for `""`, so the header loop silently consumed the
  entire response body before the SSE parser ever ran, and the event
  dispatch branch was dead code besides. Separately, the raw status line
  (`"HTTP/1.1 200 OK"`) was fed whole into a parser expecting `"200 OK"`,
  so `status` was always `0` and even a successful response took the error
  branch. All three fixed; added a `BodyReader` that also dechunks
  `Transfer-Encoding: chunked` bodies (common through HTTPS proxies, and
  previously unhandled); added the first real test coverage for this path
  (`chatCompletionStream` suite in `tllm_client.nim`).
- **Security — path traversal in the web UI's static asset handler.**
  `serveAsset` joined the request path onto `web_assets/` and read it with
  no `..`-segment check; `GET /assets/../../../../etc/passwd` returned
  arbitrary local files when built without `-d:embedAssets` (the default).
  Added `isSafeAssetPath`.
- **Daemon silently swallowed agent-run errors.** `cmdDaemon`'s error path
  returned a default-initialized `AgentResult` whose `stopReason` defaulted
  to `asrFinished` instead of `asrError`, so a crashed agent run reported
  success with an empty message to Discord instead of surfacing the
  failure. Now sets `stopReason = asrError` with the real error text.
- **SQLite WAL mode was dropped, not added to, in `memory.nim`.** The
  `busy_timeout` PRAGMA replaced `journal_mode=WAL` instead of joining it,
  contrary to the change's own intent. Restored WAL alongside busy_timeout.
- **Code quality pass.** Removed dead `parseRole` proc in `llm_client.nim`.
  Added `stderr` logging to previously-silent CatchableError discards in
  `llm_client` and the daemon agent runner. `validate()` now warns when
  OpenRouter is selected but `OPENROUTER_API_KEY` is empty.

### Fixed — 2026-07-20 follow-up audit (spec drift vs. Tasks 1–3)

- **The cross-package injection hack was not actually eliminated.** The
  "Changed" entry above (and `agent_dispatcher.nim`'s own header comment)
  claimed relocating `agent_loop.nim` removed the injected `AgentRunFn`
  wrapper — it didn't; `cmdDaemon` still built a `runFn` closure and passed
  it to `newAgentDispatcher`. `dispatchAgent` now calls
  `agent_loop.runAgentLoop` directly (opening/closing its own `Memory` per
  dispatch); `AgentRunFn` removed from `agent_dispatcher.nim`.
- **Web UI security hardening (Task 3 Phase 3d) was silently incomplete.**
  Input size validation (>10KB) was implemented; CSRF protection and rate
  limiting were not, and the gap wasn't documented anywhere. Added an
  `Origin`-header CSRF check and a per-client fixed-window rate limiter to
  `POST /api/chat` (`rate_limit.nim` turned out not to fit — it's an
  outbound retry-with-backoff helper for calling other APIs, not an
  inbound throttle; see `task-03-web-ui.md`).
- **`web_server.nim` had no test coverage.** Added `tweb_server.nim`
  covering routing, path-traversal rejection, the chat/sessions/search
  endpoints, and the new CSRF/rate-limit behavior, using a threaded mock
  LLM backend (the blocking `chatCompletion` client can't be exercised by
  an async-only mock without deadlocking the test's own event loop).
- **Task 1 Phase 1b's required WAL concurrency test was missing.** Added
  a `tmemory.nim` test that runs a writer and a reader against the same
  file-backed database from separate threads/connections and asserts
  neither hits `SQLITE_BUSY`.
- **Discord had no "still working" signal on long agent runs** (Task 2
  Phase 2d was unimplemented, though honestly flagged as deferred).
  Progressive message-edit streaming isn't achievable without an async
  LLM client or real dispatcher threading (both out of scope), so instead:
  `AgentConfig.turnCallback` fires once per ReAct iteration, and
  `AgentDispatcher.turnCallback` wires it to Discord's typing indicator,
  refreshing it every turn instead of letting it lapse after ~10s on
  multi-turn runs.

- **Security — coding-harness file tools ignored the sandbox root.**
  `read_file` / `write_file` in `talos_code/code_tool.nim` documented
  operating "within the sandbox" (and the CLI refuses to start without
  `TALOS_SANDBOX_ROOT`), but never enforced it — extension-less paths
  bypassed even the extension filter, letting a model read/write anywhere
  (`/etc/passwd`, `~/.ssh/*`, …). Added `withinSandbox` (symlink/`..`-resolving,
  `/`-boundary, fail-closed) and gated both tools on it.
- **Security — sandbox escape via sibling-prefix path.**
  `file_path_validator.validatePath` used `startsWith(sandbox)`, so
  `/home/u/sandbox-evil/…` passed the check for a `/home/u/sandbox` sandbox.
  Now requires an exact match or a `/` boundary.
- **`talos_code` could not run any real build/test command.** `runCompile`
  called `startProcess` without `poEvalCommand`, so multi-word commands like
  `nim c -r src/main.nim` were treated as a single executable name and failed
  to launch. Added `poEvalCommand`.
- **Shell / compile output deadlock on large output.** `tools/shell.nim` and
  `talos_code/compile.nim` read the child's pipe only after it exited, so any
  command emitting more than one pipe buffer (~64 KiB) blocked forever and was
  killed as a false timeout. Both now drain incrementally (non-blocking) on
  POSIX, capping stored output.
- **Search crashed on ordinary text.** `memory.searchHistory` passed the raw
  query to FTS5 `MATCH`; inputs like `rm -rf`, `foo:bar`, or a lone quote raised
  an uncaught `DbError`. Now retries as a sanitized literal query and returns no
  results rather than raising.
- **`file_write` permission bypass.** `file_tool` checked `canUseTool(…,
  "write_file", …)` while the tool registers as `file_write`, so an explicit
  `tools.deny = ["file_write"]` was silently ignored. Fixed the name.
- **Compiler-output parser crash.** `parseNimCompilerOutput` ran `parseInt` on
  any `word(...)` line unguarded, so captured output like `assert(x == y)` raised
  a `ValueError`. Now skips non-numeric locations like the legacy parser.
- **Config test isolation.** `.env`-precedence tests in `tconfig.nim` /
  `tintegration.nim` didn't clear the matching OS env var, so the suite failed on
  machines that export `OPENROUTER_API_KEY`.

Regression tests were added for every item above (460 tests total, 0 failures).

## [0.1.0] — 2026-05-30

Initial release covering the completed foundation phases.

### Added

- **mercury_core** — shared library with:
  - `config.nim`: Layered configuration (defaults → TOML → `.env` → env vars),
    validated at startup with clear error messages
  - `llm_client.nim`: OpenAI-compatible Chat Completions client with exponential
    backoff retry, typed error hierarchy (`AuthError`, `RateLimitError`,
    `ServerError`, `RetryExhaustedError`)
  - `token_counter.nim`: Heuristic token estimator (GPT tokenizer ratios, bilingual
    support)
  - `memory.nim`: SQLite + FTS5 session persistence, full-text search,
    token-usage tracking
  - `tool_registry.nim`: Named tool registration with JSON schema export and
    safe execution wrapper
  - `discord.nim`: Dependency-injection Discord bot (`DiscordBot` ref) for
    testability
  - `discord_bridge.nim`: `RealDiscordApi` wrapping dimscord REST (send, typing,
    thread management)
  - `discord_commands.nim`: Command parser for `!status`, `!config`, `!admin`,
    `!session`, `!search` with permission checks
  - `discord_types.nim`, `discord_mocks.nim`: Shared types and offline mock API
  - `agent_dispatcher.nim`: Async agent request queue with callback-based result
    delivery
  - `permission.nim`: Role-based permission evaluator (admin, allow, deny lists)
  - `file_path_validator.nim`: Path traversal guards, percent-decode normalization,
    configurable allow/deny patterns
  - `file_tool.nim`: Agent tools for safe file read/write with path rules
  - `message_chunker.nim`: Splits long agent output at Discord's 2000-char limit
  - `rate_limit.nim`: Per-user token-bucket rate limiting
  - `thread_mapping.nim`: Maps Discord channel+user to persistent agent threads
    via SQLite with WAL mode

- **mercury_agent** — CLI binary with:
  - `mercury_agent.nim`: cligen-based dispatcher for `chat`, `ask`, `session`,
    `history`, `search`, `daemon` subcommands
  - `agent_loop.nim`: ReAct loop with loop detection, error recovery, configurable
    iteration cap, and OpenAI function-calling integration
  - `tools/shell.nim`: Sandboxed shell tool with deny-list (20+ patterns),
    per-call timeout (default 30s, max 5min), and 64KB output cap

- **CI pipeline** (GitHub Actions) — automated build + test on push/PR to `main`,
  running against Nim 2.0.8 and 2.2.2

- **Test suite** — 312 assertions across 23 test files:
  - mercury_core: config, LLM client, token counter, memory, tool registry,
    mock server, Discord bot, permission, file tools, rate limiting,
    thread mapping, message chunking, agent dispatcher, e2e
  - mercury_agent: CLI, agent loop, integration, shell tool

### Fixed

- SSL build on Nim 2.2.x: `config.nims` files in both packages now pass
  `--define:ssl`, resolving `raiseSSLError` undeclared identifier in dimscord
  builds
- `file_tool.nim`: Added `except Exception` alongside `except CatchableError`
  to handle Nim 2.2.x's stricter exception propagation on `moveFile` when
  compiled with `-d:ssl`
- `.gitignore`: Removed `*.nims` glob that was preventing `config.nims` from
  being tracked; force-added both `config.nims` files
- `tllm_client.nim` mock server: Added `sleep(50)` inside accept loop so the
  thread reliably detects `running = false` on shutdown, preventing 2s test
  hangs
- Shell timeout test: Removed brittle `durationMs < 3000` wall-clock assertion
  that failed on heavily-loaded CI containers; retained behavioral guarantees
  (`timedOut == true`, timeout message in stderr)
- Stale `OPENROUTER_BASE_URL` in `.env.example` → correct var `MERCURY_OPENROUTER_ENDPOINT`
- `stderr.writeLine` in `discord.nim` → `std/logging` with `newConsoleLogger` +
  `notice()`
- Missing `tllm_client.nim` in `mercury_core.nimble` test task (18→19 entries)
- Missing `tintegration.nim` in `mercury_agent.nimble` test task (3→4 entries)
- `Makefile` test target: replaced `|| true` with proper `&&` chaining so
  failures are not silently swallowed

### Changed

- `allowlistParts` slicing in `discord_commands.nim` simplified from
  `parts[1..<1+(parts.len-1)]` to `parts[1..^1]`
- Daemon dispatcher: replaced `asyncCheck` with `sendWithLogging` (try/except +
  stderr logging) to prevent silent error swallowing when Discord drops mid-response
- Thread-mapping SQLite DB: added `PRAGMA journal_mode=WAL` +
  `PRAGMA busy_timeout=5000` to prevent `SQLITE_BUSY` deadlocks under concurrent
  access
- Permission tests expanded from 6 to 26 covering admin deny, conflict resolution,
  risk-level combos, empty config, explicit allow/deny override behavior
- Shell tool tests relocated from `mercury_core/tests/ttool_registry.nim` to
  `mercury_agent/tests/test_shell_tool.nim` (eliminates cross-package import)

### Docs

- `README.md`: Architecture overview, CLI reference, configuration table,
  quick-start guide, module maps
- `STATUS.md`: Phase-by-phase completion status, test coverage table,
  known issues, architecture diagram
- `CONTRIBUTING.md`: Setup, build commands, SSL workaround, module dependency
  graph, release process, code health summary
- `mercury_core/DISCORD.md`: Discord bot architecture, command reference,
  thread model, testing strategy, module reference
- `.sisyphus/plans/roadmap.md`: Project roadmap with P0/P1/P2/P3 tiers and
  quick wins

## [Unreleased]

### Added

- **mercury_agent/tests/tbench.nim** — component benchmark suite that
  measures framework overhead independent of LLM latency. Results:
  - Memory ops (session + 3 msgs + history): **0.264ms** per run
  - Tool construction: **0.003ms** per tool
  - Tool execution: **0.301µs** per call
  - Registry lookup: **0.422µs** per call
  - LLMClient construction: **0.002ms** per instance
  - Config default+validate: **0.195µs** per instance
  - **Key finding**: framework overhead is **~0.1ms per ReAct iteration**
    (0.01% of ~800ms LLM call time). The agent loop is NOT the bottleneck.
  - Run: `nim c -d:ssl -r tests/tbench.nim` (from mercury_agent/)

- **mercury_core**: `mock_mcp_server.nim` — async mock MCP HTTP server
  for testing against the `asynchttpserver` pattern. Supports initialize,
  tools/list, tools/call, JSON-RPC error responses, and HTTP error codes.
- **mercury_core**: `test_mcp_client.nim` expanded from 16 to 25 tests.
  Added 9 integration tests using the mock MCP server to verify the
  JSON-RPC protocol: initialize handshake, tool discovery, tool calls,
  error handling, method routing, and request counting.
- **mercury_core**: `test_mcp_tool.nim` — 11 tests for the MCP tool
  registration bridge (`mcp_tool.nim`): single-tool registration,
  duplicate detection, empty-name rejection, null schema handling,
  multi-tool batch registration, disabled/unreachable server handling,
  and execute-proc error mapping.

- **mercury_code** — autonomous coding harness binary:
  - `code_runner.nim`: `CodingHarnessConfig`, `CompileResult`/`CompileError`,
    `parseNimErrors()`, `formatCompileResult()`
  - `code_tool.nim`: `compileTool`, `testTool`, `readFileTool`, `writeFileTool`
    (all `{.gcsafe, raises: [].}` closures matching shell tool pattern)
  - `compile.nim`: subprocess execution with timeout and 512 KiB output cap
  - `mercury_code.nim`: CLI entry point (`--task`, `--version`, `--help`)
  - `tcode_runner.nim`: 11 tests (formatter, error parser, config defaults)
- **build_llm_client.nim** (mercury_core): shared `MercuryConfig → LLMClient`
  builder used by both `mercury_agent` and `mercury_code`

### Changed

- **CI pipeline** (`.github/workflows/ci.yml`): added build + test steps for
  `mercury_code` package on both Nim 2.0.8 and 2.2.2
- **.gitignore**: added `mercury_code/src/mercury_code/mercury_code` and
  `mercury_code/tcode_runner` build artifacts

### Security

- **mercury_code/compile.nim**: `except:` (bare catch) → `except CatchableError:`
  to avoid silencing `Defect` types in subprocess output handling

### Added

- **mercury_core**: `persona.nim` — Persona system with `PersonaConfig`,
  `PersonaRegistry`, TOML loading from `~/.config/mercury/personas.toml`.
  Supports system prompt, model/temperature overrides, per-persona tool
  allow/deny lists, memory scope (own_sessions/none/shared), max history
  cap, delegation bounds, and iteration limits.
- **mercury_core**: `delegate.nim` — DelegationConfig with safety bounds
  (`maxDelegationDepth`, `maxDelegationsPerRun`), `canDelegate()`,
  `useDelegationSlot()`, `applyPersonaDelegation()`.
- **mercury_core**: `tool_registry.nim` — `scopedRegistry()` produces a
  filtered `ToolRegistry` per persona; `filterToolsByPersona()` handles
  allow/deny logic (deny wins on conflict, empty allow = all pass).
- **mercury_agent**: `run <persona> <task>` subcommand that loads
  `~/.config/mercury/personas.toml`, builds a persona-scoped agent config,
  and executes via `runAgentLoop`.
- **mercury_agent**: `delegate` tool (gcsafe closure, `{.raises: [].}`) that
  spawns child agents from named personas within the ReAct loop. Safety
  bounds enforced via `DelegationConfig`.
- **mercury_core**: `test_persona.nim` — 22 tests covering registry
  construction, tool filtering, memory scope, delegation config, defaults.
- **config/personas.example.toml**: Template with 4 personas:
  `code_reviewer` (shell+files), `researcher` (stateless),
  `writer` (files only, memory-capped), `debug` (full access).

### Changed

- **mercury_core/agent_loop.nim**: `AgentConfig` extended with optional
  `persona: PersonaConfig` and `delegation: DelegationConfig` fields.
- **mercury_core**: `tconfig.nim` now imports `mcp_client` for
  `DefaultMcpServerUrl` constant used in tests.

### Security

- **mercury_core/persona.nim**: `parseMemoryScope()` and `parseBool()`
  use constant-time `case` statements; persona names normalized to
  lowercase to prevent duplicate registration via case-folding.
- **mercury_agent**: `cmdRunPersona` validates persona existence before
  spawning; registry globals set before agent loop to prevent nil
  reference in delegate tool.

## [0.1.1] — 2026-06-14

### Fixed

- **MCP/persona/delegation deep audit (Jun 11)**: 9 issues fixed across 6 files.
  - **delegate.nim**: Wired `canDelegate()` check and `useDelegationSlot()` into
    the delegate tool's execute path — delegation depth is now enforced at
    runtime instead of being dead code. The delegate tool is also registered
    in `cmdRunPersona`'s registry so it's available to persona-scoped agents.
  - **mcp_client.nim**: Added `defer: client.http.close()` in `discoverTools`
    to prevent HTTP handle leaks in long-running processes. Also wrapped the
    `notifications/initialized` POST in try/except so a dropped connection
    between initialize and notification doesn't crash the caller. Removed
    dead `bodyStr` variable (unused `pretty()` call). Fixed misleading
    `discoverTools` comment that claimed to prefix tool names but didn't.
    Included `errCode` in JSON-RPC error messages (was computed but unused).
  - **mcp_tool.nim**: Removed dead `except Exception` branch (unreachable
    after `CatchableError` + `Defect` handlers). Changed `var McpClient`
    parameters to `McpClient` (ref object, no mutation needed). Added
    `finally: client.http.close()` in `registerMcpServer` to prevent HTTP
    handle leak. Added `std/httpclient` import for the close() call.
  - **persona.nim**: Removed tautological condition in `applyPersonaDefaults`
    (`A and A` no-op).
  - **config.nim**: Added `name*: string` to `McpServerConfig` — TOML section
    names (`[mcp_servers.filesystem]` → `"filesystem"`) are now propagated
    through config for use in error messages and future tool-prefixing.
  - **mercury_agent.nim**: Removed unused `mcp_client` import.
  - **delegate.nim**: Removed unused `strutils` import.

### Quality

- **Test quality audit**: Reviewed all 26 test source files (388 tests total).
  Fixed 5 weak tests:
  - `test_agent_dispatcher.nim`: renamed "no-ops" to "are idempotent" — now
    verifies two dispatchers can be started/stopped independently with
    meaningful `d1 != nil and d2 != nil` assertion (replaced `check true`).
  - `test_discord_bot.nim`: renamed "chunked and sent" to "triggers at least
    one send" — test name no longer implies chunking verification which it
    doesn't perform. Also fixed `bot = false` syntax error (`=` → `:`).
  - `test_e2e_discord.nim`: wrapped file tool test file creation/cleanup in
    `try/finally` to guarantee `test_allowed.txt` and `.env_test` are removed
    even if test crashes mid-assertion.
  - `tllm_client.nim`: renamed "sends Authorization header" to "request body
    is well-formed JSON with required keys" — current mock cannot inspect HTTP
    headers; test now accurately describes what it actually verifies.
  - `tcli.nim`: replaced hardcoded `/tmp/mercury-cli-resolved.db` with unique
    temp path (`getTempDir() / "mercury_cli_test_abs_{PID}.db"`) + cleanup.

- **Deep audit (May 30)**: Fixed GC-safety issues across all packages.
  Added `{.gcsafe.}` to all async callback type definitions and closures in
  `discord.nim`, `discord_mocks.nim`, `agent_dispatcher.nim`, and
  `mercury_agent.nim`. Changed test closure patterns from global variable
  capture to `new(AgentResult)` heap allocation to satisfy Nim 2.2.x ORC.
  Exported `jsonRpcResponseId*` from `mcp_client.nim` for test import.
  Fixed unterminated string literal in `test_mcp_client.nim`.
  Added `--threads:on` to `tllm_client.nim` and `--threads:on` to
  `mercury_agent.nimble` test task. Added `threadpool` import to
  `tllm_client.nim` for `Thread` type.

### Security

- All 17 modified files: `AgentCallback`, async proc types, factory
  closures, and test closures are now `{.gcsafe.}` throughout. No
  `{.gcsafe.}` violations in any test file remain.

### Changed

- **mercury_core.nimble**: added `-d:ssl` to all 21 test exec commands,
  `--threads:on` for `tllm_client.nim`; removed dangling `test_discord`
  entry
- **mercury_agent.nimble**: added `--threads:on` for `tagent_loop.nim`
- **mercury_core/config.nims** and **mercury_agent/config.nims**: structure
  for `--threads:on` support

### Added

- **.github/workflows/ci.yml**: `--threads:on` flag added to test jobs for
  `tllm_client.nim` threadpool requirement

[0.1.0]: https://github.com/MrSpaghatti/talos/compare/initial...v0.1.0