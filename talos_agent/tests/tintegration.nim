## End-to-end integration tests for Talos.
##
## These tests exercise the entire stack wired together as a real run
## would assemble it:
##
##   loadConfig -> TalosConfig
##                 |
##                 v
##         newLLMClient(...)  -----> MockLLMServer (HTTP, on localhost)
##                 |
##                 v
##         newToolRegistry()
##         register(shellTool())
##                 |
##                 v
##              newMemory(":memory:")  (sqlite + FTS5)
##                 |
##                 v
##              runAgentLoop(...)
##
## They are intentionally separate from `tagent_loop.nim` (which focuses
## on the agent loop in isolation) and `tconfig.nim` / `tmemory.nim`
## (which focus on individual modules). The point of this file is to
## prove that the modules compose correctly end-to-end.

import std/[asyncdispatch, asynchttpserver, json, locks, os, strutils,
            times, unittest, net]

import talos_core/config
import talos_core/llm_client
import talos_core/tool_registry
import talos_core/memory

import talos_core/testkit/mock_server
import talos_core/agent_loop
import tools/shell

# ---------------------------------------------------------------------------
# Threaded async-dispatcher harness around `mock_server.MockLLMServer`.
#
# Mirrors the harness in tagent_loop.nim. We keep a private copy here so
# the integration tests can run independently and so we can extend the
# harness if needed without touching the unit tests.
# ---------------------------------------------------------------------------

type
  QueuedKind = enum
    qkText, qkToolCall, qkError

  QueuedResponse = object
    kind: QueuedKind
    text: string
    toolName: string
    toolArgs: JsonNode
    errCode: int
    errMsg: string

  ServerHarness = ref object
    server: MockLLMServer
    thread: Thread[ServerHarness]

    portReady: bool
    portCond: Cond
    portLock: Lock

    stopFlag: bool
    lock: Lock
    cond: Cond              ## signalled when queue grows or stopFlag flips

    queue: seq[QueuedResponse]
    fallback: QueuedResponse

proc applyResponse(srv: MockLLMServer; r: QueuedResponse) =
  case r.kind
  of qkText:     srv.setResponse(r.text)
  of qkToolCall: srv.setToolCallResponse(r.toolName, r.toolArgs)
  of qkError:    srv.setErrorResponse(r.errCode, r.errMsg)

proc takeNext(h: ServerHarness): QueuedResponse =
  withLock h.lock:
    while h.queue.len == 0 and not h.stopFlag:
      wait(h.cond, h.lock)
    if h.queue.len > 0:
      result = h.queue[0]
      h.queue.delete(0)
    else:
      result = h.fallback

proc serveOne(h: ServerHarness) {.async.} =
  let next = takeNext(h)
  applyResponse(h.server, next)
  let srv = h.server
  let done = newFuture[void]("serveOne.done")
  proc handler(req: Request) {.async, gcsafe.} =
    {.cast(gcsafe).}:
      try:
        await srv.handleRequest(req)
      except CatchableError:
        discard
      finally:
        if not done.finished:
          done.complete()
  await h.server.server.acceptRequest(handler)
  await done

proc harnessThreadProc(h: ServerHarness) {.thread, gcsafe.} =
  {.cast(gcsafe).}:
    h.server.server.listen(Port(0))
    h.server.port = h.server.server.getPort().int

  withLock h.portLock:
    h.portReady = true
    signal(h.portCond)

  while true:
    var stop = false
    withLock h.lock:
      stop = h.stopFlag
    if stop:
      break
    try:
      {.cast(gcsafe).}:
        let f = serveOne(h)
        while not f.finished:
          poll(50)
          var localStop = false
          withLock h.lock:
            localStop = h.stopFlag
          if localStop:
            break
    except CatchableError:
      discard

  {.cast(gcsafe).}:
    try: h.server.stop() except CatchableError: discard

proc newHarness(): ServerHarness =
  result = ServerHarness(
    server: newMockLLMServer(),
    queue: @[],
    fallback: QueuedResponse(kind: qkText, text: ""),
  )
  initLock(result.lock)
  initLock(result.portLock)
  initCond(result.portCond)
  initCond(result.cond)

proc startHarness(h: ServerHarness) =
  createThread(h.thread, harnessThreadProc, h)
  withLock h.portLock:
    while not h.portReady:
      wait(h.portCond, h.portLock)

proc stopHarness(h: ServerHarness) =
  withLock h.lock:
    h.stopFlag = true
    signal(h.cond)
  try: h.server.server.close() except CatchableError: discard
  joinThread(h.thread)
  deinitCond(h.portCond)
  deinitLock(h.portLock)
  deinitCond(h.cond)
  deinitLock(h.lock)

