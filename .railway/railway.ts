// ---------------------------------------------------------------------------
// codex-remote-railway — Infrastructure as Code (IaC)
// ---------------------------------------------------------------------------
// Provisions the remote-env stack:
//
//   - app         : the container (Dockerfile at repo root). Runs in one
//                   of two modes selected by START_MODE:
//                     tailscale-only (default) — just tailscaled + SSH,
//                       so you can bring the box up first and set up
//                       Codex over the tailnet later.
//                     codex+tailscale — tailscaled + `codex app-server`.
//   - codex-data  : SINGLE persistent volume mounted at /workspace.
//                   Railway allows one volume per service, mounted at one
//                   path. The entrypoint symlinks the two dirs that must
//                   survive redeploys INTO subdirs of /workspace:
//                     /root/.codex        -> /workspace/.codex-data
//                     /var/lib/tailscale  -> /workspace/.tailscale-state
//                   This is what preserves the Tailscale node identity
//                   (so redeploys reuse the tailnet host, no re-join,
//                   no new machine key) and Codex session state.
//
// Secrets (TS_AUTHKEY, CODEX_WS_TOKEN, OPENAI_API_KEY) are NOT declared
// here. Set them manually on the app service in the Railway dashboard so
// an apply never overwrites them.
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
      // Start mode. Default keeps the container as a Tailscale-only
      // remote environment (no Codex app-server) so you can SSH in over
      // the tailnet and set up Codex interactively before flipping to
      // codex+tailscale mode.
      START_MODE: "tailscale-only",

      // Where the volume is mounted. The entrypoint symlinks /root/.codex
      // and /var/lib/tailscale into subdirs of this path.
      WORKSPACE_DIR: "/workspace",

      // --- Codex settings (used only when START_MODE=codex+tailscale) ---
      // The entrypoint binds `codex app-server` to ws://0.0.0.0:${PORT}.
      // Railway provides PORT automatically; no need to set it here.
      CODEX_LISTEN_HOST: "0.0.0.0",
      CODEX_HOME: "/root/.codex",
      CODEX_LOG_LEVEL: "info",

      // --- SECRETS: set manually on the app service (NOT declared here) ---
      // TS_AUTHKEY          = REQUIRED on FIRST boot only. Reusable
      //                       Tailscale auth key used to join the tailnet.
      //                       After first join, the node identity lives
      //                       on the persistent volume and TS_AUTHKEY can
      //                       be revoked. Redeploys reuse the persisted
      //                       identity and do NOT re-`tailscale up`.
      // TS_HOSTNAME         = optional; tailnet node name (default:
      //                       codex-remote-railway)
      // CODEX_WS_TOKEN      = strong random token, required only when
      //                       START_MODE=codex+tailscale
      // OPENAI_API_KEY      = OpenAI API key for model calls (only used
      //                       in codex+tailscale mode; can also be a
      //                       pre-authenticated auth.json on the volume)
    },
  });

  return project("codex-remote", {
    resources: [group("Codex Remote", [app]), codexData],
  });
});
