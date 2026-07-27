## Tests for talos_agent/web_server.nim
##
## The server under test runs async (asynchttpserver) on the main thread's
## event loop; the mocked LLM backend runs on its own OS thread via
## mock_llm_server (talos_core/llm_client uses a blocking socket client,
## so an async-only mock would deadlock against it — see that module's
## header comment). Test requests use AsyncHttpClient + waitFor so the
## event loop keeps pumping while a chat request's LLM call blocks the
## main thread on the mock server's independent thread.

import std/[asyncdispatch, httpclient, json, os, strutils, unittest]

import talos_core/config
import talos_core/llm_client
import talos_core/tool_registry
import talos_core/memory
import talos_agent/web_server
import talos_core/testkit/mock_llm_server

const SuccessBody = """
{
  "id": "chatcmpl-1",
  "object": "chat.completion",
  "model": "test-model",
  "choices": [{
    "index": 0,
    "message": {"role": "assistant", "content": "hello from web"},
    "finish_reason": "stop"
  }],
  "usage": {"prompt_tokens": 5, "completion_tokens": 3, "total_tokens": 8}
}
"""

proc newTestServer(llmServer: MockServer): WebServer =
  var cfg = defaultConfig()
  cfg.webPort = 0   ## OS-assigned; start() reports the real port back
  result = newWebServer(cfg, makeClient(llmServer), newToolRegistry(), newMemory(":memory:"))

template withServer(ws, body: untyped): untyped =
  waitFor ws.start()
  try:
    body
  finally:
    ws.stop()

suite "web_server routing":
  setup:
    var llmServer = startMockServer()
  teardown:
    stopMockServer(llmServer)

  test "GET / serves index.html":
    let ws = newTestServer(llmServer)
    withServer ws:
      let client = newAsyncHttpClient()
      let resp = waitFor client.get("http://127.0.0.1:" & $ws.port & "/")
      check resp.code == Http200
      client.close()

  test "GET /assets/style.css serves the stylesheet":
    let ws = newTestServer(llmServer)
    withServer ws:
      let client = newAsyncHttpClient()
      let resp = waitFor client.get("http://127.0.0.1:" & $ws.port & "/assets/style.css")
      check resp.code == Http200
      client.close()

  test "GET /assets/../talos_agent.nimble is rejected (path traversal)":
    let ws = newTestServer(llmServer)
    withServer ws:
      let client = newAsyncHttpClient()
      let resp = waitFor client.get(
        "http://127.0.0.1:" & $ws.port & "/assets/..%2Ftalos_agent.nimble")
      check resp.code != Http200
      client.close()

  test "GET /api/sessions returns an empty JSON array on a fresh store":
    let ws = newTestServer(llmServer)
    withServer ws:
      let client = newAsyncHttpClient()
      let resp = waitFor client.get("http://127.0.0.1:" & $ws.port & "/api/sessions")
      check resp.code == Http200
      let body = waitFor resp.body
      check parseJson(body).kind == JArray
      client.close()

  test "GET /api/search without q returns 400":
    let ws = newTestServer(llmServer)
    withServer ws:
      let client = newAsyncHttpClient()
      let resp = waitFor client.get("http://127.0.0.1:" & $ws.port & "/api/search")
      check resp.code == Http400
      client.close()

  test "unknown route returns 404":
    let ws = newTestServer(llmServer)
    withServer ws:
      let client = newAsyncHttpClient()
      let resp = waitFor client.get("http://127.0.0.1:" & $ws.port & "/nope")
      check resp.code == Http404
      client.close()

suite "web_server POST /api/chat":
  setup:
    var llmServer = startMockServer()
  teardown:
    stopMockServer(llmServer)

  test "valid message runs the agent loop and returns its text":
    llmServer.enqueue("200 OK", SuccessBody)
    let ws = newTestServer(llmServer)
    withServer ws:
      let client = newAsyncHttpClient()
      client.headers = newHttpHeaders([("Content-Type", "application/json")])
      let resp = waitFor client.post(
        "http://127.0.0.1:" & $ws.port & "/api/chat", body = $(%*{"message": "hi"}))
      check resp.code == Http200
      let body = waitFor resp.body
      check parseJson(body)["text"].getStr() == "hello from web"
      client.close()

  test "missing message field returns 400":
    let ws = newTestServer(llmServer)
    withServer ws:
      let client = newAsyncHttpClient()
      client.headers = newHttpHeaders([("Content-Type", "application/json")])
      let resp = waitFor client.post(
        "http://127.0.0.1:" & $ws.port & "/api/chat", body = $(%*{}))
      check resp.code == Http400
      client.close()

  test "oversized message (>10KB) returns 400":
    let ws = newTestServer(llmServer)
    withServer ws:
      let client = newAsyncHttpClient()
      client.headers = newHttpHeaders([("Content-Type", "application/json")])
      let huge = "x".repeat(10_001)
      let resp = waitFor client.post(
        "http://127.0.0.1:" & $ws.port & "/api/chat", body = $(%*{"message": huge}))
      check resp.code == Http400
      client.close()

  test "mismatched Origin header is rejected (CSRF)":
    let ws = newTestServer(llmServer)
    withServer ws:
      let client = newAsyncHttpClient()
      client.headers = newHttpHeaders([
        ("Content-Type", "application/json"),
        ("Origin", "http://evil.example"),
      ])
      let resp = waitFor client.post(
        "http://127.0.0.1:" & $ws.port & "/api/chat", body = $(%*{"message": "hi"}))
      check resp.code == Http403
      client.close()

  test "matching same-origin Origin header is accepted":
    llmServer.enqueue("200 OK", SuccessBody)
    let ws = newTestServer(llmServer)
    withServer ws:
      let client = newAsyncHttpClient()
      client.headers = newHttpHeaders([
        ("Content-Type", "application/json"),
        ("Origin", "http://127.0.0.1:" & $ws.port),
      ])
      let resp = waitFor client.post(
        "http://127.0.0.1:" & $ws.port & "/api/chat", body = $(%*{"message": "hi"}))
      check resp.code == Http200
      client.close()

  test "requests beyond the per-client limit get 429":
    let ws = newTestServer(llmServer)
    ws.rateLimitMax = 3
    withServer ws:
      for i in 1 .. 3:
        llmServer.enqueue("200 OK", SuccessBody)
      let client = newAsyncHttpClient()
      client.headers = newHttpHeaders([("Content-Type", "application/json")])
      var lastCode: HttpCode
      var lastBody: string
      for i in 1 .. 4:
        let resp = waitFor client.post(
          "http://127.0.0.1:" & $ws.port & "/api/chat", body = $(%*{"message": "hi"}))
        lastCode = resp.code
        lastBody = waitFor resp.body
      check lastCode == Http429
      check "rate limit" in lastBody
      client.close()
