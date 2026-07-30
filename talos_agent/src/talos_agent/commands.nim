## CLI command handlers: chat, ask, session, sessions, search, run, web.

import std/[os, strutils, strformat, asyncdispatch, asynchttpserver, net, options]
import db_connector/db_sqlite
import talos_core/agent_loop
import talos_core/build_llm_client
import talos_core/config
import talos_core/delegate
import talos_core/llm_client
import talos_core/memory
import talos_core/persona
import talos_core/plan_executor
import talos_core/tool_registry
import talos_agent/bang
import talos_agent/cli
import talos_agent/config
import talos_agent/delegate_tool
import talos_agent/state
import talos_agent/web_server
import talos_agent/tui/chat_tui
import talos_agent/session_alias
import talos_agent/voice
import tools/shell

# ---------------------------------------------------------------------------
# Shared turn logic
# ---------------------------------------------------------------------------

proc runOneTurn(
    cfg: TalosConfig;
    llm: LLMClient;
    reg: ToolRegistry;
    mem: var Memory;
    userInput: string;
    streamCallback: OnStreamEvent = nil;
    resumeSessionId: string = "";
): AgentResult =
  ## Thin wrapper around `runAgentLoop` so the chat and ask commands
  ## share their per-turn logic. Passing the previous turn's
  ## `res.sessionId` back in as `resumeSessionId` is what gives the
  ## interactive REPL real multi-turn memory instead of each line being
  ## answered as if it were the first message of a new conversation.
  resetDelegationBudget()
  var agentCfg = newAgentConfig(cfg, systemPrompt = TalosSystemPrompt)
  agentCfg.streamCallback = streamCallback
  runAgentLoop(agentCfg, llm, reg, mem, userInput, resumeSessionId = resumeSessionId)

proc runChatLoop*(
    cfg: TalosConfig;
    llm: LLMClient;
    reg: ToolRegistry;
    mem: var Memory;
    initialBanner: string = "";
    streamCallback: OnStreamEvent = nil;
    initialSessionId: string = "";
): int =
  ## Runs the interactive REPL until EOF or `:quit`. SIGINT between
  ## turns is treated as a clean exit. Returns 0 on clean exit, 1 on
  ## unrecoverable error.
  ##
  ## `initialSessionId`, if given, is resumed for the first turn (its
  ## prior history is loaded into context, not just replayed to stdout);
  ## every subsequent turn resumes whatever session the previous turn
  ## returned, so the whole REPL runs as one continuous conversation.
  if initialBanner.len > 0:
    printSystemNote(initialBanner)
  printSystemNote("type :quit to exit; Ctrl+C to interrupt")
  var sessionId = initialSessionId
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
    if isBangCommand(trimmed):
      # `!<cmd>` (task-10): run it through the shell tool right here —
      # never sent to the LLM, but stored as a [!<cmd>] system message so
      # the agent sees what the user ran on its next turn.
      let bangRes = runBangCommand(reg, mem, sessionId, TalosSystemPrompt, trimmed)
      sessionId = bangRes.sessionId
      if bangRes.display.len > 0:
        printSystemNote(bangRes.display)
      continue
    var res: AgentResult
    try:
      res = runOneTurn(cfg, llm, reg, mem, trimmed, streamCallback, sessionId)
    except CatchableError as e:
      printError(e.msg)
      continue
    sessionId = res.sessionId
    # Don't re-print text if streaming already printed it token-by-token.
    if streamCallback == nil:
      printAssistant(res.text)
    else:
      stdout.writeLine("")
    if res.stopReason != asrFinished:
      printSystemNote("stop reason: " & $res.stopReason)
  return 0

# ---------------------------------------------------------------------------
# Chat / ask / session
# ---------------------------------------------------------------------------

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

proc cmdChat*(
    model = "";
    provider = "";
    temperature = -1.0;
    config = "";
    envFile = ".env";
    noStream = false;
    alias = "";
): int =
  ## Interactive chat mode: fullscreen TUI. Returns a process exit code.
  ##
  ## `alias`, if given, resumes the session last used under that name
  ## (from any surface) instead of starting fresh — see cmdAsk's alias
  ## doc comment for the full picture.
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
  let personasPath = defaultPersonasPath()
  let pReg = loadPersonasSafe(personasPath)
  setAgentGlobals(llm, cfg, pReg, defaultDelegationConfig())

  let reg = buildRegistry(cfg)
  var mem = openMemory(cfg)
  defer: mem.close()

  var resumeId = ""
  if alias.len > 0:
    let db = open(resolveDbPath(cfg), "", "", "")
    initSessionAliasSchema(db)
    let existing = getSessionForAlias(db, alias)
    if existing.isSome: resumeId = existing.get()
    db.close()

  return runTui(cfg, llm, reg, mem, noStream,
                requestSetup = resetDelegationBudget,
                initialSessionId = resumeId, aliasName = alias)

