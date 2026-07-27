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
import std/terminal as std_terminal
import illwill
import talos_core/config
import talos_core/llm_client
import talos_core/tool_registry
import talos_core/memory
import talos_core/agent_loop
import talos_core/token_counter
import talos_agent/cli

import theme
import transcript
import input_bar
import streaming
import overlay

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
    activeOverlay*: Overlay
      ## `oNone` when no floating pane is open. While active, it owns
      ## all keyboard input instead of the normal chat input bar.
    turnCount*: int
      ## ReAct loop iterations for the in-flight (or most recent) turn.
    tokenEstimate*: int
      ## Estimated token count for the current session; refreshed after
      ## each turn and after loading/switching sessions or models. The
      ## sidebar itself shows/hides automatically based on terminal
      ## width (see `renderFrame`), so this just needs to stay current.
    requestSetup*: proc() {.gcsafe, raises: [].}
      ## Optional; called before each agent turn. Used to reset per-turn
      ## state living outside this module — e.g. the delegation budget,
      ## which is otherwise a process-lifetime global.

proc tuiCtrlCHook() {.noconv.} =
  ## illwill expects the Ctrl+C hook itself to tear down raw/fullscreen
  ## terminal state and exit — the shared `state.onCtrlC` hook used by
  ## `chat`/`daemon`/`web` only sets a flag, which works for those
  ## (long-running or loop-checked) but leaves the terminal in raw mode
  ## here since the TUI's key-read loop never consults that flag.
  illwillDeinit()
  quit(0)

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

proc refreshTokenEstimate(ts: TuiState) =
  ## Recomputes the sidebar's token estimate from the current session's
  ## stored history. Cheap local-sqlite read; called after each turn and
  ## when the sidebar is toggled on, not on every render.
  if ts.currentSessionId.len == 0:
    ts.tokenEstimate = 0
    return
  try:
    ts.tokenEstimate = countMessages(getHistory(ts.mem, ts.currentSessionId), ts.llm.model)
  except CatchableError:
    ts.tokenEstimate = 0

proc renderSidebar(ts: TuiState; x, y, w, h: int) =
  ## Draws the context/info panel in the column starting at `x`,
  ## spanning `w` columns and rows `y ..< y + h`.
  if w < 4 or h < 2: return
  ts.tb.setForegroundColor(ts.theme.muted)
  for row in y ..< y + h:
    ts.tb.write(x, row, repeat(' ', w))
  ts.tb.drawVertLine(x, y, y + h - 1)

  var line = y
  template put(s: string) =
    if line < y + h:
      ts.tb.write(x + 2, line, s)
      line.inc

  ts.tb.setForegroundColor(ts.theme.accent, bright = true)
  put("Info")
  line.inc
  ts.tb.setForegroundColor(ts.theme.assistantMsg)
  put("provider  " & ts.cfg.provider)
  put("model     " & ts.llm.model)
  put("session   " & (
    if ts.currentSessionId.len > 0: ts.currentSessionId[0 ..< min(16, ts.currentSessionId.len)]
    else: "(new)"))
  put("tokens    ~" & $ts.tokenEstimate)
  put("turn      " & $ts.turnCount)
  ts.tb.resetAttributes()

proc renderFrame(ts: TuiState) =
  ## Draw the full TUI frame into the terminal buffer.
  let w = terminalWidth()
  let h = terminalHeight()
  ts.tb = newTerminalBuffer(w, h)
  ts.tb.resetAttributes()

  # Status bar (1 line at bottom, full width)
  let statusY = h - 1
  ts.tb.setForegroundColor(ts.theme.statusBarFg)
  ts.tb.setBackgroundColor(ts.theme.statusBarBg)
  ts.tb.write(0, statusY, ts.statusMsg & repeat(' ', max(0, w - ts.statusMsg.len)))
  ts.tb.resetAttributes()

  # Context/info sidebar (right column). Purely automatic: shows once the
  # terminal is wide enough for it not to crush the main pane, hides
  # again the moment it isn't — no manual toggle to fall out of sync
  # with the actual window size.
  const sidebarW = 28
  let showSidebar = w > sidebarW + 20
  let mainW = if showSidebar: w - sidebarW else: w

  # Input bar (above status bar, variable height)
  let inputHeight = 3   # allow up to 3 lines
  let inputY = statusY - 1
  let cursorPos = ts.input.render(ts.tb, ts.theme, inputY, mainW,
                                   focused = ts.activeOverlay.kind == oNone)

  # Transcript region (everything above input bar)
  let transcriptY = inputY - inputHeight
  let transcriptHeight = max(transcriptY, 1)
  if transcriptHeight > 0:
    ts.transcript.setWidth(mainW)
    ts.transcript.render(ts.tb, ts.theme, 0, transcriptHeight)

  # Streaming region (rendered after transcript if there's content)
  let streamHeight = ts.streaming.height()
  if streamHeight > 0:
    # Clamp to 0: a long streamed response with more wrapped lines than
    # transcriptHeight would otherwise make this negative, and illwill's
    # write() takes a Natural row — a negative offset raised a range-check
    # Defect instead of just rendering from the top.
    let streamY = max(0, transcriptHeight - streamHeight)
    ts.streaming.render(ts.tb, ts.theme, 0, streamY, mainW)

  if showSidebar:
    renderSidebar(ts, mainW, 0, sidebarW, statusY)

  # Overlay (floating pane), drawn last so it sits on top of everything.
  if ts.activeOverlay.kind != oNone:
    ts.activeOverlay.render(ts.tb, ts.theme, w, h)

  ts.tb.display()
  # illwill's diff-based writer never drives the real hardware cursor —
  # it only leaves it wherever the last changed cell happened to be
  # painted (the tail of the screen after a full redraw). Position the
  # actual terminal cursor explicitly here, using the coordinates the
  # input bar computed above.
  if cursorPos.y >= 0:
    std_terminal.setCursorPos(cursorPos.x, cursorPos.y)
    showCursor()
  else:
    hideCursor()
  # std/terminal's setCursorPos/showCursor/hideCursor write raw ANSI via
  # File.write with no trailing newline and no flush of their own —
  # unlike illwill.display() (which explicitly flushes at the end),
  # these sit in stdio's buffer until something else flushes, lagging
  # the visible cursor by one full frame behind the content it follows.
  flushFile(stdout)
  ts.dirty = false
