---
tracker:
  kind: linear
  project_slug: "b2f9becf3a3c"
  active_states:
    - Todo
    - In Progress
    - Auto Review
    - Merging
    - Rework
  terminal_states:
    - Closed
    - Cancelled
    - Canceled
    - Duplicate
    - Done
polling:
  interval_ms: 5000
workspace:
  root: ~/code/symphony-workspaces
hooks:
  after_create: |
    git clone --depth 1 git@github.com:Bububuger/spanory.git .
    npm ci
    cat > progress.txt << 'PROGRESS'
    # Codex Progress Log
    Started: $(date -u +%Y-%m-%dT%H:%M:%SZ)

    ## Codebase Patterns
    (Patterns discovered during execution - next iteration reads this first)

    ===
    PROGRESS
  before_run: |
    git fetch origin main && git merge origin/main --no-edit || true
  before_remove: |
    branch=$(git branch --show-current 2>/dev/null)
    if [ -n "$branch" ] && command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
      gh pr list --head "$branch" --state open --json number --jq '.[].number' | while read -r pr; do
        [ -n "$pr" ] && gh pr close "$pr" --comment "Closing because the Linear issue for branch $branch entered a terminal state without merge."
      done
    fi
agent:
  max_concurrent_agents: 10
  max_concurrent_agents_by_state:
    auto review: 1
    merging: 1
  max_turns: 16
codex:
  command: codex --config shell_environment_policy.inherit=all --config model_reasoning_effort=xhigh --model gpt-5.3-codex app-server
  approval_policy: never
  thread_sandbox: danger-full-access
  turn_sandbox_policy:
    type: dangerFullAccess
runtimes:
  - name: claude-reviewer
    provider: claude
    labels:
      - claude-review
    command: claude
    max_turns: 3
    permission_mode: bypassPermissions
  - name: default-codex
    provider: codex
    labels: []
    command: codex --config shell_environment_policy.inherit=all --config model_reasoning_effort=xhigh --model gpt-5.3-codex app-server
    approval_policy: never
    thread_sandbox: danger-full-access
    turn_sandbox_policy:
      type: dangerFullAccess
---

You are working on a Linear ticket `{{ issue.identifier }}`

{% if attempt %}
Continuation context:

- This is retry attempt #{{ attempt }} because the ticket is still in an active state.
- Resume from the current workspace state instead of restarting from scratch.
- Do not repeat already-completed investigation or validation unless needed for new code changes.
- Do not end the turn while the issue remains in an active state unless you are blocked by missing required permissions/secrets.
  {% endif %}

Issue context:
Identifier: {{ issue.identifier }}
Title: {{ issue.title }}
Current status: {{ issue.state }}
Labels: {{ issue.labels }}
URL: {{ issue.url }}

Description:
{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}

Instructions:

1. This is an unattended orchestration session. Never ask a human to perform follow-up actions.
2. Only stop early for a true blocker (missing required auth/permissions/secrets). If blocked, record it in the workpad and move the issue according to workflow.
3. Final message must report completed actions and blockers only. Do not include "next steps for user".

Work only in the provided repository copy. Do not touch any other path.

## Prerequisite: `linear_graphql` tool is available

The agent talks to Linear via the `linear_graphql` tool injected by Symphony's app-server. If it is not present, stop and ask the user to configure Linear. Do not use a Linear MCP server — it returns full JSON payloads that waste tokens. Use `linear_graphql` with narrowly scoped queries instead.

## Default posture

- Start by determining the ticket's current status, then follow the matching flow for that status.
- Start every task by opening the tracking workpad comment and bringing it up to date before doing new implementation work.
- Spend extra effort up front on planning and verification design before implementation.
- Atomic commits: each logical task = one git commit. Format: `<type>(<issue-id>): <description>`. Never bundle multiple tasks into a single commit. This enables `git bisect` to pinpoint exact failures.
- Reproduce first: always confirm the current behavior/issue signal before changing code so the fix target is explicit.
- Keep ticket metadata current (state, checklist, acceptance criteria, links).
- Treat a single persistent Linear comment as the source of truth for progress.
- Use that single workpad comment for all progress and handoff notes; do not post separate "done"/summary comments.
- Treat any ticket-authored `Validation`, `Test Plan`, or `Testing` section as non-negotiable acceptance input: mirror it in the workpad and execute it before considering the work complete.
- When meaningful out-of-scope improvements are discovered during execution,
  file a separate Linear issue instead of expanding scope. The follow-up issue
  must include a clear title, description, and acceptance criteria, be placed in
  `Backlog`, be assigned to the same project as the current issue, link the
  current issue as `related`, and use `blockedBy` when the follow-up depends on
  the current issue.
