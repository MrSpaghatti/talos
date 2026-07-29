## Tests for talos_agent CLI helpers (talos_agent.nim).
##
## These tests exercise the pieces of the CLI that don't require a live
## LLM endpoint:
##   - Config-override layering
##   - Sqlite-backed session listing / lookup
##   - The sessions and search subcommand entry points against an empty
##     fresh database
##
## Subcommands that talk to an LLM (`chat`, `ask`, `session`) are not
## covered here — `tagent_loop.nim` already exercises that path via the
## mock server. We instead make sure dispatch and option-parsing wiring
## is correct by invoking the dedicated proc entry points.

import std/[os, osproc, strutils, times, unittest]

import talos_core/config
import talos_core/llm_client
import talos_core/memory
import talos_agent

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc tempDbPath(): string =
  ## Returns a unique writable path for a fresh sqlite db. Files are
  ## removed in `teardownDb`.
  result = getTempDir() / ("talos_cli_test_" & $getCurrentProcessId() &
                           "_" & $epochTime() & ".db")
  if fileExists(result):
    removeFile(result)

proc teardownDb(path: string) =
  ## Removes any sqlite/WAL artifacts left around by the test.
  for suffix in ["", "-wal", "-shm", "-journal"]:
    let p = path & suffix
    if fileExists(p):
      try: removeFile(p) except CatchableError: discard

proc minimalCfg(dbPath: string): TalosConfig =
  ## Builds a self-contained TalosConfig that does not need a config
  ## file or env vars.
  result = defaultConfig()
  result.dbPath = dbPath
  result.openrouterApiKey = "test-key"

proc seedSession(dbPath, content: string): string =
  ## Creates one session with one user message in a fresh memory db
  ## and returns the session id.
  var mem = newMemory(dbPath)
  defer: mem.close()
  let sid = mem.newSession()
  let msg = ChatMessage(role: crUser, content: content)
  mem.appendMessage(sid, msg)
  return sid

proc captureStdout(body: proc(): int): tuple[rc: int; output: string] =
  ## Redirects the process-wide `stdout` handle to a temp file for the
  ## duration of `body`, so tests can assert on what a CLI command
  ## actually prints to the user, not just its exit code.
  let path = getTempDir() / ("talos_cli_stdout_" & $getCurrentProcessId() &
                             "_" & $epochTime() & ".txt")
  let capture = open(path, fmWrite)
  let realStdout = stdout
  stdout = capture
  var rc: int
  try:
    rc = body()
  finally:
    stdout = realStdout
    capture.close()
  result = (rc, readFile(path))
  try: removeFile(path) except CatchableError: discard

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

suite "cli: applyOverrides":
  test "empty overrides leave config untouched":
    var cfg = defaultConfig()
    let before = cfg
    applyOverrides(cfg, emptyOverrides())
    check cfg.provider == before.provider
    check cfg.openrouterModel == before.openrouterModel
    check cfg.vllmModel == before.vllmModel
    check cfg.temperature == before.temperature

  test "model override applies to the active provider":
    var cfg = defaultConfig()
    cfg.provider = "openrouter"
    var ov = emptyOverrides()
    ov.model = "openrouter/mock"
    applyOverrides(cfg, ov)
    check cfg.openrouterModel == "openrouter/mock"
    # vllmModel is *not* changed when openrouter is active.
    check cfg.vllmModel == DefaultVllmModel

  test "model override targets vllmModel when provider=vllm":
    var cfg = defaultConfig()
    cfg.provider = "vllm"
    var ov = emptyOverrides()
    ov.model = "qwen-mock"
    applyOverrides(cfg, ov)
    check cfg.vllmModel == "qwen-mock"
    check cfg.openrouterModel == DefaultOpenrouterModel

  test "provider override switches active provider":
    var cfg = defaultConfig()
    var ov = emptyOverrides()
    ov.provider = "vllm"
    applyOverrides(cfg, ov)
    check cfg.provider == "vllm"

  test "temperature override only applies when explicitly set":
    var cfg = defaultConfig()
    cfg.temperature = 0.7
    var ov = emptyOverrides()
    applyOverrides(cfg, ov)
    check cfg.temperature == 0.7
    ov.hasTemperature = true
    ov.temperature = 0.1
    applyOverrides(cfg, ov)
    check cfg.temperature == 0.1

