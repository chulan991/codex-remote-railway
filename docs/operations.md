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
| Sessions vanish after redeploy.                                            | `/root/.codex` is not on the persistent volume.                                                              | Confirm the `codex-data` volume is mounted at `/root/.codex` in the service settings.    |
