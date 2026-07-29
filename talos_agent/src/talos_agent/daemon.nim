## Discord daemon command and Discord API callback wrappers.

import std/[os, strutils, asyncdispatch, options]
import db_connector/db_sqlite
import talos_core/agent_dispatcher
import talos_core/build_llm_client
import talos_core/config
import talos_core/crash_report
import talos_core/heartbeat
import talos_agent/discord/discord
import talos_agent/discord/discord_bridge
import talos_agent/discord/discord_mocks
import talos_agent/discord/discord_types
import talos_agent/discord/discord_config
import talos_agent/discord/thread_mapping
import talos_core/file_tool
import talos_core/file_path_validator
import talos_core/llm_client
import talos_core/memory
import talos_core/message_chunker
import talos_core/mcp_tool
import talos_core/persona
import talos_core/delegate
import talos_core/tool_registry
import tools/shell
import tools/browser
import tools/email
import tools/memory_tools
import talos_agent/email_config
import talos_agent/cli
import talos_agent/config
import talos_agent/delegate_tool
import talos_agent/state
import talos_agent/voice
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

proc sendWithLogging*(sendFn: SendMessageFn; channelId, content: string;
                       ring: RingLogger = nil): Future[void] {.async.} =
  ## Sends a message to Discord, logging errors to stderr (and, if a
  ## RingLogger is given, into it too) instead of letting asyncCheck
  ## silently swallow them.
  try:
    discard await sendFn(channelId, content)
  except CatchableError as e:
    let line = "failed to send message: " & e.msg
    stderr.writeLine("[daemon] " & line)
    if ring != nil: ring.log(line)

# ---------------------------------------------------------------------------
# Daemon command
# ---------------------------------------------------------------------------

