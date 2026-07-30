## Coding tool registry helpers.
##
## Exposes the coding harness as OpenAI function-calling tools that can
## be registered against a `ToolRegistry`:
##
##   import talos_core/tool_registry
##   import talos_code/code_tool
##   let reg = newToolRegistry()
##   reg.register(compileTool(cfg))
##   reg.register(testTool(cfg))
##
## Each tool wraps `runCompile` with the appropriate sandbox root guard,
## parameterises the command, and returns structured output (or a
## parseable error summary for the LLM to fix).

import std/[json, strutils, os]

import talos_core/tool_registry
import talos_core/file_path_validator
import code_runner
import compile

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc clampOutput(s: string; cap: int): string =
  if s.len <= cap: s
  else: s[0 ..< cap] & "\n... [output truncated]"

proc withinSandbox*(path, root: string): bool =
  ## True if `path` resolves to `root` itself or a location beneath it.
  ## Resolution follows symlinks and collapses `..`/`.` via resolvePathSafe,
  ## and the boundary requires a full "/" separator so a sibling directory
  ## sharing the prefix cannot escape. An empty `root` means no sandbox is
  ## configured, so the check is skipped (unrestricted).
  if root.len == 0:
    return true
  try:
    let absRoot = resolvePathSafe(root)
    let absPath = resolvePathSafe(path)
    result = absPath == absRoot or absPath.startsWith(absRoot & "/")
  except CatchableError:
    result = false  # fail closed if the path cannot be resolved

proc formatCompileResultForTool(res: CompileResult): string =
  ## LLM-facing formatter: clamps stdout to keep tool output small. Named
  ## distinctly from code_runner.formatCompileResult (the human-facing CLI
  ## formatter) rather than shadowing it — the two serve different
  ## purposes (clamped tool output vs. full CLI summary), but the previous
  ## name collision made it easy to miss that this one used a stale
  ## `exitCode == -1` proxy for "timed out" instead of the real
  ## `res.timedOut`/`res.truncated` fields (now reliably populated by
  ## runCompile).
  if res.success:
    return "Compiled successfully in " & $res.durationMs & "ms.\n" &
           "stdout:\n" & res.stdout
  var lines = @[if res.timedOut: "TIMEOUT or LAUNCH FAILURE"
                else: "Compilation failed (exit " & $res.exitCode & ") in " &
                      $res.durationMs & "ms.\n"]
  if res.errors.len > 0:
    lines.add "Errors:\n"
    for err in res.errors:
      lines.add "  " & err.file & "(" & $err.line & "," & $err.column & "): " &
                err.severity & ": " & err.message
  else:
    lines.add "stdout:\n" & clampOutput(res.stdout, 4096)
  if res.stderr.len > 0:
    lines.add "stderr:\n" & res.stderr
  if res.truncated:
    lines.add "(output truncated)"
  lines.join("\n")

# ---------------------------------------------------------------------------
# Compile tool
# ---------------------------------------------------------------------------

proc compileTool*(cfg: CodingHarnessConfig): Tool =
  let buildCmd = cfg.buildCmd
  let timeoutMs = cfg.buildTimeoutMs
  let maxOut = cfg.maxOutputBytes
  let execute: ToolExecuteProc = proc (args: JsonNode): ToolResult {.gcsafe, raises: [].} =
    if buildCmd.len == 0:
      return ToolResult(output: "no build command configured", isError: true)
    try:
      let res = runCompile(buildCmd, timeoutMs, maxOut)
      return ToolResult(output: formatCompileResultForTool(res), isError: not res.success)
    except CatchableError as e:
      return ToolResult(output: "compile failed: " & e.msg, isError: true)
  result = newTool(
    name = "compile",
    description = "Compile the project. Returns structured errors with file, " &
                  "line, and message so the model can fix them. Use this " &
                  "after writing or modifying code.",
    parameters = %*{
      "type": "object",
      "properties": {},
      "description": "Run the project's configured build command.",
    },
    execute = execute,
  )

# ---------------------------------------------------------------------------
# Test tool
# ---------------------------------------------------------------------------

proc testTool*(cfg: CodingHarnessConfig): Tool =
  let testCmd = cfg.testCmd
  let timeoutMs = cfg.testTimeoutMs
  let maxOut = cfg.maxOutputBytes
  let execute: ToolExecuteProc = proc (args: JsonNode): ToolResult {.gcsafe, raises: [].} =
    if testCmd.len == 0:
      return ToolResult(output: "no test command configured", isError: true)
    try:
      let res = runCompile(testCmd, timeoutMs, maxOut)
      return ToolResult(output: formatCompileResultForTool(res), isError: not res.success)
    except CatchableError as e:
      return ToolResult(output: "test failed: " & e.msg, isError: true)
  result = newTool(
    name = "test",
    description = "Run the project's test suite. Returns pass/fail counts and " &
                  "any test error details.",
    parameters = %*{
      "type": "object",
      "properties": {},
    },
    execute = execute,
  )