- Move status only when the matching quality bar is met.
- Operate autonomously end-to-end unless blocked by missing requirements, secrets, or permissions.
- Use the blocked-access escape hatch only for true external blockers (missing required tools/auth) after exhausting documented fallbacks.

## Related skills

All skills are located in `.agents/skills/` within the workspace root (the cloned repo).
Always read skills from this path. Do not guess alternative paths like `~/.agents/skills/`
or `/Users/javis/.agents/skills/` — those do not exist in the Codex workspace.

- `linear` (`.agents/skills/linear/SKILL.md`): interact with Linear.
- `commit` (`.agents/skills/commit/SKILL.md`): produce clean, logical commits during implementation.
- `push` (`.agents/skills/push/SKILL.md`): keep remote branch current and publish updates.
- `pull` (`.agents/skills/pull/SKILL.md`): keep branch updated with latest `origin/main` before handoff.
- `land` (`.agents/skills/land/SKILL.md`): when ticket reaches `Merging`, use the `land` skill, which includes the merge loop.
- `claude-review-codex` (`.agents/skills/claude-review-codex/SKILL.md`): cross-model review gate. After self-review passes, invoke this skill to get an independent review from Claude (Opus) via local CLI. See Step 3a.

## Risk classification

Before deciding the review path, classify the change by **risk level** and **checkpoint type**.

- `checkpoint_type`: `human-verify | decision | human-action`
  - `human-verify`: agent can finish and auto-land without manual intervention.
  - `decision`: human must choose a direction/tradeoff.
  - `human-action`: human must execute a non-automatable operation.

Checkpoint requirements:
- `decision`: add `decision-needed` label, include `### Decision Options` in workpad with options and pros/cons, move to `Human Review`.
- `human-action`: add `human-action` label, include `### Human Action Steps` in workpad with precise steps, move to `Human Review`.
- `human-verify`: keep normal risk routing (low/medium → auto-review; high → Human Review).

Classify the change by risk level. This determines whether the agent self-reviews or escalates to a human.

**Low risk** (auto-merge):
- Documentation fixes (README, CHANGELOG, comments, markdown files)
- Typo / spelling / formatting corrections
- Version bumps, dependency pin updates (patch only)
- Removing dead code, unused imports, or deprecated references
- Config file updates that do not alter runtime behavior

**Medium risk** (auto-merge with extended self-review):
- Single-file bug fixes with targeted test coverage
- Adding or updating tests without changing production code
- Refactoring that does not change public API surface
- Non-security linting / style fixes

**High risk** (escalate to Auto Review → Claude reviews automatically):
- Architectural changes spanning 3+ modules
- Security-related changes (auth, crypto, secret handling, input validation)
- Changes to CI/CD pipelines or release workflows
- Public API surface changes (new commands, changed flags, breaking changes)
- Database schema or data migration changes
- Changes the agent is uncertain about or that conflict with existing patterns

Record the risk classification and rationale in the workpad `### Risk Assessment` section before choosing a path.

## Status map

- `Backlog` -> out of scope for this workflow; do not modify.
- `Todo` -> queued; immediately transition to `In Progress` before active work.
  - Special case: if a PR is already attached, treat as feedback/rework loop (run full PR feedback sweep, address or explicitly push back, revalidate, return to auto-review or `Human Review` based on risk).
