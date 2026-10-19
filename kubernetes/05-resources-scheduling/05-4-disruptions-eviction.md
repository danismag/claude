# 05-4. Disruptions: PDB, drain, eviction

> Модуль 5 «Ресурсы и планирование» · часть 4 из 4 · 🟡🔴 · ~1 ч чтения + ~45 мин лабы · Нужно: стенд 00-1. В лабе узел `lab-worker` проходит drain (затрагивает PostgreSQL сквозного сценария — на 1–2 минуты), а на `lab-worker3` временно меняется конфигурация kubelet.

---

## Зачем это DevOps-у

Узлы обновляют, перезагружают, выводят на обслуживание, удаляет автоскейлер — и каждый раз поды выселяются. Если это делать без правил, сервис падает «по расписанию». С правилами (PodDisruptionBudget) — обновление узлов застревает навсегда, потому что PDB не даёт выселить единственную реплику. Отдельная история — недобровольное вытеснение kubelet'ом при нехватке памяти или диска на узле. На собеседовании: «что такое PDB», «почему drain завис», «кого kubelet выселит первым».

В сквозном сценарии мы сделаем drain узла, где живёт PostgreSQL с local-path томом, и увидим, во что это превращается для orders-api.

---

## 1. Добровольные и недобровольные прерывания 🟢

| Прерывание | Примеры | PDB учитывается? |
|---|---|---|
| **добровольное** (voluntary) | `kubectl drain`, Cluster Autoscaler/Karpenter убирают узел, обновление managed-узлов, eviction через API | **да** — через Eviction API |
| **недобровольное** | отказ узла, kernel panic, OOM на узле, вытеснение kubelet'ом по давлению ресурсов, `kubectl delete pod` | нет |

PDB защищает только от первых. `kubectl delete pod`, rollout Deployment'а и удаление namespace PDB не проверяют — у Deployment свой «бюджет» в `maxUnavailable` (02-2).

## 2. PodDisruptionBudget 🟡

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata: {name: web}
spec:
  minAvailable: 2            # или maxUnavailable: 1 (лучше — работает при масштабировании)
  selector: {matchLabels: {app: web}}
  unhealthyPodEvictionPolicy: AlwaysAllow   # см. §4
