#!/usr/bin/env bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root (sudo) so k3s and kubectl can access /etc/rancher/k3s/k3s.yaml" >&2
  exit 1
fi

ARGOCD_VERSION=${ARGOCD_VERSION:-v2.12.6}
TERRAFORM_MIN_VERSION=${TERRAFORM_MIN_VERSION:-1.5.0}
K3S_DATA_DIR=${K3S_DATA_DIR:-/srv/k3s/data}
LOCAL_PATH_STORAGE_DIR=${LOCAL_PATH_STORAGE_DIR:-/srv/k3s/storage}

configure_host_resolver() {
  if [ -L /etc/resolv.conf ] \
    && [ "$(readlink -f /etc/resolv.conf)" = "/run/systemd/resolve/stub-resolv.conf" ] \
    && [ -f /run/systemd/resolve/resolv.conf ]; then
    echo "Pointing /etc/resolv.conf at /run/systemd/resolve/resolv.conf so host image pulls bypass the local DNS stub."
    ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
  fi
}

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
    bootstrap_email="pierce403@gmail.com"
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

configure_local_path_storage() {
  mkdir -p "$K3S_DATA_DIR"
  mkdir -p "$LOCAL_PATH_STORAGE_DIR"

  if ! kubectl -n kube-system get configmap local-path-config >/dev/null 2>&1; then
    echo "local-path-config not found; skipping local-path storage directory patch." >&2
    return
  fi

  local patch_file
  patch_file=$(mktemp)
  cat >"$patch_file" <<EOF
data:
  config.json: |-
    {
      "nodePathMap":[
      {
        "node":"DEFAULT_PATH_FOR_NON_LISTED_NODES",
        "paths":["${LOCAL_PATH_STORAGE_DIR}"]
      }
      ]
    }
EOF

  if ! kubectl -n kube-system patch configmap local-path-config --type merge --patch-file "$patch_file"; then
    rm -f "$patch_file"
    return 1
  fi
  rm -f "$patch_file"
}

if ! command -v k3s >/dev/null 2>&1; then
  configure_host_resolver
  curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--disable traefik --write-kubeconfig-mode 644 --data-dir ${K3S_DATA_DIR}" sh -s -
fi

export KUBECONFIG=${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}

configure_host_resolver
configure_local_path_storage
ensure_terraform
ensure_authentik_secrets

kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"

# Wait briefly for Argo CD API server to come up (best-effort)
kubectl -n argocd rollout status deploy/argocd-server --timeout=180s || true

# Apply root app only when secrets are present
kubectl apply -f bootstrap/root-app.yaml