proc cmdAsk*(
    question: seq[string];
    model = "";
    provider = "";
    temperature = -1.0;
    config = "";
    envFile = ".env";
    noStream = false;
    plan = false;
    alias = "";
): int =
  ## Single-shot question mode.
  ##
  ## `alias`, if given, resumes the session last used under that name
  ## (from any surface — CLI, TUI, or a Discord thread aliased via
  ## `!alias set <name>`) instead of starting fresh, and updates the
  ## alias to point at this turn's session afterward. This is what lets
  ## a conversation started on one surface continue on another.
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
  let personasPath = defaultPersonasPath()
  let pReg = loadPersonasSafe(personasPath)
  setAgentGlobals(llm, cfg, pReg, defaultDelegationConfig())

  let reg = buildRegistry(cfg)
  var mem = openMemory(cfg)
  defer: mem.close()
  let userInput = question.join(" ")

  var resumeId = ""
  if alias.len > 0:
    let db = open(resolveDbPath(cfg), "", "", "")
    initSessionAliasSchema(db)
    let existing = getSessionForAlias(db, alias)
    if existing.isSome: resumeId = existing.get()
    db.close()

  proc saveAlias(sid: string) =
    if alias.len == 0: return
    let db = open(resolveDbPath(cfg), "", "", "")
    initSessionAliasSchema(db)
    setSessionAlias(db, alias, sid)
    db.close()

  if plan:
    # --- Plan-Execute mode ---
    var planRes: PlanResult
    try:
      # Plan generation routes through the "plan" role (task-13) when
      # configured — e.g. a stronger/pricier model for decomposition than
      # the "default" role used for step execution below. Falls back to
      # the same model as `llm` when no [roles.plan] section is configured.
      let planLlm = buildLLMClient(cfg, "plan")
      let executionPlan = generatePlan(planLlm, userInput, reg)
      stdout.writeLine(formatPlan(executionPlan))
      stdout.flushFile()
      var agentCfg = newAgentConfig(cfg, systemPrompt = TalosSystemPrompt)
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
            stdout.flushFile(),
        resumeSessionId = resumeId)
    except PlanError as e:
      printError("Plan generation failed: " & e.msg); return 1
    except CatchableError as e:
      printError(e.msg); return 1
    saveAlias(planRes.sessionId)
    if noStream:
      stdout.writeLine(planRes.finalAnswer)
    else:
      stdout.write("\n"); stdout.flushFile()
    return 0

  # --- ReAct mode (default) ---
  var res: AgentResult
  try:
    if noStream:
      let agentCfg = newAgentConfig(cfg, systemPrompt = TalosSystemPrompt)
      res = runAgentLoop(agentCfg, llm, reg, mem, userInput, resumeSessionId = resumeId)
    else:
      var agentCfg = newAgentConfig(cfg, systemPrompt = TalosSystemPrompt)
      agentCfg.streamCallback = proc(event: ChatCompletionStreamEvent) {.gcsafe, raises: [].} =
        {.cast(raises: []).}:
          if event.kind == sekContent and event.delta.len > 0:
            stdout.write(event.delta)
            stdout.flushFile()
      res = runAgentLoop(agentCfg, llm, reg, mem, userInput, resumeSessionId = resumeId)
  except CatchableError as e:
    printError(e.msg); return 1
  saveAlias(res.sessionId)
  stdout.writeLine(res.text)
  if res.stopReason != asrFinished:
    return 3
  return 0

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
  let personasPath = defaultPersonasPath()
  let pReg = loadPersonasSafe(personasPath)
  setAgentGlobals(llm, cfg, pReg, defaultDelegationConfig())

  let reg = buildRegistry(cfg)
  var mem = openMemory(cfg)
  defer: mem.close()
  let history = mem.getHistory(sessionId)
  printSystemNote(
    fmt"resuming session {sessionId} ({history.len} messages)")
  replayHistory(history)
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
    initialSessionId = sessionId,
    streamCallback = streamCb,
  )
  return 0

# ---------------------------------------------------------------------------
# History / search
# ---------------------------------------------------------------------------

proc cmdSessions*(
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

proc cmdSearch*(
    query: seq[string];
    limit = 20;
    semantic = false;
    config = "";
    envFile = ".env";
): int =
  ## Search across stored message content. With --semantic, also pulls in
  ## semantically-related retained facts (see the retain/recall/reflect
  ## tools) and merges both into one ranked list via searchHybrid.
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

  if semantic:
    let hits = mem.searchHybrid(q, buildEmbeddingClient(cfg), topK = limit)
    if hits.len == 0:
      printSystemNote("no matches")
      return 0
    for h in hits:
      echo fmt"[{h.kind}] [{h.sessionId}] {h.createdAt}"
      echo "  " & h.content
    return 0

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
# Persona run
# ---------------------------------------------------------------------------

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
  var reg = loadPersonasSafe(personasPath)
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

  # Set agent globals so the delegate tool can work
  setAgentGlobals(llm, cfg, reg, dc)

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
  let personasPath = defaultPersonasPath()
  let pReg = loadPersonasSafe(personasPath)
  setAgentGlobals(llm, cfg, pReg, defaultDelegationConfig())

  let reg = buildRegistry(cfg)
  var mem = openMemory(cfg)
  defer: mem.close()

  let ws = newWebServer(cfg, llm, reg, mem)
  ws.requestSetup = resetDelegationBudget
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