proc cmdDaemon*(
    config = "";
    envFile = ".env";
    discordConfig = "";
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
  # Recent-activity ring buffer, folded into the crash report on a fatal
  # error — gives a crash report more context than the exception alone
  # when nobody was watching the terminal/journal at the time.
  var ring = newRingLogger()
  var ov = emptyOverrides()
  ov.configPath = config
  ov.envPath = envFile
  var cfg: TalosConfig
  try:
    cfg = loadConfigWithOverrides(ov)
  except ConfigError as e:
    printError(e.msg); return 2
  let discordCfg = loadDiscordConfig(discordConfig)
  ring.log("config loaded")

  # Read Discord bot token from the configured env var
  let tokenEnv = discordCfg.tokenEnv
  let token = getEnv(tokenEnv)
  if token.len == 0:
    printError("Discord token not found in env var: " & tokenEnv)
    return 2

  # Build LLM client
  let llm = buildLLMClient(cfg)

  # Open memory store (before tool registration — retain/recall/reflect
  # need a live handle to build their MemoryToolOptions).
  var mem = openMemory(cfg)

  # Build tool registry
  var reg = newToolRegistry()

  # File tools — always available for safe Discord file access
  let fileRules = FileRules(
    sandboxDir: discordCfg.fileSandboxDir,
    allowPatterns: discordCfg.fileRules.allow,
    askPatterns: @[],
    denyPatterns: discordCfg.fileRules.deny,
  )
  reg.register(fileReadTool(fileRules))
  reg.register(fileWriteTool(fileRules, toToolAcl(discordCfg)))

  # Shell tool — available in Discord mode too (whitelist-only, solo-user
  # daemon), but permission-gated per caller: admins and tools.allow get
  # it, tools.deny actually denies, everyone else gets "requires approval".
  # The message-level isUserAllowed() gate alone gave every whitelisted
  # user admin-equivalent shell — weaker gating than file_write.
  reg.register(shellTool(defaultShellOptions(), toToolAcl(discordCfg)))

  # Browser tool — same gating shape as shell: admins and tools.allow get
  # it, everyone else gets "requires approval".
  reg.register(browserTool(defaultBrowserOptions(), toToolAcl(discordCfg)))

  # Email tool — same gating shape as shell/browser. Reports "not
  # configured" for send until ~/.config/talos/email.toml (or
  # TALOS_EMAIL_SMTP_PASSWORD) is actually set up.
  reg.register(emailTool(toEmailOptions(loadEmailConfig()), toToolAcl(discordCfg)))

  # retain/recall/reflect — retain writes durable memory (riskMedium, same
  # gating shape as file_write/shell/browser/email); recall/reflect are
  # read-only and always ungated, matching file_read's precedent.
  let memOpts = newMemoryToolOptions(mem, buildEmbeddingClient(cfg), llm)
  reg.register(retainTool(memOpts, toToolAcl(discordCfg)))
  reg.register(recallTool(memOpts))
  reg.register(reflectTool(memOpts))

  # Delegate + MCP tools — opt-in via daemonDelegation config flag.
  if discordCfg.daemonDelegation:
    # Set agent globals so the delegate tool can initialise.
    setGlobalLLMClient(llm)
    setTalosConfig(cfg)
    setToolAcl(toToolAcl(discordCfg))
    let personasPath = defaultPersonasPath()
    let pReg = loadPersonasSafe(personasPath)
    setPersonaRegistry(pReg)
    setDelegationConfig(defaultDelegationConfig())

    reg.register(makeDelegateTool())
    if cfg.mcpServers.len > 0:
      discard registerMcpServers(reg, cfg.mcpServers)

  # Open thread-mapping DB with WAL mode and busy timeout
  # to avoid SQLITE_BUSY when the memory module writes concurrently.
  let threadDbPath = resolveDbPath(cfg)
  let threadDb = open(threadDbPath, "", "", "")
  threadDb.exec(sql"PRAGMA journal_mode=WAL")
  threadDb.exec(sql"PRAGMA busy_timeout=5000")
  initThreadMappingSchema(threadDb)

  ring.log("memory + thread-mapping DB opened")

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
        asyncCheck sendWithLogging(sendFn, r.surfaceId, chunk, ring)
  # Discord's typing indicator expires after ~10s; refresh it once per
  # ReAct turn so it stays lit for the length of a multi-turn agent run
  # instead of just the first ~10s. See agent_loop.AgentConfig.turnCallback.
  let turnCallback = proc(surfaceId: string) {.gcsafe, raises: [].} =
    {.cast(gcsafe), cast(raises: []).}:
      try:
        waitFor typingFn(surfaceId)
      except CatchableError:
        discard
  let dispatcher = newAgentDispatcher(
    callbackProc, cfg, llm, reg, resolveDbPath(cfg), turnCallback = turnCallback,
    requestSetup = resetDelegationBudget, systemPrompt = TalosSystemPrompt
  )

  # Create the DI-based DiscordBot with real API callbacks
  let bot = newDiscordBot(
    sendMessage = makeSendFn(api),
    triggerTyping = makeTypingFn(api),
    createThread = makeCreateThreadFn(api),
    archiveThread = makeArchiveThreadFn(api),
    db = threadDb,
    config = discordCfg,
    dispatcher = dispatcher,
    shard = shard,
  )

  # Proactive heartbeat — off by default (heartbeatIntervalSec == 0). v1
  # ships the scheduler plumbing wired end-to-end with a no-op check;
  # deciding what's actually worth surfacing unprompted is a follow-on now
  # that the mechanism itself is proven live, not a blocker to landing it.
  if discordCfg.heartbeatIntervalSec > 0 and discordCfg.admins.allow.len > 0:
    let adminId = discordCfg.admins.allow[0]
    let surfaceFn = proc(message: string) =
      proc deliver(): Future[void] {.async.} =
        let dmId = await api.getOrCreateDM(adminId)
        discard await api.sendMessage(dmId, message)
      asyncCheck deliver()
    let hb = newHeartbeat(discordCfg.heartbeatIntervalSec * 1000, surfaceFn)
    hb.addCheck(proc(): Future[Option[string]] {.async.} =
      return none(string))
    asyncCheck hb.run()
    ring.log("heartbeat started (interval=" & $discordCfg.heartbeatIntervalSec & "s)")

  ring.log("starting Discord gateway session")

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
    ring.log("daemon crashed: " & e.msg)
    # The crash report file is the durable source of truth; write it
    # unconditionally before attempting anything that touches the network.
    writeCrashReport(defaultCrashReportPath(), e, ring)
    # Best-effort DM to the first configured admin — bonus-effort only,
    # under a hard timeout so an unreachable Discord connection (plausibly
    # the cause of the crash itself) can't hang shutdown.
    if discordCfg.admins.allow.len > 0:
      let adminId = discordCfg.admins.allow[0]
      let crashMsg = "Talos daemon crashed: " & e.msg
      proc notifyAdmin(): Future[void] {.async.} =
        let dmId = await api.getOrCreateDM(adminId)
        discard await api.sendMessage(dmId, crashMsg)
      try:
        let completed = waitFor notifyAdmin().withTimeout(5000)
        if not completed:
          stderr.writeLine("[daemon] crash DM to admin timed out")
      except CatchableError as notifyErr:
        stderr.writeLine("[daemon] failed to send crash DM: " & notifyErr.msg)
    printError("Daemon crashed: " & e.msg)
    return 1
  finally:
    if not daemonShutdownRequested:
      threadDb.close()
      mem.close()
  return 0
