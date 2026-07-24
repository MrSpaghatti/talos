## Talos agent CLI.
##
## Provides the user-facing command-line interface for the Talos agent.
## Subcommands:
##   - chat                  Interactive REPL
##   - ask <question>        One-shot question
##   - session <id>          Resume an existing session, then chat
##   - history               List recent sessions
##   - search <query>        Full-text search across stored messages
##
## Configuration is loaded by `talos_core/config.loadConfig()`. Per-run
## flags `--model`, `--provider`, and `--temperature` override the values
## in the loaded config without touching disk.

import std/[os, strutils, strformat, asyncdispatch, options, json,
            asynchttpserver, net]
import db_connector/db_sqlite

import talos_core/config
import talos_core/discord
import talos_core/discord_bridge
import talos_core/discord_mocks
import talos_core/discord_types
import talos_core/llm_client
import talos_core/tool_registry
import talos_core/memory
import talos_core/thread_mapping
import talos_core/file_tool
import talos_core/file_path_validator
import talos_core/message_chunker
import talos_core/mcp_tool
import talos_core/persona
import talos_core/delegate
from talos_core/agent_dispatcher import AgentDispatcher, AgentRequest,
    newAgentDispatcher

import dimscord

import talos_core/agent_loop
import talos_core/plan_executor
import tools/shell
import talos_agent/web_server
import talos_agent/tui/chat_tui

# ---------------------------------------------------------------------------
# Globals for graceful Ctrl+C handling
# ---------------------------------------------------------------------------

var ctrlCRequested* = false
  ## Set by the SIGINT hook so the chat loop can exit cleanly between
  ## turns. Exposed for tests.

var daemonShutdownRequested* = false
var gWebServer*: WebServer = nil
  ## Set by cmdWeb so the Ctrl+C hook can close the server socket.


proc onCtrlC() {.noconv.} =
  ctrlCRequested = true
  daemonShutdownRequested = true
  if not gWebServer.isNil:
    gWebServer.server.close()
  # Best-effort newline so the next prompt isn't glued to "^C".
  try: stdout.write("\n") except CatchableError: discard

# ---------------------------------------------------------------------------
# Config / dependency wiring
# ---------------------------------------------------------------------------

type
  RunOverrides* = object
    ## Per-run flag overrides. Empty/sentinel values mean "leave alone".
    model*: string
    provider*: string
    temperature*: float
    hasTemperature*: bool
    configPath*: string
    envPath*: string

proc emptyOverrides*(): RunOverrides =
  RunOverrides(
    model: "",
    provider: "",
    temperature: 0.0,
    hasTemperature: false,
    configPath: "",
    envPath: ".env",
  )

proc applyOverrides*(cfg: var TalosConfig; ov: RunOverrides) =
  ## Mutates `cfg` to reflect any non-empty fields of `ov`. The model
  ## override is applied to whichever provider is currently active so a
  ## simple `--model x` works regardless of provider.
  if ov.provider.len > 0:
    cfg.provider = ov.provider
  if ov.model.len > 0:
    case cfg.provider
    of "vllm":       cfg.vllmModel = ov.model
    of "openrouter": cfg.openrouterModel = ov.model
    else:            cfg.openrouterModel = ov.model
  if ov.hasTemperature:
    cfg.temperature = ov.temperature

proc loadConfigWithOverrides*(ov: RunOverrides): TalosConfig =
  ## Loads config from disk and applies per-run flag overrides. Validation
  ## is re-run after overrides so an invalid provider on the CLI surfaces
  ## as a `ConfigError`.
  result = loadConfig(configPath = ov.configPath, envFilePath = ov.envPath)
  applyOverrides(result, ov)
  validate(result)

proc activeBaseUrl(cfg: TalosConfig): string =
  case cfg.provider
  of "vllm":       cfg.vllmEndpoint
  of "openrouter": cfg.openrouterEndpoint
  else:            cfg.openrouterEndpoint

proc activeModel(cfg: TalosConfig): string =
  case cfg.provider
  of "vllm":       cfg.vllmModel
  of "openrouter": cfg.openrouterModel
  else:            cfg.openrouterModel

proc activeApiKey(cfg: TalosConfig): string =
  case cfg.provider
  of "openrouter": cfg.openrouterApiKey
  else:            ""

proc buildLLMClient*(cfg: TalosConfig): LLMClient =
  ## Builds an LLMClient from a fully-resolved TalosConfig.
  newLLMClient(
    baseUrl = activeBaseUrl(cfg),
    apiKey  = activeApiKey(cfg),
    model   = activeModel(cfg),
  )

# ---------------------------------------------------------------------------
# Global state for tool closures
# ---------------------------------------------------------------------------

type
  AgentGlobals* = ref object
    ## Container for agent-loop globals that need safe closure capture.
    personaRegistry*: PersonaRegistry
    llmClient*: LLMClient
    delegationConfig*: DelegationConfig
    talosConfig*: TalosConfig

var gGlobals*: AgentGlobals = nil

proc setPersonaRegistry*(reg: PersonaRegistry) =
  if gGlobals.isNil:
    gGlobals = AgentGlobals(personaRegistry: reg)
  else:
    gGlobals.personaRegistry = reg

proc setGlobalLLMClient*(llm: LLMClient) =
  if gGlobals.isNil:
    gGlobals = AgentGlobals(llmClient: llm)
  else:
    gGlobals.llmClient = llm

proc setDelegationConfig*(dc: DelegationConfig) =
  if gGlobals.isNil:
    gGlobals = AgentGlobals(delegationConfig: dc)
  else:
    gGlobals.delegationConfig = dc

proc setTalosConfig*(cfg: TalosConfig) =
  if gGlobals.isNil:
    gGlobals = AgentGlobals(talosConfig: cfg)
  else:
    gGlobals.talosConfig = cfg

