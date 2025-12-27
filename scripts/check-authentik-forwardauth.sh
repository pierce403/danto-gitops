#!/usr/bin/env bash
set -euo pipefail

NAMESPACE=${NAMESPACE:-authentik}
SERVICE=${SERVICE:-authentik-server}
PATH_SUFFIX=${PATH_SUFFIX:-/outpost.goauthentik.io/auth/traefik}

# Create a temporary pod to test cluster DNS/service reachability
POD_NAME="fa-check-$(date +%s)"

kubectl -n "$NAMESPACE" run "$POD_NAME" \
  --image=curlimages/curl:8.10.1 \
  --restart=Never \
  --command -- sh -c "curl -sS -o /dev/null -w '%{http_code}\n' \
    -H 'Host: auth.x43.io' \
    -H 'X-Forwarded-Host: argo.x43.io' \
    -H 'X-Forwarded-Proto: https' \
    -H 'X-Forwarded-Uri: /' \
    http://${SERVICE}.${NAMESPACE}.svc.cluster.local${PATH_SUFFIX}" \
  >/dev/null

kubectl -n "$NAMESPACE" wait --for=condition=Ready pod/$POD_NAME --timeout=60s >/dev/null || true

STATUS=$(kubectl -n "$NAMESPACE" logs "$POD_NAME" 2>/dev/null | tail -n1 || true)

kubectl -n "$NAMESPACE" delete pod "$POD_NAME" --ignore-not-found >/dev/null

if [ "$STATUS" = "200" ] || [ "$STATUS" = "302" ] || [ "$STATUS" = "401" ]; then
  echo "Forward-auth endpoint reachable (HTTP $STATUS)"
  exit 0
fi

echo "Forward-auth endpoint check failed (status: ${STATUS:-unknown})" >&2
exit 1
