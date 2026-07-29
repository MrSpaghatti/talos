## One-off empirical comparison of candidate OpenRouter embedding models for
## Talos's vector-memory feature (Phase 6 / task-05-vector-memory.md).
##
## Not part of the build — compile and run manually:
##   nim c --path:/home/spag/talos_core/src --path:src -r scripts/eval_embeddings.nim
##
## Requires network access and OPENROUTER_API_KEY in ../.env (the monorepo
## root .env) — this machine's Claude Code sandbox has no network egress, so
## this must be run directly by a human in a real shell, not by the agent.
##
## Method: six sentences across three topics (two paraphrases per topic,
## deliberately using different vocabulary so lexical/FTS overlap is low —
## this isolates true semantic understanding from keyword matching). For
## each candidate model, computes cosine similarity for every pair and
## reports the margin between same-topic and cross-topic similarity. A
## bigger margin means better separation of "actually related" from
## "unrelated" — the property that matters for recall() quality.

import std/[os, strformat, math]
import talos_core/embeddings
import talos_core/config

type
  TestItem = object
    text: string
    topic: int

const items = [
  TestItem(topic: 0, text: "My dog Biscuit needs to go to the vet next Tuesday for his annual checkup."),
  TestItem(topic: 0, text: "I have to take my puppy to see the veterinarian early next week."),
  TestItem(topic: 1, text: "The Manta WebDAV transport pipes files from ServerLink to the Pi via rclone."),
  TestItem(topic: 1, text: "We're syncing documents from the ServerLink to the Raspberry Pi through a WebDAV-based rclone pipeline."),
  TestItem(topic: 2, text: "Talos should feel like an ambient life assistant, not a customer support bot."),
  TestItem(topic: 2, text: "I want the agent's personality to be a proactive daily companion, not a generic helpdesk voice."),
]

const candidateModels = [
  "openai/text-embedding-3-large",
  "openai/text-embedding-3-small",
  "google/gemini-embedding-001",
  "baai/bge-m3",
]

proc loadApiKey(): string =
  let envPath = getAppDir() / ".." / ".." / ".env"
  for (key, val) in parseEnvFile(envPath):
    if key == "OPENROUTER_API_KEY":
      return val
  # Fall back to process env in case it's already exported.
  result = getEnv("OPENROUTER_API_KEY")

proc evalModel(apiKey, model: string) =
  echo &"\n=== {model} ==="
  var vectors: seq[seq[float32]] = @[]
  try:
    let client = newEmbeddingClient("https://openrouter.ai/api/v1", apiKey, model)
    for it in items:
      let r = client.getEmbedding(it.text)
      vectors.add(r.vector)
      echo &"  embedded ({r.vector.len}-dim, {r.tokensUsed} tokens): {it.text[0..min(40, it.text.len-1)]}..."
  except CatchableError as e:
    echo &"  FAILED: {e.msg}"
    return

  var sameSims: seq[float32] = @[]
  var crossSims: seq[float32] = @[]
  for i in 0 ..< items.len:
    for j in (i+1) ..< items.len:
      let sim = cosineSimilarity(vectors[i], vectors[j])
      if items[i].topic == items[j].topic:
        sameSims.add(sim)
      else:
        crossSims.add(sim)

  let meanSame = sameSims.sum() / sameSims.len.float32
  let meanCross = crossSims.sum() / crossSims.len.float32
  echo &"  mean same-topic similarity:  {meanSame:.4f}"
  echo &"  mean cross-topic similarity: {meanCross:.4f}"
  echo &"  margin (higher = better):    {(meanSame - meanCross):.4f}"

when isMainModule:
  let apiKey = loadApiKey()
  if apiKey.len == 0:
    echo "ERROR: OPENROUTER_API_KEY not found in ../.env or environment."
    quit(1)
  echo "Talos embedding model comparison"
  echo "================================"
  for model in candidateModels:
    evalModel(apiKey, model)
