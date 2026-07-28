## Cross-surface session aliasing.
##
## Lets a conversation started on one surface (CLI, TUI, Discord) be
## picked up on another by a shared human-readable name instead of a raw
## session ID, so it doesn't have to cold-start. Generalizes the same
## idea thread_mapping.nim already uses for Discord-thread continuity
## (an ID -> session_id lookup) into something any surface can use.
##
## Lives in the same SQLite file as memory/thread_mapping (cfg.dbPath) —
## each caller opens its own short-lived connection, matching the pattern
## thread_mapping.nim's callers already use.

import db_connector/db_sqlite
import std/[options, strutils]
import talos_core/util

proc initSessionAliasSchema*(db: DbConn) =
  ## Creates the session_aliases table if it does not already exist.
  ## Safe to call multiple times (idempotent).
  db.exec(sql"""
    CREATE TABLE IF NOT EXISTS session_aliases (
      alias           TEXT PRIMARY KEY,
      session_id      TEXT NOT NULL,
      created_at      TEXT NOT NULL,
      last_active_at  TEXT NOT NULL
    )
  """)

proc setSessionAlias*(db: DbConn; alias, sessionId: string) =
  ## Upserts an alias -> session mapping. If the alias already exists,
  ## repoints it at the given session and refreshes last_active_at.
  let ts = nowIso()
  db.exec(sql"""
    INSERT INTO session_aliases (alias, session_id, created_at, last_active_at)
    VALUES (?, ?, ?, ?)
    ON CONFLICT(alias) DO UPDATE SET
      session_id = excluded.session_id,
      last_active_at = excluded.last_active_at
  """, alias, sessionId, ts, ts)

proc getSessionForAlias*(db: DbConn; alias: string): Option[string] =
  ## Returns the session ID aliased by `alias`, or None if unknown.
  let row = db.getRow(sql"""
    SELECT session_id FROM session_aliases WHERE alias = ?
  """, alias)
  if row.len == 0 or row[0].len == 0:
    return none[string]()
  return some(row[0])

proc touchSessionAlias*(db: DbConn; alias: string) =
  ## Refreshes last_active_at for an existing alias. No-op if unknown.
  db.exec(sql"""
    UPDATE session_aliases SET last_active_at = ? WHERE alias = ?
  """, nowIso(), alias)

proc listSessionAliases*(db: DbConn): seq[tuple[alias, sessionId, lastActiveAt: string]] =
  ## Lists all aliases, most recently active first.
  result = @[]
  for row in db.fastRows(sql"""
    SELECT alias, session_id, last_active_at FROM session_aliases
    ORDER BY last_active_at DESC
  """):
    result.add (row[0], row[1], row[2])

proc removeSessionAlias*(db: DbConn; alias: string) =
  db.exec(sql"DELETE FROM session_aliases WHERE alias = ?", alias)

# ---------------------------------------------------------------------------
# Text-command handler
# ---------------------------------------------------------------------------
# Kept here (not in a surface-specific module) so any surface — Discord's
# !alias, a future CLI subcommand, etc. — can drive it with plain strings
# and no dependency on that surface's own types.

proc handleAliasCommand*(db: DbConn; args: string;
                          currentSessionId: Option[string]): string =
  ## Handles `<prefix>alias <set|show|clear> [name]`. `currentSessionId`,
  ## if given, is the session the *caller* is presently in (e.g. a
  ## Discord thread's mapped session) — used by `set` to know what to
  ## alias, since a name always points at a specific session, not a
  ## surface.
  initSessionAliasSchema(db)
  let parts = args.splitWhitespace(maxsplit = 1)
  if parts.len == 0 or parts[0].len == 0:
    return "Usage: alias <set|show|clear> [name]"
  let subcmd = parts[0].toLowerAscii()
  case subcmd
  of "set":
    if parts.len < 2 or parts[1].strip().len == 0:
      return "Usage: alias set <name>"
    if currentSessionId.isNone:
      return "No active session here yet — talk to me first, then alias it."
    let name = parts[1].strip()
    setSessionAlias(db, name, currentSessionId.get())
    return "Aliased this conversation as '" & name &
      "' — resume it from another surface with --alias " & name & "."
  of "show":
    if parts.len < 2 or parts[1].strip().len == 0:
      let aliases = listSessionAliases(db)
      if aliases.len == 0:
        return "No aliases set."
      var lines: seq[string] = @[]
      for a in aliases:
        lines.add(a.alias & " -> " & a.sessionId)
      return lines.join("\n")
    let name = parts[1].strip()
    let sid = getSessionForAlias(db, name)
    if sid.isNone:
      return "No such alias: " & name
    return name & " -> " & sid.get()
  of "clear":
    if parts.len < 2 or parts[1].strip().len == 0:
      return "Usage: alias clear <name>"
    let name = parts[1].strip()
    removeSessionAlias(db, name)
    return "Cleared alias '" & name & "'."
  else:
    return "Unknown alias subcommand: " & subcmd & " (try set|show|clear)"
