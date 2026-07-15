# codex-remote-railway

A long-lived remote development container on [Railway](https://railway.com),
accessed privately over [Tailscale](https://tailscale.com). Ships in two
modes selected by the `START_MODE` env var:

- **`tailscale-only`** (default) — boot just Tailscale + Tailscale SSH.
  You SSH in over the tailnet to work interactively (or set Codex up by
  hand). Nothing else is started, so the container stays quiet and cheap.
- **`codex+tailscale`** — boot Tailscale, then run
  [`codex app-server`](https://developers.openai.com/codex/cli/reference)
  with capability-token WebSocket auth so a local `codex --remote wss://…`
  client attaches to it.

Either way, the Tailscale node identity lives on the persistent volume, so
redeploys reuse the same tailnet DNS name and IP — no re-join, no new
machine registration.

When the Codex mode is enabled, the TUI runs on your laptop and **all
execution — model calls, sandboxing, git work, package installs, disk I/O
— runs on the Railway container**:

```
   your laptop                             Railway service
 ┌──────────────┐   wss:// (bearer)   ┌────────────────────────┐
 │  codex --    │◄───────────────────►│  codex app-server      │
 │  remote …    │                     │  + /workspace volume   │
 └──────────────┘                     │  + optional Tailscale  │
                                      └────────────────────────┘
```

## What this repo ships

| Path                         | What it is                                                                             |
|------------------------------|----------------------------------------------------------------------------------------|
| `Dockerfile`                 | Node 22 + Codex CLI + dev toolchain (git, gh, ripgrep, jq, python3) + Tailscale binaries |
| `entrypoint.sh`              | Optional Tailscale bring-up + derive WS auth digest + `exec codex app-server`          |
| `.railway/railway.ts`        | Railway IaC that provisions the app service and the persistent volume                  |
| `.railway/README.md`         | Deep-dive on the IaC + remaining manual steps                                          |
| `.env.example`               | Documented list of every service variable                                              |
| `scripts/generate-token.sh`  | One-shot generator for the WebSocket capability token + SHA-256 digest                 |
| `scripts/connect.sh`         | Local wrapper for `codex --remote wss://…`                                             |
| `docs/`                      | Operator + client walkthroughs                                                         |

## Sources / docs used

- [Codex CLI command reference](https://developers.openai.com/codex/cli/reference) —
  `codex app-server`, `--remote`, `--remote-auth-token-env`, `remote-control`.
- [Railway Infrastructure as Code](https://docs.railway.com/infrastructure-as-code) +
  [reference](https://docs.railway.com/infrastructure-as-code/reference).
- [Railway Dockerfile builder](https://docs.railway.com/builds/dockerfiles),
  [variables](https://docs.railway.com/guides/variables),
  [volumes](https://docs.railway.com/reference/volumes),
  [public networking](https://docs.railway.com/guides/public-networking).
- [Tailscale — Run Tailscale in a container](https://tailscale.com/kb/1282/docker) +
  [Tailscale SSH](https://tailscale.com/kb/1193/tailscale-ssh).

---

## Deploy path A (recommended): Infrastructure as Code

Provision the whole stack from `.railway/railway.ts` with the Railway CLI:

```sh
railway login
railway link           # or: railway init
npm install            # installs the `railway` SDK (Node.js 22+)
npm run railway:plan   # railway config plan  — preview
npm run railway:apply  # railway config apply — create resources
```

That creates the app service and the `codex-data` volume (mounted at
`/workspace`, `/root/.codex`, and `/var/lib/tailscale`). Then complete the
manual secret steps documented in
[`.railway/README.md`](./.railway/README.md#remaining-manual-steps-railway-does-not-do-these-for-you).

## Deploy path B (manual): GitHub → Railway dashboard

1. In Railway: **New Project → Deploy from GitHub repo** → pick
   `chulan991/codex-remote-railway`. Railway detects the root `Dockerfile`.
2. Add a **Volume**: **New → Volume**, mount points `/workspace`,
   `/root/.codex`, and `/var/lib/tailscale` (all backed by the same volume).
3. Set the variables (next section).
4. (Optional) Generate a public domain: **Settings → Networking → Generate
   Domain** — only needed if you want to reach the server over the public
   internet instead of the tailnet.

## Variables to set (app service)

Railway scans `.env.example` in the repo root and offers these keys when you
create the service. See [`.env.example`](./.env.example) for the fully
annotated list. The minimum is:

| Variable                | Required?                                                             | What it does                                                                                     |
|-------------------------|-----------------------------------------------------------------------|--------------------------------------------------------------------------------------------------|
| `START_MODE`            | Defaults to `tailscale-only`                                          | Selects the container mode. Set to `codex+tailscale` to run `codex app-server`.                  |
| `TS_AUTHKEY`            | **Yes**, on FIRST boot only                                           | Reusable Tailscale auth key. Persisted node identity means later redeploys don't need it.        |
| `TS_HOSTNAME`           | Optional                                                              | Tailnet node name (default `codex-remote-railway`).                                              |
| `CODEX_WS_TOKEN`        | Required only when `START_MODE=codex+tailscale` (or use the SHA256)   | Plaintext capability token. The entrypoint derives the SHA-256 digest at boot and drops the plaintext from the process env before `exec`. |
| `CODEX_WS_TOKEN_SHA256` | Alternative to `CODEX_WS_TOKEN`                                       | Pre-computed SHA-256 hex digest. Prefer this if you don't want the plaintext token on the server. |
| `OPENAI_API_KEY`        | Required for model calls in `codex+tailscale` mode (or use `auth.json` on the volume) | Auth for the model API calls made by the app-server.                                             |

Generate a token pair with the helper:

```sh
./scripts/generate-token.sh
```

## Connect from your laptop

Once the service is up, on your local machine:

```sh
export CODEX_WS_TOKEN='the-plaintext-token-you-set-on-the-server'

# Over Tailscale (recommended):
codex --remote wss://codex-remote-railway.<tailnet>.ts.net \
      --remote-auth-token-env CODEX_WS_TOKEN

# ...or over a Railway public domain:
codex --remote wss://<railway-domain> \
      --remote-auth-token-env CODEX_WS_TOKEN
```

`scripts/connect.sh` wraps that:

```sh
export CODEX_REMOTE_HOST='codex-remote-railway.<tailnet>.ts.net'
export CODEX_WS_TOKEN='the-plaintext-token'
./scripts/connect.sh
```

> **Version pinning matters.** The Codex docs warn that `codex app-server` is
> "primarily for development and debugging and may change without notice", so
> the client and server must be on **matching `codex` versions**. Pin
> `CODEX_VERSION` as a build arg on the Railway service, and install the
> same version on your laptop (`npm i -g @openai/codex@<version>`). Bump
> both sides together.

## Persistent storage (important)

Railway container filesystems are **ephemeral** — anything written to disk
is lost on redeploy/restart unless a **Volume** is attached. Railway also
allows exactly **one volume per service, mounted at exactly one path**, so
this repo uses a single `codex-data` volume mounted at `/workspace` and the
entrypoint symlinks the other two directories that need to survive:

- `/workspace` — repos, scratch dirs, whatever you check out.
- `/root/.codex` → `/workspace/.codex-data` — Codex config + auth
  (`auth.json`) + session state, so `codex resume`, `codex fork`,
  `codex archive`, and `codex unarchive` survive redeploys.
- `/var/lib/tailscale` → `/workspace/.tailscale-state` — Tailscale state,
  so the node keeps its identity across redeploys and the entrypoint's
  "skip `tailscale up` if BackendState is already Running" check works.

Migration is dotfile-safe and non-destructive: on first boot the entrypoint
moves any existing dir contents onto the volume with `mv -n` (never
overwrites) and only replaces the source dir with a symlink if it becomes
empty afterwards.

## Tailscale-only mode — SSH into the box

Once the service is deployed with `START_MODE=tailscale-only` (the default):

```sh
# From any machine on your tailnet:
ssh root@codex-remote-railway   # or the exact tailnet DNS name printed at boot
```

Tailscale SSH is enabled via `tailscale up --ssh`, so authentication is
handled by the tailnet, not by a password or SSH key on the container. From
that shell you can `codex login`, clone repos into `/workspace`, and
generally set things up before flipping the container to `codex+tailscale`
mode.

## Security

- The app-server listens on `ws://` inside the container. **TLS is terminated
  in front** — either by Railway's public edge (for `wss://<railway-domain>`)
  or by Tailscale's HTTPS certificates (for `wss://<hostname>.<tailnet>.ts.net`).
  Codex only sends the bearer token over `wss://` or loopback `ws://`, so a
  bare public listener without TLS would refuse to authenticate.
- Prefer **Tailscale-only** exposure for real work: don't generate a Railway
  public domain, leave the tailnet as the only way to reach the port.
- The plaintext `CODEX_WS_TOKEN` is unset from the process environment
  before `exec`ing the app-server (see `entrypoint.sh`), so it doesn't show
  up in `/proc/<pid>/environ` for the running server. You can also set only
  `CODEX_WS_TOKEN_SHA256` and never store the plaintext on the server at all.
- Rotate the token by updating the Railway variable and redeploying, then
  updating your local `CODEX_WS_TOKEN`.

## Model auth on the server

The app-server makes the model API calls, so credentials must live on the
server, not the client. Two supported paths:

1. **API key** — set `OPENAI_API_KEY` on the app service.
2. **ChatGPT / Codex sign-in** — run `codex login` on any machine, then copy
   the resulting `~/.codex/auth.json` into the Railway volume at
   `/root/.codex/auth.json`.

## Troubleshooting

- **Client fails handshake / "auth required".** The client is sending the
  token over `ws://` instead of `wss://`. Codex refuses to send tokens over
  plain `ws://` unless the host is loopback. Use `wss://…` (Railway public
  domain or Tailscale HTTPS).
- **Client "protocol mismatch" / unexpected disconnects.** Client and server
  are on different `codex` versions. Rebuild the Railway image with a pinned
  `CODEX_VERSION` and install the same version locally.
- **Model calls fail once attached.** No `OPENAI_API_KEY` and no
  `/root/.codex/auth.json` on the volume. Fix one of them and redeploy.
- **Tailscale did not come up.** Check `TS_AUTHKEY` is set and is a
  **reusable** auth key. The entrypoint logs the reason to stdout.

## License

[MIT](./LICENSE).
