#!/usr/bin/env bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root on danto." >&2
  exit 1
fi

APPLY=0
DELETE_ORIGINALS=0
MIGRATE_DOCKER=1
MIGRATE_K3S=1

DOCKER_DATA_ROOT=${DOCKER_DATA_ROOT:-/srv/docker}
K3S_DATA_DIR=${K3S_DATA_DIR:-/srv/k3s/data}
LOCAL_PATH_STORAGE_DIR=${LOCAL_PATH_STORAGE_DIR:-/srv/k3s/storage}

usage() {
  cat <<EOF
Usage: $0 [--apply] [--delete-originals] [--docker-only|--k3s-only]

Migrates heavy runtime state from /var/lib onto /srv:
  Docker: /var/lib/docker -> ${DOCKER_DATA_ROOT}
  k3s:    /var/lib/rancher/k3s -> ${K3S_DATA_DIR}

By default this is a dry run. Use --apply to stop services, copy data,
repoint services, and restart them. Use --delete-originals only after the
services restart successfully; this is what actually frees root disk space.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --apply)
      APPLY=1
      ;;
    --delete-originals)
      DELETE_ORIGINALS=1
      ;;
    --docker-only)
      MIGRATE_DOCKER=1
      MIGRATE_K3S=0
      ;;
    --k3s-only)
      MIGRATE_DOCKER=0
      MIGRATE_K3S=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

run() {
  echo "+ $*"
  if [ "$APPLY" -eq 1 ]; then
    "$@"
  fi
}

ensure_parent() {
  run mkdir -p "$(dirname "$1")"
}

copy_tree() {
  local source=$1
  local target=$2

  if [ ! -d "$source" ]; then
    echo "Skipping missing source: $source"
    return
  fi
  if [ -e "$target" ] && [ ! -d "$target" ]; then
    echo "Target exists and is not a directory: $target" >&2
    exit 1
  fi

  ensure_parent "$target"
  run mkdir -p "$target"
  run rsync -aHAXS --numeric-ids "${source}/" "${target}/"
}

merge_docker_daemon_json() {
  local data_root=$1
  if [ "$APPLY" -ne 1 ]; then
    echo "+ set /etc/docker/daemon.json data-root to ${data_root}"
    return
  fi

  python3 - "$data_root" <<'PY'
import json
import pathlib
import sys

data_root = sys.argv[1]
path = pathlib.Path("/etc/docker/daemon.json")
data = {}
if path.exists() and path.read_text().strip():
    data = json.loads(path.read_text())
data["data-root"] = data_root
tmp = path.with_suffix(".json.tmp")
tmp.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
tmp.replace(path)
PY
}

set_k3s_data_dir() {
  local data_dir=$1
  local env_file=/etc/systemd/system/k3s.service.env

  if [ "$APPLY" -ne 1 ]; then
    echo "+ set K3S_DATA_DIR=${data_dir} in ${env_file}"
    return
  fi

  touch "$env_file"
  sed -i '/^K3S_DATA_DIR=/d' "$env_file"
  printf 'K3S_DATA_DIR=%s\n' "$data_dir" >>"$env_file"
}

replace_with_symlink() {
  local source=$1
  local target=$2
  local stamp=$3
  local backup="${source}.migrated-${stamp}"

  if [ -L "$source" ]; then
    echo "Source is already a symlink: $source -> $(readlink "$source")"
    return
  fi
  if [ ! -d "$source" ]; then
    echo "Source no longer exists as a directory: $source"
    return
  fi

  run mv "$source" "$backup"
  run ln -s "$target" "$source"

  if [ "$DELETE_ORIGINALS" -eq 1 ]; then
    run rm -rf "$backup"
  else
    echo "Original retained at ${backup}; root disk is not fully freed until it is deleted."
  fi
}

need_cmd rsync
need_cmd python3
need_cmd systemctl

STAMP=$(date +%Y%m%d%H%M%S)

echo "Current disk usage:"
df -h / /srv || true
echo

if [ "$APPLY" -eq 1 ]; then
  if [ "$MIGRATE_K3S" -eq 1 ]; then
    run systemctl stop k3s
  fi
  if [ "$MIGRATE_DOCKER" -eq 1 ]; then
    run systemctl stop docker
  fi
fi

if [ "$MIGRATE_K3S" -eq 1 ]; then
  echo "k3s migration:"
  copy_tree /var/lib/rancher/k3s "$K3S_DATA_DIR"
fi

if [ "$MIGRATE_DOCKER" -eq 1 ]; then
  echo "Docker migration:"
  copy_tree /var/lib/docker "$DOCKER_DATA_ROOT"
fi

if [ "$APPLY" -ne 1 ]; then
  echo
  echo "Dry run complete. Re-run with --apply to migrate."
  echo "Add --delete-originals after reviewing the plan if you want to free root disk in the same run."
  exit 0
fi

if [ "$MIGRATE_K3S" -eq 1 ]; then
  set_k3s_data_dir "$K3S_DATA_DIR"
  run mkdir -p "$LOCAL_PATH_STORAGE_DIR"
  replace_with_symlink /var/lib/rancher/k3s "$K3S_DATA_DIR" "$STAMP"
fi

if [ "$MIGRATE_DOCKER" -eq 1 ]; then
  merge_docker_daemon_json "$DOCKER_DATA_ROOT"
  replace_with_symlink /var/lib/docker "$DOCKER_DATA_ROOT" "$STAMP"
fi

run systemctl daemon-reload

if [ "$MIGRATE_DOCKER" -eq 1 ]; then
  run systemctl start docker
fi
if [ "$MIGRATE_K3S" -eq 1 ]; then
  run systemctl start k3s
fi

echo
echo "Post-migration checks:"
df -h / /srv || true
systemctl is-active docker 2>/dev/null || true
systemctl is-active k3s 2>/dev/null || true
if command -v kubectl >/dev/null 2>&1 && [ -r /etc/rancher/k3s/k3s.yaml ]; then
  KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl get nodes || true
fi
