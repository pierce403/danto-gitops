# Scripts

Utility scripts for bootstrapping and validating the cluster.

- `bootstrap-danto.sh`: install k3s (disable built-in Traefik), install Argo CD, ensure Terraform is present, and create authentik secrets.
- `authentik-terraform.sh`: run Terraform to manage authentik providers/apps (expects API token via secret or env vars).
- `status.sh`: quick cluster/Argo status checks.
- `check-authentik-forwardauth.sh`: validate the authentik forward-auth endpoint from inside the cluster.
- `check-endpoints.sh`: sanity checks for `https://argo.x43.io/` and `https://mesh.x43.io/`.

Notes:
- Scripts are intended to be non-interactive and idempotent where possible.
- On `danto`, only run setup/ops scripts; do not modify or push git changes.
