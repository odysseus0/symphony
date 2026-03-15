# Backend Operations Guide

This guide covers day-2 operations for multi-backend runs.

## Logging and Debugging by Backend

## 1. Confirm routed backend command

Use label-based routing config in `WORKFLOW.md`:

- `codex.command` (default fallback)
- `codex.command_by_label` (label overrides)

If a backend appears incorrect, inspect the issue labels and command map first.

## 2. Inspect runtime logs

Run Symphony with log output enabled and filter by issue/session context:

```bash
cd elixir
mix run -e 'SymphonyElixir.CLI.main(["WORKFLOW.md"])'
```

Useful patterns:

- `issue_id=<...> issue_identifier=<...>`
- `session_id=<thread>-<turn>`
- `startup_failed`
- `turn_ended_with_error`

## 3. Reproduce backend process behavior with focused tests

```bash
cd elixir
mix test test/symphony_elixir/multi_backend_fallback_test.exs
mix test test/symphony_elixir/multi_backend_concurrency_test.exs
```

These tests provide deterministic startup-failure, timeout, and cross-issue isolation signals.

## Langfuse: Distinguish Traces Across Backends

When Langfuse is enabled in your deployment pipeline, store backend identity on every trace/span as metadata.

Recommended fields:

- `backend`: `codex | opencode | claude`
- `issue_id`: Linear issue UUID
- `issue_identifier`: human-readable key (for example `BUB-87`)
- `session_id`: `<thread_id>-<turn_id>`

Recommended conventions:

- Trace name: `symphony.agent.run`
- Span name: `backend.<backend>.turn`
- Tags: `backend:<name>`, `team:<team_key>`, `project:<slug>`

This makes backend-specific latency/error slices straightforward in Langfuse dashboards.

## Troubleshooting Checklist

- [ ] Labels are present and match `codex.command_by_label` keys exactly after lowercase/trim normalization.
- [ ] Each configured backend command (`codex.command` or `SYMPHONY_LIVE_*_COMMAND`) can complete the app-server initialize/thread handshake.
- [ ] `LINEAR_API_KEY` is set and valid for the target workspace/project.
- [ ] `codex.turn_timeout_ms` and `codex.read_timeout_ms` are high enough for backend startup latency.
- [ ] `mix test test/symphony_elixir/backend_protocol_consistency_test.exs` passes after protocol changes.
- [ ] `mix test test/symphony_elixir/live_e2e_test.exs` is executed with `SYMPHONY_RUN_LIVE_E2E=1` in a real environment.

## Incident Triage Order

1. Reproduce with fallback/concurrency tests.
2. Validate routing labels and resolved command.
3. Inspect startup and turn lifecycle logs by `session_id`.
4. Check Langfuse traces grouped by `backend`.
5. Re-run live E2E matrix after fixes.
