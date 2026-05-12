# Scripts

Utility scripts for bootstrapping and validating the cluster.

- `bootstrap-danto.sh`: install k3s (disable built-in Traefik), point k3s local-path PVC storage at `/srv/k3s/storage`, keep host DNS off the `127.0.0.53` stub when ServiceLB owns port `53`, install Argo CD, ensure Terraform is present, and create authentik secrets.
- `authentik-terraform.sh`: run Terraform to manage authentik providers/apps (expects API token via secret or env vars).
- `authentik-terraform.sh` also reads Google OAuth credentials from `authentik-google-oauth` and creates `meshcentral-oidc` if missing.
- `status.sh`: quick cluster/Argo status checks.
- `check-authentik-forwardauth.sh`: validate the authentik forward-auth endpoint from inside the cluster.
- `check-dns.sh`: validate authoritative DNS answers and public delegation for `x43.io`.
- `check-endpoints.sh`: sanity checks for public HTTPS app endpoints.

Notes:
- Scripts are intended to be non-interactive and idempotent where possible.
- On `danto`, only run setup/ops scripts; do not modify or push git changes.
- GitHub Actions `danto-smoke` runs `check-dns.sh` plus a public Argo endpoint check without any secrets.
- Argo CD Notifications reports sync results back to GitHub commit statuses when `argocd-notifications-secret` exists.