# ---------------------------------------------------------------------------
# Delegate tool
# ---------------------------------------------------------------------------

# Forward declarations for symbols defined later in the file.
proc makeDelegateTool*(): Tool
proc defaultPersonasPath*(): string

proc makeDelegateParams*(): JsonNode =
  ## Builds the JSON Schema for the delegate tool parameters.
  let p = newJObject()
  p["type"] = %"object"
  p["properties"] = newJObject()
  p["properties"]["persona"] = newJObject()
  p["properties"]["persona"]["type"] = %"string"
  p["properties"]["persona"]["description"] =
    %"Name of the persona to spawn (e.g. 'code_reviewer')"
  p["properties"]["task"] = newJObject()
  p["properties"]["task"]["type"] = %"string"
  p["properties"]["task"]["description"] =
    %"The subtask description for the child agent"
  p["required"] = newJArray()
  p["required"].add(%"persona")
  p["required"].add(%"task")
  p

proc childGetsDelegateTool*(persona: PersonaConfig; llmConfigured: bool): bool =
  ## Whether a child agent spawned for `persona` should itself get a
  ## `delegate` tool (i.e. whether it may delegate further). Requires both
  ## the persona opting in via `delegate_enabled` (an operator can use this
  ## to build a persona that must not spawn sub-agents) and a real LLM
  ## being configured — a fake/placeholder LLM can't run a further child
  ## agent even if the persona would otherwise allow it. Pulled out as a
  ## pure function so the gating decision itself is directly testable
  ## without needing a live delegation round-trip.
  persona.delegateEnabled and llmConfigured

proc makeDelegateExecuteProc*(): auto =
  ## Returns a gcsafe closure that captures the current AgentGlobals ref.
  ## The ref object is GC-safe to capture, and the closure accesses globals
  ## through the ref rather than directly.
  let captured = gGlobals
  return proc (args: JsonNode): ToolResult =
    if captured.isNil:
      return ToolResult(
        output: "delegate: agent globals not initialized",
        isError: true,
        exitCode: 1,
      )
    # Check delegation depth tracking before spawning.
    if not captured.delegationConfig.canDelegate():
      let reason =
        if captured.delegationConfig.maxDepth <= 0:
          "maximum delegation depth reached"
        elif captured.delegationConfig.maxDelegations <= 0:
          "maximum delegations per run exhausted"
        else:
          "delegation limit reached"
      return ToolResult(
        output: "delegate: " & reason,
        isError: true,
        exitCode: 1,
      )
    let personaName = args{"persona"}.getStr("")
    let task = args{"task"}.getStr("")
    if personaName.len == 0:
      return ToolResult(
        output: "delegate: 'persona' argument is required",
        isError: true,
        exitCode: 1,
      )
    if task.len == 0:
      return ToolResult(
        output: "delegate: 'task' argument is required",
        isError: true,
        exitCode: 1,
      )
    if captured.personaRegistry.isNil:
      return ToolResult(
        output: "delegate: no persona registry loaded (no personas.toml found)",
        isError: true,
        exitCode: 1,
      )
    if not captured.personaRegistry.hasPersona(personaName):
      return ToolResult(
        output: "delegate: unknown persona '" & personaName &
          "'. Available: " & captured.personaRegistry.listPersonas().join(", "),
        isError: true,
        exitCode: 1,
      )
    let persona =
      try: captured.personaRegistry.getPersona(personaName)
      except PersonaError:
        return ToolResult(
          output: "delegate: failed to load persona '" & personaName & "'",
          isError: true,
          exitCode: 1,
        )
    if captured.llmClient.baseUrl.len == 0:
      return ToolResult(
        output: "delegate: LLM client not available (baseUrl is empty)",
        isError: true,
        exitCode: 1,
      )
    let parentCfg =
      if captured.talosConfig.provider.len > 0: captured.talosConfig
      else: defaultConfig()
    var childCfg = newAgentConfig(parentCfg)
    if persona.systemPrompt.len > 0:
      childCfg.systemPrompt = persona.systemPrompt
    if persona.maxIterations > 0:
      childCfg.maxIterations = persona.maxIterations
    childCfg.persona = persona
    childCfg.delegation = applyPersonaDelegation(
      persona.maxDelegationDepth,
      persona.maxDelegationsPerRun,
      persona.name,
      parentMaxDepth = captured.delegationConfig.maxDepth,
    )
    # Inline resolveDbPath logic since it's defined later in the file.
    let rawPath = parentCfg.dbPath
    let dbPath =
      if rawPath.startsWith("~"): expandTilde(rawPath)
      else: rawPath
    var childMem: Memory
    try:
      childMem = newMemory(dbPath)
    except CatchableError:
      return ToolResult(
        output: "delegate: cannot open memory store",
        isError: true,
        exitCode: 1,
      )
    # Consume one delegation slot before spawning the child.
    captured.delegationConfig.useDelegationSlot()

    # Build a proper registry so the child has tools.
    # Temporarily swap delegation config so the child's delegate tool
    # captures its own bounds rather than the parent's.
    let savedDc = gGlobals.delegationConfig
    gGlobals.delegationConfig = childCfg.delegation
    defer: gGlobals.delegationConfig = savedDc
    var childReg = newToolRegistry()
    childReg.register(shellTool())
    let llmConfigured = not gGlobals.isNil and gGlobals.llmClient.baseUrl.len > 0
    if childGetsDelegateTool(persona, llmConfigured):
      childReg.register(makeDelegateTool())
    if parentCfg.mcpServers.len > 0:
      discard registerMcpServers(childReg, parentCfg.mcpServers)
    let scopedChildReg = scopedRegistry(childReg, persona)

    let childResult = runAgentLoop(
      agentCfg = childCfg,
      llm = captured.llmClient,
      registry = scopedChildReg,
      memory = childMem,
      userInput = task,
    )
    childMem.close()
    var lines: seq[string] = @[]
    lines.add("=== Child Agent Result ===")
    lines.add("Persona: " & persona.name)
    lines.add("Session: " & childResult.sessionId)
    lines.add("Stop reason: " & $childResult.stopReason)
    lines.add("Tokens: " & $childResult.stats.totalTokens &
      " (prompt: " & $childResult.stats.promptTokens &
      ", completion: " & $childResult.stats.completionTokens & ")")
    lines.add("Turns: " & $childResult.stats.totalTurns)
    lines.add("Tool calls: " & $childResult.stats.toolCallsMade)
    lines.add("")
    lines.add("--- Response ---")
    if childResult.text.len > 0:
      lines.add(childResult.text)
    else:
      lines.add("(no text produced)")
    return ToolResult(
      output: lines.join("\n"),
      isError: false,
      exitCode: 0,
    )

