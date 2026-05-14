#!/usr/bin/env bash
set -euo pipefail

NAMESPACE=${NAMESPACE:-cloud}
DEPLOYMENT=${DEPLOYMENT:-cloud}
PROVIDER_ID=${PROVIDER_ID:-authentik}
DISCOVERY_URI=${DISCOVERY_URI:-https://auth.x43.io/application/o/nextcloud-oidc/.well-known/openid-configuration}

if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl not found. This script requires kubectl access to the cluster." >&2
  exit 1
fi

if ! kubectl -n "$NAMESPACE" get secret nextcloud-oidc >/dev/null 2>&1; then
  cat <<'MSG' >&2
Missing cloud/nextcloud-oidc.
Run scripts/authentik-terraform.sh first, or create the secret manually with client_id and client_secret keys.
MSG
  exit 1
fi

CLIENT_ID=$(kubectl -n "$NAMESPACE" get secret nextcloud-oidc -o jsonpath='{.data.client_id}' | base64 -d)
CLIENT_SECRET=$(kubectl -n "$NAMESPACE" get secret nextcloud-oidc -o jsonpath='{.data.client_secret}' | base64 -d)

kubectl -n "$NAMESPACE" exec "deploy/$DEPLOYMENT" -- \
  su -s /bin/sh www-data -c "php occ app:install user_oidc" >/dev/null 2>&1 || true

SECRET_FILE=/tmp/nextcloud-oidc-client-secret
printf '%s' "$CLIENT_SECRET" | kubectl -n "$NAMESPACE" exec -i "deploy/$DEPLOYMENT" -- \
  sh -c "umask 077 && cat > '$SECRET_FILE' && chown www-data:www-data '$SECRET_FILE'"

cleanup() {
  kubectl -n "$NAMESPACE" exec "deploy/$DEPLOYMENT" -- rm -f "$SECRET_FILE" >/dev/null 2>&1 || true
}
trap cleanup EXIT

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
