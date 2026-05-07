# Bootstrap secrets (authentik)

This repo avoids committing raw secrets. The bootstrap script now generates these automatically; use this doc only if you need to create them manually (offline or custom values).

## Namespaces

```bash
kubectl create namespace authentik
```

## Authentik secret key + DB password (manual)

Generate a single password and reuse it for both authentik and the embedded Postgres:

```bash
export AUTHENTIK_SECRET_KEY=$(openssl rand -hex 32)
export AUTHENTIK_DB_PASSWORD=$(openssl rand -hex 24)
export AUTHENTIK_BOOTSTRAP_PASSWORD=$(openssl rand -base64 24)
export AUTHENTIK_BOOTSTRAP_TOKEN=$(openssl rand -hex 32)
export AUTHENTIK_BOOTSTRAP_EMAIL="pierce403@gmail.com" # optional

kubectl -n authentik create secret generic authentik-secrets \
  --from-literal=secret_key="$AUTHENTIK_SECRET_KEY" \
  --from-literal=postgresql_password="$AUTHENTIK_DB_PASSWORD"

kubectl -n authentik create secret generic authentik-postgresql \
  --from-literal=password="$AUTHENTIK_DB_PASSWORD"

kubectl -n authentik create secret generic authentik-bootstrap \
  --from-literal=bootstrap_password="$AUTHENTIK_BOOTSTRAP_PASSWORD" \
  --from-literal=bootstrap_token="$AUTHENTIK_BOOTSTRAP_TOKEN" \
  --from-literal=bootstrap_email="$AUTHENTIK_BOOTSTRAP_EMAIL"
```

Notes:
- `authentik-secrets` is referenced by `clusters/danto/platform/authentik/values.yaml` via env vars.
- `authentik-postgresql` is referenced by the embedded Postgres chart.
- `authentik-bootstrap` seeds the admin bootstrap password/token on first startup and must exist before the first authentik pod starts.
- If you later move to an external DB, replace these with your external DB credentials and disable the embedded Postgres.

## Authentik Terraform API token (post-setup, manual)

After authentik is running, you can reuse the bootstrap token (API intent) or create a separate API token and store it as a secret:

```bash
kubectl -n authentik create secret generic authentik-terraform \
  --from-literal=token="YOUR_AUTHENTIK_API_TOKEN"
```

## Google OAuth credentials (manual)

Create this secret for Terraform to configure the Google OAuth source:

```bash
kubectl -n authentik create secret generic authentik-google-oauth \
  --from-literal=client_id="YOUR_GOOGLE_CLIENT_ID" \
  --from-literal=client_secret="YOUR_GOOGLE_CLIENT_SECRET"
```

## Authoritative DNS public IP

Hickory DNS renders the `x43.io` zone from this secret:

```bash
kubectl get namespace dns >/dev/null 2>&1 || kubectl create namespace dns
kubectl -n dns create secret generic danto-public-ip \
  --from-literal=ipv4="YOUR_DANTO_PUBLIC_IPV4"
```

## Argo CD Notifications GitHub App

Create a GitHub App with repository permission **Commit statuses: Read and write**, install it only on this repo, then store the app credentials in Argo CD:

```bash
kubectl -n argocd create secret generic argocd-notifications-secret \
  --from-literal=github-app-id="YOUR_GITHUB_APP_ID" \
  --from-literal=github-installation-id="YOUR_GITHUB_APP_INSTALLATION_ID" \
  --from-file=github-private-key=/path/to/private-key.pem
```

The GitHub App does not need repository contents access.
