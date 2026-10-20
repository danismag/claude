#!/usr/bin/env bash
# Стенд курса kubernetes. Запуск: bash kubernetes/lab/lab-up.sh   (повторный запуск безопасен — шаги идемпотентны)
# Уборка: bash kubernetes/lab/lab-down.sh [--purge]
#
# Топология (всё — контейнеры Docker в сети kind на одной машине):
#
#   хост
#   127.0.0.1:6443x ─────► lab-control-plane   kube-apiserver, etcd, scheduler, controller-manager (static pods)
#   127.0.0.1:8088  ─────►   :30080 NodePort ─► Envoy Gateway (Gateway "lab", namespace envoy-gateway-system)
#                          lab-worker            kubelet + containerd, kube-proxy (iptables), kindnet (CNI)
#                          lab-worker2           — «/ 3 рабочих узла
#                          lab-worker3           —
#   127.0.0.1:5001  ─────► kind-registry   registry:2.8.3 — образы стенда (localhost:5001/... на хосте и в узлах)
#
#   Дополнения: metrics-server (kubectl top, HPA), local-path-provisioner (StorageClass standard, встроен в kind),
#   Envoy Gateway + CRD Gateway API.
#   kubeconfig: контекст kind-lab в ~/.kube/config (или в $KUBECONFIG). Файлы стенда: ~/lab/k8s.
# Ресурсы: ~2,5 ГБ RAM на пустом стенде, ~3 ГБ диска под образы.
set -euo pipefail

LAB=${LAB:-$HOME/lab/k8s}
CLUSTER=lab
NODE_IMAGE=kindest/node:v1.36.1
REG_NAME=kind-registry
REG_PORT=5001
REG_IMAGE=registry:2.8.3
METRICS_VERSION=v0.8.0
EG_VERSION=1.9.2

log() { printf '\n== %s\n' "$*"; }
mkdir -p "$LAB"

log "реестр $REG_NAME → 127.0.0.1:$REG_PORT"
if [ "$(docker inspect -f '{{.State.Running}}' $REG_NAME 2>/dev/null || true)" != true ]; then
  docker rm -f $REG_NAME >/dev/null 2>&1 || true
  docker run -d --restart=always --name $REG_NAME -p 127.0.0.1:$REG_PORT:5000 -v kind-registry-data:/var/lib/registry $REG_IMAGE >/dev/null
fi

log "кластер kind $CLUSTER (1 control-plane + 3 worker, $NODE_IMAGE)"
cat > "$LAB/kind.yaml" <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: $CLUSTER
containerdConfigPatches:
- |-
  [plugins."io.containerd.cri.v1.images".registry]
    config_path = "/etc/containerd/certs.d"
nodes:
- role: control-plane
  extraPortMappings:
  - {containerPort: 30080, hostPort: 8088, listenAddress: "127.0.0.1"}   # Gateway (NodePort 30080)
- role: worker
- role: worker
- role: worker
EOF
if ! kind get clusters 2>/dev/null | grep -qx $CLUSTER; then
  kind create cluster --config "$LAB/kind.yaml" --image $NODE_IMAGE --wait 120s
else
  # после перезагрузки машины контейнеры узлов могут быть остановлены
  for n in $(kind get nodes --name $CLUSTER); do docker start "$n" >/dev/null; done
fi
kubectl config use-context kind-$CLUSTER >/dev/null
for i in $(seq 1 60); do kubectl get --raw /readyz >/dev/null 2>&1 && break; sleep 2; done   # apiserver после docker start
kubectl wait --for=condition=Ready node --all --timeout=180s

log "узлы видят реестр как localhost:$REG_PORT"
docker network connect kind $REG_NAME 2>/dev/null || true
for n in $(kind get nodes --name $CLUSTER); do
  docker exec -i "$n" sh -c "mkdir -p /etc/containerd/certs.d/localhost:$REG_PORT && cat > /etc/containerd/certs.d/localhost:$REG_PORT/hosts.toml" <<EOF
[host."http://$REG_NAME:5000"]
EOF
done
kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: ConfigMap
metadata: {name: local-registry-hosting, namespace: kube-public}
data:
  localRegistryHosting.v1: |
    host: "localhost:$REG_PORT"
EOF

log "metrics-server $METRICS_VERSION"
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/download/$METRICS_VERSION/components.yaml >/dev/null
# в kind у kubelet самоподписанный сертификат — без этого флага metrics-server не соберёт метрики
if ! kubectl -n kube-system get deploy metrics-server -o jsonpath='{.spec.template.spec.containers[0].args}' | grep -q kubelet-insecure-tls; then
  kubectl -n kube-system patch deploy metrics-server --type=json \
    -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]' >/dev/null
fi
kubectl -n kube-system rollout status deploy/metrics-server --timeout=180s

log "Envoy Gateway $EG_VERSION (+ CRD Gateway API)"
helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm --version $EG_VERSION \
  -n envoy-gateway-system --create-namespace --wait --timeout 5m >/dev/null
kubectl apply -f - >/dev/null <<'EOF'
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: EnvoyProxy
metadata: {name: nodeport, namespace: envoy-gateway-system}
spec:
  provider:
    type: Kubernetes
    kubernetes:
      envoyService:
        type: NodePort
        # по умолчанию Envoy Gateway ставит Local: трафик на узел без пода Envoy отбрасывается (03-2)
        externalTrafficPolicy: Cluster
        patch:
          type: StrategicMerge
          value:
            spec:
              ports:
              - {port: 80, nodePort: 30080}
---
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata: {name: eg}
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
  parametersRef: {group: gateway.envoyproxy.io, kind: EnvoyProxy, name: nodeport, namespace: envoy-gateway-system}
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata: {name: lab, namespace: envoy-gateway-system}
spec:
  gatewayClassName: eg
  listeners:
  - name: http
    protocol: HTTP
    port: 80
    allowedRoutes: {namespaces: {from: All}}
EOF
kubectl -n envoy-gateway-system wait --for=condition=Programmed gateway/lab --timeout=180s

log "готово"
kubectl get nodes
cat <<EOF

Контекст: kind-$CLUSTER · реестр: localhost:$REG_PORT · вход: http://<имя>.localhost:8088 (Gateway lab)
Дальше: orders-api по 00-1 §4 (сборка, push в localhost:$REG_PORT, манифесты в namespace orders).
EOF
