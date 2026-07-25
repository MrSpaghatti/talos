## Discord daemon command and Discord API callback wrappers.

import std/[os, strutils, asyncdispatch, options]
import db_connector/db_sqlite
import talos_core/agent_dispatcher
import talos_core/build_llm_client
import talos_core/config
import talos_core/discord
import talos_core/discord_bridge
import talos_core/discord_mocks
import talos_core/discord_types
import talos_core/file_tool
import talos_core/file_path_validator
import talos_core/llm_client
import talos_core/memory
import talos_core/message_chunker
import talos_core/mcp_tool
import talos_core/persona
import talos_core/delegate
import talos_core/thread_mapping
import talos_core/tool_registry
import tools/shell
import talos_agent/cli
import talos_agent/config
import talos_agent/delegate_tool
import talos_agent/state
import dimscord

# ---------------------------------------------------------------------------
# Discord API callback wrappers
# ---------------------------------------------------------------------------
# These named procs wrap RealDiscordApi calls so they can be passed as
# callbacks to DiscordBot. Nim's {.async.} pragma doesn't work on inline
# proc literals, so we define them as named procs that capture the API
# adapter via closure.

proc makeSendFn(api: RealDiscordApi): SendMessageFn =
  proc send(channelId, content: string): Future[string] {.async, gcsafe.} =
    return await api.sendMessage(channelId, content)
  return send

proc makeTypingFn(api: RealDiscordApi): TriggerTypingFn =
  proc typing(channelId: string) {.async, gcsafe.} =
    await api.triggerTyping(channelId)
  return typing

proc makeCreateThreadFn(api: RealDiscordApi): CreateThreadFn =
  proc create(channelId, messageId, name: string): Future[string] {.async, gcsafe.} =
    return await api.createThread(channelId, messageId, name)
  return create

proc makeArchiveThreadFn(api: RealDiscordApi): ArchiveThreadFn =
  proc archive(threadId: string) {.async, gcsafe.} =
    await api.archiveThread(threadId)
  return archive

proc sendWithLogging*(sendFn: SendMessageFn; channelId, content: string): Future[void] {.async.} =
  ## Sends a message to Discord, logging errors to stderr instead of
  ## letting asyncCheck silently swallow them.
  try:
    discard await sendFn(channelId, content)
  except CatchableError as e:
    stderr.writeLine("[daemon] failed to send message: " & e.msg)

# ---------------------------------------------------------------------------
# Daemon command
# ---------------------------------------------------------------------------