proc enqueueText(h: ServerHarness; text: string) =
  withLock h.lock:
    h.queue.add(QueuedResponse(kind: qkText, text: text))
    signal(h.cond)

proc enqueueToolCall(h: ServerHarness; name: string; args: JsonNode) =
  withLock h.lock:
    h.queue.add(QueuedResponse(
      kind: qkToolCall, toolName: name, toolArgs: args))
    signal(h.cond)

proc enqueueError(h: ServerHarness; code: int; msg: string) =
  withLock h.lock:
    h.queue.add(QueuedResponse(
      kind: qkError, errCode: code, errMsg: msg))
    signal(h.cond)

proc setFallbackText(h: ServerHarness; text: string) =
  withLock h.lock:
    h.fallback = QueuedResponse(kind: qkText, text: text)

# ---------------------------------------------------------------------------
# Temp-file helpers
# ---------------------------------------------------------------------------

proc writeTempFile(path, content: string) =
  createDir(parentDir(path))
  writeFile(path, content)

proc tempPath(prefix, suffix: string): string =
  let stamp = $getCurrentProcessId() & "_" & $epochTime()
  result = getTempDir() / (prefix & "_" & stamp & suffix)
  if fileExists(result):
    removeFile(result)

proc cleanupSqlite(path: string) =
  for s in ["", "-wal", "-shm", "-journal"]:
    let p = path & s
    if fileExists(p):
      try: removeFile(p) except CatchableError: discard

# ---------------------------------------------------------------------------
# LLM client wired against the mock harness
# ---------------------------------------------------------------------------

proc makeClient(h: ServerHarness; cfg: TalosConfig): LLMClient =
  ## Builds an LLMClient that targets the mock harness but takes
  ## defaults (model, maxTokens, ...) from a real TalosConfig so we
  ## exercise the full config -> client wiring.
  newLLMClient(
    baseUrl = "http://127.0.0.1:" & $h.server.port & "/v1",
    apiKey = if cfg.openrouterApiKey.len > 0: cfg.openrouterApiKey
             else: "test-key",
    model = "mock-model",
    maxRetries = 1,
    retryBackoffMs = 5,
    timeoutMs = 5_000,
  )

# ---------------------------------------------------------------------------
# Tools used by the integration tests
# ---------------------------------------------------------------------------

proc echoToolExecute(args: JsonNode): ToolResult {.gcsafe, raises: [].} =
  let n = args{"text"}
  let s = if n.isNil or n.kind != JString: "" else: n.getStr()
  ToolResult(output: "echo:" & s, isError: false, exitCode: 0)

proc echoTool(): Tool =
  let schema = %*{
    "type": "object",
    "properties": {"text": {"type": "string"}},
    "required": ["text"],
  }
  newTool("echo", "Echo back the supplied text", schema, echoToolExecute)

# ---------------------------------------------------------------------------
# 1. Full pipeline tests
# ---------------------------------------------------------------------------

