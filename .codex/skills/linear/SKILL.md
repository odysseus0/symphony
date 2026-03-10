---
name: linear
description: |
  Linear API operations for Symphony agents. Provides scripts for workpad sync,
  state transitions, PR attachment, and file uploads. Use these scripts instead
  of composing raw GraphQL.
---

# Linear Operations

Scripts for all common Linear operations. Use these instead of raw `linear_graphql`
calls — they handle auth, error handling, and return minimal output.

All scripts require `LINEAR_API_KEY` in the environment.

## Workpad

Maintain a local `workpad.md` file in your workspace root. Edit it freely (zero
API cost), then sync to Linear at milestones — plan finalized, implementation
done, validation complete. Do not sync after every small change.

```
python3 .codex/skills/linear/scripts/sync-workpad.py <issue-id>
```

First call creates the comment on the issue. Subsequent calls update it.
State is tracked in `.workpad-id` (created automatically).

Output: `synced (created)` or `synced (updated)`

## State transitions

Move an issue to a named workflow state. Resolves the state name to an internal
ID automatically — you never need to look up state IDs.

```
python3 .codex/skills/linear/scripts/move-issue.py <issue-id> "<state-name>"
```

Output: `moved to <state-name>` or lists available states on error.

## PR attachment

Link a GitHub PR to a Linear issue:

```
python3 .codex/skills/linear/scripts/attach-pr.py <issue-id> <pr-url> [title]
```

Output: `attached`

For non-GitHub URLs (plain links, docs, etc.):

```
python3 .codex/skills/linear/scripts/attach-url.py <issue-id> <url> [title]
```

Output: `attached`

## File upload

Upload a file (screenshot, video, etc.) and get a URL to embed in comments or
the workpad:

```
python3 .codex/skills/linear/scripts/upload-file.py <file-path>
```

Output: the asset URL. Embed as `![description](url)` for images or
`[filename](url)` for other files.

## Reading issues

The orchestrator injects issue context (identifier, title, description, state,
labels, URL) into your prompt at startup. You usually do not need to re-read
the issue.

If you need comments, attachments, or linked PRs:

```
python3 .codex/skills/linear/scripts/read-issue.py <issue-id>
```

Output: markdown-formatted comments (with IDs) and attachments. Only what
you need for context — not the full issue dump.

## Rules

- Use the scripts above for all write operations. Do not compose raw GraphQL
  for workpad updates, state transitions, PR attachments, or file uploads.
- Do not use `__type` introspection queries — they return the entire schema
  (200K+ chars) and waste most of the context window.
- Keep `linear_graphql` queries narrowly scoped — ask only for fields you need.
- Sync the workpad at milestones, not after every change.
