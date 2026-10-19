# 01-2. Узел: kubelet, CRI, CNI, kube-proxy

> Модуль 1 «Архитектура» · часть 2 из 3 · 🟢🟡🔴 · ~1,5 ч чтения + ~1 ч лабы (из них 7 мин — ожидание вытеснения) · Нужно: стенд 00-1

---

## Зачем это DevOps-у

Control plane решает, **где** запустить под; всё остальное делает узел. Когда «под не стартует», «контейнер работает, а под NotReady», «узел флапает» или «после падения узла сервис лёг, хотя БД жива» — разбираться приходится на узле: kubelet, containerd, CNI, cgroups. На собеседовании спрашивают про pause-контейнер, static pods, что такое CRI и CNI, и через сколько поды уедут с упавшего узла — с цифрами.

В сквозном сценарии мы остановим kubelet на узле с PostgreSQL и увидим, что через 53 секунды `curl http://orders.localhost:8088/api/orders` начинает отвечать 503, хотя процесс PostgreSQL продолжает работать.

---

## 1. Что работает на узле 🟢

| Компонент | Как запущен | Что делает |
|---|---|---|
| **kubelet** | systemd-сервис | watch подов своего узла в apiserver; создаёт их через CRI; probes; монтирует тома; пишет status и heartbeat |
| **containerd** (CRI-рантайм) | systemd-сервис | образы, контейнеры, sandbox'ы подов; вызывает runc и CNI |
| **runc** | вызывается containerd | создаёт процесс в namespaces и cgroups (OCI runtime) |
| **CNI-плагины** | бинарники в `/opt/cni/bin`, конфиг в `/etc/cni/net.d` | вызываются при создании sandbox'а: интерфейс, IP, маршруты |
| **kube-proxy** | DaemonSet | правила iptables/nftables/ipvs для Service (03-2) |
| CNI-агент (kindnet, Calico, Cilium) | DaemonSet | раздаёт подсети узлам, маршруты, NetworkPolicy |

Docker в узле Kubernetes не нужен: с 1.24 dockershim удалён, kubelet говорит с рантаймом по **CRI** (gRPC). На стенде — containerd 2.3.1. Образы, собранные Docker'ом, работают — это OCI-образы.

## 2. Под изнутри: pause-контейнер и namespaces 🟢🟡

Под — это **sandbox** (набор общих namespaces) плюс контейнеры в нём. Sandbox держит крошечный процесс `/pause` (образ `registry.k8s.io/pause:3.10` на стенде): он создаёт и удерживает сетевой namespace, пока контейнеры пода перезапускаются.

Проверено на узле (под orders-api):

```
"image": "registry.k8s.io/pause:3.10",
"path": "/var/run/netns/cni-542787ea-dd36-7a95-0fc7-860c6ccbef33",
"ip": "10.244.1.5"

/proc/1616/ns/net -> net:[4026534532]      ← pause
/proc/1643/ns/net -> net:[4026534532]      ← контейнер api: тот же сетевой namespace
/proc/1616/ns/pid -> pid:[4026534597]
/proc/1643/ns/pid -> pid:[4026534599]      ← PID namespace у каждого свой
```

Общее у контейнеров пода: сеть (IP, порты, `localhost`), IPC, тома. Раздельное по умолчанию: PID и файловая система. `shareProcessNamespace: true` даёт общий PID-namespace (тогда PID 1 — pause, и сигналы ведут себя иначе), `kubectl debug --target` подключает отладочный контейнер к PID-namespace одного контейнера (00-2).

Почему pause, а не первый контейнер: если контейнер приложения упал и перезапустился, IP и сетевой namespace остаются — порт-маппинги, правила kube-proxy и endpoints не меняются.

## 3. Путь от binding до Running 🟡

```
apiserver: pod.spec.nodeName = lab-worker3
   │ watch
kubelet: syncPod
   1. admission на узле (хватает ли ресурсов, nodeSelector, taints — «последняя проверка»)
   2. cgroup пода (по QoS-классу, 05-1)
   3. тома: Secret/ConfigMap/PVC — смонтировать, дождаться attach (04-2)
   4. CRI RunPodSandbox → containerd → pause + CNI ADD → IP
   5. pull образов (imagePullPolicy, секреты реестра)
   6. init-контейнеры по очереди, затем sidecar'ы, затем основные (02-1)
   7. probes: startup → readiness/liveness (02-5)
   8. status → apiserver: PodReadyToStartContainers, Initialized, ContainersReady, Ready
```

