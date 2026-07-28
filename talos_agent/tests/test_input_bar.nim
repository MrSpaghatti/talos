## Tests for talos_agent/tui/input_bar.nim

import std/[unittest, unicode]
import illwill
import talos_agent/tui/theme
import talos_agent/tui/input_bar

suite "InputBar: editing":
  test "insertRune and backspace":
    var bar = newInputBar()
    bar.insertRune(Rune('h'))
    bar.insertRune(Rune('i'))
    check bar.text == "hi"
    bar.backspace()
    check bar.text == "h"

  test "submit returns and clears the text":
    var bar = newInputBar()
    bar.insertText("hello")
    let submitted = bar.submit()
    check submitted == "hello"
    check bar.text == ""

  test "history recalls previously submitted input":
    var bar = newInputBar()
    bar.insertText("first")
    discard bar.submit()
    bar.insertText("second")
    discard bar.submit()
    bar.historyUp()
    check bar.text == "second"
    bar.historyUp()
    check bar.text == "first"

suite "InputBar: render":
  test "the prompt is styled with theme.inputPrompt, not left over from a prior color":
    var bar = newInputBar()
    bar.insertText("hi")
    var tb = newTerminalBuffer(20, 3)
    # Simulate a prior draw leaving the buffer's color on something else,
    # the way the transcript/sidebar draw before the input bar each frame.
    tb.setForegroundColor(fgRed)
    discard bar.render(tb, defaultTheme(), 2, 20, focused = true)
    check tb[0, 2].fg == defaultTheme().inputPrompt
