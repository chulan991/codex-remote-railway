#!/usr/bin/env bash
# Generate a strong Codex WebSocket capability token and print BOTH the
# plaintext (for CODEX_WS_TOKEN on both sides) and the SHA-256 digest (for
# CODEX_WS_TOKEN_SHA256 if you would rather not store the plaintext on the
# server).
set -euo pipefail

TOKEN="$(openssl rand -base64 48 | tr -d '=+/' | cut -c1-64)"
DIGEST="$(printf %s "$TOKEN" | sha256sum | awk '{print $1}')"

cat <<EOF
# --- Codex Remote WebSocket capability token -------------------------------

# Set on the Railway 'app' service Variables tab (recommended):
CODEX_WS_TOKEN=$TOKEN

# ...OR set the digest instead, and keep the plaintext only on your laptop:
CODEX_WS_TOKEN_SHA256=$DIGEST

# On your local machine, export the plaintext and pass its env-var name to
# codex when attaching:
#   export CODEX_WS_TOKEN='$TOKEN'
#   codex --remote wss://<host>[:<port>] --remote-auth-token-env CODEX_WS_TOKEN
EOF
