## Talos TUI streaming region.
##
## Append-only region for the currently-streaming assistant response.
## New tokens extend the last line or add lines. When the response
## completes (tool call or finish), the block is "frozen" into the
## transcript and a new streaming region starts.

import std/[strutils, unicode]
import illwill
import theme

type
  StreamBlock* = object
    lines*: seq[string]           ## Wrapped lines of the current response
    raw*: string                  ## Accumulated raw text (for freeze)

  StreamingRegion* = ref object
    current*: StreamBlock         ## Current streaming block
    width*: int                   ## Terminal width for wrapping
    dirty*: bool                  ## New content since last render

proc newStreamingRegion*(w: int): StreamingRegion =
  StreamingRegion(width: max(w, 1))

proc wordWrap(text: string; maxWidth: int): seq[string] =
  ## Rune-aware word wrap with a hard-wrap fallback for over-long,
  ## space-free words (long URLs, CJK runs). Comparing byte counts against
  ## a column width — as the sibling TUI regions did before their rune
  ## fixes — systematically over-wraps any non-ASCII streamed text and a
  ## single long word used to be emitted as one overflowing line.
  let width = if maxWidth < 1: 1 else: maxWidth
  if text.len == 0: return @[""]
  var lines: seq[string] = @[]
  for rawLine in text.split('\n'):
    var curLine: seq[Rune] = @[]
    var lineHasContent = false
    for word in rawLine.split(' '):
      var w = toRunes(word)
      # Hard-wrap anything wider than the terminal on its own.
      while w.len > width:
        if lineHasContent:
          lines.add($curLine)
          curLine = @[]
          lineHasContent = false
        lines.add($w[0 ..< width])
        w = w[width .. ^1]
      if not lineHasContent:
        curLine = w
        lineHasContent = true
      elif curLine.len + 1 + w.len <= width:
        curLine.add(Rune(' '))
        curLine.add(w)
      else:
        lines.add($curLine)
        curLine = w
    lines.add($curLine)
  lines

proc append*(region: var StreamingRegion; token: string) =
  if token.len == 0: return
  region.dirty = true
  region.current.raw.add(token)
  region.current.lines = wordWrap(region.current.raw, region.width)
  if region.current.lines.len == 0:
    region.current.lines = @[""]

proc freeze*(region: var StreamingRegion): string =
  result = region.current.raw
  region.current = StreamBlock()
  region.dirty = false

proc clear*(region: var StreamingRegion) =
  region.current = StreamBlock()
  region.dirty = false

proc setWidth*(region: var StreamingRegion; width: int) =
  let w = max(width, 1)
  if w != region.width:
    region.width = w
    region.current.lines = wordWrap(region.current.raw, region.width)

proc height*(region: StreamingRegion): int =
  max(region.current.lines.len, 0)

proc render*(region: var StreamingRegion; tb: var TerminalBuffer;
             theme: TuiTheme; x, y: int; width: int) =
  if region.current.lines.len == 0: return
  region.dirty = false
  tb.setForegroundColor(theme.assistantMsg)
  for i, line in region.current.lines:
    let row = y + i
    if row < 0: continue
    tb.write(x, row, line)