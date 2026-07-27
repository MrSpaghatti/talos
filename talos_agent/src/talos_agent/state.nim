## Agent process-wide state.
##
## Holds the global state shared across CLI command handlers: the
## `AgentGlobals` ref used by the delegate tool's closures, and the
## Ctrl+C / daemon-shutdown flags used for graceful interruption.

import std/[asyncdispatch, asynchttpserver]
import talos_agent/web_server
import talos_core/acl
import talos_core/config
import talos_core/delegate
import talos_core/llm_client
import talos_core/persona

# ---------------------------------------------------------------------------
# Global state for tool closures
# ---------------------------------------------------------------------------

type
  AgentGlobals* = ref object
    ## Container for agent-loop globals that need safe closure capture.
    personaRegistry*: PersonaRegistry
    llmClient*: LLMClient
    delegationConfig*: DelegationConfig
    talosConfig*: TalosConfig
    toolAcl*: ToolAcl
      ## Caller-identity ACL for gating a delegated child's shell tool in
      ## daemon mode (see delegate_tool.nim). Zero value denies everyone,
      ## matching an unconfigured product config — set explicitly by
      ## whichever product enables delegation (e.g. the Discord daemon).

var gGlobals*: AgentGlobals = nil

proc setPersonaRegistry*(reg: PersonaRegistry) =
  if gGlobals.isNil:
    gGlobals = AgentGlobals(personaRegistry: reg)
  else:
    gGlobals.personaRegistry = reg

proc setGlobalLLMClient*(llm: LLMClient) =
  if gGlobals.isNil:
    gGlobals = AgentGlobals(llmClient: llm)
  else:
    gGlobals.llmClient = llm

proc setDelegationConfig*(dc: DelegationConfig) =
  if gGlobals.isNil:
    gGlobals = AgentGlobals(delegationConfig: dc)
  else:
    gGlobals.delegationConfig = dc

proc setTalosConfig*(cfg: TalosConfig) =
  if gGlobals.isNil:
    gGlobals = AgentGlobals(talosConfig: cfg)
  else:
    gGlobals.talosConfig = cfg

proc setToolAcl*(acl: ToolAcl) =
  if gGlobals.isNil:
    gGlobals = AgentGlobals(toolAcl: acl)
  else:
    gGlobals.toolAcl = acl

proc resetDelegationBudget*() {.gcsafe, raises: [].} =
  ## Restores the delegation budget to its configured baseline. Must be
  ## called at the start of every top-level request/turn (daemon message,
  ## web chat, CLI/TUI turn): the delegate tool consumes budget from the
  ## process-wide global, which otherwise never resets — after maxDepth
  ## delegations total, daemon-wide, every later delegate call from any
  ## user in any thread fails with "maximum delegation depth reached"
  ## until the process restarts.
  {.cast(gcsafe), cast(raises: []).}:
    setDelegationConfig(defaultDelegationConfig())

# ---------------------------------------------------------------------------
# Globals for graceful Ctrl+C handling
# ---------------------------------------------------------------------------

var ctrlCRequested* = false
  ## Set by the SIGINT hook so the chat loop can exit cleanly between
  ## turns. Exposed for tests.

var daemonShutdownRequested* = false
var gWebServer*: WebServer = nil
  ## Set by cmdWeb so the Ctrl+C hook can close the server socket.

proc onCtrlC*() {.noconv.} =
  ctrlCRequested = true
  daemonShutdownRequested = true
  if not gWebServer.isNil:
    gWebServer.server.close()
  # Best-effort newline so the next prompt isn't glued to "^C".
  try: stdout.write("\n") except CatchableError: discard
