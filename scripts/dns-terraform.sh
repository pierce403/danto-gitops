#!/usr/bin/env bash
set -euo pipefail

if [ -f .env.dns ]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env.dns
  set +a
fi

if ! command -v terraform >/dev/null 2>&1; then
  echo "terraform not found. Run this script on a machine with terraform installed." >&2
  exit 1
fi

missing=()
for name in NAMECHEAP_USER_NAME NAMECHEAP_API_USER NAMECHEAP_API_KEY NAMECHEAP_CLIENT_IP DANTO_IPV4; do
  if [ -z "${!name:-}" ]; then
    missing+=("$name")
  fi
done

if [ "${#missing[@]}" -gt 0 ]; then
  cat >&2 <<MSG
Missing required DNS environment variables:
  ${missing[*]}

Set them in the environment or in a local .env.dns file.
Namecheap API also requires NAMECHEAP_CLIENT_IP to be whitelisted in the Namecheap dashboard.
MSG
  exit 1
fi

export TF_VAR_danto_ipv4="$DANTO_IPV4"

cd clusters/danto/dns/namecheap
terraform init
terraform apply
