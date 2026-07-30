## NOTE: This project has been renamed from Mercury Agent to Talos Agent. All package names (mercury_core, mercury_agent, mercury_code) are now (talos_core, talos_agent, talos_code).

# Task 10: Bang Commands (`!<cmd>`)

**Status**: ✅ Done (2026-07-30) — shipped as `talos_agent/src/talos_agent/bang.nim`
(shared helper), wired into both the plain REPL (`commands.nim: runChatLoop`)
and the TUI (`tui/chat_tui.nim: runBangTurn`). Differences from the sketch
below: the helper lives in its own module (not inline in the chat loop)
because both surfaces need it; `AgentResult.sessionId` already existed, so
no extension was needed; and a bang command issued before any turn creates
the session itself, seeding the system prompt first (the agent loop only
seeds prompts into empty sessions). Tests: `tests/test_bang.nim` (10 checks).
**Dependencies**: Task 1 (Agent Loop) — intercepts user input and stores results in memory
**Complexity**: Small-Medium

---

## Target

- `mercury_agent/src/tools/shell.nim` (existing — reused, not modified)
- `mercury_agent/src/mercury_agent.nim` (modified — `runChatLoop` input interceptor)

## Current State

- The chat REPL (`runChatLoop`) sends all non-`:quit` input directly to the agent loop
- The shell tool (`tools/shell`) can execute arbitrary commands with deny-list safety guards and timeout
- Discord has `!config`, `!status`, `!admin`, `!session` as hardcoded prefix commands in `discord_commands.nim` — but these are bot-management commands, not general shell execution
- Slash commands (task 9) are `/<cmd>` — client-side, display output in transcript, never hit the LLM
- Memory stores messages with roles: `crSystem`, `crUser`, `crAssistant`, `crTool`

## Design

A line starting with `!` is a **bang command**: the rest of the line is executed as a shell command via the existing `shellTool()`, and the output is both displayed to the user and stored as a `crSystem`-role message in the conversation history so the agent can see it too.

This is the same idea as `!pwd` / `!ls` / `!cat` in Claude Code, Codex, and similar agent harnesses — the user manually runs a command mid-conversation to give the agent context without waiting for a tool-call round-trip.

### Key behavior

```
> !pwd
[!] /home/user/project
>
```

After `!pwd` runs:
- The output `"/home/user/project"` appears in the terminal
- A `ChatMessage(role: crSystem, content: "[!pwd]\n/home/user/project")` is appended to the current session's message history
- On the next turn, the agent sees this system message in its context — it knows the user just ran `pwd` and saw the result

### Safety

Bang commands reuse the existing `ShellOptions.denyPatterns` from `tools/shell`. A bang command that matches a deny pattern is refused with an error message stored as a system note. No new safety mechanism needed.

### Implementation

In `runChatLoop`, before the `runOneTurn` call, add a check:

```nim
proc handleBangCommand(line: string, reg: ToolRegistry, mem: var Memory, sessionId: string): bool =
  ## Returns true if the line was consumed (don't send to LLM).
  if not line.startsWith("!"):
    return false
  let cmd = line[1..^1].strip()
  if cmd.len == 0:
    return true  # bare "!" — nothing to run, just consume
  let shell = reg.get("shell")
  var result: ToolResult
  try:
    result = shell.execute(%*{"cmd": cmd, "timeoutMs": 30_000})
  except CatchableError as e:
    result = ToolResult(output: "! " & e.msg, isError: true, exitCode: 1)
  let display = if result.isError: "ERROR: " & result.output else: result.output
  printSystemNote(display)
  # Store as a system message so the agent sees it on the next turn.
  if not mem.isNil:
    let msg = ChatMessage(
      role: crSystem,
      content: "[!" & cmd & "]\n" & result.output,
    )
    mem.appendMessage(sessionId, msg)
  return true
```

The interceptor slot in `runChatLoop`:

```nim
# Before: runOneTurn(cfg, llm, reg, mem, trimmed, streamCallback)
# After:
if handleBangCommand(trimmed, reg, mem, currentSessionId):
  continue
res = runOneTurn(cfg, llm, reg, mem, trimmed, streamCallback)
```

### Session ID tracking

`runChatLoop` currently calls `runOneTurn` which internally creates sessions via `runAgentLoop`. Bang commands need the current session ID to append their output. Two options:

1. **Extract session ID from `runAgentLoop`** — `runAgentLoop` returns an `AgentResult` which could be extended with `sessionId`. The chat loop tracks `lastSessionId`.
2. **Inline session management** — move session creation up into `runChatLoop`, pass the session ID into `runAgentLoop` via `resumeSessionId`.

Option 1 is simpler and non-breaking. We add `sessionId*: string` to `AgentResult`, set it in `runAgentLoop` whenever a session is created or resumed, and capture it in `runChatLoop`.

### Display

Command output is printed via `printSystemNote` (the existing `[system]` prefix helper), consistent with EOF/interrupt messages. The stored system message uses `[!<cmd>]` prefix so the agent can distinguish between user-run commands and its own tool calls. The LLM sees it in history like:

```
[system] [!pwd]
/home/user/project
```

## Files Created

None. This is a <50-line addition to existing files.

## Files Modified

| File | Change |
|------|--------|
| `mercury_agent/src/mercury_agent.nim` | Add `handleBangCommand` proc, wire into `runChatLoop`, extend `AgentResult` with `sessionId` |

## Acceptance

- `!pwd` in the chat REPL prints the current directory and does NOT hit the LLM
- `!echo hello` prints "hello"
- `!ls nonexistent` prints an error (shell returns non-zero exit code)
- A denied command (e.g. `!rm -rf /`) prints a refusal message without executing
- A bare `!` is a no-op (no shell spawned)
- After `!pwd`, the next `>` prompt sends the `[!pwd]` system message as context — the agent knows the user ran `pwd`
- `!` commands stored in memory appear in `/search` results (task 9)
- All existing 479 tests pass