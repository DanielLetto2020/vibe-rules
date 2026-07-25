#!/usr/bin/env bash
# Проверка манифестов до применения. Ставится в CI как блокирующий гейт.
#   kubeconform  — соответствие схемам API Kubernetes
#   kube-linter  — типовые ошибки безопасности и надёжности
set -euo pipefail
DIR="${1:-k8s}"
echo "▸ схемы (kubeconform)"
kubeconform -strict -summary -ignore-missing-schemas "$DIR"
echo "▸ безопасность и надёжность (kube-linter)"
kube-linter lint "$DIR"
