## Discord configuration types.

import talos_core/file_path_validator
import talos_core/acl
export acl  ## Re-export AccessControl/ToolAcl so callers that only import
            ## discord_types (the common case) get both without a second import.

type
  DiscordConfig* = object
    tokenEnv*: string
    prefix*: string
    admins*: AccessControl
    users*: AccessControl
    fileRules*: AccessControl
    fileSandboxDir*: string  ## Optional: confines file_read/file_write to this
                             ## directory (and its descendants) when set. Empty
                             ## by default — purely opt-in, no forced default.
    tools*: AccessControl
    daemonDelegation*: bool  ## Enable agent delegation and MCP tools in daemon mode

proc defaultDiscordConfig*(): DiscordConfig =
  result = DiscordConfig(
    tokenEnv: "DISCORD_BOT_TOKEN",
    prefix: "!",
    admins: AccessControl(allow: @[], deny: @[]),
    users: AccessControl(allow: @[], deny: @[]),
    # The mandatory deny patterns (file_path_validator.mandatoryDenyPatterns)
    # are always enforced independently of this list — this is just a
    # sensible starting default for the user-configurable deny list.
    fileRules: AccessControl(allow: @[], deny: mandatoryDenyPatterns),
    fileSandboxDir: "",
    tools: AccessControl(allow: @[], deny: @[]),
    daemonDelegation: false
  )

proc toToolAcl*(cfg: DiscordConfig): ToolAcl =
  ## Adapts Discord's config into core's product-agnostic ACL shape.
  ## A literal field copy — DiscordConfig.admins/users/tools are already
  ## AccessControl, core's own type.
  ToolAcl(admins: cfg.admins, users: cfg.users, tools: cfg.tools)
