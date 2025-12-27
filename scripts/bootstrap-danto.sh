#!/usr/bin/env bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root (sudo) so k3s and kubectl can access /etc/rancher/k3s/k3s.yaml" >&2
  exit 1
fi

ARGOCD_VERSION=${ARGOCD_VERSION:-v2.12.6}

if ! command -v k3s >/dev/null 2>&1; then
  curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--disable traefik" sh -s -
fi

export KUBECONFIG=${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}

kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"

# Wait briefly for Argo CD API server to come up (best-effort)
kubectl -n argocd rollout status deploy/argocd-server --timeout=180s || true

# Apply root app only when secrets are present
if kubectl -n authentik get secret authentik-secrets >/dev/null 2>&1 \
  && kubectl -n authentik get secret authentik-postgresql >/dev/null 2>&1; then
  kubectl apply -f bootstrap/root-app.yaml
else
  cat <<'MSG'
Authentik secrets not found. Create them first:
  docs/bootstrap-secrets.md
Then rerun this script (or apply bootstrap/root-app.yaml manually).
MSG
fi
