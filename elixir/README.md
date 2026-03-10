# Symphony (getting-started fork)

Fork of [openai/symphony](https://github.com/openai/symphony) with setup friction removed. See the [upstream README](https://github.com/openai/symphony/tree/main/elixir) for the full spec and configuration reference.

## What's changed from upstream

- **Sandbox → `dangerFullAccess`** — the workflow is GitHub-centric: agents commit, push, and create PRs. The upstream default (`workspaceWrite`) blocks `.git/` writes, causing silent failures. Each worker runs in its own isolated clone, so full access is safe.
- **Linear MCP → scoped `linear_graphql`** — Linear MCP returns full JSON payloads that waste tokens. This fork uses `linear_graphql` with narrowly scoped queries only.
- **Internal tool references removed** — `github-pr-media` and `launch-app` were never open-sourced. Media upload now uses the `linear` skill's `fileUpload` flow. App launching is project-specific — see the setup skill.
- **Portable `before_remove` hook** — upstream runs a Symphony-specific Mix task. Replaced with a `gh` one-liner that works in any repo.

## Get started

If you're using Claude Code or Codex, install the setup skill — it handles everything below plus project-specific config like `launch-app`:

```
npx skills add https://github.com/odysseus0/symphony/tree/getting-started -s symphony-setup -y
```

Otherwise, the quick start:

1. Build: `git clone -b getting-started https://github.com/odysseus0/symphony && cd symphony/elixir && mise trust && mise install && mise exec -- mix setup && mise exec -- mix build`
2. Install skills: `npx skills add https://github.com/odysseus0/symphony/tree/getting-started -a codex --copy -y` and copy `elixir/WORKFLOW.md` to your repo
3. In WORKFLOW.md, set `tracker.project_slug` and `hooks.after_create` (clone your repo + setup commands)
4. Add **Rework**, **Human Review**, **Merging** as custom states in Linear (Team Settings → Workflow)
5. Commit, push, then: `mise exec -- ./bin/symphony /path/to/your-repo/WORKFLOW.md`

**[Getting Symphony Running](TODO)** — full walkthrough with context on why these fixes matter.

## License

Same as upstream: [Apache License 2.0](../LICENSE).