proc makeDelegateTool*(): Tool =
  ## Returns the delegate tool with the current agent globals captured.
  ## Call this after setting globals via setPersonaRegistry / setGlobalLLMClient.
  let description = "Spawn a child agent from a named persona to handle " &
    "a specific subtask. The child agent runs with its own system prompt, " &
    "tool restrictions, and memory isolation. " &
    "Args: persona (string, name of persona), task (string, the subtask). " &
    "Returns: the child's final text response plus execution metadata."

  let exec = makeDelegateExecuteProc()
  newTool(
    name = "delegate",
    description = description,
    parameters = makeDelegateParams(),
    execute = exec,
  )

proc delegateTool*(): Tool =
  ## Creates the delegate tool with a snapshot of current globals.
  ## NOTE: prefer `makeDelegateTool` after globals are set. This proc
  ## captures globals at proc definition time (potentially nil).
  makeDelegateTool()

proc buildRegistry*(cfg: TalosConfig = defaultConfig()): ToolRegistry =
  ## Builds the default tool registry for the agent. Registers the shell tool
  ## and any MCP tools configured in `cfg.mcpServers`. Also registers the
  ## delegate tool if agent globals are available.
  result = newToolRegistry()
  result.register(shellTool())
  if cfg.mcpServers.len > 0:
    discard registerMcpServers(result, cfg.mcpServers)
  # Register delegate tool — only if globals are set
  if not gGlobals.isNil and gGlobals.llmClient.baseUrl.len > 0:
    result.register(makeDelegateTool())

proc resolveDbPath*(cfg: TalosConfig): string =
  ## Expands `~` in the configured DB path and ensures the parent dir
  ## exists. Returns the absolute path used for SQLite.
  result = cfg.dbPath
  if result.startsWith("~"):
    result = expandTilde(result)
  let parent = parentDir(result)
  if parent.len > 0 and not dirExists(parent):
    try:
      createDir(parent)
    except CatchableError:
      stderr.writeLine("Warning: could not create parent directory for '" & result & "'.")

proc openMemory*(cfg: TalosConfig): Memory =
  ## Opens the memory store at the path configured in `cfg`.
  newMemory(resolveDbPath(cfg))

# ---------------------------------------------------------------------------
# Chat REPL
# ---------------------------------------------------------------------------

type
  SessionSummary* = object   ## defined here; also referenced by listRecentSessions
    id*: string
    createdAt*: string
    updatedAt*: string
    messageCount*: int

proc printSystemNote(text: string)  ## fwd
proc printError(text: string)        ## fwd
proc printAssistant(text: string)    ## fwd
proc sessionExists*(dbPath, sessionId: string): bool   ## fwd
proc listRecentSessions*(dbPath: string; limit: int = 20): seq[SessionSummary]   ## fwd

proc readLine(prompt: string): tuple[line: string, eof: bool] =
  ## Reads a single line of input. Returns `(text, eof=true)` on EOF.
  stdout.write(prompt)
  stdout.flushFile()
  try:
    let line = stdin.readLine()
    return (line, false)
  except EOFError:
    return ("", true)
  except IOError:
    return ("", true)

proc isExitCommand(line: string): bool =
  let s = line.strip().toLowerAscii()
  s in [":q", ":quit", ":exit", "/quit", "/exit", "exit", "quit"]

proc runOneTurn(
    cfg: TalosConfig;
    llm: LLMClient;
    reg: ToolRegistry;
    mem: var Memory;
    userInput: string;
    streamCallback: OnStreamEvent = nil;
): AgentResult =
  ## Thin wrapper around `runAgentLoop` so the chat and ask commands
  ## share their per-turn logic.
  if streamCallback != nil:
    var agentCfg = newAgentConfig(cfg)
    agentCfg.streamCallback = streamCallback
    runAgentLoop(agentCfg, llm, reg, mem, userInput)
  else:
    runAgentLoop(cfg, llm, reg, mem, userInput)

proc runChatLoop*(
    cfg: TalosConfig;
    llm: LLMClient;
    reg: ToolRegistry;
    mem: var Memory;
    initialBanner: string = "";
    streamCallback: OnStreamEvent = nil;
): int =
  ## Runs the interactive REPL until EOF or `:quit`. SIGINT between
  ## turns is treated as a clean exit. Returns 0 on clean exit, 1 on
  ## unrecoverable error.
  if initialBanner.len > 0:
    printSystemNote(initialBanner)
  printSystemNote("type :quit to exit; Ctrl+C to interrupt")
  while true:
    if ctrlCRequested:
      printSystemNote("interrupted")
      break
    let (line, eof) = readLine("> ")
    if eof:
      printSystemNote("eof")
      break
    if ctrlCRequested:
      printSystemNote("interrupted")
      break
    let trimmed = line.strip()
    if trimmed.len == 0:
      continue
    if isExitCommand(trimmed):
      printSystemNote("bye")
      break
    var res: AgentResult
    try:
      res = runOneTurn(cfg, llm, reg, mem, trimmed, streamCallback)
    except CatchableError as e:
      printError(e.msg)
      continue
    # Don't re-print text if streaming already printed it token-by-token.
    if streamCallback == nil:
      printAssistant(res.text)
    else:
      stdout.writeLine("")
    if res.stopReason != asrFinished:
      printSystemNote("stop reason: " & $res.stopReason)
  return 0