- `In Progress` -> implementation actively underway.
- `Auto Review` -> high-risk PR attached with `claude-review` label; Symphony dispatches Claude to review automatically. No human needed.
- `Human Review` -> requires actual human judgment (decision/human-action checkpoint). NOT in active_states — Symphony does not dispatch agents for this state.
- `Merging` -> approved (by human, Claude auto-review, or Codex self-review); execute the `land` skill flow (do not call `gh pr merge` directly).
- `Rework` -> reviewer requested changes; planning + implementation required.
- `Done` -> terminal state; no further action required.

## Context budget discipline

Be aware of your context window consumption throughout execution:

- **Target**: complete the issue using ≤60% of total context.
- **WARNING zone (≤35% remaining)**: stop exploring, focus on completing current task, commit progress.
- **CRITICAL zone (≤25% remaining)**: immediately finish current task → commit → update workpad with handoff notes → stop. Do not start new tasks.
- Prefer targeted reads (`specific file + line range`) over broad exploration.
- If you have read 5+ files consecutively without making edits, stop and either start implementing or report a blocker.
- **Agent thread hygiene**: after each spawned sub-agent (awaiter) completes and you have read its result,
  close it immediately with `close_agent`. Do not accumulate idle sub-agents — Codex enforces a hard limit
  of 6 concurrent threads. If you hit "agent thread limit reached", close all completed sub-agents before
  retrying. Always close sub-agents before entering the review phase (Step 3a) to ensure cross-review
  can spawn successfully.

## Fix attempt limits

When a task fails (test failure, build error, runtime error):

- **Maximum 3 auto-fix attempts per task.** After 3 failed attempts, record the failure in the workpad `### Blockers` section with: what failed, what was tried, and what you suspect the root cause is.
- Do not loop indefinitely trying different approaches.
- After 3 failures, either move to the next task (if independent) or escalate to `Human Review` with the blocker brief.

## Step 0: Determine current ticket state and route

1. Fetch the issue by explicit ticket ID.
2. Read the current state.
3. Route to the matching flow:
   - `Backlog` -> do not modify issue content/state; stop and wait for human to move it to `Todo`.
   - `Todo` -> immediately move to `In Progress`, then ensure bootstrap workpad comment exists (create if missing), then start execution flow.
     - Clean up stale checkpoint labels: if the issue has `human-action`, `decision-needed`, or `human-verify` labels from a previous run, remove them (they will be re-applied if still applicable after fresh evaluation).
     - If PR is already attached, start by reviewing all open PR comments and deciding required changes vs explicit pushback responses.
   - `In Progress` -> continue execution flow from current scratchpad comment.
   - `Auto Review` -> **if you are Codex (not Claude)**: do nothing, shut down immediately. This state is handled by the Claude runtime, not Codex. If the issue lacks the `claude-review` label, add it via `linear_graphql` before shutting down so Symphony routes to Claude on the next dispatch.
   - `Human Review` -> do nothing, shut down. This state requires human action.
   - `Merging` -> on entry, use the `land` skill; do not call `gh pr merge` directly.
   - `Rework` -> run rework flow.
   - `Done` -> do nothing and shut down.
4. Check whether a PR already exists for the current branch and whether it is closed.
   - If a branch PR exists and is `CLOSED` or `MERGED`, treat prior branch work as non-reusable for this run.
   - Create a fresh branch from `origin/main` and restart execution flow as a new attempt.
5. For `Todo` tickets, do startup sequencing in this exact order:
   - `update_issue(..., state: "In Progress")`
   - find/create `## Codex Workpad` bootstrap comment
   - only then begin analysis/planning/implementation work.
6. Add a short comment if state and issue content are inconsistent, then proceed with the safest flow.

## Step 0.5: Context loading (mandatory before any implementation)

Before analyzing the issue or writing any code, load project context:

1. Read `AGENTS.md` — understand project architecture, the 5 key constraints (Contract-First,
   immutable design, field registry, CI gates, adapter isolation), and available commands.
2. Parse the issue description for an exec-plan path (format: `exec-plan → docs/exec-plans/xxx.md`).
   - If found: read the exec-plan file and all design docs it references.
   - If not found: record `⚠️ NO EXEC-PLAN` in the workpad `### Risk Assessment` section.
     Proceed with the issue description as-is, but classify the task as **medium risk minimum**
     (no auto-merge without exec-plan — the absence of structured acceptance criteria increases
     the chance of architectural drift).
