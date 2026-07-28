## Talos email tool.
##
## Sends mail via SMTP. Uses the async `smtp` client even though this
## tool's own `execute` is synchronous — wrapping the send in
## `asyncdispatch.withTimeout` is what lets a dead/slow mail server time
## out cleanly instead of hanging the whole agent turn, since the sync
## socket API this package exposes has no timeout knob of its own.
##
## Out of scope (deferred — see plans/task history):
##   - Reading/searching an inbox via IMAP. The one Nim IMAP library
##     available (`mailclient`) has a confirmed bug in its FETCH-response
##     parser: it reads literal-syntax data off the wire correctly, but
##     fails to extract it into header/body fields (only handles quoted
##     strings, not the literal syntax real servers like Gmail actually
##     use). Shipping "read" today would silently return empty bodies
##     against real accounts. Revisit once there's a reliable IMAP client
##     for Nim, or time to write a targeted parser around that gap.
##   - Attachments, HTML bodies (plain text only), OAuth2 (password/app-
##     password auth only).

import std/[json, asyncdispatch]
import smtp
import talos_core/tool_registry
import talos_core/acl
import talos_core/permission

const
  DefaultEmailTimeoutMs* = 15_000
  MaxEmailTimeoutMs* = 60_000

type
  EmailOptions* = object
    fromAddress*: string
    smtpHost*: string
    smtpPort*: int
    smtpUser*: string
    smtpPassword*: string
    smtpUseSsl*: bool       ## implicit TLS, typically port 465
    smtpUseStartTls*: bool  ## STARTTLS after connect, typically port 587
    timeoutMs*: int

proc defaultEmailOptions*(): EmailOptions =
  EmailOptions(smtpPort: 587, smtpUseStartTls: true, timeoutMs: DefaultEmailTimeoutMs)

# ---------------------------------------------------------------------------
# Schema
# ---------------------------------------------------------------------------

proc emailParametersSchema*(): JsonNode =
  %*{
    "type": "object",
    "properties": {
      "to": {"type": "string", "description": "Recipient email address."},
      "subject": {"type": "string", "description": "Subject line."},
      "body": {"type": "string", "description": "Plain-text message body."},
    },
    "required": ["to", "subject", "body"],
  }

# ---------------------------------------------------------------------------
# Sending
# ---------------------------------------------------------------------------

proc sendAsync(opts: EmailOptions; to, subject, body: string): Future[void] {.async.} =
  var conn = newAsyncSmtp(useSsl = opts.smtpUseSsl)
  await conn.connect(opts.smtpHost, Port(opts.smtpPort))
  if opts.smtpUseStartTls:
    await conn.startTls()
  if opts.smtpUser.len > 0:
    await conn.auth(opts.smtpUser, opts.smtpPassword)
  let msg = createMessage(subject, body, sender = opts.fromAddress, mTo = @[to])
  await conn.sendMail(opts.fromAddress, @[to], $msg)
  await conn.close()

proc doSend(opts: EmailOptions; to, subject, body: string): tuple[ok: bool; err: string] =
  if opts.smtpHost.len == 0:
    return (false, "email: not configured (no smtp_host in email.toml) — " &
                   "see plans/task history for the config file shape")
  if opts.fromAddress.len == 0:
    return (false, "email: not configured (no from_address in email.toml)")
  try:
    let fut = sendAsync(opts, to, subject, body)
    if not waitFor fut.withTimeout(opts.timeoutMs):
      return (false, "email: send timed out after " & $opts.timeoutMs & "ms")
    if fut.failed:
      return (false, "email: " & fut.error.msg)
    return (true, "")
  except CatchableError as e:
    return (false, "email: " & e.msg)

# ---------------------------------------------------------------------------
# Tool wiring
# ---------------------------------------------------------------------------

proc makeEmailExecuteProc(opts: EmailOptions): ToolExecuteProc =
  result = proc (args: JsonNode): ToolResult {.gcsafe.} =
    {.cast(gcsafe).}:
      let to = if not args.isNil and args.kind == JObject: args{"to"}.getStr("") else: ""
      let subject = if not args.isNil and args.kind == JObject: args{"subject"}.getStr("") else: ""
      let body = if not args.isNil and args.kind == JObject: args{"body"}.getStr("") else: ""
      if to.len == 0:
        return ToolResult(output: "email: 'to' argument is required", isError: true)
      if subject.len == 0:
        return ToolResult(output: "email: 'subject' argument is required", isError: true)

      var localOpts = opts
      if localOpts.timeoutMs <= 0 or localOpts.timeoutMs > MaxEmailTimeoutMs:
        localOpts.timeoutMs = min(max(localOpts.timeoutMs, 1), MaxEmailTimeoutMs)

      let (ok, err) =
        try:
          doSend(localOpts, to, subject, body)
        except CatchableError as e:
          (false, "email: internal error: " & e.msg)

      if not ok:
        return ToolResult(output: err, isError: true)
      return ToolResult(output: "email sent to " & to, isError: false)

proc emailTool*(opts: EmailOptions = defaultEmailOptions()): Tool =
  ## Builds a `Tool` value for the email tool. Register it with a
  ## `ToolRegistry` to expose it to the LLM.
  newTool(
    name = "email",
    description = "Send a plain-text email via the configured SMTP " &
      "account. Reports 'not configured' if no account has been set up.",
    parameters = emailParametersSchema(),
    execute = makeEmailExecuteProc(opts),
  )

proc emailTool*(opts: EmailOptions, acl: ToolAcl): Tool =
  ## Permission-gated variant for contexts with a real caller identity
  ## (the Discord daemon and its delegation children) — mirrors
  ## `tools/shell.shellTool(opts, acl)` and `tools/browser.browserTool(opts, acl)`.
  let inner = makeEmailExecuteProc(opts)
  let gated = proc (args: JsonNode): ToolResult {.gcsafe, raises: [].} =
    let callerId =
      if not args.isNil and args.kind == JObject: args{"_callerId"}.getStr("")
      else: ""
    let perm = try: canUseTool(callerId, "email", acl)
               except CatchableError:
                 return ToolResult(output: "email: permission check failed",
                                   isError: true)
    case perm
    of pdDeny:
      return ToolResult(output: "email: access denied for this user",
                        isError: true)
    of pdAsk:
      return ToolResult(
        output: "email: requires approval — ask an admin, or add " &
                "'email' to the tools allow-list",
        isError: true)
    of pdAllow:
      try:
        return inner(args)
      except CatchableError as e:
        return ToolResult(output: "email: internal error: " & e.msg,
                          isError: true)
      except Exception as e:
        return ToolResult(output: "email: internal error: " & e.msg,
                          isError: true)
  newTool(
    name = "email",
    description = "Send a plain-text email via the configured SMTP " &
      "account. Reports 'not configured' if no account has been set up.",
    parameters = emailParametersSchema(),
    execute = gated,
  )
