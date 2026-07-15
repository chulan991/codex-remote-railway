#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# codex-remote-railway — container entrypoint
# ---------------------------------------------------------------------------
# TWO START MODES (selected by the START_MODE env var):
#
#   tailscale-only   (DEFAULT)
#     Boot only Tailscale, keep the container alive, and do NOT start
#     `codex app-server`. Intended for standing up a remote environment
#     you SSH into over the tailnet to set Codex up interactively (or
#     to iterate on the Codex layer later). Because Tailscale state
#     lives on the persistent volume, redeploys reuse the same node
#     identity and do NOT re-`tailscale up` unless the daemon reports
#     the node is not Running.
#
#   codex+tailscale
#     Boot Tailscale as above, then exec `codex app-server` with
#     capability-token WebSocket auth. This is the fully-automated
#     "remote Codex server" mode.
#
# PERSISTENCE
#   Railway allows one volume per service, mounted at /workspace here.
#   setup_persistent_dirs symlinks the two logical dirs the app cares
#   about into subdirs of /workspace:
#     /root/.codex        -> /workspace/.codex-data
#     /var/lib/tailscale  -> /workspace/.tailscale-state
#   Migration is dotfile-safe and non-destructive: existing files on
#   the volume are never overwritten (mv -n), the source dir is only
#   replaced with a symlink if it becomes empty.
#
# TAILSCALE IDEMPOTENCY
#   start_tailscale:
#     1. Starts tailscaled with state in /var/lib/tailscale (persisted).
#     2. Waits for the local API socket to come up.
#     3. Reads BackendState from `tailscale status --json`:
#         - "Running"                       -> skip `tailscale up` entirely
#         - "Stopped" / "NoState" / "NeedsLogin" / anything else
#                                           -> re-run `tailscale up`
#     4. When re-running `tailscale up`:
#         - if persisted state has a node key already, no auth key is
#           required (Tailscale reuses the stored identity)
#         - if there is no persisted identity, TS_AUTHKEY MUST be set,
#           or the entrypoint fails fast with a clear error.
# ---------------------------------------------------------------------------

set -euo pipefail

log() { printf '[entrypoint] %s\n' "$*"; }

START_MODE="${START_MODE:-tailscale-only}"
WORKSPACE_DIR="${WORKSPACE_DIR:-/workspace}"

# --- Persistent storage via symlinks on the mounted volume ------------------
setup_persistent_dirs() {
  local workspace="$WORKSPACE_DIR"

  if [ ! -d "$workspace" ]; then
    log "ERROR: $workspace does not exist. Is the Railway volume mounted?"
    exit 1
  fi

  mkdir -p "$workspace/.codex-data" "$workspace/.tailscale-state"

  _link_persistent_dir "/root/.codex"       "$workspace/.codex-data"
  _link_persistent_dir "/var/lib/tailscale" "$workspace/.tailscale-state"
}

_link_persistent_dir() {
  local logical="$1"
  local persisted="$2"

  if [ -L "$logical" ]; then
    local current
    current="$(readlink -f "$logical" 2>/dev/null || true)"
    if [ "$current" = "$persisted" ]; then
      log "✓ $logical already symlinked to $persisted"
      return 0
    fi
    log "Retargeting symlink $logical -> $persisted (was: $current)"
    rm -f "$logical"
    ln -s "$persisted" "$logical"
    return 0
  fi

  if [ -e "$logical" ]; then
    # Not a symlink but exists -> plain dir. Migrate contents into the
    # persisted target (dotfile-safe, non-destructive) then symlink.
    if [ -d "$logical" ] && [ -z "$(ls -A "$logical" 2>/dev/null || true)" ]; then
      rmdir "$logical"
    else
      log "⚠ Migrating existing $logical into $persisted (mv -n, dotfile-safe)"
      find "$logical" -mindepth 1 -maxdepth 1 -print0 \
        | xargs -0 -r -I{} mv -n {} "$persisted/" || true
      if ! rmdir "$logical" 2>/dev/null; then
        log "WARNING: $logical still not empty after migration; leaving as-is"
        return 0
      fi
    fi
  fi

  mkdir -p "$(dirname "$logical")"
  ln -s "$persisted" "$logical"
  log "✓ Linked $logical -> $persisted"
}