```

Проверено (3 реплики `web`, 1 реплика `single`):

```
NAME     MIN AVAILABLE   MAX UNAVAILABLE   ALLOWED DISRUPTIONS
single   1               N/A               0              ← выселить нельзя никогда
web      2               N/A               1
```

`ALLOWED DISRUPTIONS` — сколько подов можно выселить прямо сейчас. Для одной реплики с `minAvailable: 1` — всегда 0: такой PDB **блокирует drain навсегда**. Правила:

- `maxUnavailable: 1` вместо `minAvailable: N-1` — не ломается при изменении числа реплик;
- для сервисов с одной репликой PDB либо не ставят, либо ставят `maxUnavailable: 1` (прерывание допустимо, но по одному);
- PDB на StatefulSet кворумных систем (etcd, ZooKeeper, Kafka) — `maxUnavailable: 1`, чтобы drain не унёс кворум.

## 3. kubectl drain 🟡

`drain` = `cordon` (узел `unschedulable`) + выселение подов через **Eviction API** с уважением PDB и grace period.

Проверено — drain без флагов **отказался**, но узел при этом уже cordon'нут:

```
cannot delete DaemonSet-managed Pods (use --ignore-daemonsets to ignore): kube-system/kindnet-v72nj, kube-system/kube-proxy-grrbj
cannot delete Pods that declare no controller (use --force to override): lab-05-4/bare
unschedulable after refused drain: true
```

| Флаг | Зачем | Риск |
|---|---|---|
| `--ignore-daemonsets` | пропустить поды DaemonSet (их нельзя выселить — вернутся на тот же узел) | нет |
| `--delete-emptydir-data` | разрешить выселять поды с `emptyDir` | данные emptyDir теряются |
| `--force` | удалить поды без контроллера | они не вернутся |
| `--timeout` | ограничить общее время | без него drain может висеть вечно |
| `--disable-eviction` | удалять вместо выселения — **в обход PDB** | ровно то, от чего PDB защищал |

С флагами (проверено, `--timeout=45s`):

```
9 error when evicting pods/"single-674944c7bd-zkjjs" -n "lab-05-4" (will retry after 5s): Cannot evict pod as it would violate the pod's disruption budget.
error: unable to drain node "lab-worker" due to error: ... global timeout reached: 45s
```

`web` выселен и пересоздан на `lab-worker2`, `single` остался — drain ретраит каждые 5 с до таймаута. Без `--timeout` так висит процедура обновления узлов в CI или в облаке (managed node group ждёт и в конце концов форсирует).

### Drain узла с БД на local-томе 🔴

Проверено: на `lab-worker` работал `postgres-0` сквозного сценария. После drain:

```
orders/postgres-0   Pending
0/4 nodes are available: 1 node(s) had untolerated taint(s), 1 node(s) were unschedulable, 2 node(s) didn't match PersistentVolume's node affinity.
orders api: 503
```

PV local-path привязан к `lab-worker` (04-2), узел cordon'нут — БД некуда встать, orders-api отвечает 503, пока узел не вернут. После `uncordon` — **2 с** до `200`. Drain узла с локальными данными — это простой; поэтому у StatefulSet БД на local-томах: реплики на уровне приложения, PDB, который не даёт выселить primary без switchover, и runbook «сначала переключить primary, потом drain».

## 4. Eviction API и «нездоровые» поды 🟡🔴

Выселение — это POST на подресурс `pods/<имя>/eviction`. Ответ при нарушении PDB — **429 Too Many Requests** (проверено):

```
Error from server (TooManyRequests): Cannot evict pod as it would violate the pod's disruption budget.
```

Ловушка: PDB считает «здоровыми» только Ready-поды. Если все поды сервиса не Ready (сломанный релиз, CrashLoop), `currentHealthy=0`, `disruptionsAllowed=0` — и **ни один из бесполезных подов нельзя выселить**: drain узла висит из-за сервиса, который и так не работает. Проверено (2 реплики, readiness всегда падает, `minAvailable: 1`):

```
evict with default policy (IfHealthyBudget):
Error from server (TooManyRequests): Cannot evict pod as it would violate the pod's disruption budget.
evict with AlwaysAllow:
{"kind":"Status","apiVersion":"v1","metadata":{},"status":"Success","code":201}
AlwaysAllow currentHealthy=0 disruptionsAllowed=0
```

`unhealthyPodEvictionPolicy: AlwaysAllow` (stable с 1.31) разрешает выселять **неготовые** поды независимо от бюджета — их выселение не уменьшает доступность. Ставьте его во все PDB, если нет особых причин.

## 5. Вытеснение kubelet'ом (node-pressure eviction) 🟡🔴

Kubelet сам выселяет поды, когда ресурсы **узла** опускаются ниже порогов:

| Сигнал | Дефолтный жёсткий порог (Linux) |
|---|---|
| `memory.available` | 100Mi |
| `nodefs.available` | 10% |
| `nodefs.inodesFree` | 5% |
| `imagefs.available` | 15% |
| `pid.available` | — |

`evictionHard` — выселять сразу; `evictionSoft` + `evictionSoftGracePeriod` — после N секунд ниже порога; `evictionMinimumReclaim` — сколько освобождать сверх порога, чтобы не «дребезжать». При срабатывании: условие узла `MemoryPressure`/`DiskPressure`, taint `node.kubernetes.io/memory-pressure:NoSchedule`, выселение подов.

**Порядок выселения** по памяти: сначала поды, чьё потребление **превышает requests**; среди них — по `priority`; затем по величине превышения над request. QoS прямо не участвует, но BestEffort (request 0) почти всегда «превышает больше всех», а Guaranteed (потребление ≤ лимит = request) — не превышает никогда.

Опыт на стенде. У kind пороги выключены, поэтому на `lab-worker3` временно задан `memory.available: 14900Mi` (лаба, шаг 5). Первое наблюдение — **порог вычитается из allocatable** (проверено):

```
capacity=16315248Ki allocatable=1057648Ki
memory             1028Mi (99%)  776Mi (75%)        ← requests уже почти весь allocatable
```

Под с request 64Mi на узел больше не помещался (`Insufficient memory`), пришлось дать ему request 1Mi. Это та же арифметика, что в проде: `allocatable = capacity − kube-reserved − system-reserved − evictionHard`.

Три пода: Guaranteed (200 МиБ при request 300Mi), BestEffort (200 МиБ), Burstable (300 МиБ при request 1Mi). Проверено:

```
t=+1s  avail=15045Mi MemoryPressure=False | besteffort:Running burstable:Running guaranteed:Running
t=+12s avail=14949Mi MemoryPressure=True  | besteffort:ContainerStatusUnknown burstable:Running guaranteed:Running
besteffort: Failed/Evicted The node was low on resource: memory. Threshold quantity: 14900Mi, available: 15089952Ki. Container besteffort was using 209476Ki, request is 0, has larger consumption of me…
taints=[{"effect":"NoSchedule","key":"node.kubernetes.io/memory-pressure",...}]
EvictionThresholdMet        Attempting to reclaim memory
NodeHasInsufficientMemory   Node lab-worker3 status is now: NodeHasInsufficientMemory
```

Выселен BestEffort — в момент проверки он превышал свой request (0) сильнее остальных: Burstable ещё дозаполнял свои 300 МиБ. Guaranteed не тронут. Kubelet выселил одного и остановился: доступная память вернулась к порогу. Выселенный под — `Failed/Evicted` (в `kubectl get` — `ContainerStatusUnknown`), его **не перезапускают**: голый под потерян, под контроллера — пересоздастся на другом узле.

Особенность kind, из-за которой без ручного порога опыт не работает: kubelet в узле-контейнере считает `memory.available` от лимита своего контейнера (= вся память хоста, 16,3 ГБ) минус потребление узла и видит 15–16 ГБ свободными, даже когда на хосте свободно 8 ГБ (проверено: `availableMi: 15473` против `available=8221278208` у `free -b` на хосте). Вложенные контейнеры не видят давления хоста — в реальном кластере узел обычно VM или железо, и сигнал честный.

Вытеснение kubelet'ом — недобровольное: **PDB не учитывается**. Защита — правильные requests (поды в пределах request выселяют последними), PriorityClass для критичного, `system-reserved`/`kube-reserved`, чтобы узел не вставал в ноль из-за системных процессов.

## 6. Graceful node shutdown 🔴

При выключении узла (systemd-inhibit) kubelet может корректно остановить поды: `shutdownGracePeriod` (общее время) и `shutdownGracePeriodCriticalPods` (из них — на критичные поды). В kind оба `0s` — выключение узла убивает поды без SIGTERM. На VM и железе включайте (например, 30 с и 10 с), иначе перезагрузка узла = жёсткое убийство всех подов. Non-graceful shutdown (узел выключен, а kubelet об этом не сообщил) — taint `node.kubernetes.io/out-of-service` (01-2).

---

## 🔧 Лаба

### Шаг 0. Подготовка

```bash
kubectl config use-context kind-lab
kubectl create ns lab-05-4
kubectl config set-context --current --namespace=lab-05-4
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
      terminationGracePeriodSeconds: 5
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms: [{matchExpressions: [{key: kubernetes.io/hostname, operator: In, values: [lab-worker, lab-worker2]}]}]
      containers:
      - {name: c, image: localhost:5001/orders-api:2.0, readinessProbe: {httpGet: {path: /ready, port: 8000}, periodSeconds: 2, initialDelaySeconds: 3}}
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata: {name: web}
spec:
  minAvailable: 2
  selector: {matchLabels: {app: web}}
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: single}
spec:
  replicas: 1
  selector: {matchLabels: {app: single}}
  template:
    metadata: {labels: {app: single}}
    spec:
      nodeSelector: {kubernetes.io/hostname: lab-worker}
      containers: [{name: c, image: registry.k8s.io/pause:3.10}]
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata: {name: single}
spec:
  minAvailable: 1
  selector: {matchLabels: {app: single}}
