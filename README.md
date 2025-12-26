# danto-gitops

GitOps repo for the danto cluster using Argo CD and an app-of-apps layout.

## Layout

- `bootstrap/` one-time Argo root app
- `clusters/danto/argocd/` Argo projects + applications (app-of-apps)
- `clusters/danto/platform/` ingress + auth middleware bits
- `clusters/danto/apps/` MeshCentral + future apps

## Prereqs

- DNS A records: `auth.x43.io`, `argo.x43.io`, `mesh.x43.io`, `danto.x43.io` → the same public IP
- Firewall: allow `22` and `443` only
- If using k3s, disable the built-in Traefik (`--disable traefik`) before installing this stack

## Bootstrap (short)

1. Install Kubernetes (k3s is fine; disable the built-in Traefik if you use k3s).
2. Install Argo CD into the `argocd` namespace.
3. If you fork/rename this repo, update repo URLs in:
   - `bootstrap/root-app.yaml`
   - `clusters/danto/argocd/projects/*.yaml`
   - `clusters/danto/argocd/applications/*.yaml`
4. Create bootstrap secrets (see `docs/bootstrap-secrets.md`).
5. Apply the root app:
   - `kubectl apply -f bootstrap/root-app.yaml`
6. Wait for Argo CD to sync, then finish initial authentik setup at `https://auth.x43.io`.

## Authentik + Google SSO

- Create a Google OAuth client for `https://auth.x43.io`.
- Add Google as an authentik IdP, then create authentik Applications as your launchpad.
- Default policy: restrict access to your Google account (or Workspace domain/groups).

## Notes

- Traefik uses TLS-ALPN-01 (443 only) with persistent ACME storage; the HTTP (web) entrypoint is disabled.
- Authentik cookie domain is set to `.x43.io` for sibling subdomains.
- For SSO across sibling subdomains, ensure your authentik forward-auth provider/outpost is configured for `.x43.io` to avoid redirect loops.
- Authentik uses the chart’s embedded Postgres for v1. Upgrade later to external DB (and Redis if you add it).
- MeshCentral is configured for TLS offload behind Traefik; adjust `clusters/danto/apps/meshcentral/configmap.yaml` if needed.
- Argo CD is terminated at Traefik; `argocd-server` runs in insecure mode internally.

## Secrets hygiene

No raw secrets are committed. Bootstrap secrets are created manually; see `docs/bootstrap-secrets.md`.

## CI checks

GitHub Actions runs kustomize/helm rendering plus kubeconform validation. Configure branch protection to require this workflow so phone merges are blocked on render failures.
