## Tests for tools/browser.nim
##
## Two tiers: pure validation logic (no Chrome involved — argument checks
## return before ever touching the browser) and live end-to-end tests that
## launch a real headless Chromium against a local `file://` fixture (no
## network dependency, deterministic content, but still exercises the real
## launch/navigate/evaluate/close pipeline this tool actually depends on).

import std/[json, unittest, strutils, asynchttpserver, asyncdispatch]
import talos_core/tool_registry
import talos_core/acl
import tools/browser

proc startFixtureServer(html: string): AsyncHttpServer =
  ## A tiny local HTTP server serving `html` on every path. Used instead
  ## of a `file://` URL — the browser tool deliberately rejects non-http
  ## schemes (see "non-http(s) url is rejected" below), so a real http://
  ## endpoint is the only way to exercise the live Chrome pipeline without
  ## weakening that guard for tests.
  result = newAsyncHttpServer()
  result.listen(Port(0))
  let srv = result
  proc handler(req: Request) {.async.} =
    await req.respond(Http200, html, newHttpHeaders([("Content-Type", "text/html")]))
  proc loop() {.async.} =
    while true:
      await srv.acceptRequest(handler)
  asyncCheck loop()

suite "browser tool: argument validation (no Chrome needed)":
  test "missing url is rejected":
    let tool = browserTool()
    let res = tool.execute(%*{})
    check res.isError
    check "required" in res.output

  test "non-http(s) url is rejected":
    let tool = browserTool()
    let res = tool.execute(%*{"url": "file:///etc/passwd"})
    check res.isError
    check "http" in res.output

  test "ftp url is rejected":
    let tool = browserTool()
    let res = tool.execute(%*{"url": "ftp://example.com"})
    check res.isError

suite "browser tool: gated variant (no Chrome needed for denial paths)":
  proc acl(admins: seq[string] = @[]): ToolAcl =
    ToolAcl(admins: AccessControl(allow: admins))

  test "unlisted caller is denied before ever launching a browser":
    let tool = browserTool(defaultBrowserOptions(), acl())
    let res = tool.execute(%*{"url": "https://example.com", "_callerId": "stranger"})
    check res.isError
    check "denied" in res.output

  test "missing _callerId fails closed (denied, not silently allowed)":
    let tool = browserTool(defaultBrowserOptions(), acl(admins = @["admin1"]))
    let res = tool.execute(%*{"url": "https://example.com"})
    check res.isError

suite "browser tool: live Chrome (against a local HTTP fixture server)":
  # One server, shared by both tests and never explicitly closed: closing
  # it mid-test races against the async accept loop if a request is still
  # in flight (as it deliberately is in the too-short-timeout case below),
  # producing a spurious "Bad file descriptor" from the dangling future.
  # The process exiting after this test binary finishes reclaims the
  # socket regardless.
  let server = startFixtureServer("""
<!DOCTYPE html>
<html>
<head><title>Talos Browser Test Fixture</title></head>
<body><p>Hello from the browser tool test fixture.</p></body>
</html>
""")
  let port = server.getPort().int

  test "loads a page and extracts its title and text":
    let tool = browserTool()
    let res = tool.execute(
      %*{"url": "http://127.0.0.1:" & $port & "/", "timeoutMs": 15000})
    check not res.isError
    check "Talos Browser Test Fixture" in res.output
    check "Hello from the browser tool test fixture" in res.output

  test "a too-short timeout reports failure rather than hanging forever":
    let tool = browserTool()
    # 1ms can't possibly launch a browser + navigate + evaluate — this
    # proves our own withTimeout guard fires, independent of network
    # conditions or how Chrome happens to handle any particular URL.
    let res = tool.execute(
      %*{"url": "http://127.0.0.1:" & $port & "/", "timeoutMs": 1})
    check res.isError
    check "timed out" in res.output
