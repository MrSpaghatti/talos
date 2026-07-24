# Talos Agent — Project Roadmap

**Last updated**: July 24, 2026
**Current state**: All planned phases complete (518 tests, CI green on Nim 2.0.8 + 2.2.2). 7 long-horizon tasks — 5 done, 2 remaining (Task 5 Vector Memory, Task 7 MCP Streaming).

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

## 📊 Test Suite

| Package | Test Files | Tests | Status |
|---------|-----------|-------|--------|
| talos_core | 22 | 391 | ✅ All pass |
| talos_agent | 7 | 98 | ✅ All pass |
| talos_code | 1 | 29 | ✅ All pass |
| **Total** | **30** | **518** | **✅ 0 FAILED** |
