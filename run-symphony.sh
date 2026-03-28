#!/usr/bin/env bash
# Symphony launcher — loads secrets from Keychain, then exec's the Elixir runtime.
# Usage: run-symphony.sh <project-dir>
# Example:
#   run-symphony.sh spanory
#   run-symphony.sh another-project
set -euo pipefail

SYMPHONY_BIN="/Users/javis/Documents/workspace/projects/symphony/elixir/bin/symphony"
PROJECTS_ROOT="/Users/javis/Documents/workspace/projects"
GUARDRAIL_FLAG="--i-understand-that-this-will-be-running-without-the-usual-guardrails"

PROJECT="${1:?Usage: run-symphony.sh <project-name>}"

# Resolve project directory: try exact path first, then common locations
if [ -d "$PROJECT" ]; then
  PROJECT_DIR="$PROJECT"
elif [ -d "$PROJECTS_ROOT/$PROJECT" ]; then
  PROJECT_DIR="$PROJECTS_ROOT/$PROJECT"
elif [ -d "$PROJECTS_ROOT/${PROJECT}-all/$PROJECT" ]; then
  PROJECT_DIR="$PROJECTS_ROOT/${PROJECT}-all/$PROJECT"
else
  echo "Project not found: $PROJECT" >&2
  echo "Searched: $PROJECT, $PROJECTS_ROOT/$PROJECT, $PROJECTS_ROOT/${PROJECT}-all/$PROJECT" >&2
  exit 1
fi

export LINEAR_API_KEY
LINEAR_API_KEY="$(security find-generic-password -a "$USER" -s LINEAR_API_KEY -w)"

export HOME="/Users/javis"
export MIX_HOME="/Users/javis/.local/share/mise/installs/elixir/1.19.5-otp-28/.mix"
export MIX_ARCHIVES="${MIX_HOME}/archives"
export PATH="/Users/javis/.local/share/mise/installs/erlang/28.4.1/bin:/Users/javis/.local/share/mise/installs/elixir/1.19.5-otp-28/bin:${MIX_HOME}/escripts:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"

PIDFILE="/tmp/symphony-$(echo "$PROJECT_DIR" | md5 -q).pid"

# Guard: prevent multiple instances for the same project
if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
  echo "Symphony already running for $PROJECT_DIR (pid $(cat "$PIDFILE"))" >&2
  exit 1
fi

echo "Symphony starting for: $PROJECT_DIR"
cd "$PROJECT_DIR"
echo $$ > "$PIDFILE"
exec "$SYMPHONY_BIN" "$GUARDRAIL_FLAG"
