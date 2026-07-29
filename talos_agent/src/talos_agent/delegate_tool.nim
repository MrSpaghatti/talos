## Delegate tool and tool registry builder.
##
## The delegate tool spawns a child agent from a named persona to handle
## a specific subtask. The child runs with its own system prompt, tool
## restrictions, and memory isolation.

import std/[json, os, strutils]
import talos_core/agent_loop
import talos_core/build_llm_client
import talos_core/config
import talos_core/delegate
import talos_core/llm_client
import talos_core/memory
import talos_core/mcp_tool
import talos_core/persona
import talos_core/tool_registry
import tools/shell
import tools/browser
import tools/email
import tools/memory_tools
import talos_agent/email_config
import talos_agent/state

# ---------------------------------------------------------------------------
# Delegate tool
# ---------------------------------------------------------------------------
# Forward declaration — `makeDelegateExecuteProc` references this.
proc makeDelegateTool*(): Tool

proc makeDelegateParams*(): JsonNode =
  ## Builds the JSON Schema for the delegate tool parameters.
  let p = newJObject()
  p["type"] = %"object"
  p["properties"] = newJObject()
  p["properties"]["persona"] = newJObject()
  p["properties"]["persona"]["type"] = %"string"
  p["properties"]["persona"]["description"] =
    %"Name of the persona to spawn (e.g. 'code_reviewer')"
  p["properties"]["task"] = newJObject()
  p["properties"]["task"]["type"] = %"string"
  p["properties"]["task"]["description"] =
    %"The subtask description for the child agent"
  p["required"] = newJArray()
  p["required"].add(%"persona")
  p["required"].add(%"task")
  p

proc childGetsDelegateTool*(persona: PersonaConfig; llmConfigured: bool): bool =
  ## Whether a child agent spawned for `persona` should itself get a
  ## `delegate` tool (i.e. whether it may delegate further). Requires both
  ## the persona opting in via `delegate_enabled` (an operator can use this
  ## to build a persona that must not spawn sub-agents) and a real LLM
  ## being configured — a fake/placeholder LLM can't run a further child
  ## agent even if the persona would otherwise allow it. Pulled out as a
  ## pure function so the gating decision itself is directly testable
  ## without needing a live delegation round-trip.
  persona.delegateEnabled and llmConfigured

