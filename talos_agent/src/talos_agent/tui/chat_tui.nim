## Talos TUI main loop.
##
## Fullscreen terminal UI replacing the bare `readLine("> ")` REPL.
## Layout: scrollable transcript (user/assistant/tool messages) +
## status bar + input bar. Integrates with the agent loop for
## streaming token-by-token rendering.
##
## The TUI is single-threaded — the agent loop blocks during LLM calls
## (same as today's chat mode), and illwill's `getKey()` is non-blocking.

import std/[strutils, os]
import std/unicode
import illwill
import talos_core/config
import talos_core/llm_client
import talos_core/tool_registry
import talos_core/memory
import talos_core/agent_loop

import theme
import transcript
import input_bar
import streaming

type
  TuiState* = ref object
    cfg*: TalosConfig
    llm*: LLMClient
    reg*: ToolRegistry
    mem*: Memory
    theme*: TuiTheme
    transcript*: TranscriptRegion
    input*: InputBar
    streaming*: StreamingRegion
    tb*: TerminalBuffer
    dirty*: bool
    quitRequested*: bool
    statusMsg*: string
    noStream*: bool
    currentSessionId*: string

proc updateStatus(ts: TuiState) =
  ## Build status bar text from current state.
  var parts: seq[string] = @[]
  if ts.cfg.provider.len > 0:
    let model =
      case ts.cfg.provider
      of "vllm": ts.cfg.vllmModel
      of "openrouter": ts.cfg.openrouterModel
      else: ts.cfg.openrouterModel
    parts.add(model)
  if ts.currentSessionId.len > 0:
    parts.add(ts.currentSessionId[0..<min(20, ts.currentSessionId.len)])
  parts.add("Ctrl+C to exit")
  ts.statusMsg = parts.join(" │ ")

proc renderFrame(ts: TuiState) =
  ## Draw the full TUI frame into the terminal buffer.
  let w = terminalWidth()
  let h = terminalHeight()
  ts.tb = newTerminalBuffer(w, h)
  ts.tb.resetAttributes()

  # Status bar (1 line at bottom)
  let statusY = h - 1
  ts.tb.setForegroundColor(ts.theme.statusBarFg)
  ts.tb.setBackgroundColor(ts.theme.statusBarBg)
  ts.tb.write(0, statusY, ts.statusMsg & repeat(' ', max(0, w - ts.statusMsg.len)))
  ts.tb.resetAttributes()

  # Input bar (above status bar, variable height)
  let inputHeight = 3   # allow up to 3 lines
  let inputY = statusY - 1
  ts.input.render(ts.tb, ts.theme, inputY, w, focused = true)

  # Transcript region (everything above input bar)
  let transcriptY = inputY - inputHeight
  let transcriptHeight = max(transcriptY, 1)
  if transcriptHeight > 0:
    ts.transcript.setWidth(w)
    ts.transcript.render(ts.tb, ts.theme, 0, transcriptHeight)

  # Streaming region (rendered after transcript if there's content)
  let streamHeight = ts.streaming.height()
  if streamHeight > 0:
    # Clamp to 0: a long streamed response with more wrapped lines than
    # transcriptHeight would otherwise make this negative, and illwill's
    # write() takes a Natural row — a negative offset raised a range-check
    # Defect instead of just rendering from the top.
    let streamY = max(0, transcriptHeight - streamHeight)
    ts.streaming.render(ts.tb, ts.theme, 0, streamY, w)

  ts.tb.setCursorPos(0, statusY)  # cursor at status bar (invisible)
  ts.tb.display()
  ts.dirty = false
