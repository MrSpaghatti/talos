
 # Talos Agent

[![CI](https://github.com/MrSpaghatti/talos/actions/workflows/ci.yml/badge.svg)](https://github.com/MrSpaghatti/talos/actions/workflows/ci.yml)

Talos is a small, self-contained Nim **AI agent** built around the
OpenAI Chat Completions protocol. It speaks to any OpenAI-compatible
endpoint (OpenRouter, vLLM, OpenAI, …), exposes tools to the model via
function calling, persists every conversation to a local SQLite
database with FTS5 full-text search, and ships a CLI for chatting with
the agent or browsing past sessions.

```
+-----------------+     +-------------------+     +----------------+
|  talos_agent    | --> | talos_core/llm    | --> |  LLM endpoint  |
|     (CLI)       |     |     _client       |     |   (HTTP/JSON)  |
+--------+--------+     +-------------------+     +----------------+
         |
         |  ReAct loop
         v
+--------+--------+     +-------------------+     +----------------+
|   agent_loop    | --> |   tool_registry   | --> |  shell, ...    |
+--------+--------+     +-------------------+     +----------------+
         |
         |  appendMessage / getHistory / searchHistory
         v
+--------+--------+
|  memory (SQLite |
|     + FTS5)     |
+-----------------+
```

## Features

- **Provider agnostic** — works with any OpenAI-compatible Chat
  Completions endpoint. Built-in defaults for OpenRouter and vLLM.
- **Tool calling** — register Nim procs as tools; the model invokes
  them via OpenAI function-calling. Ships with a sandboxed `shell`
  tool (deny-list + per-call timeout), plus `file_read` and
  `file_write` tools with path-based allow/deny policies.
- **Persistent memory** — every conversation is logged to SQLite with
  a FTS5 full-text index over message content.
- **CLI** — `chat`, `ask`, `session`, `history`, `search`.
- **Discord daemon** — run Talos as a Discord bot with DI-based
  architecture, permission system, thread management, rate limiting,
  and offline-testable mock API.
- **Loop & error safety** — agent loop has loop-detection, max-iteration
  limits, and graceful handling of LLM/tool errors.
- **Plan-Execute mode** — `ask --plan` asks the LLM to decompose the goal
  into a structured plan, then executes steps in dependency order with
  tool calls and reasoning, before synthesising a final answer.
- **Layered configuration** — defaults < TOML config < .env <
  environment variables.

## Layout

```
talos/
├── talos_core/       # shared library
│   ├── src/            # config, llm_client, memory,
│   │                   # tool_registry, token_counter,
│   │                   # agent_loop.nim (ReAct loop),
│   │                   # discord.nim (DI bot),
│   │                   # discord_bridge, discord_commands,
│   │                   # discord_types, discord_mocks,
│   │                   # agent_dispatcher, permission,
│   │                   # file_path_validator, file_tool,
│   │                   # message_chunker, rate_limit,
│   │                   # thread_mapping, build_llm_client
│   └── tests/          # 20+ test files covering all modules
├── talos_agent/      # CLI binary (talos_agent.nim,
│   ├── src/            # tools/shell.nim)
│   └── tests/          # tagent_loop, tcli, tintegration, test_shell_tool
├── talos_code/       # autonomous coding harness binary
│   ├── src/            # talos_code.nim, code_runner.nim,
│   │                   # code_tool.nim, compile.nim, config.nims
│   └── tests/          # tcode_runner (23 tests)
├── Makefile
├── STATUS.md           # current state of the project
├── AUDIT_REPORT.md     # deep dive audit report and next steps
└── README.md           # this file
```

## Quick start

### Prerequisites

- Nim ≥ 2.0 (we use 2.2.10)
- `nimble`
- SQLite shared library (with FTS5 — included in standard SQLite ≥ 3.9)
- OpenSSL dependencies (`libssl-dev`)

### Build

```bash
make build           # builds both talos_core and talos_agent
# or, equivalently:
cd talos_core   && nimble build
cd talos_agent  && nimble build
```

## Further Reading

Talos looks for configuration in three places, **highest priority first**:

1. Environment variables (e.g. `TALOS_PROVIDER=openrouter`).
2. `.env` in the current directory (typically your API key).
3. `~/.config/talos/config.toml` (or the path passed to `--config`).

Minimal `.env`:

```bash
OPENROUTER_API_KEY=sk-or-...
```

Optional `~/.config/talos/config.toml`:

```toml
[talos]
provider = "openrouter"
openrouter_model = "anthropic/claude-3.5-sonnet"
max_tokens = 4096
temperature = 0.3
max_loop_iterations = 10
db_path = "~/.local/share/talos/talos.db"
```

### Run

```bash
# One-shot question
./talos_agent/talos_agent ask "what is the capital of France?"

# Interactive chat
./talos_agent/talos_agent chat

# List recent sessions
./talos_agent/talos_agent history

# Full-text search across all stored messages
./talos_agent/talos_agent search "capital of France"

# Resume an existing session (history is shown read-only; new turns
# go to a fresh session)
./talos_agent/talos_agent session sess_20260101T120000_123456789

# Per-run overrides (no need to edit the config file)
./talos_agent/talos_agent ask "ping" \
    --provider=vllm --model=qwen2.5-7b-instruct --temperature=0.1

# Run as a Discord bot (set DISCORD_BOT_TOKEN first)
export DISCORD_BOT_TOKEN="your_token_here"
./talos_agent/talos_agent daemon
```

## CLI usage

```
talos_agent <subcommand> [options]

Subcommands:
  chat                    Interactive REPL.
  ask <question>          Single-shot question.
  session <id>            Print history of a session and continue chatting
                          (new turns go to a new session).
  history                 List most recently updated sessions.
  search <query>          FTS5 search across stored messages.
  run <persona> <task>    Run a named persona with a given task.
  web                     Start the web UI HTTP server (blocking).
  daemon                  Start the Discord bot daemon (blocking).

Common options (chat / ask / session):
  --model=<name>          Override model name for the active provider.
  --provider=<name>       Override provider (openrouter | vllm).
  --temperature=<float>   Override sampling temperature (0..2). Negative
                          means leave at config default.
  --config=<path>         Path to TOML config (overrides default).
  --envFile=<path>        Path to .env (default: .env).
  --noStream              Disable token-by-token streaming output.

Option for ask only:
  --plan                  Use plan-execute mode (LLM decomposes into steps,
                          executes them, synthesises a final answer).


Options for history / search:
  --limit=<n>             Max sessions / matches to show.
  --config=<path>         Path to TOML config (overrides default).
  --envFile=<path>        Path to .env (default: .env).

Run `talos_agent --help` or `talos_agent <subcommand> --help` for
the full list.
```

## Configuration reference

| Key (TOML)            | Env var                       | Default                                      | Description                                      |
| --------------------- | ----------------------------- | -------------------------------------------- | ------------------------------------------------ |
| `provider`            | `TALOS_PROVIDER`            | `openrouter`                                 | Active provider: `openrouter` or `vllm`.         |
| `openrouter_endpoint` | `TALOS_OPENROUTER_ENDPOINT` | `https://openrouter.ai/api/v1`               | OpenRouter base URL.                             |
| `openrouter_model`    | `TALOS_OPENROUTER_MODEL`    | `openrouter/auto`                            | Model name used when provider=openrouter.        |
| `vllm_endpoint`       | `TALOS_VLLM_ENDPOINT`       | `http://192.168.4.30:8000/v1`                | vLLM base URL.                                   |
| `vllm_model`          | `TALOS_VLLM_MODEL`          | `qwen2.5-7b-instruct`                        | Model name used when provider=vllm.              |
| `max_tokens`          | `TALOS_MAX_TOKENS`          | `4096`                                       | Per-request `max_tokens`.                        |
| `temperature`         | `TALOS_TEMPERATURE`         | `0.3`                                        | Sampling temperature in `[0, 2]`.                |
| `max_loop_iterations` | `TALOS_MAX_LOOP_ITERATIONS` | `10`                                         | Hard cap on ReAct iterations per query.          |
| `db_path`             | `TALOS_DB_PATH`             | `~/.local/share/talos/talos.db`              | SQLite database path. `~` expands to `$HOME`.    |
| `web_port`            | `TALOS_WEB_PORT`            | `8080`                                       | Port for the web UI HTTP server.                 |
| `discord.token_env`   | `DISCORD_BOT_TOKEN`           | `DISCORD_BOT_TOKEN`                          | Env var holding the Discord bot token.          |
| `discord.prefix`      | `DISCORD_PREFIX`              | `!`                                          | Command prefix for bot commands.                |
| `discord.admins.allow`| (TOML only)                   | `[]`                                         | Discord user IDs with admin privileges.         |
| `discord.file_rules`  | (TOML only)                   | see `talos_core/DISCORD.md`                  | File access allow/deny patterns.                |
| (n/a)                 | `OPENROUTER_API_KEY`          | (empty)                                      | API key sent as `Authorization: Bearer ...`.     |

`.env` is also read (in `loadConfig`) for `OPENROUTER_API_KEY`,
`TALOS_PROVIDER`, and `TALOS_VLLM_ENDPOINT` — useful when you don't
want to export those variables globally.

## Architecture overview

### `talos_core/`

| Module              | Responsibility                                                                  |
| ------------------- | ------------------------------------------------------------------------------- |
| `config.nim`        | Loads `TalosConfig` from defaults + TOML + `.env` + env vars; validates.       |
| `llm_client.nim`    | Synchronous OpenAI-compatible Chat Completions client with retry/error types.   |
| `tool_registry.nim` | Named registry of tools; serializes to OpenAI `tools` array; safe execution.    |
| `memory.nim`        | SQLite + FTS5: sessions, messages, full-text search, token-usage aggregation.   |
| `agent_loop.nim`    | ReAct loop: build prompt, call LLM, dispatch tool calls, log to memory.         |
| `plan_executor.nim` | Plan-Execute mode: LLM-generated plan, topo-sorted step execution, synthesis. |
| `token_counter.nim` | Cheap heuristic token counter used to size requests.                            |

### `talos_core/` — Discord & Agent Infrastructure

| Module                  | Responsibility                                                              |
| ----------------------- | --------------------------------------------------------------------------- |
| `discord.nim`           | DI-based Discord bot: `DiscordBot` ref object with injected API callbacks.  |
| `discord_bridge.nim`    | `RealDiscordApi` — wraps dimscord REST API (send, typing, threads).         |
| `discord_commands.nim`  | Command parser + handlers for `!status`, `!config`, `!admin`, `!session`.   |
| `discord_types.nim`     | Shared types (`DiscordConfig`, `DiscordUser`, `FileRules`).                  |
| `discord_mocks.nim`     | `MockDiscordApi`, `MockShard` — full offline Discord simulation for tests.  |
| `agent_dispatcher.nim`  | Async agent request queue: accepts messages, dispatches to agent loop,      |
|                         | returns result via callback.                                                |
| `permission.nim`        | Permission evaluator: user allow/deny lists, tool risk levels, path checks. |
| `file_path_validator.nim`| Path traversal protection, canonicalization, deny-list matching.            |
| `file_tool.nim`         | `fileReadTool` / `fileWriteTool` with pattern-based allow/deny.             |
| `message_chunker.nim`   | Splits long messages at the Discord 2000-char limit.                        |
| `rate_limit.nim`        | Per-user token-bucket rate limiter.                                         |
| `thread_mapping.nim`    | Persistent Discord channel→thread mapping backed by SQLite.                 |

### `talos_agent/`

| Module                  | Responsibility                                                              |
| ----------------------- | --------------------------------------------------------------------------- |
| `talos_agent.nim`     | CLI wiring + subcommand entry points (`chat`, `ask`, `session`, `daemon`).  |
| `tools/shell.nim`       | Shell tool with deny-list and per-call timeout.                             |

The agent loop's contract is simple:

```nim
proc runAgentLoop*(
    cfg: TalosConfig;
    llm: LLMClient;
    registry: ToolRegistry;
    memory: var Memory;
    userInput: string;
): AgentResult
```

It returns once the model emits a final text answer, the iteration cap
is hit, or the loop detector fires (same tool + same args N times in a
row).

## Development

### Build & test

```bash
make build           # build both packages
make test            # run all tests (talos_core + talos_agent)
```

> **Note**: The full build (including the Discord daemon) now works on
> Nim 2.2.10. Both packages pass `--define:ssl` via `config.nims` to handle
> the `raiseSSLError` compatibility issue introduced in Nim 2.2.x.

Equivalent commands:

```bash
cd talos_core   && nimble test
cd talos_agent  && nimble test
```

### Test layout

The test suite is split into focused modules:

- `talos_core/tests/`
  - `tconfig.nim` — config defaults, TOML parsing, env-var precedence,
    `validate`.
  - `tllm_client.nim` — request building, response parsing, retry logic,
    typed errors.
  - `tmemory.nim` — sessions, append/getHistory, FTS5, token usage.
  - `ttool_registry.nim` — registration, execution, OpenAI serialization.
  - `ttoken_counter.nim` — heuristic counter sanity checks.
  - `mock_server.nim` — `MockLLMServer`, an in-process HTTP mock used by
    integration tests.
  - `test_*.nim` — 11 Discord/security test files (permission, file_tool,
    rate_limit, thread_mapping, message_chunker, agent_dispatcher,
    discord_bot, discord_commands, discord_mocks, discord_config,
    e2e_discord, and reconnection).

- `talos_agent/tests/`
  - `tagent_loop.nim` — ReAct loop driven against the mock server: text
    answer, tool-call turn, max iterations, loop detection, tool errors,
    memory logging, the `TalosConfig` overload.
  - `tcli.nim` — config-override layering, recent-session listing,
    `cmdHistory`/`cmdSearch`/`cmdAsk`/`cmdSession` argument validation,
    binary `--help` smoke test.
  - `test_shell_tool.nim` — deny-list matching, command execution,
    timeout handling, tool registry integration.
  - **`tintegration.nim`** — full end-to-end stack: `loadConfig` →
    `LLMClient` → `ToolRegistry` (with the real `shellTool`) →
    SQLite-backed `Memory` → `runAgentLoop`. Covers:
      1. **Full pipeline** — text-only response, tool-call response,
         LLM error path; verifies session is created and history is
         logged correctly.
      2. **Config loading** — defaults, TOML overrides, env-var
         precedence, `.env` API-key loading, validation rejection.
      3. **Memory persistence** — multi-message session round-trip,
         FTS5 search across multiple sessions, on-disk persistence
         across reopen.
      4. **Tool registry** — register `shellTool`, execute, deny-list,
         malformed JSON, OpenAI definition serialization, duplicate
         registration error.
      5. **Agent loop** — full ReAct turn (tool call → tool result →
         final answer) with full memory log assertions; on-disk
         persistence + FTS5 search of agent output across reopen.

### Running a single test file

```bash
cd talos_agent
nimble c -r tests/tintegration.nim
```

### Coding style

- Modules have a docstring header summarizing intent and out-of-scope
  items.
- Public procs use `*` and have docstrings.
- Errors are typed (`ConfigError`, `LLMError` subtypes, `ToolError`
  subtypes, `MemoryError`) and never leak generic `CatchableError` to
  callers when avoidable.
- Tests use `unittest`, with one suite per behaviour cluster.

## Code Formatting

Use `nimpretty` (Nim's official formatter) to format code:

```bash
nimpretty src/talos_core/src/talos_core/*.nim
nimpretty src/talos_agent/src/*.nim
```

The `nph` Make target attempts to run it; `nimpretty` is included with Nim.

## Development Status

Talos is currently **Phase 1 (Foundation) + Phase 2 (Discord) +
 Phase 3 P1 (talos_code) — all complete**. See `STATUS.md` for the
 full status breakdown.

### Roadmap

| Phase | What | Status |
|-------|------|--------|
| 1.1–1.4 | Core library (config, LLM, tokens, memory) | ✅ Complete |
| 2.1–2.3 | Agent core (tools, ReAct loop, mocks) | ✅ Complete |
| 3.1–3.3 | CLI, integration, end-to-end tests | ✅ Complete |
| Phase 2 | Discord bot with permissions, threads, file tools | ✅ Complete |
| P0 | CI pipeline (GitHub Actions on Nim 2.0.8 + 2.2.2) | ✅ Complete |
| P0 | Deep code audit (40+ source files, 312+ tests) | ✅ Complete |
| P1 | `talos_code` — coding harness (compile, test, read_file, write_file) | ✅ Complete |
| P2 | MCP support for external tool discovery | 🔜 Planned |
| P2 | Sub-agent delegation for parallel work | 🔜 Planned |
| P3 | Web UI (lightweight HTTP chat frontend) | 🔜 Planned |

## License

MIT.
