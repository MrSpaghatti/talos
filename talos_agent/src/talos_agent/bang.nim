## Bang commands (task-10): `!<cmd>` runs a shell command directly.
##
## A line starting with `!` in the chat REPL or TUI is executed through
## the registered shell tool (inheriting its deny-list and timeout) and
## the output is (a) shown to the user and (b) appended to the current
## session as a crSystem message prefixed `[!<cmd>]`, so the agent sees
## what the user ran on its next turn — same idea as `!pwd`/`!ls` in
## Claude Code and similar harnesses: hand the agent context without a
## tool-call round-trip.
##
## Deliberately distinct from Discord's `!status`/`!config`/... prefix
## commands (bot management, discord/commands.nim) and from `/` slash
## commands (client-side UI, never shell).

import std/[json, strutils]
import talos_core/llm_client
import talos_core/memory
import talos_core/tool_registry

type
  BangResult* = object
    display*: string     ## text to show the user ("" for a bare `!`)
    isError*: bool
    sessionId*: string   ## session the output was stored in; equals the
                         ## input sessionId unless one had to be created

proc isBangCommand*(line: string): bool =
  ## True for lines the bang interceptor should consume. `!` followed by
  ## nothing is still consumed (as a no-op) so a stray `!` never reaches
  ## the LLM as a message.
  line.startsWith("!")

proc runBangCommand*(
    reg: ToolRegistry;
    mem: Memory;
    sessionId: string;
    systemPrompt: string;
    line: string;
): BangResult =
  ## Executes `line` (which must start with `!`) via the shell tool and
  ## persists the output as a `[!<cmd>]`-prefixed crSystem message.
  ##
  ## If no session exists yet (first input of a fresh chat is a bang
  ## command), one is created and seeded with `systemPrompt` first — the
  ## agent loop only seeds the system prompt into *empty* sessions, so
  ## storing the bang output without it would leave the session
  ## permanently promptless.
  result.sessionId = sessionId
  let cmd = line[1..^1].strip()
  if cmd.len == 0:
    return    # bare "!": consume silently, nothing to run or store

  var res: ToolResult
  if reg.isNil or not reg.has("shell"):
    res = ToolResult(output: "shell tool is not available", isError: true, exitCode: -1)
  else:
    try:
      res = reg.execute("shell", %*{"cmd": cmd})
    except CatchableError as e:
      res = ToolResult(output: e.msg, isError: true, exitCode: -1)

  result.isError = res.isError
  result.display =
    if res.isError: "ERROR: " & res.output
    else: res.output

  if result.sessionId.len == 0:
    result.sessionId = mem.newSession()
    if systemPrompt.len > 0:
      mem.appendMessage(result.sessionId,
        ChatMessage(role: crSystem, content: systemPrompt))
  mem.appendMessage(result.sessionId, ChatMessage(
    role: crSystem,
    content: "[!" & cmd & "]\n" & result.display,
  ))
