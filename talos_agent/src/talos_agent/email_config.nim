## Email tool configuration, loaded independently of talos_core's
## TalosConfig — mirrors the discord_config.nim/personas.toml pattern
## (its own TOML file, its own loader) rather than baking a product
## config into core's config struct.
##
## Not yet loaded from anywhere by default — callers opt in explicitly
## (see talos_agent/tools/email.nim's EmailOptions, which this adapts
## into).

import std/[os, parsecfg, strutils, streams]
import tools/email

type
  EmailConfig* = object
    fromAddress*: string
    smtpHost*: string
    smtpPort*: int
    smtpUser*: string
    smtpPassword*: string
    smtpUseSsl*: bool       ## implicit TLS, typically port 465
    smtpUseStartTls*: bool  ## STARTTLS after connect, typically port 587

proc defaultEmailConfig*(): EmailConfig =
  EmailConfig(smtpPort: 587, smtpUseStartTls: true)

proc defaultEmailConfigPath*(): string =
  getHomeDir() / ".config" / "talos" / "email.toml"

proc parseBoolField(val: string): bool =
  val.toLowerAscii() in @["1", "true", "yes", "on", "enabled"]

proc applyEmailTomlSection(cfg: var EmailConfig; section, key, val: string) =
  if section.toLowerAscii() != "email":
    return
  case key.toLowerAscii()
  of "from_address": cfg.fromAddress = val
  of "smtp_host": cfg.smtpHost = val
  of "smtp_port":
    try: cfg.smtpPort = parseInt(val)
    except ValueError: discard
  of "smtp_user": cfg.smtpUser = val
  of "smtp_password": cfg.smtpPassword = val
  of "smtp_use_ssl": cfg.smtpUseSsl = parseBoolField(val)
  of "smtp_use_starttls": cfg.smtpUseStartTls = parseBoolField(val)
  else: discard

proc loadEmailConfig*(path: string = ""): EmailConfig =
  ## Loads email config from its own TOML file (default
  ## ~/.config/talos/email.toml). Missing file (the common case until
  ## someone sets this up) yields the all-empty default — the email tool
  ## reports "not configured" for send rather than erroring on load.
  result = defaultEmailConfig()
  let p = if path.len > 0: path else: defaultEmailConfigPath()
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
      applyEmailTomlSection(result, currentSection, event.key, event.value)
    of cfgOption:
      discard
    of cfgError:
      # Best-effort: a malformed email.toml shouldn't crash the whole
      # config load — surface as defaults rather than raising.
      break

  let envPassword = getEnv("TALOS_EMAIL_SMTP_PASSWORD")
  if envPassword.len > 0:
    result.smtpPassword = envPassword

proc toEmailOptions*(cfg: EmailConfig): EmailOptions =
  EmailOptions(
    fromAddress: cfg.fromAddress,
    smtpHost: cfg.smtpHost,
    smtpPort: (if cfg.smtpPort > 0: cfg.smtpPort else: defaultEmailOptions().smtpPort),
    smtpUser: cfg.smtpUser,
    smtpPassword: cfg.smtpPassword,
    smtpUseSsl: cfg.smtpUseSsl,
    smtpUseStartTls: cfg.smtpUseStartTls,
    timeoutMs: defaultEmailOptions().timeoutMs,
  )
