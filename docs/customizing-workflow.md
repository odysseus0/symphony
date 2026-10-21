# Customizing WORKFLOW.md

A guide for writing your own `WORKFLOW.md` to control how Symphony agents handle
issue tickets.

## What WORKFLOW.md is

`WORKFLOW.md` is a single file that serves two purposes:

1. **YAML front matter** — runtime configuration consumed by the Symphony
   orchestrator (polling, workspace, hooks, agent commands, routing).
2. **Markdown body** — the prompt template injected into the agent at session
   start for every issue.

The orchestrator parses the front matter into typed config. The body is rendered
through a Liquid-compatible template engine with issue variables
(`{{ issue.identifier }}`, `{{ issue.title }}`, etc.) and sent as the agent's
initial instructions.

```
┌─────────────────────────────────────────┐
│  ---                                    │
│  tracker:                               │  ← YAML front matter
│    kind: linear                         │    (orchestrator config)
│    project_slug: "..."                  │
│  workspace:                             │
│    root: ~/workspaces                   │
│  ...                                    │
│  ---                                    │
│                                         │
│  You are working on {{ issue.title }}   │  ← Markdown body
│                                         │    (agent prompt template)
│  ## Status map                          │
│  ...                                    │
│  ## Guardrails                          │
│  ...                                    │
└─────────────────────────────────────────┘
```

Key runtime properties:

- Loaded once at startup; hot-reloaded on file change without restart.
- If the file is missing or has invalid YAML, the orchestrator refuses to boot.
- If a reload fails, the last known good workflow is kept.

## The layering principle

The most important design decision is **what goes inline vs. what gets delegated
to skills**.

Use this rule:

> **"What / when / whether" stays inline. "How" goes to a skill.**

In other words, the WORKFLOW.md body is the agent's **brain** (decision logic),
while skills are the agent's **hands** (operational procedures).

### Why this split matters

The Markdown body is **injected** — the agent sees it before doing anything.
Skills are **pulled** — the agent must choose to read them via a tool call. If
decision-critical information lives in a skill file, the agent may act before
reading it, leading to wrong state transitions, skipped quality gates, or scope
drift.

Conversely, inlining every operational procedure bloats the initial prompt,
wastes tokens on details the agent doesn't need until a specific step, and makes
maintenance painful.

### What belongs inline

Content that affects routing, judgment, or constraints:

- **State machine / status map** — which states exist, transitions between them,
  and what each state means.
- **Default posture** — global behavioral rules (plan first, reproduce first,
  operate autonomously, etc.).
- **Quality gates** — completion bar, acceptance criteria requirements, what must
  be true before a state transition.
- **Guardrails** — hard constraints the agent must never violate (scope control,
  workspace safety, terminal state handling).
- **Issue context block** — template variables that inject the current ticket's
  data into the prompt.
- **Continuation / retry context** — how the agent should behave on retry
  attempts.
- **Skill directory** — a list of available skills with trigger conditions
  (not just names, but *when* to use each one).
- **Progress tracking format** — workpad template or equivalent structure that
  the agent uses throughout execution.

### What belongs in skills

Repeatable procedures that answer "how do I perform operation X":

- `commit` — how to stage, format, and create a git commit.
- `push` — how to push to remote and handle auth/errors.
- `pull` — how to sync with upstream and resolve conflicts.
- `land` — how to monitor checks, handle review feedback, and merge a PR.
- `linear` — how to interact with the Linear API (queries, mutations, uploads).
- Any project-specific build/test/deploy procedures.

### Reference format for skills

When listing skills in the prompt, always include the **trigger condition**, not
just the skill name:

```markdown
## Related skills

- `commit`: produce clean commits during implementation.
- `push`: keep remote branch current and publish updates.
- `pull`: sync with `origin/main` before code edits and before handoff.
- `land`: when ticket reaches `Merging`, run the merge loop.
- `linear`: interact with Linear for state updates, comments, and uploads.
```

Bad (no trigger context):

```markdown
## Related skills

- `commit`
- `push`
- `pull`
- `land`
```

Without trigger context, the agent has to guess when to invoke each skill.

## YAML front matter reference

The front matter configures the orchestrator. Refer to `SPEC.md` Section 5.3
for the full schema. Here is the minimal set you need:

```yaml
---
tracker:
  kind: linear
  project_slug: "your-project-slug"
  active_states:
    - Todo
    - In Progress
  terminal_states:
    - Done
    - Closed
    - Cancelled
workspace:
  root: ~/code/workspaces
hooks:
  after_create: |
    git clone --depth 1 git@github.com:your-org/your-repo.git .
agent:
  max_concurrent_agents: 5
  max_turns: 20
codex:
  command: codex app-server
---
```

### Multi-agent routing

Define multiple agents and route issues by Linear label:

```yaml
agents:
  codex:
    command: codex --model gpt-5.3-codex app-server
  cursor:
    command: cursor-symphony-bridge --model opus-4.6
routing:
  default_agent: codex
  by_label:
    use-cursor: cursor
```

### Hooks

- `after_create` — runs once when a workspace directory is first created.
  Typically clones the repo and installs dependencies.
