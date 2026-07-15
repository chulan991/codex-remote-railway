# syntax=docker/dockerfile:1.7
# Tailscale-only remote development environment for Railway.
# Codex is intentionally not installed yet. It can be layered onto this image
# later without changing the service, volume, or Tailscale state path.

FROM tailscale/tailscale:stable AS tailscale

FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    WORKSPACE_DIR=/workspace \
    TS_STATE_DIR=/workspace/.tailscale-state \
    TS_AUTH_ONCE=true \
    TS_USERSPACE=true \
    TS_ENABLE_HEALTH_CHECK=true \
    TS_LOCAL_ADDR_PORT=0.0.0.0:9002 \
    TS_EXTRA_ARGS=--ssh

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        bash ca-certificates curl gnupg tini \
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

COPY --from=tailscale /usr/local/bin/tailscale /usr/local/bin/tailscale
COPY --from=tailscale /usr/local/bin/tailscaled /usr/local/bin/tailscaled
COPY --from=tailscale /usr/local/bin/containerboot /usr/local/bin/containerboot

RUN mkdir -p /workspace/.tailscale-state
WORKDIR /workspace

COPY entrypoint.sh /entrypoint.sh
RUN chmod 0755 /entrypoint.sh

# Tailscale's unauthenticated health endpoint. Do not attach a public Railway
# domain to this service; operational access is through the tailnet.
EXPOSE 9002
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
    CMD curl -fsS http://127.0.0.1:9002/healthz || exit 1

ENTRYPOINT ["/usr/bin/tini", "--", "/entrypoint.sh"]