# ---------------------------------------------------------------------------
# Subcommand entry points
# ---------------------------------------------------------------------------

proc cmdChat*(
    model = "";
    provider = "";
    temperature = -1.0;
    config = "";
    envFile = ".env";
    noStream = false;
): int =
  ## Interactive chat mode. Returns a process exit code.
  setControlCHook(onCtrlC)
  var ov = emptyOverrides()
  ov.model = model
  ov.provider = provider
  if temperature >= 0.0:
    ov.temperature = temperature
    ov.hasTemperature = true
  ov.configPath = config
  ov.envPath = envFile
  var cfg: TalosConfig
  try:
    cfg = loadConfigWithOverrides(ov)
  except ConfigError as e:
    printError(e.msg); return 2
  let llm = buildLLMClient(cfg)

  # Set agent globals so delegate tool can work from this flow.
  setGlobalLLMClient(llm)
  setTalosConfig(cfg)
  let personasPath = defaultPersonasPath()
  let pReg =
    if fileExists(personasPath): loadPersonasFile(personasPath)
    else: newPersonaRegistry()
  setPersonaRegistry(pReg)
  setDelegationConfig(defaultDelegationConfig())

  let reg = buildRegistry(cfg)
  var mem = openMemory(cfg)
  defer: mem.close()
  var streamCb: OnStreamEvent = nil
  if not noStream:
    streamCb = proc(event: ChatCompletionStreamEvent) {.gcsafe, raises: [].} =
      {.cast(raises: []).}:
        if event.kind == sekContent and event.delta.len > 0:
          stdout.write(event.delta)
          stdout.flushFile()
  discard runChatLoop(
    cfg, llm, reg, mem,
    initialBanner = fmt"chat: provider={cfg.provider} model={activeModel(cfg)}",
    streamCallback = streamCb,
  )

proc cmdAsk*(
    question: seq[string];
    model = "";
    provider = "";
    temperature = -1.0;
    config = "";
    envFile = ".env";
    noStream = false;
    plan = false;
): int =
  ## Single-shot question mode.
  if question.len == 0:
    printError("ask requires a question")
    return 2
  var ov = emptyOverrides()
  ov.model = model
  ov.provider = provider
  if temperature >= 0.0:
    ov.temperature = temperature
    ov.hasTemperature = true
  ov.configPath = config
  ov.envPath = envFile
  var cfg: TalosConfig
  try:
    cfg = loadConfigWithOverrides(ov)
  except ConfigError as e:
    printError(e.msg); return 2
  let llm = buildLLMClient(cfg)

  # Set agent globals so delegate tool can work from this flow.
  setGlobalLLMClient(llm)
  setTalosConfig(cfg)
  let personasPath = defaultPersonasPath()
  let pReg =
    if fileExists(personasPath): loadPersonasFile(personasPath)
    else: newPersonaRegistry()
  setPersonaRegistry(pReg)
  setDelegationConfig(defaultDelegationConfig())

  let reg = buildRegistry(cfg)
  var mem = openMemory(cfg)
  defer: mem.close()
  let userInput = question.join(" ")

  if plan:
    # --- Plan-Execute mode ---
    var planRes: PlanResult
    try:
      let executionPlan = generatePlan(llm, userInput, reg)
      stdout.writeLine(formatPlan(executionPlan))
      stdout.flushFile()
      var agentCfg = newAgentConfig(cfg)
      if not noStream:
        agentCfg.streamCallback = proc(event: ChatCompletionStreamEvent) {.gcsafe, raises: [].} =
          {.cast(raises: []).}:
            if event.kind == sekContent and event.delta.len > 0:
              stdout.write(event.delta)
              stdout.flushFile()
      planRes = executePlan(agentCfg, llm, reg, mem, userInput, executionPlan,
        stepCallback = proc(step: PlanStep) {.gcsafe, raises: [].} =
          {.cast(raises: []).}:
            stdout.writeLine(formatStepStatus(step))
            stdout.flushFile())
    except PlanError as e:
      printError("Plan generation failed: " & e.msg); return 1
    except CatchableError as e:
      printError(e.msg); return 1
    if noStream:
      stdout.writeLine(planRes.finalAnswer)
    else:
      stdout.write("\n"); stdout.flushFile()
    return 0

  # --- ReAct mode (default) ---
  var res: AgentResult
  try:
    if noStream:
      res = runAgentLoop(cfg, llm, reg, mem, userInput)
    else:
      var agentCfg = newAgentConfig(cfg)
      agentCfg.streamCallback = proc(event: ChatCompletionStreamEvent) {.gcsafe, raises: [].} =
        {.cast(raises: []).}:
          if event.kind == sekContent and event.delta.len > 0:
            stdout.write(event.delta)
            stdout.flushFile()
      res = runAgentLoop(agentCfg, llm, reg, mem, userInput)
  except CatchableError as e:
    printError(e.msg); return 1
  stdout.writeLine(res.text)
  if res.stopReason != asrFinished:
    return 3
  return 0

