## Talos coding harness configuration.
##
## Extends the base TalosConfig with coding-specific settings:
##   - Language-specific build/test commands
##   - Allowed file extensions for read/write
##   - Sandbox root (the directory the agent may touch)
##   - Compile result size caps

import std/[strutils]

# ---------------------------------------------------------------------------
# Compile error structures
# ---------------------------------------------------------------------------

type
  CompileError* = object
    ## A single parsed compiler error / warning / note.
    file*: string     ## Absolute path to the source file.
    line*: int        ## 1-based line number in `file`.
    column*: int      ## 1-based column (0 if unknown).
    severity*: string ## "error", "warning", "hint", "note".
    message*: string  ## Human-readable diagnostic text.

  CompileResult* = object
    ## The result of a `runCompile` call.
    success*: bool            ## True if the command exited 0.
    exitCode*: int            ## Raw exit code from the compiler.
    stdout*: string          ## Captured stdout (truncated).
    stderr*: string           ## Captured stderr (truncated).
    durationMs*: int          ## Wall-clock time in milliseconds.
    errors*: seq[CompileError]  ## Parsed error list (empty if parsing fails).
    timedOut*: bool           ## True if the command exceeded its deadline.
    truncated*: bool          ## True if stdout/stderr were clamped.

# ---------------------------------------------------------------------------
# Coding harness configuration
# ---------------------------------------------------------------------------

type
  CodingHarnessConfig* = object
    ## Per-project coding harness settings.
    sandboxRoot*: string
      ## The root directory the agent may read/write. Must be an absolute path.
      ## Compiles and tests run inside this tree.

    allowedExtensions*: seq[string]
      ## File extensions the harness may read or write.
      ## e.g. @[".nim", ".c", ".h", ".cfg", ".md"]

    buildCmd*: string
      ## Command to build the project. Run from `sandboxRoot`.
      ## e.g. "nim c -r --hints:off --warnings:off src/main.nim"

    buildTimeoutMs*: int
      ## Hard kill deadline for the build command (default 120s).

    testCmd*: string
      ## Command to run the project tests. Run from `sandboxRoot`.
      ## e.g. "nim c -r tests/test_all.nim"

    testTimeoutMs*: int
      ## Hard kill deadline for the test command (default 300s).

    maxOutputBytes*: int
      ## Cap on stdout/stderr returned per compile/test invocation.
      ## Defaults to 256 KB.

const
  DefaultBuildTimeoutMs* = 120_000   ## 2 minutes
  DefaultTestTimeoutMs*  = 300_000   ## 5 minutes
  DefaultMaxOutputBytes* = 512 * 1024 ## 512 KB

proc defaultCodingHarnessConfig*(): CodingHarnessConfig =
  CodingHarnessConfig(
    sandboxRoot: "",
    allowedExtensions: @[".nim", ".c", ".h", ".cfg", ".md", ".txt", ".json",
                         ".toml", ".yml", ".yaml"],
    buildCmd: "",
    buildTimeoutMs: DefaultBuildTimeoutMs,
    testCmd: "",
    testTimeoutMs: DefaultTestTimeoutMs,
    maxOutputBytes: DefaultMaxOutputBytes,
  )

# ---------------------------------------------------------------------------
# Compiler output parser
# ---------------------------------------------------------------------------

proc parseNimCompilerOutput*(raw: string): seq[CompileError] =
  ## Parses Nim's line-oriented compiler output into structured errors.
  ##
  ## Nim emits diagnostics in two formats:
  ##
  ##   /path/to/file.nim(line, col) [severity] message
  ##   /path/to/file.nim(line, col) severity: message
  ##
  ## Both are handled. Unknown lines are silently skipped.
  result = @[]
  for line in raw.splitLines:
    let stripped = line.strip()
    if stripped.len == 0:
      continue

    # Nim emits diagnostics in the form: /path/to/file.nim(line, col) [severity] message
    # Find the first '(' which marks the start of (line, col).
    let pathEnd = stripped.find('(')
    if pathEnd < 2:
      continue

    let file = stripped[0 ..< pathEnd]
    # Extract (line, col) parenthesis block.
    var parenEnd = -1
    for i in pathEnd ..< stripped.len:
      if stripped[i] == ')':
        parenEnd = i
        break
    if parenEnd < pathEnd + 2:
      continue

    let paren = stripped[pathEnd + 1 ..< parenEnd]
    let parts = paren.split(',')
    if parts.len < 1:
      continue

    # The "(...)" is only a real diagnostic location if it parses as numbers.
    # Ordinary text such as "assert(x == y)" or "func(argname)" also matches
    # the file(...) shape, so guard the conversion and skip non-diagnostics
    # instead of raising a ValueError.
    var lineNum, colNum: int
    try:
      lineNum = parseInt(parts[0].strip())
      colNum = if parts.len > 1: parseInt(parts[1].strip()) else: 0
    except ValueError:
      continue

    # Extract severity and message: either "[severity]" or "severity:" prefix.
    let after = stripped[parenEnd + 1 ..< stripped.len].strip()
    var severity = "error"
    var message = after

    if after.startsWith('['):
      # "[severity] message" or "[severity]"
      let close = after.find(']')
      if close > 1:
        severity = after[1 ..< close].toLowerAscii()
        message = after[close + 1 .. after.high].strip()
      else:
        message = after
    elif ':' in after:
      let colon = after.find(':')
      severity = after[0 ..< colon].toLowerAscii().strip()
      message = after[colon + 1 .. after.high].strip()
    else:
      message = after

    result.add CompileError(
      file: file,
      line: lineNum,
      column: colNum,
      severity: severity,
      message: message,
    )

