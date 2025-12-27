#!/usr/bin/env bash
set -euo pipefail

AUTHENTIK_URL_DEFAULT=${AUTHENTIK_URL:-"https://auth.x43.io"}
AUTHENTIK_TOKEN_DEFAULT=${AUTHENTIK_TOKEN:-""}

if ! command -v terraform >/dev/null 2>&1; then
  echo "terraform not found. Run this script on a machine with terraform installed." >&2
  exit 1
fi

if [ -z "$AUTHENTIK_TOKEN_DEFAULT" ]; then
  if kubectl -n authentik get secret authentik-terraform >/dev/null 2>&1; then
    AUTHENTIK_TOKEN_DEFAULT=$(kubectl -n authentik get secret authentik-terraform -o jsonpath='{.data.token}' | base64 -d)
  elif kubectl -n authentik get secret authentik-bootstrap >/dev/null 2>&1; then
    AUTHENTIK_TOKEN_DEFAULT=$(kubectl -n authentik get secret authentik-bootstrap -o jsonpath='{.data.bootstrap_token}' | base64 -d)
    echo "Using bootstrap token from authentik-bootstrap (API token). If auth fails, create an authentik-terraform token." >&2
  fi
fi

if [ -z "$AUTHENTIK_TOKEN_DEFAULT" ]; then
  cat <<'MSG' >&2
No authentik API token found.
Create one of these secrets in the authentik namespace:
  - authentik-terraform (key: token)
  - authentik-bootstrap (key: bootstrap_token)
MSG
  exit 1
fi

export AUTHENTIK_URL="$AUTHENTIK_URL_DEFAULT"
export AUTHENTIK_TOKEN="$AUTHENTIK_TOKEN_DEFAULT"

cd clusters/danto/platform/authentik/terraform
terraform init
terraform apply
