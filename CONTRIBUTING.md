# Contributing to Talos Agent

## Development Setup

### Prerequisites

- **Nim ≥ 2.0** (recommended: Nim 2.0.x for full builds, Nim 2.2.x for
  core-only development)
- **nimble** (Nim's package manager)
- **SQLite** (with FTS5 support — included in standard SQLite ≥ 3.9)
- **OpenRouter API key** (or any OpenAI-compatible endpoint) for running
  the agent; tests use mocks and need no API key

### Environment

```bash
git clone <repo-url>
cd talos-agent

# Create an .env for your API key (tests don't need this)
cp .env.example .env
# Edit .env and set OPENROUTER_API_KEY=sk-or-...

# Install nimble dependencies
cd talos_core && nimble install -y
cd ../talos_agent && nimble install -y
cd ..
```

---

## Building

### Core library only (always works)

```bash
cd talos_core && nimble build
```

### Full build (CLI + Discord daemon)

```bash
make build
```

> **SSL compatibility**: Both packages pass `--define:ssl` via `config.nims`,
> which resolves the `raiseSSLError` issue that existed in Nim 2.2.x.
> The build works on both Nim 2.0.x and Nim 2.2.x.

---

## Testing

### Run everything

```bash
make test
```

### Run core tests only

```bash
cd talos_core && nimble test
```

### Run agent tests only

```bash
cd talos_agent && nimble test
```

### Run a single test file

```bash
cd talos_core && nim c --path:src -r tests/tconfig.nim
cd talos_agent && nim c --path:src -r tests/tcli.nim
```

### Run Discord-specific tests

```bash
cd talos_core
nim c -r tests/test_discord_mocks.nim
nim c -r tests/test_discord_commands.nim
nim c -r tests/test_discord_bot.nim
nim c -r tests/test_e2e_discord.nim
```

### Code formatting

```bash
make nph
nimpretty src/talos_core/src/talos_core/*.nim
```

---

## Project Structure

```
talos/
├── talos_core/              # Shared library (no binary)
│   ├── src/talos_core/      # 19 source modules (incl. agent_loop.nim,
│   │                         # build_llm_client.nim)
│   └── tests/                 # 20+ test files
├── talos_agent/             # CLI + Discord daemon binary
│   ├── src/                   # talos_agent.nim, tools/
│   └── tests/                 # tagent_loop, tcli, tintegration, test_shell_tool
├── talos_code/              # Autonomous coding harness binary
│   ├── src/talos_code/      # talos_code.nim, code_runner.nim,
│   │                         # code_tool.nim, compile.nim, config.nims
│   └── tests/                 # tcode_runner (23 tests)
├── Makefile                   # build/test/lint shortcuts
└── *.md                       # Documentation
```

### Module dependency graph (simplified)

```
config.nim ──▶ llm_client.nim ──▶ agent_loop.nim (talos_core) ──▶ talos_agent.nim
     │                               │
     └──▶ memory.nim ────────────────┘
          tool_registry.nim ─────────┘
               │
               ├── tools/shell.nim
               ├── file_tool.nim
               └── file_path_validator.nim

discord.nim ──▶ discord_commands.nim ──▶ agent_dispatcher.nim ──▶ agent_loop
     │                                      │
     ├── discord_bridge.nim                 └── permission.nim
     ├── discord_types.nim                       │
     ├── discord_mocks.nim                       ├── file_tool.nim
     ├── message_chunker.nim                     ├── rate_limit.nim
     └── thread_mapping.nim                      └── file_path_validator.nim

talos_code.nim ──▶ agent_loop ──▶ build_llm_client ──▶ llm_client
     │
     ├── code_runner.nim   (CompileResult, parseNimErrors, CodingHarnessConfig)
     ├── code_tool.nim     (compile, test, read_file, write_file tools)
     └── compile.nim       (subprocess execution with timeout)
```

---

## Code Conventions

### General

- Modules have a docstring header summarizing their intent and explicitly
  listing what is out of scope.
- Public procs use `*` and have a docstring.
- Imports are grouped: `std/*` first, then package imports, then local.
- Lines wrap at 80 columns for docstrings and comments; code can go to
  100 where readability benefits.

### Error handling

- Use typed exceptions (`ConfigError`, `LLMError`, `MemoryError`,
  `ToolNotFoundError`, etc.) — never raise or catch generic
  `CatchableError` unless unavoidable (see below).
- Catch `CatchableError` in top-level event loops (CLI REPL, Discord
  message handler) to prevent crashes from propagating to the user.
- Never catch `Defect` (assertions, index errors, etc.) — let them crash.
- Tool execution procs use `{.gcsafe, raises: [].}` — the registry wraps
  escaped exceptions into `ToolResult{isError: true}`.

### Testing

- One `suite` per behavior cluster; one `test` per scenario.
- Use `check` for assertions, `expect` for exception testing.
- Mock external dependencies (HTTP, filesystem, Discord API) rather than
  making real network calls.
- In-memory SQLite (`:memory:`) for memory module tests.

### Discord-specific

- All Discord API operations go through injected callback procs
  (`SendMessageFn`, `TriggerTypingFn`, etc.) — never call Dimscord
  directly from a module that should be testable.
- New commands add a handler proc in `discord_commands.nim` and wire it
  in the command dispatch table. Add tests in `test_discord_commands.nim`.

---

## Adding a New Tool

1. Create the tool module in `talos_core/src/talos_core/` (or
   `talos_agent/src/tools/` if it depends on agent-layer resources).
2. Define a `proc toolFn(args: JsonNode, ...): string` that matches
   `ToolExecuteProc` signature `{.gcsafe, raises: [].}`.
3. Register it in `buildRegistry()` in `talos_agent.nim` (CLI) or
   in the Discord daemon's `cmdDaemon` (Discord).
4. Add tests in `talos_core/tests/` or `talos_agent/tests/`.

---

## Test Suite

**518 tests pass** across 30 test files (391 core + 98 agent + 29 code), 0 FAILED.

After any change, run `make test` from the project root. This builds and
tests both packages, with proper exit-code propagation so CI or your local
shell will catch regressions.

### Code health verified (May 29, 2026 deep audit)

- **Error handling**: All production `except` blocks use `CatchableError`
  rather than `Exception` (except the documented `file_tool.nim` dual-catch
  required by Nim 2.2.x + `-d:ssl`).
- **Thread safety**: Zero global mutable state in production code.
- **Security**: Shell tool deny-list (22 patterns), path validation with
  sandbox boundaries, role-based permission system.
- **No unsafe Nim patterns**: No `cast`, pointer arithmetic, or raw memory
  access in production code.
- **No resource leaks**: All DB connections, sockets, and processes are
  closed via `defer` or `try/except/finally`.

## Known Issues

| Issue | Module | Workaround |
|-------|--------|------------|
| `tllm_client` hangs ~2s on exit | `llm_client.nim` tests | Run tests individually with `nim c -r` |

### Previously Fixed

| Issue | Fix |
|-------|-----|
| `raiseSSLError` removed in Nim 2.2.x | `config.nims` passes `--define:ssl` in both packages |
| `nre` package unlisted dependency | Replaced with `std/re` |
| `Exception` catch in `file_tool` | Changed to `CatchableError` (with dual-catch comment for SSL mode) |
| Permission tool-name mismatch for shell | Added `"shell"` mapping to high-risk list |
| Redundant `setControlCHook` | Removed duplicate call in daemon branch |
| `*.nims` gitignored (config.nims untracked) | Removed `*.nims` from `.gitignore`, force-tracked `config.nims` files |

---

## Releasing

1. Update the `version` field in all three `.nimble` files.
2. Update `STATUS.md` with the new version and date.
3. Tag the release: `git tag v0.X.Y && git push origin v0.X.Y`.
4. (Future) CI will build binaries and create a GitHub Release.
