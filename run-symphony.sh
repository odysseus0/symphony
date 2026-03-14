#!/usr/bin/env bash
# Symphony launcher — loads secrets from Keychain, then exec's the Elixir runtime.
set -euo pipefail

export LINEAR_API_KEY
LINEAR_API_KEY="$(security find-generic-password -a "$USER" -s LINEAR_API_KEY -w)"

export HOME="/Users/javis"
export MIX_HOME="/Users/javis/.local/share/mise/installs/elixir/1.19.5-otp-28/.mix"
export MIX_ARCHIVES="${MIX_HOME}/archives"
export PATH="/Users/javis/.local/share/mise/installs/erlang/28.4.1/bin:/Users/javis/.local/share/mise/installs/elixir/1.19.5-otp-28/bin:${MIX_HOME}/escripts:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"

cd /Users/javis/code/symphony/elixir
exec ./bin/symphony "$@"
