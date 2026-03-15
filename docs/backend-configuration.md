# Backend Configuration Guide

This guide shows how to configure Codex/OpenCode/Claude backend execution in `WORKFLOW.md`.

## Prerequisites

Install and verify all backend CLIs you plan to use:

```bash
codex --version
opencode --version
claude --version
```

Required environment variables:

```bash
export LINEAR_API_KEY="<linear_api_key>"
```

Live matrix command overrides:

```bash
export SYMPHONY_LIVE_CODEX_COMMAND="codex app-server"
export SYMPHONY_LIVE_OPENCODE_COMMAND="/path/to/opencode-app-server-wrapper"
export SYMPHONY_LIVE_CLAUDE_COMMAND="/path/to/claude-app-server-wrapper"
```

Notes:

- `codex` uses `codex app-server` by default when override is not set.
- `opencode` and `claude` live tests require explicit `SYMPHONY_LIVE_OPENCODE_COMMAND` and `SYMPHONY_LIVE_CLAUDE_COMMAND`.
- If those environment variables are unset, the corresponding live tests are skipped to avoid false failures in environments without app-server-compatible wrappers.

## Copy-Paste Multi-Backend `WORKFLOW.md` Example

```md
---
tracker:
  kind: linear
  endpoint: https://api.linear.app/graphql
  api_key: "$LINEAR_API_KEY"
  project_slug: "your-project-slug"
  active_states: ["Todo", "In Progress", "Merging", "Rework"]
  terminal_states: ["Done", "Closed", "Canceled", "Cancelled", "Duplicate"]

polling:
  interval_ms: 5000

workspace:
  root: ~/code/symphony-workspaces

agent:
  max_concurrent_agents: 10
  max_turns: 20

codex:
  command: "codex app-server"
  command_by_label:
    backend:codex: "codex app-server"
    backend:opencode: "opencode app-server"
    backend:claude: "claude app-server"
  approval_policy: never
  thread_sandbox: danger-full-access
  turn_sandbox_policy:
    type: dangerFullAccess

observability:
  dashboard_enabled: true
  refresh_ms: 1000
  render_interval_ms: 16
---

You are working on a Linear ticket `{{ issue.identifier }}`.
Labels: {{ issue.labels }}
```

## Per-Label Routing Rules

`codex.command_by_label` routes by issue labels:

- Symphony lowercases and trims both configured label keys and issue labels.
- It checks issue labels in their incoming order and picks the first matching command.
- If no label matches, Symphony falls back to `codex.command`.

Recommended convention:

- `backend:codex`
- `backend:opencode`
- `backend:claude`

## Validation Checklist

After configuration updates:

```bash
cd elixir
mix test test/symphony_elixir/backend_protocol_consistency_test.exs
mix test test/symphony_elixir/multi_backend_fallback_test.exs
mix test test/symphony_elixir/multi_backend_concurrency_test.exs
mix test test/symphony_elixir/live_e2e_test.exs
```

To run live E2E matrix (real services):

```bash
export SYMPHONY_RUN_LIVE_E2E=1
cd elixir && mix test test/symphony_elixir/live_e2e_test.exs
```
