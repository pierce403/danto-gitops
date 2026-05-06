# danto-gitops

GitOps repo for the danto cluster using Argo CD and an app-of-apps layout.

## Layout

- `bootstrap/` one-time Argo root app
- `clusters/danto/argocd/` Argo projects + applications (app-of-apps)
- `clusters/danto/platform/` ingress + auth middleware bits
- `clusters/danto/apps/` MeshCentral, Nextcloud (`cloud`), CryptPad (`pad`), Hypersnap + future apps

## Prereqs

- DNS: `danto.x43.io` A record → the public server IP; `auth.x43.io`, `argo.x43.io`, `mesh.x43.io`, `cloud.x43.io`, `pad.x43.io`, `pad-sandbox.x43.io`, `snap.x43.io`, and `grafana.x43.io` CNAME → `danto.x43.io`
- Firewall: allow `22`, `443`, `3382/udp`, and `3383/tcp`
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
- `scripts/dns-terraform.sh`: applies Git-managed Namecheap DNS records.
- `scripts/check-authentik-forwardauth.sh`: validates the forward-auth endpoint is reachable inside the cluster.
- `scripts/check-endpoints.sh`: sanity checks the public HTTPS endpoints for Argo CD, MeshCentral, Nextcloud, CryptPad, Hypersnap, and Grafana.

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

## DNS Terraform (GitOps-managed)

`x43.io` currently uses Namecheap BasicDNS (`dns1.registrar-servers.com`, `dns2.registrar-servers.com`). DNS records are managed with the official Namecheap Terraform provider in:

- `clusters/danto/dns/namecheap/`

The DNS model keeps one A record for `danto.x43.io`; app hostnames CNAME to it. This makes public IP rotation a single-record change.

Create a local `.env.dns` file or export these variables:

```bash
export NAMECHEAP_USER_NAME="YOUR_NAMECHEAP_USERNAME"
export NAMECHEAP_API_USER="YOUR_NAMECHEAP_USERNAME"
export NAMECHEAP_API_KEY="YOUR_NAMECHEAP_API_KEY"
export NAMECHEAP_CLIENT_IP="YOUR_WHITELISTED_IPV4"
export DANTO_IPV4="YOUR_DANTO_PUBLIC_IPV4"
```

Then apply:

```bash
./scripts/dns-terraform.sh
```

Notes:
- Namecheap API access must be enabled and `NAMECHEAP_CLIENT_IP` must be whitelisted in the Namecheap dashboard.
- Terraform state and local `.env*` files are gitignored.
- The DNS module uses `MERGE` mode so it manages the declared danto/app records without intentionally replacing unrelated records.
- Review the first Terraform plan carefully if existing app hostnames are already A records; switching a hostname to CNAME may require removing the old conflicting host record in Namecheap.

## Authentik + Google SSO

- Create a Google OAuth client for `https://auth.x43.io`.
- Store its credentials in `authentik-google-oauth` (see “Google OAuth credentials” below).
- Terraform wires Google as the default login source and creates the Authentik apps/providers.
- Default policy: restrict access to `admin_email` (default: `pierce403@gmail.com`) or optional admin domain.

## App bootstrap secrets

Create these secrets before syncing `cloud` and `pad` for the first time:

### Nextcloud (`cloud.x43.io`)

```bash
kubectl get namespace cloud >/dev/null 2>&1 || kubectl create namespace cloud
kubectl -n cloud create secret generic cloud-secrets \
  --from-literal=mariadb-root-password="$(openssl rand -hex 32)" \
  --from-literal=mariadb-password="$(openssl rand -hex 32)" \
  --from-literal=nextcloud-admin-user="cloudadmin" \
  --from-literal=nextcloud-admin-password="$(openssl rand -hex 32)"
```

### CryptPad (`pad.x43.io`)

```bash
kubectl get namespace pad >/dev/null 2>&1 || kubectl create namespace pad
kubectl -n pad create secret generic pad-secrets \
  --from-literal=login_salt="$(openssl rand -hex 32)"
```

Notes:
- `login_salt` must be set before the first CryptPad user is created; changing it later breaks logins.
- `cloud` and `pad` are protected at Traefik by the shared authentik forward-auth middleware, matching the rest of the repo.
- CryptPad still has its own first-run onboarding flow; grab the setup token from the `pad` pod logs on initial boot to create the internal admin account.

## Hypersnap

Hypersnap runs as a stateful Farcaster/Snapchain-derived node using `farcasterorg/hypersnap:latest`.

- HTTP API: `https://snap.x43.io/v2/farcaster/*` via Traefik websecure and authentik forward-auth.
- Grafana: `https://grafana.x43.io/` via Traefik websecure and authentik forward-auth.
- Node gossip: public `3382/udp` via Traefik `IngressRouteUDP`.
- gRPC: public `3383/tcp` via Traefik `IngressRouteTCP`.
- Storage: `hypersnap-data` PVC requests `2Ti`; upstream documents `1.5TB` free storage as the minimum.
- Runtime resources request `4` CPUs and `16Gi` memory.
- Metrics flow: Hypersnap emits StatsD metrics to `hypersnap-statsd`; Grafana provisions the upstream Hypersnap/Snapchain dashboard with a Graphite datasource backed by that StatsD container.

The HTTP API is authenticated because this repo requires every web-exposed service to use the shared authentik forward-auth middleware. The raw gossip and gRPC node ports are not browser endpoints and are exposed through dedicated Traefik entrypoints.

DNS remains provider-managed through Namecheap Terraform. A CNAME does not delegate DNS control; authoritative control comes from NS delegation. If self-hosted DNS is needed later, delegate a subdomain to at least two authoritative nameservers instead of moving all of `x43.io` to one server.

## Notes

- Traefik uses TLS-ALPN-01 (443 only) with persistent ACME storage; the HTTP (web) entrypoint is disabled.
- Traefik also exposes dedicated Hypersnap node entrypoints on `3382/udp` and `3383/tcp`.
- Authentik cookie domain is set to `.x43.io` for sibling subdomains.
- For SSO across sibling subdomains, ensure your authentik forward-auth provider/outpost is configured for `.x43.io` to avoid redirect loops.
- Authentik uses the chart’s embedded Postgres for v1. Upgrade later to external DB (and Redis if you add it).
- MeshCentral is configured for TLS offload behind Traefik and OIDC via authentik; adjust `clusters/danto/apps/meshcentral/configmap.yaml` if needed.
- Argo CD is terminated at Traefik; `argocd-server` runs in insecure mode internally.

## External endpoints

- `https://auth.x43.io/` authentik
- `https://argo.x43.io/` Argo CD
- `https://mesh.x43.io/` MeshCentral
- `https://cloud.x43.io/` Nextcloud
- `https://snap.x43.io/v2/farcaster/` Hypersnap HTTP API
- `https://grafana.x43.io/` Hypersnap/Snapchain metrics dashboard
- `https://pad.x43.io/` CryptPad
- `https://pad-sandbox.x43.io/` CryptPad sandbox companion host

## Secrets hygiene

No raw secrets are committed. Bootstrap secrets are created manually; see `docs/bootstrap-secrets.md`.

## CI checks

GitHub Actions runs kustomize/helm rendering plus kubeconform validation. Configure branch protection to require this workflow so phone merges are blocked on render failures.