Ошибки этого пути видны в событиях пода и в его статусе: `FailedMount`, `FailedCreatePodSandBox` (часто — CNI), `ErrImagePull`/`ImagePullBackOff`, `CreateContainerConfigError` (нет ключа в Secret/ConfigMap), `CrashLoopBackOff`. Разбор каждой — 11-1.

Как kubelet узнаёт, что контейнер умер: **PLEG** (Pod Lifecycle Event Generator) периодически сверяет состояние контейнеров с рантаймом (в новых версиях — по событиям CRI). Сообщение `PLEG is not healthy` в логах kubelet и узел NotReady — рантайм не отвечает (перегружен, завис containerd, тысячи мёртвых контейнеров).

## 4. CNI: откуда у пода IP 🟡

При создании sandbox'а containerd вызывает плагины из `/etc/cni/net.d`. На стенде — kindnet (проверено, сокращено):

```json
{ "cniVersion": "0.3.1", "name": "kindnet",
  "plugins": [
    { "type": "ptp", "ipam": { "type": "host-local", "ranges": [[ { "subnet": "10.244.1.0/24" } ]] }, "mtu": 1500 },
    { "type": "portmap", "capabilities": { "portMappings": true } } ] }
```

`ptp` создаёт veth-пару (один конец в netns пода, другой на узле), `host-local` выдаёт IP из подсети узла. Таблица маршрутов узла `lab-worker3` (проверено):

```
default via 172.20.0.1 dev eth0
10.244.0.0/24 via 172.20.0.2 dev eth0       ← подсеть пода на другом узле — через его IP
10.244.1.3 dev vethc3005564 scope host       ← под на этом узле — прямо в veth
10.244.1.5 dev veth6a79cd61 scope host
10.244.2.0/24 via 172.20.0.3 dev eth0
10.244.3.0/24 via 172.20.0.5 dev eth0
```

Модель Kubernetes: каждый под получает IP, поды видят друг друга без NAT. Как именно — дело CNI: маршруты (kindnet, Calico BGP), оверлей (VXLAN, Geneve), eBPF (Cilium). Подробно, с трассировкой пакета — 03-1.

## 5. cgroups узла 🟡

Kubelet с `cgroupDriver: systemd` (проверено) раскладывает поды в slice'ы по QoS-классам. На стенде (`systemd-cgls -u kubelet.slice`, сокращено):

```
kubelet.slice
├─kubelet.service
│ └─222 /usr/bin/kubelet ...
└─kubelet-kubepods.slice
  ├─kubelet-kubepods-pod01b8c840_….slice           ← Guaranteed — прямо в kubepods
  │ ├─cri-containerd-e6f0….scope  └─724 /bin/kindnetd
  │ └─cri-containerd-eec6….scope  └─466 /pause
  ├─kubelet-kubepods-besteffort.slice
  │ └─kubelet-kubepods-besteffort-pode619e41a_….slice
  │   ├─cri-containerd-b7c7….scope  └─480 /pause
  │   └─cri-containerd-906e….scope  └─559 /usr/local/bin/kube-proxy ...
  └─kubelet-kubepods-burstable.slice …
```

Префикс `kubelet-` и вложенность в `kubelet.slice` — особенность kind (kubelet сам в контейнере). На обычном узле: `/sys/fs/cgroup/kubepods.slice/kubepods-burstable.slice/kubepods-burstable-pod<uid>.slice/cri-containerd-<id>.scope`. Драйвер cgroups у kubelet и рантайма **обязан совпадать** (systemd на systemd-дистрибутивах) — иначе под нагрузкой узел становится нестабильным.

## 6. Static pods и mirror pods 🟡

Kubelet на каждом узле следит за каталогом `staticPodPath` (проверено: `/etc/kubernetes/manifests` на всех узлах стенда, не только на control-plane) и запускает поды из файлов — без scheduler'а и без apiserver. В API появляется **mirror pod** с суффиксом имени узла.