suite "integration: full pipeline (config + client + registry + memory + agent)":

  test "text-only response flows end-to-end":
    let h = newHarness()
    startHarness(h)
    defer: stopHarness(h)

    h.enqueueText("Hello from the full stack")

    # Build a real TalosConfig the same way the CLI would, then wire
    # every concrete dependency on top of it.
    var cfg = defaultConfig()
    cfg.openrouterApiKey = "sk-test"
    cfg.maxLoopIterations = 4
    validate(cfg)

    let llm = makeClient(h, cfg)
    let registry = newToolRegistry()
    registry.register(shellTool())
    registry.register(echoTool())
    var mem = newMemory(":memory:")
    defer: mem.close()

    let res = runAgentLoop(cfg, llm, registry, mem,
                           userInput = "say hi")

    check res.text == "Hello from the full stack"
    check res.stopReason == asrFinished
    check res.stats.totalTurns == 1
    check res.stats.toolCallsMade == 0
    # The full pipeline must produce a real session id and a logged
    # conversation (system + user + assistant at minimum).
    check res.sessionId.startsWith("sess_")
    let history = mem.getHistory(res.sessionId)
    check history.len == 3
    check history[0].role == crSystem
    check history[1].role == crUser
    check history[1].content == "say hi"
    check history[2].role == crAssistant
    check history[2].content == "Hello from the full stack"

  test "tool call response is dispatched through registry and memory":
    let h = newHarness()
    startHarness(h)
    defer: stopHarness(h)

    # Turn 1: model asks for echo. Turn 2: model emits final answer.
    h.enqueueToolCall("echo", %*{"text": "round-trip"})
    h.enqueueText("ok: round-trip done")

    var cfg = defaultConfig()
    cfg.openrouterApiKey = "sk-test"
    cfg.maxLoopIterations = 5

    let llm = makeClient(h, cfg)
    let registry = newToolRegistry()
    registry.register(echoTool())
    var mem = newMemory(":memory:")
    defer: mem.close()

    let res = runAgentLoop(cfg, llm, registry, mem,
                           userInput = "use the echo tool please")

    check res.text == "ok: round-trip done"
    check res.stopReason == asrFinished
    check res.stats.toolCallsMade == 1
    check res.stats.totalTurns == 2

    # End-to-end: the tool invocation must be visible in memory as a
    # tool message containing the registry's output.
    let history = mem.getHistory(res.sessionId)
    var sawToolResult = false
    for m in history:
      if m.role == crTool and m.content.contains("echo:round-trip"):
        sawToolResult = true
        break
    check sawToolResult

  test "LLM error is surfaced through agent result without crashing":
    let h = newHarness()
    startHarness(h)
    defer: stopHarness(h)

    h.enqueueError(500, "upstream blew up")

    var cfg = defaultConfig()
    cfg.openrouterApiKey = "sk-test"
    cfg.maxLoopIterations = 2

    let llm = makeClient(h, cfg)
    let registry = newToolRegistry()
    var mem = newMemory(":memory:")
    defer: mem.close()

    let res = runAgentLoop(cfg, llm, registry, mem,
                           userInput = "trigger 500")

    check res.stopReason == asrError
    check res.text.contains("LLM request failed")
    # Even the error path must persist a session and an assistant
    # message so callers can audit failures.
    let history = mem.getHistory(res.sessionId)
    check history.len >= 1
    var sawError = false
    for m in history:
      if m.role == crAssistant and m.content.contains("LLM request failed"):
        sawError = true
        break
    check sawError

# ---------------------------------------------------------------------------
# 2. Config loading tests (TOML + env + defaults composition)
# ---------------------------------------------------------------------------

suite "integration: config loading (toml + env + defaults)":
  # "defaults with no files present" is covered by tconfig.nim's
  # "loadConfig defaults" suite — nothing integration-specific about it.

  test "TOML file overrides defaults":
    let tmpDir = getTempDir() / "talos_integration_toml"
    createDir(tmpDir)
    defer: removeDir(tmpDir)
    let cfgFile = tmpDir / "config.toml"
    writeTempFile(cfgFile, """
[talos]
provider=vllm
max_tokens=1234
temperature=0.42
max_loop_iterations=7
db_path=/tmp/talos-integration.db
""")
    let cfg = loadConfig(
      configPath = cfgFile,
      envFilePath = "/nonexistent/.env",
    )
    check cfg.provider == "vllm"
    check cfg.maxTokens == 1234
    check abs(cfg.temperature - 0.42) < 1e-9
    check cfg.maxLoopIterations == 7
    check cfg.dbPath == "/tmp/talos-integration.db"

  test "env vars override TOML, .env supplies api key":
    let tmpDir = getTempDir() / "talos_integration_env"
    createDir(tmpDir)
    defer: removeDir(tmpDir)
    let cfgFile = tmpDir / "config.toml"
    writeTempFile(cfgFile, "[talos]\nmax_tokens=2048\nprovider=vllm\n")
    let envFile = tmpDir / ".env"
    writeTempFile(envFile, "OPENROUTER_API_KEY=sk-from-env-file\n")

    putEnv("TALOS_MAX_TOKENS", "555")
    putEnv("TALOS_PROVIDER", "openrouter")
    # Clear any real OPENROUTER_API_KEY from the OS env so it does not shadow
    # the .env file value under test (OS env has higher precedence than .env).
    let hadApiKey = existsEnv("OPENROUTER_API_KEY")
    let oldApiKey = getEnv("OPENROUTER_API_KEY")
    delEnv("OPENROUTER_API_KEY")
    defer:
      delEnv("TALOS_MAX_TOKENS")
      delEnv("TALOS_PROVIDER")
      if hadApiKey:
        putEnv("OPENROUTER_API_KEY", oldApiKey)

    let cfg = loadConfig(configPath = cfgFile, envFilePath = envFile)
    # env var beats TOML
    check cfg.maxTokens == 555
    check cfg.provider == "openrouter"
    # .env supplies the API key
    check cfg.openrouterApiKey == "sk-from-env-file"

  test "validate rejects an obviously broken config":
    var cfg = defaultConfig()
    cfg.provider = "not-a-provider"
    expect ConfigError:
      validate(cfg)