# --- Tailscale --------------------------------------------------------------
AUTHKEY="${TS_AUTHKEY:-${TAILSCALE_AUTHKEY:-}}"
TS_STATE_DIR_DEFAULT="/var/lib/tailscale"
STATE_DIR="${TS_STATE_DIR:-$TS_STATE_DIR_DEFAULT}"
SOCKET="${TS_SOCKET:-/tmp/tailscaled.sock}"
HOSTNAME_TS="${TS_HOSTNAME:-codex-remote-railway}"
TAILSCALED_PID=""

# Return the Tailscale BackendState string, or "NoDaemon" if the API socket
# is not responding. Used to decide whether to skip `tailscale up`.
_ts_backend_state() {
  tailscale --socket="$SOCKET" status --json 2>/dev/null \
    | grep -o '"BackendState":[[:space:]]*"[^"]*"' \
    | head -1 \
    | sed -E 's/.*"BackendState":[[:space:]]*"([^"]*)".*/\1/' \
    || printf 'NoDaemon'
}

# True if the persisted Tailscale state directory contains a node key. In
# that case `tailscale up` can re-use the existing identity without needing
# TS_AUTHKEY. If the state is empty (first boot on a fresh volume), an
# auth key is required.
_ts_has_persisted_identity() {
  [ -s "$STATE_DIR/tailscaled.state" ]
}

start_tailscale() {
  mkdir -p "$STATE_DIR" 2>/dev/null || {
    log "WARNING: could not create $STATE_DIR — falling back to /tmp/tailscale"
    STATE_DIR="/tmp/tailscale"
    mkdir -p "$STATE_DIR"
  }

  log "Starting tailscaled (userspace networking, state=$STATE_DIR)"
  tailscaled \
    --state="$STATE_DIR/tailscaled.state" \
    --socket="$SOCKET" \
    --tun=userspace-networking &
  TAILSCALED_PID=$!

  # Wait for the local API to come up.
  local n=0 backend=""
  while [ "$n" -lt 30 ]; do
    backend="$(_ts_backend_state)"
    case "$backend" in
      Running|Stopped|Starting|NeedsLogin|NoState) break ;;
    esac
    n=$((n + 1))
    sleep 1
  done

  backend="$(_ts_backend_state)"
  log "tailscaled reports BackendState=$backend"

  if [ "$backend" = "Running" ]; then
    log "✓ Tailscale already Running (persisted identity) — skipping 'tailscale up'"
    _log_ts_identity
    return 0
  fi

  # Any state other than Running -> we need to join (or rejoin).
  # If we have persisted identity we do NOT need an auth key.
  local up_args=(--ssh --hostname="$HOSTNAME_TS" --accept-dns=false)
  if _ts_has_persisted_identity; then
    log "Persisted Tailscale identity found — re-connecting without auth key"
  else
    if [ -z "$AUTHKEY" ]; then
      log "FATAL: no persisted Tailscale identity and TS_AUTHKEY is not set."
      log "       Set TS_AUTHKEY on this service to allow the FIRST tailnet"
      log "       join. Subsequent redeploys will reuse the persisted node"
      log "       identity and TS_AUTHKEY can be revoked afterwards."
      exit 1
    fi
    log "No persisted identity — joining tailnet with TS_AUTHKEY"
    up_args+=(--authkey="$AUTHKEY")
  fi

  # shellcheck disable=SC2086 # TS_EXTRA_ARGS is intentionally word-split.
  if tailscale --socket="$SOCKET" up "${up_args[@]}" ${TS_EXTRA_ARGS:-}; then
    log "✓ Tailscale is up (SSH enabled) as '$HOSTNAME_TS'"
    _log_ts_identity
  else
    log "ERROR: 'tailscale up' failed. See tailscaled logs above."
    exit 1
  fi
}