suite "cli: loadConfigWithOverrides":
  test "applies env-based overrides on top of defaults":
    putEnv("TALOS_PROVIDER", "openrouter")
    putEnv("OPENROUTER_API_KEY", "fake-key")
    defer:
      delEnv("TALOS_PROVIDER")
      delEnv("OPENROUTER_API_KEY")

    var ov = emptyOverrides()
    ov.envPath = "/dev/null"
    ov.model = "openrouter/test-model"
    let cfg = loadConfigWithOverrides(ov)
    check cfg.provider == "openrouter"
    check cfg.openrouterModel == "openrouter/test-model"
    check cfg.openrouterApiKey == "fake-key"

  test "rejects an invalid provider override":
    putEnv("OPENROUTER_API_KEY", "fake-key")
    defer: delEnv("OPENROUTER_API_KEY")
    var ov = emptyOverrides()
    ov.envPath = "/dev/null"
    ov.provider = "definitely-not-real"
    expect ConfigError:
      discard loadConfigWithOverrides(ov)

  test "rejects an out-of-range temperature":
    putEnv("OPENROUTER_API_KEY", "fake-key")
    defer: delEnv("OPENROUTER_API_KEY")
    var ov = emptyOverrides()
    ov.envPath = "/dev/null"
    ov.hasTemperature = true
    ov.temperature = 3.5
    expect ConfigError:
      discard loadConfigWithOverrides(ov)

suite "cli: resolveDbPath":
  test "expands a leading tilde to the home directory":
    var cfg = defaultConfig()
    cfg.dbPath = "~/.local/share/talos/test.db"
    let resolved = resolveDbPath(cfg)
    check not resolved.startsWith("~")
    check resolved.endsWith("/.local/share/talos/test.db")

  test "leaves an absolute path alone":
    var cfg = defaultConfig()
    let absPath = getTempDir() / "talos_cli_test_abs_" & $getCurrentProcessId() & ".db"
    cfg.dbPath = absPath
    let resolved = resolveDbPath(cfg)
    check resolved == absPath
    defer: teardownDb(absPath)

suite "cli: listRecentSessions":
  test "returns empty seq when the db file does not exist":
    let path = "/tmp/talos_cli_does_not_exist_" & $epochTime() & ".db"
    check listRecentSessions(path).len == 0

  test "lists most-recently-updated sessions in descending order":
    let path = tempDbPath()
    defer: teardownDb(path)

    # Sessions are ordered by `updated_at` (ISO seconds), so we space
    # them out by >1s to avoid same-second tiebreaker ambiguity.
    let s1 = seedSession(path, "first")
    sleep(1100)
    let s2 = seedSession(path, "second")
    sleep(1100)
    let s3 = seedSession(path, "third")

    let listed = listRecentSessions(path, limit = 10)
    check listed.len == 3
    check listed[0].id == s3
    check listed[1].id == s2
    check listed[2].id == s1
    for s in listed:
      check s.messageCount == 1
      check s.updatedAt.len > 0

  test "respects the limit parameter":
    let path = tempDbPath()
    defer: teardownDb(path)
    discard seedSession(path, "a")
    sleep(5)
    discard seedSession(path, "b")
    sleep(5)
    discard seedSession(path, "c")

    let listed = listRecentSessions(path, limit = 2)
    check listed.len == 2

suite "cli: sessionExists":
  test "returns false for a missing db":
    check not sessionExists(
      "/tmp/talos_cli_missing_" & $epochTime() & ".db",
      "sess_anything")

  test "returns true only for ids that actually exist":
    let path = tempDbPath()
    defer: teardownDb(path)
    let sid = seedSession(path, "hello")
    check sessionExists(path, sid)
    check not sessionExists(path, "sess_does_not_exist")

