# OpenCode Backend

`SymphonyElixir.Backend.OpenCode` adapts OpenCode ACP (`opencode acp`) to the
`SymphonyElixir.AgentBackend` behaviour used by the orchestrator.

## Prerequisites

- `opencode` CLI installed and available in `PATH`
- workflow config uses `codex.backend: opencode`
- ACP protocol version currently pinned to `1`

## Workflow Configuration

```yaml
codex:
  backend: opencode
  opencode_command: opencode acp
  opencode_mcp_servers:
    - name: linear
      command: npx
      args: ["-y", "@linear/mcp-server"]
      env: []
```

`opencode_mcp_servers` is passed through to ACP `session/new` as
`params.mcpServers`.

## Runtime Model Mapping

| Symphony | OpenCode ACP |
| --- | --- |
| `start_session` | `initialize` -> `session/new` |
| `run_turn` | `session/prompt` + `session/update` notifications -> final response |
| `stop_session` | close ACP port |

Observed `session/update` update kinds:

- `available_commands_update`
- `agent_thought_chunk`
- `agent_message_chunk`
- `usage_update`

## Sandbox / Runtime Config

The adapter creates a per-session runtime folder under workspace
`.symphony-opencode/<id>/opencode.json`.

This temporary config is used only for the spawned ACP process and removed when
the session stops.

## Known Limitations

- ACP method coverage in this adapter is intentionally narrow (`initialize`,
  `session/new`, `session/prompt`).
- The adapter forwards MCP server definitions, but MCP server correctness is
  owned by the configured server command itself.