_log_ts_identity() {
  local dns ip4
  dns="$(tailscale --socket="$SOCKET" status --json 2>/dev/null \
         | grep -o '"DNSName":[[:space:]]*"[^"]*"' | head -1 \
         | sed -E 's/.*"DNSName":[[:space:]]*"([^"]*)".*/\1/' || true)"
  ip4="$(tailscale --socket="$SOCKET" ip -4 2>/dev/null | head -1 || true)"
  [ -n "$dns" ] && log "  tailnet DNS: ${dns%.}"
  [ -n "$ip4" ] && log "  tailnet IPv4: $ip4"
}

# --- Codex app-server (only in codex+tailscale mode) ------------------------
resolve_token_sha256() {
  if [ -n "${CODEX_WS_TOKEN_SHA256:-}" ]; then
    printf '%s' "$CODEX_WS_TOKEN_SHA256" | tr -d '[:space:]'
    return 0
  fi
  if [ -n "${CODEX_WS_TOKEN:-}" ]; then
    printf '%s' "$CODEX_WS_TOKEN" | sha256sum | awk '{print $1}'
    return 0
  fi
  return 1
}

start_codex_app_server() {
  local port="${PORT:-8080}"
  local listen_host="${CODEX_LISTEN_HOST:-0.0.0.0}"

  local token_sha256
  token_sha256="$(resolve_token_sha256 || true)"
  if [ -z "$token_sha256" ]; then
    log "FATAL: START_MODE=codex+tailscale but no CODEX_WS_TOKEN or"
    log "       CODEX_WS_TOKEN_SHA256 is set. Refusing to start an"
    log "       unauthenticated app-server on a public listener."
    exit 1
  fi

  if [ -z "${OPENAI_API_KEY:-}" ] && [ ! -f /root/.codex/auth.json ]; then
    log "WARNING: neither OPENAI_API_KEY nor /root/.codex/auth.json is present."
    log "         Model calls will fail until one is provided."
  fi

  log "Starting codex app-server on ${listen_host}:${port} (capability-token auth)"
  log "Codex version: $(codex --version 2>/dev/null || echo unknown)"

  # Drop plaintext token from env before exec so it does not leak into
  # subprocess env dumps or crash logs.
  unset CODEX_WS_TOKEN

  exec codex app-server \
    --listen "ws://${listen_host}:${port}" \
    --ws-auth capability-token \
    --ws-token-sha256 "$token_sha256"
}

# --- Signal handling --------------------------------------------------------
# When Railway sends SIGTERM we want to cleanly stop tailscaled so the
# persisted state file is flushed to disk before the volume unmounts.
_shutdown() {
  log "Received signal — shutting down cleanly"
  if [ -n "$TAILSCALED_PID" ] && kill -0 "$TAILSCALED_PID" 2>/dev/null; then
    tailscale --socket="$SOCKET" down 2>/dev/null || true
    kill -TERM "$TAILSCALED_PID" 2>/dev/null || true
    wait "$TAILSCALED_PID" 2>/dev/null || true
  fi
  exit 0
}
trap _shutdown SIGTERM SIGINT

# --- Main -------------------------------------------------------------------
log "START_MODE=$START_MODE"
setup_persistent_dirs
start_tailscale

case "$START_MODE" in
  tailscale-only)
    log "✓ Tailscale-only mode: container will stay alive with tailscaled"
    log "  running. SSH in over the tailnet to set up Codex:"
    log "    ssh root@${HOSTNAME_TS}   # (or the tailnet DNS name above)"
    # Block forever, but keep responding to signals so SIGTERM is handled.
    # `wait` on a background sleep is the standard trick for a signal-
    # responsive idle loop under bash.
    while true; do
      sleep 3600 &
      wait $! || true
    done
    ;;
  codex+tailscale)
    start_codex_app_server
    ;;
  *)
    log "FATAL: unknown START_MODE='$START_MODE'. Expected one of:"
    log "       tailscale-only | codex+tailscale"
    exit 1
    ;;
esac
