## talos_code — autonomous coding harness binary.
##
## Built on the ReAct agent loop from `talos_core/agent_loop`, extended
## with coding-specific tools (compile, test, read_file, write_file) from
## `talos_code/code_tool`.
##
## Usage:
##   talos_code --task "fix the off-by-one error in src/main.nim"
##   talos_code --task "add tests for the parser module"
##   talos_code --task "implement the fizzbuzz function in src/fizzbuzz.nim"
##
## Configuration:
##   Uses the same layered config as `talos_agent` (see talos_core/config).
##   Additional keys (TOML / env):
##     TALOS_SANDBOX_ROOT      — absolute path the agent may touch
##     TALOS_ALLOWED_EXTENSIONS — comma-separated list, e.g. ".nim,.c,.h"
##     TALOS_BUILD_CMD         — build command, run from sandboxRoot
##     TALOS_TEST_CMD          — test command, run from sandboxRoot
##     TALOS_BUILD_TIMEOUT_MS  — build timeout in ms (default 120000)
##     TALOS_TEST_TIMEOUT_MS   — test timeout in ms (default 300000)
##
## Out of scope (deferred):
##   - Docker container sandboxing (Phase 4+)
##   - Multi-file diffs and PR creation
##   - Branch-per-task isolation

import std/[os, strutils, sequtils]

import talos_core/config
import talos_core/tool_registry
import talos_core/build_llm_client
import talos_core/memory
import talos_core/agent_loop
import talos_code/code_runner
import talos_code/code_tool

const Version* = "0.1.0"

proc showHelp =
  echo "talos_code --task <description>"
  echo "  --task <desc>   coding task to execute"
  echo "  --version       print version"
  echo "  --help          this message"
  echo ""
  echo "Environment variables:"
  echo "  TALOS_CONFIG_PATH       path to config.toml"
  echo "  TALOS_DB_PATH          SQLite memory database path"
  echo "  TALOS_SANDBOX_ROOT     absolute path the agent may touch"
  echo "  TALOS_ALLOWED_EXTENSIONS comma-separated, e.g. '.nim,.c,.h'"
  echo "  TALOS_BUILD_CMD       build command run from sandboxRoot"
  echo "  TALOS_TEST_CMD        test command run from sandboxRoot"
  echo "  TALOS_BUILD_TIMEOUT_MS build timeout in ms (default 120000)"
  echo "  TALOS_TEST_TIMEOUT_MS  test timeout in ms (default 300000)"

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

proc main*() =
  let p = paramCount()
  if p >= 1 and paramStr(1) == "--help":
    showHelp()
    quit 0
  if p >= 1 and paramStr(1) == "--version":
    echo "talos_code v", Version
    quit 0

  # Get task from positional argument (after any flags).
  let task =
    if p >= 1: paramStr(1)
    else: ""

  let cfg = loadConfig()
  let llm = buildLLMClient(cfg)
  var mem = newMemory(cfg.dbPath)
  let registry = newToolRegistry()

  # Build CodingHarnessConfig from env / config.
  var harnessCfg = defaultCodingHarnessConfig()
  harnessCfg.sandboxRoot = getEnv("TALOS_SANDBOX_ROOT", "")

  let extEnv = getEnv("TALOS_ALLOWED_EXTENSIONS", "")
  if extEnv.len > 0:
    harnessCfg.allowedExtensions = extEnv.split(',').mapIt(it.strip())
  else:
    harnessCfg.allowedExtensions = @[".nim", ".c", ".h", ".cfg", ".md", ".txt",
                                     ".json", ".toml", ".yml", ".yaml"]

  harnessCfg.buildCmd = getEnv("TALOS_BUILD_CMD", "")
  harnessCfg.testCmd  = getEnv("TALOS_TEST_CMD", "")
  let buildT = getEnv("TALOS_BUILD_TIMEOUT_MS", "")
  harnessCfg.buildTimeoutMs = if buildT.len > 0: parseInt(buildT) else: 120_000
  let testT = getEnv("TALOS_TEST_TIMEOUT_MS", "")
  harnessCfg.testTimeoutMs = if testT.len > 0: parseInt(testT) else: 300_000

  # Register coding tools.
  registry.register(compileTool(harnessCfg))
  registry.register(testTool(harnessCfg))
  registry.register(readFileTool(harnessCfg))
  registry.register(writeFileTool(harnessCfg))

  # Build agent config.
  let agentCfg = newAgentConfig(cfg)

  if task.len == 0:
    echo "Error: no task provided. Run with --help for usage."
    quit 1

  if harnessCfg.sandboxRoot.len == 0:
    echo "Error: TALOS_SANDBOX_ROOT must be set to an absolute directory path."
    quit 1
  if not isAbsolute(harnessCfg.sandboxRoot):
    # withinSandbox() (code_tool.nim) resolves both the sandbox root and
    # every checked path relative to the process's current directory at
    # check time. A relative root would still pass the check above, but a
    # later `setCurrentDir` (e.g. from a build/test command) would shift
    # what it resolves to, turning a supposed sandbox boundary into a
    # moving target — a real escape, not just a validation nicety.
    echo "Error: TALOS_SANDBOX_ROOT must be an absolute path, got '" &
      harnessCfg.sandboxRoot & "'."
    quit 1
  if not dirExists(harnessCfg.sandboxRoot):
    echo "Error: TALOS_SANDBOX_ROOT does not exist or is not a directory: '" &
      harnessCfg.sandboxRoot & "'."
    quit 1

  echo "Starting coding task: ", task
  let result = runAgentLoop(agentCfg, llm, registry, mem, task)
  echo "\nResult (", $result.stopReason, "):\n", result.text
  echo "\nStats: ", result.stats.totalTurns, " turns, ",
        result.stats.toolCallsMade, " tool calls, ",
        result.stats.totalTokens, " tokens"

when isMainModule:
  main()