Проверено:

| Действие | Результат |
|---|---|
| файл `static-web.yaml` в `/etc/kubernetes/manifests` на `lab-worker2` | через ≤15 с `static-web-lab-worker2 1/1 Running`; аннотация `kubernetes.io/config.source: file`, ownerReference — `Node lab-worker2` |
| `kubectl delete pod static-web-lab-worker2` | mirror pod пересоздан, **контейнер тот же** (`crictl ps`: создан 20 с назад) — удалением через API static pod не убить |
| удалить файл | через ~30 с под исчез и в API, и на узле (kubelet перечитывает каталог раз в 20 с — `fileCheckFrequency`) |

Применение: control plane kubeadm, иногда — агенты, которые должны работать до сети кластера. Опасность: файл в `/etc/kubernetes/manifests` на любом узле — способ запустить под в обход RBAC и admission. Плагин `NodeRestriction` запрещает mirror pod'ам ссылаться на Secret/ConfigMap/ServiceAccount, но сам под с `hostPath` запустится.

## 7. Heartbeat, NotReady и вытеснение 🟡🔴

Kubelet сообщает «я жив» двумя способами:

| Механизм | Частота (проверено, `/configz`) | Зачем |
|---|---|---|
| Lease в `kube-node-lease` | продление каждые ~10 с, `leaseDurationSeconds: 40` | дешёвый heartbeat — маленький объект |
| `node.status` | `nodeStatusUpdateFrequency: 10s` проверка; полная запись при изменении или раз в `nodeStatusReportFrequency: 5m` | условия узла (Ready, MemoryPressure, DiskPressure, PIDPressure), ресурсы, образы |

Node lifecycle controller в controller-manager ждёт `node-monitor-grace-period` (в 1.36 — 50 с; раньше было 40 с) без обновлений и ставит узлу `Ready=Unknown` и taint'ы `node.kubernetes.io/unreachable:NoSchedule` и `:NoExecute`. Каждый под по умолчанию получает toleration к `unreachable:NoExecute` с `tolerationSeconds: 300` — через 5 минут он помечается на удаление, и его контроллер создаёт замену на другом узле.

Замер на стенде (лаба, шаг 5) — остановлен kubelet на `lab-worker`, где работают PostgreSQL и один под `web`:

| t | Что произошло |
|---|---|
| 0 | `systemctl stop kubelet`. Контейнеры узла **продолжают работать** (containerd жив) |
| +53 с | узел `Unknown/NodeStatusUnknown`, taint'ы `unreachable` NoSchedule + NoExecute; у `postgres-0` `Ready=False`, endpoint postgres неготов; сквозной запрос — **503** |
| +353 с | поды узла получили `deletionTimestamp`: `web` → `Terminating`, создан новый `web`; `postgres-0` → `Terminating` и **не пересоздаётся** |
| kubelet вернули | через 8 с `api=200`; Terminating-поды удалены, `postgres-0` создан заново на том же узле (его PV local-path привязан к `lab-worker`), данные на месте |

Три вывода из замера:

1. **Сервис лёг через 53 секунды, хотя ни один процесс не упал.** Endpoint'ы подов на узле `Unknown` помечаются неготовыми; headless Service `postgres` перестал отдавать адрес в DNS, orders-api не смог подключиться к БД и ответил 503 на readiness — оба пода orders-api выпали из Service.
2. **StatefulSet не пересоздаёт под, пока узел не подтвердит его смерть.** Гарантия StatefulSet — не больше одного пода с этим именем одновременно (иначе два PostgreSQL на одном томе). Контроллер не знает, мёртв ли узел или просто потерял связь, — и ждёт. Выход для действительно мёртвого узла — удалить объект Node (или под с `--force --grace-period=0`, понимая риск), либо taint `node.kubernetes.io/out-of-service` (non-graceful node shutdown, stable с 1.28) — тогда поды и тома освобождаются.
3. **Замена под `web` осталась Pending** до возврата узла: `topologySpreadConstraints` с `maxSkew: 1` по `kubernetes.io/hostname` продолжает считать узел с taint'ом доменом (по умолчанию `nodeTaintsPolicy: Ignore`), и новый под «не помещается»:

