# Reliability

## Current State

Symphony runs as a long-lived escript daemon (launchd on macOS).
All state is in-memory (Orchestrator GenServer) — no database persistence.

Monitoring: Terminal status dashboard + Phoenix LiveView + structured JSON logs
Alerting: TBD

## Resilience Mechanisms

- **Retry with backoff**: Failed agent runs retried with configurable max attempts
- **Empty turn circuit breaker**: Consecutive empty turns (<5s) trigger early exit after 3 occurrences
- **Issue state refresh**: Each turn re-checks issue state from tracker before continuing
- **Error classification**: `ErrorClassifier` categorizes failures for appropriate retry/abort decisions
- **Orchestrator reconciliation**: Running entries reconciled against actual task status on each poll cycle

## SLA Targets
TBD — needs team input

## Known Failure Modes

- Orchestrator crash loses all in-memory running state (restarts with clean slate)
- Tracker API rate limits can delay polling
- Agent backend timeouts (configurable per-runtime: `turn_timeout_ms`, `read_timeout_ms`, `stall_timeout_ms`)
