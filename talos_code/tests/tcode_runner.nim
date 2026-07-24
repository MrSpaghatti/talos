## Tests for the code runner module.
## Covers CompileResult formatting, error parsing, and CodingHarnessConfig defaults.

import std/[unittest, strutils, json, monotimes, os, times]

import talos_code/code_runner
import talos_code/code_tool
import talos_code/compile
import talos_core/tool_registry

# ---------------------------------------------------------------------------
# CompileResult formatting
# ---------------------------------------------------------------------------

suite "formatCompileResult":

  test "success — no output":
    let res = CompileResult(success: true, exitCode: 0, stdout: "", stderr: "",
                             durationMs: 100, errors: @[])
    let formatted = formatCompileResult(res)
    check: "✓ BUILD SUCCEEDED" in formatted

  test "success — with output":
    let res = CompileResult(success: true, exitCode: 0, stdout: "Compiling...",
                             stderr: "", durationMs: 200, errors: @[])
    let formatted = formatCompileResult(res)
    check: "✓ BUILD SUCCEEDED" in formatted
    check: "Compiling..." in formatted

  test "failure — with errors":
    var errors = newSeq[CompileError]()
    errors.add CompileError(file: "src/foo.nim", line: 10, column: 5,
                            severity: "error", message: "undeclared identifier: bar")
    let res = CompileResult(success: false, exitCode: 1,
                             stdout: "Compiling foo.nim...", stderr: "Error",
                             durationMs: 300, errors: errors)
    let formatted = formatCompileResult(res)
    check: "✗ BUILD FAILED" in formatted
    check: "src/foo.nim(10,5)" in formatted
    check: "undeclared identifier: bar" in formatted

  test "timeout — timed out flag set":
    let res = CompileResult(success: false, exitCode: -1,
                             stdout: "", stderr: "timed out",
                             durationMs: 5000, errors: @[], timedOut: true)
    let formatted = formatCompileResult(res)
    check: "✗ TIMEOUT" in formatted

  test "truncated output on a failed build":
    let veryLong = "x".repeat(500)
    let res = CompileResult(success: false, exitCode: 1, stdout: veryLong,
                             stderr: veryLong, durationMs: 100,
                             errors: @[], truncated: true)
    let formatted = formatCompileResult(res)
    check: "✗ BUILD FAILED (output truncated)" in formatted

  test "successful build with truncated output is still a success":
    # Regression guard: success and truncated are independent flags set by
    # runCompile; the old priority chain reported this as "✗ TRUNCATED".
    let res = CompileResult(success: true, exitCode: 0, stdout: "lots",
                             stderr: "", durationMs: 100,
                             errors: @[], truncated: true)
    let formatted = formatCompileResult(res)
    check: "✓ BUILD SUCCEEDED (output truncated)" in formatted
    check: "✗" notin formatted

# ---------------------------------------------------------------------------
# Error parsing
# ---------------------------------------------------------------------------

suite "parseNimErrors":

  test "basic error":
    let raw = "src/foo.nim(10, 5) Error: undeclared identifier: bar"
    let errors = parseNimErrors(raw, "src/foo.nim")
    check: errors.len == 1
    check: errors[0].file == "src/foo.nim"
    check: errors[0].line == 10
    check: errors[0].column == 5
    check: errors[0].severity == "error"
    check: "undeclared identifier" in errors[0].message

  test "error without column":
    let raw = "src/bar.nim(20) Error: type mismatch"
    let errors = parseNimErrors(raw, "src/bar.nim")
    check: errors.len == 1
    check: errors[0].line == 20
    check: errors[0].column == 0
    check: errors[0].severity == "error"

  test "multiple errors":
    let raw = "src/a.nim(1, 1) Error: first error" & "\n" &
              "src/b.nim(2, 2) Warning: second warning"
    let errors = parseNimErrors(raw, "")
    check: errors.len == 2
    check: errors[0].severity == "error"
    check: errors[1].severity == "warning"

  test "empty input":
    check: parseNimErrors("", "").len == 0
    check: parseNimErrors("no errors here", "").len == 0

  test "skips lines without file(path) pattern":
    let raw = "some unrelated output\nsrc/file.nim(5, 3) Error: real error"
    let errors = parseNimErrors(raw, "src/file.nim")
    check: errors.len == 1
    check: errors[0].line == 5