```
0/4 nodes are available: 2 node(s) didn't match pod topology spread constraints, 2 node(s) had untolerated taint(s). ...
```

Подробности spread — 05-2. Итого с дефолтами: **~5 минут 50 секунд** от потери узла до замены подов Deployment, и бесконечно — для StatefulSet без вмешательства. Ускоряют: меньший `tolerationSeconds` в подах (не ниже минуты — иначе короткий сетевой сбой устроит массовую миграцию), readiness, не зависящий от единственной БД, реплики БД на разных узлах с автоматическим failover (09-1).

## 8. Логи, образы, ресурсы узла 🟡

- **Логи контейнеров**: kubelet через containerd пишет stdout/stderr в `/var/log/pods/<ns>_<pod>_<uid>/<container>/N.log`; `/var/log/containers/*.log` — симлинки для агентов сбора (Fluent Bit, Promtail). Ротация — kubelet: `containerLogMaxSize: 10Mi`, `containerLogMaxFiles: 5` (проверено). `kubectl logs` читает текущий файл через kubelet, `--previous` — предыдущий экземпляр. Логи удаляются вместе с подом.
- **Образы**: GC при заполнении диска выше `imageGCHighThresholdPercent` (дефолт 85%) до `imageGCLowThresholdPercent` (80%). В kind GC выключен (`100`), eviction-пороги — `0%`: стенд не защищает свой диск, следите за `docker system df`.
- **`maxPods: 110`** на узел — дефолт; ограничен ещё и размером подсети узла (/24 = 254 адреса).
- **`serializeImagePulls: true`** — образы тянутся по одному; на узле с медленным реестром один огромный образ задерживает старт всех подов.
- **Allocatable**: capacity минус `kube-reserved`, `system-reserved` и порог eviction — 05-1, 05-4. В kind — равно capacity.

Эффективную конфигурацию kubelet (с дефолтами) показывает `/configz`:

```bash
kubectl get --raw /api/v1/nodes/lab-worker3/proxy/configz | jq '.kubeletconfig | {nodeStatusUpdateFrequency, nodeLeaseDurationSeconds, containerLogMaxSize, containerLogMaxFiles, imageGCHighThresholdPercent, evictionHard, maxPods}'
```

---

## 🔧 Лаба

### Шаг 0. Подготовка

```bash
kubectl config use-context kind-lab
kubectl create ns lab-01-2
kubectl config set-context --current --namespace=lab-01-2
kubectl -n orders get pods -o wide        # запомните, на каком узле postgres-0 (у автора — lab-worker)
```

### Шаг 1. Sandbox, pause и namespaces

```bash
W=$(kubectl -n orders get pod -l app=orders-api -o jsonpath='{.items[0].spec.nodeName}')
docker exec $W sh -c '
  P=$(crictl pods --namespace orders --name orders-api -q | head -1)
  crictl inspectp $P | grep -E "\"(ip|path|image)\"" | head -4
  PP=$(crictl inspectp -o go-template --template "{{.info.pid}}" $P)
  C=$(crictl ps --pod $P -q); CP=$(crictl inspect -o go-template --template "{{.info.pid}}" $C)
  ls -l /proc/$PP/ns/net /proc/$CP/ns/net /proc/$PP/ns/pid /proc/$CP/ns/pid
  ps -eo pid,args | grep "[/]pause" | head -3'
```

Ожидаемо (проверено): у pause и контейнера `api` одинаковый `net:[…]` и разные `pid:[…]`, по одному процессу `/pause` на каждый под узла.

### Шаг 2. CNI и маршруты

```bash
docker exec $W cat /etc/cni/net.d/10-kindnet.conflist
docker exec $W ip route
kubectl get nodes -o custom-columns=NAME:.metadata.name,PODCIDR:.spec.podCIDR,IP:.status.addresses[0].address
```

Сопоставьте: подсеть узла в `podCIDR` = `subnet` в конфиге CNI; маршрут на каждую чужую подсеть ведёт через IP её узла, на свои поды — через veth.

### Шаг 3. cgroups и конфигурация kubelet

