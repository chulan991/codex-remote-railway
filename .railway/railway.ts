// Tailscale-only remote environment on Railway.
//
// Compatibility rule: keep the existing project, service, volume resource,
// mount path, and state directory names stable. Renaming any of them can make
// Railway create or attach different storage and would lose the current
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
  // The legacy resource name is retained intentionally. Its single mount at
  // /workspace contains the existing state at /workspace/.tailscale-state.
  const codexData = volume("codex-data", { region: REGION, sizeMB: 5120 });

  // The legacy service name is also retained so an apply updates the current
  // service instead of provisioning a replacement.
  const app = service("app", {
    source: github(REPO, { branch: BRANCH }),
    replicas: 1,
    volumeMounts: {
      "/workspace": codexData,
    },
    env: {
      WORKSPACE_DIR: "/workspace",
      PORT: "9002",
      TS_STATE_DIR: "/workspace/.tailscale-state",
      TS_AUTH_ONCE: "true",
      TS_USERSPACE: "true",
      TS_ENABLE_HEALTH_CHECK: "true",
      TS_LOCAL_ADDR_PORT: "0.0.0.0:9002",

      // Secrets and identity-specific settings remain dashboard-managed so
      // config apply does not overwrite an existing setup:
      // TS_AUTHKEY    = needed for first registration or recovery only
      // TS_HOSTNAME   = optional tailnet node name
      // TS_EXTRA_ARGS = optional extra flags; entrypoint always adds --ssh
    },
  });

  // These names remain unchanged for an in-place update of the current stack.
  return project("codex-remote", {
    resources: [group("Codex Remote", [app]), codexData],
  });
});