suite "parseNimCompilerOutput":

  test "parses a real diagnostic line":
    let raw = "/path/file.nim(10, 5) Error: undeclared identifier: bar"
    let errors = parseNimCompilerOutput(raw)
    check: errors.len == 1
    check: errors[0].file == "/path/file.nim"
    check: errors[0].line == 10
    check: errors[0].column == 5

  test "non-numeric parenthesis lines do not raise and are skipped":
    # "assert(x == y)" / "func(argname)" match the file(...) shape but are not
    # diagnostics. Previously the unguarded parseInt raised a ValueError.
    let raw = "myfunc(argname) returned 3\n" &
              "assert(x == y)\n" &
              "/path/real.nim(7, 2) Error: boom"
    var errors: seq[CompileError]
    # Must not raise.
    errors = parseNimCompilerOutput(raw)
    check: errors.len == 1
    check: errors[0].file == "/path/real.nim"
    check: errors[0].line == 7
    check: errors[0].column == 2

  test "diagnostic with non-numeric column is skipped, not fatal":
    let raw = "/path/file.nim(10, oops) Error: weird"
    check: parseNimCompilerOutput(raw).len == 0

# ---------------------------------------------------------------------------
# CodingHarnessConfig defaults
# ---------------------------------------------------------------------------

suite "defaultCodingHarnessConfig":

  test "no build/test command configured by default":
    # The rest of defaultCodingHarnessConfig()'s literal values (timeouts,
    # allowedExtensions, etc.) aren't worth pinning here — they'd just
    # mirror the constant back at itself. This one has real behavioral
    # weight: compileTool/testTool below key their "not configured" error
    # off buildCmd/testCmd being empty by default.
    let cfg = defaultCodingHarnessConfig()
    check: cfg.buildCmd == ""
    check: cfg.testCmd == ""

# ---------------------------------------------------------------------------
# compileTool / testTool — the actual agent-facing Tool wrappers around
# runCompile. Previously untested: runCompile itself was covered above, but
# nothing proved these Tools are wired to call it and format its result.
# ---------------------------------------------------------------------------

suite "compileTool and testTool":

  test "compileTool runs the configured build command and reports success":
    var cfg = defaultCodingHarnessConfig()
    cfg.buildCmd = "echo build ok"
    let res = compileTool(cfg).execute(%*{})
    check: not res.isError
    check: "build ok" in res.output

  test "compileTool reports failure when the build command exits non-zero":
    var cfg = defaultCodingHarnessConfig()
    cfg.buildCmd = "sh -c 'echo broke; exit 1'"
    let res = compileTool(cfg).execute(%*{})
    check: res.isError
    check: "broke" in res.output

  test "compileTool with no build command configured returns a clear error":
    let cfg = defaultCodingHarnessConfig()  # buildCmd is "" by default
    let res = compileTool(cfg).execute(%*{})
    check: res.isError
    check: "no build command configured" in res.output

  test "testTool runs the configured test command and reports success":
    var cfg = defaultCodingHarnessConfig()
    cfg.testCmd = "echo tests passed"
    let res = testTool(cfg).execute(%*{})
    check: not res.isError
    check: "tests passed" in res.output

  test "testTool reports failure when the test command exits non-zero":
    var cfg = defaultCodingHarnessConfig()
    cfg.testCmd = "sh -c 'exit 1'"
    let res = testTool(cfg).execute(%*{})
    check: res.isError

  test "testTool with no test command configured returns a clear error":
    let cfg = defaultCodingHarnessConfig()
    let res = testTool(cfg).execute(%*{})
    check: res.isError
    check: "no test command configured" in res.output

# ---------------------------------------------------------------------------
# File tool sandbox enforcement
# ---------------------------------------------------------------------------

