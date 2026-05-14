#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/in-cluster-secrets.sh
source "$SCRIPT_DIR/lib/in-cluster-secrets.sh"

NAMESPACE=${NAMESPACE:-argocd}
WEBHOOK_SECRET_NAME=${WEBHOOK_SECRET_NAME:-argocd-github-webhook}
PATCH_JOB_NAME=${PATCH_JOB_NAME:-argocd-webhook-secret-patch}
SETUP_TOKEN_SECRET_NAME=${SETUP_TOKEN_SECRET_NAME:-github-webhook-setup-token}
SETUP_JOB_NAME=${SETUP_JOB_NAME:-github-webhook-setup}
GITHUB_REPOSITORY=${GITHUB_REPOSITORY:-pierce403/danto-gitops}
WEBHOOK_URL=${WEBHOOK_URL:-https://argo.x43.io/api/webhook}
GITHUB_WEBHOOK_SETUP_IMAGE=${GITHUB_WEBHOOK_SETUP_IMAGE:-python:3.12-alpine}
CONFIGURE_GITHUB=0
ROTATE=0

usage() {
  cat <<'USAGE'
Usage: configure-github-webhook.sh [--github] [--rotate]

Generate Argo CD's GitHub webhook shared secret inside the cluster and copy it
into argocd-secret from an in-cluster Job. With --github, also create/update
the GitHub webhook using a temporary GITHUB_TOKEN.

Environment:
  GITHUB_TOKEN       Temporary token with repository webhook write permission
  GITHUB_REPOSITORY  owner/repo (default: pierce403/danto-gitops)
  WEBHOOK_URL        GitHub webhook payload URL (default: https://argo.x43.io/api/webhook)
  GITHUB_WEBHOOK_SETUP_IMAGE
                     Image for the one-time GitHub API Job (default: python:3.12-alpine)

Options:
  --github  Create/update the GitHub webhook from an in-cluster one-time Job
  --rotate  Delete and regenerate the cluster webhook secret before configuring
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --github)
      CONFIGURE_GITHUB=1
      ;;
    --rotate)
      ROTATE=1
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

if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl not found. This script requires kubectl access to the cluster." >&2
  exit 1
fi

cleanup_argocd_patch_job() {
  kubectl -n "$NAMESPACE" delete job "$PATCH_JOB_NAME" --ignore-not-found >/dev/null 2>&1 || true
  kubectl -n "$NAMESPACE" delete rolebinding "$PATCH_JOB_NAME" --ignore-not-found >/dev/null 2>&1 || true
  kubectl -n "$NAMESPACE" delete role "$PATCH_JOB_NAME" --ignore-not-found >/dev/null 2>&1 || true
  kubectl -n "$NAMESPACE" delete serviceaccount "$PATCH_JOB_NAME" --ignore-not-found >/dev/null 2>&1 || true
}

patch_argocd_webhook_secret() {
  cleanup_argocd_patch_job

  cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${PATCH_JOB_NAME}
  namespace: ${NAMESPACE}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ${PATCH_JOB_NAME}
  namespace: ${NAMESPACE}
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    resourceNames: ["argocd-secret"]
    verbs: ["patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ${PATCH_JOB_NAME}
  namespace: ${NAMESPACE}
subjects:
  - kind: ServiceAccount
    name: ${PATCH_JOB_NAME}
    namespace: ${NAMESPACE}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: ${PATCH_JOB_NAME}
---
apiVersion: batch/v1
kind: Job
metadata:
  name: ${PATCH_JOB_NAME}
  namespace: ${NAMESPACE}
spec:
  backoffLimit: 1
  ttlSecondsAfterFinished: 300
  template:
    spec:
      restartPolicy: Never
      serviceAccountName: ${PATCH_JOB_NAME}
      containers:
        - name: patch-argocd-secret
          image: ${SECRET_GENERATOR_IMAGE}
          imagePullPolicy: IfNotPresent
          env:
            - name: POD_NAMESPACE
              valueFrom:
                fieldRef:
                  fieldPath: metadata.namespace
            - name: WEBHOOK_SECRET
              valueFrom:
                secretKeyRef:
                  name: ${WEBHOOK_SECRET_NAME}
                  key: webhook.github.secret
          command:
            - /bin/sh
            - -ec
            - |
              api_url="https://kubernetes.default.svc/api/v1/namespaces/\$POD_NAMESPACE/secrets/argocd-secret"
              api_token=\$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
              api_ca=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
              encoded=\$(printf '%s' "\$WEBHOOK_SECRET" | base64 | tr -d '\n')
              response=\$(mktemp)
              payload=\$(mktemp)
              trap 'rm -f "\$response" "\$payload"' EXIT

              printf '{"data":{"webhook.github.secret":"%s"}}\n' "\$encoded" > "\$payload"
              code=\$(curl -sS \
                --request PATCH \
                --cacert "\$api_ca" \
                --header "Authorization: Bearer \$api_token" \
                --header "Content-Type: application/merge-patch+json" \
                --data-binary "@\$payload" \
                --output "\$response" \
                --write-out "%{http_code}" \
                "\$api_url")

              case "\$code" in
                200|201)
                  ;;
                *)
                  echo "Kubernetes API returned HTTP \$code while patching argocd-secret" >&2
                  cat "\$response" >&2 || true
                  exit 1
                  ;;
              esac
EOF

  if ! kubectl -n "$NAMESPACE" wait --for=condition=complete "job/$PATCH_JOB_NAME" --timeout="$SECRET_GENERATOR_TIMEOUT" >/dev/null; then
    kubectl -n "$NAMESPACE" logs "job/$PATCH_JOB_NAME" >&2 || true
    cleanup_argocd_patch_job
    return 1
  fi

  cleanup_argocd_patch_job
}

