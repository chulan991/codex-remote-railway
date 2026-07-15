// ---------------------------------------------------------------------------
// Codex Remote on Railway — Infrastructure as Code (IaC)
// ---------------------------------------------------------------------------
// Provisions the "Codex app-server on Railway" stack:
//
//   - app         : the codex app-server (built from this repo's Dockerfile)
//   - codex-data  : a SINGLE persistent volume mounted at /workspace.
//                   Railway allows one volume per service, mounted at one
//                   path. The entrypoint symlinks the other two dirs that
//                   need to survive redeploys INTO subdirs of /workspace:
//                     /root/.codex        -> /workspace/.codex-data
//                     /var/lib/tailscale  -> /workspace/.tailscale-state
//                   This gives three logical persistence locations backed
//                   by one disk. All three survive redeploys.
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
  // ONE volume, ONE mount point at /workspace. Railway's contract is one
  // volume per service. The entrypoint symlinks /root/.codex and
  // /var/lib/tailscale into subdirs of /workspace on boot (idempotent,
  // non-destructive — migrates existing dir contents into the volume the
  // first time it runs, then only relinks on subsequent boots).
  //
  // Detaching a mounted volume or changing placement is treated as
  // destructive by `railway config apply`, so as long as this mount stays
  // declared the volume is preserved across redeploys and re-applies. This
  // is what lets `codex resume`, `codex fork`, `codex archive`, and the
  // Tailscale node identity survive a redeploy.
  const codexData = volume("codex-data", { region: REGION, sizeMB: 5120 });

  // --- codex app-server ---------------------------------------------------
  const app = service("app", {
    source: github(REPO, { branch: BRANCH }),
    replicas: 1,
    volumeMounts: {
      "/workspace": codexData,
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

      // Where the entrypoint expects the volume to be mounted. Overridable
      // for advanced setups, but the default is what the shipped
      // entrypoint symlinks into.
      WORKSPACE_DIR: "/workspace",

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
