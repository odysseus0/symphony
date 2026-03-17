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
4. **`LINEAR_API_KEY`** — run `test -n "$LINEAR_API_KEY" && echo "set" || echo "missing"`. Must persist across sessions (shell config, not just `export`).
5. **Linear MCP** — verify Linear MCP is available. If not, set it up:
   - Claude Code: `claude mcp add --transport http linear https://mcp.linear.app/mcp`
   - Codex: `codex mcp add linear --url https://mcp.linear.app/mcp`
   - Other clients: see [Linear MCP docs](https://linear.app/docs/mcp)
6. **Git clone auth** — the `after_create` hook runs `git clone` unattended. Verify the user's repo clone URL works non-interactively: `git clone --depth 1 <url> /tmp/test-clone && rm -rf /tmp/test-clone`. HTTPS with password prompts will silently fail. Use SSH keys (no passphrase) or HTTPS with credential helper / token.
7. **Cursor agent (optional)** — if the user wants to use Cursor as an agent backend in addition to (or instead of) Codex:
   - Run `agent --version` to check the Cursor CLI is installed (typically at `~/.local/bin/agent`). If missing, tell the user to install it from Cursor settings.
   - Run `agent login` if not already authenticated, or verify `CURSOR_API_KEY` is set.
   - Run `which cursor-symphony-bridge` — if not found, `mix symphony.install` (in the Build step) will create it automatically.

Report results to the user before proceeding.

## Build Symphony

Prefer cloning the current repo's remote when running from a Symphony fork. Resolve the source in this order:

1. `origin` remote URL of the current git repo
2. `upstream` remote URL of the current git repo
3. Fallback: [odysseus0/symphony](https://github.com/odysseus0/symphony)

```bash
SYMPHONY_REPO_URL="$(git remote get-url origin 2>/dev/null || true)"
if [ -z "$SYMPHONY_REPO_URL" ]; then
  SYMPHONY_REPO_URL="$(git remote get-url upstream 2>/dev/null || true)"
fi
if [ -z "$SYMPHONY_REPO_URL" ]; then
  SYMPHONY_REPO_URL="https://github.com/odysseus0/symphony.git"
fi

git clone "$SYMPHONY_REPO_URL"
cd symphony/elixir
mise trust && mise install
mise exec -- mix setup
mise exec -- mix build
```

`mix setup` runs `deps.get` → `escript.build` → `symphony.install`. The last step symlinks agent bridge scripts (`cursor-symphony-bridge`, `symphony-linear-cli`) into `~/.local/bin/` so they are available on PATH.

After build, verify the scripts are installed:

```bash
which cursor-symphony-bridge && echo "cursor bridge OK"
which symphony-linear-cli && echo "linear CLI OK"
```

Note: `mise install` downloads precompiled Erlang/Elixir if available for the platform. If not, it compiles from source — this can take 10-20 minutes. Let the user know before starting.

## Prepare the user's repo

Auto-detect as much as possible. Only ask the user to confirm or fill gaps.

### Auto-detect repo info

- **Repo path** — `git rev-parse --show-toplevel` from the current directory. If not in a git repo, ask.
- **Clone URL** — `git remote get-url origin`. Verify it works non-interactively: `git clone --depth 1 <url> /tmp/test-clone && rm -rf /tmp/test-clone`.
- **Setup commands** — infer from lockfiles/manifests. Confirm with the user.

### Choose skills source strategy

Ask the user to choose one strategy before patching `WORKFLOW.md`:

1. **Default (recommended): project-local skills**
   - Install/copy worker skills into the user's repo (`.agents/skills/*`) and commit them.
   - Every workspace clone gets the exact same skill version as the code branch.
2. **Custom: central skills repo**
   - Keep canonical skills in a dedicated repo, and sync them during `hooks.after_create`.
   - Use this when many repos must share one managed skill set.

If the user does not specify, default to **project-local skills**.

### Auto-discover Linear project

Use Linear MCP to list projects. Present the list and let the user pick. The `slugId` is what goes in WORKFLOW.md's `tracker.project_slug`.

### Auto-check and create workflow states

After the user picks a project, use Linear MCP to check the team's workflow states. Three custom states are required. If any are missing, create them via `curl`:

```bash
curl -s -X POST https://api.linear.app/graphql \
  -H "Content-Type: application/json" \
  -H "Authorization: $LINEAR_API_KEY" \
  -d '{"query": "mutation($input: WorkflowStateCreateInput!) { workflowStateCreate(input: $input) { success workflowState { id name } } }", "variables": {"input": {"teamId": "<team-id>", "name": "<name>", "type": "started", "color": "<color>"}}}'
```

| Name | Color |
|------|-------|
| Rework | `#db6e1f` |
| Human Review | `#da8b0d` |
| Merging | `#0f783c` |

Confirm with the user before creating.

### Auto-detect app/UI

Check whether the project has a launchable UI before asking:
- `electron` or `electron-builder` in package.json dependencies → Electron app
- `react-scripts`, `next`, `vite`, `nuxt` in dependencies → web app with dev server
- `start` or `dev` script in package.json → likely has a dev server
- `Procfile`, `docker-compose.yml` → service with runtime

If detected, propose a `launch-app` skill based on what you find (framework, start script, default port). Confirm with the user and adjust. If nothing detected, ask whether there's a UI — for pure libraries/CLIs/APIs, skip the launch skill.

### Install skills and workflow

Install `WORKFLOW.md` into the user's repo, then configure skills based on the
selected strategy:

1. **Skills (project-local strategy)** — install via skills.sh (agents need these in their workspace clone):
   ```bash
   cd <user's repo>
   npx skills add odysseus0/symphony -a codex -s linear land commit push pull debug --copy -y
   ```
   The `--copy` flag is required — symlinks would break in workspace clones. The `-s` flag excludes `symphony-setup` (meta-skill, not needed by workers).
2. **Skills (central strategy)** — keep canonical skills in the central repo and sync `.agents/skills` from `hooks.after_create`. Skip local install unless the user asks for fallback duplication.
3. **`elixir/WORKFLOW.md`** — copy the **entire file** including the markdown body. The prompt body contains the state machine, planning protocol, and validation strategy that makes agents effective.

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

If the user chose **custom central skills repo**, extend `after_create` to sync
skills right after cloning the project:

```yaml
hooks:
  after_create: |
    git clone --depth 1 <user's repo clone URL> .
    tmp_skills_dir="$(mktemp -d)"
    git clone --depth 1 --branch <ref-or-branch> <skills-repo-url> "$tmp_skills_dir"
    rm -rf .agents/skills
    mkdir -p .agents/skills
    cp -R "$tmp_skills_dir"/.agents/skills/. .agents/skills/
    rm -rf "$tmp_skills_dir"
    <user's setup commands, if any>
```

Rules:
- Keep project clone first (`git clone ... .`) so code always matches the issue branch.
- Central repo is for skills distribution only unless the user explicitly wants more.
- Ensure the central skills repo clone URL also works non-interactively.

**Leave everything else as-is.** Sandbox, approval_policy, polling interval, and concurrency settings all have good defaults in the fork.

## Cursor agent setup (optional)

If the user wants Cursor as an agent backend (in addition to or instead of Codex), add this to the WORKFLOW.md frontmatter. The template already includes the configuration — just verify it is present:

```yaml
agents:
  codex:
    command: codex --config shell_environment_policy.inherit=all --config model_reasoning_effort=xhigh --model gpt-5.3-codex app-server
    approval_policy: never
    thread_sandbox: danger-full-access
    turn_sandbox_policy:
      type: dangerFullAccess
  cursor:
    command: cursor-symphony-bridge
    approval_policy: never
    thread_sandbox: danger-full-access
routing:
  default_agent: codex
  by_label:
    use-cursor: cursor
```

With this configuration, tickets labeled `use-cursor` in Linear are dispatched to the Cursor agent. All others use Codex by default.

The WORKFLOW.md prompt already includes a "Linear access" section that tells the agent to fall back to `symphony-linear-cli` (a shell command) when the native `linear_graphql` tool is unavailable. This is essential for the Cursor agent, which does not receive Symphony's dynamic tools.

Verify the Cursor agent is ready:

1. `cursor-symphony-bridge` is on PATH (installed by `mix setup`).
2. `symphony-linear-cli` is on PATH (installed by `mix setup`).
3. `LINEAR_API_KEY` is set in the shell environment that runs Symphony.
4. `agent` CLI (Cursor) is installed and authenticated.

## App launch skill (if applicable)

If the user's project has a UI or app that needs runtime testing, create `.agents/skills/launch-app/SKILL.md` in their repo:

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

Commit strategy:

- **Project-local skills**: commit `.agents/skills/`, `WORKFLOW.md`, and `launch-app` (if created).
- **Central skills repo**: commit `WORKFLOW.md` and `launch-app` (if created) in the project repo; commit skill changes in the central skills repo.

Then push. **Push is critical** — agents clone from the remote, so unpushed changes are invisible to workers.

After pushing, verify: `git log origin/$(git branch --show-current) --oneline -1` should show your commit.

## Pre-launch: check active tickets

Before starting Symphony, use Linear MCP to list all tickets in active states (`Todo`, `In Progress`, `Rework`). **Symphony will immediately dispatch agents for every active ticket — not just new ones.**

Show the list to the user and ask if they're comfortable with all of these being worked on. Move anything they're not ready to hand off back to Backlog.

## Run

```bash
cd <symphony-path>/elixir
mise exec -- ./bin/symphony <repo-path>/WORKFLOW.md \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails
```

The guardrails flag is required — Symphony runs Codex agents with `danger-full-access` sandboxing.

Add `--port <port>` to enable the Phoenix web dashboard.

## Verify

Have the user push a test ticket to Todo in Linear. Watch for the first worker to claim it. If it fails, run this checklist:

- [ ] `LINEAR_API_KEY` available in the shell running Symphony?
- [ ] `codex` authenticated?
- [ ] `gh auth status` passing?
- [ ] Repo clone URL works non-interactively?
- [ ] Chosen skills source is pushed? (project-local `.agents/skills/` or central skills repo) and `WORKFLOW.md` pushed?
- [ ] Custom Linear states (Rework, Human Review, Merging) added?

To verify the Cursor agent specifically, add the `use-cursor` label to a test ticket. Extra checklist:

- [ ] `cursor-symphony-bridge` on PATH? (`which cursor-symphony-bridge`)
- [ ] `symphony-linear-cli` on PATH? (`which symphony-linear-cli`)
- [ ] Cursor CLI `agent` authenticated? (`agent --version`)
- [ ] Bridge logs at `~/.cache/symphony-logs/bridge-*.log` show session activity?

## Getting started after setup

Once Symphony is running, help the user with their first workflows:

### Break down a feature into tickets

The user has a big feature idea. Use Linear MCP to break it into tickets. For each ticket:
- Clear title and description with acceptance criteria
- Set blocking relationships where order matters
- Assign to the Symphony project so agents can pick them up
- Start with tickets that have no blockers in Todo

### First run

Push a few tickets to Todo and watch. Walk the user through what to expect:
- Idle agents claim tickets within seconds
- Each agent writes a plan as a Linear comment before implementing
- PRs appear on GitHub with the `symphony` label
- The Linear board updates as agents move tickets through states

### Tune on the fly

WORKFLOW.md hot-reloads within ~1 second — no restart needed. Common adjustments:
- `agent.max_concurrent_agents` — scale up/down based on API limits or repo complexity
- `agent.max_turns` — increase for complex tickets, decrease to limit token spend
- `polling.interval_ms` — how often Symphony checks for new/changed tickets