ensure_namespace "$NAMESPACE"

if [ "$ROTATE" -eq 1 ]; then
  kubectl -n "$NAMESPACE" delete secret "$WEBHOOK_SECRET_NAME" --ignore-not-found >/dev/null
fi

ensure_generated_secret "$NAMESPACE" "$WEBHOOK_SECRET_NAME" \
  --hex webhook.github.secret 32

kubectl -n "$NAMESPACE" label secret "$WEBHOOK_SECRET_NAME" \
  app.kubernetes.io/part-of=argocd --overwrite >/dev/null

patch_argocd_webhook_secret

echo "Configured Argo CD to verify GitHub webhooks using an in-cluster generated secret."

if [ "$CONFIGURE_GITHUB" -eq 0 ]; then
  echo "Skipping GitHub webhook setup; rerun with --github and a temporary GITHUB_TOKEN to configure GitHub."
  exit 0
fi

if [ -z "${GITHUB_TOKEN:-}" ]; then
  echo "GITHUB_TOKEN is required with --github. Use a temporary token with repository webhook write permission." >&2
  exit 1
fi

cleanup_github_setup() {
  kubectl -n "$NAMESPACE" delete job "$SETUP_JOB_NAME" --ignore-not-found >/dev/null 2>&1 || true
  kubectl -n "$NAMESPACE" delete secret "$SETUP_TOKEN_SECRET_NAME" --ignore-not-found >/dev/null 2>&1 || true
}

cleanup_github_setup

token_b64=$(printf '%s' "$GITHUB_TOKEN" | base64 | tr -d '\n')
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Secret
metadata:
  name: ${SETUP_TOKEN_SECRET_NAME}
  namespace: ${NAMESPACE}
type: Opaque
data:
  token: ${token_b64}
EOF

cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: batch/v1
kind: Job
metadata:
  name: ${SETUP_JOB_NAME}
  namespace: ${NAMESPACE}
spec:
  backoffLimit: 1
  ttlSecondsAfterFinished: 300
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: setup-github-webhook
          image: ${GITHUB_WEBHOOK_SETUP_IMAGE}
          imagePullPolicy: IfNotPresent
          env:
            - name: GITHUB_TOKEN
              valueFrom:
                secretKeyRef:
                  name: ${SETUP_TOKEN_SECRET_NAME}
                  key: token
            - name: WEBHOOK_SECRET
              valueFrom:
                secretKeyRef:
                  name: ${WEBHOOK_SECRET_NAME}
                  key: webhook.github.secret
            - name: GITHUB_REPOSITORY
              value: ${GITHUB_REPOSITORY}
            - name: WEBHOOK_URL
              value: ${WEBHOOK_URL}
          command:
            - python
            - -c
            - |
              import json
              import os
              import sys
              import urllib.error
              import urllib.request

              token = os.environ["GITHUB_TOKEN"]
              repo = os.environ["GITHUB_REPOSITORY"]
              webhook_url = os.environ["WEBHOOK_URL"]
              webhook_secret = os.environ["WEBHOOK_SECRET"]
              api = f"https://api.github.com/repos/{repo}"
              headers = {
                  "Accept": "application/vnd.github+json",
                  "Authorization": f"Bearer {token}",
                  "User-Agent": "danto-gitops-webhook-setup",
                  "X-GitHub-Api-Version": "2022-11-28",
              }

              def request(method, url, payload=None):
                  data = None
                  request_headers = dict(headers)
                  if payload is not None:
                      data = json.dumps(payload, separators=(",", ":")).encode()
                      request_headers["Content-Type"] = "application/json"
                  req = urllib.request.Request(
                      url,
                      data=data,
                      headers=request_headers,
                      method=method,
                  )
                  try:
                      with urllib.request.urlopen(req, timeout=30) as response:
                          body = response.read().decode()
                          return response.status, json.loads(body) if body else None
                  except urllib.error.HTTPError as exc:
                      body = exc.read().decode()
                      print(
                          f"GitHub API returned HTTP {exc.code} while calling {method} {url}",
                          file=sys.stderr,
                      )
                      if body:
                          print(body, file=sys.stderr)
                      raise

              hooks = []
              page = 1
              while True:
                  _, page_hooks = request("GET", f"{api}/hooks?per_page=100&page={page}")
                  page_hooks = page_hooks or []
                  hooks.extend(page_hooks)
                  if len(page_hooks) < 100:
                      break
                  page += 1

              hook = next(
                  (
                      item
                      for item in hooks
                      if item.get("config", {}).get("url") == webhook_url
                  ),
                  None,
              )
              payload = {
                  "name": "web",
                  "active": True,
                  "events": ["push"],
                  "config": {
                      "url": webhook_url,
                      "content_type": "json",
                      "secret": webhook_secret,
                      "insecure_ssl": "0",
                  },
              }

              if hook:
                  request("PATCH", f"{api}/hooks/{hook['id']}", payload)
                  action = "updated"
              else:
                  request("POST", f"{api}/hooks", payload)
                  action = "created"

              print(f"GitHub webhook {action} for {repo}.")
EOF

if ! kubectl -n "$NAMESPACE" wait --for=condition=complete "job/$SETUP_JOB_NAME" --timeout="$SECRET_GENERATOR_TIMEOUT" >/dev/null; then
  kubectl -n "$NAMESPACE" logs "job/$SETUP_JOB_NAME" >&2 || true
  cleanup_github_setup
  exit 1
fi

kubectl -n "$NAMESPACE" logs "job/$SETUP_JOB_NAME"
cleanup_github_setup
echo "Removed temporary GitHub setup token from the cluster."
