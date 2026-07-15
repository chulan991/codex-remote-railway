<!--
Repo standards: read AGENTS.md before opening this PR.
Title format: Conventional Commits — e.g. `feat(entrypoint): support signed-bearer-token WS auth`.
-->

## Summary

<!-- One or two sentences on what this changes and why. -->

## Linked issue

<!-- Use GitHub-native syntax so merging closes the issue automatically. -->
Closes #

## Type of change

- [ ] `feat` — new functionality
- [ ] `fix` — bug fix (staging → main)
- [ ] `hotfix` — urgent fix targeting `main`
- [ ] `chore` — tooling, deps, CI, docs, internal
- [ ] `refactor` — no behavior change
- [ ] `docs` — docs only

## Areas touched

- [ ] `Dockerfile` / base image / Codex version
- [ ] `entrypoint.sh` (Tailscale bring-up, WS auth, exec)
- [ ] `.railway/railway.ts` (Railway IaC)
- [ ] `scripts/*`
- [ ] Docs (`README.md`, `docs/*`, `.env.example`, `AGENTS.md`)
- [ ] CI (`.github/workflows/*`)

## How I tested this

<!--
Ideally cover both sides:
  1. Server: `docker build .` locally, `docker run` with a test token + no
     TS_AUTHKEY, confirm entrypoint refuses to start without CODEX_WS_TOKEN
     and starts cleanly with one.
  2. Client: `codex --remote wss://…` from another machine, confirm
     handshake, run a basic command.
-->

## Codex version alignment

- Server `CODEX_VERSION` (build arg): `…`
- Client `codex --version`: `…`
- [ ] Both sides are on the same version, or version bump is intentional and
      documented in this PR.

## Secrets checklist

- [ ] No real tokens, API keys, or auth.json committed.
- [ ] Any new secret is documented in `.env.example` and `.railway/README.md`.
- [ ] `.gitignore` still covers `.env`, `auth.json`, and personal overrides.

## Follow-ups

<!-- Anything intentionally left out of this PR that we should track. -->
