# Operations

## First-time deploy

1. `railway login && railway link` (or `railway init`) inside this repo.
2. `npm install && npm run railway:apply`.
3. Set secrets on the `app` service:
   - `CODEX_WS_TOKEN` (or `CODEX_WS_TOKEN_SHA256`) — see
     [`scripts/generate-token.sh`](../scripts/generate-token.sh).
   - `OPENAI_API_KEY` (or copy `auth.json` onto the volume).
   - Optional: `TS_AUTHKEY`, `TS_HOSTNAME`, `TS_EXTRA_ARGS`.
4. (Optional) Generate a Railway public domain if you don't want to rely on
   Tailscale.
5. On your laptop: `export CODEX_WS_TOKEN=…` and
   `codex --remote wss://<host> --remote-auth-token-env CODEX_WS_TOKEN`.

## Rotate the WS capability token

1. Run `./scripts/generate-token.sh` locally, copy the new value.
2. Update `CODEX_WS_TOKEN` (or `CODEX_WS_TOKEN_SHA256`) on the Railway app
   service.
3. Redeploy the app service.
4. Update `CODEX_WS_TOKEN` on every laptop that connects.

## Upgrade Codex on the server

1. Pick a target version from
   [`@openai/codex` releases](https://www.npmjs.com/package/@openai/codex?activeTab=versions).
2. Bump `CODEX_VERSION` on the Railway `app` service (or, better, pass it as
   a `--build-arg` in your Dockerfile builder). Redeploy.
3. `npm i -g @openai/codex@<same-version>` on every client.

## Recover Codex sessions after a redeploy

Sessions live under `/root/.codex` on the `codex-data` volume. Because that
path is mounted from the persistent volume, `codex resume`, `codex fork`,
`codex archive`, and `codex unarchive` continue to work across redeploys.
If they don't, the mount is missing — check the volume is attached at
`/root/.codex` in the Railway service settings.

## Take Tailscale offline (temporarily)

Unset `TS_AUTHKEY` on the app service and redeploy. The entrypoint logs
"skipping Tailscale" and the app-server keeps running; the tailnet node
disappears until you re-set the key.

## Recover from a de-authorized tailnet node

Symptoms: entrypoint logs `Persisted Tailscale identity found` followed by
`Switching ipn state NoState -> NeedsLogin` and an interactive
`login.tailscale.com/a/...` URL. This happens when the node was removed or
de-authorized in the Tailscale admin console but the persisted identity is
still on the `/workspace` volume, so the daemon keeps replaying the
rejected credentials.

Two levers, pick one:

1. **Re-attach the existing identity (preferred).** Rotate `TS_AUTHKEY` in
   the Tailscale admin and set the new value on the Railway service. On
   next boot the entrypoint sees `BackendState=NeedsLogin` and re-attaches
   with `--authkey ... --force-reauth` automatically. No local state
   change, no new node in the admin console.
2. **Wipe local state and register a fresh node.** Set `TS_WIPE_STATE=1`
   on the service (together with a valid `TS_AUTHKEY`) and redeploy. The
   entrypoint deletes `/var/lib/tailscale/*` before starting tailscaled,
   so the daemon registers a new node under the same `TS_HOSTNAME`.
   **Unset `TS_WIPE_STATE` immediately after the successful boot** —
   leaving it on rotates the identity on every redeploy and pollutes the
   admin console with duplicate machines.

## Reach the container's shell

- **Tailscale enabled:** `ssh root@codex-remote-railway.<tailnet>.ts.net`
  (Tailscale SSH — no separate SSH key setup needed once the tailnet is up).
- **Otherwise:** `railway ssh` from your laptop with the project linked.

## Common failure modes

| Symptom                                                                    | Likely cause                                                                                                | Fix                                                                                     |
|----------------------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------|-----------------------------------------------------------------------------------------|
| Entrypoint exits with `FATAL: no CODEX_WS_TOKEN or CODEX_WS_TOKEN_SHA256`. | Neither variable set.                                                                                        | Set `CODEX_WS_TOKEN` on the app service and redeploy.                                    |
| Client handshake fails with "auth required".                               | Client connected over `ws://` (non-loopback), so Codex refused to send the token.                            | Use `wss://…` (Railway public domain or Tailscale HTTPS).                                |
| Client connects, then immediately disconnects with a protocol error.       | Client and server on different `codex` versions.                                                             | Pin `CODEX_VERSION` on both sides.                                                       |
| Model calls fail with 401/403 after attaching.                             | No `OPENAI_API_KEY` on the app service and no `auth.json` on the volume.                                     | Set one of them.                                                                         |
| Tailscale never comes up.                                                  | `TS_AUTHKEY` is single-use and was already consumed on a previous boot.                                       | Generate a **reusable** auth key and update `TS_AUTHKEY`.                                |
| Boot logs show `BackendState=NeedsLogin` and an interactive auth URL.       | Persisted node identity was de-authorized upstream; daemon keeps replaying rejected creds.                     | See [Recover from a de-authorized tailnet node](#recover-from-a-de-authorized-tailnet-node). |
| Sessions vanish after redeploy.                                            | `/root/.codex` is not on the persistent volume.                                                              | Confirm the `codex-data` volume is mounted at `/root/.codex` in the service settings.    |