proc runAgentTurn(ts: TuiState; userInput: string)
proc handleSlashCommand(ts: TuiState; raw: string)
proc handleKey(ts: TuiState; key: Key) =
  ## Route keypress to the appropriate handler.
  case key
  of Key.None:
    discard
  of Key.Enter:
    let text = ts.input.submit()
    if text.len > 0:
      if text.startsWith('/'):
        handleSlashCommand(ts, text)
      else:
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
  if ts.requestSetup != nil:
    ts.requestSetup()
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
  ts.turnCount = 0
  agentCfg.turnCallback = proc() {.gcsafe, raises: [].} =
    ts.turnCount += 1
    if ts.turnCount > 1:
      ts.statusMsg = "turn " & $ts.turnCount & "..."
    else:
      ts.statusMsg = "thinking..."
    ts.dirty = true

  # Run the agent loop (blocks until done)
  var res: AgentResult
  try:
    res = runAgentLoop(agentCfg, ts.llm, ts.reg, ts.mem, userInput)
    ts.currentSessionId = res.sessionId
    ts.refreshTokenEstimate()
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

proc handleSlashCommand(ts: TuiState; raw: string) =
  ## Dispatches a `/`-prefixed input line as a command instead of
  ## sending it to the agent. `raw` includes the leading slash.
  let parts = strutils.splitWhitespace(raw[1..^1])
  let cmd = if parts.len > 0: parts[0] else: ""
  case cmd
  of "new":
    ts.transcript.clear()
    ts.currentSessionId = ""
    ts.tokenEstimate = 0
    ts.turnCount = 0
    ts.updateStatus()
  of "quit", "exit":
    illwillDeinit()
    quit(0)
  of "info":
    # The sidebar shows/hides itself automatically based on terminal
    # width; this is a one-off status line for when the terminal is too
    # narrow to show it.
    ts.refreshTokenEstimate()
    ts.transcript.addSystem(
      "provider=" & ts.cfg.provider & " model=" & ts.llm.model &
      " session=" & (if ts.currentSessionId.len > 0: ts.currentSessionId else: "(new)") &
      " tokens=~" & $ts.tokenEstimate & " turn=" & $ts.turnCount)
  of "help":
    const helpRows = [
      "/help          show this list",
      "/sessions      browse and load a past session",
      "/model         switch the active model",
      "/info          print current provider/model/session/tokens",
      "/new           start a fresh session",
      "/quit, /exit   exit Talos",
      "PageUp/PageDn  scroll the transcript",
      "Up/Down        input history / navigate an open pane",
      "Enter          submit input / confirm a pane selection",
      "Esc            cancel an open pane",
    ]
    var rows: seq[OverlayRow] = @[]
    for line in helpRows: rows.add((label: line, id: ""))
    ts.activeOverlay = newOverlay(oHelp, "Help (Esc to close)", rows)
  of "sessions":
    let dbPath = resolveDbPath(ts.cfg)
    let sessions = listRecentSessions(dbPath, 20)
    var rows: seq[OverlayRow] = @[]
    for s in sessions:
      let shortId = s.id[0 ..< min(24, s.id.len)]
      let label = shortId & "  " & s.updatedAt & "  (" & $s.messageCount & " msgs)"
      rows.add((label: label, id: s.id))
    ts.activeOverlay = newOverlay(
      oSessions, "Sessions (Enter to load, Esc to cancel)", rows)
  of "model":
    let models = listModels(ts.llm)
    var rows: seq[OverlayRow] = @[]
    for m in models: rows.add((label: m, id: m))
    ts.activeOverlay = newOverlay(
      oModel, "Model (Enter to select, Esc to cancel)", rows)
    if rows.len == 0:
      ts.transcript.addSystem(
        "no models returned by the " & ts.cfg.provider & " endpoint's " &
        "/models list — check the endpoint is reachable")
  of "":
    ts.transcript.addSystem("empty command — try /help")
  else:
    ts.transcript.addSystem("unknown command: /" & cmd & " (try /help)")

