---
name: symphony-setup
description: Set up Symphony (OpenAI's Codex orchestrator) for a user's repo. Use when the user mentions Symphony setup, configuring Symphony, getting Symphony running, or wants to connect their repo to Linear for autonomous Codex agents. Also use when the user says "set up symphony", "configure symphony for my repo", or references WORKFLOW.md configuration.
---

# Symphony Setup

Set up [Symphony](https://github.com/openai/symphony) — OpenAI's orchestrator that turns Linear tickets into pull requests via autonomous Codex agents.

## Prerequisites

Ensure these are available before proceeding:

- **Codex CLI** — installed and authenticated
- **mise** — Symphony requires Elixir 1.19 / OTP 28 (pinned in `elixir/mise.toml`). mise handles version management.
- **LINEAR_API_KEY** — personal API key from Linear (Settings → Security & access → Personal API keys). Must persist in shell config.
- **GitHub** — the workflow is GitHub-centric: agents commit, push, and create PRs via `gh`. Other hosts need workflow modifications.

## Build Symphony

Use the getting-started fork — sandbox, MCP, and internal tool references already fixed:

```bash
git clone -b getting-started https://github.com/odysseus0/symphony
cd symphony/elixir
mise trust && mise install
mise exec -- mix setup
mise exec -- mix build
```

## Prepare the user's repo

Ask the user for:
- **repo path** and **repo clone URL**
- **Linear project slug** (right-click project in Linear → copy URL → slug is in the path)
- **setup commands** after clone (if any)
- **Does the project have a UI/app that needs runtime testing?** If yes, what's the launch command?

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

Commit `.codex/`, `WORKFLOW.md`, and `launch-app` skill (if created) to the user's repo and push. Agents clone from the remote, so changes must be pushed.

## Linear custom states

The workflow requires three non-standard states the user must add manually in Linear (Team Settings → Workflow): **Rework**, **Human Review**, **Merging**. Without them, agents can't transition tickets through the full lifecycle.

## Run

```bash
cd <symphony-path>/elixir
mise exec -- ./bin/symphony <repo-path>/WORKFLOW.md
```

Add `--port <port>` to enable the Phoenix web dashboard.

Have the user push a test ticket to Todo in Linear to verify. If the first worker fails, common causes: `LINEAR_API_KEY` not available in the shell running Symphony, `codex` not authenticated, or repo clone URL requires interactive auth.
