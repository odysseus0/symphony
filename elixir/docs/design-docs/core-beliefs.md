# Core Beliefs

## Spec Alignment

The Elixir implementation tracks `SPEC.md` (language-agnostic service spec). Implementation may be a superset but must not conflict. Spec updates ship with behavior changes.

## Workspace Isolation

Agent execution never touches the source repo directly. Every issue gets an isolated git worktree under a configured workspace root. This is a safety invariant, not a convenience.

## Config-as-Code

All runtime behavior is defined in `WORKFLOW.md` YAML frontmatter, versioned with the repo. No out-of-band config files, no environment variable sprawl beyond secrets.

## Backend Agnosticism

Symphony dispatches to any AI coding agent (Codex, Claude Code, OpenCode) through a uniform `AgentBackend` behaviour. The `command` field is the single source of truth for what runs — no provider/model abstraction layer.

## Observability First

Structured JSON logs with mandatory issue/session context fields. Terminal dashboard and LiveView for real-time status. Logs must be searchable by `issue_id`, `issue_identifier`, and `session_id`.

## Narrow Scope

Symphony is a scheduler/runner and tracker reader. Ticket writes (state transitions, comments, PR links) are the coding agent's responsibility, not Symphony's.
