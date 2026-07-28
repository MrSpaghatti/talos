## Tests for talos_agent/session_alias.nim
##
## All tests use an in-memory SQLite database (:memory:) so no files are
## created on disk and tests are fully isolated.

import std/[unittest, options, os, strutils]
import db_connector/db_sqlite
import talos_agent/session_alias

proc openTestDb(): DbConn =
  let db = open(":memory:", "", "", "")
  initSessionAliasSchema(db)
  return db

suite "initSessionAliasSchema":
  test "creates session_aliases table without error":
    let db = openTestDb()
    defer: db.close()
    let rows = db.getAllRows(sql"SELECT name FROM sqlite_master WHERE type='table' AND name='session_aliases'")
    check rows.len == 1

  test "idempotent — calling twice does not error":
    let db = openTestDb()
    defer: db.close()
    initSessionAliasSchema(db)
    let rows = db.getAllRows(sql"SELECT name FROM sqlite_master WHERE type='table' AND name='session_aliases'")
    check rows.len == 1

suite "setSessionAlias / getSessionForAlias":
  test "unknown alias returns none":
    let db = openTestDb()
    defer: db.close()
    check getSessionForAlias(db, "nope").isNone

  test "set then get round-trips":
    let db = openTestDb()
    defer: db.close()
    setSessionAlias(db, "project-x", "sess_abc")
    check getSessionForAlias(db, "project-x") == some("sess_abc")

  test "setting an existing alias repoints it at the new session":
    let db = openTestDb()
    defer: db.close()
    setSessionAlias(db, "project-x", "sess_abc")
    setSessionAlias(db, "project-x", "sess_def")
    check getSessionForAlias(db, "project-x") == some("sess_def")

suite "listSessionAliases":
  test "empty db returns empty seq":
    let db = openTestDb()
    defer: db.close()
    check listSessionAliases(db).len == 0

  test "lists most recently active first":
    let db = openTestDb()
    defer: db.close()
    setSessionAlias(db, "older", "sess_1")
    sleep(1100)  # ensure different second-level timestamps
    setSessionAlias(db, "newer", "sess_2")
    let aliases = listSessionAliases(db)
    check aliases.len == 2
    check aliases[0].alias == "newer"
    check aliases[1].alias == "older"

  test "touching an alias moves it to the front":
    let db = openTestDb()
    defer: db.close()
    setSessionAlias(db, "a", "sess_a")
    sleep(1100)  # ensure different second-level timestamps
    setSessionAlias(db, "b", "sess_b")
    sleep(1100)
    touchSessionAlias(db, "a")
    let aliases = listSessionAliases(db)
    check aliases[0].alias == "a"

suite "removeSessionAlias":
  test "removes an existing alias":
    let db = openTestDb()
    defer: db.close()
    setSessionAlias(db, "gone-soon", "sess_x")
    removeSessionAlias(db, "gone-soon")
    check getSessionForAlias(db, "gone-soon").isNone

  test "removing an unknown alias is a no-op":
    let db = openTestDb()
    defer: db.close()
    removeSessionAlias(db, "never-existed")  # should not raise

suite "handleAliasCommand":
  test "no subcommand shows usage":
    let db = openTestDb()
    defer: db.close()
    check "Usage" in handleAliasCommand(db, "", none(string))

  test "set with no active session tells the caller to talk first":
    let db = openTestDb()
    defer: db.close()
    let resp = handleAliasCommand(db, "set project-x", none(string))
    check "No active session" in resp
    check getSessionForAlias(db, "project-x").isNone

  test "set with an active session creates the alias":
    let db = openTestDb()
    defer: db.close()
    let resp = handleAliasCommand(db, "set project-x", some("sess_123"))
    check "project-x" in resp
    check getSessionForAlias(db, "project-x") == some("sess_123")

  test "set requires a name":
    let db = openTestDb()
    defer: db.close()
    check "Usage" in handleAliasCommand(db, "set", some("sess_123"))

  test "show with no name lists all aliases":
    let db = openTestDb()
    defer: db.close()
    check "No aliases set" in handleAliasCommand(db, "show", none(string))
    discard handleAliasCommand(db, "set project-x", some("sess_123"))
    let resp = handleAliasCommand(db, "show", none(string))
    check "project-x" in resp
    check "sess_123" in resp

  test "show with a name reports that alias's session":
    let db = openTestDb()
    defer: db.close()
    discard handleAliasCommand(db, "set project-x", some("sess_123"))
    check "sess_123" in handleAliasCommand(db, "show project-x", none(string))

  test "show with an unknown name reports it's unknown":
    let db = openTestDb()
    defer: db.close()
    check "No such alias" in handleAliasCommand(db, "show ghost", none(string))

  test "clear removes the alias":
    let db = openTestDb()
    defer: db.close()
    discard handleAliasCommand(db, "set project-x", some("sess_123"))
    discard handleAliasCommand(db, "clear project-x", none(string))
    check getSessionForAlias(db, "project-x").isNone

  test "unknown subcommand is reported":
    let db = openTestDb()
    defer: db.close()
    check "Unknown alias subcommand" in handleAliasCommand(db, "bogus", none(string))