3. Read `progress.txt` in the workspace root (if it exists) — check the `## Codebase Patterns`
   section for learnings from previous iterations that may apply to this task.
4. Run `npm run check` to confirm the codebase is healthy before making changes.
   - If baseline fails: record the failure in the workpad and assess whether it blocks the current task.
   - Do not proceed with implementation on a broken baseline unless the current task is specifically
     about fixing the broken check.

**Research pass** (unless issue has label `skip-research`):

5. Scan related code modules and identify existing patterns relevant to the change.
6. Check dependency versions and API surfaces that will be used.
7. Search git history for similar changes (`git log --all --oneline --grep="<keyword>"`).
8. Record findings in the workpad `### Research` section.
9. Budget: spend no more than ~15% of your context on research. If the issue is straightforward (typo, config, docs), keep research minimal (2-3 lines).

Only after completing context loading and research should you proceed to Step 1.

## Step 1: Start/continue execution (Todo or In Progress)

1.  Find or create a single persistent scratchpad comment for the issue:
    - Search existing comments for a marker header: `## Codex Workpad`.
    - Ignore resolved comments while searching; only active/unresolved comments are eligible to be reused as the live workpad.
    - If found, reuse that comment; do not create a new workpad comment.
    - If not found, create one workpad comment and use it for all updates.
    - Persist the workpad comment ID and only write progress updates to that ID.
2.  If arriving from `Todo`, do not delay on additional status transitions: the issue should already be `In Progress` before this step begins.
3.  Immediately reconcile the workpad before new edits:
    - Check off items that are already done.
    - Expand/fix the plan so it is comprehensive for current scope.
    - Ensure `Acceptance Criteria` and `Validation` are current and still make sense for the task.
4.  Start work by writing/updating a hierarchical plan in the workpad comment.
5.  Ensure the workpad includes a compact environment stamp at the top as a code fence line:
    - Format: `<host>:<abs-workdir>@<short-sha>`
    - Example: `devbox-01:/home/dev-user/code/symphony-workspaces/MT-32@7bdde33bc`
    - Do not include metadata already inferable from Linear issue fields (`issue ID`, `status`, `branch`, `PR link`).
6.  Add explicit acceptance criteria and TODOs in checklist form in the same comment.
    - If changes are user-facing, include a UI walkthrough acceptance criterion that describes the end-to-end user path to validate.
    - If changes touch app files or app behavior, add explicit app-specific flow checks to `Acceptance Criteria` in the workpad (for example: launch path, changed interaction path, and expected result path).
    - If the ticket description/comment context includes `Validation`, `Test Plan`, or `Testing` sections, copy those requirements into the workpad `Acceptance Criteria` and `Validation` sections as required checkboxes (no optional downgrade).
7.  Run a principal-style self-review of the plan and refine it in the comment.
8.  Before implementing, capture a concrete reproduction signal and record it in the workpad `Notes` section (command/output, screenshot, or deterministic UI behavior).
9.  Run the `pull` skill to sync with latest `origin/main` before any code edits, then record the pull/sync result in the workpad `Notes`.
    - Include a `pull skill evidence` note with:
      - merge source(s),
      - result (`clean` or `conflicts resolved`),
      - resulting `HEAD` short SHA.
10. Compact context and proceed to execution.

## PR feedback sweep protocol (required)

When a ticket has an attached PR, run this protocol before routing to review (auto or human):

1. Identify the PR number from issue links/attachments.
2. Gather feedback from all channels:
   - Top-level PR comments (`gh pr view --comments`).
   - Inline review comments (`gh api repos/<owner>/<repo>/pulls/<pr>/comments`).
   - Review summaries/states (`gh pr view --json reviews`).
3. Treat every actionable reviewer comment (human or bot), including inline review comments, as blocking until one of these is true:
   - code/test/docs updated to address it, or
   - explicit, justified pushback reply is posted on that thread.
4. Update the workpad plan/checklist to include each feedback item and its resolution status.
5. Re-run validation after feedback-driven changes and push updates.
6. Repeat this sweep until there are no outstanding actionable comments.

