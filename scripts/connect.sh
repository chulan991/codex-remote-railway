#!/usr/bin/env bash
# Convenience wrapper for attaching a LOCAL codex client to the Railway
# app-server. Reads the WSS host and token from env vars so no secrets end
# up in your shell history.
#
# Usage:
#   export CODEX_REMOTE_HOST='codex-remote-railway.tail-XXXX.ts.net'  # tailnet
#     # ...or a Railway public domain, e.g. 'codex-remote.up.railway.app'
#   export CODEX_WS_TOKEN='the-token-you-set-on-the-server'
#   ./scripts/connect.sh
#
# Any additional args are forwarded to `codex` (e.g. `resume`, `fork <id>`).
set -euo pipefail

: "${CODEX_REMOTE_HOST:?set CODEX_REMOTE_HOST to the wss host (Tailscale MagicDNS name or Railway public domain)}"
: "${CODEX_WS_TOKEN:?set CODEX_WS_TOKEN to the plaintext capability token the server was configured with}"

PORT_SUFFIX=""
if [ -n "${CODEX_REMOTE_PORT:-}" ]; then
  PORT_SUFFIX=":${CODEX_REMOTE_PORT}"
fi

URL="wss://${CODEX_REMOTE_HOST}${PORT_SUFFIX}"

exec codex \
  --remote "$URL" \
  --remote-auth-token-env CODEX_WS_TOKEN \
  "$@"
