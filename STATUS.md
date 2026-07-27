# Talos Agent — Development Status

**Last Updated**: July 24, 2026
**Project Path**: `/home/spag/talos`
**Phase**: Phase 1+2 complete. Tasks 1, 2, 3, 4, 6, & 8 (of 8) done; Task 5 (Vector Memory) and Task 7 (MCP Streaming) remaining. Onboarding fixes + deep-dive audits complete (2026-07-22, 2026-07-24).

---

## Summary

All planned waves are implemented and verified. Talos is a fully functional
AI agent with:

- **CLI agent** (`chat`, `ask`, `session`, `history`, `search`)
- **Discord daemon** (DI-based bot with permissions, threads, file tools)
- **Persistent memory** (SQLite + FTS5 full-text search)
- **ReAct loop** with loop detection, error recovery, and configurable limits
- **Streaming responses** (SSE) — token-by-token CLI output via `chatCompletionStream`;
  Discord progressive edits deferred (requires threading)
- **Web UI** — single-page chat interface served via `talos_agent web`,
  with session browsing, full-text search, and chat via REST API
- **Tool system** with sandboxed shell, file read/write, permission checks,
  MCP client bridge, and persona-scoped agent delegation
---

## Completed

### Phase 1 Wave 1: Foundation (100%)
| Task | Module | Tests |
|------|--------|-------|
| 1.1 Config (TOML + .env + env vars) | `config.nim` | 35/35 pass |
| 1.2 LLM client (OpenAI Chat Completions) | `llm_client.nim` | 16/16 pass |
| 1.3 Token counter (heuristic) | `token_counter.nim` | 14/14 pass |
| 1.4 SQLite memory + FTS5 | `memory.nim` | 27/27 pass |

### Phase 1 Wave 2: Agent Core (100%)
| Task | Module | Tests |
|------|--------|-------|
| 2.1 Tool registry + shell tool | `tool_registry.nim`, `tools/shell.nim` | 20/20 pass |
| 2.2 ReAct agent loop | `agent_loop.nim` | 10/10 pass |
| 2.3 Mock HTTP server | `mock_server.nim` | 3/3 pass |

### Phase 1 Wave 3: CLI + Integration (100%)
| Task | Module | Tests |
|------|--------|-------|
| 3.1 CLI interface (cligen) | `talos_agent.nim` | 19/19 pass |
| 3.2 Integration wiring | `talos_agent.nim` | 17/17 pass (integration tests) |
| 3.3 End-to-end tests + docs | `tagent_loop`, `tcli`, `tintegration` | All pass |
| Agent shell tool | `test_shell_tool.nim` | 18/18 pass |

### Phase 2 Discord Integration (100%)
| Module | Responsibility | Key Features |
|--------|----------------|--------------|
| `discord.nim` | DI-based bot object | Callback injection, shard, agent dispatcher wiring |
| `discord_commands.nim` | Command handler | `!status`, `!config`, `!admin`, `!session` — with permission checks |
| `discord_bridge.nim` | Real Discord API adapter | `sendMessage`, `triggerTyping`, `createThread`, `archiveThread` |
| `discord_types.nim` | Shared types | `DiscordConfig`, `DiscordUser`, `FileRules` |
| `discord_mocks.nim` | Mock implementations | `MockDiscordApi`, `MockShard` for offline testing |
| `permission.nim` | Permission evaluator | User allow/deny lists, tool risk levels, path-based file rules |
| `file_path_validator.nim` | Path safety | Path traversal guards, deny-list, percent-decode |
| `file_tool.nim` | File read/write tools | Pattern-based allow/deny paths |
| `message_chunker.nim` | Discord message chunking | Splits long messages at 2000-char Discord limit |
| `rate_limit.nim` | Rate limiter | Per-user token-bucket rate limiting |
| `thread_mapping.nim` | Thread persistence | Maps Discord channel+user to persistent agent threads |
| `agent_dispatcher.nim` | Async agent runner | Queues agent requests with callback for result delivery |