suite "cli: cmdSessions and cmdSearch on a fresh db":
  test "history prints 'no sessions yet' to the user when the db is empty":
    let path = tempDbPath()
    defer: teardownDb(path)
    putEnv("TALOS_DB_PATH", path)
    putEnv("OPENROUTER_API_KEY", "dummy")
    defer:
      delEnv("TALOS_DB_PATH")
      delEnv("OPENROUTER_API_KEY")
    let (rc, output) = captureStdout(proc(): int = cmdSessions(envFile = "/dev/null"))
    check rc == 0
    check "no sessions yet" in output

  test "history prints the seeded session's id in the table it shows the user":
    let path = tempDbPath()
    defer: teardownDb(path)
    let sid = seedSession(path, "alpha bravo")
    putEnv("TALOS_DB_PATH", path)
    putEnv("OPENROUTER_API_KEY", "dummy")
    defer:
      delEnv("TALOS_DB_PATH")
      delEnv("OPENROUTER_API_KEY")
    let (rc, output) = captureStdout(proc(): int = cmdSessions(envFile = "/dev/null"))
    check rc == 0
    check sid in output

  test "search rejects an empty query":
    let path = tempDbPath()
    defer: teardownDb(path)
    putEnv("TALOS_DB_PATH", path)
    putEnv("OPENROUTER_API_KEY", "dummy")
    defer:
      delEnv("TALOS_DB_PATH")
      delEnv("OPENROUTER_API_KEY")
    let rc = cmdSearch(query = @[], envFile = "/dev/null")
    check rc == 2

  test "search with no matches tells the user, and doesn't fabricate a hit":
    let path = tempDbPath()
    defer: teardownDb(path)
    discard seedSession(path, "the quick brown fox")
    putEnv("TALOS_DB_PATH", path)
    putEnv("OPENROUTER_API_KEY", "dummy")
    defer:
      delEnv("TALOS_DB_PATH")
      delEnv("OPENROUTER_API_KEY")
    let (rc, output) = captureStdout(
      proc(): int = cmdSearch(query = @["nonexistent"], envFile = "/dev/null"))
    check rc == 0
    check "no matches" in output

  test "search with a hit prints the matching session and content to the user":
    let path = tempDbPath()
    defer: teardownDb(path)
    let sid = seedSession(path, "the quick brown fox")
    putEnv("TALOS_DB_PATH", path)
    putEnv("OPENROUTER_API_KEY", "dummy")
    defer:
      delEnv("TALOS_DB_PATH")
      delEnv("OPENROUTER_API_KEY")
    let (rc, output) = captureStdout(
      proc(): int = cmdSearch(query = @["quick"], envFile = "/dev/null"))
    check rc == 0
    check sid in output
    check "quick" in output

  test "search --semantic still returns the FTS hit when the embeddings backend is unreachable":
    let path = tempDbPath()
    defer: teardownDb(path)
    let sid = seedSession(path, "the quick brown fox")
    putEnv("TALOS_DB_PATH", path)
    putEnv("OPENROUTER_API_KEY", "dummy")
    # Port 1 refuses connections immediately (nothing listens there) rather
    # than hanging on DNS resolution — keeps this test fast while still
    # exercising searchHybrid's graceful fallback-to-FTS-only path.
    putEnv("TALOS_EMBEDDING_ENDPOINT", "http://127.0.0.1:1")
    defer:
      delEnv("TALOS_DB_PATH")
      delEnv("OPENROUTER_API_KEY")
      delEnv("TALOS_EMBEDDING_ENDPOINT")
    let (rc, output) = captureStdout(
      proc(): int = cmdSearch(query = @["quick"], semantic = true, envFile = "/dev/null"))
    check rc == 0
    check sid in output
    check "[message]" in output

suite "cli: ask and session error handling without a live LLM":
  test "ask requires a question":
    putEnv("OPENROUTER_API_KEY", "dummy")
    defer: delEnv("OPENROUTER_API_KEY")
    check cmdAsk(question = @[], envFile = "/dev/null") == 2

  test "session requires an id":
    putEnv("OPENROUTER_API_KEY", "dummy")
    defer: delEnv("OPENROUTER_API_KEY")
    check cmdSession(id = @[], envFile = "/dev/null") == 2

  test "session reports unknown id without crashing":
    let path = tempDbPath()
    defer: teardownDb(path)
    putEnv("TALOS_DB_PATH", path)
    putEnv("OPENROUTER_API_KEY", "dummy")
    defer:
      delEnv("TALOS_DB_PATH")
      delEnv("OPENROUTER_API_KEY")
    let rc = cmdSession(id = @["sess_made_up"], envFile = "/dev/null")
    check rc == 4

suite "cli: binary smoke test":
  test "the built binary prints a usage banner with --help":
    let bin = currentSourcePath().parentDir().parentDir() / "talos_agent"
    if not fileExists(bin):
      skip()
    else:
      let (output, code) = execCmdEx(bin & " --help")
      check code == 0
      check output.contains("chat")
      check output.contains("ask")
      check output.contains("sessions")
      check output.contains("search")
