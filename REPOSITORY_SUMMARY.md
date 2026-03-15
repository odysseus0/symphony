# Repository Summary

This repository is a fork of `openai/symphony` focused on production-oriented defaults and a smoother onboarding flow. The current implementation is concentrated in a single Elixir service under `elixir/`, with the repository root holding the high-level product docs and specification.

## Top-Level Layout

- `README.md`: project overview, quick start, and differences from upstream.
- `SPEC.md`: the detailed service specification, including workflow/config schema, orchestration rules, safety invariants, and a validation matrix.
- `.github/workflows/`: CI for `make all` and PR description linting.
- `elixir/`: the active Mix project.

## Elixir Project Map

- `elixir/WORKFLOW.md`: example workflow contract used to configure tracker, workspace creation hooks, Codex runtime settings, and the prompt template passed to agents.
- `elixir/lib/symphony_elixir/`: orchestration runtime.
- `elixir/lib/symphony_elixir_web/`: Phoenix dashboard and JSON observability API.
- `elixir/docs/`: focused operational docs for logging and token accounting.
- `elixir/test/`: ExUnit coverage, dashboard snapshots, Mix task tests, and a live end-to-end test.

The codebase is small and concentrated: `36` files under `elixir/lib`, `28` files under `elixir/test`, and `2` focused docs under `elixir/docs`.

## Runtime Flow

1. `SymphonyElixir.CLI` starts the service from a `WORKFLOW.md` path and requires an explicit acknowledgement flag before launch.
2. `SymphonyElixir.Workflow` loads YAML front matter plus the Markdown prompt body from `WORKFLOW.md`.
3. `SymphonyElixir.Orchestrator` polls Linear for candidate issues, enforces concurrency/retry limits, and schedules agent work.
4. `SymphonyElixir.Workspace` creates a per-issue workspace under the configured workspace root and runs lifecycle hooks such as `after_create` and `before_remove`.
5. `SymphonyElixir.AgentRunner` starts a Codex app-server session, renders the issue prompt, and keeps taking continuation turns while the Linear issue remains active.
6. `SymphonyElixir.Codex.AppServer` speaks JSON-RPC over stdio to Codex and exposes the dynamic tool bridge used by the workflow.
7. `SymphonyElixir.Linear.Adapter` and related client modules fetch/update issue state and comments in Linear.
8. `SymphonyElixir.HttpServer` and the Phoenix modules expose the dashboard and JSON observability endpoints when a server port is configured.

## Key Implementation Areas

- `elixir/lib/symphony_elixir/config/schema.ex`: typed config parsing and defaults for tracker, polling, workspace, agent, Codex, hooks, and observability/server settings.
- `elixir/lib/symphony_elixir/path_safety.ex` and `elixir/lib/symphony_elixir/workspace.ex`: workspace root enforcement and symlink/path safety checks.
- `elixir/lib/symphony_elixir/prompt_builder.ex`: renders the workflow prompt with Liquid/Solid templates and issue data.
- `elixir/lib/mix/tasks/`: repo-specific development guardrails such as `specs.check`, `pr_body.check`, and workspace cleanup helpers.

## Developer Workflow

The repo expects Elixir `1.19.5` on OTP `28` via `mise`.

Common commands:

- `make -C elixir setup`
- `make -C elixir build`
- `make -C elixir test`
- `make -C elixir coverage`
- `make -C elixir dialyzer`
- `make -C elixir all`

The CI entry point is `make all`. PR descriptions are also linted against `.github/pull_request_template.md`.

## Operational Constraints And Risks

- The Elixir README explicitly calls this implementation prototype software intended for evaluation rather than a hardened production service.
- Real end-to-end validation depends on external systems: `make -C elixir e2e` requires `LINEAR_API_KEY` and `codex` on `PATH`.
- The workflow depends on non-standard Linear states such as `Rework`, `Human Review`, and `Merging`.
- Workspace safety is a core design constraint; the implementation is careful not to run Codex in the source repo and rejects workspace paths that escape the configured root.
- The root `SPEC.md` is the authoritative behavior contract, so meaningful runtime changes should stay aligned with that document.
