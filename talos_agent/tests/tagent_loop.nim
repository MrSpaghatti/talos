## Tests for talos_agent/agent_loop.nim
##
## Drives the ReAct loop against the async mock server from
## `talos_core/testkit/mock_server.nim`. The mock server only accepts a
## single connection per `start()`; this test runs the asyncdispatcher
## in a dedicated thread and re-arms `acceptRequest` for every turn so
## the sync LLMClient can complete multi-turn conversations against it.

import std/[asyncdispatch, asynchttpserver, json, locks, strutils,
            unittest, net]

import talos_core/llm_client
import talos_core/tool_registry
import talos_core/memory
import talos_core/config

import talos_core/testkit/mock_server
import talos_core/agent_loop

# ---------------------------------------------------------------------------
# Threaded async-dispatcher harness around `mock_server.MockLLMServer`
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
  ## Blocks until a queued response is available or stopFlag is set.
  ## Returns the first queued response, or the fallback if stopping.
  withLock h.lock:
    while h.queue.len == 0 and not h.stopFlag:
      wait(h.cond, h.lock)
    if h.queue.len > 0:
      result = h.queue[0]
      h.queue.delete(0)
    else:
      result = h.fallback

proc serveOne(h: ServerHarness) {.async.} =
  ## Programs the mock server's response slot, accepts a single TCP
  ## connection, and waits until the response has actually been written
  ## back. `acceptRequest` only awaits the TCP accept (the actual request
  ## handling is `asyncCheck`-ed), so we use a `done` Future that the
  ## callback completes after `handleRequest` returns to keep the
  ## response slot stable until the bytes are on the wire.
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
  # Bind a listening socket from inside this thread so the dispatcher
  # owns it. The asyncdispatcher's globals are thread-local, so as long
  # as only this thread polls, we can safely cast to gcsafe.
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
        # Block until exactly one request is served. The 50ms poll cap
        # keeps the stop flag responsive even when no client connects.
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
  # Closing the listening socket from the test thread unblocks the
  # dispatcher's accept call so the worker thread can exit.
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

proc requestCount(h: ServerHarness): int =
  h.server.getRequestCount()

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc makeClient(h: ServerHarness; maxRetries = 1): LLMClient =
  newLLMClient(
    baseUrl = "http://127.0.0.1:" & $h.server.port & "/v1",
    apiKey = "test-key",
    model = "mock-model",
    maxRetries = maxRetries,
    retryBackoffMs = 5,
    timeoutMs = 5_000,
  )

proc echoToolExecute(args: JsonNode): ToolResult {.gcsafe, raises: [].} =
  ## A trivial tool that echoes its `text` argument back as output.
  let n = args{"text"}
  let s = if n.isNil or n.kind != JString: "" else: n.getStr()
  ToolResult(output: "echo:" & s, isError: false, exitCode: 0)

proc failingToolExecute(args: JsonNode): ToolResult {.gcsafe, raises: [].} =
  ## A tool that always reports an error.
  ToolResult(
    output: "boom: simulated tool failure",
    isError: true,
    exitCode: 2,
  )

proc echoTool(): Tool =
  let schema = %*{
    "type": "object",
    "properties": {"text": {"type": "string"}},
    "required": ["text"],
  }
  newTool("echo", "Echo back the supplied text", schema, echoToolExecute)

proc failingTool(): Tool =
  newTool(
    "failing",
    "A tool that always fails",
    emptyParameters(),
    failingToolExecute,
  )

proc smallAgentConfig(maxIterations = 5; threshold = 3): AgentConfig =
  AgentConfig(
    maxIterations: maxIterations,
    loopDetectionThreshold: threshold,
    systemPrompt: "test-system",
  )

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

suite "agent_loop: text-only response":
  test "returns assistant text when no tools are needed":
    let h = newHarness()
    startHarness(h)
    defer: stopHarness(h)

    h.enqueueText("Hello, world!")
    h.setFallbackText("UNEXPECTED EXTRA RESPONSE")

    let llm = makeClient(h)
    let reg = newToolRegistry()
    var mem = newMemory(":memory:")
    defer: mem.close()

    let res = runAgentLoop(
      smallAgentConfig(),
      llm, reg, mem,
      userInput = "ping",
    )

    check res.text == "Hello, world!"
    check res.stopReason == asrFinished
    check res.stats.totalTurns == 1
    check res.stats.toolCallsMade == 0
    check h.requestCount == 1

