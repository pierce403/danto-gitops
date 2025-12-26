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
