#!/usr/bin/env bash
set -euo pipefail

DOMAIN=${DOMAIN:-x43.io}
SERVER=${SERVER:-x43ns1.deanpierce.net}

if ! command -v dig >/dev/null 2>&1; then
  echo "dig not found. Install bind-utils/dnsutils to run DNS checks." >&2
  exit 1
fi

query() {
  local name=$1
  local type=$2
  dig @"$SERVER" "$name" "$type" +short +norecurse
}

expect_line() {
  local label=$1
  local expected=$2
  local actual=$3

  if printf '%s\n' "$actual" | grep -Fx "$expected" >/dev/null 2>&1; then
    echo "$label -> ok"
  else
    echo "$label -> expected '$expected', got:" >&2
    printf '%s\n' "$actual" >&2
    exit 1
  fi
}

echo "Checking authoritative DNS at $SERVER for $DOMAIN"

soa=$(query "$DOMAIN" SOA)
expect_line "SOA" "x43ns1.deanpierce.net. admin.x43.io. 2026051601 1800 900 604800 300" "$soa"

ns=$(query "$DOMAIN" NS)
expect_line "NS x43ns1" "x43ns1.deanpierce.net." "$ns"
expect_line "NS x43ns2" "x43ns2.deanpierce.net." "$ns"

danto=$(query "danto.$DOMAIN" A)
if [ -z "$danto" ]; then
  echo "danto.$DOMAIN A -> no answer" >&2
  exit 1
fi
echo "danto.$DOMAIN A -> $danto"

danto_prefix=${danto%.*}
expect_line "argus.$DOMAIN A" "$danto_prefix.251" "$(query "argus.$DOMAIN" A)"
expect_line "majin.$DOMAIN A" "$danto_prefix.252" "$(query "majin.$DOMAIN" A)"
expect_line "nweb.$DOMAIN A" "$danto_prefix.253" "$(query "nweb.$DOMAIN" A)"

test_record=$(query "test.$DOMAIN" A)
expect_line "test.$DOMAIN A" "6.6.6.6" "$test_record"

for host in auth argo chat drive grafana mesh pad pad-sandbox snap; do
  cname=$(query "$host.$DOMAIN" CNAME)
  expect_line "$host.$DOMAIN CNAME" "danto.$DOMAIN." "$cname"
done

delegation=$(dig "$DOMAIN" NS +short || true)
if [ -n "$delegation" ]; then
  expect_line "delegation x43ns1" "x43ns1.deanpierce.net." "$delegation"
  expect_line "delegation x43ns2" "x43ns2.deanpierce.net." "$delegation"
else
  echo "delegation check -> no recursive answer yet"
fi
