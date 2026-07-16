// Tailscale-only remote environment on Railway.
//
// Compatibility rule: keep the existing project, service, volume resource,
// mount path, and state directory names stable. This makes an apply update the
// current deployment instead of replacing the storage that holds the existing
// Tailscale node identity.

import {
  defineRailway,
  github,
  group,
  project,
  service,
  volume,
} from "railway/iac";

const REPO = "chulan991/codex-remote-railway";
const BRANCH = "main";
const REGION = "us-west2";

export default defineRailway((_ctx) => {
  // Retain the existing resource name and mount path. Tailscale state remains
  // at /workspace/.tailscale-state on this volume across every redeploy.
  const codexData = volume("codex-data", { region: REGION, sizeMB: 5120 });

  // Retain the existing service name so Railway updates it in place.
  const app = service("app", {
    source: github(REPO, { branch: BRANCH }),
    replicas: 1,
    volumeMounts: {
      "/workspace": codexData,
    },
    env: {
      WORKSPACE_DIR: "/workspace",
      TS_STATE_DIR: "/workspace/.tailscale-state",
      TS_SOCKET: "/tmp/tailscaled.sock",
      TS_HOSTNAME: "codex-remote-railway",

      // Dashboard-managed values are intentionally omitted so an IaC apply
      // never clears or replaces the current Tailscale setup:
      // TS_AUTHKEY    = required for first setup; keep for automatic recovery
      // TS_EXTRA_ARGS = optional tags or other tailscale up arguments
    },
  });

  return project("codex-remote", {
    resources: [group("Codex Remote", [app]), codexData],
  });
});