# ---------------------------------------------------------------------------
# 3. Memory persistence tests (sessions, history, FTS5 search)
# ---------------------------------------------------------------------------

suite "integration: memory persistence + FTS5 search":

  test "session round-trip: append and retrieve a multi-message history":
    var mem = newMemory(":memory:")
    defer: mem.close()

    let sid = mem.newSession()
    check sid.startsWith("sess_")

    let m1 = ChatMessage(role: crSystem,    content: "you are talos")
    let m2 = ChatMessage(role: crUser,      content: "hello agent")
    let m3 = ChatMessage(
      role: crAssistant,
      content: "",
      toolCalls: @[
        ToolCall(id: "call_1", name: "echo", arguments: """{"text":"hi"}""")
      ],
    )
    let m4 = ChatMessage(
      role: crTool,
      name: "echo",
      toolCallId: "call_1",
      content: "echo:hi",
    )
    let m5 = ChatMessage(role: crAssistant, content: "all done")

    mem.appendMessage(sid, m1, tokensIn = 5,  tokensOut = 0)
    mem.appendMessage(sid, m2, tokensIn = 4,  tokensOut = 0)
    mem.appendMessage(sid, m3, tokensIn = 9,  tokensOut = 12)
    mem.appendMessage(sid, m4)
    mem.appendMessage(sid, m5, tokensIn = 0,  tokensOut = 7)

    let history = mem.getHistory(sid)
    check history.len == 5
    check history[0].role == crSystem
    check history[0].content == "you are talos"
    check history[2].role == crAssistant
    check history[2].toolCalls.len == 1
    check history[2].toolCalls[0].name == "echo"
    check history[2].toolCalls[0].arguments == """{"text":"hi"}"""
    check history[3].role == crTool
    check history[3].name == "echo"
    check history[3].toolCallId == "call_1"
    check history[3].content == "echo:hi"

    # Token usage is aggregated.
    let usage = mem.getTokenUsage(sid)
    check usage.promptTokens == 5 + 4 + 9
    check usage.completionTokens == 12 + 7
    check usage.totalTokens == usage.promptTokens + usage.completionTokens

  test "searchHistory finds messages via FTS5":
    var mem = newMemory(":memory:")
    defer: mem.close()

    let sidA = mem.newSession()
    let sidB = mem.newSession()
    mem.appendMessage(sidA,
      ChatMessage(role: crUser, content: "the quick brown fox"))
    mem.appendMessage(sidA,
      ChatMessage(role: crAssistant, content: "lazy dog jumped over"))
    mem.appendMessage(sidB,
      ChatMessage(role: crUser, content: "completely unrelated message"))

    # FTS5 token match
    let hitsFox = mem.searchHistory("fox")
    check hitsFox.len >= 1
    var foundFox = false
    for h in hitsFox:
      if h.sessionId == sidA and h.content.contains("fox"):
        foundFox = true
    check foundFox

    # Match in the OTHER session, not the first one
    let hitsUnrelated = mem.searchHistory("unrelated")
    check hitsUnrelated.len >= 1
    check hitsUnrelated[0].sessionId == sidB

    # Empty query yields no results (per memory.nim contract).
    check mem.searchHistory("").len == 0

  test "memory survives across reopen of the same on-disk database":
    let dbPath = tempPath("talos_integration_mem", ".db")
    defer: cleanupSqlite(dbPath)

    var sid = ""
    block:
      var mem = newMemory(dbPath)
      defer: mem.close()
      sid = mem.newSession()
      mem.appendMessage(sid,
        ChatMessage(role: crUser, content: "persisted message"))

    # Reopen.
    var mem2 = newMemory(dbPath)
    defer: mem2.close()
    let history = mem2.getHistory(sid)
    check history.len == 1
    check history[0].role == crUser
    check history[0].content == "persisted message"

# ---------------------------------------------------------------------------
# 4. Tool registry integration tests
# ---------------------------------------------------------------------------

