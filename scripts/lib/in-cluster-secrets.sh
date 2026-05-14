#!/usr/bin/env bash

SECRET_GENERATOR_IMAGE=${SECRET_GENERATOR_IMAGE:-curlimages/curl:8.11.1}
SECRET_GENERATOR_TIMEOUT=${SECRET_GENERATOR_TIMEOUT:-180s}
GENERATED_SECRET_CREATED=0

ensure_namespace() {
  local namespace=$1
  kubectl create namespace "$namespace" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
}

indent_block() {
  sed 's/^/                /'
}

safe_name() {
  printf '%s' "$1" | tr '[:upper:]_' '[:lower:]-' | tr -c 'a-z0-9-' '-' | sed -E 's/^-+//; s/-+$//; s/-+/-/g' | cut -c1-48
}

cleanup_generated_secret_job() {
  local namespace=$1
  local job_name=$2
  local role_name=$3
  local binding_name=$4
  local service_account=$5

  kubectl -n "$namespace" delete job "$job_name" --ignore-not-found >/dev/null 2>&1 || true
  kubectl -n "$namespace" delete rolebinding "$binding_name" --ignore-not-found >/dev/null 2>&1 || true
  kubectl -n "$namespace" delete role "$role_name" --ignore-not-found >/dev/null 2>&1 || true
  kubectl -n "$namespace" delete serviceaccount "$service_account" --ignore-not-found >/dev/null 2>&1 || true
}

ensure_generated_secret() {
  local namespace=$1
  local secret_name=$2
  shift 2

  local literal_values=""
  local generated_values=""

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --literal)
        literal_values="${literal_values}${2}"$'\n'
        shift 2
        ;;
      --hex)
        generated_values="${generated_values}${2}=hex:${3}"$'\n'
        shift 3
        ;;
      --base64)
        generated_values="${generated_values}${2}=base64:${3}"$'\n'
        shift 3
        ;;
      *)
        echo "unknown ensure_generated_secret option: $1" >&2
        return 2
        ;;
    esac
  done

  GENERATED_SECRET_CREATED=0
  ensure_namespace "$namespace"

  if kubectl -n "$namespace" get secret "$secret_name" >/dev/null 2>&1; then
    echo "$namespace/$secret_name already exists; leaving it unchanged."
    return 0
  fi

  local suffix
  suffix=$(safe_name "$secret_name")
  local service_account="secret-generator-${suffix}"
  local role_name="secret-generator-${suffix}"
  local binding_name="secret-generator-${suffix}"
  local job_name="secret-generator-${suffix}"

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
        - name: generate-secret
          image: ${SECRET_GENERATOR_IMAGE}
          imagePullPolicy: IfNotPresent
          env:
            - name: POD_NAMESPACE
              valueFrom:
                fieldRef:
                  fieldPath: metadata.namespace
            - name: SECRET_NAME
              value: ${secret_name}
            - name: LITERAL_VALUES
              value: |-
$(printf '%s' "$literal_values" | indent_block)
            - name: GENERATED_VALUES
              value: |-
$(printf '%s' "$generated_values" | indent_block)
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
                    echo "Kubernetes API returned HTTP \$code while creating \$SECRET_NAME" >&2
                    cat "\$response" >&2 || true
                    exit 1
                    ;;
                esac
                rm -f "\$response"
              }

              payload=\$(mktemp)
              trap 'rm -f "\$payload"' EXIT
              {
                printf '{"apiVersion":"v1","kind":"Secret","metadata":'
                printf '{"name":"%s","namespace":"%s"},' "\$SECRET_NAME" "\$POD_NAMESPACE"
                printf '"type":"Opaque","data":{'
              } > "\$payload"

              first=1
              old_ifs=\$IFS
              IFS=\$(printf '\n_')
              IFS=\${IFS%_}
              for line in \$LITERAL_VALUES; do
                [ -n "\$line" ] || continue
                key=\${line%%=*}
                value=\${line#*=}
                emit_data "\$key" "\$value"
              done

              for line in \$GENERATED_VALUES; do
                [ -n "\$line" ] || continue
                key=\${line%%=*}
                spec=\${line#*=}
                kind=\${spec%%:*}
                bytes=\${spec#*:}
                case "\$kind" in
                  hex)
                    value=\$(rand_hex "\$bytes")
                    ;;
                  base64)
                    value=\$(rand_base64 "\$bytes")
                    ;;
                  *)
                    echo "unknown generated secret kind: \$kind" >&2
                    exit 1
                    ;;
                esac
                emit_data "\$key" "\$value"
              done
              IFS=\$old_ifs

              printf '}}\n' >> "\$payload"
              post_secret
EOF

  if ! kubectl -n "$namespace" wait --for=condition=complete "job/$job_name" --timeout="$SECRET_GENERATOR_TIMEOUT" >/dev/null; then
    kubectl -n "$namespace" logs "job/$job_name" >&2 || true
    cleanup_generated_secret_job "$namespace" "$job_name" "$role_name" "$binding_name" "$service_account"
    return 1
  fi

  cleanup_generated_secret_job "$namespace" "$job_name" "$role_name" "$binding_name" "$service_account"
  GENERATED_SECRET_CREATED=1
  echo "Created $namespace/$secret_name from inside the cluster."
}
