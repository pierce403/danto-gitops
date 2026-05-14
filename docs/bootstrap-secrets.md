# Bootstrap Secrets

This repo avoids committing raw secrets. Generated secrets are created automatically by short-lived Kubernetes Jobs inside the target namespace and stored as Kubernetes Secrets.

## Generated Authentik Secrets

`scripts/bootstrap-danto.sh` automatically creates these if missing:

- `authentik-secrets`
- `authentik-postgresql`
- `authentik-bootstrap`

The generated DB password is reused for both authentik and the embedded Postgres. Set `AUTHENTIK_BOOTSTRAP_EMAIL` before running the script if the bootstrap admin email should differ from the default.

Notes:
- `authentik-secrets` is referenced by `clusters/danto/platform/authentik/values.yaml` via env vars.
- `authentik-postgresql` is referenced by the embedded Postgres chart.
- `authentik-bootstrap` seeds the admin bootstrap password/token on first startup and must exist before the first authentik pod starts.
- If you later move to an external DB, replace these with your external DB credentials and disable the embedded Postgres.

## Authentik Terraform API token

After authentik is running, Terraform can reuse the generated bootstrap token. If you want a separate API token, import that Authentik-issued token as a Kubernetes Secret:

```bash
kubectl -n authentik create secret generic authentik-terraform \
  --from-literal=token="YOUR_AUTHENTIK_API_TOKEN"
```

## Google OAuth Credentials

Google issues these credentials; this repo cannot generate them. Import them for Terraform to configure the Google OAuth source:

```bash
kubectl -n authentik create secret generic authentik-google-oauth \
  --from-literal=client_id="YOUR_GOOGLE_CLIENT_ID" \
  --from-literal=client_secret="YOUR_GOOGLE_CLIENT_SECRET"
```

## Authoritative DNS Public IP

Hickory DNS renders the `x43.io` zone from this imported value:

```bash
kubectl get namespace dns >/dev/null 2>&1 || kubectl create namespace dns
kubectl -n dns create secret generic danto-public-ip \
  --from-literal=ipv4="YOUR_DANTO_PUBLIC_IPV4"
```

## Argo CD GitHub Webhook

Run this on danto to create the Argo CD GitHub webhook shared secret automatically inside the cluster and copy it into `argocd-secret` from an in-cluster Job:

```bash
./scripts/configure-github-webhook.sh
```

To configure the matching GitHub repository webhook, provide a temporary GitHub token with repository webhook write permission:

```bash
GITHUB_TOKEN="YOUR_TEMPORARY_GITHUB_TOKEN" ./scripts/configure-github-webhook.sh --github
```

The generated shared secret never appears in Git or in the host shell. The temporary GitHub token is placed into a short-lived setup Secret and deleted after the setup Job finishes.

## Argo CD Notifications GitHub App

This is optional and only needed for outbound GitHub commit statuses. Deploy-on-push uses the webhook above and does not require a GitHub App private key.

Create a GitHub App with repository permission **Commit statuses: Read and write**, install it only on this repo, then import the GitHub-issued app credentials in Argo CD:

```bash
kubectl -n argocd create secret generic argocd-notifications-secret \
  --from-literal=github-app-id="YOUR_GITHUB_APP_ID" \
  --from-literal=github-installation-id="YOUR_GITHUB_APP_INSTALLATION_ID" \
  --from-file=github-private-key=/path/to/private-key.pem
```

The GitHub App does not need repository contents access.