proc replayHistory(history: seq[ChatMessage]) =
  ## Renders a previously-stored session to stdout so the user has
  ## context before resuming.
  for m in history:
    case m.role
    of crSystem:    discard      ## skip the system prompt
    of crUser:      stdout.writeLine("> " & m.content)
    of crAssistant:
      if m.content.len > 0:
        stdout.writeLine("Talos> " & m.content)
      elif m.toolCalls.len > 0:
        for tc in m.toolCalls:
          stdout.writeLine(fmt"[tool-call] {tc.name}({tc.arguments})")
    of crTool:
      stdout.writeLine(fmt"[tool-result {m.name}] {m.content}")
  stdout.flushFile()

proc cmdSession*(
    id: seq[string];
    model = "";
    provider = "";
    temperature = -1.0;
    config = "";
    envFile = ".env";
    noStream = false;
): int =
  ## Resume an existing session and continue chatting.
  if id.len == 0:
    printError("session requires an id")
    return 2
  let sessionId = id[0]
  setControlCHook(onCtrlC)
  var ov = emptyOverrides()
  ov.model = model
  ov.provider = provider
  if temperature >= 0.0:
    ov.temperature = temperature
    ov.hasTemperature = true
  ov.configPath = config
  ov.envPath = envFile
  var cfg: TalosConfig
  try:
    cfg = loadConfigWithOverrides(ov)
  except ConfigError as e:
    printError(e.msg); return 2
  let dbPath = resolveDbPath(cfg)
  if not sessionExists(dbPath, sessionId):
    printError("no such session: " & sessionId); return 4
  let llm = buildLLMClient(cfg)

  # Set agent globals so delegate tool can work from this flow.
  setGlobalLLMClient(llm)
  setTalosConfig(cfg)
  let personasPath = defaultPersonasPath()
  let pReg =
    if fileExists(personasPath): loadPersonasFile(personasPath)
    else: newPersonaRegistry()
  setPersonaRegistry(pReg)
  setDelegationConfig(defaultDelegationConfig())

  let reg = buildRegistry(cfg)
  var mem = openMemory(cfg)
  defer: mem.close()
  let history = mem.getHistory(sessionId)
  printSystemNote(
    fmt"resuming session {sessionId} ({history.len} messages)")
  replayHistory(history)
  ## NOTE: runAgentLoop always opens a *new* session under the hood.
  printSystemNote(
    "starting a new session for follow-up turns " &
    "(history is read-only here)")
  var streamCb: OnStreamEvent = nil
  if not noStream:
    streamCb = proc(event: ChatCompletionStreamEvent) {.gcsafe, raises: [].} =
      {.cast(raises: []).}:
        if event.kind == sekContent and event.delta.len > 0:
          stdout.write(event.delta)
          stdout.flushFile()
  discard runChatLoop(
    cfg, llm, reg, mem,
    initialBanner = fmt"session: provider={cfg.provider} model={activeModel(cfg)}",
    streamCallback = streamCb,
  )
  return 0

proc cmdHistory*(
    limit = 20;
    config = "";
    envFile = ".env";
): int =
  ## List the most recently updated sessions.
  var ov = emptyOverrides()
  ov.configPath = config
  ov.envPath = envFile
  var cfg: TalosConfig
  try:
    cfg = loadConfigWithOverrides(ov)
  except ConfigError as e:
    printError(e.msg); return 2
  let dbPath = resolveDbPath(cfg)
  let sessions = listRecentSessions(dbPath, limit)
  if sessions.len == 0:
    printSystemNote("no sessions yet")
    return 0
  echo fmt"{""SESSION ID"":<40}  {""UPDATED"":<25}  MSGS"
  for s in sessions:
    echo fmt"{s.id:<40}  {s.updatedAt:<25}  {s.messageCount}"
  return 0

# ---------------------------------------------------------------------------
# Output formatting
# ---------------------------------------------------------------------------

proc printAssistant(text: string) =
  stdout.writeLine("Talos> " & text)
  stdout.flushFile()

proc printSystemNote(text: string) =
  stdout.writeLine("[" & text & "]")
  stdout.flushFile()

proc printError(text: string) =
  stderr.writeLine("error: " & text)
  stderr.flushFile()

# ---------------------------------------------------------------------------
# Recent-sessions listing
#
# memory.nim does not expose a `listSessions` proc, so we open our own
# read-only sqlite handle against the same db file. This keeps the
# read-only modules untouched while still letting the CLI render the
# `history` view.
# ---------------------------------------------------------------------------

proc listRecentSessions*(dbPath: string; limit: int = 20): seq[SessionSummary] =
  ## Returns up to `limit` most-recently-updated sessions. Returns an
  ## empty seq if the DB does not yet exist (no prior runs).
  result = @[]
  if not fileExists(dbPath):
    return
  let db = open(dbPath, "", "", "")
  defer: db.close()
  for row in db.fastRows(sql"""
    SELECT s.id, s.created_at, s.updated_at,
           (SELECT COUNT(*) FROM messages m WHERE m.session_id = s.id)
    FROM sessions s
    ORDER BY s.updated_at DESC
    LIMIT ?
  """, $limit):
    result.add(SessionSummary(
      id: row[0],
      createdAt: row[1],
      updatedAt: row[2],
      messageCount: parseInt(row[3]),
    ))

proc sessionExists*(dbPath, sessionId: string): bool =
  ## True if a session with the given id exists in the DB at `dbPath`.
  if not fileExists(dbPath):
    return false
  let db = open(dbPath, "", "", "")
  defer: db.close()
  let row = db.getRow(
    sql"SELECT id FROM sessions WHERE id = ?", sessionId)
  return row[0].len > 0

# ---------------------------------------------------------------------------
# Persona run subcommand
# ---------------------------------------------------------------------------

proc defaultPersonasPath*(): string =
  ## Returns the default personas config path: ~/.config/talos/personas.toml
  let home = getHomeDir()
  if home.len == 0:
    return ""
  return home / ".config" / "talos" / "personas.toml"

