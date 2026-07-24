## Talos shell tool.
##
## Executes shell commands on behalf of the agent with two safety guards:
##   1. A configurable deny-list of patterns matched against the command
##      string (case-insensitive). Matching commands are refused without
##      ever being passed to the OS.
##   2. A timeout. The command is started via `osproc.startProcess` and
##      polled; if it has not exited by the deadline we kill the process
##      tree and return a timeout error.
##
## The tool is designed to be registered against a `ToolRegistry` from
## `talos_core/tool_registry`:

##   import talos_core/tool_registry
##   import tools/shell
##   let reg = newToolRegistry()
##   reg.register(shellTool())
##
## The tool's JSON-schema parameters are:
##   {"type": "object",
##    "properties": {
##      "cmd": {"type": "string"},
##      "timeoutMs": {"type": "integer"}
##    },
##    "required": ["cmd"]}
##
## Out of scope (deferred):
##   - cwd / env overrides (Phase 2)
##   - stdin support
##   - output streaming / size caps (we currently return everything)

import std/[json, osproc, streams, strutils, times, os, monotimes]
when defined(posix):
  import std/posix

import talos_core/tool_registry
import talos_core/posix_io

const
  DefaultShellTimeoutMs* = 30_000
  ## Default per-call timeout for the shell tool (30s).

  MaxShellTimeoutMs* = 5 * 60_000
  ## Hard upper bound on a single shell call (5min).

  ## Patterns that cause an immediate refusal. Matched case-insensitively
  ## against the *normalized* command string (collapsed whitespace). This
  ## is intentionally a narrow, conservative deny-list — it is not a full
  ## sandbox and the agent should still operate inside an isolated env.
  DefaultDenyPatterns* = @[
    "rm -rf /",
    "rm -rf /*",
    "rm -rf ~",
    "rm -rf $home",
    ":(){ :|:& };:",     # classic fork bomb
    ":(){:|:&};:",        # whitespace-collapsed variant
    "mkfs",
    "mkfs.",
    "dd if=/dev/zero of=/dev/",
    "dd if=/dev/random of=/dev/",
    "dd if=/dev/urandom of=/dev/",
    "> /dev/sda",
    "of=/dev/sda",
    "of=/dev/nvme",
    "shutdown",
    "reboot",
    "halt",
    "poweroff",
    "init 0",
    "init 6",
    "chmod -r 777 /",
    "chown -r ",
    "fdisk",
    "wipefs",
  ]

type
  ShellOptions* = object
    ## Static configuration for the shell tool.
    timeoutMs*: int
    maxOutputBytes*: int            ## 0 = unlimited.
    denyPatterns*: seq[string]
    shellPath*: string              ## defaults to /bin/sh
    workingDir*: string             ## "" = inherit caller cwd

  ShellExecution* = object
    ## Detailed result of a shell invocation, returned alongside ToolResult
    ## via `runShell`.
    stdout*: string
    stderr*: string
    exitCode*: int
    timedOut*: bool
    denied*: bool
    durationMs*: int

const
  DefaultMaxOutputBytes* = 256 * 1024
  ## Hard cap on captured stdout+stderr per invocation (256 KiB).

proc defaultShellOptions*(): ShellOptions =
  ShellOptions(
    timeoutMs: DefaultShellTimeoutMs,
    maxOutputBytes: DefaultMaxOutputBytes,
    denyPatterns: DefaultDenyPatterns,
    shellPath: "/bin/sh",
    workingDir: "",
  )

# ---------------------------------------------------------------------------
# Deny-list logic
# ---------------------------------------------------------------------------

proc normalizeForDeny(cmd: string): string =
  ## Lowercases and collapses runs of whitespace to a single space so that
  ## simple obfuscation (extra spaces, mixed case) does not bypass the
  ## deny-list.
  result = newStringOfCap(cmd.len)
  var prevSpace = false
  for ch in cmd:
    if ch in {' ', '\t', '\n', '\r'}:
      if not prevSpace:
        result.add(' ')
        prevSpace = true
    else:
      result.add(ch.toLowerAscii)
      prevSpace = false
  result = result.strip()

proc isDenied*(cmd: string; patterns: seq[string]): bool =
  ## Returns true if `cmd` matches any deny-list pattern. Patterns are
  ## matched case-insensitively as substrings of the normalized command.
  let normalized = normalizeForDeny(cmd)
  for raw in patterns:
    let pat = raw.toLowerAscii.strip()
    if pat.len == 0:
      continue
    if normalized.contains(pat):
      return true
  return false

# ---------------------------------------------------------------------------
# Process execution with timeout
# ---------------------------------------------------------------------------

proc finalizeCapture(buf: string; total, cap: int): string =
  ## `buf` already holds at most `cap` captured bytes; `total` is the number
  ## of bytes actually produced. Appends a truncation notice if we dropped any.
  if cap <= 0 or total <= cap:
    return buf
  result = buf
  result.add("\n... [truncated " & $(total - cap) & " bytes]")