proc cmdDaemon*(
    config = "";
    envFile = ".env";
): int =
  ## Starts the Discord bot daemon.
  ##
  ## Wires the DI-based DiscordBot with a real Dimscord client:
  ## 1. Loads config and reads the Discord token from the env var.
  ## 2. Creates a Dimscord client and RealDiscordApi adapter.
  ## 3. Builds the LLM client, tool registry, and memory store.
  ## 4. Opens the thread-mapping DB and initialises its schema.
  ## 5. Registers file tools conditionally (based on config).
  ## 6. Creates an AgentDispatcher whose callback sends results to Discord.
  ## 7. Wires the message_create event to onMessageCreate.
  ## 8. Starts the Discord gateway session.
  ## 9. Handles SIGINT/SIGTERM for graceful shutdown.
  setControlCHook(onCtrlC)
  var ov = emptyOverrides()
  ov.configPath = config
  ov.envPath = envFile
  var cfg: TalosConfig
  try:
    cfg = loadConfigWithOverrides(ov)
  except ConfigError as e:
    printError(e.msg); return 2

  # Read Discord bot token from the configured env var
  let tokenEnv = cfg.discord.tokenEnv
  let token = getEnv(tokenEnv)
  if token.len == 0:
    printError("Discord token not found in env var: " & tokenEnv)
    return 2

  # Build LLM client
  let llm = buildLLMClient(cfg)

  # Build tool registry
  var reg = newToolRegistry()

  # File tools — always available for safe Discord file access
  let fileRules = FileRules(
    sandboxDir: cfg.discord.fileSandboxDir,
    allowPatterns: cfg.discord.fileRules.allow,
    askPatterns: @[],
    denyPatterns: cfg.discord.fileRules.deny,
  )
  reg.register(fileReadTool(fileRules))
  reg.register(fileWriteTool(fileRules, cfg.discord))

  # Shell tool — available in Discord mode too (whitelist-only, solo-user
  # daemon), but permission-gated per caller: admins and tools.allow get
  # it, tools.deny actually denies, everyone else gets "requires approval".
  # The message-level isUserAllowed() gate alone gave every whitelisted
  # user admin-equivalent shell — weaker gating than file_write.
  reg.register(shellTool(defaultShellOptions(), cfg.discord))

  # Delegate + MCP tools — opt-in via daemonDelegation config flag.
  if cfg.discord.daemonDelegation:
    # Set agent globals so the delegate tool can initialise.
    setGlobalLLMClient(llm)
    setTalosConfig(cfg)
    let personasPath = defaultPersonasPath()
    let pReg = loadPersonasSafe(personasPath)
    setPersonaRegistry(pReg)
    setDelegationConfig(defaultDelegationConfig())

    reg.register(makeDelegateTool())
    if cfg.mcpServers.len > 0:
      discard registerMcpServers(reg, cfg.mcpServers)

  # Open memory store
  var mem = openMemory(cfg)

  # Open thread-mapping DB with WAL mode and busy timeout
  # to avoid SQLITE_BUSY when the memory module writes concurrently.
  let threadDbPath = resolveDbPath(cfg)
  let threadDb = open(threadDbPath, "", "", "")
  threadDb.exec(sql"PRAGMA journal_mode=WAL")
  threadDb.exec(sql"PRAGMA busy_timeout=5000")
  initThreadMappingSchema(threadDb)

  # Create Dimscord client
  let discord = newDiscordClient(token)

  # Create the real API adapter
  let api = newRealDiscordApi(discord.api)

  # Create a MockShard with the bot's user ID (populated on ready)
  var shard = newMockShard("")

  # Create the agent dispatcher — callback sends results to Discord.
  # dispatchAgent calls runAgentLoop directly (see agent_dispatcher.nim);
  # no injected run-function wrapper needed here.
  let sendFn = makeSendFn(api)
  let typingFn = makeTypingFn(api)
  let callbackProc = proc(r: agent_dispatcher.AgentResult) {.gcsafe, raises: [].} =
    {.cast(raises: []).}:
      let text = if r.error.isSome: "Error: " & r.error.get()
                 else: r.responseText
      let chunks = chunkMessage(text)
      for chunk in chunks:
        asyncCheck sendWithLogging(sendFn, r.channelId, chunk)
  # Discord's typing indicator expires after ~10s; refresh it once per
  # ReAct turn so it stays lit for the length of a multi-turn agent run
  # instead of just the first ~10s. See agent_loop.AgentConfig.turnCallback.
  let turnCallback = proc(channelId: string) {.gcsafe, raises: [].} =
    {.cast(gcsafe), cast(raises: []).}:
      try:
        waitFor typingFn(channelId)
      except CatchableError:
        discard
  let dispatcher = newAgentDispatcher(
    callbackProc, cfg, llm, reg, resolveDbPath(cfg), turnCallback = turnCallback,
    requestSetup = resetDelegationBudget
  )

  # Create the DI-based DiscordBot with real API callbacks
  let bot = newDiscordBot(
    sendMessage = makeSendFn(api),
    triggerTyping = makeTypingFn(api),
    createThread = makeCreateThreadFn(api),
    archiveThread = makeArchiveThreadFn(api),
    db = threadDb,
    config = cfg.discord,
    dispatcher = dispatcher,
    shard = shard,
  )

  # Graceful shutdown handled by the setControlCHook above
  # Start the Discord bot (blocks until session ends or error)
  # `finally` always runs on the way out of this try (normal return,
  # exception, or the early `return 1` below), so it alone owns closing
  # threadDb/mem — closing them again in `except` would double-close an
  # already-closed SQLite handle (undefined behavior) on any crash that
  # occurs while daemonShutdownRequested is still false, which is the
  # common case for a real Discord/network exception mid-run.
  try:
    waitFor startDiscordBot(discord, bot)
  except CatchableError as e:
    printError("Daemon crashed: " & e.msg)
    return 1
  finally:
    if not daemonShutdownRequested:
      threadDb.close()
      mem.close()
  return 0
