# Talos — Development Status

**Last updated**: 2026-07-30
**Verification method**: every claim below was checked directly in this
session — full test suites re-run to completion (not recalled from a
previous run), daemon state checked via `systemctl`, CI state checked via
`gh run list`, feature claims checked by grepping the actual source rather
than trusting task specs or prior status docs. A previous status pass on
this project claimed "100% done" in places that weren't — the intent here
is to not repeat that.

---

## Summary

Talos is now three separate packages: **`talos_core`** (a standalone,
Discord-agnostic foundation library, its own git repo), **`talos_agent`**
(the general ambient assistant — CLI, TUI, web UI, Discord daemon), and
**`talos_code`** (a separate coding-harness agent, out of scope for feature
work). `talos_agent` and `talos_code` still live together in one repo
(`github.com/mrspaghatti/talos`); `talos_core` was extracted to
`github.com/mrspaghatti/talos_core` and is consumed as a pinned git
dependency.

The Discord daemon is **live** — running under systemd, connected, and has
already crash-reported and recovered at least once in the wild. This is the
first time in the project's history it's actually been deployed rather than
just built.

## Verified test state (this session)

| Package | Test files | Checks | Result |
|---|---|---|---|
| `talos_core` | 23 | 496 | ✅ 0 failed |
| `talos_agent` | 23 | 273 | ✅ 0 failed |
| `talos_code` | 1 | 33 | ✅ 0 failed |
| **Total** | **47** | **802** | **✅ 0 failed** |

Each suite was run to completion via `nimble test -y` with full,
untruncated output inspected for `[FAILED]` — not inferred from exit code
alone.

## CI / repo state — ✅ clean

- Local `main` and `origin/main` are in sync at `03d9b30` (repin to
  talos_core v1.15.1); nothing outstanding to push.
- GitHub Actions on `origin/main` is **green on both matrix legs** (Nim
  2.0.x and 2.2.x) — confirmed via `gh run view` on run `30517592876`
  for `03d9b30`.
