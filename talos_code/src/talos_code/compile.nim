## Sandboxed compilation runner.
##
## Provides `runCompile` which executes an arbitrary shell command
## (typically a compiler invocation) with a hard timeout, captures
## output, parses structured errors, and returns a `CompileResult`.
##
## The key safety property: this proc does NOT make its own security
## decisions. It delegates entirely to the shell tool's deny-list and
## to the sandbox root guard set by the caller. Callers MUST:
##   1. Validate the command is within `sandboxRoot` before calling.
##   2. Use the shell tool's deny-list for command-level safety.

import std/[osproc, times, monotimes, os, strutils]
when defined(posix):
  import std/posix
else:
  import std/streams

import code_runner
import talos_core/posix_io

const DefaultCompileTimeoutMs = 120_000

when defined(linux):
  proc collectDescendants(rootPid: Pid): seq[Pid] =
    ## Recursively walks /proc/<pid>/task/<pid>/children (Linux 3.5+) to find
    ## every transitive descendant of `rootPid`. Process-group-independent —
    ## unlike the pgid-based kill below, this still finds the whole tree even
    ## when the child was never made its own process group leader. Nim's
    ## stdlib only uses posix_spawn (and therefore honors poDaemon) on Linux
    ## when NOT built with -d:useClone under Nim 2.2+; on the 2.0.x series it
    ## unconditionally falls back to a bare fork()+exec() on Linux that never
    ## sets up a process group at all, silently breaking the pgid kill below.
    result = @[]
    var frontier = @[rootPid]
    while frontier.len > 0:
      var next: seq[Pid] = @[]
      for pid in frontier:
        try:
          let raw = readFile("/proc/" & $pid & "/task/" & $pid & "/children").strip()
          if raw.len > 0:
            for tok in raw.splitWhitespace():
              try:
                let child = Pid(parseInt(tok))
                result.add(child)
                next.add(child)
              except ValueError:
                discard
        except IOError, OSError:
          discard  # process already exited, or /proc entry unreadable
      frontier = next

