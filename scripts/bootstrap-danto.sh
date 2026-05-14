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
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/in-cluster-secrets.sh
source "$SCRIPT_DIR/lib/in-cluster-secrets.sh"

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

ensure_authentik_secrets() {
  ensure_namespace authentik

  local existing_count=0
  kubectl -n authentik get secret authentik-secrets >/dev/null 2>&1 && existing_count=$((existing_count + 1))
  kubectl -n authentik get secret authentik-postgresql >/dev/null 2>&1 && existing_count=$((existing_count + 1))
  kubectl -n authentik get secret authentik-bootstrap >/dev/null 2>&1 && existing_count=$((existing_count + 1))

  if [ "$existing_count" -eq 3 ]; then
    echo "authentik bootstrap secrets already exist; leaving them unchanged."
    return
  fi

  if [ "$existing_count" -gt 0 ]; then
    echo "Partial authentik bootstrap secrets exist; refusing to generate replacements that could desynchronize credentials." >&2
    echo "Ensure authentik-secrets, authentik-postgresql, and authentik-bootstrap all exist, or delete the partial set before first startup." >&2
    exit 1
  fi

  local namespace=authentik
  local service_account=authentik-secret-generator
  local role_name=authentik-secret-generator
  local binding_name=authentik-secret-generator
  local job_name=authentik-secret-generator
  local bootstrap_email=${AUTHENTIK_BOOTSTRAP_EMAIL:-pierce403@gmail.com}

  kubectl -n "$namespace" delete job "$job_name" --ignore-not-found >/dev/null 2>&1 || true

  cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${service_account}
  namespace: ${namespace}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ${role_name}
  namespace: ${namespace}
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["create"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ${binding_name}
  namespace: ${namespace}
subjects:
  - kind: ServiceAccount
    name: ${service_account}
    namespace: ${namespace}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: ${role_name}
---
apiVersion: batch/v1
kind: Job
metadata:
  name: ${job_name}
  namespace: ${namespace}
spec:
  backoffLimit: 1
  ttlSecondsAfterFinished: 300
  template:
    spec:
      restartPolicy: Never
      serviceAccountName: ${service_account}
      containers:
        - name: generate-authentik-secrets
          image: ${SECRET_GENERATOR_IMAGE}
          imagePullPolicy: IfNotPresent
          env:
            - name: POD_NAMESPACE
              valueFrom:
                fieldRef:
                  fieldPath: metadata.namespace
            - name: BOOTSTRAP_EMAIL
              value: ${bootstrap_email}
          command:
            - /bin/sh
            - -ec
            - |
              api_url="https://kubernetes.default.svc/api/v1/namespaces/\$POD_NAMESPACE/secrets"
              api_token=\$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
              api_ca=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt

              rand_hex() {
                od -An -N "\$1" -tx1 /dev/urandom | tr -d ' \n'
              }

              rand_base64() {
                head -c "\$1" /dev/urandom | base64 | tr -d '\n'
              }

              emit_data() {
                key=\$1
                value=\$2
                encoded=\$(printf '%s' "\$value" | base64 | tr -d '\n')
                if [ "\$first" -eq 0 ]; then
                  printf ',' >> "\$payload"
                fi
                printf '"%s":"%s"' "\$key" "\$encoded" >> "\$payload"
                first=0
              }

              post_secret() {
                response=\$(mktemp)
                code=\$(curl -sS \
                  --cacert "\$api_ca" \
                  --header "Authorization: Bearer \$api_token" \
                  --header "Content-Type: application/json" \
                  --data-binary "@\$payload" \
                  --output "\$response" \
                  --write-out "%{http_code}" \
                  "\$api_url")
                case "\$code" in
                  200|201)
                    ;;
                  *)
                    echo "Kubernetes API returned HTTP \$code while creating a bootstrap secret" >&2
                    cat "\$response" >&2 || true
                    exit 1
                    ;;
                esac
                rm -f "\$response"
              }

              create_secret() {
                name=\$1
                shift
                payload=\$(mktemp)
                trap 'rm -f "\$payload"' EXIT
                {
                  printf '{"apiVersion":"v1","kind":"Secret","metadata":'
                  printf '{"name":"%s","namespace":"%s"},' "\$name" "\$POD_NAMESPACE"
                  printf '"type":"Opaque","data":{'
                } > "\$payload"
                first=1
                for pair in "\$@"; do
                  key=\${pair%%=*}
                  value=\${pair#*=}
                  emit_data "\$key" "\$value"
                done
                printf '}}\n' >> "\$payload"
                post_secret
                rm -f "\$payload"
                trap - EXIT
              }

              secret_key=\$(rand_hex 32)
              db_password=\$(rand_hex 24)
              bootstrap_password=\$(rand_base64 24)
              bootstrap_token=\$(rand_hex 32)
              bootstrap_email=\$BOOTSTRAP_EMAIL

              create_secret authentik-secrets \
                "secret_key=\$secret_key" \
                "postgresql_password=\$db_password"
              create_secret authentik-postgresql \
                "password=\$db_password"
              create_secret authentik-bootstrap \
                "bootstrap_password=\$bootstrap_password" \
                "bootstrap_token=\$bootstrap_token" \
                "bootstrap_email=\$bootstrap_email"
EOF

  if ! kubectl -n "$namespace" wait --for=condition=complete "job/$job_name" --timeout="$SECRET_GENERATOR_TIMEOUT" >/dev/null; then
    kubectl -n "$namespace" logs "job/$job_name" >&2 || true
    cleanup_generated_secret_job "$namespace" "$job_name" "$role_name" "$binding_name" "$service_account"
    return 1
  fi

  cleanup_generated_secret_job "$namespace" "$job_name" "$role_name" "$binding_name" "$service_account"
  echo "Created missing authentik bootstrap secrets from inside the cluster."
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
