#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: ensure-app-secrets.sh [--all|--cloud|--chat|--pad] [--restart]

Generate missing disposable app bootstrap secrets as Kubernetes Secrets.
Secret values are generated locally on the cluster host, sent only to the
Kubernetes API, and never printed or written to git.

Options:
  --all       Ensure cloud, chat, and pad secrets (default)
  --cloud     Ensure Nextcloud secrets only
  --chat      Ensure Mattermost secrets only
  --pad       Ensure CryptPad secrets only
  --restart   Roll deployments after creating any missing secrets
USAGE
}

ensure_openssl() {
  if command -v openssl >/dev/null 2>&1; then
    return
  fi

  echo "openssl is required to generate secrets." >&2
  exit 1
}

ensure_kubectl() {
  if command -v kubectl >/dev/null 2>&1; then
    return
  fi

  echo "kubectl is required to create Kubernetes Secrets." >&2
  exit 1
}

rand_hex() {
  local bytes=$1
  openssl rand -hex "$bytes"
}

ensure_namespace() {
  local namespace=$1
  kubectl create namespace "$namespace" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
}

secret_exists() {
  local namespace=$1
  local name=$2
  kubectl -n "$namespace" get secret "$name" >/dev/null 2>&1
}

created_any=0
restart=0
ensure_cloud=0
ensure_chat=0
ensure_pad=0

if [[ $# -eq 0 ]]; then
  ensure_cloud=1
  ensure_chat=1
  ensure_pad=1
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --all)
      ensure_cloud=1
      ensure_chat=1
      ensure_pad=1
      ;;
    --cloud)
      ensure_cloud=1
      ;;
    --chat)
      ensure_chat=1
      ;;
    --pad)
      ensure_pad=1
      ;;
    --restart)
      restart=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 1
      ;;
  esac
  shift
done

ensure_openssl
ensure_kubectl

if [[ "$ensure_cloud" -eq 1 ]]; then
  ensure_namespace cloud
  if secret_exists cloud cloud-secrets; then
    echo "cloud/cloud-secrets already exists; leaving it unchanged."
  else
    kubectl -n cloud create secret generic cloud-secrets \
      --from-literal=mariadb-root-password="$(rand_hex 32)" \
      --from-literal=mariadb-password="$(rand_hex 32)" \
      --from-literal=nextcloud-admin-user="${NEXTCLOUD_ADMIN_USER:-cloudadmin}" \
      --from-literal=nextcloud-admin-password="$(rand_hex 32)" >/dev/null
    echo "Created cloud/cloud-secrets."
    created_any=1
  fi

  if [[ "$restart" -eq 1 ]]; then
    kubectl -n cloud rollout restart deployment/cloud-db deployment/cloud >/dev/null 2>&1 || true
  fi
fi

if [[ "$ensure_chat" -eq 1 ]]; then
  ensure_namespace chat
  if secret_exists chat chat-secrets; then
    echo "chat/chat-secrets already exists; leaving it unchanged."
  else
    kubectl -n chat create secret generic chat-secrets \
      --from-literal=postgres-password="$(rand_hex 32)" >/dev/null
    echo "Created chat/chat-secrets."
    created_any=1
  fi

  if [[ "$restart" -eq 1 ]]; then
    kubectl -n chat rollout restart deployment/chat-db deployment/chat >/dev/null 2>&1 || true
  fi
fi

if [[ "$ensure_pad" -eq 1 ]]; then
  ensure_namespace pad
  if secret_exists pad pad-secrets; then
    echo "pad/pad-secrets already exists; leaving it unchanged."
  else
    kubectl -n pad create secret generic pad-secrets \
      --from-literal=login_salt="$(rand_hex 32)" >/dev/null
    echo "Created pad/pad-secrets."
    created_any=1
  fi

  if [[ "$restart" -eq 1 ]]; then
    kubectl -n pad rollout restart deployment/pad >/dev/null 2>&1 || true
  fi
fi

if [[ "$created_any" -eq 0 ]]; then
  echo "No missing app secrets found."
fi
