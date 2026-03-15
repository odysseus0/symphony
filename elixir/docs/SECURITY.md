# Security

## Threat Surface

Symphony handles:
- **Issue tracker API tokens** (Linear/Plane) — used for polling and state reads
- **AI provider API keys** — passed to agent backends via environment
- **Agent sandboxing** — controls what the coding agent can do in the workspace

## Key Controls

### Workspace Isolation
- Agent execution runs in per-issue git worktrees, never in the source repo
- `PathSafety` module validates all workspace paths stay under configured root
- Workspace root is configurable but enforced at runtime

### Credential Handling
- API tokens read from environment variables, never from config files
- No credentials stored in `WORKFLOW.md` or any versioned file
- Agent sandbox policies (approval, thread sandbox, turn sandbox) configured per-runtime

### Agent Sandbox Policies
- `approval_policy`: controls whether agent actions require human approval
- `thread_sandbox`: constrains filesystem access scope per thread
- `turn_sandbox_policy`: per-turn execution constraints
- Policies configurable per-runtime in `WORKFLOW.md`

## Incident Response
TBD — needs team input