- `before_run` — runs before each agent attempt. Use for env checks or
  pre-flight setup.
- `after_run` — runs after each agent attempt. Use for cleanup or reporting.
- `before_remove` — runs before workspace deletion. Use for closing orphaned
  PRs.

## Prompt body structure

Below is a recommended structure for the Markdown body. Adapt sections to your
workflow; remove what doesn't apply.

```markdown
You are working on a Linear ticket `{{ issue.identifier }}`

{% if attempt %}
This is retry attempt #{{ attempt }}. Resume from current state.
{% endif %}

Issue context:
Identifier: {{ issue.identifier }}
Title: {{ issue.title }}
Status: {{ issue.state }}
Labels: {{ issue.labels }}
URL: {{ issue.url }}

Description:
{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}

## Operating rules
<!-- Global behavioral constraints. 3-5 bullets. -->

## Related skills
<!-- Skill name + trigger condition. -->

## Status map
<!-- Every state + what the agent should do in each. -->

## Execution flow
<!-- Step-by-step lifecycle from Todo to Done. -->

## Quality gates
<!-- What must be true before state transitions. -->

## Guardrails
<!-- Hard constraints that must never be violated. -->

## Progress template
<!-- Workpad / scratchpad structure for tracking progress. -->
```

## Template variables

The prompt body is rendered with [Liquid](https://shopify.github.io/liquid/)
syntax. Available variables:

| Variable | Type | Description |
|---|---|---|
| `issue.identifier` | string | Human-readable ticket key (e.g. `ABC-123`) |
| `issue.id` | string | Internal tracker ID |
| `issue.title` | string | Issue title |
| `issue.description` | string or nil | Issue body |
| `issue.state` | string | Current state name |
| `issue.labels` | list of strings | Normalized to lowercase |
| `issue.url` | string or nil | Tracker URL |
| `issue.priority` | integer or nil | Lower = higher priority |
| `issue.branch_name` | string or nil | Tracker-provided branch |
| `issue.blocked_by` | list of objects | Blocker references |
| `attempt` | integer or nil | nil on first run, >=1 on retry |

Use `{% if variable %}` guards for optional fields to avoid template errors
(strict mode rejects undefined variables).

## Design decisions and tradeoffs

### Prompt length vs. completeness

| Approach | Tokens per session | Risk |
|---|---|---|
| Everything inline (~800+ lines) | High | Attention dilution; agent ignores late sections |
| Lean prompt + heavy skills (~100 lines) | Low initial, variable runtime | Agent may skip reading a skill; loses global context |
| **Hybrid (~200-400 lines)** | **Moderate** | **Best balance of context and cost** |

The hybrid approach keeps the state machine, guardrails, and quality gates
inline (the agent always sees them) while delegating operational procedures to
skills (the agent reads them only when needed).

### When to go leaner

If your workflow is simple (fewer than 4 states, no rework loop, no PR feedback
sweep), you can keep the prompt under 150 lines and skip skills entirely. Put
everything inline.

### When to add more skills

If you find a section of WORKFLOW.md that:
- is only relevant during one specific step,
- is longer than ~30 lines, and
- could be reused across different workflows,

extract it into a skill and reference it from the prompt with a trigger
condition.

## Checklist for a new WORKFLOW.md

- [ ] YAML front matter has `tracker.kind`, `tracker.project_slug`,
      `workspace.root`, and `hooks.after_create` at minimum.
- [ ] Active and terminal states match your Linear team's workflow states.
- [ ] Prompt body starts with issue context block using template variables.
- [ ] `{% if attempt %}` block handles retry/continuation behavior.
- [ ] Status map covers every state the agent might encounter.
- [ ] Related skills section lists each skill with its trigger condition.
- [ ] At least one quality gate defines what must be true before moving to
      review/done.
- [ ] Guardrails section lists hard constraints (scope control, workspace
      safety, terminal state handling).
- [ ] Progress template defines the structure for the agent's tracking comment.
- [ ] Tested with `mise exec -- ./bin/symphony ./WORKFLOW.md` to confirm the
      orchestrator boots without errors.

## Common mistakes

**Putting the state machine in a skill.** The agent may start executing before
reading the skill, leading to wrong state transitions. Keep routing logic
inline.

**Listing skills without trigger conditions.** The agent needs to know *when*
to use a skill, not just that it exists. Always pair the skill name with its
trigger.

**Duplicating logic between WORKFLOW.md and skills.** If both the workflow and a
skill describe how to handle PR feedback, they will drift. Pick one owner for
each piece of logic.

**Overloading the prompt with tool-specific commands.** Detailed CLI usage
(`gh api repos/...`, `git rebase --onto ...`) belongs in skills. The workflow
should describe intent ("merge latest main into branch"), not implementation
("run `git fetch origin && git merge origin/main`").

**Forgetting `{% if %}` guards for optional template variables.** The template
engine runs in strict mode. If `issue.description` is nil and you render
`{{ issue.description }}` without a guard, the template fails.

**Making the prompt too long.** Beyond ~400 lines of Markdown body, the agent's
attention to later sections degrades. If you exceed this, look for sections to
extract into skills.
