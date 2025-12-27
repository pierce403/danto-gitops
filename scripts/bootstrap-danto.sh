#!/usr/bin/env bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root (sudo) so k3s and kubectl can access /etc/rancher/k3s/k3s.yaml" >&2
  exit 1
fi

ARGOCD_VERSION=${ARGOCD_VERSION:-v2.12.6}
TERRAFORM_MIN_VERSION=${TERRAFORM_MIN_VERSION:-1.5.0}

version_ge() {
  # returns 0 if $1 >= $2
  [ "$(printf '%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]
}

install_terraform_ubuntu() {
  DEBIAN_FRONTEND=noninteractive apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y gnupg curl lsb-release ca-certificates
  install -m 0755 -d /usr/share/keyrings
  curl -fsSL https://apt.releases.hashicorp.com/gpg | gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
  echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
    > /etc/apt/sources.list.d/hashicorp.list
  DEBIAN_FRONTEND=noninteractive apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y terraform
}

ensure_terraform() {
  local current_version=""
  if command -v terraform >/dev/null 2>&1; then
    current_version=$(terraform version -json 2>/dev/null | awk -F '\"' '/terraform_version/{print $4}')
    if [ -z "$current_version" ]; then
      current_version=$(terraform version | head -n1 | sed -E 's/^Terraform v//')
    fi
  fi

  if [ -z "$current_version" ]; then
    echo "Installing terraform..."
    if [ -f /etc/os-release ] && grep -qiE '^ID=ubuntu|^ID=debian' /etc/os-release; then
      install_terraform_ubuntu
    else
      echo "Unsupported OS for automated terraform install. Install terraform >= ${TERRAFORM_MIN_VERSION} manually." >&2
      exit 1
    fi
    return
  fi

  if ! version_ge "$current_version" "$TERRAFORM_MIN_VERSION"; then
    echo "Upgrading terraform to >= ${TERRAFORM_MIN_VERSION} (current: ${current_version})..."
    if [ -f /etc/os-release ] && grep -qiE '^ID=ubuntu|^ID=debian' /etc/os-release; then
      install_terraform_ubuntu
    else
      echo "Unsupported OS for automated terraform upgrade. Install terraform >= ${TERRAFORM_MIN_VERSION} manually." >&2
      exit 1
    fi
  fi
}

if ! command -v k3s >/dev/null 2>&1; then
  curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--disable traefik" sh -s -
fi

export KUBECONFIG=${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}

ensure_terraform

kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"

# Wait briefly for Argo CD API server to come up (best-effort)
kubectl -n argocd rollout status deploy/argocd-server --timeout=180s || true

# Apply root app only when secrets are present
if kubectl -n authentik get secret authentik-secrets >/dev/null 2>&1 \
  && kubectl -n authentik get secret authentik-postgresql >/dev/null 2>&1 \
  && kubectl -n authentik get secret authentik-bootstrap >/dev/null 2>&1; then
  kubectl apply -f bootstrap/root-app.yaml
else
  cat <<'MSG'
Required authentik secrets not found. Create them first:
  docs/bootstrap-secrets.md
Then rerun this script (or apply bootstrap/root-app.yaml manually).
MSG
fi