suite "code_tool sandbox enforcement":

  setup:
    let sandbox = getTempDir() / "talos_code_sandbox_test"
    createDir(sandbox)
    var cfg = defaultCodingHarnessConfig()
    cfg.sandboxRoot = sandbox

  teardown:
    removeDir(sandbox)

  test "read within sandbox succeeds":
    let p = sandbox / "hello.nim"
    writeFile(p, "echo 1")
    let t = readFileTool(cfg)
    let res = t.execute(%*{"path": p})
    check: not res.isError
    check: res.output == "echo 1"

  test "read of absolute path outside sandbox is denied":
    let t = readFileTool(cfg)
    let res = t.execute(%*{"path": "/etc/passwd"})
    check: res.isError
    check: "outside the sandbox" in res.output

  test "read escaping via .. is denied":
    let t = readFileTool(cfg)
    let res = t.execute(%*{"path": sandbox / ".." / "escape.nim"})
    check: res.isError
    check: "outside the sandbox" in res.output

  test "write outside sandbox is denied and creates nothing":
    let target = getTempDir() / "talos_code_outside_target.nim"
    removeFile(target)
    let t = writeFileTool(cfg)
    let res = t.execute(%*{"path": target, "content": "malicious"})
    check: res.isError
    check: "outside the sandbox" in res.output
    check: not fileExists(target)

  test "write within sandbox succeeds":
    let p = sandbox / "out.nim"
    let t = writeFileTool(cfg)
    let res = t.execute(%*{"path": p, "content": "written"})
    check: not res.isError
    check: readFile(p) == "written"

  test "sibling directory sharing the sandbox prefix cannot escape":
    let sibling = sandbox & "-evil"
    createDir(sibling)
    defer: removeDir(sibling)
    let t = readFileTool(cfg)
    let res = t.execute(%*{"path": sibling / "secret.nim"})
    check: res.isError
    check: "outside the sandbox" in res.output

# ---------------------------------------------------------------------------
# runCompile execution
# ---------------------------------------------------------------------------

suite "runCompile execution":

  test "multi-word command actually launches and captures output":
    # Regression: without poEvalCommand, startProcess treated the whole
    # string as one executable name and every real build command failed.
    let res = runCompile("echo hello from compile", 10_000)
    check: res.success
    check: res.exitCode == 0
    check: "hello from compile" in res.stdout

  test "non-zero exit is reported as failure":
    let res = runCompile("sh -c 'echo boom; exit 2'", 10_000)
    check: not res.success
    check: res.exitCode == 2
    check: "boom" in res.stdout

  test "timeout actually kills and returns promptly":
    # Regression guard: asserts wall-clock time, not just the timedOut flag.
    # The setpgid-after-spawn version reported timedOut=true but never
    # delivered a signal, so this call took the full 5s.
    let t0 = getMonoTime()
    let res = runCompile("sleep 5", timeoutMs = 200)
    let elapsedMs = (getMonoTime() - t0).inMilliseconds
    check: res.timedOut
    check: not res.success
    check: elapsedMs < 2_000

  test "timeout kills the whole process tree, not just the shell":
    # A grandchild (the compiled-and-run binary in a real "nim c -r" build)
    # must not survive the kill and keep running after TIMEOUT is reported.
    let marker = getTempDir() / "talos_compile_tree_kill_" & $getMonoTime().ticks
    defer: removeFile(marker)
    let res = runCompile("sh -c 'sleep 2; touch " & marker & "'", timeoutMs = 200)
    check: res.timedOut
    sleep(2_300)
    check: not fileExists(marker)

  test "large output does not deadlock and is captured up to the cap":
    # More than one pipe buffer; before the incremental drain this hung
    # until the timeout and lost the output.
    let res = runCompile("seq 1 200000", 15_000, maxOutputBytes = 64 * 1024)
    check: not res.timedOut
    check: res.success
    check: res.stdout.startsWith("1\n")
    check: "[output truncated]" in res.stdout