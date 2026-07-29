## Tests for tools/memory_tools.nim (retain/recall/reflect)
##
## Uses an in-memory Memory store and a mock embeddings/LLM HTTP server so
## no real network calls happen. Mirrors the mock-server pattern from
## talos_core's tembeddings.nim/tllm_client.nim tests.

import std/[json, unittest, strutils]
import talos_core/tool_registry
import talos_core/acl
import talos_core/memory
import talos_core/embeddings
import talos_core/llm_client
import talos_core/testkit/mock_llm_server
import tools/memory_tools

const EmbedBody = """
{"data": [{"embedding": [1.0, 0.0], "index": 0}], "usage": {"total_tokens": 3}}
"""

const ChatBody = """
{
  "id": "chatcmpl-mock",
  "object": "chat.completion",
  "model": "test-model",
  "choices": [{
    "index": 0,
    "message": {"role": "assistant", "content": "Synthesized answer."},
    "finish_reason": "stop"
  }]
}
"""

var sharedServer = startMockServer()

proc makeOpts(): MemoryToolOptions =
  let embedClient = newEmbeddingClient(
    baseUrl = baseUrlFor(sharedServer), apiKey = "k",
    model = "test-embed-model", maxRetries = 1)
  let llm = newLLMClient(
    baseUrl = baseUrlFor(sharedServer), apiKey = "k",
    model = "test-model", maxRetries = 1)
  newMemoryToolOptions(newMemory(":memory:"), embedClient, llm)

suite "retain tool":
  setup:
    resetMock(sharedServer)

  test "missing content is rejected":
    let tool = retainTool(makeOpts())
    let res = tool.execute(%*{})
    check res.isError
    check "'content'" in res.output

  test "successful retain embeds and stores, returns an id":
    sharedServer.enqueue("200 OK", EmbedBody)
    let opts = makeOpts()
    let tool = retainTool(opts)
    let res = tool.execute(%*{"content": "the sky is blue"})
    check not res.isError
    check "retained fact #" in res.output
    check opts.mem.listRetainedFacts().len == 1

  test "embedding failure is reported as a tool error":
    sharedServer.enqueue("500 Internal Server Error", """{"error": {"message": "boom"}}""")
    let tool = retainTool(makeOpts())
    let res = tool.execute(%*{"content": "x"})
    check res.isError

suite "retain tool: gated variant":
  setup:
    resetMock(sharedServer)

  proc acl(admins: seq[string] = @[]): ToolAcl =
    ToolAcl(admins: AccessControl(allow: admins))

  test "unlisted caller is denied before any embedding call":
    let tool = retainTool(makeOpts(), acl())
    let res = tool.execute(%*{"content": "x", "_callerId": "stranger"})
    check res.isError
    check "denied" in res.output
    check sharedServer.requestCount == 0

  test "missing _callerId fails closed":
    let tool = retainTool(makeOpts(), acl(admins = @["admin1"]))
    let res = tool.execute(%*{"content": "x"})
    check res.isError

  test "admin caller reaches the real retain path":
    sharedServer.enqueue("200 OK", EmbedBody)
    let opts = makeOpts()
    let tool = retainTool(opts, acl(admins = @["admin1"]))
    let res = tool.execute(%*{"content": "x", "_callerId": "admin1"})
    check not res.isError
    check opts.mem.listRetainedFacts().len == 1

suite "recall tool":
  setup:
    resetMock(sharedServer)

  test "missing query is rejected":
    let tool = recallTool(makeOpts())
    let res = tool.execute(%*{})
    check res.isError
    check "'query'" in res.output

  test "recall with no retained facts returns a clear empty message":
    sharedServer.enqueue("200 OK", EmbedBody)
    let tool = recallTool(makeOpts())
    let res = tool.execute(%*{"query": "anything"})
    check not res.isError
    check "no matching retained facts" in res.output

  test "recall finds a previously retained fact":
    let opts = makeOpts()
    sharedServer.enqueue("200 OK", EmbedBody)
    discard retainTool(opts).execute(%*{"content": "the sky is blue"})
    sharedServer.enqueue("200 OK", EmbedBody)
    let res = recallTool(opts).execute(%*{"query": "sky color"})
    check not res.isError
    check "the sky is blue" in res.output

suite "reflect tool":
  setup:
    resetMock(sharedServer)

  test "missing query is rejected":
    let tool = reflectTool(makeOpts())
    let res = tool.execute(%*{})
    check res.isError
    check "'query'" in res.output

  test "reflect with no retained facts skips the LLM call":
    sharedServer.enqueue("200 OK", EmbedBody)
    let tool = reflectTool(makeOpts())
    let res = tool.execute(%*{"query": "anything"})
    check not res.isError
    check "No retained facts" in res.output
    check sharedServer.requestCount == 1  # embedding only, no chat call

  test "reflect synthesizes an answer from recalled facts":
    let opts = makeOpts()
    sharedServer.enqueue("200 OK", EmbedBody)
    discard retainTool(opts).execute(%*{"content": "the sky is blue"})
    sharedServer.enqueue("200 OK", EmbedBody)
    sharedServer.enqueue("200 OK", ChatBody)
    let res = reflectTool(opts).execute(%*{"query": "what color is the sky"})
    check not res.isError
    check res.output == "Synthesized answer."