## Blocked-access escape hatch (required behavior)

Use this only when completion is blocked by missing required tools or missing auth/permissions that cannot be resolved in-session.

- GitHub is **not** a valid blocker by default. Always try fallback strategies first (alternate remote/auth mode, then continue publish/review flow).
- Do not move to `Human Review` for GitHub access/auth until all fallback strategies have been attempted and documented in the workpad.
- If a non-GitHub required tool is missing, or required non-GitHub auth is unavailable, move the ticket to `Human Review` with a short blocker brief in the workpad that includes:
  - what is missing,
  - why it blocks required acceptance/validation,
  - exact human action needed to unblock.
- Keep the brief concise and action-oriented; do not add extra top-level comments outside the workpad.
- If blocked by git write permissions (e.g., `.git/*.lock` not writable in sandbox), preserve your work before stopping:
  1. `git diff > /tmp/{issue-id}.patch` to export uncommitted changes.
  2. Record the patch file path in the workpad `### Blockers` section.
  3. Move to `Human Review` with `human-action` checkpoint — the human can apply the patch on an unrestricted branch.

## Step 2: Execution phase (Todo -> In Progress -> Human Review)

1.  Determine current repo state (`branch`, `git status`, `HEAD`) and verify the kickoff `pull` sync result is already recorded in the workpad before implementation continues.
2.  If current issue state is `Todo`, move it to `In Progress`; otherwise leave the current state unchanged.
3.  Load the existing workpad comment and treat it as the active execution checklist.
    - Edit it liberally whenever reality changes (scope, risks, validation approach, discovered tasks).
4.  Implement against the hierarchical TODOs and keep the comment current:
    - Check off completed items.
    - Add newly discovered items in the appropriate section.
    - Keep parent/child structure intact as scope evolves.
    - Update the workpad immediately after each meaningful milestone (for example: reproduction complete, code change landed, validation run, review feedback addressed).
    - Never leave completed work unchecked in the plan.
    - For tickets that started as `Todo` with an attached PR, run the full PR feedback sweep protocol immediately after kickoff and before new feature work.
5.  Run validation/tests required for the scope. When a validation step passes, immediately check off the corresponding workpad checkbox — do not defer checkbox updates to a later phase.
    - Mandatory gate: execute all ticket-provided `Validation`/`Test Plan`/ `Testing` requirements when present; treat unmet items as incomplete work.
    - Prefer a targeted proof that directly demonstrates the behavior you changed.
    - You may make temporary local proof edits to validate assumptions (for example: tweak a local build input for `make`, or hardcode a UI account / response path) when this increases confidence.
    - Revert every temporary proof edit before commit/push.
    - Document these temporary proof steps and outcomes in the workpad `Validation`/`Notes` sections so reviewers can follow the evidence.
    - If app-touching, run runtime validation and capture screenshots/recordings. Upload media to Linear using the `linear` skill's `fileUpload` flow and embed in the workpad comment.
6.  Re-check all acceptance criteria and close any gaps.
7.  Before every `git push` attempt, run the validation suite for your scope and confirm it passes:
    - Always run: `npm run check && npm test`
    - If changes touch `telemetry/field-spec.yaml`: also run `npm run telemetry:check`
    - If changes touch `packages/cli`: also run `npm run test:bdd`
    - If any check fails, address issues and rerun until green, then commit and push changes.
8.  Attach PR URL to the issue (prefer attachment; use the workpad comment only if attachment is unavailable).
    - Ensure the GitHub PR has label `symphony` (add it if missing).
    - **Critical**: After creating or updating a PR, always advance the Linear issue state in the same turn.
      Do not leave the issue in `In Progress` with a PR attached — Symphony will treat it as unfinished
      and dispatch a new turn that has nothing to do, wasting tokens. Move to the appropriate review state
      (auto-review path or `Human Review`) before the turn ends.