proc cmdRunPersona*(
    persona: seq[string];
    task: seq[string];
    config = "";
    envFile = ".env";
): int =
  ## Run a named persona with a given task. Loads personas.toml and spawns
  ## a child agent from the matching persona config.
  if persona.len == 0:
    printError("run requires a persona name")
    return 2
  if task.len == 0:
    printError("run requires a task")
    return 2

  let personaName = persona[0]
  let taskText = task.join(" ")

  # Load config and build base dependencies
  var ov = emptyOverrides()
  ov.configPath = config
  ov.envPath = envFile
  var cfg: TalosConfig
  try:
    cfg = loadConfigWithOverrides(ov)
  except ConfigError as e:
    printError(e.msg); return 2

  # Load persona registry
  let personasPath = defaultPersonasPath()
  var reg = loadPersonasFile(personasPath)
  if not reg.hasPersona(personaName):
    printError("persona '" & personaName & "' not found in " & personasPath)
    let available = reg.listPersonas()
    if available.len > 0:
      printError("available personas: " & available.join(", "))
    else:
      printError("(no personas loaded — check " & personasPath & ")")
    return 3

  # Build LLM client and memory
  let llm = buildLLMClient(cfg)
  var mem = openMemory(cfg)
  defer: mem.close()

  # Set agent globals so the delegate tool can work
  setGlobalLLMClient(llm)
  setPersonaRegistry(reg)
  setTalosConfig(cfg)

  # Build child agent config (must happen before registries so delegation
  # bounds are available when the delegate tool is wired).
  let pc = reg.getPersona(personaName)
  var agentCfg = newAgentConfig(cfg)
  if pc.systemPrompt.len > 0:
    agentCfg.systemPrompt = pc.systemPrompt
  if pc.maxIterations > 0:
    agentCfg.maxIterations = pc.maxIterations
  agentCfg.persona = pc
  let dc = applyPersonaDelegation(
    pc.maxDelegationDepth,
    pc.maxDelegationsPerRun,
    pc.name,
  )
  agentCfg.delegation = dc
  setDelegationConfig(dc)

  # Build filtered registry scoped to the persona
  var baseReg = newToolRegistry()
  baseReg.register(shellTool())
  # Register delegate tool so the LLM can spawn child agents.
  if not gGlobals.isNil and gGlobals.llmClient.baseUrl.len > 0:
    baseReg.register(makeDelegateTool())
  let scopedReg = scopedRegistry(baseReg, pc)

  # Run the agent
  printSystemNote("spawning persona '" & personaName & "'...")
  var agentResult: AgentResult
  try:
    agentResult = runAgentLoop(agentCfg, llm, scopedReg, mem, taskText)
  except CatchableError as e:
    printError(e.msg); return 1

  stdout.writeLine(agentResult.text)
  if agentResult.stopReason != asrFinished:
    printSystemNote("stop reason: " & $agentResult.stopReason)
  return 0

# ---------------------------------------------------------------------------
# Search
# ---------------------------------------------------------------------------

proc cmdSearch*(
    query: seq[string];
    limit = 20;
    config = "";
    envFile = ".env";
): int =
  ## Search across stored message content.
  if query.len == 0:
    printError("search requires a query")
    return 2
  var ov = emptyOverrides()
  ov.configPath = config
  ov.envPath = envFile
  var cfg: TalosConfig
  try:
    cfg = loadConfigWithOverrides(ov)
  except ConfigError as e:
    printError(e.msg); return 2
  var mem = openMemory(cfg)
  defer: mem.close()
  let q = query.join(" ")
  let hits = mem.searchHistory(q)
  if hits.len == 0:
    printSystemNote("no matches")
    return 0
  var shown = 0
  for r in hits:
    if shown >= limit: break
    echo fmt"[{r.sessionId}] {r.createdAt}  {r.role}"
    echo "  " & r.snippet
    inc shown
  return 0

# ---------------------------------------------------------------------------
# Wiring
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Discord API callback wrappers
# ---------------------------------------------------------------------------
# These named procs wrap RealDiscordApi calls so they can be passed as
# callbacks to DiscordBot. Nim's {.async.} pragma doesn't work on inline
# proc literals, so we define them as named procs that capture the API
# adapter via closure.

proc makeSendFn(api: RealDiscordApi): SendMessageFn =
  proc send(channelId, content: string): Future[string] {.async, gcsafe.} =
    return await api.sendMessage(channelId, content)
  return send

proc makeTypingFn(api: RealDiscordApi): TriggerTypingFn =
  proc typing(channelId: string) {.async, gcsafe.} =
    await api.triggerTyping(channelId)
  return typing

proc makeCreateThreadFn(api: RealDiscordApi): CreateThreadFn =
  proc create(channelId, messageId, name: string): Future[string] {.async, gcsafe.} =
    return await api.createThread(channelId, messageId, name)
  return create

proc makeArchiveThreadFn(api: RealDiscordApi): ArchiveThreadFn =
  proc archive(threadId: string) {.async, gcsafe.} =
    await api.archiveThread(threadId)
  return archive

proc sendWithLogging*(sendFn: SendMessageFn; channelId, content: string): Future[void] {.async.} =
  ## Sends a message to Discord, logging errors to stderr instead of
  ## letting asyncCheck silently swallow them.
  try:
    discard await sendFn(channelId, content)
  except CatchableError as e:
    stderr.writeLine("[daemon] failed to send message: " & e.msg)

# ---------------------------------------------------------------------------
# Web UI command
# ---------------------------------------------------------------------------