- **`talos_core` now has its own CI** (`.github/workflows/ci.yml` in that
  repo, same Nim 2.0.x/2.2.x matrix, deliberately no `restore-keys` cache
  fallback after the monorepo's stale-cache poisoning). Green on both legs
  for v1.15.1 (run `30517586141`). It earned its keep on its very first
  run by catching a real bug: `newMemory` ran `PRAGMA journal_mode=WAL`
  *before* setting `busy_timeout`, so a concurrent open during a write
  failed instantly with "database is locked" — live-relevant, since the
  daemon plus a concurrent CLI/TUI share one DB. Fixed in v1.15.1
  (timeout set first).
- Unbounded-growth items from the audit follow-up are closed in
  v1.15.0 + `9517cdb`: `gPendingNotes` (`advisor.nim`) is now an
  `OrderedTable` capped at 256 with oldest-first eviction, and the TUI
  transcript caps at 2000 entries (trims to newest 1500, clamps
  `scrollOffset`). Four new tests cover them.
- Getting there took a chain of fixes, each surfaced only once the prior
  one was resolved and CI progressed further:
  1. All 5 items of the 2026-07-29 audit findings (below) — SQLite handle
     leak, unbounded MCP SSE retry, `gGlobals` mutation race, `talos_code`
     write/sandbox hardening, stream-truncation misclassification. Shipped
     as monorepo commit `e2883e3` + `talos_core` v1.14.0 (commit `b3b1b46`
     in that repo).
  2. GH Actions nimble cache poisoning: loose `restore-keys` let a
     `.nimble`-file change (the v1.14.0 repin) inherit a stale
     `~/.nimble` predating the `ToolAcl`/`DiscordConfig` decoupling,
     producing a phantom compile error. Fixed by dropping the fallback
     keys (`4519174`).
  3. A genuine Nim-2.0.x-only bug: that series unconditionally excludes
     Linux from `posix_spawn`, so `poDaemon`'s process-group setup
     silently never happens there, breaking the shell tool's
     timeout-kill. Fixed by walking `/proc/<pid>/task/<pid>/children`
     directly instead of trusting process groups, in both
     `talos_agent/src/tools/shell.nim` (`e087f75` was an insufficient
     first attempt, `1cf6b7d` the working fix) and `talos_code`'s
     independent copy in `compile.nim` (`db39637`).
  4. A missing D-Bus session bus in the GitHub runner, needed by the
     browser tool's live-Chrome tests. Fixed by wrapping the test step in
     `dbus-run-session --` (`2d90df9`).

## Live deployment

- systemd user unit `talos-daemon.service`: **enabled**, `Restart=always`,
  `linger` on — survives logout and crashes.
- Confirmed running and connected this session (`systemctl --user status`):
  bot "Raven" online, PID live, clean startup log. Restarted 2026-07-30
  onto the binary rebuilt against `talos_core` v1.15.1 (picks up the
  busy_timeout/WAL ordering fix and the gPendingNotes cap); "Connected as
  Raven" confirmed post-restart.
- `~/.config/talos/discord.toml` exists and is loaded.
- `~/.local/share/talos/crash_reports/latest.log` exists with a real entry
  from 2026-07-27 — the crash-report path has actually fired once in
  production, not just in tests.
- Not independently re-verified this session: `!status`/`!config`/`!admin`/
  `!session` command behavior against a live non-admin account, or a
  forced-crash DM-to-admin round trip. Both were verified once during Phase
  3's initial standup; not repeated here.

---

## Architecture

```
github.com/mrspaghatti/talos_core (standalone repo, pinned by version tag)
  config, llm_client (+ role-based routing/fallback chains), token_counter,
  memory (SQLite + FTS5 + brute-force cosine vector recall), embeddings,
  tool_registry, agent_loop, agent_dispatcher, plan_executor, persona
  (+ delegation routing + advisor), mcp_client/mcp_tool (SSE + streamable
  HTTP), heartbeat, crash_report, code_summary, acl/permission/
  file_path_validator/file_tool, message_chunker, posix_io, util,
  testkit/ (shared mock servers for downstream test suites)

github.com/mrspaghatti/talos (monorepo)
  talos_agent/   CLI (cli.nim, commands.nim), TUI (tui/chat_tui.nim +
                 overlay/input_bar/theme/transcript/streaming), web_server,
                 Discord stack (discord/ — bot, bridge, commands, config,
                 thread_mapping, mocks), session_alias (cross-surface
                 continuity), voice (persona/system-prompt pass),
                 delegate_tool, email_config, tools/ (shell, browser, email,
                 memory_tools[retain/recall/reflect])
  talos_code/    talos_code.nim, code_runner, code_tool, compile
                 — untouched by this plan except "don't break it"
```

---

## Feature status, verified against source

### Done and confirmed working

| Feature | Where | Notes |
|---|---|---|
| Core/Discord decoupling | `talos_core` has zero `DiscordConfig`/`dimscord` references | `ToolAcl` replaces `DiscordConfig` in `permission.nim`/`file_tool.nim` |
| `talos_core` as standalone repo | `github.com/mrspaghatti/talos_core`, tags v1.0.0–v1.15.1, own CI green | consumed via pinned `requires` (v1.15.1) in both consumer `.nimble` files |
| Discord daemon, live | systemd unit, confirmed running | see Live Deployment above |
| Crash reporting | `crash_report.nim` (`RingLogger` + `writeCrashReport`) | has a real captured crash on disk |
| Proactive heartbeat | `heartbeat.nim`, wired into daemon | interval-tick scheduler; check logic still minimal by design |
| Personality/voice pass | `voice.nim` | system-prompt/persona rework, not generic-assistant tone |
| Cross-surface continuity | `session_alias.nim` | CLI/TUI/Discord can share session identity |
| TUI flare | `tui/theme.nim`, `tui/transcript.nim` | role labels, tool-call coloring, spacing |
| `/btw` ephemeral question | `chat_tui.nim: runBtwTurn`/`handleSlashCommand` | **TUI only** — not in Discord, not in `ask`/non-TUI `chat` |
| Email tool | `tools/email.nim` | SMTP send + IMAP read/search, riskHigh-gated |
| Browser tool | `tools/browser.nim` | headless Chrome via CDP, riskHigh-gated |
| Vector memory (Task 5) | `memory.nim` + `embeddings.nim`, `retain`/`recall`/`reflect` tools | brute-force cosine, hybrid FTS5+semantic search (`--semantic` CLI flag) |
| MCP streaming (Task 7) | `mcp_client.nim`/`mcp_tool.nim` | SSE + streamable-HTTP transport, `tool_list_changed` reconciliation, tested against a real reference MCP server |
| Role-based model routing (task-13) | `build_llm_client.nim` | `[roles.*]` config, per-role fallback chains |
| Subagent dispatch routing (task-17) | `persona.nim: routeToDelegate` | keyword-overlap auto-routing, explicit persona still wins |
| Advisor role (task-16) | `advisor.nim`, wired in `agent_dispatcher.nim` | reviews transcript post-turn, injects a note into the next turn only, never persisted |
| Summarized reads (task-18) | `code_summary.nim`, `file_tool.nim` | structural summary above a line threshold; `full=true` bypasses it; `talos_code`'s own read tool deliberately untouched |
| 2026-07-29 audit findings (5/5) | see [ROADMAP.md](ROADMAP.md) audit table | SQLite handle leak, MCP SSE retry/timeout, `gGlobals` atomic replace, `talos_code` write/sandbox hardening, stream-truncation reclassification — all fixed, tested, shipped |

### Real but partial

| Feature | Gap |
|---|---|
| Slash commands (task-09) | Works in the TUI (`/help /new /session /model /info /btw /quit`) via an inline `handleSlashCommand` in `chat_tui.nim` — but the dedicated `slash_commands.nim` module the original spec called for was never split out, and none of this exists outside the TUI. |
| URI-scheme tool addressing | Recommended as part of Task 7's design (`read://`/`search://`/`write://`-style prefix dispatch unifying MCP and local tools) — the core SSE streaming work landed, this specific unification did not. |

### Not done

| Item | Status |
|---|---|
| Bang commands, `!<cmd>` shell interception in CLI/TUI (task-10) | No interceptor found in `commands.nim`/`cli.nim`. (Discord's separate `!status`/`!config`/`!admin`/`!session` prefix commands are unrelated and *are* implemented.) |
| Preview-then-accept edit workflow (task-12) | Deliberately deferred — `talos_code`-specific, out of scope for this plan. |
| Checkpoints / context pruning (task-14) | **Not implemented** — no checkpoint/rewind concept anywhere in `memory.nim`, `agent_loop.nim`, or the CLI. This was previously tracked as done alongside `/btw`; that was incorrect — only `/btw` shipped. |
| Session branching, `/tree` (task-15) | Deliberately deferred — no concrete need yet. |

---

## Known issues

- `tllm_client.nim`'s mock TCP server doesn't join cleanly on exit — cosmetic
  ~2s hang at shutdown when run in the full batch, not test-correctness
  affecting.

---

## Next

See [ROADMAP.md](ROADMAP.md) for the tracking table. With Phases 0–7 of the
alpha→prod plan complete, both repos' CI green, and the prod-hardening
items (core CI, unbounded-growth caps, v1.15.1 rollout to the live daemon)
shipped, the only open decision is whether task-10/task-14 (bang commands,
checkpoints) are worth picking back up or formally deferring like
task-12/task-15.
