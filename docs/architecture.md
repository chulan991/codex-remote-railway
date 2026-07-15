# Architecture

## The moving parts

```
   your laptop                                        Railway service
 ┌────────────────┐                              ┌────────────────────────────┐
 │  codex --      │                              │  entrypoint.sh             │
 │  remote wss:// │                              │   ├─ tailscaled (opt)      │
 │  --remote-     │◄────wss:// (bearer)─────────►│   └─ codex app-server      │
 │  auth-token-   │       token: CODEX_WS_TOKEN  │        --listen ws://…     │
 │  env CODEX_WS_ │                              │        --ws-auth           │
 │  TOKEN         │                              │          capability-token  │
 └────────────────┘                              │        --ws-token-sha256 … │
                                                 │                            │
                                                 │  Volume: codex-data        │
                                                 │   ├─ /workspace            │
                                                 │   ├─ /root/.codex          │
                                                 │   └─ /var/lib/tailscale    │
                                                 └────────────────────────────┘
```

## Why `codex app-server` + `codex --remote`

Codex CLI ships a first-class client/server split:

- **Server:** `codex app-server --listen ws://IP:PORT` holds the working
  directory, runs commands in its own sandbox, makes the model calls, and
  manages session state (`resume`, `fork`, `archive`, `unarchive`).
- **Client:** `codex --remote wss://host:port
  --remote-auth-token-env CODEX_WS_TOKEN` runs only the TUI.

The remote client mode is officially supported for `codex`, `codex resume`,
`codex fork`, `codex archive`, `codex delete`, and `codex unarchive`. Other
subcommands reject remote mode. See the
[Codex CLI reference](https://developers.openai.com/codex/cli/reference).

## Auth model

Two options, both natively supported by `codex app-server`:

| Mode                    | Server config                                                                  | Client config                                                             |
|-------------------------|--------------------------------------------------------------------------------|---------------------------------------------------------------------------|
| `capability-token`      | `--ws-auth capability-token --ws-token-sha256 <hex>` (via `CODEX_WS_TOKEN[_SHA256]`) | `--remote-auth-token-env CODEX_WS_TOKEN` where `CODEX_WS_TOKEN` = plaintext |
| `signed-bearer-token`   | `--ws-auth signed-bearer-token --ws-shared-secret-file …` (+ audience/issuer)  | Same `--remote-auth-token-env`, but the value is a signed JWT              |

This repo ships **`capability-token`** by default — simple, symmetric, and
enough for a single-operator setup. A signed-bearer-token variant is a
straightforward extension (`--ws-shared-secret-file /run/secrets/ws-hmac`,
`--ws-audience`, `--ws-issuer`).

Codex only sends the bearer token over `wss://` URLs or loopback `ws://`
URLs, so TLS in front of the container is mandatory for anything reachable
off-box. Railway's public edge provides TLS on `https://…up.railway.app`
domains, and Tailscale provides HTTPS certificates for tailnet MagicDNS
names.

## Why Tailscale is optional

The default Railway path (public domain + TLS-terminated `wss://`) works
fine. Tailscale is bolted on for the common preference of "don't expose it
to the public internet at all":

- No public Railway domain generated.
- App-server is only reachable at `wss://<hostname>.<tailnet>.ts.net`.
- Tailscale SSH is enabled so you can also open a shell into the container
  from any tailnet node.

Tailscale runs in **userspace networking** mode (`--tun=userspace-networking`)
because Railway containers don't have kernel TUN or `NET_ADMIN`. State
persists on the `codex-data` volume at `/var/lib/tailscale`, which is what
makes the entrypoint's "skip `tailscale up` if already connected" check
idempotent across redeploys.

## Persistence

One volume, three mount points:

| Path                 | Why                                                                                                            |
|----------------------|----------------------------------------------------------------------------------------------------------------|
| `/workspace`         | Repos, scratch dirs, anything Codex checks out. Where you actually work.                                       |
| `/root/.codex`       | Codex config + `auth.json` + session state. Persisting this is what makes `codex resume`, `fork`, and `archive` work across redeploys. |
| `/var/lib/tailscale` | Tailscale state so the tailnet node keeps its identity across redeploys.                                       |

## Version pinning

`codex app-server` is documented as "primarily for development and debugging
and may change without notice". Practical consequence: **the wire protocol
between client and server is not a stability contract yet**. Pin
`CODEX_VERSION` as a Docker build arg on the Railway image, install the same
version on the client, and bump both together.
