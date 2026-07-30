## Tests for bang commands (task-10): `!<cmd>` intercepted before the LLM,
## executed via the shell tool, output persisted as a [!<cmd>] crSystem
## message so the agent sees it on its next turn.

import std/[strutils, unittest]
import talos_core/llm_client
import talos_core/memory
import talos_core/tool_registry
import talos_agent/bang
import tools/shell

proc makeReg(): ToolRegistry =
  result = newToolRegistry()
  result.register(shellTool())

suite "isBangCommand":
  test "recognizes bang lines, including a bare bang":
    check isBangCommand("!pwd")
    check isBangCommand("!")
  test "does not consume ordinary input or slash commands":
    check not isBangCommand("hello!")
    check not isBangCommand("/help")
    check not isBangCommand("what does ! mean?")

suite "runBangCommand":
  test "runs the command and returns its output":
    var mem = newMemory()
    let sid = mem.newSession()
    let res = runBangCommand(makeReg(), mem, sid, "SYS", "!echo hello")
    check not res.isError
    # The shell tool frames output as "exit: 0\nstdout:\n<output>" — the
    # same shape the agent sees from its own shell tool calls.
    check res.display.contains("hello")
    check res.sessionId == sid

  test "output is stored as a [!cmd] system message in the session":
    var mem = newMemory()
    let sid = mem.newSession()
    discard runBangCommand(makeReg(), mem, sid, "SYS", "!echo stored-marker")
    let history = mem.getHistory(sid)
    check history.len == 1
    check history[0].role == crSystem
    check history[0].content.startsWith("[!echo stored-marker]")
    check history[0].content.contains("stored-marker")

  test "creates and seeds a session when none exists yet":
    var mem = newMemory()
    let res = runBangCommand(makeReg(), mem, "", "the system prompt", "!echo first")
    check res.sessionId.len > 0
    let history = mem.getHistory(res.sessionId)
    check history.len == 2
    check history[0].role == crSystem
    check history[0].content == "the system prompt"
    check history[1].content.startsWith("[!echo first]")

  test "a failing command reports an error":
    var mem = newMemory()
    let sid = mem.newSession()
    let res = runBangCommand(makeReg(), mem, sid, "SYS", "!ls /nonexistent-talos-test-dir")
    check res.isError
    check res.display.startsWith("ERROR:")

  test "a deny-listed command is refused and the refusal is stored":
    var mem = newMemory()
    let sid = mem.newSession()
    let res = runBangCommand(makeReg(), mem, sid, "SYS", "!rm -rf /")
    check res.isError
    let history = mem.getHistory(sid)
    check history.len == 1
    check history[0].content.contains("ERROR:")

  test "a bare bang is a no-op: nothing run, nothing stored":
    var mem = newMemory()
    let sid = mem.newSession()
    let res = runBangCommand(makeReg(), mem, sid, "SYS", "!")
    check res.display.len == 0
    check mem.getHistory(sid).len == 0

  test "missing shell tool degrades to an error instead of crashing":
    var mem = newMemory()
    let sid = mem.newSession()
    let res = runBangCommand(newToolRegistry(), mem, sid, "SYS", "!echo hi")
    check res.isError
    check res.display.contains("not available")

  test "stored bang output is findable via FTS search":
    var mem = newMemory()
    let sid = mem.newSession()
    discard runBangCommand(makeReg(), mem, sid, "SYS", "!echo xylophone-needle")
    let hits = mem.searchHistory("xylophone-needle")
    check hits.len >= 1
