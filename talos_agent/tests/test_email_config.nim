## Tests for talos_agent/email_config.nim
##
## Email config is loaded from its own TOML file, independent of
## talos_core's config.toml — mirrors discord_config.nim.

import std/[os, unittest]
import talos_agent/email_config

proc writeTempFile(path, content: string) =
  createDir(parentDir(path))
  writeFile(path, content)

suite "Email Config Defaults":
  test "default email config is unconfigured but has sane SMTP defaults":
    let cfg = defaultEmailConfig()
    check cfg.fromAddress == ""
    check cfg.smtpHost == ""
    check cfg.smtpPort == 587
    check cfg.smtpUseStartTls == true
    check cfg.smtpUseSsl == false

  test "loadEmailConfig with no file at the path returns defaults":
    let cfg = loadEmailConfig("/nonexistent/email.toml")
    check cfg.smtpHost == ""
    check cfg.smtpPort == 587

suite "Email Config Parsing":
  let tmpDir = getTempDir() / "talos_test_email_toml"

  setup:
    createDir(tmpDir)

  teardown:
    removeDir(tmpDir)

  test "parses a full [email] section":
    let cfgFile = tmpDir / "email.toml"
    writeTempFile(cfgFile, """
[email]
from_address = "talos@example.com"
smtp_host = "smtp.example.com"
smtp_port = 465
smtp_user = "talos@example.com"
smtp_password = "hunter2"
smtp_use_ssl = true
smtp_use_starttls = false
""")
    let cfg = loadEmailConfig(cfgFile)
    check cfg.fromAddress == "talos@example.com"
    check cfg.smtpHost == "smtp.example.com"
    check cfg.smtpPort == 465
    check cfg.smtpUser == "talos@example.com"
    check cfg.smtpPassword == "hunter2"
    check cfg.smtpUseSsl == true
    check cfg.smtpUseStartTls == false

  test "malformed file falls back to defaults instead of raising":
    let cfgFile = tmpDir / "bad.toml"
    writeTempFile(cfgFile, "this is not [valid toml at all =")
    let cfg = loadEmailConfig(cfgFile)
    check cfg.smtpPort == 587  # still the default

  test "TALOS_EMAIL_SMTP_PASSWORD env var overrides the file's password":
    let cfgFile = tmpDir / "email.toml"
    writeTempFile(cfgFile, """
[email]
smtp_host = "smtp.example.com"
smtp_password = "from-file"
""")
    putEnv("TALOS_EMAIL_SMTP_PASSWORD", "from-env")
    defer: delEnv("TALOS_EMAIL_SMTP_PASSWORD")
    let cfg = loadEmailConfig(cfgFile)
    check cfg.smtpPassword == "from-env"

suite "toEmailOptions":
  test "adapts EmailConfig into EmailOptions with a sensible timeout default":
    var ecfg = defaultEmailConfig()
    ecfg.smtpHost = "smtp.example.com"
    ecfg.fromAddress = "talos@example.com"
    let opts = toEmailOptions(ecfg)
    check opts.smtpHost == "smtp.example.com"
    check opts.fromAddress == "talos@example.com"
    check opts.timeoutMs > 0

  test "zero smtp_port falls back to the default port":
    var ecfg = EmailConfig(smtpPort: 0)
    let opts = toEmailOptions(ecfg)
    check opts.smtpPort == 587