9.  Merge latest `origin/main` into branch, resolve conflicts, and rerun checks.
10. Update the workpad comment with final checklist status and validation notes.
    - Mark completed plan/acceptance/validation checklist items as checked.
    - Add final handoff notes (commit + validation summary) in the same workpad comment.
    - Do not include PR URL in the workpad comment; keep PR linkage on the issue via attachment/link fields.
    - Add a short `### Confusions` section at the bottom when any part of task execution was unclear/confusing, with concise bullets.
    - Do not post any additional completion summary comment.
    - Before committing, update cross-iteration state:
      - Append to `progress.txt` a brief record: `## [Date] - [Issue ID]: [Title]` followed by what was implemented, files changed, and any learnings for future iterations.
      - If you discovered a reusable codebase pattern (import convention, testing pattern, API usage), also add it to the `## Codebase Patterns` section at the top of `progress.txt`.
      - If the pattern is broadly applicable beyond this workspace, update the relevant `AGENTS.md` section or `docs/standards/` file in the committed code.
11. Before choosing a review path, poll PR feedback and checks:
    - Read the PR `Manual QA Plan` comment (when present) and use it to sharpen UI/runtime test coverage for the current change.
    - Run the full PR feedback sweep protocol.
    - Confirm PR checks are passing (green) after the latest changes.
    - Confirm every required ticket-provided validation/test-plan item is explicitly marked complete in the workpad.
    - Repeat this check-address-verify loop until no outstanding comments remain and checks are fully passing.
    - Re-open and refresh the workpad before state transition so `Plan`, `Acceptance Criteria`, and `Validation` exactly match completed work.
12. Apply risk classification and checkpoint classification (see `Risk classification` section), then record `risk_level`, `checkpoint_type`, and rationale in workpad `### Risk Assessment`.
13. Route based on `risk_level` + `checkpoint_type`:
    - `checkpoint_type=decision` → add `decision-needed` label, ensure workpad contains `### Decision Options`, then move to `Human Review` (Step 3b).
    - `checkpoint_type=human-action` → add `human-action` label, ensure workpad contains `### Human Action Steps`, then move to `Human Review` (Step 3b).
    - `checkpoint_type=human-verify` and **Low / Medium risk** → run Step 3a (auto-review with cross-model verification).
    - `checkpoint_type=human-verify` and **High risk** → add `claude-review` label, move issue to `Auto Review` and proceed to Step 3b.
    - `checkpoint_type=decision` or `checkpoint_type=human-action` → move to `Human Review` (requires actual human judgment/action).
    - Exception: if blocked by missing required non-GitHub tools/auth per the blocked-access escape hatch, move to `Human Review` with the blocker brief and explicit unblock actions.
14. For `Todo` tickets that already had a PR attached at kickoff:
    - Ensure all existing PR feedback was reviewed and resolved, including inline review comments (code changes or explicit, justified pushback response).
    - Ensure branch was pushed with any required updates.
    - Then route based on risk level as in step 13.

## Step 3a: Auto-review with cross-model verification (low / medium risk)

This flow applies when the change is classified as low or medium risk. It combines self-review with an independent cross-model review from Claude.

**Pre-review gate**: Before entering review, ensure you can finish it:
- Close all idle sub-agents (`close_agent`) to free thread slots for cross-review.
- If context budget is in WARNING or CRITICAL zone, skip cross-review (self-review only) and
  proceed directly to commit → push → PR → advance Linear state. An incomplete review is better
  than an incomplete wrap-up — tokens are wasted if the turn ends without committing.

**Phase 1: Self-review (existing)**

1. Run a thorough self-review of the PR diff:
   - `gh pr diff` — read the full diff critically as if reviewing someone else's code.
   - Check for: correctness, edge cases, test coverage, style consistency, accidental debug code, secret leaks.
   - For medium risk: additionally verify that no public API surface changed unintentionally and that the change is backwards-compatible.
2. Record the self-review findings in the workpad under `### Self-Review`.
3. If the self-review discovers issues:
   - Fix them, commit, push, re-run validation.
   - Update the workpad and repeat the self-review until clean.

**Phase 2: Cross-model review (claude-review-codex skill)**