suite "integration: tool registry + shell tool":

  test "shell tool registers and executes via the registry":
    let registry = newToolRegistry()
    registry.register(shellTool())
    check registry.has("shell")
    check registry.len == 1

    # Run a trivially safe command. Pipe to /bin/sh so this works on
    # any POSIX host with /bin/sh available.
    let res = registry.execute("shell", """{"cmd": "echo integration_ok"}""")
    check not res.isError
    check res.exitCode == 0
    check res.output.contains("integration_ok")

  test "shell tool denies dangerous commands without executing them":
    let registry = newToolRegistry()
    registry.register(shellTool())
    let res = registry.execute("shell", """{"cmd": "rm -rf /"}""")
    check res.isError
    check res.output.contains("DENIED")

  test "shell tool reports invalid JSON arguments cleanly":
    let registry = newToolRegistry()
    registry.register(shellTool())
    # Arguments aren't even valid JSON.
    let res = registry.execute("shell", "this is not json")
    check res.isError
    check res.output.contains("invalid arguments")

  test "openAI definitions include the registered shell tool":
    let registry = newToolRegistry()
    registry.register(shellTool())
    let defs = registry.toOpenAIDefinitions()
    check defs.kind == JArray
    check defs.len == 1
    let entry = defs[0]
    check entry.kind == JObject
    check entry["type"].getStr() == "function"
    let fn = entry["function"]
    check fn["name"].getStr() == "shell"
    check fn["description"].getStr().len > 0
    let params = fn["parameters"]
    check params["type"].getStr() == "object"
    check params["properties"].hasKey("cmd")
    check params["required"].kind == JArray

  test "registry rejects duplicate registrations of the same tool":
    let registry = newToolRegistry()
    registry.register(shellTool())
    expect ToolDuplicateError:
      registry.register(shellTool())

# ---------------------------------------------------------------------------
# 5. Agent loop integration test (full ReAct + memory logging)
# ---------------------------------------------------------------------------

suite "integration: agent loop end-to-end (ReAct + memory log)":

  test "ReAct: tool call -> tool result -> final answer, all logged":
    let h = newHarness()
    startHarness(h)
    defer: stopHarness(h)

    # Turn 1: tool call. Turn 2: final answer that references the
    # output the tool produced, proving the tool result was actually
    # fed back to the model loop.
    h.enqueueToolCall("echo", %*{"text": "from-react"})
    h.enqueueText("answer references echo:from-react")
    h.setFallbackText("UNEXPECTED EXTRA TURN")

    var cfg = defaultConfig()
    cfg.openrouterApiKey = "sk-test"
    cfg.maxLoopIterations = 5

    let llm = makeClient(h, cfg)
    let registry = newToolRegistry()
    registry.register(echoTool())
    var mem = newMemory(":memory:")
    defer: mem.close()

    let agentCfg = newAgentConfig(cfg)
    let res = runAgentLoop(agentCfg, llm, registry, mem,
                           userInput = "do the react thing")

    # Outcome
    check res.stopReason == asrFinished
    check res.text == "answer references echo:from-react"
    check res.stats.totalTurns == 2
    check res.stats.toolCallsMade == 1

    # Memory log: system + user + assistant(tool_call) + tool + assistant
    let history = mem.getHistory(res.sessionId)
    check history.len == 5
    check history[0].role == crSystem
    check history[1].role == crUser
    check history[1].content == "do the react thing"
    check history[2].role == crAssistant
    check history[2].toolCalls.len == 1
    check history[2].toolCalls[0].name == "echo"
    check history[3].role == crTool
    check history[3].name == "echo"
    check history[3].content.contains("echo:from-react")
    check history[4].role == crAssistant
    check history[4].content == "answer references echo:from-react"

  test "agent loop persists session to disk and is searchable afterwards":
    let h = newHarness()
    startHarness(h)
    defer: stopHarness(h)

    h.enqueueText("persisted answer with searchable_sentinel inside")

    let dbPath = tempPath("talos_integration_agent", ".db")
    defer: cleanupSqlite(dbPath)

    var cfg = defaultConfig()
    cfg.openrouterApiKey = "sk-test"
    cfg.maxLoopIterations = 3
    cfg.dbPath = dbPath

    let llm = makeClient(h, cfg)
    let registry = newToolRegistry()
    var mem = newMemory(dbPath)

    let res = runAgentLoop(cfg, llm, registry, mem,
                           userInput = "make it searchable")
    check res.stopReason == asrFinished
    mem.close()

    # Reopen and search via FTS5: the persisted assistant message
    # must be findable.
    var mem2 = newMemory(dbPath)
    defer: mem2.close()
    let hits = mem2.searchHistory("searchable_sentinel")
    check hits.len >= 1
    var foundInRightSession = false
    for h2 in hits:
      if h2.sessionId == res.sessionId:
        foundInRightSession = true
    check foundInRightSession
