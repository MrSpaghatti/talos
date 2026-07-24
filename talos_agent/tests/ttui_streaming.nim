## Tests for the TUI streaming region's word wrapping.
##
## Regression coverage for the byte-vs-rune wrap bug: `wordWrap` compared
## UTF-8 byte counts against a column width, so any non-ASCII streamed
## text (accents, CJK, em dashes) over-wrapped, and a space-free "word"
## longer than the terminal width was emitted as a single overflowing
## line with no hard-wrap fallback.

import std/[strutils, unicode, unittest]

import talos_agent/tui/streaming

proc wrappedLines(text: string; width: int): seq[string] =
  ## Drives the public API: append the full text to a fresh region and
  ## return the resulting wrapped lines.
  var region = newStreamingRegion(width)
  region.append(text)
  region.current.lines

suite "streaming region word wrap":
  test "plain ASCII words wrap at the width":
    let lines = wrappedLines("alpha beta gamma delta", 11)
    check lines == @["alpha beta", "gamma delta"]

  test "wrap width counts runes, not bytes":
    # Five two-byte runes (ü) per word: byte-based wrapping would put one
    # word per line at width 11 (6 bytes + space + 6 bytes > 11), rune
    # counting fits two ("ééééé ééééé" = 11 runes).
    let lines = wrappedLines("ééééé ééééé ééééé", 11)
    check lines.len == 2
    check lines[0].runeLen == 11

  test "over-long space-free word is hard-wrapped, not overflowed":
    let url = "https://example.com/" & "x".repeat(60)
    let lines = wrappedLines(url, 20)
    check lines.len == 4
    for line in lines:
      check line.runeLen <= 20

  test "hard wrap lands on rune boundaries":
    # 30 CJK runes (90 bytes) at width 10: a byte-offset slice would cut
    # a 3-byte sequence mid-character; every output line must be valid
    # UTF-8 of exactly 10 runes.
    let text = "軆".repeat(30)
    let lines = wrappedLines(text, 10)
    check lines.len == 3
    for line in lines:
      check line.runeLen == 10
      check line.validateUtf8() == -1

  test "embedded newlines are respected":
    let lines = wrappedLines("first\nsecond line here", 40)
    check lines[0] == "first"
    check lines[1] == "second line here"

  test "empty token is a no-op":
    var region = newStreamingRegion(20)
    region.append("")
    check region.current.lines.len == 0
