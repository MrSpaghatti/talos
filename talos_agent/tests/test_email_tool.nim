## Tests for tools/email.nim
##
## No live SMTP credentials exist yet (see plans history — email.toml is
## intentionally unconfigured until the user sets up a real account), so
## these cover argument validation, the "not configured" path, and the
## permission-gated variant's denial paths — none of which touch a real
## network connection. A live send smoke test is deferred until real
## credentials are supplied.

import std/[json, unittest, strutils]
import talos_core/tool_registry
import talos_core/acl
import tools/email

suite "email tool: argument validation":
  test "missing 'to' is rejected":
    let tool = emailTool()
    let res = tool.execute(%*{"subject": "hi", "body": "hello"})
    check res.isError
    check "'to'" in res.output

  test "missing 'subject' is rejected":
    let tool = emailTool()
    let res = tool.execute(%*{"to": "a@b.com", "body": "hello"})
    check res.isError
    check "'subject'" in res.output

suite "email tool: unconfigured account":
  test "send reports 'not configured' rather than attempting a connection":
    let tool = emailTool(defaultEmailOptions())  # smtpHost/fromAddress empty
    let res = tool.execute(%*{"to": "a@b.com", "subject": "hi", "body": "hello"})
    check res.isError
    check "not configured" in res.output

  test "a configured host but no from_address still reports not configured":
    var opts = defaultEmailOptions()
    opts.smtpHost = "smtp.example.com"
    let tool = emailTool(opts)
    let res = tool.execute(%*{"to": "a@b.com", "subject": "hi", "body": "hello"})
    check res.isError
    check "not configured" in res.output

suite "email tool: gated variant":
  proc acl(admins: seq[string] = @[]): ToolAcl =
    ToolAcl(admins: AccessControl(allow: admins))

  test "unlisted caller is denied before any SMTP attempt":
    let tool = emailTool(defaultEmailOptions(), acl())
    let res = tool.execute(
      %*{"to": "a@b.com", "subject": "hi", "body": "hi", "_callerId": "stranger"})
    check res.isError
    check "denied" in res.output

  test "missing _callerId fails closed":
    let tool = emailTool(defaultEmailOptions(), acl(admins = @["admin1"]))
    let res = tool.execute(%*{"to": "a@b.com", "subject": "hi", "body": "hi"})
    check res.isError

  test "admin caller reaches the real send path (and hits 'not configured', not 'denied')":
    let tool = emailTool(defaultEmailOptions(), acl(admins = @["admin1"]))
    let res = tool.execute(
      %*{"to": "a@b.com", "subject": "hi", "body": "hi", "_callerId": "admin1"})
    check res.isError
    check "not configured" in res.output
