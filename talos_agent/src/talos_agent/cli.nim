## Shared CLI utilities: output formatting, input, session listing, persona loading.

import std/[os, strutils, strformat]
import db_connector/db_sqlite
import talos_core/config
import talos_core/memory
import talos_core/persona

# ---------------------------------------------------------------------------
# Output formatting
# ---------------------------------------------------------------------------

proc printAssistant*(text: string) =
  stdout.writeLine("Talos> " & text)
  stdout.flushFile()

proc printSystemNote*(text: string) =
  stdout.writeLine("[" & text & "]")
  stdout.flushFile()

proc printError*(text: string) =
  stderr.writeLine("error: " & text)
  stderr.flushFile()

# ---------------------------------------------------------------------------
# Persona loading
# ---------------------------------------------------------------------------

proc defaultPersonasPath*(): string =
  ## Returns the default personas config path: ~/.config/talos/personas.toml
  let home = getHomeDir()
  if home.len == 0:
    return ""
  return home / ".config" / "talos" / "personas.toml"

proc loadPersonasSafe*(path: string): PersonaRegistry =
  ## Loads personas with a malformed file surfacing as a clean CLI error
  ## (matching how ConfigError is handled) instead of an unhandled stack
  ## trace. Triggers: a TOML syntax error, or a duplicate persona name
  ## (names are case-insensitive, so [personas.Foo] + [personas.foo]
  ## collides). A missing file is fine — personas are optional.
  try:
    if fileExists(path): loadPersonasFile(path)
    else: newPersonaRegistry()
  except PersonaError as e:
    printError("personas: " & e.msg)
    quit(2)

# ---------------------------------------------------------------------------
# Input
# ---------------------------------------------------------------------------

proc readLine*(prompt: string): tuple[line: string, eof: bool] =
  ## Reads a single line of input. Returns `(text, eof=true)` on EOF.
  stdout.write(prompt)
  stdout.flushFile()
  try:
    let line = stdin.readLine()
    return (line, false)
  except EOFError:
    return ("", true)
  except IOError:
    return ("", true)

proc isExitCommand*(line: string): bool =
  let s = line.strip().toLowerAscii()
  s in [":q", ":quit", ":exit", "/quit", "/exit", "exit", "quit"]

# ---------------------------------------------------------------------------
# Recent-sessions listing
# ---------------------------------------------------------------------------

type
  SessionSummary* = object
    id*: string
    createdAt*: string
    updatedAt*: string
    messageCount*: int

proc listRecentSessions*(dbPath: string; limit: int = 20): seq[SessionSummary] =
  ## Returns up to `limit` most-recently-updated sessions. Returns an
  ## empty seq if the DB does not yet exist (no prior runs).
  result = @[]
  if not fileExists(dbPath):
    return
  let db = open(dbPath, "", "", "")
  defer: db.close()
  for row in db.fastRows(sql"""
    SELECT s.id, s.created_at, s.updated_at,
           (SELECT COUNT(*) FROM messages m WHERE m.session_id = s.id)
    FROM sessions s
    ORDER BY s.updated_at DESC
    LIMIT ?
  """, $limit):
    result.add(SessionSummary(
      id: row[0],
      createdAt: row[1],
      updatedAt: row[2],
      messageCount: parseInt(row[3]),
    ))

proc sessionExists*(dbPath, sessionId: string): bool =
  ## True if a session with the given id exists in the DB at `dbPath`.
  if not fileExists(dbPath):
    return false
  let db = open(dbPath, "", "", "")
  defer: db.close()
  let row = db.getRow(
    sql"SELECT id FROM sessions WHERE id = ?", sessionId)
  return row[0].len > 0