proc runAgentTurn(ts: TuiState; userInput: string)
proc handleKey(ts: TuiState; key: Key) =
  ## Route keypress to the appropriate handler.
  case key
  of Key.None:
    discard
  of Key.Enter:
    let text = ts.input.submit()
    if text.len > 0:
      runAgentTurn(ts, text)
      ts.dirty = true
  of Key.Backspace:
    ts.input.backspace()
    ts.dirty = true
  of Key.Delete:
    ts.input.delete()
    ts.dirty = true
  of Key.Left:
    ts.input.cursorLeft()
    ts.dirty = true
  of Key.Right:
    ts.input.cursorRight()
    ts.dirty = true
  of Key.Home:
    ts.input.cursorHome()
    ts.dirty = true
  of Key.End:
    ts.input.cursorEnd()
    ts.dirty = true
  of Key.Up:
    ts.input.historyUp()
    ts.dirty = true
  of Key.Down:
    ts.input.historyDown()
    ts.dirty = true
  of Key.PageUp:
    ts.transcript.scrollUp(3)
    ts.dirty = true
  of Key.PageDown:
    ts.transcript.scrollDown(3)
    ts.dirty = true
  of Key.Escape:
    ts.input.clear()
    ts.dirty = true
  of Key.CtrlC:
    ts.quitRequested = true
  of Key.CtrlL:
    ts.dirty = true
  of Key.CtrlD:
    ts.transcript.jumpToBottom()
    ts.dirty = true
  else:
    # Printable characters
    if ord(key) >= 32 and ord(key) < 127:
      let r = Rune(ord(key))
      ts.input.insertRune(r)
      ts.dirty = true
proc runAgentTurn(ts: TuiState; userInput: string) =
  ## Run one turn of the agent loop and render results into the transcript.
  ts.transcript.addUser(userInput)
  ts.updateStatus()
  ts.dirty = true

  # Build streaming callback
  var agentCfg = newAgentConfig(ts.cfg)
  if not ts.noStream:
    ts.streaming = newStreamingRegion(ts.transcript.wrapWidth)
    agentCfg.streamCallback = proc(event: ChatCompletionStreamEvent) {.gcsafe, raises: [].} =
      if event.kind == sekContent and event.delta.len > 0:
        ts.streaming.append(event.delta)
        ts.dirty = true

  # Add turn callback for status updates
  var turnN = 0
  agentCfg.turnCallback = proc() {.gcsafe, raises: [].} =
    turnN += 1
    if turnN > 1:
      ts.statusMsg = "turn " & $turnN & "..."
    else:
      ts.statusMsg = "thinking..."
    ts.dirty = true

  # Run the agent loop (blocks until done)
  var res: AgentResult
  try:
    res = runAgentLoop(agentCfg, ts.llm, ts.reg, ts.mem, userInput)
    ts.currentSessionId = res.sessionId
  except CatchableError as e:
    ts.transcript.addError(e.msg)
    ts.updateStatus()
    ts.dirty = true
    return

  # Freeze streaming content
  let streamText = ts.streaming.freeze()
  ts.streaming.clear()

  # Add final assistant text
  if res.text.len > 0:
    ts.transcript.addAssistant(res.text)
  elif streamText.len > 0:
    ts.transcript.addAssistant(streamText)

  if res.stopReason != asrFinished:
    ts.transcript.addSystem("stop reason: " & $res.stopReason)

  ts.updateStatus()
  ts.dirty = true
proc runTui*(cfg: TalosConfig; llm: LLMClient; reg: ToolRegistry;
             mem: Memory; noStream = false): int =
  ## Run the fullscreen TUI. Returns 0 on clean exit, 1 on error.

  if getEnv("TERM") == "dumb":
    stderr.writeLine("Error: TERM=dumb — TUI requires a real terminal.")
    return 1

  let w = terminalWidth()
  let h = terminalHeight()
  if w <= 0 or h <= 0:
    stderr.writeLine("Error: No terminal detected. TUI requires a real terminal.")
    return 1

  illwillInit(fullScreen = true, mouse = true)

  var ts = TuiState(
    cfg: cfg,
    llm: llm,
    reg: reg,
    mem: mem,
    theme: defaultTheme(),
    transcript: newTranscriptRegion(w),
    input: newInputBar(multiline = true),
    streaming: newStreamingRegion(w),
    currentSessionId: "",
    noStream: noStream,
  )
  ts.updateStatus()

  try:
    ts.renderFrame()

    while true:
      let key = getKey()
      if key == Key.Mouse:
        let mouse = getMouse()
        if mouse.scroll:
          case mouse.scrollDir
          of sdUp:    ts.transcript.scrollUp(3)
          of sdDown:  ts.transcript.scrollDown(3)
          of sdNone:  discard
          ts.dirty = true
        continue

      ts.handleKey(key)

      if ts.quitRequested:
        break

      if ts.dirty:
        ts.renderFrame()

  finally:
    illwillDeinit()

  return 0