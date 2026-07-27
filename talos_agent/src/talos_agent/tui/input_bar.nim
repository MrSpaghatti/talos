## Talos TUI input bar.
##
## Multi-line input with cursor movement, backspace/delete, history
## navigation (up/down), and submit. Paste support via bracket-paste
## (terminal-level, transparent to illwill).

import std/[strutils, unicode]
import illwill
import theme

const
  MaxHistory* = 1000
  MinInputWidth = 3

type
  InputBar* = ref object
    text*: string                ## Current input text
    cursorPos*: int             ## Byte position in text (NOT rune index)
    history*: seq[string]       ## Previous submitted inputs (newest last)
    historyIdx*: int            ## -1 = not navigating; else index into history
    savedText*: string          ## Saved input before history navigation
    multiline*: bool            ## Whether to accept newlines (Shift+Enter)

proc newInputBar*(multiline = false): InputBar =
  InputBar(
    cursorPos: 0,
    historyIdx: -1,
    multiline: multiline,
  )

# ---- Cursor helpers ----

proc runeIndexToBytePos(text: string; runeIdx: int): int =
  ## Convert a rune index to byte position. Clamps to [0, text.len].
  if runeIdx <= 0: return 0
  let rc = runeLen(text)
  if runeIdx >= rc: return text.len
  return runeOffset(text, runeIdx)

proc bytePosToRuneIndex(text: string; bytePos: int): int =
  ## Convert byte position to rune index. Clamps to [0, runeLen].
  if bytePos <= 0 or text.len == 0: return 0
  let rc = runeLen(text)
  if bytePos >= text.len: return rc
  var ri = 0
  for r in runes(text):
    if runeOffset(text, ri) >= bytePos: return ri
    ri += 1
  return rc

proc cursorLeft*(bar: var InputBar) =
  if bar.text.len == 0 or bar.cursorPos == 0: return
  let ri = bytePosToRuneIndex(bar.text, bar.cursorPos)
  if ri > 0:
    bar.cursorPos = runeIndexToBytePos(bar.text, ri - 1)

proc cursorRight*(bar: var InputBar) =
  let ri = bytePosToRuneIndex(bar.text, bar.cursorPos)
  let rc = runeLen(bar.text)
  if ri < rc:
    bar.cursorPos = runeIndexToBytePos(bar.text, ri + 1)

proc cursorHome*(bar: var InputBar) =
  bar.cursorPos = 0

proc cursorEnd*(bar: var InputBar) =
  bar.cursorPos = bar.text.len

# ---- Editing ----

proc insertRune*(bar: var InputBar; r: Rune) =
  let s = $r
  bar.text.insert(s, bar.cursorPos)
  bar.cursorPos += s.len

proc insertText*(bar: var InputBar; s: string) =
  bar.text.insert(s, bar.cursorPos)
  bar.cursorPos += s.len

proc backspace*(bar: var InputBar) =
  if bar.text.len == 0 or bar.cursorPos == 0: return
  let ri = bytePosToRuneIndex(bar.text, bar.cursorPos)
  if ri == 0: return
  let prev = runeIndexToBytePos(bar.text, ri - 1)
  bar.text.delete(prev, bar.cursorPos - 1)
  bar.cursorPos = prev

proc delete*(bar: var InputBar) =
  if bar.cursorPos >= bar.text.len: return
  let ri = bytePosToRuneIndex(bar.text, bar.cursorPos)
  let next = runeIndexToBytePos(bar.text, ri + 1)
  bar.text.delete(bar.cursorPos, next - 1)

proc clear*(bar: var InputBar) =
  bar.text = ""
  bar.cursorPos = 0
  bar.historyIdx = -1

# ---- History ----

proc pushHistory*(bar: var InputBar; text: string) =
  let s = text.strip()
  if s.len == 0: return
  if bar.history.len > 0 and bar.history[^1] == s: return
  bar.history.add(s)
  if bar.history.len > MaxHistory:
    bar.history.delete(0)

proc historyUp*(bar: var InputBar) =
  if bar.history.len == 0: return
  if bar.historyIdx < 0:
    bar.savedText = bar.text
    bar.historyIdx = bar.history.len - 1
  elif bar.historyIdx > 0:
    bar.historyIdx -= 1
  else:
    return
  bar.text = bar.history[bar.historyIdx]
  bar.cursorPos = bar.text.len

proc historyDown*(bar: var InputBar) =
  if bar.historyIdx < 0: return
  if bar.historyIdx < bar.history.len - 1:
    bar.historyIdx += 1
    bar.text = bar.history[bar.historyIdx]
  else:
    bar.historyIdx = -1
    bar.text = bar.savedText
  bar.cursorPos = bar.text.len

# ---- Submission ----

proc submit*(bar: var InputBar): string =
  ## Returns the current text and clears the bar.
  result = bar.text
  if result.len > 0:
    pushHistory(bar, result)
  clear(bar)

# ---- Rendering ----

proc wrappedInputLines(text: string; width: int): seq[string] =
  ## Wraps on rune boundaries, not raw byte offsets — slicing by byte
  ## offset would split a multi-byte UTF-8 character mid-sequence for any
  ## non-ASCII input, corrupting it and miscounting its visual width.
  if width < 1: return @[]
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

proc render*(bar: var InputBar; tb: var TerminalBuffer; theme: TuiTheme;
             y: int; width: int; focused: bool): tuple[x, y: int] =
  ## Renders the input bar and returns the absolute screen position the
  ## real terminal cursor should be moved to, or (-1, -1) if it
  ## shouldn't be shown here (unfocused, or nothing rendered). Callers
  ## must apply this via the real terminal cursor themselves —
  ## `TerminalBuffer.setCursorPos` below only tracks illwill's internal
  ## default-write position and never moves the actual hardware cursor.
  result = (-1, -1)
  let prompt = "> "
  let availWidth = max(width - prompt.len, MinInputWidth)
  let lines = wrappedInputLines(bar.text, availWidth)
  let nLines = max(lines.len, 1)

  for i in 0..<nLines:
    let row = y - nLines + 1 + i
    if row < 0: continue
    tb.write(0, row, repeat(' ', width))
    if i == 0:
      tb.write(0, row, prompt)
    else:
      tb.write(0, row, repeat(' ', prompt.len))
    if i < lines.len:
      tb.setForegroundColor(fgNone)
      tb.write(prompt.len, row, lines[i])

  if focused and lines.len > 0:
    let lastLineIdx = nLines - 1
    # Compute the rune offset within the last rendered line. Must be in
    # the same units as cursorRunIdx (a rune index over the whole text) —
    # summing lines[j].len (a byte count) here used to diverge from a rune
    # index for any non-ASCII content, occasionally driving cursorX
    # negative and crashing on setCursorPos's Natural parameter.
    var prevLinesRunes = 0
    for j in 0..<lastLineIdx:
      prevLinesRunes += runeLen(lines[j])
    let cursorRunIdx = bytePosToRuneIndex(bar.text, bar.cursorPos)
    let cursorInLastLine = cursorRunIdx - prevLinesRunes
    let cursorX = prompt.len + max(0, min(cursorInLastLine, availWidth))
    let cursorRow = y - nLines + 1 + lastLineIdx
    if cursorRow >= 0:
      result = (cursorX, cursorRow)