suite "agent_loop: tool call then text":
  test "executes tool, sends result back, returns final answer":
    let h = newHarness()
    startHarness(h)
    defer: stopHarness(h)

    # Turn 1: model asks to call `echo` with {"text": "abc"}
    h.enqueueToolCall("echo", %*{"text": "abc"})
    # Turn 2: model produces final answer.
    h.enqueueText("done: echo:abc")

    let llm = makeClient(h)
    let reg = newToolRegistry()
    reg.register(echoTool())
    var mem = newMemory(":memory:")
    defer: mem.close()

    let res = runAgentLoop(
      smallAgentConfig(),
      llm, reg, mem,
      userInput = "use the echo tool",
    )

    check res.text == "done: echo:abc"
    check res.stopReason == asrFinished
    check res.stats.toolCallsMade == 1
    check res.stats.totalTurns == 2
    check h.requestCount == 2

suite "agent_loop: max iterations":
  test "stops with synthetic message when iterations exhausted":
    let h = newHarness()
    startHarness(h)
    defer: stopHarness(h)

    # Every request returns a tool call so the model never finishes.
    # Distinct args per turn keep loop detection from firing first.
    let cfg = smallAgentConfig(maxIterations = 3, threshold = 99)
    for i in 0 ..< cfg.maxIterations:
      h.enqueueToolCall("echo", %*{"text": "iter-" & $i})
    h.setFallbackText("should-not-be-used")

    let llm = makeClient(h)
    let reg = newToolRegistry()
    reg.register(echoTool())
    var mem = newMemory(":memory:")
    defer: mem.close()

    let res = runAgentLoop(cfg, llm, reg, mem, userInput = "spin")

    check res.stopReason == asrMaxIterations
    check res.text.contains("Max iterations")
    check res.stats.totalTurns == cfg.maxIterations
    check res.stats.toolCallsMade == cfg.maxIterations

suite "agent_loop: loop detection":
  test "stops when same tool+args are issued threshold times in a row":
    let h = newHarness()
    startHarness(h)
    defer: stopHarness(h)

    for _ in 0 ..< 10:
      h.enqueueToolCall("echo", %*{"text": "same"})

    let cfg = smallAgentConfig(maxIterations = 20, threshold = 3)
    let llm = makeClient(h)
    let reg = newToolRegistry()
    reg.register(echoTool())
    var mem = newMemory(":memory:")
    defer: mem.close()

    let res = runAgentLoop(cfg, llm, reg, mem, userInput = "loop me")

    check res.stopReason == asrLoopDetected
    check res.text.contains("Loop detected")
    check res.text.contains("echo")
    check res.stats.totalTurns == 3
    check res.stats.toolCallsMade == 3

  test "different args do NOT trigger loop detection":
    let h = newHarness()
    startHarness(h)
    defer: stopHarness(h)

    h.enqueueToolCall("echo", %*{"text": "a"})
    h.enqueueToolCall("echo", %*{"text": "b"})
    h.enqueueToolCall("echo", %*{"text": "c"})
    h.enqueueText("converged")

    let cfg = smallAgentConfig(maxIterations = 10, threshold = 3)
    let llm = makeClient(h)
    let reg = newToolRegistry()
    reg.register(echoTool())
    var mem = newMemory(":memory:")
    defer: mem.close()

    let res = runAgentLoop(cfg, llm, reg, mem, userInput = "vary args")
    check res.stopReason == asrFinished
    check res.text == "converged"
    check res.stats.toolCallsMade == 3

