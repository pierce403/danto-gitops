# Bootstrap secrets (authentik)

This repo avoids committing raw secrets. Create these before Argo syncs the authentik app.

## Namespaces

```bash
kubectl create namespace authentik
```

## Authentik secret key + DB password

Generate a single password and reuse it for both authentik and the embedded Postgres:

```bash
export AUTHENTIK_SECRET_KEY=$(openssl rand -hex 32)
export AUTHENTIK_DB_PASSWORD=$(openssl rand -hex 24)

kubectl -n authentik create secret generic authentik-secrets \
  --from-literal=secret_key="$AUTHENTIK_SECRET_KEY" \
  --from-literal=postgresql_password="$AUTHENTIK_DB_PASSWORD"

kubectl -n authentik create secret generic authentik-postgresql \
  --from-literal=password="$AUTHENTIK_DB_PASSWORD"
```

Notes:
- `authentik-secrets` is referenced by `clusters/danto/platform/authentik/values.yaml` via env vars.
- `authentik-postgresql` is referenced by the embedded Postgres chart.
- If you later move to an external DB, replace these with your external DB credentials and disable the embedded Postgres.
