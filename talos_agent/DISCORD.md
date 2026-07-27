# Discord Integration

Talos features a complete, DI-based Discord integration that bridges the `AgentDispatcher` (from `talos_core`) with Dimscord. The bot listens for mentions and commands, routes conversations into threads, and maintains session continuity using SQLite.

All Discord-specific code lives in `talos_agent` — `talos_core` has no knowledge of Discord and depends only on the generic `ToolAcl` type for permission gating (see `talos_core/acl.nim`, `talos_core/permission.nim`).

## Configuration

Discord config is loaded from its own file, independent of `talos_core`'s `config.toml` — default path `~/.config/talos/discord.toml` (override with `cmdDaemon`'s `discordConfig` param). See `talos_agent/discord/discord_config.nim`.

```toml
[discord]
# The environment variable holding the Discord token (default: DISCORD_BOT_TOKEN)
token_env = "DISCORD_BOT_TOKEN"
# Command prefix for bot commands (default: !)
prefix = "!"

[discord.admins]
# List of Discord user IDs who have admin privileges
allow = ["1234567890"]
deny = []

[discord.users]
# List of Discord user IDs allowed to interact with the bot
# If empty, all users can interact (subject to other limits)
allow = []
deny = []

[discord.file_rules]
# File access rules for the read/write tools
allow = ["src/*", "docs/*"]
deny = [".env*", "*.key", ".git/*"]
# Optional: sandbox root for file tool paths (also settable via
# TALOS_FILE_SANDBOX_DIR, which takes precedence)
sandbox_dir = ""

[discord.tools]
# Control which users can use which tools
allow = []
deny = []
```

Note: empty `admins`/`users` allow-lists mean nobody is authorized — the allow-list must be populated with real Discord user IDs before running the daemon for real.

## Permission Model

Discord's config is adapted into `talos_core`'s product-agnostic `ToolAcl` at the boundary (`toToolAcl(cfg: DiscordConfig): ToolAcl` in `discord_types.nim`), which `talos_core/permission.nim` then evaluates:
1. **Bot Interaction (`discord.users`)**: Controls who can send messages to the bot and mention it.
2. **Bot Administration (`discord.admins`)**: Controls who can use administrative commands (like `!config`, `!admin`).
3. **Tool Usage (`discord.tools`)**: Restricts certain tools (like `file_write`, `shell`) to specific users, by risk tier.

## File Tool Configuration

The File Tool uses `discord.file_rules` to determine access:
- **allow**: Paths the bot can read/write without restriction.
- **deny**: Paths that are strictly forbidden. There are mandatory deny rules for credentials (`.env`, `.ssh`, etc.) enforced regardless of config.

## Bot Commands Reference

Commands can be invoked in channels where the bot is present using the configured prefix (`!` by default).

### `!status`
Available to: All allowed users
Shows the bot's current status, uptime, loaded config paths, and active admins.

### `!config`
Available to: Admins only
- `!config show`: Dumps the current parsed configuration.
- `!config set <key> <value>`: Updates a configuration value in memory.
- `!config reload`: Reloads the configuration from disk.
- `!config allowlist <add|remove|list> [path]`: Manages the dynamic file allowlist in memory.

### `!admin`
Available to: Admins only
- `!admin restart`: Restarts the bot process.
- `!admin reconnect`: Forces the Dimscord gateway to reconnect.

### `!session`
Available to: All allowed users
Manage the current agent session.

## Running the Daemon

To run the Talos Discord bot, use the `daemon` command in the CLI:

```bash
export DISCORD_BOT_TOKEN="your_token_here"
talos_agent daemon
```

This will initialize the database, load `config.toml` and `discord.toml`, and connect to Discord via the Gateway.

## Local Testing Instructions

The Discord integration is built using Dependency Injection. `talos_agent/discord/discord.nim` depends on callback procs for API actions rather than raw Dimscord endpoints.

To run the End-to-end Discord tests locally:

```bash
cd talos_agent
nim c --path:src --path:../talos_core/src --threads:on -r tests/test_e2e_discord.nim
```

