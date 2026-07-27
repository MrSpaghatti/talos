## Talos TUI overlay/modal framework.
##
## A generic centered, bordered floating pane with a selectable list of
## rows — the building block for `/sessions`, `/model`, and `/help`.
## Only one overlay is active at a time; while active it owns all
## keyboard and mouse input instead of the normal chat input.

import std/strutils
import illwill
import theme

type
  OverlayKind* = enum
    oNone, oSessions, oModel, oHelp

  OverlayRow* = tuple[label: string, id: string]

  RowRect* = tuple[y1, y2: int, id: string]
    ## Absolute screen rows spanned by a rendered row, for click
    ## hit-testing (see `chat_tui.handleKey`'s mouse-press branch).

  Overlay* = object
    kind*: OverlayKind
    title*: string
    rows*: seq[OverlayRow]
    selectedIdx*: int
    rowRects*: seq[RowRect]
      ## Rebuilt on every `render` call.

  OverlayResultKind* = enum
    orNone, orConfirmed, orCancelled

  OverlayResult* = object
    kind*: OverlayResultKind
    id*: string   ## valid when kind == orConfirmed

proc newOverlay*(kind: OverlayKind; title: string;
                  rows: seq[OverlayRow]): Overlay =
  Overlay(kind: kind, title: title, rows: rows, selectedIdx: 0)

proc noOverlay*(): Overlay =
  Overlay(kind: oNone)

proc handleKey*(ov: var Overlay; key: Key): OverlayResult =
  ## Routes a keypress to the overlay. Caller should stop routing keys
  ## to the normal chat input while `ov.kind != oNone`.
  case key
  of Key.Up:
    if ov.rows.len > 0:
      ov.selectedIdx = (ov.selectedIdx - 1 + ov.rows.len) mod ov.rows.len
    OverlayResult(kind: orNone)
  of Key.Down:
    if ov.rows.len > 0:
      ov.selectedIdx = (ov.selectedIdx + 1) mod ov.rows.len
    OverlayResult(kind: orNone)
  of Key.Enter:
    if ov.rows.len > 0 and ov.selectedIdx < ov.rows.len:
      OverlayResult(kind: orConfirmed, id: ov.rows[ov.selectedIdx].id)
    else:
      OverlayResult(kind: orCancelled)
  of Key.Escape, Key.CtrlC:
    OverlayResult(kind: orCancelled)
  else:
    OverlayResult(kind: orNone)

proc render*(ov: var Overlay; tb: var TerminalBuffer; theme: TuiTheme;
             termW, termH: int) =
  ## Draws a centered bordered box listing `ov.rows`, highlighting the
  ## selected row. No-op if the overlay is inactive or the terminal is
  ## too small to fit a usable box.
  ov.rowRects.setLen(0)
  if ov.kind == oNone: return

  let boxW = max(20, min(60, termW - 4))
  let contentH = max(ov.rows.len, 1)
  let boxH = min(contentH + 4, max(termH - 4, 5))  # border + title + margin
  let x1 = max(0, (termW - boxW) div 2)
  let y1 = max(0, (termH - boxH) div 2)
  let x2 = min(termW - 1, x1 + boxW - 1)
  let y2 = min(termH - 1, y1 + boxH - 1)

  # Clear the box interior so it isn't see-through over the transcript.
  tb.setForegroundColor(theme.accent, bright = true)
  for y in y1..y2:
    tb.write(x1, y, repeat(' ', max(0, x2 - x1 + 1)))
  tb.drawRect(x1, y1, x2, y2)

  # Title, centered on the top border.
  if ov.title.len > 0:
    let t = " " & ov.title & " "
    let tx = x1 + max(1, (boxW - t.len) div 2)
    tb.write(tx, y1, t)

  # Rows, one per line, starting two rows below the top border.
  let listTop = y1 + 2
  let listBottom = min(y2 - 1, listTop + ov.rows.len - 1)
  for i, row in ov.rows:
    let y = listTop + i
    if y > listBottom: break
    let selected = i == ov.selectedIdx
    if selected:
      tb.setForegroundColor(theme.statusBarFg)
      tb.setBackgroundColor(theme.statusBarBg)
    else:
      tb.setForegroundColor(theme.assistantMsg)
    let label = row.label
    let visible =
      if label.len > boxW - 4: label[0 ..< boxW - 4]
      else: label
    tb.write(x1 + 2, y, visible & repeat(' ', max(0, boxW - 4 - visible.len)))
    tb.resetAttributes()
    ov.rowRects.add((y1: y, y2: y, id: row.id))

  if ov.rows.len == 0:
    tb.setForegroundColor(theme.muted)
    tb.write(x1 + 2, listTop, "(nothing to show)")

  tb.resetAttributes()