```bash
docker exec $W systemd-cgls --no-pager -u kubelet.slice | head -25
kubectl get --raw /api/v1/nodes/$W/proxy/configz | jq -c '.kubeletconfig | {nodeStatusUpdateFrequency, nodeStatusReportFrequency, nodeLeaseDurationSeconds, containerLogMaxSize, containerLogMaxFiles, imageGCHighThresholdPercent, imageGCLowThresholdPercent, evictionHard, maxPods, serializeImagePulls}'
kubectl -n kube-node-lease get lease $W -o jsonpath='{.spec}{"\n"}'
docker exec $W ls -l /var/log/containers | head -3
```

Проверено:

```
{"nodeStatusUpdateFrequency":"10s","nodeStatusReportFrequency":"5m0s","nodeLeaseDurationSeconds":40,"containerLogMaxSize":"10Mi","containerLogMaxFiles":5,"imageGCHighThresholdPercent":100,"imageGCLowThresholdPercent":80,"evictionHard":{"imagefs.available":"0%","nodefs.available":"0%","nodefs.inodesFree":"0%"},"maxPods":110,"serializeImagePulls":true}
{"holderIdentity":"lab-worker","leaseDurationSeconds":40,"renewTime":"2026-10-14T08:51:49.053074Z"}
lrwxrwxrwx 1 root root 140 Oct 14 08:25 envoy-…_envoy-gateway-system_envoy-e2d4….log -> /var/log/pods/envoy-gateway-system_envoy-…_1cefb68a-…/envoy/0.log
```

Повторите `get lease` несколько раз — `renewTime` сдвигается каждые ~10 с.

### Шаг 4. Static pod на worker'е

```bash
docker exec -i lab-worker2 sh -c 'cat > /etc/kubernetes/manifests/static-web.yaml' <<'EOF'
apiVersion: v1
kind: Pod
metadata: {name: static-web, namespace: lab-01-2}
spec:
  containers:
  - name: web
    image: busybox:1.37
    command: ["sleep", "infinity"]
EOF
sleep 15; kubectl get pods -o wide
kubectl get pod static-web-lab-worker2 -o jsonpath='{.metadata.annotations}{"\n"}{.metadata.ownerReferences}{"\n"}'
kubectl delete pod static-web-lab-worker2; sleep 5; kubectl get pods
docker exec lab-worker2 crictl ps --name '^web$'
docker exec lab-worker2 rm /etc/kubernetes/manifests/static-web.yaml
sleep 30; kubectl get pods
```

Проверено:

```
NAME                     READY   STATUS    RESTARTS   AGE   IP            NODE          ...
static-web-lab-worker2   1/1     Running   0          15s   10.244.3.10   lab-worker2   ...
{"kubernetes.io/config.hash":"17b2e4f7…","kubernetes.io/config.mirror":"17b2e4f7…","kubernetes.io/config.seen":"2026-10-14T08:52:06…","kubernetes.io/config.source":"file"}
[{"apiVersion":"v1","controller":true,"kind":"Node","name":"lab-worker2","uid":"8eddb6f6-…"}]
pod "static-web-lab-worker2" deleted from lab-01-2 namespace
NAME                     READY   STATUS    RESTARTS   AGE
static-web-lab-worker2   1/1     Running   0          6s
CONTAINER           IMAGE               CREATED             STATE     NAME   ATTEMPT   POD ID          POD                      NAMESPACE
83462e6183552       30ecbe1509090       20 seconds ago      Running   web    0         b3d278488e485   static-web-lab-worker2   lab-01-2
No resources found in lab-01-2 namespace.
```

Mirror pod после `delete` «помолодел» (6 с), а контейнер — тот же, созданный 20 с назад.

### Шаг 5. Узел теряет kubelet

Разложите три пода по узлам и запустите наблюдение на 7 минут. Если PostgreSQL у вас не на `lab-worker` — подставьте его узел в `NODE`.

