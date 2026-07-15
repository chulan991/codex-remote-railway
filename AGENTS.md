# AGENTS.md — codex-remote-railway

> Standardized AI-agent context for this repo. Read this first.
>
> This file follows the [agents.md](https://agents.md/) open standard and is
> read natively by Codex, Cursor, Aider, Jules, Factory, Zed, Warp, VS Code,
> Devin, GitHub Copilot, and others. Claude Code reads it as a fallback when
> no `CLAUDE.md` is present. `CLAUDE.md` is intentionally gitignored — keep
> personal overrides local.

---

## Project

**codex-remote-railway** deploys [`codex app-server`](https://developers.openai.com/codex/cli/reference)
on [Railway](https://railway.com) so a local `codex --remote wss://…` client
can offload all execution to the remote container. Optional Tailscale
integration lets you reach the app-server privately over a tailnet.

Read next:
- [`README.md`](./README.md) — human-facing overview and quick start
- [`.railway/README.md`](./.railway/README.md) — Railway IaC deep-dive
- [`.env.example`](./.env.example) — every service variable, annotated
- [`docs/architecture.md`](./docs/architecture.md) — how the pieces fit
- [`docs/operations.md`](./docs/operations.md) — deploy / rotate / upgrade

---

## Local overrides

If [`AGENTS.local.md`](./AGENTS.local.md) exists in the working tree,
**prioritize its instructions** for the current developer's session. That
file is gitignored and holds per-developer preferences. Never commit it.

---

## Branch flow

```
                          ┌─── feature/fix/chore ───┐
                          │                         ▼
        ┌──── main ◄── auto-PR ──── staging ◄──────┘
        │                  ▲
        └── hotfix ────────┘
```

- **`main`** — production. Protected: 1 approval required, linear history,
  conversation resolution required.
- **`staging`** — pre-prod integration. Most feature/fix/chore PRs target
  this branch.
- **Feature, fix, chore branches** → PR to `staging`.
- **Hotfixes** → PR directly to `main`.
- **Never push directly to `main` or `staging`.** All changes via PR.

## Branch naming

Format: `<initials>/<type>/<short-info>[-<issue-number>]`

| Type         | Purpose                                              | Default base |
|--------------|------------------------------------------------------|--------------|
| `feature`    | New functionality, enhancements                       | `staging`    |
| `fix`        | Bug fix that follows the normal staging→main cycle    | `staging`    |
| `hotfix`     | Urgent fix that must reach production immediately     | `main`       |
| `chore`      | Tooling, deps, CI, docs, internal non-behavior work   | `staging`    |
| `experiment` | Spike / proof-of-concept (not intended to merge)      | `staging`    |
| `revert`     | Reverts of a prior merge                              | matches origin |

**Initials.** Humans: 2–3 lowercase letters (e.g. `cm`). AI agents: named
prefix (`copilot/`, `codex/`, `claude/`, `pplx/`).

**Info part.** Lowercase, kebab-case, ≤ 50 chars.

Examples: `cm/feature/ws-signed-bearer-token`, `cm/chore/bump-codex-0.42`,
`copilot/fix/entrypoint-tailscale-retry`.

## Commit & PR title format

[Conventional Commits](https://www.conventionalcommits.org/):

```
<type>(<optional-scope>): <subject>
```

- Types: `feat`, `fix`, `hotfix`, `chore`, `refactor`, `docs`, `ci`, `test`, `perf`
- Subject: ≤ 72 chars, imperative mood, no trailing period
- Squash-merge, so the **PR title becomes the merge commit**.

---

## Repo layout

```
.
├── Dockerfile                # codex app-server image (Node 22 + Codex + toolchain + TS binaries)
├── entrypoint.sh             # optional TS bring-up + WS auth digest + exec app-server
├── package.json              # Railway IaC SDK (dev only)
├── .env.example              # annotated variable reference
├── .railway/
│   ├── railway.ts            # Railway IaC (app + codex-data volume)
│   └── README.md             # IaC deep-dive + remaining manual steps
├── scripts/
│   ├── generate-token.sh     # WS capability token + SHA-256 digest generator
│   └── connect.sh            # local `codex --remote` wrapper
├── docs/
│   ├── architecture.md
│   └── operations.md
└── .github/
    ├── pull_request_template.md
    ├── ISSUE_TEMPLATE/
    │   ├── bug_report.md
    │   ├── feature_request.md
    │   └── hotfix.md
    └── workflows/
        └── lint.yml
```

---

## Things AI agents must not do

- **Do not** commit real tokens, `OPENAI_API_KEY`, `TS_AUTHKEY`, or any
  `auth.json`. `.env` is gitignored — keep it that way.
- **Do not** bind `codex app-server` to a public listener without capability
  token or signed bearer token auth. The entrypoint refuses to start without
  `CODEX_WS_TOKEN` (or `CODEX_WS_TOKEN_SHA256`) for exactly this reason.
- **Do not** embed the plaintext token in the Dockerfile or `railway.ts`.
  Secrets are set on the Railway app service manually.
- **Do not** bump `CODEX_VERSION` on the server without a matching client
  bump documented in the PR. Client/server protocol drift is the number-one
  source of "it broke overnight" reports.
- **Do not** replace the capability-token flow with unauthenticated
  `ws://` on a public domain "for testing".