EOF
kubectl rollout status deploy/web; kubectl rollout status deploy/single
kubectl run bare --image=registry.k8s.io/pause:3.10 --overrides='{"spec":{"nodeName":"lab-worker"}}'
kubectl get pdb; kubectl get pods -o wide
kubectl -n orders get pods -o wide        # где postgres-0? (у автора — lab-worker)
```

### Шаг 1. Drain

```bash
kubectl drain lab-worker --timeout=20s                    # отказ — и cordon
kubectl get node lab-worker -o jsonpath='{.spec.unschedulable}{"\n"}'
kubectl drain lab-worker --ignore-daemonsets --delete-emptydir-data --force --timeout=45s 2>&1 | grep -vE '^evicting pod|^pod/' | sort | uniq -c
kubectl get pods -o wide; kubectl -n orders get pods
curl -s -o /dev/null -w 'orders api: %{http_code}\n' http://orders.localhost:8088/api/orders
kubectl -n orders get events --field-selector involvedObject.name=postgres-0,reason=FailedScheduling -o jsonpath='{.items[-1:].message}{"\n"}'
t0=$(date +%s); kubectl uncordon lab-worker
until [ "$(curl -s -o /dev/null -w '%{http_code}' http://orders.localhost:8088/api/orders)" = 200 ]; do sleep 1; done; echo "200 after $(( $(date +%s)-t0 ))s"
```

Проверено: вывод в §3.

### Шаг 2. PDB и нездоровые поды

```bash
kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata: {name: sick}
spec:
  replicas: 2
  selector: {matchLabels: {app: sick}}
  template:
    metadata: {labels: {app: sick}}
    spec:
      terminationGracePeriodSeconds: 1
      containers: [{name: c, image: localhost:5001/orders-api:2.0, readinessProbe: {httpGet: {path: /nope, port: 8000}, periodSeconds: 2}}]
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata: {name: sick}
spec:
  minAvailable: 1
  selector: {matchLabels: {app: sick}}
