## Talos TUI transcript.
##
## Scrollable message history region. Receives new messages from the
## agent loop, scrolls to follow streaming output, and pauses
## scroll-on-output when the user scrolls up.

import std/[strutils, unicode]
import illwill
import theme

type
  MessageRole* = enum
    mrUser = "user"
    mrAssistant = "assistant"
    mrTool = "tool"
    mrToolResult = "tool_result"
    mrSystem = "system"
    mrError = "error"

  TranscriptEntry* = object
    role*: MessageRole
    content*: string
    detail*: string

  TranscriptRegion* = ref object
    entries*: seq[TranscriptEntry]
    scrollOffset*: int
    autoScroll*: bool
    wrapWidth*: int
    dirty*: bool

proc newTranscriptRegion*(width: int): TranscriptRegion =
  TranscriptRegion(
    wrapWidth: max(width, 1),
    autoScroll: true,
  )

proc wrapLine(text: string; maxWidth: int): seq[string] =
  ## Hard-wrap text to width, on rune boundaries. Preserves embedded
  ## newlines. Wrapping by raw byte offset would split a multi-byte UTF-8
  ## character mid-sequence for any non-ASCII content (from the user or an
  ## LLM response) and miscount its visual width.
  let width = if maxWidth < 1: 1 else: maxWidth
  for rawLine in text.split('\n'):
    if rawLine.len == 0:
      result.add("")
      continue
    let runeSeq = toRunes(rawLine)
    var i = 0
    while i < runeSeq.len:
      let endPos = min(i + width, runeSeq.len)
      result.add($runeSeq[i..<endPos])
      i += width
  if result.len == 0:
    result.add("")

proc totalLines(region: TranscriptRegion): int =
  for e in region.entries:
    result += wrapLine(e.content, region.wrapWidth).len

proc addMessage*(region: var TranscriptRegion; role: MessageRole;
                 content: string; detail: string = "") =
  region.entries.add(TranscriptEntry(role: role, content: content, detail: detail))
  region.dirty = true

proc addUser*(region: var TranscriptRegion; content: string) =
  region.addMessage(mrUser, content)

proc addAssistant*(region: var TranscriptRegion; content: string) =
  region.addMessage(mrAssistant, content)

proc addToolCall*(region: var TranscriptRegion; name: string; args: string) =
  region.addMessage(mrTool, "tool: " & name, args)

proc addToolResult*(region: var TranscriptRegion; name: string; content: string) =
  region.addMessage(mrToolResult, content, name)

proc addSystem*(region: var TranscriptRegion; content: string) =
  region.addMessage(mrSystem, content)

proc addError*(region: var TranscriptRegion; content: string) =
  region.addMessage(mrError, content)

proc clear*(region: var TranscriptRegion) =
  region.entries = @[]
  region.scrollOffset = 0
  region.autoScroll = true
  region.dirty = true

proc setWidth*(region: var TranscriptRegion; width: int) =
  let w = max(width, 1)
  if w != region.wrapWidth:
    region.wrapWidth = w
    region.dirty = true

proc scrollUp*(region: var TranscriptRegion; delta: int = 1) =
  region.scrollOffset += delta
  let maxOff = max(totalLines(region) - 1, 0)
  if region.scrollOffset > maxOff:
    region.scrollOffset = maxOff
  region.autoScroll = (region.scrollOffset == 0)

proc scrollDown*(region: var TranscriptRegion; delta: int = 1) =
  region.scrollOffset -= delta
  if region.scrollOffset <= 0:
    region.scrollOffset = 0
    region.autoScroll = true

proc jumpToBottom*(region: var TranscriptRegion) =
  region.scrollOffset = 0
  region.autoScroll = true

proc render*(region: var TranscriptRegion; tb: var TerminalBuffer;
             theme: TuiTheme; y: int; height: int) =
  ## Render visible entries from top of region (`y`) down for `height` rows.
  region.dirty = false
  if region.wrapWidth < 1: return

  let totalLns = totalLines(region)
  let viewBottom = totalLns - region.scrollOffset
  let viewTop = max(viewBottom - height, 0)

  var currentLine = 0
  for e in region.entries:
    let lines = wrapLine(e.content, region.wrapWidth)
    let entryStart = currentLine
    let entryEnd = currentLine + lines.len
    currentLine = entryEnd

    for i, line in lines:
      let ln = entryStart + i
      if ln < viewTop: continue
      if ln >= viewBottom: break
      let renderRow = y + (ln - viewTop)
      if renderRow - y >= height: break

      tb.write(0, renderRow, repeat(' ', region.wrapWidth))

      case e.role
      of mrUser:
        tb.setForegroundColor(theme.userMsg, bright = true)
        tb.write(0, renderRow, "> " & line)
      of mrAssistant:
        tb.setForegroundColor(theme.assistantMsg)
        tb.write(0, renderRow, line)
      of mrTool:
        tb.setForegroundColor(theme.toolCall)
        tb.write(0, renderRow, "  " & line)
      of mrToolResult:
        tb.setForegroundColor(theme.toolResult)
        tb.write(0, renderRow, "  " & line)
      of mrSystem:
        tb.setForegroundColor(theme.muted)
        tb.write(0, renderRow, "[system] " & line)
      of mrError:
        tb.setForegroundColor(theme.errorMsg)
        tb.write(0, renderRow, "[error] " & line)

    if currentLine >= viewBottom:
      break