proc makeDelegateExecuteProc*(): auto =
  ## Returns a gcsafe closure that captures the current AgentGlobals ref.
  ## The ref object is GC-safe to capture, and the closure accesses globals
  ## through the ref rather than directly.
  let captured = gGlobals
  return proc (args: JsonNode): ToolResult =
    if captured.isNil:
      return ToolResult(
        output: "delegate: agent globals not initialized",
        isError: true,
        exitCode: 1,
      )
    # Check delegation depth tracking before spawning.
    if not captured.delegationConfig.canDelegate():
      let reason =
        if captured.delegationConfig.maxDepth <= 0:
          "maximum delegation depth reached"
        elif captured.delegationConfig.maxDelegations <= 0:
          "maximum delegations per run exhausted"
        else:
          "delegation limit reached"
      return ToolResult(
        output: "delegate: " & reason,
        isError: true,
        exitCode: 1,
      )
    let personaName = args{"persona"}.getStr("")
    let task = args{"task"}.getStr("")
    if personaName.len == 0:
      return ToolResult(
        output: "delegate: 'persona' argument is required",
        isError: true,
        exitCode: 1,
      )
    if task.len == 0:
      return ToolResult(
        output: "delegate: 'task' argument is required",
        isError: true,
        exitCode: 1,
      )
    if captured.personaRegistry.isNil:
      return ToolResult(
        output: "delegate: no persona registry loaded (no personas.toml found)",
        isError: true,
        exitCode: 1,
      )
    if not captured.personaRegistry.hasPersona(personaName):
      return ToolResult(
        output: "delegate: unknown persona '" & personaName &
          "'. Available: " & captured.personaRegistry.listPersonas().join(", "),
        isError: true,
        exitCode: 1,
      )
    let persona =
      try: captured.personaRegistry.getPersona(personaName)
      except PersonaError:
        return ToolResult(
          output: "delegate: failed to load persona '" & personaName & "'",
          isError: true,
          exitCode: 1,
        )
    if captured.llmClient.baseUrl.len == 0:
      return ToolResult(
        output: "delegate: LLM client not available (baseUrl is empty)",
        isError: true,
        exitCode: 1,
      )
    let parentCfg =
      if captured.talosConfig.provider.len > 0: captured.talosConfig
      else: defaultConfig()
    var childCfg = newAgentConfig(parentCfg)
    if persona.systemPrompt.len > 0:
      childCfg.systemPrompt = persona.systemPrompt
    if persona.maxIterations > 0:
      childCfg.maxIterations = persona.maxIterations
    childCfg.persona = persona
    childCfg.delegation = applyPersonaDelegation(
      persona.maxDelegationDepth,
      persona.maxDelegationsPerRun,
      persona.name,
      parentMaxDepth = captured.delegationConfig.maxDepth,
    )
    let dbPath = resolveDbPath(parentCfg)
    var childMem: Memory
    try:
      childMem = newMemory(dbPath)
    except CatchableError:
      return ToolResult(
        output: "delegate: cannot open memory store",
        isError: true,
        exitCode: 1,
      )
    # Consume one delegation slot before spawning the child.
    captured.delegationConfig.useDelegationSlot()

    # Build a proper registry so the child has tools.
    # Temporarily swap delegation config so the child's delegate tool
    # captures its own bounds rather than the parent's.
    let savedDc = gGlobals.delegationConfig
    gGlobals.delegationConfig = childCfg.delegation
    defer: gGlobals.delegationConfig = savedDc
    var childReg = newToolRegistry()
    # Propagate the caller's identity into the child so its tool calls are
    # gated for the same user (the agent loop injects childCfg.callerId as
    # `_callerId` into every child tool call). A non-empty _callerId means
    # a Discord-daemon context: give the child the permission-gated shell.
    # An empty one means CLI/TUI, where the ungated shell is intentional.
    let delegCallerId =
      if not args.isNil and args.kind == JObject: args{"_callerId"}.getStr("")
      else: ""
    childCfg.callerId = delegCallerId
    if delegCallerId.len > 0:
      childReg.register(shellTool(defaultShellOptions(), captured.toolAcl))
    else:
      childReg.register(shellTool())
    let llmConfigured = not gGlobals.isNil and gGlobals.llmClient.baseUrl.len > 0
    if childGetsDelegateTool(persona, llmConfigured):
      childReg.register(makeDelegateTool())
    if parentCfg.mcpServers.len > 0:
      discard registerMcpServers(childReg, parentCfg.mcpServers)
    let scopedChildReg = scopedRegistry(childReg, persona)

    let childResult = runAgentLoop(
      agentCfg = childCfg,
      llm = captured.llmClient,
      registry = scopedChildReg,
      memory = childMem,
      userInput = task,
    )
    childMem.close()
    var lines: seq[string] = @[]
    lines.add("=== Child Agent Result ===")
    lines.add("Persona: " & persona.name)
    lines.add("Session: " & childResult.sessionId)
    lines.add("Stop reason: " & $childResult.stopReason)
    lines.add("Tokens: " & $childResult.stats.totalTokens &
      " (prompt: " & $childResult.stats.promptTokens &
      ", completion: " & $childResult.stats.completionTokens & ")")
    lines.add("Turns: " & $childResult.stats.totalTurns)
    lines.add("Tool calls: " & $childResult.stats.toolCallsMade)
    lines.add("")
    lines.add("--- Response ---")
    if childResult.text.len > 0:
      lines.add(childResult.text)
    else:
      lines.add("(no text produced)")
    return ToolResult(
      output: lines.join("\n"),
      isError: false,
      exitCode: 0,
    )

proc makeDelegateTool*(): Tool =
  ## Returns the delegate tool with the current agent globals captured.
  ## Call this after setting globals via setPersonaRegistry / setGlobalLLMClient.
  let description = "Spawn a child agent from a named persona to handle " &
    "a specific subtask. The child agent runs with its own system prompt, " &
    "tool restrictions, and memory isolation. " &
    "Args: persona (string, name of persona), task (string, the subtask). " &
    "Returns: the child's final text response plus execution metadata."

  let exec = makeDelegateExecuteProc()
  newTool(
    name = "delegate",
    description = description,
    parameters = makeDelegateParams(),
    execute = exec,
  )

proc delegateTool*(): Tool =
  ## Creates the delegate tool with a snapshot of current globals.
  ## NOTE: prefer `makeDelegateTool` after globals are set. This proc
  ## captures globals at proc definition time (potentially nil).
  makeDelegateTool()

proc buildRegistry*(cfg: TalosConfig = defaultConfig()): ToolRegistry =
  ## Builds the default tool registry for the agent. Registers the shell tool
  ## and any MCP tools configured in `cfg.mcpServers`. Also registers the
  ## delegate tool if agent globals are available.
  result = newToolRegistry()
  result.register(shellTool())
  result.register(browserTool())
  result.register(emailTool(toEmailOptions(loadEmailConfig())))
  try:
    let mem = openMemory(cfg)
    let memOpts = newMemoryToolOptions(
      mem, buildEmbeddingClient(cfg), buildLLMClient(cfg))
    result.register(retainTool(memOpts))
    result.register(recallTool(memOpts))
    result.register(reflectTool(memOpts))
  except CatchableError:
    # No durable memory available (e.g. unwritable db path) — skip these
    # tools rather than fail startup; shell/browser/email etc. still work.
    discard
  if cfg.mcpServers.len > 0:
    discard registerMcpServers(result, cfg.mcpServers)
  # Register delegate tool — only if globals are set
  if not gGlobals.isNil and gGlobals.llmClient.baseUrl.len > 0:
    result.register(makeDelegateTool())