```bash
kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata: {name: web}
spec:
  replicas: 3
  selector: {matchLabels: {app: web}}
  template:
    metadata: {labels: {app: web}}
    spec:
      topologySpreadConstraints:
      - {maxSkew: 1, topologyKey: kubernetes.io/hostname, whenUnsatisfiable: DoNotSchedule, labelSelector: {matchLabels: {app: web}}}
      containers:
      - {name: web, image: busybox:1.37, command: ["sleep", "infinity"]}
EOF
kubectl rollout status deploy/web
kubectl get pods -o wide

NODE=lab-worker
t0=$(date +%s); prev=""
docker exec $NODE systemctl stop kubelet; echo "t=0 kubelet stopped on $NODE"
while [ $(( $(date +%s)-t0 )) -lt 420 ]; do
  n=$(kubectl get node $NODE -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}/{.status.conditions[?(@.type=="Ready")].reason} taints={.spec.taints[*].key}:{.spec.taints[*].effect}')
  p=$(kubectl -n orders get pod postgres-0 -o jsonpath='{.status.phase}/ready={.status.conditions[?(@.type=="Ready")].status}/del={.metadata.deletionTimestamp}')
  w=$(kubectl get pods -o wide --no-headers | awk '{printf "%s:%s:%s ", substr($1,length($1)-4), $3, $7}')
  ep=$(kubectl -n orders get endpointslice -l kubernetes.io/service-name=postgres -o jsonpath='{.items[0].endpoints[*].conditions.ready}')
  c=$(curl -s -o /dev/null -m 3 -w '%{http_code}' http://orders.localhost:8088/api/orders)
  cur="node=$n | pg=$p ep_ready=$ep | web=$w | api=$c"
  [ "$cur" != "$prev" ] && echo "t=+$(( $(date +%s)-t0 ))s $cur" && prev=$cur
  sleep 3
done
```

Проверено (запросы к API — из сети kind, 00-1 §4.4):

```
t=0 kubelet stopped on lab-worker
t=+1s node=True/KubeletReady taints=: | pg=Running/ready=True/del= ep_ready=true | web=j62pr:Running:lab-worker2 wz5nv:Running:lab-worker xpvrm:Running:lab-worker3  | api=200
t=+53s node=Unknown/NodeStatusUnknown taints=node.kubernetes.io/unreachable node.kubernetes.io/unreachable:NoSchedule NoExecute | pg=Running/ready=False/del= ep_ready=false | web=j62pr:Running:lab-worker2 wz5nv:Running:lab-worker xpvrm:Running:lab-worker3  | api=503
t=+353s node=Unknown/NodeStatusUnknown taints=node.kubernetes.io/unreachable node.kubernetes.io/unreachable:NoSchedule NoExecute | pg=Running/ready=False/del=2026-10-14T09:00:41Z ep_ready=false | web=5hmqj:Pending:<none> j62pr:Running:lab-worker2 wz5nv:Terminating:lab-worker xpvrm:Running:lab-worker3  | api=503
```

Пока узел «мёртв», проверьте, что PostgreSQL на самом деле жив, и почему новый `web` не планируется:

```bash
docker exec $NODE crictl ps --name postgres                   # Running
kubectl get events --field-selector reason=FailedScheduling -o jsonpath='{.items[-1:].message}{"\n"}'
```

Верните kubelet и засеките восстановление:

```bash
t0=$(date +%s); docker exec $NODE systemctl start kubelet
until [ "$(curl -s -o /dev/null -m 3 -w '%{http_code}' http://orders.localhost:8088/api/orders)" = 200 ]; do sleep 1; done
echo "api=200 after $(( $(date +%s)-t0 ))s"
kubectl -n orders get pods -o wide; kubectl get pods -o wide
curl -s http://orders.localhost:8088/api/orders | jq -c '[.orders[].item]'
```

Проверено:

```
api=200 after 8s
postgres-0 Running 0 10.244.2.7 lab-worker
web-747b449645-5hmqj Running lab-worker
...
["book","pen","lamp"]
```

`postgres-0` — новый под (`RESTARTS 0`, новый IP) на том же узле и с теми же данными: том local-path живёт на диске `lab-worker`.

### Уборка

```bash
docker exec lab-worker systemctl is-active kubelet           # active
docker exec lab-worker2 ls /etc/kubernetes/manifests          # пусто — static-web удалён
kubectl config set-context --current --namespace=default
kubectl delete ns lab-01-2
```

---

## 🔥 Кейс из прода: «упал один узел — лёг весь сервис, хотя у нас две реплики»