suite "agent_loop: tool errors":
  test "tool error is reported back to the LLM, loop continues":
    let h = newHarness()
    startHarness(h)
    defer: stopHarness(h)

    # Turn 1: model calls a tool that always fails.
    h.enqueueToolCall("failing", %*{})
    # Turn 2: after seeing the ERROR text, model recovers.
    h.enqueueText("recovered after error")

    let cfg = smallAgentConfig()
    let llm = makeClient(h)
    let reg = newToolRegistry()
    reg.register(failingTool())
    var mem = newMemory(":memory:")
    defer: mem.close()

    let res = runAgentLoop(cfg, llm, reg, mem,
                           userInput = "trigger an error")
    check res.stopReason == asrFinished
    check res.text == "recovered after error"
    check res.stats.toolCallsMade == 1

    # Verify the tool result message logged to memory carries the
    # ERROR marker so downstream consumers can detect failures.
    let history = mem.getHistory(res.sessionId)
    var sawErrorToolMsg = false
    for m in history:
      if m.role == crTool and m.content.startsWith("ERROR:"):
        sawErrorToolMsg = true
        break
    check sawErrorToolMsg

  test "unknown tool name yields an error tool message, loop continues":
    let h = newHarness()
    startHarness(h)
    defer: stopHarness(h)

    h.enqueueToolCall("does_not_exist", %*{"x": 1})
    h.enqueueText("oh well")

    let cfg = smallAgentConfig()
    let llm = makeClient(h)
    let reg = newToolRegistry()           # empty registry
    var mem = newMemory(":memory:")
    defer: mem.close()

    let res = runAgentLoop(cfg, llm, reg, mem, userInput = "go")
    check res.stopReason == asrFinished
    check res.text == "oh well"

suite "agent_loop: memory logging":
  test "logs system, user, assistant and tool messages":
    let h = newHarness()
    startHarness(h)
    defer: stopHarness(h)

    h.enqueueToolCall("echo", %*{"text": "hi"})
    h.enqueueText("final answer")

    let cfg = smallAgentConfig()
    let llm = makeClient(h)
    let reg = newToolRegistry()
    reg.register(echoTool())
    var mem = newMemory(":memory:")
    defer: mem.close()

    let res = runAgentLoop(cfg, llm, reg, mem, userInput = "do it")
    check res.stopReason == asrFinished

    let history = mem.getHistory(res.sessionId)
    # Expected order: system, user, assistant(tool_calls), tool, assistant
    check history.len == 5
    check history[0].role == crSystem
    check history[0].content == cfg.systemPrompt
    check history[1].role == crUser
    check history[1].content == "do it"
    check history[2].role == crAssistant
    check history[2].toolCalls.len == 1
    check history[2].toolCalls[0].name == "echo"
    check history[3].role == crTool
    check history[3].name == "echo"
    check history[3].content.contains("echo:hi")
    check history[4].role == crAssistant
    check history[4].content == "final answer"

  test "session id from result matches a real session in memory":
    let h = newHarness()
    startHarness(h)
    defer: stopHarness(h)

    h.enqueueText("ok")

    let llm = makeClient(h)
    let reg = newToolRegistry()
    var mem = newMemory(":memory:")
    defer: mem.close()

    let res = runAgentLoop(
      smallAgentConfig(), llm, reg, mem, userInput = "ping")
    check res.sessionId.startsWith("sess_")
    let history = mem.getHistory(res.sessionId)
    check history.len == 3
    check history[0].role == crSystem
    check history[1].role == crUser
    check history[1].content == "ping"
    check history[2].role == crAssistant
    check history[2].content == "ok"

