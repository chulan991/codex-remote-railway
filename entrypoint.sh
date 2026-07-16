#!/usr/bin/env bash
# Tailscale-only Railway remote environment.
#
# The existing Railway volume stays mounted at /workspace. Tailscale state is
# stored at /workspace/.tailscale-state so the node identity survives normal
# restarts, image rebuilds, and redeploys.

set -euo pipefail

log() { printf '[remote-env] %s\n' "$*"; }
fatal() {
  log "ERROR: $*"
  exit 1
}

workspace="${WORKSPACE_DIR:-${RAILWAY_VOLUME_MOUNT_PATH:-/workspace}}"
state_dir="${TS_STATE_DIR:-$workspace/.tailscale-state}"
state_file="$state_dir/tailscaled.state"
socket="${TS_SOCKET:-/tmp/tailscaled.sock}"
hostname="${TS_HOSTNAME:-codex-remote-railway}"
authkey="${TS_AUTHKEY:-${TAILSCALE_AUTHKEY:-}}"
tailscaled_pid=""

backend_state() {
  tailscale --socket="$socket" status --json 2>/dev/null \
    | grep -o '"BackendState"[[:space:]]*:[[:space:]]*"[^"]*"' \
    | head -1 \
    | sed -E 's/.*"BackendState"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/' \
    || printf 'NoDaemon'
}

wait_for_daemon() {
  local attempt state
  attempt=0
  while [ "$attempt" -lt 30 ]; do
    state="$(backend_state)"
    case "$state" in
      Running|Stopped|Starting|NeedsLogin|NoState) return 0 ;;
    esac
    attempt=$((attempt + 1))
    sleep 1
  done
  return 1
}

run_tailscale_up() {
  local include_auth="$1"
  local args=(--ssh --hostname="$hostname")

  if [ "$include_auth" = "true" ]; then
    [ -n "$authkey" ] || return 1
    args+=(--authkey="$authkey")
  fi

  # shellcheck disable=SC2086 # TS_EXTRA_ARGS is intentionally word-split.
  tailscale --socket="$socket" up "${args[@]}" ${TS_EXTRA_ARGS:-}
}

shutdown() {
  log "Stopping tailscaled cleanly."
  if [ -n "$tailscaled_pid" ] && kill -0 "$tailscaled_pid" 2>/dev/null; then
    kill -TERM "$tailscaled_pid" 2>/dev/null || true
    wait "$tailscaled_pid" 2>/dev/null || true
  fi
  exit 0
}
trap shutdown SIGTERM SIGINT

[ -d "$workspace" ] || fatal "$workspace is missing. Keep the existing Railway volume mounted at /workspace."
mkdir -p "$state_dir"
[ -w "$state_dir" ] || fatal "$state_dir is not writable. Check the Railway volume attachment."

log "Starting tailscaled with persistent state at $state_dir."
tailscaled \
  --state="$state_file" \
  --socket="$socket" \
  --tun=userspace-networking &
tailscaled_pid=$!

wait_for_daemon || fatal "tailscaled did not become ready within 30 seconds."
state="$(backend_state)"
log "tailscaled BackendState=$state"

if [ "$state" = "Running" ]; then
  log "Reusing the existing Tailscale node identity. No setup was rerun."
elif [ -s "$state_file" ]; then
  log "Persisted Tailscale state exists but the node is not connected. Retrying without replacing its identity."
  if ! run_tailscale_up false; then
    if [ -n "$authkey" ]; then
      log "Reconnect failed. Retrying recovery with TS_AUTHKEY."
      run_tailscale_up true || fatal "Tailscale recovery failed with the supplied auth key."
    else
      fatal "Tailscale reconnect failed. Set TS_AUTHKEY temporarily for recovery."
    fi
  fi
else
  [ -n "$authkey" ] || fatal "No Tailscale state exists. Set TS_AUTHKEY for the initial setup."
  log "No persisted identity found. Running the initial Tailscale setup."
  run_tailscale_up true || fatal "Initial Tailscale setup failed."
fi

state="$(backend_state)"
[ "$state" = "Running" ] || fatal "Tailscale did not reach Running state after setup. Current state: $state"

log "Tailscale is connected as $hostname with SSH enabled."
log "The container is now a Tailscale-only remote environment. Codex can be installed later over SSH."

wait "$tailscaled_pid"
