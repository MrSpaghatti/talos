## Tests for talos_agent/tui/transcript.nim

import std/[unittest, unicode, strutils]
import illwill
import talos_agent/tui/theme
import talos_agent/tui/transcript

proc rowText(tb: TerminalBuffer; y, width: int): string =
  for x in 0 ..< width:
    result.add($tb[x, y].ch)

suite "TranscriptRegion: entries":
  test "starts empty":
    let r = newTranscriptRegion(80)
    check r.entries.len == 0

  test "addUser/addAssistant/addSystem/addError append entries":
    var r = newTranscriptRegion(80)
    r.addUser("hi")
    r.addAssistant("hello")
    r.addSystem("note")
    r.addError("oops")
    check r.entries.len == 4
    check r.entries[0].role == mrUser
    check r.entries[1].role == mrAssistant
    check r.entries[2].role == mrSystem
    check r.entries[3].role == mrError

  test "addToolCall/addToolResult stash the tool name in detail":
    var r = newTranscriptRegion(80)
    r.addToolCall("shell", "{\"cmd\": \"ls\"}")
    r.addToolResult("shell", "file1\nfile2")
    check r.entries[0].role == mrTool
    check r.entries[0].detail == "{\"cmd\": \"ls\"}"
    check r.entries[1].role == mrToolResult
    check r.entries[1].detail == "shell"

  test "clear resets entries, scroll, and autoScroll":
    var r = newTranscriptRegion(80)
    r.addUser("hi")
    r.scrollUp(5)
    r.clear()
    check r.entries.len == 0
    check r.scrollOffset == 0
    check r.autoScroll == true

suite "TranscriptRegion: scrolling":
  test "scrollDown never goes negative and restores autoScroll":
    var r = newTranscriptRegion(80)
    r.addUser("hi")
    r.scrollDown(100)
    check r.scrollOffset == 0
    check r.autoScroll == true

  test "scrollUp past the top clamps instead of scrolling forever":
    var r = newTranscriptRegion(80)
    for i in 1..5:
      r.addUser("line " & $i)
    r.scrollUp(10_000)
    let clamped = r.scrollOffset
    r.scrollUp(10_000)
    check r.scrollOffset == clamped

  test "scrollUp then scrollDown to zero re-enables autoScroll":
    var r = newTranscriptRegion(80)
    r.addUser("hi")
    r.scrollUp(3)
    check r.autoScroll == false
    r.scrollDown(3)
    check r.autoScroll == true

suite "TranscriptRegion: cap":
  test "entries are trimmed to KeepTranscriptEntries once past the cap":
    var r = newTranscriptRegion(80)
    for i in 0 .. MaxTranscriptEntries:  # one past the cap
      r.addUser("msg " & $i)
    check r.entries.len < MaxTranscriptEntries
    # The survivors are the newest entries, oldest dropped.
    check r.entries[^1].content == "msg " & $MaxTranscriptEntries
    check r.entries[0].content != "msg 0"

  test "trim clamps a scroll offset pointing above the surviving content":
    var r = newTranscriptRegion(80)
    for i in 0 ..< MaxTranscriptEntries:
      r.addUser("msg " & $i)
    r.scrollUp(999_999)  # clamped to totalLines - 1, i.e. the very top
    r.addUser("overflow")  # triggers the trim
    # scrollOffset must not exceed what remains, or render goes blank.
    r.scrollUp(0)  # re-clamp path; offset must already be in range
    check r.scrollOffset >= 0
    var tb = newTerminalBuffer(80, 10)
    r.render(tb, defaultTheme(), 0, 10)
    check rowText(tb, 0, 80).strip().len > 0

suite "TranscriptRegion: render":
  test "user messages are prefixed with '> '":
    var r = newTranscriptRegion(80)
    r.addUser("hello there")
    var tb = newTerminalBuffer(80, 10)
    r.render(tb, defaultTheme(), 0, 10)
    check rowText(tb, 0, 80).strip()[0] == '>'

  test "assistant messages get a 'Talos' label on the first line":
    var r = newTranscriptRegion(80)
    r.addAssistant("hi back")
    var tb = newTerminalBuffer(80, 10)
    r.render(tb, defaultTheme(), 0, 10)
    check "Talos" in rowText(tb, 0, 80)

  test "consecutive entries are separated by a blank row":
    var r = newTranscriptRegion(80)
    r.addUser("first")
    r.addUser("second")
    var tb = newTerminalBuffer(80, 10)
    r.render(tb, defaultTheme(), 0, 10)
    # row 0: "first", row 1: blank separator, row 2: "second"
    check rowText(tb, 0, 80).strip().len > 0
    check rowText(tb, 1, 80).strip().len == 0
    check rowText(tb, 2, 80).strip().len > 0