suite "agent_loop: resumeSessionId":
  test "second call with the same resumeSessionId sees the first call's history":
    let h = newHarness()
    startHarness(h)
    defer: stopHarness(h)

    h.enqueueText("first answer")
    h.enqueueText("second answer")

    let llm = makeClient(h)
    let reg = newToolRegistry()
    var mem = newMemory(":memory:")
    defer: mem.close()

    let cfg = smallAgentConfig()
    let sid = "sess_shared_thread"

    let res1 = runAgentLoop(
      cfg, llm, reg, mem, userInput = "first message",
      resumeSessionId = sid)
    check res1.sessionId == sid
    check res1.text == "first answer"

    let res2 = runAgentLoop(
      cfg, llm, reg, mem, userInput = "second message",
      resumeSessionId = sid)
    check res2.sessionId == sid
    check res2.text == "second answer"

    # Both turns landed in the SAME session, in order: system, user1,
    # assistant1, user2, assistant2. A single system prompt is seeded only
    # once, on the first turn.
    let history = mem.getHistory(sid)
    check history.len == 5
    check history[0].role == crSystem
    check history[1].role == crUser
    check history[1].content == "first message"
    check history[2].role == crAssistant
    check history[2].content == "first answer"
    check history[3].role == crUser
    check history[3].content == "second message"
    check history[4].role == crAssistant
    check history[4].content == "second answer"

    # The second LLM request must have carried the first turn's messages —
    # this is the actual "continuity" property, not just a shared DB row.
    check h.server.getLastRequestBody().contains("first message")
    check h.server.getLastRequestBody().contains("first answer")

  test "resumeSessionId with no prior history behaves like a fresh session":
    let h = newHarness()
    startHarness(h)
    defer: stopHarness(h)

    h.enqueueText("hello")

    let llm = makeClient(h)
    let reg = newToolRegistry()
    var mem = newMemory(":memory:")
    defer: mem.close()

    let sid = "sess_brand_new_thread"
    let res = runAgentLoop(
      smallAgentConfig(), llm, reg, mem, userInput = "hi",
      resumeSessionId = sid)

    check res.sessionId == sid
    check res.text == "hello"
    let history = mem.getHistory(sid)
    check history.len == 3  # system, user, assistant
    check history[0].role == crSystem

  test "two different Discord threads stay isolated — no cross-talk":
    ## Guards the realistic regression this fix could introduce: a second
    ## thread's turn accidentally seeing a *different* thread's history.
    ## Simulates two separate Discord threads (distinct resumeSessionId
    ## per thread) interleaved on the same Memory store, as would happen
    ## with two users talking to the bot in different channels at once.
    let h = newHarness()
    startHarness(h)
    defer: stopHarness(h)

    h.enqueueText("thread A: got it")
    h.enqueueText("thread B: got it")

    let llm = makeClient(h)
    let reg = newToolRegistry()
    var mem = newMemory(":memory:")
    defer: mem.close()

    let cfg = smallAgentConfig()
    discard runAgentLoop(
      cfg, llm, reg, mem, userInput = "thread A: my name is Alice",
      resumeSessionId = "sess_thread_a")
    discard runAgentLoop(
      cfg, llm, reg, mem, userInput = "thread B: my name is Bob",
      resumeSessionId = "sess_thread_b")

    let historyA = mem.getHistory("sess_thread_a")
    let historyB = mem.getHistory("sess_thread_b")

    # Each thread's history contains only its own turn, never the other's.
    check historyA.len == 3  # system, user, assistant
    check historyB.len == 3
    check historyA[1].content == "thread A: my name is Alice"
    check historyB[1].content == "thread B: my name is Bob"
    for msg in historyA:
      check "Bob" notin msg.content
    for msg in historyB:
      check "Alice" notin msg.content

suite "agent_loop: convenience overload":
  test "TalosConfig overload threads maxLoopIterations through":
    let h = newHarness()
    startHarness(h)
    defer: stopHarness(h)

    # The mock never produces a final text answer, so the only way this
    # run can stop is by hitting maxIterations — proving the overload
    # actually wires TalosConfig.maxLoopIterations into AgentConfig
    # rather than falling back to the (much larger) default.
    for i in 0 ..< 4:
      h.enqueueToolCall("echo", %*{"text": "iter-" & $i})
    h.setFallbackText("should-not-be-used")

    var mc = defaultConfig()
    mc.maxLoopIterations = 4
    let llm = makeClient(h)
    let reg = newToolRegistry()
    reg.register(echoTool())
    var mem = newMemory(":memory:")
    defer: mem.close()

    let res = runAgentLoop(mc, llm, reg, mem, userInput = "hi")
    check res.stopReason == asrMaxIterations
    check res.stats.totalTurns == 4
