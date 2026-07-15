#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Codex Remote on Railway — container entrypoint
# ---------------------------------------------------------------------------
# 1. Optionally join a Tailscale tailnet (with Tailscale SSH) — only when
#    TS_AUTHKEY / TAILSCALE_AUTHKEY is set. Idempotent: persisted state on
#    the volume keeps the node identity across redeploys, so a subsequent
#    boot skips `tailscale up`. Tailscale failure never blocks app-server.
# 2. Derive the WebSocket capability-token SHA-256 digest (from the plaintext
#    CODEX_WS_TOKEN, unless CODEX_WS_TOKEN_SHA256 is provided directly).
# 3. Exec `codex app-server --listen ws://0.0.0.0:${PORT}` with capability-
#    token auth. Clients connect with `codex --remote wss://…
#    --remote-auth-token-env CODEX_WS_TOKEN` (TLS terminated in front of the
#    container — Railway public domains and Tailscale HTTPS both do this).
# ---------------------------------------------------------------------------

set -euo pipefail

log() { printf '[entrypoint] %s\n' "$*"; }

# --- Tailscale ---------------------------------------------------------------
AUTHKEY="${TS_AUTHKEY:-${TAILSCALE_AUTHKEY:-}}"
TS_STATE_DIR_DEFAULT="/var/lib/tailscale"
STATE_DIR="${TS_STATE_DIR:-$TS_STATE_DIR_DEFAULT}"
SOCKET="${TS_SOCKET:-/tmp/tailscaled.sock}"
HOSTNAME_TS="${TS_HOSTNAME:-codex-remote-railway}"

start_tailscale() {
  if [ -z "$AUTHKEY" ]; then
    log "No TS_AUTHKEY / TAILSCALE_AUTHKEY set — skipping Tailscale."
    return 0
  fi

  log "Tailscale auth key detected — starting tailscaled (userspace networking)."
  mkdir -p "$STATE_DIR" 2>/dev/null || {
    log "WARNING: could not create $STATE_DIR — falling back to /tmp/tailscale."
    STATE_DIR="/tmp/tailscale"
    mkdir -p "$STATE_DIR"
  }

  tailscaled \
    --state="$STATE_DIR/tailscaled.state" \
    --socket="$SOCKET" \
    --tun=userspace-networking &

  # Wait for the local API to come up.
  n=0
  until tailscale --socket="$SOCKET" status --json 2>/dev/null | grep -q '"BackendState"' \
        || [ "$n" -ge 30 ]; do
    n=$((n + 1))
    sleep 1
  done

  # Idempotent join: skip `tailscale up` if the daemon reports "Running".
  if tailscale --socket="$SOCKET" status --json 2>/dev/null \
       | grep -q '"BackendState":[[:space:]]*"Running"'; then
    log "Already connected to the tailnet — skipping 'tailscale up'."
    return 0
  fi

  log "Joining tailnet and enabling Tailscale SSH."
  # shellcheck disable=SC2086 # TS_EXTRA_ARGS is intentionally word-split.
  if tailscale --socket="$SOCKET" up \
       --ssh \
       --authkey="$AUTHKEY" \
       --hostname="$HOSTNAME_TS" \
       ${TS_EXTRA_ARGS:-}; then
    log "Tailscale is up (SSH enabled) as '$HOSTNAME_TS'."
  else
    log "WARNING: 'tailscale up' failed — continuing without Tailscale."
  fi
}

# --- Codex app-server auth ---------------------------------------------------
resolve_token_sha256() {
  # Precedence: explicit digest > derive from plaintext token > error.
  if [ -n "${CODEX_WS_TOKEN_SHA256:-}" ]; then
    printf '%s' "$CODEX_WS_TOKEN_SHA256" | tr -d '[:space:]'
    return 0
  fi
  if [ -n "${CODEX_WS_TOKEN:-}" ]; then
    printf '%s' "$CODEX_WS_TOKEN" \
      | sha256sum \
      | awk '{print $1}'
    return 0
  fi
  return 1
}

# --- Codex config / OpenAI auth ---------------------------------------------
# Make sure the persisted Codex config dir exists and warn early if there's no
# way for the model calls to authenticate. The user can either:
#   * set OPENAI_API_KEY as a Railway variable, OR
#   * bake a pre-authenticated auth.json into /root/.codex on the volume
#     (produced by `codex login` on any machine, then copied in).
mkdir -p /root/.codex
if [ -z "${OPENAI_API_KEY:-}" ] && [ ! -f /root/.codex/auth.json ]; then
  log "WARNING: neither OPENAI_API_KEY nor /root/.codex/auth.json is present."
  log "         The app-server will start but model calls will fail until one"
  log "         of them is provided. See README → 'Model auth on the server'."
fi

# --- Main --------------------------------------------------------------------
start_tailscale

PORT="${PORT:-8080}"
LISTEN_HOST="${CODEX_LISTEN_HOST:-0.0.0.0}"

TOKEN_SHA256="$(resolve_token_sha256 || true)"
if [ -z "$TOKEN_SHA256" ]; then
  log "FATAL: no CODEX_WS_TOKEN or CODEX_WS_TOKEN_SHA256 set — refusing to"
  log "       start an unauthenticated app-server on a public listener."
  log "       Set CODEX_WS_TOKEN (recommended) as a Railway variable."
  exit 1
fi

log "Starting codex app-server on ${LISTEN_HOST}:${PORT} (capability-token auth)."
log "Codex version: $(codex --version 2>/dev/null || echo unknown)"

# Drop the plaintext token from the process env before exec so it does not
# show up in `codex` subprocess env dumps or crash logs. The digest is all
# `codex app-server` needs.
unset CODEX_WS_TOKEN

exec codex app-server \
  --listen "ws://${LISTEN_HOST}:${PORT}" \
  --ws-auth capability-token \
  --ws-token-sha256 "${TOKEN_SHA256}"
