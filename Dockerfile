# syntax=docker/dockerfile:1.7
# ---------------------------------------------------------------------------
# Codex Remote on Railway
# ---------------------------------------------------------------------------
# Runs `codex app-server` as a long-lived Railway service so a local machine
# can attach to it with `codex --remote wss://…`. All model calls, sandboxing,
# git/gh work, package installs, and disk I/O happen on the Railway container;
# only the TUI runs locally.
#
# OPTIONAL Tailscale is baked in and driven at runtime by entrypoint.sh: with
# no auth key set the entrypoint skips Tailscale and exposes the app-server on
# the container port instead. With TS_AUTHKEY set, the node joins the tailnet
# (Tailscale SSH enabled) and the app-server is reachable over the tailnet.
#
# Auth: capability-token WebSocket auth. entrypoint.sh derives the required
# SHA-256 digest from CODEX_WS_TOKEN (or reads it from CODEX_WS_TOKEN_SHA256)
# and passes it to `codex app-server` via --ws-token-sha256. The client sets
# --remote-auth-token-env CODEX_WS_TOKEN with the plaintext token.
#
# Base: Debian slim. Node 22 (Codex CLI's supported runtime) + a working dev
# toolchain (git, gh, ripgrep, jq, curl, build-essential, python3) so the
# remote environment is actually useful once you attach.
# ---------------------------------------------------------------------------

# Tailscale binaries (baked in; only started when TS_AUTHKEY is present).
FROM tailscale/tailscale:stable AS tailscale

FROM node:22-bookworm-slim AS base

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    NODE_ENV=production \
    NPM_CONFIG_UPDATE_NOTIFIER=false \
    NPM_CONFIG_FUND=false

# System tooling the remote environment needs to be useful:
#   - git, gh          : source control + GitHub CLI (Codex leans on both)
#   - openssh-client   : git+ssh, remote gh, occasional ssh work
#   - ripgrep, fd-find : fast search (Codex/agents rely on these)
#   - jq               : shell JSON glue
#   - curl, ca-certs   : HTTPS out to model APIs, npm, GitHub
#   - build-essential  : native npm builds
#   - python3, pip     : common tooling
#   - tini             : PID 1, forwards signals cleanly
#   - iproute2, iptables, iputils-ping : Tailscale userspace helpers + diag
# Then install the GitHub CLI from the official apt repo.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg tini \
        git openssh-client \
        ripgrep fd-find jq \
        build-essential python3 python3-pip \
        iproute2 iptables iputils-ping \
        procps less nano; \
    install -m 0755 -d /etc/apt/keyrings; \
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | gpg --dearmor -o /etc/apt/keyrings/githubcli-archive-keyring.gpg; \
    chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg; \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends gh; \
    ln -s "$(command -v fdfind)" /usr/local/bin/fd; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*

# Tailscale binaries (kept in /usr/local/bin so the entrypoint can find them).
COPY --from=tailscale /usr/local/bin/tailscaled /usr/local/bin/tailscaled
COPY --from=tailscale /usr/local/bin/tailscale  /usr/local/bin/tailscale

# ---------------------------------------------------------------------------
# Codex CLI
# ---------------------------------------------------------------------------
# Installed globally so `codex` is on PATH for both the app-server (started
# by the entrypoint) and any interactive session the operator opens via
# Tailscale SSH.
#
# CODEX_VERSION is pinned via build arg so both sides of the client/server
# handshake can be aligned. The OpenAI docs warn that `codex app-server` is
# "primarily for development and debugging and may change without notice",
# so client and server MUST be on matching versions.
ARG CODEX_VERSION=latest
RUN npm install -g @openai/codex@${CODEX_VERSION} \
 && codex --version

# ---------------------------------------------------------------------------
# Runtime layout
# ---------------------------------------------------------------------------
# /workspace       — mounted from the Railway volume (repos, scratch dirs)
# /root/.codex     — mounted from the Railway volume (session state, auth,
#                    config). Persisting this means resume/fork/archive keep
#                    working across redeploys.
# /var/lib/tailscale — Tailscale state (also on the volume when TS is enabled)
#
# Exposed port matches the Railway PORT convention; the entrypoint binds the
# app-server to 0.0.0.0:${PORT:-8080}.
RUN mkdir -p /workspace /root/.codex /var/lib/tailscale
WORKDIR /workspace

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 8080

# tini as PID 1 → clean signal handling for tailscaled + codex app-server.
ENTRYPOINT ["/usr/bin/tini", "--", "/entrypoint.sh"]
