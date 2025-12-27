#!/usr/bin/env bash
set -euo pipefail

AUTHENTIK_URL_DEFAULT=${AUTHENTIK_URL:-"https://auth.x43.io"}
AUTHENTIK_TOKEN_DEFAULT=${AUTHENTIK_TOKEN:-""}

if [ -z "$AUTHENTIK_TOKEN_DEFAULT" ]; then
  AUTHENTIK_TOKEN_DEFAULT=$(kubectl -n authentik get secret authentik-terraform -o jsonpath='{.data.token}' | base64 -d)
fi

export AUTHENTIK_URL="$AUTHENTIK_URL_DEFAULT"
export AUTHENTIK_TOKEN="$AUTHENTIK_TOKEN_DEFAULT"

cd clusters/danto/platform/authentik/terraform
terraform init
terraform apply
