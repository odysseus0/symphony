# Symphony

Fork of [openai/symphony](https://github.com/openai/symphony) with better defaults for production use and a complete onboarding flow. Push tickets to a Linear board, agents ship the code.

[![Symphony demo video preview](.github/media/symphony-demo-poster.jpg)](.github/media/symphony-demo.mp4)

## Quick start

If you have an AI coding agent, one command:

```
npx skills add odysseus0/symphony -s symphony-setup -y
```

Then ask your agent to set up Symphony for your repo.

## How it works

Symphony polls a Linear project for active tickets. Each ticket gets an isolated workspace clone and a Codex agent. The agent reads the ticket, writes a plan, implements, validates, and opens a PR. You review PRs and move tickets through states — the agents handle the rest.

The state machine lives in `WORKFLOW.md` — a markdown file with YAML frontmatter for config and a prompt body that defines agent behavior. Hot-reloads in under a second, no restart needed.

## Multi-agent support

Symphony supports routing issues to different coding agents via label-based routing. In addition to the default Codex agent, Symphony includes a protocol bridge for **Cursor CLI** using the [Agent Client Protocol (ACP)](https://agentclientprotocol.com/). The `cursor-symphony-bridge` script translates between Symphony's app-server protocol and ACP's session-based JSON-RPC 2.0 protocol, enabling persistent sessions, streaming updates, and automatic permission handling.

To route issues to Cursor, configure agents and routing in your `WORKFLOW.md`:

```yaml
agents:
  cursor:
    command: cursor-symphony-bridge --model gpt-5.4
routing:
  default_agent: cursor
  # or route by label:
  by_label:
    use-cursor: cursor
```

The bridge forwards `--model` to the Cursor CLI at startup, so you can pin a
specific model per agent definition. If you prefer an environment default,
`CURSOR_MODEL=gpt-5.4` is also supported, but an explicit `--model` in
`command:` takes precedence.

Requires the Cursor CLI (`agent`) on PATH and `CURSOR_API_KEY` set in the
environment.

## What's different from upstream

- **Cheaper Linear calls** — agents no longer burn tokens on schema introspection before every GraphQL call, and workpad sync is a single dynamic tool instead of a hand-rolled mutation
- **Correct sandbox** — the workflow is git + GitHub PR centric. Upstream's default sandbox blocks `.git/` writes, which silently breaks the entire flow. Fixed.
- **Media uploads via Linear** — upstream references a GitHub media upload skill that doesn't ship. The workflow and Linear skill now use Linear's native `fileUpload` mutation for screenshots and recordings
- **Setup skill** — auto-detects your repo, installs worker skills, creates Linear workflow states, and verifies everything before launch

## Manual setup

1. Build: `git clone https://github.com/odysseus0/symphony && cd symphony/elixir && mise trust && mise install && mise exec -- mix setup && mise exec -- mix build`
2. Install skills: `npx skills add odysseus0/symphony -a codex -s linear land commit push pull debug --copy -y` and copy `elixir/WORKFLOW.md` to your repo
3. In WORKFLOW.md, set `tracker.project_slug` and `hooks.after_create` (clone your repo + setup commands)
4. Add **Rework**, **Human Review**, **Merging** as custom states in Linear (Team Settings → Workflow)
5. Commit, push, then: `mise exec -- ./bin/symphony /path/to/your-repo/WORKFLOW.md`

**[Getting Started with OpenAI Symphony](https://x.com/odysseus0z/status/2031850264240800131)** — full walkthrough with context on why these defaults matter.

## License

[Apache License 2.0](LICENSE)
