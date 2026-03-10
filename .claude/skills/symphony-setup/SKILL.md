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

Ask the user for:
- **repo path** and **repo clone URL**
- **setup commands** after clone (if any)
- **Does the project have a UI/app that needs runtime testing?** If yes, what's the launch command?

**Auto-discover Linear project** — don't ask the user for the slug. Query Linear directly using `curl` + `$LINEAR_API_KEY` to list projects, present the choices, and let the user pick. See [references/linear-graphql.md](references/linear-graphql.md) for the GraphQL patterns.

**Auto-check workflow states** — after the user picks a project, query the team's workflow states to check if the 3 custom states (Rework, Human Review, Merging) already exist. Report which are missing so the user knows exactly what to add. See [references/linear-graphql.md](references/linear-graphql.md) for the query.

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

## Run

```bash
cd <symphony-path>/elixir
mise exec -- ./bin/symphony <repo-path>/WORKFLOW.md
```

Add `--port <port>` to enable the Phoenix web dashboard.

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
