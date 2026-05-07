# Codex conventions for danto-gitops

When adding a new service/app:

- Create a new folder at `clusters/danto/apps/<name>/` with a `kustomization.yaml` and manifests.
- Default hostname is `<app>.x43.io`.
- Anything web-exposed must be behind Traefik and use the authentik forward-auth middleware (`authentik-authentik-forward-auth@kubernetescrd`).
- No NodePorts; only Ingress/IngressRoute.
- Update the parent Argo application list: `clusters/danto/argocd/applications/kustomization.yaml`.
- Document new external endpoints in `README.md`.
- Never commit raw secrets; use manual secret creation or external secret tooling.

Platform notes:

- If using k3s, disable the built-in Traefik before installing this Traefik.
- Keep the Traefik web (80) entrypoint disabled unless explicitly needed.
- Argo CD is terminated at Traefik; keep argocd-server in insecure mode internally.
- Forward-auth/outpost config must align with `.x43.io` to avoid redirect loops.
- Keep Argo sync ordering deterministic (Traefik -> authentik -> ingresses -> apps).

Commit/push policy:

- After any repo edit, always commit and push.
- Exception: if running on `danto` or otherwise lacking commit/push capability, do not edit, commit, or push; act as the deploy/ops agent and request repo changes from the dev agent.

Running on server danto:

- The agent can pull/fetch/clone but cannot push or commit from danto. It should request any git changes instead of applying them.
- On danto, the agent should focus on pulling the latest code, bootstrapping/applying Argo CD, checking sync status, inspecting Kubernetes resources/logs, and troubleshooting runtime/deployment issues.
- On danto, the agent should only run setup/ops commands; no repo edits.

Agent roles:

- Dev agent: has working commit/push capability. It edits files, commits, and pushes changes.
- Deploy/ops agent: is running on `danto` or lacks commit/push capability. It pulls/fetches code, applies/bootstrap Argo, checks cluster state, troubleshoots workloads, and never edits, commits, or pushes.
- Deploy/ops agent can and should send recommendations to the dev agent (file paths + proposed changes or a patch summary).
