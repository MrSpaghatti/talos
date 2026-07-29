## One-off live integration check: connects Talos's real McpStreamingClient
## (talos_core/mcp_client.nim, Phase 6 / task-07-mcp-streaming.md) to a real,
## independently-implemented MCP server — the official
## @modelcontextprotocol/server-everything reference server running in SSE
## mode — and confirms genuine wire-level interop, not just interop with
## Talos's own hand-written mocks.
##
## Run manually (needs the reference server running — see below):
##   npx -y @modelcontextprotocol/server-everything sse &
##   nim c --path:/home/spag/talos_core/src --path:src -r scripts/live_mcp_sse_test.nim
##
## This machine's loopback networking works fine inside the agent sandbox
## (only external DNS/egress is blocked), so this one *is* run directly
## rather than handed to the user, unlike scripts/eval_embeddings.nim.

import std/[asyncdispatch, strutils]
import talos_core/mcp_client

var gotEndpoint = false
var gotAnyEvent = false
var eventLog: seq[string] = @[]

proc onEvent(e: McpSseEvent) {.gcsafe, raises: [].} =
  {.cast(gcsafe).}:
    gotAnyEvent = true
    eventLog.add(e.eventType & ": " & e.data)
    if e.eventType == "endpoint":
      gotEndpoint = true

proc main() {.async.} =
  let client = newMcpStreamingClient("http://localhost:3001/sse", onEvent = onEvent)
  echo "Connecting to real MCP reference server (server-everything, sse mode)..."
  let completed = await client.listen().withTimeout(4000)
  client.stop()

  echo "\n--- results ---"
  echo "events received: ", eventLog.len
  for line in eventLog:
    echo "  ", line[0 ..< min(120, line.len)]
  echo "got 'endpoint' event (server-initiated, real SSE framing): ", gotEndpoint
  echo "listen() completed within timeout (didn't hang): ", completed

  if gotEndpoint:
    echo "\nPASS: real SSE event stream parsed and dispatched correctly."
  else:
    echo "\nFAIL: expected an 'endpoint' event from the real server."
    quit(1)

waitFor main()