proc runCompile*(
    cmd: string;
    timeoutMs: int = DefaultCompileTimeoutMs;
    maxOutputBytes: int = DefaultMaxOutputBytes;
): CompileResult =
  ## Runs `cmd` as a subprocess with a hard `timeoutMs` deadline.
  ##
  ## Returns a `CompileResult` with `success`, `exitCode`, `stdout`,
  ## `stderr`, `durationMs`, and parsed `errors`.
  ##
  ## If the process times out it is killed (SIGKILL) and `success` is
  ## false. Partial output up to `maxOutputBytes` is returned.
  let startMono = getMonoTime()

  var p: Process
  try:
    p = startProcess(
      cmd,
      workingDir = "",
      env = nil,
      # poEvalCommand: `cmd` is a full shell command line (e.g.
      # "nim c -r src/main.nim"), so it must be evaluated by the shell.
      # Without it, startProcess treats the entire string as one executable
      # name and every multi-word build/test command fails to launch.
      # poDaemon (POSIX): child becomes a process-group leader atomically at
      # spawn (POSIX_SPAWN_SETPGROUP), so a timeout can signal the whole tree
      # — e.g. the compiled-and-run binary a "nim c -r ..." command spawns as
      # a grandchild. A post-hoc setpgid() cannot do this: under posix_spawn
      # the child has already exec'd by the time startProcess returns, so
      # setpgid fails with EACCES and the group kill silently signals nothing.
      options = {poUsePath, poStdErrToStdOut, poEvalCommand, poDaemon},
    )
  except CatchableError:
    return CompileResult(
      success: false,
      exitCode: -1,
      stdout: "",
      stderr: "failed to start process: " & getCurrentExceptionMsg(),
      durationMs: 0,
      errors: @[],
    )

  var timedOut = false
  let deadline = startMono + initDuration(milliseconds = timeoutMs)
  var pollIntervalMs = 25

  # Merged stdout+stderr (poStdErrToStdOut) must be drained while the child
  # runs; reading only after it exits deadlocks once the output exceeds one
  # pipe buffer (~64 KiB) — routine for a verbose compile or test run.
  var outBuf = ""
  var outTotal = 0

  when defined(posix):
    setNonBlocking(p.outputHandle)
    var eof = false
    while true:
      if not eof: eof = drainAvailable(p.outputHandle, outBuf, outTotal, maxOutputBytes)
      if p.peekExitCode() != -1:
        break
      if getMonoTime() >= deadline:
        timedOut = true
        # Signal the whole process group (negative pid), not just the
        # shell. SIGTERM first (graceful) — sending SIGKILL immediately
        # and only falling back to SIGTERM makes the "grace period"
        # pointless, since SIGKILL can't be caught and a process still
        # alive after it is either a zombie or stuck in uninterruptible
        # I/O either way.
        # Fall back to the direct pid if the group signal fails (e.g. the
        # group is already gone) — never let both paths fail silently.
        let pgid = Pid(-int(p.processID))
        if kill(pgid, SIGTERM) != 0:
          discard kill(Pid(p.processID), SIGTERM)
        when defined(linux):
          # Belt-and-suspenders for the Nim 2.0.x/Linux gap noted above:
          # signal every descendant directly too, in case the pgid kill
          # hit an empty/wrong group.
          let descendants = collectDescendants(Pid(p.processID))
          for d in descendants:
            discard kill(d, SIGTERM)
        var grace = 500
        while grace > 0 and p.peekExitCode() == -1:
          if not eof: eof = drainAvailable(p.outputHandle, outBuf, outTotal, maxOutputBytes)
          sleep(25)
          grace -= 25
        if p.peekExitCode() == -1:
          if kill(pgid, SIGKILL) != 0:
            discard kill(Pid(p.processID), SIGKILL)
          when defined(linux):
            for d in descendants:
              discard kill(d, SIGKILL)
        break
      sleep(pollIntervalMs)
      if pollIntervalMs < 100:
        pollIntervalMs += 5
    var guard = 0
    while not eof and guard < 100_000:
      eof = drainAvailable(p.outputHandle, outBuf, outTotal, maxOutputBytes)
      inc guard
  else:
    while true:
      let rc = p.peekExitCode()
      if rc != -1:
        break
      if getMonoTime() >= deadline:
        timedOut = true
        # SIGTERM first (graceful), SIGKILL only if it's still alive after
        # the grace period — the reverse order made the grace period
        # pointless, since a process can't be un-SIGKILLed.
        try: p.terminate() except CatchableError: discard
        var grace = 500
        while grace > 0 and p.peekExitCode() == -1:
          sleep(25)
          grace -= 25
        if p.peekExitCode() == -1:
          try: p.kill() except CatchableError: discard
        break
      sleep(pollIntervalMs)
      if pollIntervalMs < 100:
        pollIntervalMs += 5
    let rawOutput = try: readAll(p.outputStream) except CatchableError: ""
    outTotal = rawOutput.len
    outBuf = if rawOutput.len > maxOutputBytes: rawOutput[0 ..< maxOutputBytes]
             else: rawOutput

  # Bounded wait: on the normal-exit path peekExitCode already reaped the
  # child so this returns immediately; on the timeout path the 2s ceiling
  # guarantees runCompile can never hang the caller even if the kill above
  # failed (waitForExit SIGKILLs the direct child when its timeout expires).
  var exitCode = -1
  try:
    exitCode = p.waitForExit(timeout = 2_000)
  except CatchableError:
    discard

  try: p.close() except CatchableError: discard

  let durationMs = int((getMonoTime() - startMono).inMilliseconds)

  # Clamp output to maxOutputBytes.
  let stdout = if outTotal > maxOutputBytes:
                 outBuf & "\n... [output truncated]"
               else:
                 outBuf

  let errors = if exitCode != 0:
                 parseNimCompilerOutput(stdout)
               else:
                 @[]

  result = CompileResult(
    success: not timedOut and exitCode == 0,
    exitCode: if timedOut: -1 else: exitCode,
    stdout: stdout,
    stderr: if timedOut: "command timed out after " & $timeoutMs & "ms" else: "",
    durationMs: durationMs,
    errors: errors,
    timedOut: timedOut,
    truncated: outTotal > maxOutputBytes,
  )