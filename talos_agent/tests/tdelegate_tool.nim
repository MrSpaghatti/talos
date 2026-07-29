## Tests for the delegate tool execute proc.
##
## Directly tests `makeDelegateExecuteProc()` by setting up `gGlobals` and
## calling the returned closure with various argument combinations. These
## are pure unit tests that exercise the error-guard paths without running
## an agent loop or mock server.

import std/[json, unittest, strutils, os, times, tables]

import talos_core/config
import talos_core/delegate
import talos_core/persona
import talos_core/tool_registry
import talos_core/llm_client

import talos_agent

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

let testDbPath = getTempDir() / ("talos_delegate_test_" &
  $getCurrentProcessId() & "_" & $epochTime() & ".db")
  ## A handful of these tests exercise real delegate-tool execution, which
  ## opens a Memory via `resolveDbPath(cfg)` and persists messages
  ## (`delegate_tool.nim`). Without an explicit override here, `cfg.dbPath`
  ## falls back to the real default (`~/.local/share/talos/talos.db`) —
  ## every `nimble test` run was silently writing junk sessions into
  ## whatever database the person running the tests actually uses.
  ## Cleaned up at the bottom of this file, after all suites have run.

proc resetGlobals() =
  ## Resets global state between tests to avoid cross-test contamination.
  gGlobals = nil

proc makeMinimalLLM(): LLMClient =
  ## Returns a minimal LLMClient with a non-empty baseUrl so delegation
  ## guards pass. The URL is fake — tests that exercise full delegation
  ## need a running mock server.
  result = LLMClient(baseUrl: "http://localhost:19999/v1")

proc makeRegistryWithPersona(name: string): PersonaRegistry =
  ## Returns a PersonaRegistry containing one persona with the given name.
  result = newPersonaRegistry()
  let pc = PersonaConfig(
    name: name,
    systemPrompt: "",
    maxIterations: 5,
    toolsAllow: @[],
    toolsDeny: @[],
    memoryScope: msOwnSessions,
    maxDelegationDepth: 2,
    maxDelegationsPerRun: 5,
  )
  registerPersona(result, pc)

proc initGlobals(
    personaName = "test",
    maxDepth = 2,
    maxDelegations = 5,
) =
  ## Sets up gGlobals with reasonable defaults for testing.
  let llm = makeMinimalLLM()
  let reg = makeRegistryWithPersona(personaName)
  let dc = DelegationConfig(
    maxDepth: maxDepth,
    maxDelegations: maxDelegations,
    personaName: personaName,
  )
  var cfg = defaultConfig()
  cfg.dbPath = testDbPath
  setGlobalLLMClient(llm)
  setPersonaRegistry(reg)
  setDelegationConfig(dc)
  setTalosConfig(cfg)

proc initGlobalsWithSpecialty(personaName: string; specialty: string) =
  ## Like initGlobals, but the registered persona declares a `specialty`
  ## so task-17's routeToDelegate can match it.
  let llm = makeMinimalLLM()
  var reg = newPersonaRegistry()
  registerPersona(reg, PersonaConfig(
    name: personaName,
    maxIterations: 5,
    memoryScope: msOwnSessions,
    maxDelegationDepth: 2,
    maxDelegationsPerRun: 5,
    specialty: specialty,
  ))
  let dc = DelegationConfig(maxDepth: 2, maxDelegations: 5, personaName: personaName)
  var cfg = defaultConfig()
  cfg.dbPath = testDbPath
  setGlobalLLMClient(llm)
  setPersonaRegistry(reg)
  setDelegationConfig(dc)
  setTalosConfig(cfg)

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