EOF
sleep 15; kubectl get pdb sick
ev() { V=$(kubectl get pods -l app=sick -o jsonpath='{.items[0].metadata.name}')
  echo "{\"apiVersion\":\"policy/v1\",\"kind\":\"Eviction\",\"metadata\":{\"name\":\"$V\",\"namespace\":\"lab-05-4\"}}" > /tmp/ev.json
  kubectl create --raw /api/v1/namespaces/lab-05-4/pods/$V/eviction -f /tmp/ev.json; echo; }
ev
kubectl patch pdb sick -p '{"spec":{"unhealthyPodEvictionPolicy":"AlwaysAllow"}}'
ev
rm /tmp/ev.json
```

Проверено: вывод в §4.

### Шаг 3. Порог вытеснения по памяти на одном узле

```bash
kubectl delete deploy sick single web; kubectl delete pdb --all; kubectl delete pod bare --now
W=lab-worker3
kubectl get --raw /api/v1/nodes/$W/proxy/stats/summary | jq -c '.node.memory | {availableMi: (.availableBytes/1048576|floor), workingSetMi: (.workingSetBytes/1048576|floor)}'
free -m | awk 'NR==2{print "host available="$7"Mi"}'
```

Подставьте свой порог: доступное узлу минус ~550 Mi (у автора — 15473 → 14900Mi):

```bash
TH=14900Mi
docker exec $W sh -c "cp /var/lib/kubelet/config.yaml /root/kubelet-config.yaml.bak
  sed -i 's/^evictionHard:\$/evictionHard:\n  memory.available: $TH/' /var/lib/kubelet/config.yaml
  systemctl restart kubelet"
sleep 15; kubectl wait --for=condition=Ready node/$W
kubectl get --raw /api/v1/nodes/$W/proxy/configz | jq -c '.kubeletconfig.evictionHard'
kubectl get node $W -o jsonpath='capacity={.status.capacity.memory} allocatable={.status.allocatable.memory}{"\n"}'
```

Проверено: `allocatable=1057648Ki` — порог «съел» allocatable (§5).

### Шаг 4. Давление и вытеснение

```bash
mkp() { kubectl run $1 --image=python:3.12-slim --restart=Never --overrides="{\"spec\":{\"nodeSelector\":{\"kubernetes.io/hostname\":\"$W\"},\"terminationGracePeriodSeconds\":1,\"containers\":[{\"name\":\"$1\",\"image\":\"python:3.12-slim\",\"command\":[\"python\",\"-c\",\"import time; b=b'x'*($2*2**20); time.sleep(1e6)\"]${3:+,\"resources\":$3}}]}}"; }
mkp guaranteed 200 '{"requests":{"cpu":"50m","memory":"300Mi"},"limits":{"cpu":"50m","memory":"300Mi"}}'
mkp besteffort 200
kubectl wait --for=condition=Ready pod/guaranteed pod/besteffort; sleep 12
t0=$(date +%s); mkp burstable 300 '{"requests":{"memory":"1Mi"},"limits":{"memory":"1Gi"}}'
prev=""; for i in $(seq 1 45); do
  av=$(kubectl get --raw /api/v1/nodes/$W/proxy/stats/summary | jq '.node.memory.availableBytes/1048576|floor')
  mp=$(kubectl get node $W -o jsonpath='{.status.conditions[?(@.type=="MemoryPressure")].status}')
  s="MemoryPressure=$mp | $(kubectl get pods --no-headers | awk '{printf "%s:%s ", $1, $3}')"
  [ "$s" != "$prev" ] && echo "t=+$(( $(date +%s)-t0 ))s avail=${av}Mi $s" && prev=$s; sleep 2; done
