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

## Core philosophy

- Everything is GitOps (no manual UI for app/provider config).
- Secrets are never committed; they’re generated headlessly and stored as Kubernetes Secrets.
- Bootstrap scripts should be fully non-interactive where possible.
- Ops on `danto` runs setup only; the dev agent owns repo changes and automation.

## Bootstrap (short)

1. If you fork/rename this repo, update repo URLs in:
   - `bootstrap/root-app.yaml`
   - `clusters/danto/argocd/projects/*.yaml`
   - `clusters/danto/argocd/applications/*.yaml`
2. Run the bootstrap script on the server (secrets are generated if missing):
   - `sudo ./scripts/bootstrap-danto.sh`
3. Wait for Argo CD to sync, then finish initial authentik setup at `https://auth.x43.io`.

## Scripts

- `scripts/bootstrap-danto.sh`: installs k3s (with built-in Traefik disabled), installs Argo CD, and applies the root app once secrets exist.
  - Optional: set `ARGOCD_VERSION` (default: `v2.12.6`).
  - Installs or upgrades Terraform to `>= 1.5.0` on Ubuntu via the HashiCorp apt repo (non-interactive). Debian is best-effort.
  - Generates authentik bootstrap secrets if missing (headless).
- `scripts/status.sh`: quick cluster/Argo status checks.
- `scripts/authentik-terraform.sh`: applies Git-managed authentik providers/apps via Terraform.
- `scripts/check-authentik-forwardauth.sh`: validates the forward-auth endpoint is reachable inside the cluster.
- `scripts/check-endpoints.sh`: sanity checks `https://argo.x43.io/` and `https://mesh.x43.io/`.

## Authentik Terraform (GitOps-managed)

Terraform manages authentik configuration (no manual UI for apps/providers/outposts). Changes live in:

- `clusters/danto/platform/authentik/terraform/`

### Google OAuth credentials

Create a Kubernetes secret with your Google OAuth client credentials:

```bash
kubectl -n authentik create secret generic authentik-google-oauth \
  --from-literal=client_id="YOUR_GOOGLE_CLIENT_ID" \
  --from-literal=client_secret="YOUR_GOOGLE_CLIENT_SECRET"
```

### One-time API token secret

Preferred (headless): create `authentik-bootstrap` before first startup (see `docs/bootstrap-secrets.md`). The bootstrap token is an API token and can be used by Terraform.

Alternative: create a separate API token and store it in a Kubernetes Secret:

```bash
kubectl -n authentik create secret generic authentik-terraform \
  --from-literal=token="YOUR_AUTHENTIK_API_TOKEN"
```

### Apply Terraform

Run from a machine with `kubectl` + `terraform` configured (not from `danto`):

```bash
./scripts/authentik-terraform.sh
```

Notes:
- The Terraform state is stored in a Kubernetes Secret in the `authentik` namespace.
- If your instance uses different default flow slugs, update them in `clusters/danto/platform/authentik/terraform/main.tf`.
- Bootstrap env vars are only read on first startup; ensure `authentik-bootstrap` exists before the first authentik pod starts.
- Install Terraform on your workstation via your package manager or the HashiCorp install docs.
- On Ubuntu, `scripts/bootstrap-danto.sh` installs/upgrades Terraform automatically; on other OSes, install it manually.
- If the server has no outbound network access, Terraform install will fail; install it manually in that case.
- `scripts/authentik-terraform.sh` also creates the `meshcentral-oidc` secret if missing.
- Admin access is restricted by an authentik policy to `admin_email` (default: `pierce403@gmail.com`).

## Authentik + Google SSO

- Create a Google OAuth client for `https://auth.x43.io`.
- Store its credentials in `authentik-google-oauth` (see “Google OAuth credentials” below).
- Terraform wires Google as the default login source and creates the Authentik apps/providers.
- Default policy: restrict access to `admin_email` (default: `pierce403@gmail.com`) or optional admin domain.

## Notes

- Traefik uses TLS-ALPN-01 (443 only) with persistent ACME storage; the HTTP (web) entrypoint is disabled.
- Authentik cookie domain is set to `.x43.io` for sibling subdomains.
- For SSO across sibling subdomains, ensure your authentik forward-auth provider/outpost is configured for `.x43.io` to avoid redirect loops.
- Authentik uses the chart’s embedded Postgres for v1. Upgrade later to external DB (and Redis if you add it).
- MeshCentral is configured for TLS offload behind Traefik and OIDC via authentik; adjust `clusters/danto/apps/meshcentral/configmap.yaml` if needed.
- Argo CD is terminated at Traefik; `argocd-server` runs in insecure mode internally.

## Secrets hygiene

No raw secrets are committed. Bootstrap secrets are created manually; see `docs/bootstrap-secrets.md`.

## CI checks

GitHub Actions runs kustomize/helm rendering plus kubeconform validation. Configure branch protection to require this workflow so phone merges are blocked on render failures.