suite "delegate: validation guards":
  test "globals not initialized":
    resetGlobals()
    let exec = makeDelegateExecuteProc()
    let result = exec(%*{"persona": "test", "task": "do something"})
    check result.isError
    check result.exitCode == 1
    check result.output.contains("not initialized")

  test "missing persona argument with no routable match returns a router error (task-17)":
    # persona is optional as of task-17 — omitting it triggers auto-routing
    # instead of an immediate "required" error. makeRegistryWithPersona
    # registers a persona with no `specialty` and no persona named
    # "default", so nothing can match and the router itself fails closed.
    resetGlobals()
    initGlobals()
    let exec = makeDelegateExecuteProc()
    let result = exec(%*{"task": "do something"})
    check result.isError
    check result.output.contains("no persona's specialty matched")

  test "missing task argument":
    resetGlobals()
    initGlobals()
    let exec = makeDelegateExecuteProc()
    let result = exec(%*{"persona": "test"})
    check result.isError
    check result.output.contains("task")
    check result.output.contains("required")

  test "unknown persona name":
    resetGlobals()
    initGlobals("known_persona")
    let exec = makeDelegateExecuteProc()
    let result = exec(%*{"persona": "unknown_persona", "task": "do something"})
    check result.isError
    check result.output.contains("unknown persona")
    check result.output.contains("known_persona")

  test "omitting persona routes to a persona whose specialty matches the task (task-17)":
    resetGlobals()
    initGlobalsWithSpecialty("code_reviewer", "code review, quality, lint")
    let exec = makeDelegateExecuteProc()
    let result = exec(%*{"task": "please do a code review for quality issues"})
    # Routing succeeded (no "unknown persona" / router error) — the call
    # proceeds past the routing+lookup stage to whatever it fails at next
    # in this network-less unit-test setup, same as the persona-specified
    # tests elsewhere in this file.
    check not result.output.contains("no persona's specialty matched")
    check not result.output.contains("unknown persona")

  test "an explicit persona is used verbatim even when a differently-specialized persona would match better":
    resetGlobals()
    let llm = makeMinimalLLM()
    var reg = newPersonaRegistry()
    registerPersona(reg, PersonaConfig(
      name: "code_reviewer", maxIterations: 5, memoryScope: msOwnSessions,
      maxDelegationDepth: 2, maxDelegationsPerRun: 5,
      specialty: "code review, quality, lint"))
    registerPersona(reg, PersonaConfig(
      name: "generalist", maxIterations: 5, memoryScope: msOwnSessions,
      maxDelegationDepth: 2, maxDelegationsPerRun: 5))
    setGlobalLLMClient(llm)
    setPersonaRegistry(reg)
    setDelegationConfig(DelegationConfig(maxDepth: 2, maxDelegations: 5))
    var cfg = defaultConfig()
    cfg.dbPath = testDbPath
    setTalosConfig(cfg)
    let exec = makeDelegateExecuteProc()
    # Task text screams "code review", but the caller named "generalist"
    # explicitly — the router must not override that.
    let result = exec(%*{
      "persona": "generalist",
      "task": "please do a code review for quality issues",
    })
    check not result.output.contains("unknown persona")
    # (We can't observe *which* persona ran without a full mock LLM
    # round-trip, but an unrouted explicit name reaching this point at all
    # — rather than being silently redirected — is what this guards.)

  test "nil persona registry":
    resetGlobals()
    let llm = makeMinimalLLM()
    let dc = DelegationConfig(maxDepth: 2, maxDelegations: 5)
    setGlobalLLMClient(llm)
    setDelegationConfig(dc)
    # Deliberately not setting personaRegistry — it stays nil
    let exec = makeDelegateExecuteProc()
    let result = exec(%*{"persona": "test", "task": "do something"})
    check result.isError
    check result.output.contains("no persona registry")

suite "delegate: delegation limits":
  test "exhausted depth returns error":
    resetGlobals()
    initGlobals(maxDepth = 0, maxDelegations = 5)
    let exec = makeDelegateExecuteProc()
    let result = exec(%*{"persona": "test", "task": "do something"})
    check result.isError
    check result.output.contains("maximum delegation depth")

  test "exhausted per-run limit returns error":
    resetGlobals()
    initGlobals(maxDepth = 2, maxDelegations = 0)
    let exec = makeDelegateExecuteProc()
    let result = exec(%*{"persona": "test", "task": "do something"})
    check result.isError
    check result.output.contains("maximum delegations per run")

  test "slot consumption is observable: a second call sees the exhausted limit":
    resetGlobals()
    initGlobals(maxDepth = 1, maxDelegations = 1)
    let exec = makeDelegateExecuteProc()
    # First call consumes the only slot; it errors later at memory-open (no
    # real DB path in this unit-test setup), but the slot is consumed
    # before that point is reached.
    discard exec(%*{"persona": "test", "task": "do something"})
    # The behavior the counters exist to produce: a SECOND delegate call
    # must now be rejected by the delegation-limit guard itself, not just
    # leave an internal field decremented with no caller-visible effect.
    let result2 = exec(%*{"persona": "test", "task": "do something else"})
    check result2.isError
    check result2.output.contains("maximum delegation depth") or
          result2.output.contains("maximum delegations per run")

  test "resetDelegationBudget restores an exhausted budget for the next request":
    # Regression guard: the budget is a process-wide global that
    # useDelegationSlot decrements in place. Without a per-request reset,
    # exhausting it once (as few as maxDepth delegations, total, ever)
    # permanently disabled delegation for every future request from any
    # user until the process restarted. Every top-level entry point
    # (daemon dispatch, web chat, CLI/TUI turn) now calls
    # resetDelegationBudget before running the agent loop.
    resetGlobals()
    initGlobals(maxDepth = 1, maxDelegations = 1)
    let exec = makeDelegateExecuteProc()
    discard exec(%*{"persona": "test", "task": "first request's delegation"})
    # Budget exhausted mid-"request": further delegate calls fail...
    let exhausted = exec(%*{"persona": "test", "task": "still same request"})
    check exhausted.isError
    # ...but the next top-level request starts with a fresh baseline.
    resetDelegationBudget()
    check gGlobals.delegationConfig.canDelegate()
    let nextRequest = exec(%*{"persona": "test", "task": "next request"})
    # Passes the delegation-limit guard again (fails later at memory-open
    # in this unit-test setup, same as the first call — that's fine).
    check not (nextRequest.output.contains("maximum delegation depth") or
               nextRequest.output.contains("maximum delegations per run"))

