// ---------------------------------------------------------------------------
// Codex Remote on Railway — Infrastructure as Code (IaC)
// ---------------------------------------------------------------------------
// Provisions the "Codex app-server on Railway" stack:
//
//   - app         : the codex app-server (built from this repo's Dockerfile)
//   - codex-data  : a persistent volume mounted at /workspace and used for
//                   Codex config/session state (/root/.codex) + Tailscale
//                   state (/var/lib/tailscale). ONE volume, three bind
//                   locations — see the volumeMounts block below.
//
// Secrets (CODEX_WS_TOKEN, OPENAI_API_KEY, TS_AUTHKEY) are NOT declared here.
// They are set manually on the app service in the Railway dashboard so an
// apply never overwrites them.
//
// Tailscale is NOT a separate service. It runs inside the app container (see
// the root Dockerfile + entrypoint.sh) and is gated on TS_AUTHKEY being set
// on the app service.
//
// Deploy with the Railway CLI (see .railway/README.md):
//   npm install
//   npm run railway:plan    # railway config plan  — preview
//   npm run railway:apply   # railway config apply — create/update
// ---------------------------------------------------------------------------

import {
  defineRailway,
  github,
  group,
  project,
  service,
  volume,
} from "railway/iac";

// Source repository for the app service. Railway auto-detects the root
// Dockerfile and uses its Dockerfile builder.
const REPO = "chulan991/codex-remote-railway";
const BRANCH = "main";

// Volume region. This SHOULD match the region the app service deploys in;
// adjust to your project's region if different.
const REGION = "us-west2";

export default defineRailway((_ctx) => {
  // --- Persistent volume --------------------------------------------------
  // One volume, three mount points:
  //   /workspace        — repos, scratch dirs, anything Codex checks out
  //   /root/.codex      — Codex config, auth, session/resume state
  //   /var/lib/tailscale — Tailscale state (only used when TS_AUTHKEY is set)
  //
  // Persisting /root/.codex is what lets `codex resume`, `codex fork`,
  // `codex archive`, and Tailscale idempotency survive redeploys.
  const codexData = volume("codex-data", { region: REGION, sizeMB: 5120 });

  // --- codex app-server ---------------------------------------------------
  const app = service("app", {
    source: github(REPO, { branch: BRANCH }),
    replicas: 1,
    volumeMounts: {
      "/workspace": codexData,
      "/root/.codex": codexData,
      "/var/lib/tailscale": codexData,
    },
    env: {
      // The entrypoint binds `codex app-server` to ws://0.0.0.0:${PORT}.
      // Railway provides PORT automatically; no need to set it here.
      CODEX_LISTEN_HOST: "0.0.0.0",

      // Sensible Codex defaults. The actual auth token, model auth, and
      // Tailscale auth key are set manually on the app service — see the
      // "Remaining manual steps" section of .railway/README.md.
      CODEX_HOME: "/root/.codex",
      CODEX_LOG_LEVEL: "info",

      // --- SECRETS: set manually on the app service (NOT declared here) ---
      // CODEX_WS_TOKEN      = strong random token (paired with the client's
      //                       CODEX_WS_TOKEN env var; entrypoint derives the
      //                       SHA-256 digest at boot)
      // OPENAI_API_KEY      = OpenAI API key for model calls
      //                       (or copy an auth.json into /root/.codex instead)
      // TS_AUTHKEY          = optional reusable Tailscale auth key (enables
      //                       tailnet + Tailscale SSH inside the container)
      // TS_HOSTNAME         = optional; tailnet node name
    },
  });

  return project("codex-remote", {
    resources: [group("Codex Remote", [app]), codexData],
  });
});
