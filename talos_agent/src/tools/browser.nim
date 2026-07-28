## Talos browser tool.
##
## Loads a URL in a real, headless Chrome/Chromium instance (via the Chrome
## DevTools Protocol, through the `cdp` package) and returns the page's
## title and visible text. Unlike a plain HTTP fetch, this runs the page's
## JavaScript, so client-side-rendered pages actually have content by the
## time we read them.
##
## Each call launches a fresh, isolated browser instance (its own
## `--user-data-dir`) and tears it down unconditionally when done — no
## persistent browser process to manage or leak state across calls.
##
## Out of scope (deferred):
##   - Screenshots / visual output
##   - Clicking, scrolling, form-filling (multi-step interaction)
##   - Cookie/session persistence across calls

import std/[json, asyncdispatch, os, strutils, times]
import cdp
import talos_core/tool_registry
import talos_core/acl
import talos_core/permission

const
  DefaultBrowserTimeoutMs* = 20_000
  MaxBrowserTimeoutMs* = 60_000
  DefaultMaxTextChars* = 20_000
    ## Hard cap on returned page text — same spirit as shell.nim's
    ## maxOutputBytes, so one huge page can't blow out the LLM's context.

type
  BrowserOptions* = object
    timeoutMs*: int
    maxTextChars*: int

  PageLoadResult = object
    title: string
    text: string
    ok: bool
    err: string

proc defaultBrowserOptions*(): BrowserOptions =
  BrowserOptions(timeoutMs: DefaultBrowserTimeoutMs, maxTextChars: DefaultMaxTextChars)

# ---------------------------------------------------------------------------
# Schema
# ---------------------------------------------------------------------------

proc browserParametersSchema*(): JsonNode =
  %*{
    "type": "object",
    "properties": {
      "url": {
        "type": "string",
        "description": "The http:// or https:// URL to load.",
      },
      "timeoutMs": {
        "type": "integer",
        "description": "Optional per-call page-load timeout override, in milliseconds.",
      },
    },
    "required": ["url"],
  }

proc isHttpUrl(url: string): bool =
  url.startsWith("http://") or url.startsWith("https://")

# ---------------------------------------------------------------------------
# Page loading
# ---------------------------------------------------------------------------

proc loadPageAsync(url: string): Future[PageLoadResult] {.async.} =
  let userDataDir = getTempDir() / ("talos_browser_" & $getCurrentProcessId() &
                                     "_" & $getTime().toUnix() & "_" & $getTime().nanosecond)
  let browser =
    try:
      # cdp's launcher treats ANY stray line of Chrome's own stdout/stderr
      # before "DevTools listening" as a fatal launch error — including
      # harmless GPU/Vulkan capability warnings that headless Chrome
      # prints on plenty of real machines (e.g. software/virtual GPUs).
      # These flags keep Chrome from touching the GPU at all so there's
      # nothing to warn about.
      await launchBrowser(userDataDir = userDataDir, chromeArguments = @[
        "--disable-gpu",
        "--disable-software-rasterizer",
        "--disable-dev-shm-usage",
      ])
    except CatchableError as e:
      return PageLoadResult(ok: false, err: "browser: failed to launch: " & e.msg)
  try:
    let tab = await browser.newTab()
    await tab.enablePageDomain()
    discard await tab.navigate(url)
    discard await browser.waitForSessionEvent(tab.sessionId, $Page.domContentEventFired)
    let titleResp = await tab.evaluate("document.title", %*{"returnByValue": true})
    let textResp = await tab.evaluate(
      "document.body ? document.body.innerText : ''",
      %*{"returnByValue": true})
    let title = titleResp{"result"}{"result"}{"value"}.getStr("")
    let text = textResp{"result"}{"result"}{"value"}.getStr("")
    result = PageLoadResult(title: title, text: text, ok: true)
  except CatchableError as e:
    result = PageLoadResult(ok: false, err: "browser: " & e.msg)
  finally:
    try:
      await browser.close()
    except CatchableError:
      discard