suite "delegate: tool registration":
  test "buildRegistry includes delegate when globals are set":
    resetGlobals()
    initGlobals()
    var cfg = defaultConfig()
    cfg.dbPath = testDbPath
    let reg = buildRegistry(cfg)
    # Execute a no-op to verify the registry is valid
    let result = reg.execute("delegate", %*{
      "persona": "nonexistent",
      "task": "test"
    })
    # Should fail at 'unknown persona', not at 'tool not found'
    check result.isError
    check result.output.contains("unknown persona")

suite "delegate: child inherits delegate tool only when the persona allows it":
  ## Regression coverage for the delegate_enabled wiring fix: an operator
  ## who sets `delegate_enabled = false` on a persona (e.g. a "reviewer"
  ## persona that should only read code, never spawn further sub-agents)
  ## needs that to actually stick. `childGetsDelegateTool` is the exact
  ## decision point talos_agent.nim's delegate execute proc consults
  ## before registering a `delegate` tool on the spawned child's registry.
  test "persona with delegate_enabled = true and a real LLM gets delegate":
    let persona = PersonaConfig(name: "supervisor", delegateEnabled: true)
    check childGetsDelegateTool(persona, llmConfigured = true)

  test "persona with delegate_enabled = false is blocked even with a real LLM":
    let persona = PersonaConfig(name: "reviewer", delegateEnabled: false)
    check not childGetsDelegateTool(persona, llmConfigured = true)

  test "no LLM configured blocks delegation regardless of the persona flag":
    let persona = PersonaConfig(name: "supervisor", delegateEnabled: true)
    check not childGetsDelegateTool(persona, llmConfigured = false)

suite "delegate: child LLM routing via persona model_role (task-13)":
  ## resolveChildLlm is the exact decision point the delegate execute proc
  ## consults to pick which LLMClient a spawned child runs on.
  let parentLlm = LLMClient(baseUrl: "http://parent:9000/v1", model: "parent-model")

  test "persona with no model_role reuses the parent's client unchanged":
    let persona = PersonaConfig(name: "plain")
    let cfg = defaultConfig()
    let childLlm = resolveChildLlm(cfg, persona, parentLlm)
    check childLlm.baseUrl == parentLlm.baseUrl
    check childLlm.model == parentLlm.model

  test "persona with model_role = \"default\" also reuses the parent's client unchanged":
    let persona = PersonaConfig(name: "explicit_default", modelRole: "default")
    let cfg = defaultConfig()
    let childLlm = resolveChildLlm(cfg, persona, parentLlm)
    check childLlm.baseUrl == parentLlm.baseUrl
    check childLlm.model == parentLlm.model

  test "persona with an explicit non-default model_role gets its own client for that role":
    let persona = PersonaConfig(name: "explorer", modelRole: "smol")
    var cfg = defaultConfig()
    cfg.provider = "openrouter"
    cfg.openrouterEndpoint = "http://cheap-endpoint:9001/v1"
    cfg.openrouterApiKey = "cheap-key"
    cfg.roles["smol"] = ModelRoleConfig(
      provider: "openrouter", model: "openrouter/auto:cheap", fallback: @[])
    let childLlm = resolveChildLlm(cfg, persona, parentLlm)
    check childLlm.model == "openrouter/auto:cheap"
    check childLlm.baseUrl == "http://cheap-endpoint:9001/v1"
    check childLlm.baseUrl != parentLlm.baseUrl

  test "an unconfigured non-default model_role falls back to the legacy single-model fields, not the parent client":
    let persona = PersonaConfig(name: "explorer", modelRole: "smol")
    var cfg = defaultConfig()
    cfg.provider = "openrouter"
    cfg.openrouterEndpoint = "http://legacy-endpoint:9002/v1"
    cfg.openrouterModel = "legacy-model"
    let childLlm = resolveChildLlm(cfg, persona, parentLlm)
    check childLlm.model == "legacy-model"
    check childLlm.baseUrl == "http://legacy-endpoint:9002/v1"

for suffix in ["", "-wal", "-shm", "-journal"]:
  let p = testDbPath & suffix
  if fileExists(p):
    try: removeFile(p) except CatchableError: discard
