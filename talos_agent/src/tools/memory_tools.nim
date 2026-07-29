## Talos retain/recall/reflect tools — explicit long-term memory exposed as
## three tool-registry entries per feature-adoption-report.md §2.1 (the omp
## "Hindsight" shape) instead of one opaque memory tool:
##
##   retain  — durably write a fact and its embedding. This is the *only*
##             path into the semantic store: ordinary chat turns are never
##             auto-embedded, so the store stays curated instead of diluted
##             by routine turns, and embedding cost stays bounded to
##             deliberate "remember this" acts.
##   recall  — raw cosine-similarity search over retained facts. Pure data
##             operation, no LLM call.
##   reflect — recall, then one extra LLM call to synthesize a direct answer
##             from the retrieved facts instead of returning raw matches.
##
## All three sit on top of talos_core/memory.nim's `retained_facts` table
## (brute-force cosine similarity — see that module's docs for why not a
## SQL vector index) and talos_core/embeddings.nim's EmbeddingClient.
##
## retain writes durable state, so it's riskMedium-gated like file_write
## (see permission.getToolRisk) with an ACL-aware variant for Discord.
## recall/reflect are read-only (reflect's LLM call has no destructive
## side effect) and are always registered ungated, matching file_read's
## precedent — risk-gating only applies to the write path.

import std/[json, strutils, strformat]
import talos_core/tool_registry
import talos_core/acl
import talos_core/permission
import talos_core/memory
import talos_core/embeddings
import talos_core/llm_client

type
  MemoryToolOptions* = object
    mem*: Memory
    embeddingClient*: EmbeddingClient
    llmClient*: LLMClient
    defaultTopK*: int
    defaultMinScore*: float32

const
  DefaultRecallTopK* = 5
  MaxRecallTopK* = 20
  DefaultRecallMinScore* = 0.5'f32

  ReflectSystemPrompt* =
    "You are Talos's memory-reflection step. You are given a set of " &
    "previously retained facts (each with a similarity score) and a " &
    "question. Synthesize a concise, direct answer using only the given " &
    "facts — do not invent anything beyond them. If the facts don't " &
    "actually answer the question, say so plainly instead of guessing."

proc newMemoryToolOptions*(
    mem: Memory;
    embeddingClient: EmbeddingClient;
    llmClient: LLMClient;
    defaultTopK: int = DefaultRecallTopK;
    defaultMinScore: float32 = DefaultRecallMinScore;
): MemoryToolOptions =
  MemoryToolOptions(
    mem: mem,
    embeddingClient: embeddingClient,
    llmClient: llmClient,
    defaultTopK: defaultTopK,
    defaultMinScore: defaultMinScore,
  )

# ---------------------------------------------------------------------------
# Schemas
# ---------------------------------------------------------------------------

proc retainParametersSchema*(): JsonNode =
  %*{
    "type": "object",
    "properties": {
      "content": {
        "type": "string",
        "description": "The fact to durably remember, in plain language.",
      },
    },
    "required": ["content"],
  }

proc recallParametersSchema*(): JsonNode =
  %*{
    "type": "object",
    "properties": {
      "query": {
        "type": "string",
        "description": "What to search retained memory for.",
      },
      "topK": {
        "type": "integer",
        "description": "Max number of matches to return (default 5, max 20).",
      },
    },
    "required": ["query"],
  }

proc reflectParametersSchema*(): JsonNode =
  %*{
    "type": "object",
    "properties": {
      "query": {
        "type": "string",
        "description": "The question to answer using retained memory.",
      },
      "topK": {
        "type": "integer",
        "description": "Max number of retained facts to consider (default 5, max 20).",
      },
    },
    "required": ["query"],
  }

# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------

proc extractQuery(args: JsonNode; key: string): string =
  if not args.isNil and args.kind == JObject: args{key}.getStr("")
  else: ""

proc extractTopK(args: JsonNode; default, cap: int): int =
  result = default
  if not args.isNil and args.kind == JObject:
    let t = args{"topK"}.getInt(0)
    if t > 0:
      result = min(t, cap)

proc formatMatches(matches: seq[RetainedFactMatch]): string =
  if matches.len == 0:
    return "(no matching retained facts)"
  var lines: seq[string] = @[]
  for i, m in matches:
    lines.add(&"{i+1}. (score {m.score:.3f}, retained {m.createdAt}) {m.content}")
  lines.join("\n")

# ---------------------------------------------------------------------------
# retain
# ---------------------------------------------------------------------------

proc makeRetainExecuteProc(opts: MemoryToolOptions): ToolExecuteProc =
  result = proc (args: JsonNode): ToolResult {.gcsafe.} =
    {.cast(gcsafe).}:
      let content = extractQuery(args, "content")
      if content.len == 0:
        return ToolResult(output: "retain: 'content' argument is required", isError: true)
      try:
        let emb = opts.embeddingClient.getEmbedding(content)
        let id = opts.mem.retainFact(content, emb.vector, opts.embeddingClient.model)
        return ToolResult(output: "retained fact #" & $id, isError: false)
      except CatchableError as e:
        return ToolResult(output: "retain: failed to embed/store fact: " & e.msg, isError: true)