kubectl get pods -o jsonpath='{range .items[*]}{.metadata.name}: {.status.phase}/{.status.reason} {.status.message}{"\n"}{end}'
kubectl get node $W -o jsonpath='{.spec.taints}{"\n"}'
kubectl get events --field-selector involvedObject.name=$W -o custom-columns=REASON:.reason,MSG:.message | grep -iE 'memory|evict'
```

`b'x' * N` заполняет память по-настоящему (`bytearray(N)` — нет: нулевые страницы не учитываются, пока к ним не обратились). Проверено: вывод в §5. Кто будет выселен первым, зависит от того, кто в момент проверки сильнее превышает request: если Burstable успеет занять память раньше — выселят его.

### Уборка

```bash
kubectl config set-context --current --namespace=default
kubectl delete ns lab-05-4
docker exec $W sh -c 'cp /root/kubelet-config.yaml.bak /var/lib/kubelet/config.yaml && rm /root/kubelet-config.yaml.bak && systemctl restart kubelet'
sleep 15; kubectl wait --for=condition=Ready node/$W
kubectl get --raw /api/v1/nodes/$W/proxy/configz | jq -c '.kubeletconfig.evictionHard'      # без memory.available
kubectl get node $W -o jsonpath='allocatable={.status.allocatable.memory} taints={.spec.taints}{"\n"}'
curl -s -o /dev/null -w '%{http_code}\n' http://orders.localhost:8088/api/orders
```

Проверено: `{"imagefs.available":"0%","nodefs.available":"0%","nodefs.inodesFree":"0%"}`, `allocatable=16315248Ki`, taint'ов нет.

---

## 🔥 Кейс из прода: «обновление узлов зависло на шестом часу»

**Контекст.** Плановое обновление managed-кластера: node group по 40 узлов, обновление по одному узлу (drain → замена). Через 6 часов процесс стоит на 7-м узле. В консоли облака — «waiting for pods to be evicted».

**Разбор.**
1. `kubectl get pdb -A` — у трёх сервисов `ALLOWED DISRUPTIONS 0`: два — с одной репликой и `minAvailable: 1` (шаблон чарта «для надёжности»), один — сервис в CrashLoop после неудачного релиза, все поды не Ready, PDB `minAvailable: 2` (§4).
2. Drain ретраил eviction каждые 5 секунд часами (шаг 1 лабы — то же сообщение `would violate the pod's disruption budget`).
3. Облачный процесс обновления по истечении своего таймаута стал удалять узлы форсированно — вместе с подами, которым PDB «гарантировал» доступность.

**Фикс.**
- Шаблон PDB в чартах: `maxUnavailable: 1` вместо `minAvailable`, `unhealthyPodEvictionPolicy: AlwaysAllow`; для `replicas: 1` PDB не создаётся.
- Проверка в CI (Kyverno/VAP, 06-2): PDB с `ALLOWED DISRUPTIONS 0` при стабильном состоянии — ошибка (`minAvailable` ≥ replicas).
- Перед обслуживанием узлов — `kubectl get pdb -A | awk '$5==0'` и разбор каждого.
- Сервисы с одной репликой, которые не должны прерываться, — это архитектурная проблема (две реплики), а не задача для PDB.

**Что запомнить.**
- PDB с нулевым бюджетом блокирует drain навсегда.
- Неготовые поды не «здоровы» для PDB — без `AlwaysAllow` сломанный сервис блокирует обслуживание.
- `maxUnavailable: 1` — безопасный дефолт.

---

## 💼 Вопросы с собеседования

### 🟢 Junior

**1. Что такое PodDisruptionBudget?**
Ограничение на число подов, которые можно одновременно выселить добровольно (drain, автоскейлер): `minAvailable` или `maxUnavailable` по селектору. Не защищает от отказов узлов и `kubectl delete`.

**2. Что делает `kubectl drain`?**
Помечает узел unschedulable (cordon) и выселяет поды через Eviction API с учётом PDB и grace period. DaemonSet-поды пропускаются (`--ignore-daemonsets`), поды без контроллера и с emptyDir — только с флагами.

### 🟡 Middle