proc cmdWeb*(
    port = 0;
    config = "";
    envFile = ".env";
): int =
  ## Starts the web UI HTTP server.
  var ov = emptyOverrides()
  ov.configPath = config
  ov.envPath = envFile
  var cfg: TalosConfig
  try:
    cfg = loadConfigWithOverrides(ov)
  except ConfigError as e:
    printError(e.msg); return 2
  if port > 0:
    cfg.webPort = port
  let llm = buildLLMClient(cfg)

  # Set agent globals so delegate tool can work.
  setGlobalLLMClient(llm)
  setTalosConfig(cfg)
  let personasPath = defaultPersonasPath()
  let pReg =
    if fileExists(personasPath): loadPersonasFile(personasPath)
    else: newPersonaRegistry()
  setPersonaRegistry(pReg)
  setDelegationConfig(defaultDelegationConfig())

  let reg = buildRegistry(cfg)
  var mem = openMemory(cfg)
  defer: mem.close()

  let ws = newWebServer(cfg, llm, reg, mem)
  gWebServer = ws
  stderr.writeLine("[web] listening on http://localhost:" & $ws.port)

  proc serveUntilInterrupted() {.async.} =
    let ctx = WebServerContext(ws: ws)
    # serve() handles listen + accept loop. It blocks until the socket is closed.
    # Loopback only: the agent has shell/file tools and the API carries
    # no authentication, so this must not be reachable off-host.
    await ws.server.serve(
      Port(ws.port),
      address = "127.0.0.1",
      callback = proc (req: Request) {.async, gcsafe.} =
        await handleRequest(ctx, req)
    )

  setControlCHook(onCtrlC)
  waitFor serveUntilInterrupted()
  printSystemNote("shutting down web server")
  ws.stop()
  return 0

# ---------------------------------------------------------------------------
# Daemon command
# ---------------------------------------------------------------------------

proc cmdDaemon*(
    config = "";
    envFile = ".env";
): int =
  ## Starts the Discord bot daemon.
  ##
  ## Wires the DI-based DiscordBot with a real Dimscord client:
  ## 1. Loads config and reads the Discord token from the env var.
  ## 2. Creates a Dimscord client and RealDiscordApi adapter.
  ## 3. Builds the LLM client, tool registry, and memory store.
  ## 4. Opens the thread-mapping DB and initialises its schema.
  ## 5. Registers file tools conditionally (based on config).
  ## 6. Creates an AgentDispatcher whose callback sends results to Discord.
  ## 7. Wires the message_create event to onMessageCreate.
  ## 8. Starts the Discord gateway session.
  ## 9. Handles SIGINT/SIGTERM for graceful shutdown.
  setControlCHook(onCtrlC)
  var ov = emptyOverrides()
  ov.configPath = config
  ov.envPath = envFile
  var cfg: TalosConfig
  try:
    cfg = loadConfigWithOverrides(ov)
  except ConfigError as e:
    printError(e.msg); return 2

  # Read Discord bot token from the configured env var
  let tokenEnv = cfg.discord.tokenEnv
  let token = getEnv(tokenEnv)
  if token.len == 0:
    printError("Discord token not found in env var: " & tokenEnv)
    return 2

  # Build LLM client
  let llm = buildLLMClient(cfg)

  # Build tool registry
  var reg = newToolRegistry()

  # File tools — always available for safe Discord file access
  let fileRules = FileRules(
    sandboxDir: cfg.discord.fileSandboxDir,
    allowPatterns: cfg.discord.fileRules.allow,
    askPatterns: @[],
    denyPatterns: cfg.discord.fileRules.deny,
  )
  reg.register(fileReadTool(fileRules))
  reg.register(fileWriteTool(fileRules, cfg.discord))

  # Shell tool — available in Discord mode too (whitelist-only, solo-user
  # daemon; delegate's child agents already had shell access regardless).
  reg.register(shellTool())

  # Delegate + MCP tools — opt-in via daemonDelegation config flag.
  if cfg.discord.daemonDelegation:
    # Set agent globals so the delegate tool can initialise.
    setGlobalLLMClient(llm)
    setTalosConfig(cfg)
    let personasPath = defaultPersonasPath()
    let pReg =
      if fileExists(personasPath): loadPersonasFile(personasPath)
      else: newPersonaRegistry()
    setPersonaRegistry(pReg)
    setDelegationConfig(defaultDelegationConfig())

    reg.register(makeDelegateTool())
    if cfg.mcpServers.len > 0:
      discard registerMcpServers(reg, cfg.mcpServers)

  # Open memory store
  var mem = openMemory(cfg)

  # Open thread-mapping DB with WAL mode and busy timeout
  # to avoid SQLITE_BUSY when the memory module writes concurrently.
  let threadDbPath = resolveDbPath(cfg)
  let threadDb = open(threadDbPath, "", "", "")
  threadDb.exec(sql"PRAGMA journal_mode=WAL")
  threadDb.exec(sql"PRAGMA busy_timeout=5000")
  initThreadMappingSchema(threadDb)

  # Create Dimscord client
  let discord = newDiscordClient(token)

  # Create the real API adapter
  let api = newRealDiscordApi(discord.api)

  # Create a MockShard with the bot's user ID (populated on ready)
  var shard = newMockShard("")

  # Create the agent dispatcher — callback sends results to Discord.
  # dispatchAgent calls runAgentLoop directly (see agent_dispatcher.nim);
  # no injected run-function wrapper needed here.
  let sendFn = makeSendFn(api)
  let typingFn = makeTypingFn(api)
  let callbackProc = proc(r: agent_dispatcher.AgentResult) {.gcsafe, raises: [].} =
    {.cast(raises: []).}:
      let text = if r.error.isSome: "Error: " & r.error.get()
                 else: r.responseText
      let chunks = chunkMessage(text)
      for chunk in chunks:
        asyncCheck sendWithLogging(sendFn, r.channelId, chunk)
  # Discord's typing indicator expires after ~10s; refresh it once per
  # ReAct turn so it stays lit for the length of a multi-turn agent run
  # instead of just the first ~10s. See agent_loop.AgentConfig.turnCallback.
  let turnCallback = proc(channelId: string) {.gcsafe, raises: [].} =
    {.cast(gcsafe), cast(raises: []).}:
      try:
        waitFor typingFn(channelId)
      except CatchableError:
        discard
  let dispatcher = newAgentDispatcher(
    callbackProc, cfg, llm, reg, resolveDbPath(cfg), turnCallback = turnCallback
  )

  # Create the DI-based DiscordBot with real API callbacks
  let bot = newDiscordBot(
    sendMessage = makeSendFn(api),
    triggerTyping = makeTypingFn(api),
    createThread = makeCreateThreadFn(api),
    archiveThread = makeArchiveThreadFn(api),
    db = threadDb,
    config = cfg.discord,
    dispatcher = dispatcher,
    shard = shard,
  )

  # Graceful shutdown handled by the setControlCHook above
  # Start the Discord bot (blocks until session ends or error)
  # `finally` always runs on the way out of this try (normal return,
  # exception, or the early `return 1` below), so it alone owns closing
  # threadDb/mem — closing them again in `except` would double-close an
  # already-closed SQLite handle (undefined behavior) on any crash that
  # occurs while daemonShutdownRequested is still false, which is the
  # common case for a real Discord/network exception mid-run.
  try:
    waitFor startDiscordBot(discord, bot)
  except CatchableError as e:
    printError("Daemon crashed: " & e.msg)
    return 1
  finally:
    if not daemonShutdownRequested:
      threadDb.close()
      mem.close()
  return 0