**Контекст.** orders-api — 2 реплики Deployment, PostgreSQL — StatefulSet с одной репликой на локальном диске узла. Узел с PostgreSQL перестал отвечать (завис kubelet после OOM на узле; ssh работал, контейнеры тоже). Через минуту — алерт «5xx 100%», хотя оба пода orders-api на других узлах и Running.

**Разбор.**
1. `kubectl get pods -n orders` — orders-api `0/1 Running` (не Ready), postgres-0 `1/1 Running` — статус устаревший: узел `NotReady`/`Unknown`.
2. `kubectl -n orders get endpointslice` — у postgres адрес `ready: false`. Headless Service отдаёт в DNS только готовые адреса: `postgres` не резолвится, readiness orders-api (`/ready` проверяет БД) падает, оба пода выпадают из Service. Каскад: проблема узла → неготовый endpoint → readiness зависимого сервиса → 503 у всех.
3. Через 5 минут postgres-0 перешёл в `Terminating` и так и остался — StatefulSet ждал подтверждения от узла. Дежурный удалил под с `--force` — новый `postgres-0` повис в Pending: PV local-path привязан к недоступному узлу (04-2).
4. Спасло возвращение узла: перезапуск kubelet по ssh.

**Фикс.**
- PostgreSQL — с репликой и автоматическим failover (оператор CloudNativePG, 09-1) и томами, не привязанными к одному узлу.
- Readiness orders-api не роняет под при недоступной БД целиком: под остаётся в Service и отдаёт деградированный ответ (кэш, 503 только на запись) — модель «зависимости в readiness» разобрана в 02-5.
- Runbook «узел NotReady»: проверить kubelet и containerd по ssh до любых `--force`; `--force` для подов StatefulSet — только когда узел гарантированно выключен (или taint `node.kubernetes.io/out-of-service`).
- Алерт на `kube_node_status_condition{condition="Ready",status!="true"}` с понятным текстом «какие StatefulSet живут на узле».

**Что запомнить.**
- NotReady-узел за ~50 с делает endpoint'ы своих подов неготовыми — даже если процессы живы.
- Поды Deployment уезжают через ~5 минут; StatefulSet — только после подтверждения смерти узла.
- Одна реплика stateful-зависимости + readiness, проверяющий эту зависимость, = единая точка отказа для всех реплик сервиса.

---

## 💼 Вопросы с собеседования

### 🟢 Junior

**1. Что делает kubelet?**
Агент на каждом узле: следит (watch) за подами, назначенными узлу, запускает их через CRI-рантайм (containerd), монтирует тома, выполняет probes, перезапускает контейнеры по restartPolicy, пишет статус подов и узла и heartbeat (Lease) в apiserver.

**2. Что такое pause-контейнер?**
Процесс `/pause` в sandbox'е пода, который держит общие namespaces (прежде всего сетевой). Контейнеры пода присоединяются к ним; при перезапуске контейнера IP пода не меняется.

**3. Нужен ли Docker на узле Kubernetes?**
Нет. С 1.24 kubelet работает с рантаймом через CRI (containerd, CRI-O); dockershim удалён. Образы, собранные Docker'ом, — обычные OCI-образы и запускаются.

### 🟡 Middle

**4. Что такое CRI и CNI и кто их вызывает?**
CRI — gRPC-интерфейс kubelet → рантайм (создать sandbox, контейнер, pull образа). CNI — интерфейс рантайм → сетевой плагин: при создании sandbox'а containerd вызывает бинарники из `/opt/cni/bin` по конфигу `/etc/cni/net.d`, они создают интерфейс в netns пода, выдают IP и маршруты.

**5. Что такое static pod и как его удалить?**
Под из файла в `staticPodPath` (`/etc/kubernetes/manifests`), который kubelet запускает сам. В API — mirror pod; `kubectl delete` пересоздаёт только mirror, контейнер продолжает работать. Удалить — убрать файл с узла.

**6. Узел упал. Через сколько поды переедут?**
Kubelet перестаёт продлевать Lease; через `node-monitor-grace-period` (50 с в новых версиях) узел `Unknown` и получает taint `unreachable:NoExecute`; поды имеют toleration на 300 с — через ~5 мин 50 с они помечаются на удаление, Deployment создаёт замену. StatefulSet не создаёт замену, пока узел не подтвердит удаление пода (или не удалён объект Node / стоит taint out-of-service).