### Quality / Infrastructure (100%)
| Item | Status |
|------|--------|
| `make build` (core + agent + code) | ✅ Compiles (see SSL note below) |
| `make test` (core + agent + code) | ✅ All 557 tests pass, 0 FAILED |
| `nim check` (core + agent) | ✅ No static analysis errors |
| `.env` / `.env.example` | ✅ Configured |
| `.gitignore` | ✅ Covers all build artifacts |
| Architectural review | ✅ `AUDIT_REPORT.md` written |
| Hardening pass (2026-07-19) | ⚠️ Found & fixed 7 real bugs incl. 2 sandbox-escape issues and a broken compile path — see CHANGELOG `[Unreleased]` |
| CI pipeline (GitHub Actions) | ✅ Passing on Nim 2.0.8 and 2.2.2 |

---

## Known Issues (Discovered during Code Audit)

### ~~🔴 SSL build failure with dimscord on Nim 2.2.10~~ ✅ Fixed

> **Fixed**: `config.nims` in both packages now pass `--define:ssl`, which
> ensures `defineSsl` is consistently true across all modules, resolving the
> `raiseSSLError` lookup. Both `make build` and `make test` work on Nim 2.2.10.

### 🟡 LLM client test slow exit

`tllm_client.nim` starts a mock TCP server in a thread that doesn't join
cleanly on process exit. The test passes but hangs for ~2 seconds at
shutdown. Run individual tests with `nim c -r` to avoid the batch issue.

