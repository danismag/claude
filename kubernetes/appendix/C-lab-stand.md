# Приложение C. Стенд курса: запуск, ресурсы, расширения, сброс

> Сводка для повторного прохождения и восстановления стенда. Подробности — 00-1.

---

## C.0. Включить и выключить

Стенд не нужно держать запущенным. Включайте перед лабой, выключайте после.

**Включить** (из корня репозитория; первый запуск ~2 мин, повторный — ~1 мин):

```bash
cd ~/ai/runbooks
bash kubernetes/lab/lab-up.sh        # ждать «== готово»; контекст переключится на kind-lab
kubectl get nodes                    # 4 × Ready
curl -s -o /dev/null -w '%{http_code}\n' http://orders.localhost:8088/api/orders   # 200 после 02-x
```

**Выключить** (данные сохраняются):

```bash
bash kubernetes/lab/lab-down.sh      # docker stop узлов и реестра: etcd, PVC (local-path), образы в узлах остаются
```

**Удалить полностью:**

```bash
bash kubernetes/lab/lab-down.sh --purge   # кластер, реестр, том kind-registry-data и ~/lab/k8s
```

Что важно:
- После `docker start` узлов apiserver поднимается не сразу — `lab-up.sh` ждёт `/readyz`. Ручной `docker start` — подождите ~30 с.
- После перезапуска Docker узлы kind могут получить **другие IP** в сети `kind`. etcd и apiserver сертифицированы на старый адрес. Обычно kind справляется сам, но `kubeadm upgrade` на стенде падал из-за etcd-сертификатов со старым IP — перевыпуск `kubeadm init phase certs etcd-server/etcd-peer` (10-2).
- `~/lab/k8s` хранит исходники orders-api, chart'ы, kustomize и GitOps-репозиторий. Без него лабы 07–08 придётся воссоздавать по тексту частей.

## C.1. Топология и адреса

```
хост (Manjaro/Ubuntu, Docker 29)
├─ 127.0.0.1:<порт> → lab-control-plane:6443   apiserver, etcd, scheduler, controller-manager (static pods)
├─ 127.0.0.1:8088   → lab-control-plane:30080  NodePort → Envoy (Gateway lab, ns envoy-gateway-system)
├─ 127.0.0.1:5001   → kind-registry:5000       registry:2.8.3, том kind-registry-data
└─ docker-сеть kind
   ├─ lab-control-plane
   ├─ lab-worker, lab-worker2, lab-worker3   kubelet, containerd 2.3.1, kube-proxy (iptables), kindnet
   └─ kind-registry
```

| Что | Значение |
|---|---|
| Kubernetes | `lab-up.sh` создаёт **v1.36.1**; в 10-2 стенд обновлён до **v1.36.5** — обе версии подходят для всех лаб |
| Pod CIDR / Service CIDR | 10.244.0.0/16 / 10.96.0.0/12; kube-dns 10.96.0.10 |
| StorageClass | `standard` (local-path, `WaitForFirstConsumer`) |
| Дополнения `lab-up.sh` | metrics-server v0.8.0 (`--kubelet-insecure-tls`), Envoy Gateway 1.9.2 + CRD Gateway API, `externalTrafficPolicy: Cluster` |
| Сквозной сценарий | ns `orders`: Deployment orders-api 2.0 (2 реплики), StatefulSet postgres 17.6, HTTPRoute `orders.localhost` |
| Образы в реестре | `localhost:5001/orders-api:2.0`, `:2.1` |
| Контекст | `kind-lab` в `~/.kube/config` (или в `$KUBECONFIG`) |

## C.2. Ресурсы

| Состояние | RAM | Диск |
|---|---|---|
| Базовый стенд + orders (замер `docker stats`) | ~2,6 ГБ: control-plane 1,16 ГБ, workers 0,3–0,6 ГБ | ~3 ГБ образы + слой узлов |
| С Argo CD + Gitea (08) | +~1,5 ГБ ⚠️ оценка | +~1 ГБ |
| С CNPG 3 экземпляра (09-1) | +~0,8 ГБ ⚠️ оценка | +~0,9 ГБ образы (`postgresql:17.6` — 762 МБ) |

Диск: держите ≥ 10 ГБ свободного места на разделе с `/var/lib/docker`. Освободить место:
- образы, загруженные в узлы `kind load`, удаляются только по имени: `docker exec lab-worker crictl rmi <image>`; `crictl rmi --prune` их не трогает;
- образы, скачанные узлами, — `crictl rmi --prune`;
- на хосте — `docker image prune` для своих образов, после проверки.

## C.3. Расширения по частям

Лабы ставят компоненты командами в начале и удаляют их в конце. Стенд при этом не меняется.

| Часть | Что ставится | Версия | Удаляется в конце |
|---|---|---|---|
| 03-4 | cert-manager (`enableGatewayAPI: true`) | v1.21.2 | да |
| 05-3 | KEDA | 2.21.0 | да |
| 07-2 | Bitnami PostgreSQL chart | 18.12.4 | да |
| 08-1, 08-2 | Argo CD, Gitea | v3.5.5, 1.27.0 | да (после 08-2) |
| 09-1 | CloudNativePG | 1.30.1 | да |
| 09-2 | тестовые вебхуки | — | да |
| 10-2 | обновление кластера | 1.36.1 → 1.36.5 | нет — стенд остаётся на 1.36.5 |
| 10-3 | продление сертификатов, drain/reboot | — | состояние стенда то же |

Загрузка образов. Если реестр отвечает медленно или ограничивает частоту (ghcr.io, ECR Public, registry.k8s.io): `docker pull` на хосте, затем `kind load docker-image <образ> --name lab`. Так в курсе ставились CNPG и coredns для обновления.

## C.4. Сброс в исходное состояние

**Мягкий** — вернуть orders, если лаба оставила следы:

```bash
kubectl get ns | grep lab-                                  # недоудалённые namespace лаб
kubectl -n orders get networkpolicy                         # пусто
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name} {.spec.taints}{"\n"}{end}'   # нет посторонних taints
kubectl apply -f ~/lab/k8s/orders-api/k8s/                  # манифесты orders из 02-x
```

**Полный**:

```bash
bash kubernetes/lab/lab-down.sh --purge
bash kubernetes/lab/lab-up.sh
# затем 00-1 §4 — сборка orders-api 2.0/2.1, push в localhost:5001, манифесты orders
```

## C.5. Работа с несколькими кластерами

Скрипт переключает текущий контекст на `kind-lab`. Если рядом рабочие кластеры:

```bash
export KUBECONFIG=~/lab/k8s/kubeconfig     # до lab-up.sh — стенд в отдельном файле
kubectl config current-context             # перед каждой опасной командой
```

## C.6. Особенности стенда, которые встречаются в лабах

| Особенность | Где проявилось | Что делать |
|---|---|---|
| `/tmp` в узлах — noexec | 10-2 | запускать бинарники из других каталогов |
| kind отключает дисковые пороги eviction (`evictionHard … 0%`) | 11-3 | DiskPressure на стенде не воспроизводится |
| Envoy — 1 реплика | 11-3 | потеря её узла = полный простой входа; в задании ★ 11-3 — 2 реплики |
| `externalTrafficPolicy: Local` дропает NodePort на узлах без Envoy | 03-4 | на стенде — `Cluster` |
| busybox `nslookup` иначе проходит search-домены | 11-2 | `getent hosts` из образа с glibc |
| kubelet с самоподписанным serving-сертификатом | 00-1, 10-3 | metrics-server с `--kubelet-insecure-tls` |