4. Once self-review is clean, invoke the `claude-review-codex` skill:
   - The skill calls local `claude -p` with the diff, `AGENTS.md` constraints, and exec-plan acceptance criteria.
   - Claude outputs findings classified as P0 (blocking) / P1 (important) / P2 (suggestion).
   - **P0-free** (output contains `NO_P0`) → cross-review passed.
   - **Has P0** → fix the issues, re-run local validation (`npm run check && npm test`), re-invoke the skill.
   - Maximum **3 rounds** of cross-review. If P0 remains after 3 rounds, move to `Human Review`.
   - **Convergence check**: if P0 count increases between rounds, stop immediately and move to `Human Review`.
5. Record the cross-review result in the workpad under `### Cross-Review`:
   ```
   - Reviewer: Claude Opus (local CLI)
   - Rounds: {n}/3
   - Result: APPROVED | ESCALATED
   - P1 remaining: {list or "none"}
   ```
6. **Graceful degradation**: if `claude` CLI is not available (`which claude` fails) or the API call fails after 1 retry, skip cross-review, proceed with self-review only, and note in the workpad: `Cross-review skipped: {reason}`.

**Phase 3: Approve and merge**

7. Once both self-review and cross-review pass:
   - Approve the PR: `gh pr review --approve -b "[auto-review] Self-review + cross-review passed. All checks green."`.
   - Add labels: `gh pr edit --add-label auto-reviewed --add-label cross-reviewed`.
   - Move the issue to `Merging`.
8. Proceed to Step 3c (merge handling).

## Step 3b: Auto Review (high risk — Claude reviews automatically)

This flow applies when the change is classified as high risk with `checkpoint_type=human-verify`.
Symphony dispatches Claude (not Codex) to perform the review via the `claude-reviewer` runtime.

**When Claude is dispatched for Auto Review, it should:**

1. Read `AGENTS.md` to understand project constraints.
2. Read the exec-plan referenced in the issue description.
3. Read the Codex Workpad comment on the issue (via `linear_graphql`) to understand:
   - What was implemented (Plan section)
   - What was validated (Validation section)
   - Risk assessment and self-review findings
4. Review the PR diff (`gh pr diff <number>`), focusing on:
   - Design intent alignment with exec-plan acceptance criteria
   - Architecture compliance with AGENTS.md constraints
   - Cross-package boundary violations
   - Security concerns
5. Make a decision:
   - **APPROVE**: `gh pr review --approve`, remove `claude-review` label, move issue to `Merging`.
   - **REQUEST CHANGES**: leave PR comment with specific issues, move issue to `Rework`.
   - **ESCALATE**: if the change requires human judgment (architectural tradeoff, business decision),
     move issue to `Human Review` with explanation in workpad.

## Step 3b-human: Human Review (decision / human-action only)

This flow applies only when `checkpoint_type=decision` or `checkpoint_type=human-action`.
Symphony does NOT dispatch agents for this state — a human must act.

1. Issue is in `Human Review`, waiting for human.
2. Human reviews, makes decision or performs action.
3. Human moves issue to `Merging` (approved) or `Rework` (changes needed).

## Step 3c: Merge handling

1. When the issue is in `Merging`, use the `land` skill and run it in a loop until the PR is merged. Do not call `gh pr merge` directly.
2. After merge is complete, move the issue to `Done`.

## Step 4: Rework handling

1. Treat `Rework` as a full approach reset, not incremental patching.
2. Re-read the full issue body and all human comments; explicitly identify what will be done differently this attempt.
3. Close the existing PR tied to the issue.
4. Remove the existing `## Codex Workpad` comment from the issue.
5. Create a fresh branch from `origin/main`.
6. Start over from the normal kickoff flow:
   - If current issue state is `Todo`, move it to `In Progress`; otherwise keep the current state.
   - Create a new bootstrap `## Codex Workpad` comment.
   - Build a fresh plan/checklist and execute end-to-end.

## Goal-backward verification

Before marking work complete, verify from the user's perspective — not just task completion:

1. **Observable truths**: List 3-7 user-observable behaviors that should be true after this change. Verify each.
2. **Artifact existence**: For every new file/module created, verify it exists and is non-trivial (not a stub/placeholder).
3. **Artifact wiring**: For every new artifact, verify it is imported/used somewhere — not orphaned code.
4. **Anti-pattern scan**: Check for leftover `TODO`, `FIXME`, `console.log`, empty implementations, placeholder returns.

