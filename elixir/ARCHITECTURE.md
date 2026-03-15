# Architecture

Symphony is a long-running Elixir service that polls issue trackers, creates isolated per-issue workspaces, and dispatches AI coding agents to work on each issue.

## System Overview

```
┌─────────────┐     poll      ┌──────────────┐    dispatch    ┌──────────────┐
│ Issue Tracker│◄────────────►│  Orchestrator │──────────────►│ AgentRunner  │
│ (Linear/Plane)              │  (GenServer)  │               │              │
└─────────────┘               └──────────────┘               └──────┬───────┘
                                     │                               │
                              ┌──────┴───────┐              ┌───────▼───────┐
                              │   Config     │              │ AgentBackend  │
                              │ (WORKFLOW.md)│              │  (Behaviour)  │
                              └──────────────┘              └───────┬───────┘
                                                                    │
                                                    ┌───────────────┼───────────────┐
                                                    ▼               ▼               ▼
                                              ┌──────────┐  ┌──────────┐  ┌──────────┐
                                              │  Codex   │  │  Claude  │  │ OpenCode │
                                              │AppServer │  │  Code   │  │          │
                                              └──────────┘  └──────────┘  └──────────┘
```

## Tech Stack

- **Language**: Elixir 1.19 / OTP 28
- **HTTP Server**: Bandit ~1.8 + Phoenix ~1.8.0
- **Live Dashboard**: Phoenix LiveView ~1.1.0
- **HTTP Client**: Req ~0.5
- **Config Parsing**: YamlElixir ~2.12, Ecto ~3.13 (schema validation only)
- **Templating**: Solid ~1.2 (Liquid templates for prompts)
- **JSON**: Jason ~1.4
- **Quality**: Credo, Dialyxir

## Component Map

| Directory | Purpose |
|-----------|---------|
| `lib/symphony_elixir/orchestrator.ex` | Core GenServer — polls tracker, dispatches issues, manages concurrency and retries |
| `lib/symphony_elixir/agent_runner.ex` | Executes a single issue: creates workspace, runs agent turns, handles continuation |
| `lib/symphony_elixir/agent_backend.ex` | Behaviour for AI runtime backends |
| `lib/symphony_elixir/backend/` | Backend implementations (Codex, Claude Code, OpenCode, etc.) |
| `lib/symphony_elixir/codex/` | Codex app-server protocol: port management, message parsing, dynamic tools |
| `lib/symphony_elixir/config.ex` | Runtime config accessor — loads from WORKFLOW.md YAML frontmatter |
| `lib/symphony_elixir/config/` | Ecto schemas for config validation, runtime resolution |
| `lib/symphony_elixir/tracker.ex` | Tracker behaviour — abstraction over issue tracker APIs |
| `lib/symphony_elixir/tracker/` | Tracker implementations and adapters |
| `lib/symphony_elixir/linear/` | Linear API client and issue types |
| `lib/symphony_elixir/plane/` | Plane API client |
| `lib/symphony_elixir/workspace.ex` | Per-issue workspace creation (git worktree isolation) |
| `lib/symphony_elixir/prompt_builder.ex` | Builds agent prompts from issue context + Liquid templates |
| `lib/symphony_elixir/status_dashboard.ex` | Terminal dashboard — running issues, runtimes, status |
| `lib/symphony_elixir/cli.ex` | Escript entry point |
| `lib/symphony_elixir/http_server.ex` | Phoenix endpoint setup for observability API |

## Data Flow

1. **Poll** — Orchestrator queries tracker (Linear/Plane) for issues in configured active states
2. **Filter** — Issues already running or recently completed are skipped
3. **Route** — `Config.resolve_runtime_for_issue/1` matches issue labels → runtime (codex/claude/opencode)
4. **Dispatch** — AgentRunner spawned as Task under Orchestrator's TaskSupervisor
5. **Workspace** — Git worktree created under configured workspace root
6. **Execute** — Backend.start_session → Backend.run_turn in a loop until issue leaves active state or max_turns reached
7. **Cleanup** — After-run hooks execute; workspace may be preserved or cleaned up

## Configuration

All runtime config lives in `WORKFLOW.md` YAML frontmatter at the repo root. Loaded by `SymphonyElixir.Workflow` → validated by `SymphonyElixir.Config.Schema` (Ecto embedded schemas).

Key config sections: `tracker`, `agent`, `codex`, `runtimes`, `workspace`, `prompt`.

## Deployment

- Built as escript (`mix escript.build` → `bin/symphony`)
- Runs as long-lived daemon (launchd on macOS)
- No database — all state is in-memory (Orchestrator GenServer) + issue tracker
- Observability via Phoenix LiveView dashboard and JSON API