proc cmdTui*(
    model = "";
    provider = "";
    temperature = -1.0;
    config = "";
    envFile = ".env";
    noStream = false;
): int =
  ## Fullscreen terminal UI. Returns a process exit code.
  setControlCHook(onCtrlC)
  var ov = emptyOverrides()
  ov.model = model
  ov.provider = provider
  if temperature >= 0.0:
    ov.temperature = temperature
    ov.hasTemperature = true
  ov.configPath = config
  ov.envPath = envFile
  var cfg: TalosConfig
  try:
    cfg = loadConfigWithOverrides(ov)
  except ConfigError as e:
    printError(e.msg); return 2
  let llm = buildLLMClient(cfg)

  # Set agent globals so delegate tool can work from this flow.
  setGlobalLLMClient(llm)
  setTalosConfig(cfg)
  let personasPath = defaultPersonasPath()
  let pReg =
    if fileExists(personasPath): loadPersonasFile(personasPath)
    else: newPersonaRegistry()
  setPersonaRegistry(pReg)
  setDelegationConfig(defaultDelegationConfig())

  let reg = buildRegistry(cfg)
  var mem = openMemory(cfg)
  defer: mem.close()
  return runTui(cfg, llm, reg, mem, noStream)


when isMainModule:
  import cligen

  ## We dispatchMulti so the user invokes subcommands as
  ##   talos_agent chat
  ##   talos_agent ask "what is 2+2?"
  ##   talos_agent session sess_...
  ##   talos_agent history
  ##   talos_agent search "needle"
  ##   talos_agent run code_reviewer "review the auth module"
  dispatchMulti(
    [cmdTui,     cmdName = "tui",     help = {
      "model":       "override model name",
      "provider":    "override provider (openrouter|vllm)",
      "temperature": "override sampling temperature (0..2). " &
                     "Negative means leave at config default.",
      "config":      "path to TOML config (overrides default)",
      "envFile":     "path to .env file (default: .env)",
      "noStream":    "disable token-by-token streaming output",
    }],
    [cmdChat,    cmdName = "chat",    help = {
      "model":       "override model name",
      "provider":    "override provider (openrouter|vllm)",
      "temperature": "override sampling temperature (0..2). " &
                     "Negative means leave at config default.",
      "config":      "path to TOML config (overrides default)",
      "envFile":     "path to .env file (default: .env)",
      "noStream":    "disable token-by-token streaming output",
    }],
    [cmdAsk,     cmdName = "ask",     help = {
      "model":       "override model name",
      "provider":    "override provider (openrouter|vllm)",
      "temperature": "override sampling temperature (0..2). " &
                     "Negative means leave at config default.",
      "config":      "path to TOML config (overrides default)",
      "envFile":     "path to .env file (default: .env)",
      "noStream":    "disable token-by-token streaming output",
      "plan":        "use plan-execute mode instead of ReAct loop",
    }],
    [cmdSession, cmdName = "session", help = {
      "model":       "override model name",
      "provider":    "override provider (openrouter|vllm)",
      "temperature": "override sampling temperature (0..2). " &
                     "Negative means leave at config default.",
      "config":      "path to TOML config (overrides default)",
      "envFile":     "path to .env file (default: .env)",
      "noStream":    "disable token-by-token streaming output",
    }],
    [cmdHistory, cmdName = "history", help = {
      "limit":       "max sessions to show",
      "config":      "path to TOML config (overrides default)",
      "envFile":     "path to .env file (default: .env)",
    }],
    [cmdSearch,  cmdName = "search",  help = {
      "limit":       "max matches to show",
      "config":      "path to TOML config (overrides default)",
      "envFile":     "path to .env file (default: .env)",
    }],
    [cmdRunPersona, cmdName = "run", help = {
      "persona":     "name of the persona to run (from personas.toml)",
      "task":         "task description for the persona agent",
      "config":      "path to TOML config (overrides default)",
      "envFile":     "path to .env file (default: .env)",
    }],
    [cmdWeb,      cmdName = "web",      help = {
      "port":        "port to listen on (default: 8080 from config/env)",
      "config":      "path to TOML config (overrides default)",
      "envFile":     "path to .env file (default: .env)",
    }],
    [cmdDaemon,  cmdName = "daemon",  help = {
      "config":      "path to TOML config (overrides default)",
      "envFile":     "path to .env file (default: .env)",
    }],
  )