proc readAllAvailable(stream: Stream): string =
  ## Reads everything currently buffered on the stream. Returns "" on error.
  result = ""
  if stream.isNil:
    return
  try:
    result = stream.readAll()
  except CatchableError:
    discard

proc runShellRaw(cmd: string; opts: ShellOptions): ShellExecution =
  ## Runs `cmd` via the configured shell with a timeout. Captures stdout
  ## and stderr separately. Does not consult the deny-list — see `runShell`.
  let startMono = getMonoTime()
  var process: Process
  try:
    var args = @["-c", cmd]
    var procOpts: set[ProcessOption] = {poUsePath}
    process = startProcess(
      command = opts.shellPath,
      workingDir = opts.workingDir,
      args = args,
      options = procOpts,
    )
  except OSError as e:
    return ShellExecution(
      stdout: "",
      stderr: "failed to start process: " & e.msg,
      exitCode: -1,
      timedOut: false,
      denied: false,
      durationMs: int((getMonoTime() - startMono).inMilliseconds),
    )
  except CatchableError as e:
    return ShellExecution(
      stdout: "",
      stderr: "failed to start process: " & e.msg,
      exitCode: -1,
      timedOut: false,
      denied: false,
      durationMs: int((getMonoTime() - startMono).inMilliseconds),
    )

  let timeoutMs = if opts.timeoutMs <= 0: DefaultShellTimeoutMs
                  else: min(opts.timeoutMs, MaxShellTimeoutMs)
  let deadline = startMono + initDuration(milliseconds = timeoutMs)
  let cap = opts.maxOutputBytes
  var timedOut = false
  var outBuf, errBuf = ""
  var outTotal, errTotal = 0

  when defined(posix):
    # Drain stdout/stderr incrementally so a command that produces more than
    # one pipe buffer (~64 KiB) of output does not deadlock: without this the
    # child blocks writing to a full pipe, never exits, and is falsely killed
    # as a timeout with its output lost.
    setNonBlocking(process.outputHandle)
    setNonBlocking(process.errorHandle)
    # Best-effort: put the child in its own process group so a timeout can
    # signal the whole tree (e.g. a command that itself forks children)
    # instead of just this one pid — matches compile.nim's runCompile,
    # which had the identical gap. Narrow race if the child spawns its own
    # children before this lands, but covers the common case.
    discard setpgid(Pid(process.processID), Pid(0))
    var outEof, errEof = false
    var pollIntervalMs = 25
    while true:
      if not outEof: outEof = drainAvailable(process.outputHandle, outBuf, outTotal, cap)
      if not errEof: errEof = drainAvailable(process.errorHandle, errBuf, errTotal, cap)
      if process.peekExitCode() != -1:
        break
      if getMonoTime() >= deadline:
        timedOut = true
        # Signal the whole process group. SIGTERM first (graceful) — the
        # previous SIGKILL-then-SIGTERM order made the grace period
        # pointless, since SIGKILL can't be caught.
        let pgid = Pid(-int(process.processID))
        discard kill(pgid, SIGTERM)
        var graceLeft = 500
        while graceLeft > 0 and process.peekExitCode() == -1:
          if not outEof: outEof = drainAvailable(process.outputHandle, outBuf, outTotal, cap)
          if not errEof: errEof = drainAvailable(process.errorHandle, errBuf, errTotal, cap)
          sleep(25)
          graceLeft -= 25
        if process.peekExitCode() == -1:
          discard kill(pgid, SIGKILL)
        break
      sleep(pollIntervalMs)
      if pollIntervalMs < 100:
        pollIntervalMs += 5
    # Final drain now that the write end is closed, to collect the tail.
    var guard = 0
    while (not outEof or not errEof) and guard < 100_000:
      if not outEof: outEof = drainAvailable(process.outputHandle, outBuf, outTotal, cap)
      if not errEof: errEof = drainAvailable(process.errorHandle, errBuf, errTotal, cap)
      inc guard
  else:
    # Non-POSIX fallback: poll for exit, then read once. Subject to the
    # pipe-buffer limitation above, but Talos targets POSIX.
    var pollIntervalMs = 25
    while true:
      if process.peekExitCode() != -1:
        break
      if getMonoTime() >= deadline:
        timedOut = true
        # SIGTERM first (graceful), SIGKILL only if still alive after the
        # grace period — matches compile.nim's non-POSIX fallback.
        try: process.terminate() except CatchableError: discard
        var graceLeft = 500
        while graceLeft > 0 and process.peekExitCode() == -1:
          sleep(25)
          graceLeft -= 25
        if process.peekExitCode() == -1:
          try: process.kill() except CatchableError: discard
        break
      sleep(pollIntervalMs)
      if pollIntervalMs < 100:
        pollIntervalMs += 5
    let outRaw = readAllAvailable(process.outputStream)
    let errRaw = readAllAvailable(process.errorStream)
    outTotal = outRaw.len
    errTotal = errRaw.len
    outBuf = if cap > 0 and outRaw.len > cap: outRaw[0 ..< cap] else: outRaw
    errBuf = if cap > 0 and errRaw.len > cap: errRaw[0 ..< cap] else: errRaw

  var exitCode = 0
  try:
    exitCode = process.waitForExit()
  except CatchableError:
    exitCode = -1

  try: process.close() except CatchableError: discard

  result = ShellExecution(
    stdout: finalizeCapture(outBuf, outTotal, cap),
    stderr: finalizeCapture(errBuf, errTotal, cap),
    exitCode: exitCode,
    timedOut: timedOut,
    denied: false,
    durationMs: int((getMonoTime() - startMono).inMilliseconds),
  )
  if timedOut:
    result.stderr.add("\n... [killed: timeout after " & $timeoutMs & "ms]")

