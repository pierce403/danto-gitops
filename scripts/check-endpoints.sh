#!/usr/bin/env bash
set -euo pipefail

URLS=(
  "https://argo.x43.io/"
  "https://mesh.x43.io/"
)

for url in "${URLS[@]}"; do
  code=$(curl -sS -o /dev/null -w '%{http_code}' "$url" || true)
  if [ "$code" = "200" ] || [ "$code" = "302" ] || [ "$code" = "401" ]; then
    echo "$url -> $code"
  else
    echo "$url -> $code (unexpected)" >&2
    exit 1
  fi
done
