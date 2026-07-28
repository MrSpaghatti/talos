## Discord-specific configuration, loaded independently of talos_core's
## TalosConfig — mirrors the persona-config pattern (its own TOML file,
## its own loader) instead of baking a product config into core's config
## struct.

import std/[os, parsecfg, strutils, streams]
import talos_core/config  # parseCsvList
import discord_types

proc defaultDiscordConfigPath*(): string =
  getHomeDir() / ".config" / "talos" / "discord.toml"

proc applyDiscordTomlSection(cfg: var DiscordConfig; section, key, val: string) =
  let k = key.toLowerAscii()
  case section.toLowerAscii()
  of "discord":
    case k
    of "token_env": cfg.tokenEnv = val
    of "prefix": cfg.prefix = val
    of "heartbeat_interval_sec":
      try:
        cfg.heartbeatIntervalSec = parseInt(val)
      except ValueError:
        discard
    else: discard
  of "discord.admins":
    case k
    of "allow": cfg.admins.allow = parseCsvList(val)
    of "deny": cfg.admins.deny = parseCsvList(val)
    else: discard
  of "discord.users":
    case k
    of "allow": cfg.users.allow = parseCsvList(val)
    of "deny": cfg.users.deny = parseCsvList(val)
    else: discard
  of "discord.file_rules":
    case k
    of "allow": cfg.fileRules.allow = parseCsvList(val)
    of "deny": cfg.fileRules.deny = parseCsvList(val)
    of "sandbox_dir": cfg.fileSandboxDir = val
    else: discard
  of "discord.tools":
    case k
    of "allow": cfg.tools.allow = parseCsvList(val)
    of "deny": cfg.tools.deny = parseCsvList(val)
    else: discard
  else: discard

proc loadDiscordConfig*(path: string = ""): DiscordConfig =
  ## Loads Discord config from its own TOML file (default
  ## ~/.config/talos/discord.toml) — same [discord]/[discord.admins]/
  ## [discord.users]/[discord.file_rules]/[discord.tools] section layout
  ## this used to have as sections inside core's config.toml, just in a
  ## standalone file now that core has no product baked in.
  result = defaultDiscordConfig()
  let p = if path.len > 0: path else: defaultDiscordConfigPath()
  if not fileExists(p):
    return

  var stream = newFileStream(p, fmRead)
  if stream == nil:
    return
  defer: stream.close()
  var parser: CfgParser
  open(parser, stream, p)
  defer: close(parser)

  var currentSection = ""
  while true:
    let event = next(parser)
    case event.kind
    of cfgEof:
      break
    of cfgSectionStart:
      currentSection = event.section
    of cfgKeyValuePair:
      applyDiscordTomlSection(result, currentSection, event.key, event.value)
    of cfgOption:
      discard
    of cfgError:
      # Best-effort: a malformed discord.toml shouldn't crash the whole
      # config load — surface as defaults rather than raising.
      break

  let fileSandboxDir = getEnv("TALOS_FILE_SANDBOX_DIR")
  if fileSandboxDir.len > 0:
    result.fileSandboxDir = fileSandboxDir