Record results in the workpad `### Goal-Backward Verification` section.

## Completion bar before review routing

- Step 1/2 checklist is fully complete and accurately reflected in the single workpad comment.
- Acceptance criteria and required ticket-provided validation items are complete.
- Validation/tests are green for the latest commit.
- Goal-backward verification is complete with no unresolved gaps.
- PR feedback sweep is complete and no actionable comments remain.
- PR checks are green, branch is pushed, and PR is linked on the issue.
- Required PR metadata is present (`symphony` label).
- Risk classification (`risk_level`) and checkpoint classification (`checkpoint_type`) are recorded in the workpad `### Risk Assessment` section.
- If `checkpoint_type=decision`, workpad includes `### Decision Options` with options and pros/cons.
- If `checkpoint_type=human-action`, workpad includes `### Human Action Steps` with precise ordered steps.
- If app-touching, runtime validation is complete and media evidence is uploaded to the Linear workpad.

## Guardrails

- If the branch PR is already closed/merged, do not reuse that branch or prior implementation state for continuation.
- For closed/merged branch PRs, create a new branch from `origin/main` and restart from reproduction/planning as if starting fresh.
- If issue state is `Backlog`, do not modify it; wait for human to move to `Todo`.
- Do not edit the issue body/description for planning or progress tracking.
- Use exactly one persistent workpad comment (`## Codex Workpad`) per issue.
- If comment editing is unavailable in-session, use the update script. Only report blocked if both `linear_graphql` editing and script-based editing are unavailable.
- Temporary proof edits are allowed only for local verification and must be reverted before commit.
- If out-of-scope improvements are found, create a separate Backlog issue rather
  than expanding current scope, and include a clear
  title/description/acceptance criteria, same-project assignment, a `related`
  link to the current issue, and `blockedBy` when the follow-up depends on the
  current issue.
- Do not route to review (auto or human) unless the `Completion bar before review routing` is satisfied.
- In `Human Review` (high risk), do not make changes; wait and poll.
- Auto-review (Step 3a) is only permitted for low/medium risk changes. When in doubt, classify as high risk.
- Maximum 3 auto-fix attempts per failing task. After 3 failures, record blocker and move on or escalate.
- Do not read 5+ files consecutively without making edits. If stuck in analysis, start implementing or report a blocker.
- If state is terminal (`Done`), do nothing and shut down.
- Keep issue text concise, specific, and reviewer-oriented.
- If blocked and no workpad exists yet, add one blocker comment describing blocker, impact, and next unblock action.

## Workpad template

Use this exact structure for the persistent workpad comment and keep it updated in place throughout execution:

````md
## Codex Workpad

```text
<hostname>:<abs-path>@<short-sha>
```

### Plan

- [ ] 1\. Parent task
  - [ ] 1.1 Child task
  - [ ] 1.2 Child task
- [ ] 2\. Parent task

### Acceptance Criteria

- [ ] Criterion 1
- [ ] Criterion 2

### Validation

- [ ] targeted tests: `<command>`

### Risk Assessment

- risk_level: low | medium | high
- checkpoint_type: human-verify | decision | human-action
- Rationale: <one-line reason>
- Review path: auto-review | human-review

### Decision Options

- <only for `checkpoint_type=decision`; include options with pros/cons>

### Human Action Steps

- <only for `checkpoint_type=human-action`; include precise ordered steps>

### Self-Review

- <findings from PR diff self-review, only for auto-review path>

### Cross-Review

- <cross-model review result, only for auto-review path>

### Goal-Backward Verification

- [ ] Observable truth 1: <user-visible behavior>
- [ ] Artifact existence: <new files are non-stub>
- [ ] Artifact wiring: <new files are imported/used>
- [ ] Anti-pattern scan: no TODO/FIXME/placeholder remains

### Notes

- <short progress note with timestamp>

### Blockers

- <only include when auto-fix attempts exhausted — what failed, what was tried, suspected root cause>

### Confusions

- <only include when something was confusing during execution>
````