proc retainTool*(opts: MemoryToolOptions): Tool =
  newTool(
    name = "retain",
    description = "Durably remember a fact for future semantic recall. " &
      "This is the only way facts enter long-term memory — ordinary " &
      "conversation is not auto-remembered, so only call this for things " &
      "genuinely worth keeping.",
    parameters = retainParametersSchema(),
    execute = makeRetainExecuteProc(opts),
  )

proc retainTool*(opts: MemoryToolOptions, acl: ToolAcl): Tool =
  ## Permission-gated variant for contexts with a real caller identity
  ## (the Discord daemon) — mirrors tools/shell.shellTool(opts, acl).
  let inner = makeRetainExecuteProc(opts)
  let gated = proc (args: JsonNode): ToolResult {.gcsafe, raises: [].} =
    let callerId =
      if not args.isNil and args.kind == JObject: args{"_callerId"}.getStr("")
      else: ""
    let perm = try: canUseTool(callerId, "retain", acl)
               except CatchableError:
                 return ToolResult(output: "retain: permission check failed", isError: true)
    case perm
    of pdDeny:
      return ToolResult(output: "retain: access denied for this user", isError: true)
    of pdAsk:
      return ToolResult(
        output: "retain: requires approval — ask an admin, or add " &
                "'retain' to the tools allow-list",
        isError: true)
    of pdAllow:
      try:
        return inner(args)
      except CatchableError as e:
        return ToolResult(output: "retain: internal error: " & e.msg, isError: true)
      except Exception as e:
        return ToolResult(output: "retain: internal error: " & e.msg, isError: true)
  newTool(
    name = "retain",
    description = "Durably remember a fact for future semantic recall. " &
      "This is the only way facts enter long-term memory — ordinary " &
      "conversation is not auto-remembered, so only call this for things " &
      "genuinely worth keeping.",
    parameters = retainParametersSchema(),
    execute = gated,
  )

# ---------------------------------------------------------------------------
# recall
# ---------------------------------------------------------------------------

proc recallTool*(opts: MemoryToolOptions): Tool =
  let exec = proc (args: JsonNode): ToolResult {.gcsafe.} =
    {.cast(gcsafe).}:
      let query = extractQuery(args, "query")
      if query.len == 0:
        return ToolResult(output: "recall: 'query' argument is required", isError: true)
      let topK = extractTopK(args, opts.defaultTopK, MaxRecallTopK)
      try:
        let emb = opts.embeddingClient.getEmbedding(query)
        let matches = opts.mem.recallFacts(
          emb.vector, opts.embeddingClient.model, topK, opts.defaultMinScore)
        return ToolResult(output: formatMatches(matches), isError: false)
      except CatchableError as e:
        return ToolResult(output: "recall: failed to search memory: " & e.msg, isError: true)
  newTool(
    name = "recall",
    description = "Semantically search retained memory and return the " &
      "raw matches (fact text + similarity score), ranked best-first.",
    parameters = recallParametersSchema(),
    execute = exec,
  )

# ---------------------------------------------------------------------------
# reflect
# ---------------------------------------------------------------------------

proc makeReflectAnswer(opts: MemoryToolOptions; query: string; matches: seq[RetainedFactMatch]): string =
  if matches.len == 0:
    return "No retained facts are relevant to that question."
  let factsBlock = formatMatches(matches)
  let userPrompt = &"Retained facts:\n{factsBlock}\n\nQuestion: {query}"
  let history = @[ChatMessage(role: crSystem, content: ReflectSystemPrompt)]
  let resp = opts.llmClient.chatCompletion(userPrompt, history = history)
  resp.content

proc reflectTool*(opts: MemoryToolOptions): Tool =
  let exec = proc (args: JsonNode): ToolResult {.gcsafe.} =
    {.cast(gcsafe).}:
      let query = extractQuery(args, "query")
      if query.len == 0:
        return ToolResult(output: "reflect: 'query' argument is required", isError: true)
      let topK = extractTopK(args, opts.defaultTopK, MaxRecallTopK)
      try:
        let emb = opts.embeddingClient.getEmbedding(query)
        let matches = opts.mem.recallFacts(
          emb.vector, opts.embeddingClient.model, topK, opts.defaultMinScore)
        return ToolResult(output: makeReflectAnswer(opts, query, matches), isError: false)
      except CatchableError as e:
        return ToolResult(output: "reflect: failed: " & e.msg, isError: true)
  newTool(
    name = "reflect",
    description = "Answer a question by recalling relevant retained " &
      "facts and synthesizing a direct answer from them (an extra LLM " &
      "call over recall's raw matches). Use when you want an answer, " &
      "not a list of matches.",
    parameters = reflectParametersSchema(),
    execute = exec,
  )