proc applyOverlayResult(ts: TuiState; res: OverlayResult) =
  ## Closes the active overlay and applies a confirmed selection.
  let kind = ts.activeOverlay.kind
  ts.activeOverlay = noOverlay()
  if res.kind != orConfirmed or res.id.len == 0:
    return
  case kind
  of oSessions:
    try:
      let history = getHistory(ts.mem, res.id)
      ts.transcript.clear()
      for m in history:
        case m.role
        of crSystem: discard
        of crUser: ts.transcript.addUser(m.content)
        of crAssistant:
          if m.content.len > 0:
            ts.transcript.addAssistant(m.content)
          elif m.toolCalls.len > 0:
            for tc in m.toolCalls:
              ts.transcript.addToolCall(tc.name, tc.arguments)
        of crTool:
          ts.transcript.addToolResult(m.name, m.content)
      ts.currentSessionId = res.id
      ts.updateStatus()
      ts.refreshTokenEstimate()
    except CatchableError as e:
      ts.transcript.addError("failed to load session: " & e.msg)
  of oModel:
    case ts.cfg.provider
    of "vllm": ts.cfg.vllmModel = res.id
    of "openrouter": ts.cfg.openrouterModel = res.id
    else: ts.cfg.openrouterModel = res.id
    ts.llm.model = res.id
    ts.updateStatus()
    ts.refreshTokenEstimate()
    ts.transcript.addSystem("model set to " & res.id)
  of oHelp, oNone:
    discard

proc runTui*(cfg: TalosConfig; llm: LLMClient; reg: ToolRegistry;
             mem: Memory; noStream = false;
             requestSetup: proc() {.gcsafe, raises: [].} = nil): int =
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
  when defined(posix):
    # illwillInit(mouse=true) enables xterm mode 1003 (any-event mouse),
    # which reports every mouse movement, not just clicks/scroll — a
    # constant flood of coordinate escape sequences whenever the mouse is
    # over the terminal at all. We only ever act on clicks (mbaPressed)
    # and scroll, never hover, so turn 1003 back off while leaving 1002
    # (click/drag) and 1006 (SGR extended coords) enabled. Without this,
    # a stray flood of unconsumed motion bytes gets decoded as literal
    # keystrokes and typed into the input box.
    stdout.write("\e[?1003l")
    stdout.flushFile()
  setControlCHook(tuiCtrlCHook)

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
    requestSetup: requestSetup,
  )
  ts.updateStatus()

  try:
    ts.renderFrame()
    var lastW = w
    var lastH = h

    while true:
      let key = getKey()

      # getKey() is non-blocking and only reacts to actual input — a
      # terminal resize (dragging a window/pane edge) doesn't produce a
      # key event at all, so without this check the redraw (and the
      # sidebar's auto show/hide) would only happen whenever the next
      # keystroke or mouse event happened to arrive. Checking every
      # iteration keeps resize response effectively instant since this
      # loop is otherwise idle.
      let curW = terminalWidth()
      let curH = terminalHeight()
      if curW != lastW or curH != lastH:
        lastW = curW
        lastH = curH
        ts.dirty = true

      if key == Key.Mouse:
        let mouse = getMouse()
        if mouse.scroll:
          case mouse.scrollDir
          of sdUp:    ts.transcript.scrollUp(3)
          of sdDown:  ts.transcript.scrollDown(3)
          of sdNone:  discard
          ts.dirty = true
        elif mouse.action == mbaPressed and ts.activeOverlay.kind != oNone:
          # Clicking a rendered overlay row behaves like arrow-key-select
          # + Enter on that row (rects recorded during the last render).
          for rect in ts.activeOverlay.rowRects:
            if mouse.y >= rect.y1 and mouse.y <= rect.y2:
              ts.applyOverlayResult(OverlayResult(kind: orConfirmed, id: rect.id))
              ts.dirty = true
              break
        continue

      if ts.activeOverlay.kind != oNone:
        let res = ts.activeOverlay.handleKey(key)
        if res.kind != orNone:
          ts.applyOverlayResult(res)
        ts.dirty = true
      else:
        ts.handleKey(key)

      if ts.quitRequested:
        break

      if ts.dirty:
        ts.renderFrame()
      elif key == Key.None:
        # Nothing happened this iteration: back off briefly so the loop
        # isn't a pure CPU-spinning busy-wait. Short enough that resize/
        # input response still feels instant (~60Hz).
        sleep(15)

  finally:
    illwillDeinit()

  return 0