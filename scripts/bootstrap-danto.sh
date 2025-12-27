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
  if [ ! -f /usr/share/keyrings/hashicorp-archive-keyring.gpg ]; then
    if ! curl -fsSL https://apt.releases.hashicorp.com/gpg | gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg; then
      echo "Failed to download HashiCorp GPG key (check outbound network). Install terraform manually." >&2
      exit 1
    fi
  fi
  if [ ! -f /etc/apt/sources.list.d/hashicorp.list ]; then
    echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
      > /etc/apt/sources.list.d/hashicorp.list
  fi
  DEBIAN_FRONTEND=noninteractive apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y terraform
}

install_terraform_debian() {
  echo "Debian support is best-effort. Using HashiCorp's Ubuntu repo for terraform." >&2
  install_terraform_ubuntu
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
    if [ -f /etc/os-release ] && grep -qi '^ID=ubuntu' /etc/os-release; then
      install_terraform_ubuntu
    elif [ -f /etc/os-release ] && grep -qi '^ID=debian' /etc/os-release; then
      install_terraform_debian
    else
      echo "Unsupported OS for automated terraform install. Install terraform >= ${TERRAFORM_MIN_VERSION} manually." >&2
      exit 1
    fi
    return
  fi

  if ! version_ge "$current_version" "$TERRAFORM_MIN_VERSION"; then
    echo "Upgrading terraform to >= ${TERRAFORM_MIN_VERSION} (current: ${current_version})..."
    if [ -f /etc/os-release ] && grep -qi '^ID=ubuntu' /etc/os-release; then
      install_terraform_ubuntu
    elif [ -f /etc/os-release ] && grep -qi '^ID=debian' /etc/os-release; then
      install_terraform_debian
    else
      echo "Unsupported OS for automated terraform upgrade. Install terraform >= ${TERRAFORM_MIN_VERSION} manually." >&2
      exit 1
    fi
  fi
}

get_secret_value() {
  local secret_name=$1
  local key=$2
  kubectl -n authentik get secret "$secret_name" -o "jsonpath={.data.${key}}" 2>/dev/null | base64 -d || true
}

ensure_authentik_secrets() {
  kubectl create namespace authentik --dry-run=client -o yaml | kubectl apply -f -

  if ! command -v openssl >/dev/null 2>&1; then
    echo "openssl not found; installing..." >&2
    if [ -f /etc/os-release ] && grep -qi '^ID=ubuntu' /etc/os-release; then
      DEBIAN_FRONTEND=noninteractive apt-get update -y
      DEBIAN_FRONTEND=noninteractive apt-get install -y openssl
    elif [ -f /etc/os-release ] && grep -qi '^ID=debian' /etc/os-release; then
      DEBIAN_FRONTEND=noninteractive apt-get update -y
      DEBIAN_FRONTEND=noninteractive apt-get install -y openssl
    else
      echo "Unsupported OS for automated openssl install. Install openssl manually." >&2
      exit 1
    fi
  fi

  local secret_key=""
  local db_password=""
  local bootstrap_password=""
  local bootstrap_token=""
  local bootstrap_email=""

  if kubectl -n authentik get secret authentik-secrets >/dev/null 2>&1; then
    secret_key=$(get_secret_value authentik-secrets secret_key)
    db_password=$(get_secret_value authentik-secrets postgresql_password)
  fi

  if [ -z "$db_password" ] && kubectl -n authentik get secret authentik-postgresql >/dev/null 2>&1; then
    db_password=$(get_secret_value authentik-postgresql password)
  fi

  if kubectl -n authentik get secret authentik-bootstrap >/dev/null 2>&1; then
    bootstrap_password=$(get_secret_value authentik-bootstrap bootstrap_password)
    bootstrap_token=$(get_secret_value authentik-bootstrap bootstrap_token)
    bootstrap_email=$(get_secret_value authentik-bootstrap bootstrap_email)
  fi

  secret_key=${AUTHENTIK_SECRET_KEY:-$secret_key}
  db_password=${AUTHENTIK_DB_PASSWORD:-$db_password}
  bootstrap_password=${AUTHENTIK_BOOTSTRAP_PASSWORD:-$bootstrap_password}
  bootstrap_token=${AUTHENTIK_BOOTSTRAP_TOKEN:-$bootstrap_token}
  bootstrap_email=${AUTHENTIK_BOOTSTRAP_EMAIL:-$bootstrap_email}

  if [ -z "$secret_key" ]; then
    secret_key=$(openssl rand -hex 32)
  fi
  if [ -z "$db_password" ]; then
    db_password=$(openssl rand -hex 24)
  fi
  if [ -z "$bootstrap_password" ]; then
    bootstrap_password=$(openssl rand -base64 24)
  fi
  if [ -z "$bootstrap_token" ]; then
    bootstrap_token=$(openssl rand -hex 32)
  fi
  if [ -z "$bootstrap_email" ]; then
    bootstrap_email="admin@x43.io"
  fi

  if ! kubectl -n authentik get secret authentik-secrets >/dev/null 2>&1; then
    kubectl -n authentik create secret generic authentik-secrets \
      --from-literal=secret_key="$secret_key" \
      --from-literal=postgresql_password="$db_password"
  fi

  if ! kubectl -n authentik get secret authentik-postgresql >/dev/null 2>&1; then
    kubectl -n authentik create secret generic authentik-postgresql \
      --from-literal=password="$db_password"
  fi

  if ! kubectl -n authentik get secret authentik-bootstrap >/dev/null 2>&1; then
    kubectl -n authentik create secret generic authentik-bootstrap \
      --from-literal=bootstrap_password="$bootstrap_password" \
      --from-literal=bootstrap_token="$bootstrap_token" \
      --from-literal=bootstrap_email="$bootstrap_email"
  fi
}

if ! command -v k3s >/dev/null 2>&1; then
  curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--disable traefik" sh -s -
fi

export KUBECONFIG=${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}

ensure_terraform
ensure_authentik_secrets

kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"

# Wait briefly for Argo CD API server to come up (best-effort)
kubectl -n argocd rollout status deploy/argocd-server --timeout=180s || true

# Apply root app only when secrets are present
kubectl apply -f bootstrap/root-app.yaml
