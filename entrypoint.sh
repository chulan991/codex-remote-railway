#!/usr/bin/env bash
# Tailscale-only Railway remote environment bootstrap.
#
# The Railway volume remains mounted at /workspace and the Tailscale state
# stays at /workspace/.tailscale-state. Keeping both paths stable allows an
# existing node identity to survive image rebuilds and service redeploys.

set -euo pipefail

log() { printf '[remote-env] %s\n' "$*"; }
fatal() {
  log "ERROR: $*"
  exit 1
}

workspace="${WORKSPACE_DIR:-${RAILWAY_VOLUME_MOUNT_PATH:-/workspace}}"
state_dir="${TS_STATE_DIR:-$workspace/.tailscale-state}"
state_file="$state_dir/tailscaled.state"

# Support the legacy variable used by the previous entrypoint.
if [ -z "${TS_AUTHKEY:-}" ] && [ -n "${TAILSCALE_AUTHKEY:-}" ]; then
  export TS_AUTHKEY="$TAILSCALE_AUTHKEY"
fi

# Tailscale containerboot defaults. Service variables can override these.
export TS_STATE_DIR="$state_dir"
export TS_AUTH_ONCE="${TS_AUTH_ONCE:-true}"
export TS_USERSPACE="${TS_USERSPACE:-true}"
export TS_ENABLE_HEALTH_CHECK="${TS_ENABLE_HEALTH_CHECK:-true}"
export TS_LOCAL_ADDR_PORT="${TS_LOCAL_ADDR_PORT:-0.0.0.0:${PORT:-9002}}"

# This service exists to provide private shell access, so always enable
# Tailscale SSH while preserving any caller-supplied flags such as tags.
case " ${TS_EXTRA_ARGS:-} " in
  *" --ssh "*) ;;
  *) export TS_EXTRA_ARGS="--ssh${TS_EXTRA_ARGS:+ $TS_EXTRA_ARGS}" ;;
esac

[ -d "$workspace" ] || fatal "$workspace is missing. Keep the existing Railway volume mounted at /workspace."
mkdir -p "$state_dir"
[ -w "$state_dir" ] || fatal "$state_dir is not writable. Check the Railway volume attachment."

if [ -s "$state_file" ]; then
  log "Reusing persisted Tailscale identity from $state_file."
  log "TS_AUTH_ONCE=true prevents a new login during a normal redeploy."
elif [ -n "${TS_AUTHKEY:-}" ]; then
  log "No persisted Tailscale state found. Running the initial tailnet setup."
else
  fatal "No persisted Tailscale state and no TS_AUTHKEY are available. Set TS_AUTHKEY for the initial setup or recovery."
fi

log "Starting Tailscale containerboot with state in $TS_STATE_DIR."
exec /usr/local/bin/containerboot