# ---------------------------------------------------------------------------
# Read file tool
# ---------------------------------------------------------------------------

proc readFileTool*(cfg: CodingHarnessConfig): Tool =
  let allowed = cfg.allowedExtensions
  let sandboxRoot = cfg.sandboxRoot
  let execute: ToolExecuteProc = proc (args: JsonNode): ToolResult {.gcsafe, raises: [].} =
    let path = args{"path"}.getStr("")
    if path.len == 0:
      return ToolResult(output: "path is required", isError: true)
    if not withinSandbox(path, sandboxRoot):
      return ToolResult(
        output: "access denied: path is outside the sandbox root '" &
                sandboxRoot & "'",
        isError: true, exitCode: 1,
      )
    let (_, _, ext) = path.splitFile()
    if ext.len > 0 and ext notin allowed:
      return ToolResult(
        output: "file extension '" & ext & "' is not in the allowed list: " &
                allowed.join(", "),
        isError: true,
      )
    try:
      let content = readFile(path)
      return ToolResult(output: content, isError: false)
    except CatchableError as e:
      return ToolResult(
        output: "failed to read file: " & e.msg,
        isError: true,
        exitCode: 1,
      )
  result = newTool(
    name = "read_file",
    description = "Read the contents of a file within the sandbox. " &
                  "Only files with allowed extensions can be read.",
    parameters = %*{
      "type": "object",
      "properties": {
        "path": {
          "type": "string",
          "description": "Absolute path to the file to read.",
        },
      },
      "required": ["path"],
    },
    execute = execute,
  )

# ---------------------------------------------------------------------------
# Write file tool
# ---------------------------------------------------------------------------

proc writeFileTool*(cfg: CodingHarnessConfig): Tool =
  let allowed = cfg.allowedExtensions
  let sandboxRoot = cfg.sandboxRoot
  let execute: ToolExecuteProc = proc (args: JsonNode): ToolResult {.gcsafe, raises: [].} =
    let path = args{"path"}.getStr("")
    let content = args{"content"}.getStr("")
    if path.len == 0:
      return ToolResult(output: "path is required", isError: true)
    if not withinSandbox(path, sandboxRoot):
      return ToolResult(
        output: "access denied: path is outside the sandbox root '" &
                sandboxRoot & "'",
        isError: true, exitCode: 1,
      )
    let (_, _, ext) = path.splitFile()
    if ext.len > 0 and ext notin allowed:
      return ToolResult(
        output: "file extension '" & ext & "' is not in the allowed list: " &
                allowed.join(", "),
        isError: true,
      )
    let parent = parentDir(path)
    if parent.len > 0 and not dirExists(parent):
      try:
        createDir(parent)
      except CatchableError as e:
        return ToolResult(
          output: "failed to create parent directory: " & e.msg,
          isError: true,
          exitCode: 1,
        )
    # Write to a temp file and rename into place — matches file_tool.nim's
    # fileWriteTool. A bare writeFile() truncates the target immediately,
    # so a crash or disk-full error mid-write corrupts it in place; the
    # temp+rename here leaves the original file untouched until the new
    # content is fully on disk.
    let tempPath = path & ".tmp"
    try:
      writeFile(tempPath, content)
    except CatchableError as e:
      return ToolResult(
        output: "failed to write file: " & e.msg,
        isError: true,
        exitCode: 1,
      )
    try:
      moveFile(tempPath, path)
      return ToolResult(
        output: "file written: " & path & " (" & $content.len & " bytes)",
        isError: false,
      )
    except CatchableError as e:
      if fileExists(tempPath):
        try: removeFile(tempPath) except CatchableError: discard
      return ToolResult(
        output: "failed to write file: " & e.msg,
        isError: true,
        exitCode: 1,
      )
    # Nim 2.2.x with -d:ssl may flag moveFile as raising Exception transitively.
    # Catch as a safety net even though this should never trigger (same
    # footgun documented on fileWriteTool's moveFile call in file_tool.nim).
    except Exception as e:
      if fileExists(tempPath):
        try: removeFile(tempPath) except CatchableError: discard
      return ToolResult(
        output: "failed to write file: " & e.msg,
        isError: true,
        exitCode: 1,
      )
  result = newTool(
    name = "write_file",
    description = "Write content to a file within the sandbox. " &
                  "Only files with allowed extensions can be written.",
    parameters = %*{
      "type": "object",
      "properties": {
        "path": {
          "type": "string",
          "description": "Absolute path to the file to write.",
        },
        "content": {
          "type": "string",
          "description": "Full file content to write.",
        },
      },
      "required": ["path", "content"],
    },
    execute = execute,
  )