---

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│                    talos_agent (CLI)                    │
│  ┌──────────┐  ┌──────────────┐  ┌──────────────────┐   │
│  │ cligen   │  │ talos_core │  │ tools/shell.nim  │   │
│  │ dispatch │──▶│ agent_loop   │──▶ (sandboxed shell)│   │
│  └──────────┘  │ (ReAct loop) │  └──────────────────┘   │
│                └──────┬───────┘                           │
│                       │                                   │
│  ┌─────────────────────┐   ┌─────────────────────────┐   │
│  │ talos_core/       │   │ talos_core/           │   │
│  │ llm_client.nim      │   │ memory.nim (SQLite+FTS5)│   │
│  │ config.nim          │   │ tool_registry.nim       │   │
│  └─────────────────────┘   └─────────────────────────┘   │
├──────────────────────────────────────────────────────────┤
│                 talos_agent (Daemon)                    │
│  ┌──────────────────────────────────────────────────┐   │
│  │ dimscord ─▶ discord_bridge ─▶ discord.nim         │   │
│  │                                        │          │   │
│  │                    ┌─────────────────────┘          │   │
│  │                    ▼                                 │   │
│  │              discord_commands.nim                    │   │
│  │                    │                                 │   │
│  │                    ▼                                 │   │
│  │  agent_dispatcher.nim ─▶ talos_core/agent_loop    │   │
│  └──────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────┘
```

---

## Files by Layer

### talos_core (19 modules)
| File | Role |
|------|------|
| `config.nim` | Layered config (TOML + .env + env vars) |
| `llm_client.nim` | OpenAI-compatible HTTP client |
| `token_counter.nim` | Heuristic token estimation |
| `memory.nim` | SQLite + FTS5 persistence |
| `tool_registry.nim` | Named tool registration + JSON schema export |
| `agent_loop.nim` | ReAct loop: LLM → tool → loop |
| `build_llm_client.nim` | TalosConfig → LLMClient builder |
| `discord.nim` | DI-based Discord bot |
| `discord_bridge.nim` | Real Discord API adapter (Dimscord) |
| `discord_commands.nim` | Bot command handlers |
| `discord_types.nim` | Shared Discord types |
| `discord_mocks.nim` | Mock API for offline testing |
| `agent_dispatcher.nim` | Async agent request queue → agent_loop |
| `permission.nim` | User/tool permission evaluation |
| `file_path_validator.nim` | Path traversal protection |
| `file_tool.nim` | File read/write agent tools |
| `message_chunker.nim` | Discord message size splitting |
| `rate_limit.nim` | Per-user token bucket rate limiter |
| `thread_mapping.nim` | Discord→agent thread persistence |

### talos_agent (3 modules)
| File | Role |
|------|------|
| `talos_agent.nim` | CLI entry point + subcommand dispatch |
| `tools/shell.nim` | Sandboxed shell tool with deny-list, timeout |
| `tools/` | Tool implementations directory |

### talos_code (5 modules)
| File | Role |
|------|------|
| `talos_code.nim` | CLI binary entry point |
| `code_runner.nim` | CompileResult, parseNimErrors, CodingHarnessConfig |
| `code_tool.nim` | compile/test/read_file/write_file tools |
| `compile.nim` | Subprocess compile execution with timeout |
| `config.nims` | Nimble compiler switches (-d:ssl, path resolution) |

---

## Test Coverage

| Package | Test files | Tests | Status |
|---------|-----------|-------|--------|
| talos_core (Wave 1) | tconfig, tllm_client, ttoken_counter, tmemory | 134 | ✅ All pass |
| talos_core (Wave 2) | ttool_registry, test_mock_server | 22 | ✅ All pass |
| talos_core (Discord) | test_permission, test_file_*, test_rate_limit, test_thread_*, test_daemon_delegation, test_message_chunker, test_discord_*, test_e2e_discord | 153 | ✅ All pass |
| talos_core (MCP) | test_mcp_client, test_mcp_tool | 46 | ✅ All pass |
| talos_core (Persona) | test_persona | 22 | ✅ All pass |
| talos_core (Plan-Execute) | test_plan_executor | 35 | ✅ All pass |
| talos_agent | tcli, tagent_loop, tintegration, tdelegate_tool, tweb_server, test_shell_tool, tbench, ttui_streaming | 113 | ✅ All pass |
| talos_code | tcode_runner | 32 | ✅ All pass |
| **Total** | **31 test files** | **557** | **✅ 0 FAILED** |

---

## Next Steps

Seven long-horizon tasks planned. Detailed specs in `plans/task-*.md`.
See [ROADMAP.md](ROADMAP.md) for the tracking table and execution order.

### ✅ Done

1. **Task 1 — Agent Loop + Dispatcher** — `agent_loop.nim` moved to `talos_core`,
   SQLite WAL + busy_timeout in `memory.nim`, dispatcher wired to real `AgentResult`.
2. **Task 4 — Code Quality** — silent CatchableError discards logged, dead code removed,
   OpenRouter API key warning, TODO comments updated.
3. **Task 2 — Streaming** — SSE streaming via `chatCompletionStream` in `llm_client.nim`,
   `streamCallback` in `AgentConfig`, token-by-token CLI output, `--no-stream` flag.
   Discord progressive edits deferred (blocked on dimscord `--threads:on`).
4. **Task 3 — Web UI** — `talos_agent web` subcommand, `web_server.nim` with
   asynchttpserver, SPA with session search/listing, chat via `/api/chat`.
   SSE streaming deferred (asynchttpserver limitation).

5. **Task 6 — Plan-Execute Mode** — `plan_executor.nim` in `talos_core`,
   `--plan` flag on `talos_agent ask`, topological step execution with
   dependency tracking, failure handling, and final synthesis. 35 tests.
   Audited and fixed: removed redundant `tools` param from `generatePlan`,
   fixed double-print in streaming mode, fixed zero token logging for
   synthesis, added `ToolNotFoundError` guard, added real-time step
   status display via `stepCallback`, hardened `topoSort` with `PlanError`
   and O(1) queue.
6. **Task 8 — Advanced TUI** — illwill-based fullscreen terminal UI with
   scrollable transcript, streaming rendering, multi-line input with history.

### Remaining (recommended order)

1. **Task 5 — Vector Memory** (`plans/task-05-vector-memory.md`) — build
   directly in the `retain`/`recall`/`reflect` shape rather than one opaque
   memory tool (see cross-reference note at the top of that file), and
   check the `sqlite-vec` FFI approach (`plans/research-sqlite-vec-nim-ffi.md`)
   against the plan's brute-force cosine-similarity phase before implementing.
2. **Task 7 — MCP Streaming** (`plans/task-07-mcp-streaming.md`) — fold in
   URI-scheme tool addressing (`read`/`search`/`write` dispatching on URI
   prefix, covering both local resources and MCP resources) as part of the
   same design pass, not as a follow-on.

See [ROADMAP.md](ROADMAP.md)'s "Feature Adoption Backlog" section for eight
additional smaller items (task-11 through task-18) sourced from a 2026-07-25
comparative review of oh-my-pi, OpenCode, and Claude Code — full rationale in
`plans/feature-adoption-report.md`. Three of them (`/btw`, preview-edit,
model routing) are cheap and unblocked; the rest sequence around Task 5/7 or
are deferred.
