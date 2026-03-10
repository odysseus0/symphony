---
name: symphony-setup
description: Set up Symphony (OpenAI's Codex orchestrator) for a user's repo. Use when the user mentions Symphony setup, configuring Symphony, getting Symphony running, or wants to connect their repo to Linear for autonomous Codex agents. Also use when the user says "set up symphony", "configure symphony for my repo", or references WORKFLOW.md configuration.
---

# Symphony Setup

Set up [Symphony](https://github.com/openai/symphony) — OpenAI's orchestrator that turns Linear tickets into pull requests via autonomous Codex agents.

## Preflight checks

Run these checks first and **stop if any fail** — resolve before continuing:

1. **`codex`** — run `codex --version`. Must be installed and authenticated.
2. **`mise`** — run `mise --version`. Needed for Elixir/Erlang version management.
3. **`gh`** — run `gh auth status`. Must be installed AND authenticated. Agents use `gh` to create PRs and close orphaned PRs. Silent failure without it.
4. **`LINEAR_API_KEY`** — run `echo $LINEAR_API_KEY` (or `echo $LINEAR_API_KEY` in fish). Must be set in the current shell and persist across sessions (shell config, not just `export`).
5. **Git clone auth** — the `after_create` hook runs `git clone` unattended. Verify the user's repo clone URL works non-interactively: `git clone --depth 1 <url> /tmp/test-clone && rm -rf /tmp/test-clone`. HTTPS with password prompts will silently fail. Use SSH keys (no passphrase) or HTTPS with credential helper / token.

Report results to the user before proceeding.

## Build Symphony

Use the getting-started fork — sandbox, MCP, and internal tool references already fixed:

```bash
git clone -b getting-started https://github.com/odysseus0/symphony
cd symphony/elixir
mise trust && mise install
mise exec -- mix setup
mise exec -- mix build
```

Note: `mise install` downloads precompiled Erlang/Elixir if available for the platform. If not, it compiles from source — this can take 10-20 minutes. Let the user know before starting.

## Prepare the user's repo

Auto-detect as much as possible. Only ask the user to confirm or fill gaps.

### Auto-detect repo info

- **Repo path** — `git rev-parse --show-toplevel` from the current directory. If not in a git repo, ask.
- **Clone URL** — `git remote get-url origin`. Verify it works non-interactively: `git clone --depth 1 <url> /tmp/test-clone && rm -rf /tmp/test-clone`.
- **Setup commands** — infer from the repo:
  - `package-lock.json` → `npm install`
  - `yarn.lock` → `yarn install`
  - `pnpm-lock.yaml` → `pnpm install`
  - `bun.lockb` → `bun install`
  - `Gemfile` → `bundle install`
  - `requirements.txt` → `pip install -r requirements.txt`
  - `go.mod` → `go mod download`
  - If multiple or none match, ask. Confirm with the user either way.

### Auto-discover Linear project

Query Linear via `curl` + `$LINEAR_API_KEY` to list projects (see [references/linear-graphql.md](references/linear-graphql.md)). Present the list and let the user pick.

### Auto-check and create workflow states

After the user picks a project, query the team's workflow states. If any of the 3 required states (Rework, Human Review, Merging) are missing, offer to create them via `workflowStateCreate` (see [references/linear-graphql.md](references/linear-graphql.md)). Confirm before creating.

### Auto-detect app/UI

Check whether the project has a launchable UI before asking:
- `electron` or `electron-builder` in package.json dependencies → Electron app
- `react-scripts`, `next`, `vite`, `nuxt` in dependencies → web app with dev server
- `start` or `dev` script in package.json → likely has a dev server
- `Procfile`, `docker-compose.yml` → service with runtime

If detected, propose a `launch-app` skill based on what you find (framework, start script, default port). Confirm with the user and adjust. If nothing detected, ask whether there's a UI — for pure libraries/CLIs/APIs, skip the launch skill.

Copy two things from Symphony into the user's repo:

1. **`.codex/skills/`** — agents need these in their workspace clone to commit, push, open PRs, and interact with Linear.
2. **`elixir/WORKFLOW.md`** — copy the **entire file** including the markdown body. The prompt body contains the state machine, planning protocol, and validation strategy that makes agents effective.

## Patch WORKFLOW.md frontmatter

Two changes:

### 1. Project slug

```yaml
tracker:
  project_slug: "<user's project slug>"
```

### 2. after_create hook

Replace entirely — the default clones the Symphony repo itself:

```yaml
hooks:
  after_create: |
    git clone --depth 1 <user's repo clone URL> .
    <user's setup commands, if any>
```

**Leave everything else as-is.** Sandbox, approval_policy, polling interval, and concurrency settings all have good defaults in the fork.

## App launch skill (if applicable)

If the user's project has a UI or app that needs runtime testing, create `.codex/skills/launch-app/SKILL.md` in their repo:

```markdown
---
name: launch-app
description: Launch the app for runtime validation and testing.
---

# Launch App

<launch command and any setup steps specific to the user's project>
<how to verify the app is running>
<how to connect for testing — e.g., agent-browser URL, localhost port>
```

The WORKFLOW.md prompt tells agents to "run runtime validation" for app-touching changes. Without this skill, agents won't know how to launch the app. For non-app repos (libraries, CLIs, APIs), skip this.

## Commit and push

Commit `.codex/`, `WORKFLOW.md`, and `launch-app` skill (if created) to the user's repo and push. **Push is critical** — agents clone from the remote, so unpushed changes are invisible to workers.

After pushing, verify: `git log origin/$(git branch --show-current) --oneline -1` should show your commit.

## Linear custom states

The workflow requires three non-standard states: **Rework**, **Human Review**, **Merging** (all type `started`).

During the auto-check in repo preparation, if any are missing, **create them via the API** using `workflowStateCreate` (see [references/linear-graphql.md](references/linear-graphql.md)). Confirm with the user before creating. No manual Linear UI steps needed.

## Pre-launch: check active tickets

Before starting Symphony, query the project for all tickets in active states (`Todo`, `In Progress`, `Rework`). Symphony will immediately dispatch agents for **every** active ticket — not just new ones.

List them for the user and confirm they're ready. If any tickets shouldn't be worked on yet, offer to move them to `Backlog` via `issueUpdate` before launching.

## Run

```bash
cd <symphony-path>/elixir
mise exec -- ./bin/symphony <repo-path>/WORKFLOW.md \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails
```

The guardrails flag is required — Symphony runs Codex agents with `danger-full-access` sandboxing.

Add `--port <port>` to enable the Phoenix web dashboard.

`LINEAR_API_KEY` must be available in the shell environment when starting Symphony. If it's managed by sops-nix or similar, ensure it's sourced before running.

## Verify

Have the user push a test ticket to Todo in Linear. Watch for the first worker to claim it. If it fails, run this checklist:

- [ ] `LINEAR_API_KEY` available in the shell running Symphony?
- [ ] `codex` authenticated?
- [ ] `gh auth status` passing?
- [ ] Repo clone URL works non-interactively?
- [ ] `.codex/skills/` and `WORKFLOW.md` pushed to remote?
- [ ] Custom Linear states (Rework, Human Review, Merging) added?

## Getting started after setup

Once Symphony is running, help the user with their first workflows:

### Break down a feature into tickets

The user has a big feature idea. Help them break it into Linear tickets using `curl` + `$LINEAR_API_KEY` (see [references/linear-graphql.md](references/linear-graphql.md) for GraphQL patterns). For each ticket:
- Clear title and description with acceptance criteria
- Set dependencies between tickets using `issueRelationCreate` (type: `blocks`)
- Assign to the Symphony project so agents can pick them up
- Start with tickets that have no blockers in Todo

### First run

Push a few tickets to Todo and watch. Walk the user through what to expect:
- Agents claim tickets within seconds (polling interval)
- Each agent writes a plan as a Linear comment before implementing
- PRs appear on GitHub with the `symphony` label
- The Linear board updates as agents move tickets through states

### Tune on the fly

WORKFLOW.md hot-reloads within ~1 second — no restart needed. Common adjustments:
- `agent.max_concurrent_agents` — scale up/down based on API limits or repo complexity
- `agent.max_turns` — increase for complex tickets, decrease to limit token spend
- `polling.interval_ms` — how often Symphony checks for new/changed tickets
