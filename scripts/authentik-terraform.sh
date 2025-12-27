#!/usr/bin/env bash
set -euo pipefail

AUTHENTIK_URL_DEFAULT=${AUTHENTIK_URL:-"https://auth.x43.io"}
AUTHENTIK_TOKEN_DEFAULT=${AUTHENTIK_TOKEN:-""}
GOOGLE_CLIENT_ID=${AUTHENTIK_GOOGLE_CLIENT_ID:-""}
GOOGLE_CLIENT_SECRET=${AUTHENTIK_GOOGLE_CLIENT_SECRET:-""}

if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl not found. This script requires kubectl access to the cluster." >&2
  exit 1
fi

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

if [ -z "$GOOGLE_CLIENT_ID" ] || [ -z "$GOOGLE_CLIENT_SECRET" ]; then
  if kubectl -n authentik get secret authentik-google-oauth >/dev/null 2>&1; then
    GOOGLE_CLIENT_ID=$(kubectl -n authentik get secret authentik-google-oauth -o jsonpath='{.data.client_id}' | base64 -d)
    GOOGLE_CLIENT_SECRET=$(kubectl -n authentik get secret authentik-google-oauth -o jsonpath='{.data.client_secret}' | base64 -d)
  fi
fi

if [ -z "$GOOGLE_CLIENT_ID" ] || [ -z "$GOOGLE_CLIENT_SECRET" ]; then
  cat <<'MSG' >&2
Missing Google OAuth client credentials.
Provide AUTHENTIK_GOOGLE_CLIENT_ID and AUTHENTIK_GOOGLE_CLIENT_SECRET, or
create the secret:
  kubectl -n authentik create secret generic authentik-google-oauth \
    --from-literal=client_id="..." \
    --from-literal=client_secret="..."
MSG
  exit 1
fi

if ! kubectl -n authentik get secret authentik-google-oauth >/dev/null 2>&1; then
  kubectl -n authentik create secret generic authentik-google-oauth \
    --from-literal=client_id="$GOOGLE_CLIENT_ID" \
    --from-literal=client_secret="$GOOGLE_CLIENT_SECRET"
fi

export TF_VAR_google_client_id="$GOOGLE_CLIENT_ID"
export TF_VAR_google_client_secret="$GOOGLE_CLIENT_SECRET"

if [ -n "${AUTHENTIK_ADMIN_EMAIL:-}" ]; then
  export TF_VAR_admin_email="$AUTHENTIK_ADMIN_EMAIL"
fi
if [ -n "${AUTHENTIK_ADMIN_DOMAIN:-}" ]; then
  export TF_VAR_admin_domain="$AUTHENTIK_ADMIN_DOMAIN"
fi

# Ensure MeshCentral OIDC secret exists (used by both terraform and MeshCentral)
if ! kubectl get namespace meshcentral >/dev/null 2>&1; then
  kubectl create namespace meshcentral
fi

if [ -z "${MESH_OIDC_CLIENT_ID:-}" ] || [ -z "${MESH_OIDC_CLIENT_SECRET:-}" ]; then
  if kubectl -n meshcentral get secret meshcentral-oidc >/dev/null 2>&1; then
    MESH_OIDC_CLIENT_ID=$(kubectl -n meshcentral get secret meshcentral-oidc -o jsonpath='{.data.client_id}' | base64 -d)
    MESH_OIDC_CLIENT_SECRET=$(kubectl -n meshcentral get secret meshcentral-oidc -o jsonpath='{.data.client_secret}' | base64 -d)
  else
    if ! command -v openssl >/dev/null 2>&1; then
      echo "openssl not found; install it to generate MeshCentral OIDC secrets." >&2
      exit 1
    fi
    MESH_OIDC_CLIENT_ID=${MESH_OIDC_CLIENT_ID:-meshcentral}
    MESH_OIDC_CLIENT_SECRET=$(openssl rand -hex 32)
    kubectl -n meshcentral create secret generic meshcentral-oidc \
      --from-literal=client_id="$MESH_OIDC_CLIENT_ID" \
      --from-literal=client_secret="$MESH_OIDC_CLIENT_SECRET"
  fi
fi

export TF_VAR_meshcentral_oidc_client_id="$MESH_OIDC_CLIENT_ID"
export TF_VAR_meshcentral_oidc_client_secret="$MESH_OIDC_CLIENT_SECRET"

cd clusters/danto/platform/authentik/terraform
terraform init
terraform apply