proc runShell*(cmd: string; opts: ShellOptions): ShellExecution =
  ## Public entry point: enforces the deny-list, then runs the command.
  if cmd.strip().len == 0:
    return ShellExecution(
      stdout: "",
      stderr: "empty command",
      exitCode: -1,
      timedOut: false,
      denied: true,
      durationMs: 0,
    )
  if isDenied(cmd, opts.denyPatterns):
    return ShellExecution(
      stdout: "",
      stderr: "command refused by deny-list",
      exitCode: -1,
      timedOut: false,
      denied: true,
      durationMs: 0,
    )
  runShellRaw(cmd, opts)

# ---------------------------------------------------------------------------
# Tool integration
# ---------------------------------------------------------------------------

proc shellParametersSchema*(): JsonNode =
  ## JSON schema for the shell tool's arguments.
  let cmdProp = %*{
    "type": "string",
    "description": "Shell command to execute via /bin/sh -c.",
  }
  let timeoutProp = %*{
    "type": "integer",
    "description": "Optional per-call timeout in milliseconds " &
                   "(default 30000, max 300000).",
    "minimum": 1,
  }
  result = newJObject()
  result["type"] = %"object"
  result["properties"] = newJObject()
  result["properties"]["cmd"] = cmdProp
  result["properties"]["timeoutMs"] = timeoutProp
  result["required"] = %[%"cmd"]
  result["additionalProperties"] = %false

proc formatShellOutput(exec: ShellExecution): string =
  ## Formats a `ShellExecution` into the textual output an LLM will see.
  result = ""
  if exec.denied:
    result.add("DENIED: ")
    if exec.stderr.len > 0:
      result.add(exec.stderr)
    else:
      result.add("command refused")
    return
  result.add("exit: " & $exec.exitCode)
  if exec.timedOut:
    result.add(" (timed out)")
  result.add("\n")
  if exec.stdout.len > 0:
    result.add("stdout:\n")
    result.add(exec.stdout)
    if not exec.stdout.endsWith("\n"):
      result.add("\n")
  if exec.stderr.len > 0:
    result.add("stderr:\n")
    result.add(exec.stderr)
    if not exec.stderr.endsWith("\n"):
      result.add("\n")

proc makeShellExecuteProc(opts: ShellOptions): ToolExecuteProc =
  ## Returns a closure suitable for `Tool.execute` that captures `opts`.
  let captured = opts
  result = proc (args: JsonNode): ToolResult {.gcsafe, raises: [].} =
    var localOpts = captured
    if args.isNil or args.kind != JObject:
      return ToolResult(
        output: "shell: arguments must be a JSON object with 'cmd'",
        isError: true,
        exitCode: -1,
      )
    let cmdNode = args{"cmd"}
    if cmdNode.isNil or cmdNode.kind != JString:
      return ToolResult(
        output: "shell: missing required string field 'cmd'",
        isError: true,
        exitCode: -1,
      )
    let cmd = cmdNode.getStr()
    let tNode = args{"timeoutMs"}
    if not tNode.isNil and tNode.kind == JInt:
      let t = tNode.getInt()
      if t > 0:
        localOpts.timeoutMs = min(t, MaxShellTimeoutMs)

    var exec: ShellExecution
    try:
      exec = runShell(cmd, localOpts)
    except CatchableError as e:
      return ToolResult(
        output: "shell: internal error: " & e.msg,
        isError: true,
        exitCode: -1,
      )
    except Defect as e:
      return ToolResult(
        output: "shell: defect: " & e.msg,
        isError: true,
        exitCode: -1,
      )
    let isError = exec.denied or exec.timedOut or exec.exitCode != 0
    return ToolResult(
      output: formatShellOutput(exec),
      isError: isError,
      exitCode: exec.exitCode,
    )

proc shellTool*(opts: ShellOptions = defaultShellOptions()): Tool =
  ## Builds a `Tool` value for the shell tool. Register it with a
  ## `ToolRegistry` to expose it to the LLM.
  newTool(
    name = "shell",
    description = "Execute a shell command via /bin/sh -c. Returns stdout, " &
                  "stderr, and exit code. Subject to a deny-list and a " &
                  "per-call timeout.",
    parameters = shellParametersSchema(),
    execute = makeShellExecuteProc(opts),
  )