# ---------------------------------------------------------------------------
# Error parsing (legacy API)
# ---------------------------------------------------------------------------

proc parseNimErrors*(raw: string; defaultFile: string): seq[CompileError] =
  ## Parses Nim compiler errors from raw output.
  ##
  ## Supports formats like:
  ##   file.nim(line, col) Error: message
  ##   file.nim(line) Error: message
  ##
  ## Lines without a file(path) pattern are skipped.
  ## `defaultFile` is used when no file can be extracted.
  result = @[]
  for line in raw.splitLines:
    let stripped = line.strip()
    if stripped.len == 0:
      continue

    # Look for file(path) pattern
    let pathEnd = stripped.find('(')
    if pathEnd < 1:
      continue

    var file = stripped[0 ..< pathEnd]
    if file.len == 0:
      file = defaultFile

    # Find closing paren
    var parenEnd = -1
    for i in pathEnd ..< stripped.len:
      if stripped[i] == ')':
        parenEnd = i
        break
    if parenEnd < 0:
      continue

    # Extract line and optional column
    let paren = stripped[pathEnd + 1 ..< parenEnd]
    let parts = paren.split(',')
    var lineNum = 0
    var colNum = 0
    try:
      lineNum = parseInt(parts[0].strip())
      if parts.len > 1:
        colNum = parseInt(parts[1].strip())
    except CatchableError:
      continue

    # Extract severity and message after the closing paren
    let after = stripped[parenEnd + 1 ..< stripped.len].strip()
    var severity = "error"
    var message = after

    if after.startsWith('['):
      let close = after.find(']')
      if close > 1:
        severity = after[1 ..< close].toLowerAscii()
        message = after[close + 1 .. after.high].strip()
    elif ':' in after:
      let colon = after.find(':')
      severity = after[0 ..< colon].toLowerAscii().strip()
      message = after[colon + 1 .. after.high].strip()
    else:
      message = after

    result.add CompileError(
      file: file,
      line: lineNum,
      column: colNum,
      severity: severity,
      message: message,
    )

# ---------------------------------------------------------------------------
# Compile result formatting
# ---------------------------------------------------------------------------

proc formatCompileResult*(res: CompileResult): string =
  ## Formats a CompileResult into a human-readable summary string.
  ##
  ## `success` and `truncated` are independent flags, not a priority
  ## chain: a build that exits 0 with output exceeding maxOutputBytes is
  ## both at once, and must read as a success with a truncation note —
  ## not as "✗ TRUNCATED". Only timedOut implies failure by itself.
  if res.timedOut:
    result = "✗ TIMEOUT\n"
  elif res.success:
    result = "✓ BUILD SUCCEEDED"
    if res.truncated:
      result.add " (output truncated)"
    result.add "\n"
  else:
    result = "✗ BUILD FAILED"
    if res.truncated:
      result.add " (output truncated)"
    result.add "\n"

  if res.stdout.len > 0:
    result.add res.stdout
    if not res.stdout.endsWith("\n"):
      result.add "\n"

  if res.stderr.len > 0:
    result.add res.stderr
    if not res.stderr.endsWith("\n"):
      result.add "\n"

  for err in res.errors:
    if err.column > 0:
      result.add err.file & "(" & $err.line & "," & $err.column & ") " &
             err.severity & ": " & err.message & "\n"
    else:
      result.add err.file & "(" & $err.line & ") " &
             err.severity & ": " & err.message & "\n"