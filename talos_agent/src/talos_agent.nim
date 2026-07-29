## Talos agent CLI.
##
## Provides the user-facing command-line interface for the Talos agent.
## Subcommands:
##   - chat                  Fullscreen TUI (also the default with no args)
##   - ask <question>        One-shot question
##   - session <id>          Resume an existing session, then chat
##   - sessions              List recent sessions
##   - search <query>        Full-text search across stored messages
##   - run <persona> <task>  Spawn a named persona agent
##   - web                    Start the web UI server
##   - daemon                Start the Discord bot daemon
##
## Configuration is loaded by `talos_core/config.loadConfig()`. Per-run
## flags `--model`, `--provider`, and `--temperature` override the values
## in the loaded config without touching disk.
##
## Sub-modules:
##   - state          AgentGlobals + Ctrl+C handling
##   - config         RunOverrides + loadConfigWithOverrides
##   - cli            Output formatting, input, session listing, persona loading
##   - delegate_tool  Delegate tool + buildRegistry
##   - commands       Chat, ask, session, sessions, search, run, web
##   - daemon         Discord daemon command + API wrappers

import talos_agent/state
import talos_agent/config
import talos_agent/cli
import talos_agent/delegate_tool
import talos_agent/commands
import talos_agent/daemon

# Re-export so tests using `import talos_agent` can access all symbols.
export state, config, cli, delegate_tool, commands, daemon

when isMainModule:
  import cligen
  import std/os as sysos

  ## We dispatchMulti so the user invokes subcommands as
  ##   talos_agent chat
  ##   talos_agent ask "what is 2+2?"
  ##   talos_agent session sess_...
  ##   talos_agent sessions
  ##   talos_agent search "needle"
  ##   talos_agent run code_reviewer "review the auth module"
  ##
  ## No subcommand at all is shorthand for `chat` (the fullscreen TUI) —
  ## cligen's own no-args behavior is to print help, so that case is
  ## special-cased below instead of going through dispatchMulti.
  if sysos.paramCount() == 0:
    quit(cmdChat())

  dispatchMulti(
    [cmdChat,    cmdName = "chat",    help = {
      "model":       "override model name",
      "provider":    "override provider (openrouter|vllm)",
      "temperature": "override sampling temperature (0..2). " &
                     "Negative means leave at config default.",
      "config":      "path to TOML config (overrides default)",
      "envFile":     "path to .env file (default: .env)",
      "noStream":    "disable token-by-token streaming output",
    }],
    [cmdAsk,     cmdName = "ask",     help = {
      "model":       "override model name",
      "provider":    "override provider (openrouter|vllm)",
      "temperature": "override sampling temperature (0..2). " &
                     "Negative means leave at config default.",
      "config":      "path to TOML config (overrides default)",
      "envFile":     "path to .env file (default: .env)",
      "noStream":    "disable token-by-token streaming output",
      "plan":        "use plan-execute mode instead of ReAct loop",
    }],
    [cmdSession, cmdName = "session", help = {
      "model":       "override model name",
      "provider":    "override provider (openrouter|vllm)",
      "temperature": "override sampling temperature (0..2). " &
                     "Negative means leave at config default.",
      "config":      "path to TOML config (overrides default)",
      "envFile":     "path to .env file (default: .env)",
      "noStream":    "disable token-by-token streaming output",
    }],
    [cmdSessions, cmdName = "sessions", help = {
      "limit":       "max sessions to show",
      "config":      "path to TOML config (overrides default)",
      "envFile":     "path to .env file (default: .env)",
    }],
    [cmdSearch,  cmdName = "search",  help = {
      "limit":       "max matches to show",
      "semantic":    "also search retained facts semantically and merge results",
      "config":      "path to TOML config (overrides default)",
      "envFile":     "path to .env file (default: .env)",
    }],
    [cmdRunPersona, cmdName = "run", help = {
      "persona":     "name of the persona to run (from personas.toml)",
      "task":         "task description for the persona agent",
      "config":      "path to TOML config (overrides default)",
      "envFile":     "path to .env file (default: .env)",
    }],
    [cmdWeb,      cmdName = "web",      help = {
      "port":        "port to listen on (default: 8080 from config/env)",
      "config":      "path to TOML config (overrides default)",
      "envFile":     "path to .env file (default: .env)",
    }],
    [cmdDaemon,  cmdName = "daemon",  help = {
      "config":      "path to TOML config (overrides default)",
      "envFile":     "path to .env file (default: .env)",
    }],
  )
