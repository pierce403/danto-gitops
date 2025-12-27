#!/usr/bin/env bash
set -euo pipefail

kubectl get nodes -o wide
kubectl -n argocd get applications
kubectl -n argocd get appprojects
kubectl -n argocd get pods