The E2E test uses `MockDiscordApi` and `MockShard` to completely simulate Discord's HTTP and Gateway interfaces, allowing full coverage of session routing, thread creation, permission checks, and file tools without making real network requests.

### Test Suite

All Discord-related tests live in `talos_agent/tests/`:

| Test file | Tests | What it covers |
|-----------|-------|----------------|
| `test_discord_mocks.nim` | Mock API and shard | Verifies mock objects correctly simulate Discord behavior |
| `test_discord_commands.nim` | Command handlers | `!status`, `!config`, `!admin`, `!session` parsing + execution |
| `test_discord_bot.nim` | Bot integration | `onMessageCreate` routing, DI wiring, permission checks |
| `test_discord_config.nim` | Discord config parsing | TOML → `DiscordConfig`, env var overrides |
| `test_e2e_discord.nim` | End-to-end flow | Full session: message → permission → agent dispatch → response |
| `test_thread_mapping.nim` | Thread persistence | SQLite-backed channel→thread mapping |
| `test_thread_reconnection.nim` | Thread reuse | Reconnecting to an existing thread; new thread after archival |
| `test_daemon_delegation.nim` | Daemon delegation | `daemon.nim` wiring of `ToolAcl` into delegated child agents |

Generic (non-Discord) permission/file/path tests (`test_permission.nim`, `test_file_tool.nim`, `test_file_path_validator.nim`, `test_message_chunker.nim`) live in `talos_core/tests/` — Discord just consumes those modules.

### Architecture

```
Discord Gateway ──▶ dimscord ──▶ onMessageCreate(event)
                                    │
                                    ▼
                            discord_commands.nim
                              (parse prefix + command)
                                    │
                          ┌─────────┴──────────┐
                          ▼                     ▼
                    Admin command         Agent message
                    (!config, !admin)      (mention / DM)
                          │                     │
                          ▼                     ▼
                    Execute handler     agent_dispatcher.nim (talos_core)
                                          (async queue)
                                                │
                                                ▼
                                          agent_loop.nim (talos_core)
                                          (ReAct loop)
                                                │
                                                ▼
                                          sendFn callback
                                          (chunkMessage → reply)
```

### Module Reference

| Module | Location | Purpose |
|--------|----------|---------|
| `discord.nim` | `talos_agent/discord/discord.nim` | `DiscordBot` ref object with DI callbacks, `onMessageCreate` handler |
| `discord_bridge.nim` | `talos_agent/discord/discord_bridge.nim` | `RealDiscordApi` — wraps dimscord REST API |
| `discord_commands.nim` | `talos_agent/discord/discord_commands.nim` | Command parsing + handler dispatch |
| `discord_types.nim` | `talos_agent/discord/discord_types.nim` | `DiscordConfig`, `FileRules`, `toToolAcl` adapter |
| `discord_config.nim` | `talos_agent/discord/discord_config.nim` | Loads `discord.toml` independent of core's `config.toml` |
| `discord_mocks.nim` | `talos_agent/discord/discord_mocks.nim` | `MockDiscordApi`, `MockShard` for offline testing |
| `thread_mapping.nim` | `talos_agent/discord/thread_mapping.nim` | Persistent channel↔thread mapping with SQLite |
| `acl.nim` | `talos_core/acl.nim` | Generic `AccessControl`/`ToolAcl` — the permission shape core operates on |
| `agent_dispatcher.nim` | `talos_core/agent_dispatcher.nim` | `AgentDispatcher` — async agent request queue with callback |
| `permission.nim` | `talos_core/permission.nim` | User/tool permission evaluation over `ToolAcl` |
| `file_path_validator.nim` | `talos_core/file_path_validator.nim` | Path canonicalization + security validation |
| `file_tool.nim` | `talos_core/file_tool.nim` | `fileReadTool`, `fileWriteTool` — sandboxed file operations |
| `message_chunker.nim` | `talos_core/message_chunker.nim` | Splits messages at 2000-char Discord limit |
