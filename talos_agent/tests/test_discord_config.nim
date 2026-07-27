## Tests for Discord config parsing (talos_agent/discord/discord_config.nim).
##
## Discord config is loaded from its own TOML file, independent of
## talos_core's config.toml — see discord_config.nim for why.

import std/[os, unittest]
import talos_agent/discord/discord_config
import talos_agent/discord/discord_types
import talos_core/file_path_validator

proc writeTempFile(path, content: string) =
  createDir(parentDir(path))
  writeFile(path, content)

suite "Discord Config Defaults":
  test "default discord config has expected values":
    let cfg = defaultDiscordConfig()
    check cfg.tokenEnv == "DISCORD_BOT_TOKEN"
    check cfg.prefix == "!"
    check cfg.admins.allow.len == 0
    check cfg.admins.deny.len == 0
    check cfg.users.allow.len == 0
    check cfg.users.deny.len == 0
    check cfg.fileRules.allow.len == 0
    check cfg.fileRules.deny == mandatoryDenyPatterns
    check cfg.fileSandboxDir == ""
    check cfg.tools.allow.len == 0
    check cfg.tools.deny.len == 0

  test "loadDiscordConfig with no file at the path returns defaults":
    let cfg = loadDiscordConfig("/nonexistent/discord.toml")
    check cfg.tokenEnv == "DISCORD_BOT_TOKEN"
    check cfg.prefix == "!"

suite "Discord Config Parsing":
  let tmpDir = getTempDir() / "talos_test_discord_toml"

  setup:
    createDir(tmpDir)

  teardown:
    removeDir(tmpDir)

  test "parses basic [discord] section":
    let cfgFile = tmpDir / "discord.toml"
    writeTempFile(cfgFile, """
[discord]
token_env = "MY_CUSTOM_TOKEN"
prefix = "?"
""")
    let cfg = loadDiscordConfig(cfgFile)
    check cfg.tokenEnv == "MY_CUSTOM_TOKEN"
    check cfg.prefix == "?"

  test "parses [discord.admins] access control":
    let cfgFile = tmpDir / "discord.toml"
    writeTempFile(cfgFile, """
[discord.admins]
allow = "123, 456"
deny = "789"
""")
    let cfg = loadDiscordConfig(cfgFile)
    check cfg.admins.allow == @["123", "456"]
    check cfg.admins.deny == @["789"]

  test "parses [discord.file_rules] with comma separated lists":
    let cfgFile = tmpDir / "discord.toml"
    writeTempFile(cfgFile, """
[discord.file_rules]
allow = "*.txt, *.md"
deny = ".env, secret.key"
""")
    let cfg = loadDiscordConfig(cfgFile)
    check cfg.fileRules.allow == @["*.txt", "*.md"]
    check cfg.fileRules.deny == @[".env", "secret.key"]

  test "parses [discord.file_rules] sandbox_dir (opt-in, unset by default)":
    let cfgFile = tmpDir / "discord.toml"
    writeTempFile(cfgFile, """
[discord.file_rules]
sandbox_dir = "/some/project"
""")
    let cfg = loadDiscordConfig(cfgFile)
    check cfg.fileSandboxDir == "/some/project"

  test "TALOS_FILE_SANDBOX_DIR env var overrides sandbox_dir":
    let cfgFile = tmpDir / "discord.toml"
    writeTempFile(cfgFile, "")
    putEnv("TALOS_FILE_SANDBOX_DIR", "/env/project")
    defer: delEnv("TALOS_FILE_SANDBOX_DIR")
    let cfg = loadDiscordConfig(cfgFile)
    check cfg.fileSandboxDir == "/env/project"