**3. Почему drain завис?**
PDB с `ALLOWED DISRUPTIONS 0`: одна реплика с `minAvailable: 1`, `minAvailable` ≥ числа готовых подов, все поды не Ready. Drain ретраит выселение бесконечно (или до `--timeout`). Проверка — `kubectl get pdb -A`.

**4. minAvailable или maxUnavailable?**
`maxUnavailable: 1` — бюджет не зависит от числа реплик и не превращается в 0 при масштабировании вниз. `minAvailable` в абсолютном числе легко становится равным числу реплик.

**5. Кого kubelet выселит первым при нехватке памяти на узле?**
Поды, чьё потребление превышает requests; среди них — с меньшим приоритетом; затем с большим превышением. Практически: BestEffort и Burstable сверх request — первыми, Guaranteed — последними. PDB при этом не учитывается.

### 🔴 Senior

**6. Почему все поды сервиса в CrashLoop, а drain всё равно блокируется его PDB, и что делать?**
PDB считает здоровыми только Ready-поды; при `currentHealthy` < `minAvailable` бюджет 0, и даже неработающие поды выселить нельзя. `unhealthyPodEvictionPolicy: AlwaysAllow` разрешает выселять неготовые поды — их выселение не снижает доступность.

**7. Как вывести на обслуживание узел с БД на локальном диске?**
Нельзя просто drain: под не переедет (PV привязан к узлу) — простой до возвращения узла. Нужно: switchover primary на реплику на другом узле, затем drain; PDB, не позволяющий выселить primary без этого; или перенос данных (снапшот/бэкап) — и это уже миграция, а не drain.

**8. Как связаны пороги вытеснения kubelet и allocatable?**
`allocatable = capacity − kube-reserved − system-reserved − evictionHard`: scheduler не поставит поды на память, которую kubelet всё равно освободил бы вытеснением. Слишком высокий порог «съедает» allocatable (на стенде порог 14900Mi оставил 1 ГиБ), слишком низкий — узел упирается в OOM ядра раньше, чем kubelet успевает выселять.

---

## ⚠️ Подводные камни

- `minAvailable: 1` при одной реплике — drain не пройдёт никогда.
- Неготовые поды блокируют PDB без `unhealthyPodEvictionPolicy: AlwaysAllow`.
- Отказавший drain оставляет узел cordon'нутым.
- `--disable-eviction` обходит PDB.
- Drain узла с local-томами = простой их подов до возвращения узла.
- Вытеснение kubelet'ом PDB не учитывает; выселенный голый под не вернётся.
- Порог `evictionHard` вычитается из allocatable.
- В kind kubelet не видит давления памяти хоста; пороги eviction по умолчанию выключены.
- `shutdownGracePeriod: 0` — перезагрузка узла убивает поды без SIGTERM.

---

## Чеклист

- [ ] Отличу добровольные прерывания от недобровольных и где действует PDB.
- [ ] Настрою PDB (`maxUnavailable`, `AlwaysAllow`) и проверю бюджет.
- [ ] Сделаю drain с нужными флагами и разберу зависший drain.
- [ ] Объясню, что будет с подом на local-томе при drain.
- [ ] Объясню пороги и порядок вытеснения kubelet'ом и их связь с allocatable.

---

## Задание со звёздочкой

Отрепетируйте обслуживание узла со сквозным сценарием без простоя:

1. Поднимите orders-api до 3 реплик с spread по узлам (05-2) и PDB `maxUnavailable: 1, AlwaysAllow`.
2. Подумайте, что делать с PostgreSQL на local-томе: можно ли его вывести с узла без простоя на стенде? (Подсказка: нет — какие варианты дали бы оператор и реплика, 09-1?)
3. Сделайте drain узла, где нет PostgreSQL, под нагрузкой (`load.py` из 02-2) и посчитайте ошибки. Добейтесь нуля (graceful shutdown — 02-5).
4. Включите на одном worker'е `shutdownGracePeriod: 30s, shutdownGracePeriodCriticalPods: 10s` и посмотрите в логе kubelet при `docker restart` узла, что изменилось (⚠️ systemd-inhibit в узле kind может не сработать — проверьте и отметьте).

---

→ Следующая часть: **06-2. Pod Security и admission** — модуль «Доступ и безопасность»: securityContext, Pod Security Standards и Admission (enforce/warn/audit), политики admission. Часть 06-1 в этой версии курса не опубликована (00-plan §0).