proc loadPage(url: string; timeoutMs, maxTextChars: int): PageLoadResult =
  ## Synchronous wrapper: launches the browser, navigates, extracts
  ## title/text, and tears it down — all within `timeoutMs` (the browser is
  ## still closed on timeout via loadPageAsync's `finally`, since the async
  ## proc keeps running to completion in the background even after
  ## `withTimeout` gives up waiting on it).
  let fut = loadPageAsync(url)
  if not waitFor fut.withTimeout(timeoutMs):
    return PageLoadResult(ok: false,
      err: "browser: page load timed out after " & $timeoutMs & "ms")
  if fut.failed:
    return PageLoadResult(ok: false, err: "browser: " & fut.error.msg)
  result = fut.read()
  if result.ok and result.text.len > maxTextChars:
    result.text = result.text[0 ..< maxTextChars] & "\n... [truncated]"

# ---------------------------------------------------------------------------
# Tool wiring
# ---------------------------------------------------------------------------

proc makeBrowserExecuteProc(opts: BrowserOptions): ToolExecuteProc =
  result = proc (args: JsonNode): ToolResult {.gcsafe.} =
    {.cast(gcsafe).}:
      let url =
        if not args.isNil and args.kind == JObject: args{"url"}.getStr("")
        else: ""
      if url.len == 0:
        return ToolResult(output: "browser: 'url' argument is required", isError: true)
      if not isHttpUrl(url):
        return ToolResult(
          output: "browser: only http:// and https:// URLs are supported",
          isError: true)

      var localOpts = opts
      if not args.isNil and args.kind == JObject:
        let t = args{"timeoutMs"}.getInt(0)
        if t > 0:
          localOpts.timeoutMs = min(t, MaxBrowserTimeoutMs)

      let loaded =
        try:
          loadPage(url, localOpts.timeoutMs, localOpts.maxTextChars)
        except CatchableError as e:
          PageLoadResult(ok: false, err: "browser: internal error: " & e.msg)

      if not loaded.ok:
        return ToolResult(output: loaded.err, isError: true)
      return ToolResult(
        output: "Title: " & loaded.title & "\n\n" & loaded.text,
        isError: false)

proc browserTool*(opts: BrowserOptions = defaultBrowserOptions()): Tool =
  ## Builds a `Tool` value for the browser tool. Register it with a
  ## `ToolRegistry` to expose it to the LLM.
  newTool(
    name = "browser",
    description = "Load a URL in a real headless Chrome instance (full " &
      "JavaScript rendering) and return the page's title and visible " &
      "text. Use for pages a plain HTTP fetch can't render.",
    parameters = browserParametersSchema(),
    execute = makeBrowserExecuteProc(opts),
  )

proc browserTool*(opts: BrowserOptions, acl: ToolAcl): Tool =
  ## Permission-gated variant for contexts with a real caller identity
  ## (the Discord daemon and its delegation children) — mirrors
  ## `tools/shell.shellTool(opts, acl)`. Reads the reserved `_callerId`
  ## argument the agent loop injects into every tool call and consults
  ## `canUseTool` before ever launching a browser.
  let inner = makeBrowserExecuteProc(opts)
  let gated = proc (args: JsonNode): ToolResult {.gcsafe, raises: [].} =
    let callerId =
      if not args.isNil and args.kind == JObject: args{"_callerId"}.getStr("")
      else: ""
    let perm = try: canUseTool(callerId, "browser", acl)
               except CatchableError:
                 return ToolResult(output: "browser: permission check failed",
                                   isError: true)
    case perm
    of pdDeny:
      return ToolResult(output: "browser: access denied for this user",
                        isError: true)
    of pdAsk:
      return ToolResult(
        output: "browser: requires approval — ask an admin, or add " &
                "'browser' to the tools allow-list",
        isError: true)
    of pdAllow:
      try:
        return inner(args)
      except CatchableError as e:
        return ToolResult(output: "browser: internal error: " & e.msg,
                          isError: true)
      except Exception as e:
        return ToolResult(output: "browser: internal error: " & e.msg,
                          isError: true)
  newTool(
    name = "browser",
    description = "Load a URL in a real headless Chrome instance (full " &
      "JavaScript rendering) and return the page's title and visible " &
      "text. Use for pages a plain HTTP fetch can't render.",
    parameters = browserParametersSchema(),
    execute = gated,
  )
