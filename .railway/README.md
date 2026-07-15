# Railway Infrastructure as Code (IaC) for Codex Remote

`railway.ts` in this directory provisions the whole "Codex app-server on
Railway" stack from one file and wires it together, instead of clicking
through the dashboard.

## What it provisions

| Resource     | Type                         | Notes                                                                 |
|--------------|------------------------------|-----------------------------------------------------------------------|
| `app`        | Service (Dockerfile builder) | `codex app-server`, built from this repo's root `Dockerfile` via GitHub |
| `codex-data` | Volume                       | Mounted at `/workspace`, `/root/.codex`, and `/var/lib/tailscale`      |

> Tailscale is **not** a separate service. It runs inside the `app` container
> (see the root `Dockerfile` + `entrypoint.sh`) and is gated on `TS_AUTHKEY`
> being set on the `app` service. See "Optional: Tailscale tailnet" below.

### How the volume is used

One `codex-data` volume, three mount points:

| Path                 | What it holds                                                                 |
|----------------------|-------------------------------------------------------------------------------|
| `/workspace`         | Repos, scratch dirs, anything Codex checks out.                               |
| `/root/.codex`       | Codex config + auth + session state (so `codex resume/fork/archive` persist). |
| `/var/lib/tailscale` | Tailscale state (only used when `TS_AUTHKEY` is set).                         |

## Prerequisites

- [Railway CLI](https://docs.railway.com/guides/cli) installed and logged in
  (`railway login`).
- A Railway project linked to this directory (`railway link`, or `railway init`
  to create one).
- Node.js 22+ (the `railway` SDK requires it) and `npm install` run once so
  the SDK is available for the CLI to evaluate `railway.ts`.

## Deploy

```sh
npm install               # installs the `railway` SDK
npm run railway:plan      # railway config plan  — preview the changes
npm run railway:apply     # railway config apply — create/update resources
```

For non-interactive/CI runs:

```sh
railway config apply --yes --confirm-destructive
```

## Remaining manual steps (Railway does not do these for you)

1. **Set `CODEX_WS_TOKEN` on the `app` service.** This is the capability
   token the WebSocket client must present. Generate a strong random value
   locally and paste it into the app service → **Variables** tab:

   ```sh
   openssl rand -base64 48 | tr -d '=+/' | cut -c1-64
   ```

   The entrypoint derives the SHA-256 digest at boot and unsets the plaintext
   from the process env before `exec`ing the app-server. If you would rather
   never store the plaintext on the server, compute the digest locally

   ```sh
   printf %s "$TOKEN" | sha256sum
   ```

   and set `CODEX_WS_TOKEN_SHA256` on the service instead of `CODEX_WS_TOKEN`.

2. **Provide model auth on the `app` service.** The app-server makes the
   model API calls, so the credentials live on this service (not on the
   client). Choose one:

   - **API key:** set `OPENAI_API_KEY` on the app service.
   - **ChatGPT / Codex sign-in:** run `codex login` on any machine, then copy
     the resulting `~/.codex/auth.json` into the Railway volume at
     `/root/.codex/auth.json` (`railway ssh` → `cat > /root/.codex/auth.json`
     on the running container, or use the Tailscale SSH path once the tailnet
     is up).

3. **(Optional) Generate a public domain + set the base URL for clients.**
   If you plan to reach the app-server over the internet rather than over
   the tailnet, generate a Railway domain (app service → **Settings →
   Networking → Generate Domain**) and use it as the client host:

   ```sh
   codex --remote wss://<railway-domain> \
         --remote-auth-token-env CODEX_WS_TOKEN
   ```

   Railway terminates TLS in front of the container, so `wss://` on the
   public domain hits `ws://` on the container port that Codex is bound to.

4. **(Optional) Enable the tailnet.** Add a `TS_AUTHKEY` variable (a
   reusable auth key from
   [Tailscale admin → Settings → Keys](https://login.tailscale.com/admin/settings/keys))
   to the `app` service. On next boot the container joins your tailnet with
   Tailscale SSH enabled and the app-server becomes reachable at
   `wss://<TS_HOSTNAME>.<your-tailnet>.ts.net` (assuming you have HTTPS
   certificates enabled for the tailnet).

## Optional: Tailscale tailnet

`TS_AUTHKEY` and its friends are optional secrets and are intentionally NOT
declared in `railway.ts` so an apply never overwrites them. All of them are
set on the `app` service:

| Variable        | Purpose                                                        |
|-----------------|----------------------------------------------------------------|
| `TS_AUTHKEY`    | Reusable Tailscale auth key. Presence gates the whole feature. |
| `TS_HOSTNAME`   | Tailnet node name (defaults to `codex-remote-railway`).        |
| `TS_EXTRA_ARGS` | Extra flags passed to `tailscale up` (e.g. `--advertise-tags=…`). |
| `TS_STATE_DIR`  | Where tailscaled state is written (defaults to `/var/lib/tailscale`). |
