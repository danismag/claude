#!/usr/bin/env bash
# Уборка стенда курса kubernetes (топология — в lab-up.sh).
# Запуск: bash kubernetes/lab/lab-down.sh           — остановить узлы kind и реестр, всё состояние сохранить
#         bash kubernetes/lab/lab-down.sh --purge   — удалить кластер, реестр с образами (том kind-registry-data) и ~/lab/k8s
set -uo pipefail
LAB=${LAB:-$HOME/lab/k8s}
CLUSTER=lab

if [ "${1:-}" = --purge ]; then
  kind delete cluster --name $CLUSTER
  docker rm -f kind-registry >/dev/null 2>&1
  docker volume rm kind-registry-data >/dev/null 2>&1
  rm -rf "$LAB"
  echo "кластер $CLUSTER, реестр kind-registry, том kind-registry-data и $LAB удалены"
else
  # docker stop сохраняет etcd, PVC (local-path) и образы в узлах; lab-up.sh запустит их снова
  for n in $(kind get nodes --name $CLUSTER 2>/dev/null); do docker stop "$n" >/dev/null; done
  docker stop kind-registry >/dev/null 2>&1
  echo "узлы kind и реестр остановлены, данные сохранены — запуск: bash kubernetes/lab/lab-up.sh"
fi
