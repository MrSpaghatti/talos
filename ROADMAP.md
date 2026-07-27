# Talos Agent — Project Roadmap

**Last updated**: July 24, 2026
**Current state**: All planned phases complete (557 tests, CI green on Nim 2.0.8 + 2.2.2). 7 long-horizon tasks — 5 done, 2 remaining (Task 5 Vector Memory, Task 7 MCP Streaming).

---

## ✅ Complete

| Area | Deliverable | Status |
|------|-------------|--------|
| **Phase 1 — Foundation** | config, llm_client, token_counter, memory (SQLite+FTS5) | 100% |
| **Phase 2 — Agent Core** | tool_registry, shell_tool, agent_loop, mock_server | 100% |
| **Phase 3 — CLI + Integration** | talos_agent CLI, integration wiring, docs | 100% |
| **Phase 2 — Discord Bot** | DI-based bot, permission, file_tools, rate_limit, thread_mapping, agent_dispatcher | 100% |
| **P0 — SSL + CI + Audits** | Nim 2.2.x build fix, GitHub Actions CI, deep code audits | 100% |
| **P1 — talos_code** | Autonomous coding harness (code_runner, code_tool, compile) | 100% |
| **P2 — MCP Support** | Model Context Protocol client + tool bridge (36 tests) | 100% |
| **P2 — Persona + Delegation** | Persona system, agent-to-agent delegation, scoped tool filtering (33 tests) | 100% |

All 3 packages (`talos_core`, `talos_agent`, `talos_code`) build and test on both Nim 2.0.x and 2.2.x.

## 🗺️ Planned Tasks

Detailed implementation specs in `plans/task-*.md`. Recommended execution order:

1. ~~[Task 1 — Agent Loop + Dispatcher](plans/task-01-agent-loop.md)~~ ✅
2. ~~[Task 4 — Code Quality](plans/task-04-code-quality.md)~~ ✅
3. [Task 2 — Streaming](plans/task-02-streaming.md) ✅ (CLI streaming; Discord uses a refreshed typing indicator instead of progressive edits — see task file)
4. [Task 3 — Web UI](plans/task-03-web-ui.md) ✅ (non-streaming; SSE deferred; CSRF + rate limiting implemented)
5. ~~[Task 6 — Plan-Execute](plans/task-06-plan-execute.md)~~ ✅
6. [Task 7 — MCP Streaming](plans/task-07-mcp-streaming.md)
7. [Task 5 — Vector Memory](plans/task-05-vector-memory.md)

| # | Task | Status | Complexity |
|---|------|--------|------------|
| 1 | [Agent Loop + Threading](plans/task-01-agent-loop.md) | 🟢 Done | Large |
| 2 | [Streaming Responses](plans/task-02-streaming.md) | 🟢 Done | Large |
| 3 | [Web UI](plans/task-03-web-ui.md) | 🟢 Done | Medium-Large |
| 4 | [Code Quality](plans/task-04-code-quality.md) | 🟢 Done | Small-Medium |
| 5 | [Vector Memory](plans/task-05-vector-memory.md) | 🔴 Not Started | Medium-Large |
| 6 | [Plan-Execute Mode](plans/task-06-plan-execute.md) | 🟢 Done | Medium |
| 7 | [MCP Streaming](plans/task-07-mcp-streaming.md) | 🔴 Not Started | Medium |

## 🔭 Feature Adoption Backlog (2026-07-25)

Sourced from a comparative review of oh-my-pi (omp), OpenCode, and Claude
Code — full rationale in
[plans/feature-adoption-report.md](plans/feature-adoption-report.md). Two
items are folded directly into Task 5 and Task 7 above rather than tracked
separately (see the cross-reference notes at the top of each of those task
files); the rest are their own task files, numbered continuing from the
original 10.

| # | Item | Task file | Priority | Status |
|---|------|-----------|----------|--------|
| 11 | `/btw` ephemeral side-question | [task-11](plans/task-11-btw-command.md) | 1 — cheap | 🔴 Not Started |
| 12 | Preview-then-accept edit workflow | [task-12](plans/task-12-preview-edit.md) | 1 — cheap | 🔴 Not Started |
| 13 | Role-based model routing | [task-13](plans/task-13-model-routing.md) | 1 — cheap | 🔴 Not Started |
| — | retain/recall/reflect shape | folded into [task-05](plans/task-05-vector-memory.md) | 2 — with Task 5 | 🔴 Not Started |
| 14 | Checkpoints (context pruning) | [task-14](plans/task-14-checkpoints.md) | 2 — with Task 5 | 🔴 Not Started |
| 15 | Session branching (`/tree`) | [task-15](plans/task-15-session-branching.md) | 2 — deferred | ⏸️ Deferred |
| — | URI schemes as tool interface | folded into [task-07](plans/task-07-mcp-streaming.md) | 3 — with Task 7 | 🔴 Not Started |
| 16 | Advisor role | [task-16](plans/task-16-advisor-role.md) | 3 — persona ext. | 🔴 Not Started |
| 17 | Subagent dispatch routing | [task-17](plans/task-17-subagent-dispatch.md) | 3 — persona ext. | 🔴 Not Started |
| 18 | Summarized reads | [task-18](plans/task-18-summarized-reads.md) | 3 — standalone infra | 🔴 Not Started |

Recommended sequencing: 11/12/13 now (no dependencies); fold the
retain/recall/reflect shape into Task 5 and the URI-scheme design into Task 7
when those are picked up (not as follow-ons); 16/17 whenever, no blocking
dependency; 15 deferred until there's a concrete need; 18 is a standalone
infra investment, do whenever bandwidth allows.

## 📊 Test Suite

| Package | Test Files | Tests | Status |
|---------|-----------|-------|--------|
| talos_core | 22 | 412 | ✅ All pass |
| talos_agent | 8 | 113 | ✅ All pass |
| talos_code | 1 | 32 | ✅ All pass |
| **Total** | **31** | **557** | **✅ 0 FAILED** |
