#!/usr/bin/env bash
set -euo pipefail

NAMESPACE=${NAMESPACE:-cloud}
DEPLOYMENT=${DEPLOYMENT:-cloud}
PROVIDER_ID=${PROVIDER_ID:-authentik}
DISCOVERY_URI=${DISCOVERY_URI:-https://auth.x43.io/application/o/nextcloud-oidc/.well-known/openid-configuration}
SECRET_FILE=${SECRET_FILE:-/run/secrets/nextcloud-oidc/client_secret}

if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl not found. This script requires kubectl access to the cluster." >&2
  exit 1
fi

if ! kubectl -n "$NAMESPACE" get secret nextcloud-oidc >/dev/null 2>&1; then
  cat <<'MSG' >&2
Missing cloud/nextcloud-oidc.
Run scripts/authentik-terraform.sh first so it is generated automatically in the cluster.
MSG
  exit 1
fi

CLIENT_ID=$(kubectl -n "$NAMESPACE" get secret nextcloud-oidc -o jsonpath='{.data.client_id}' | base64 -d)

kubectl -n "$NAMESPACE" exec "deploy/$DEPLOYMENT" -- \
  su -s /bin/sh www-data -c "php occ app:install user_oidc" >/dev/null 2>&1 || true

if ! kubectl -n "$NAMESPACE" exec "deploy/$DEPLOYMENT" -- test -r "$SECRET_FILE"; then
  cat <<MSG >&2
Nextcloud OIDC client secret is not mounted at $SECRET_FILE.
Sync the cloud deployment after creating cloud/nextcloud-oidc, then rerun this script.
MSG
  exit 1
fi

kubectl -n "$NAMESPACE" exec "deploy/$DEPLOYMENT" -- \
  su -s /bin/sh www-data -c "php occ user_oidc:provider '$PROVIDER_ID' \
    --clientid='$CLIENT_ID' \
    --clientsecret-file='$SECRET_FILE' \
    --discoveryuri='$DISCOVERY_URI' \
    --scope=\"openid email profile\" \
    --mapping-uid='email' \
    --mapping-email='email' \
    --mapping-display-name='name' \
    --unique-uid=0"

kubectl -n "$NAMESPACE" exec "deploy/$DEPLOYMENT" -- \
  su -s /bin/sh www-data -c "php occ config:app:set user_oidc allow_multiple_user_backends --value=0"

echo "Nextcloud OIDC provider configured for $DISCOVERY_URI."