### 🔴 Senior

**7. Почему после потери узла с единственной репликой БД сервис может лечь целиком через минуту, хотя БД жива?**
Endpoint'ы подов на узле `Unknown` помечаются неготовыми; Service (особенно headless) перестаёт отдавать адрес; если readiness зависимого сервиса проверяет БД — все его поды выпадают из endpoints. Решение: реплика БД с failover, readiness без жёсткой зависимости от единственной БД, PDB и anti-affinity.

**8. Что значит `PLEG is not healthy` и что делать?**
Kubelet не успевает получить от рантайма состояние контейнеров за отведённое время (3 мин); узел становится NotReady. Причины: перегруженный или зависший containerd, тысячи остановленных контейнеров, проблемы диска (IO wait), большое число подов. Смотреть `journalctl -u kubelet -u containerd`, `crictl ps -a | wc -l`, `iostat`; лечить причину, перезапуск containerd — временная мера.

**9. Почему драйвер cgroups у kubelet и рантайма должен совпадать?**
Иначе два менеджера (systemd и cgroupfs) управляют одной иерархией, systemd не знает о части cgroup'ов, и под давлением ресурсов узел ведёт себя непредсказуемо (сбои создания подов, некорректные лимиты). На systemd-дистрибутивах — `systemd` у обоих (`cgroupDriver` в kubelet и `SystemdCgroup = true` в containerd).

---

## ⚠️ Подводные камни

- Контейнеры на узле продолжают работать, когда kubelet остановлен, — `kubectl get pods` при этом показывает устаревший статус.
- Узел `Unknown` → endpoint'ы его подов неготовы → зависимые сервисы падают через readiness. Каскад наступает за ~50 с.
- `kubectl delete pod --force` для StatefulSet на «потерянном» узле может дать два экземпляра на одном томе, если узел на самом деле жив.
- Поды с PV на локальном диске (local-path, local) не переезжают с узла — Pending до его возвращения.
- `topologySpreadConstraints` по умолчанию считает узлы с taint'ами доменами — замена может зависнуть Pending, пока узел мёртв (`nodeTaintsPolicy: Honor` меняет это).
- Удаление mirror pod не останавливает static pod; файл в `/etc/kubernetes/manifests` на любом узле — обход RBAC и admission.
- В kind GC образов и eviction по диску выключены — диск хоста заполняется незаметно.
- `imagePullPolicy: Always` + медленный реестр + `serializeImagePulls: true` — долгий старт всех подов узла.

---

## Чеклист

- [ ] Покажу на узле pause-контейнер и общий сетевой namespace пода.
- [ ] Объясню путь от binding до Ready и где на нём типовые ошибки.
- [ ] Найду конфиг CNI, подсеть узла и маршруты к подам других узлов.
- [ ] Найду cgroup пода и объясню раскладку по QoS-слайсам.
- [ ] Создам и удалю static pod; объясню, почему `kubectl delete` его не убивает.
- [ ] Назову цифры: 10 с heartbeat, 50 с до Unknown, 300 с до вытеснения; объясню, почему StatefulSet не переезжает.

---

## Задание со звёздочкой

Сократите время реакции на потерю узла для orders-api и измерьте результат:

1. Добавьте в под orders-api toleration `node.kubernetes.io/unreachable:NoExecute` с `tolerationSeconds: 60` (и такую же для `not-ready`).
2. Положите один под orders-api на узел `lab-worker` (nodeSelector или affinity) и повторите шаг 5, наблюдая за orders-api вместо `web`.
3. Сравните время до появления замены с дефолтными 353 с. Чем рискуете, если поставить 10 с? Что будет при сетевом сбое на 30 секунд у трёх узлов из четырёх?
4. Попробуйте taint `node.kubernetes.io/out-of-service=nodeshutdown:NoExecute` на «мёртвом» узле: что происходит с `postgres-0` и его томом? Снимите taint и верните kubelet.

---

→ Следующая часть: **01-3. API-объекты и kubectl под капотом** — labels и selectors, client-side и server-side apply, field managers и конфликты, ownerReferences и каскадное удаление, finalizers и подресурсы; почему `kubectl apply` затирает `replicas`, выставленные HPA.
