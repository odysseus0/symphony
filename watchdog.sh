#!/usr/bin/env bash
# Symphony Watchdog — detect rate limit recovery and restart Symphony.
# Runs periodically via launchd. Does nothing when rate-limited.
set -euo pipefail

LOG="/Users/javis/Library/Logs/Symphony/watchdog.log"
SERVICE="gui/$(id -u)/com.bububuger.symphony"
OPENAI_ENDPOINT="https://api.openai.com/v1/chat/completions"

log() { printf '%s [watchdog] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG"; }

# 1. Check if Symphony is running
if ! launchctl print "$SERVICE" &>/dev/null; then
  log "Symphony not registered, skipping"
  exit 0
fi

# 2. Read Symphony stdout for active agent count
STDOUT="/Users/javis/Library/Logs/Symphony/stdout.log"
ACTIVE_AGENTS=$(tail -200 "$STDOUT" 2>/dev/null | strings | grep -o 'Agents: [0-9]*' | tail -1 | grep -o '[0-9]*' || echo "0")

# 3. Check if there are pending issues in active states
PENDING=$(curl -s -X POST https://api.linear.app/graphql \
  -H "Content-Type: application/json" \
  -H "Authorization: $(security find-generic-password -a "$USER" -s LINEAR_API_KEY -w)" \
  -d '{"query":"{ project(id: \"b2f9becf3a3c\") { issues(filter: { state: { name: { in: [\"Todo\", \"In Progress\", \"Rework\"] } } }) { nodes { id } } } }"}' \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d['data']['project']['issues']['nodes']))" 2>/dev/null || echo "0")

if [ "$PENDING" = "0" ]; then
  log "No pending issues, all clear. Agents=$ACTIVE_AGENTS"
  exit 0
fi

# 4. If agents are running, Symphony is healthy
if [ "$ACTIVE_AGENTS" != "0" ]; then
  log "Healthy: $ACTIVE_AGENTS agents active, $PENDING issues pending"
  exit 0
fi

# 5. Zero agents + pending issues = likely rate-limited or stalled
# Probe OpenAI API with minimal request to check rate limit status
PROBE=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$OPENAI_ENDPOINT" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $OPENAI_API_KEY" \
  -d '{"model":"gpt-4o-mini","messages":[{"role":"user","content":"ping"}],"max_tokens":1}' \
  --max-time 10 2>/dev/null || echo "000")

if [ "$PROBE" = "429" ]; then
  log "Rate limited (HTTP 429). $PENDING issues waiting. Will retry next cycle."
  exit 0
fi

if [ "$PROBE" = "000" ]; then
  log "OpenAI unreachable (timeout/network). $PENDING issues waiting. Will retry next cycle."
  exit 0
fi

# 6. Rate limit cleared + zero agents + pending issues = restart Symphony
log "Rate limit cleared (HTTP $PROBE). $PENDING pending issues, 0 agents. Restarting Symphony."
launchctl kickstart -k "$SERVICE" 2>>"$LOG"
log "Symphony restarted."
