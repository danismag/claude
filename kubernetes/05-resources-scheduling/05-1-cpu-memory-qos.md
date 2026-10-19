# 05-1. Requests, limits и QoS

> Модуль 5 «Ресурсы и планирование» · часть 1 из 4 · 🟢🟡🔴 · ~1,5 ч чтения + ~1 ч лабы · Нужно: стенд 00-1 (kind 1+3, Kubernetes 1.36.1, metrics-server), образ `python:3.12-slim`

---

## Зачем это DevOps-у

Ресурсы — источник половины «странных» проблем в кластере. Под перезапускается раз в час с кодом 137 — достиг лимита памяти. После «наведения порядка» с лимитами p99 вырос в пять раз при загрузке CPU 20% — сработал троттлинг. Под Pending — не хватает requests на узлах, хотя реальная загрузка низкая. Новый сервис не создаётся — namespace упёрся в ResourceQuota. Все четыре ситуации разбираются по одной механике: что scheduler, kubelet и ядро Linux делают с числами из `resources`.

На собеседовании вопрос «чем requests отличаются от limits» задают почти всегда. Слабый ответ — «минимум и максимум». Сильный — про то, кто и где использует каждое число: scheduler суммирует requests, ядро превращает requests CPU в вес, а limits — в квоту и жёсткий потолок памяти; отсюда QoS, порядок OOM и троттлинг.

В сквозном сценарии `curl http://orders.localhost:8088/api/orders` эта часть отвечает за последнее звено — под orders-api: сколько CPU и памяти ему гарантировано, что будет, когда он попросит больше, и как это видно в метриках.

---

## 1. Что такое requests и limits 🟢

```yaml
resources:
  requests:            # сколько поду гарантировано; по этим числам планирует scheduler
    cpu: 250m          # 250 милликоров = 0,25 ядра
    memory: 256Mi      # мебибайты (2^20); 256M — мегабайты (10^6), не путать
  limits:              # потолок, который обеспечивает ядро
    cpu: "1"
    memory: 512Mi
```

| | requests | limits |
|---|---|---|
| Кто использует | scheduler (куда поставить под), kubelet (QoS, eviction), ядро (вес CPU) | ядро через cgroup: квота CPU, потолок памяти |
| CPU | доля процессора при конкуренции (`cpu.weight`) | квота за период 100 мс (`cpu.max`) — **троттлинг** |
| Память | учитывается при планировании и вытеснении, в cgroup не пишется | `memory.max` — превысил = **OOMKilled** |
| Если не указаны | 0 (или из LimitRange) | без ограничения (или из LimitRange) |
| Если указан только limit | request = limit (подставляется автоматически) | — |

Единицы: CPU — ядра (`1`, `0.5`, `500m`); память — `Ki/Mi/Gi` (двоичные) или `k/M/G` (десятичные). `1Gi` = 1073741824 байт, `1G` = 1000000000 — разница 7%.

Посмотреть, сколько запрошено на узле: `kubectl describe node <узел>` → раздел `Allocated resources`. Реальное потребление — `kubectl top pod/node` (нужен metrics-server).

## 2. Requests и планирование 🟢🟡

Scheduler ставит под на узел, если **сумма requests уже размещённых подов + request нового ≤ allocatable узла**. Реальная загрузка узла scheduler не интересует: узел может быть загружен на 5%, но «занят» по requests на 100% — новый под будет Pending. Обратное тоже верно: requests занижены — scheduler наставит на узел больше подов, чем тот вытянет.

```
allocatable = capacity − kube-reserved − system-reserved − порог eviction
```

Сообщение scheduler'а, когда места нет (проверено, запрос 20Gi на узлах по ~15,5Gi):

```
0/4 nodes are available: 1 node(s) had untolerated taint(s), 3 Insufficient memory.
no new claims to deallocate, preemption: 0/4 nodes are available: 4 Preemption is not helpful for scheduling.
```

Читать его по частям: control-plane отсеян taint'ом, у трёх worker'ов не хватает памяти, вытеснение менее приоритетных подов не поможет. Подробно scheduler — 05-2.

**Limits при планировании не учитываются.** Под с `requests.memory: 64Mi` и `limits.memory: 40Gi` спокойно запускается на узле с 15,5Gi (проверено: `greedy 1/1 Running`). Сумма limits на узле может быть сколь угодно больше его памяти — это **overcommit**, `kubectl describe node` прямо предупреждает: `Total limits may be over 100 percent, i.e., overcommitted`.

## 3. CPU: вес и квота 🟡

На cgroup v2 (Ubuntu 22.04+, Manjaro, узлы kind) kubelet и runc превращают числа в файлы cgroup контейнера:

| Поле | Файл cgroup v2 | Что делает ядро |
|---|---|---|
| `requests.cpu` | `cpu.weight` (1…10000) | при конкуренции за CPU делит время пропорционально весам; если CPU свободен — бери сколько хочешь |
| `limits.cpu` | `cpu.max` = `квота период` | за каждый период 100 мс процессы контейнера суммарно получают не больше квоты; кончилась — ждут следующего периода (**throttling**) |

Значения со стенда (проверено, `cat /sys/fs/cgroup/cpu.*` внутри контейнера):

| Под | resources | `cpu.max` | `cpu.weight` |
|---|---|---|---|
| guaranteed | req = lim = 500m | `50000 100000` | 59 |
| burstable | req 250m, без CPU-лимита | `max 100000` | 35 |
| besteffort | ничего | `max 100000` | 1 |

`50000 100000` — 50 мс CPU на каждые 100 мс, то есть 0,5 ядра. Вес считается из «старых» cgroup v1 shares (`250m` → 256 shares). Формулу перевода shares → weight runc поменял: в старых версиях она была линейной (`500m` → 20, `250m` → 10), в новых — квадратичной (на стенде, containerd 2.3.1: 59 и 35). На собеседовании важна не цифра, а принцип: **вес работает только при конкуренции, квота — всегда**.

### Почему CPU limit бьёт по задержкам 🔴

Квота считается суммарно по всем потокам контейнера. Лимит `1` CPU и четыре потока, которые одновременно проснулись обработать запросы: за 25 мс они съедают 100 мс квоты, и следующие 75 мс контейнер стоит — даже если у узла простаивают 10 ядер. Средняя загрузка в мониторинге при этом низкая (за минуту набирается 20%), а хвост задержек растёт.

Замер на стенде (проверено): «запрос» — ~100 мс чистого CPU (цикл на Python):

| Под | 1 запрос | 4 запроса одновременно |
|---|---|---|
| без CPU-лимита (request 200m) | 93–100 мс | 97–102 мс каждый |
| limit 200m | 414–512 мс | — |
| limit 500m | 157 мс | 798–1100 мс |

Отсюда распространённая практика: **для CPU — requests обязательно, limits — только по осознанной причине** (жёсткая мультиарендность, предсказуемость для бенчмарков, лицензирование по ядрам). Это «зависит, уточню»: в кластерах с чужими командами без лимитов один под может съесть весь узел — но это решается правильными requests (вес) и квотами namespace, а не квотой в каждом поде.

### Где смотреть троттлинг 🔴

`cpu.stat` в cgroup: `nr_periods` (сколько периодов контейнер был активен), `nr_throttled` (в скольких упёрся в квоту), `throttled_usec` (сколько простоял). В Prometheus это `container_cpu_cfs_throttled_periods_total / container_cpu_cfs_periods_total` из cAdvisor.

Ловушка, найденная на стенде: kubelet ставит ту же квоту и на **cgroup пода** (родителя контейнеров), и троттлинг может учитываться на нём, а не на контейнере. После трёх «запросов» под лимитом 200m (проверено):

```
pod-слайс:  cpu.max 20000 100000   nr_periods 27  nr_throttled 19  throttled_usec 1375470
контейнер:  cpu.max 20000 100000   nr_periods 22  nr_throttled 2   throttled_usec 43016
```

Задержка выросла в пять раз, а счётчик контейнера показывает 2 периода и 43 мс. Если метрика троттлинга «почти ноль», а задержки растут ровно на CPU-лимите — проверьте cgroup пода на узле (лаба, шаг 4). Распределение учёта между уровнями зависит от ядра; на стенде — Linux 6.18.

### CPU внутри контейнера 🔴

`nproc` в контейнере с лимитом 500m показывает **12** (все ядра хоста; проверено). Рантаймы, которые размеряют пулы потоков по числу ядер, без настройки создадут 12 потоков под квоту в половину ядра — и будут троттлиться ещё сильнее:

- Go до 1.25 — `GOMAXPROCS` = число ядер хоста (раньше использовали `automaxprocs`); с Go 1.25 учитывает CPU-лимит cgroup;
- JVM 10+ понимает cgroup (`-XX:ActiveProcessorCount` для явной настройки);
- Python — `os.cpu_count()` возвращает ядра хоста; число воркеров (gunicorn, uvicorn) задавайте явно.

## 4. Память: потолок и OOM 🟡

`limits.memory` → `memory.max` cgroup контейнера. Процесс выделяет больше — ядро сначала пытается освободить page cache внутри cgroup, не вышло — **OOM killer cgroup** убивает процесс. Kubelet видит `reason: OOMKilled`, `exitCode: 137` (128 + 9, SIGKILL) и перезапускает контейнер по `restartPolicy`.

`requests.memory` в cgroup не записывается (`memory.min = 0`, проверено) — он нужен scheduler'у и kubelet'у для вытеснения (05-4). Фича `MemoryQoS`, которая пишет его в `memory.min`/`memory.high`, по умолчанию выключена.

Что видно при OOM (проверено, лимит 128Mi, процесс выделяет 200 MiB):

```
NAME   READY   STATUS      RESTARTS      AGE
oom    0/1     OOMKilled   3 (30s ago)   45s

lastState: {"terminated":{"exitCode":137,"reason":"OOMKilled", ...}}
```

В `kubectl get events` при этом **нет** события OOM — только `BackOff restarting failed container`. Причина видна в `lastState` контейнера (`kubectl describe pod` → `Last State: Terminated, Reason: OOMKilled`) и в журнале ядра узла (`sudo dmesg` или `journalctl -k`):

```
Memory cgroup out of memory: Killed process 874590 (python) total-vm:218992kB, anon-rss:129904kB ... oom_score_adj:996
Tasks in /.../kubelet-kubepods-burstable-pod.../cri-containerd-....scope are going to be killed due to memory.oom.group set
```

### `memory.oom.group` 🔴

На cgroup v2 в Kubernetes 1.32+ kubelet ставит `memory.oom.group = 1` (проверено: у всех трёх подов `oom.group=1`). Ядро при OOM убивает **все процессы контейнера**, а не только самый «тяжёлый». Раньше, если в контейнере были PID 1 (`sh`, супервизор) и воркеры, OOM убивал одного воркера, контейнер продолжал жить «полуживым», и `OOMKilled` в статусе не появлялся. Вернуть старое поведение можно флагом kubelet `singleProcessOOMKill: true` — обычно незачем.

### Что не входит в лимит памяти — и что входит

В `memory.max` учитывается **page cache** контейнера (файлы, которые он читал и писал) и tmpfs (`emptyDir: {medium: Memory}`). Page cache ядро вытесняет перед OOM, поэтому «память почти на лимите» у сервиса с активным диском — ещё не беда. Метрика, по которой kubelet и `kubectl top` судят о памяти, — **working set** = usage − неактивный файловый кэш.

JVM, Node.js и Go не знают о лимите, если их не настроить: `-XX:MaxRAMPercentage=75`, `--max-old-space-size`, `GOMEMLIMIT`. Иначе heap растёт до лимита cgroup — и контейнер убивает ядро, а не GC рантайма.

## 5. QoS-классы 🟡

Kubelet выводит класс из `resources` всех контейнеров пода:

| QoS | Условие | `oom_score_adj` (проверено) | Кого убивают/вытесняют |
|---|---|---|---|
| **Guaranteed** | у каждого контейнера requests = limits по CPU и памяти | −997 | последним |
| **Burstable** | хотя бы один request или limit, но не Guaranteed | 2…999: `1000 − 1000 × request / память узла` (на стенде: 128Mi → 992, 64Mi → 996) | в середине; чем меньше request относительно потребления — тем раньше |
| **BestEffort** | ничего не задано | 1000 | первым |

`oom_score_adj` работает, когда кончается память **всего узла** (глобальный OOM killer ядра), — ориентир для ядра, кого убить. Kubelet при давлении на память (05-4) выселяет поды в похожем порядке: сначала те, кто превысил свой request, затем по приоритету и превышению.

QoS также определяет cgroup-слайс пода: `kubepods-besteffort.slice`, `kubepods-burstable.slice`, Guaranteed — прямо в `kubepods.slice`.

Частая практика — память request = limit, CPU только request (без лимита). Класс при этом Burstable, и это нормально: по памяти под защищён (не превышает свой request — не первый кандидат на вытеснение), а Guaranteed нужен в основном для CPU Manager со `static`-политикой (выделенные целые ядра) и для самых критичных подов.

## 6. LimitRange и ResourceQuota 🟡

| | LimitRange | ResourceQuota |
|---|---|---|
| Уровень | контейнер/под в namespace | namespace в сумме |
| Что делает | подставляет `default`/`defaultRequest`, проверяет `min`/`max`/`maxLimitRequestRatio` | ограничивает сумму `requests.*`, `limits.*`, число объектов (`pods`, `services`, `persistentvolumeclaims`…) |
| Когда срабатывает | admission при создании пода | admission при создании объекта |

Ловушка (проверено): если в квоте есть `requests.cpu`/`limits.memory`, **каждый** под в namespace обязан их указать — иначе отказ:

```
Error from server (Forbidden): pods "nores" is forbidden: failed quota: team-quota:
must specify limits.memory for: nores; requests.cpu for: nores; requests.memory for: nores
```

Поэтому квоту всегда ставят вместе с LimitRange, который подставит значения по умолчанию. Второе: квота отказывает **созданию пода**, а не Deployment'у — Deployment создаётся, а ReplicaSet молча не добирает реплики. `kubectl get deploy` покажет `7/12`, причина — в событиях ReplicaSet (`exceeded quota`), не в событиях Deployment.

## 7. Изменение ресурсов без перезапуска (in-place resize) 🔴

С Kubernetes 1.35 изменение `resources` работающего пода — стабильная функция (на стенде 1.36 работает без feature gates, проверено). Меняется через подресурс `resize`:

```bash
kubectl patch pod cpu-limited --subresource resize \
  --patch '{"spec":{"containers":[{"name":"app","resources":{"requests":{"cpu":"500m"},"limits":{"cpu":"500m"}}}]}}'
```

Kubelet меняет cgroup на лету (`cpu.max` 20000 → 50000, `restarts=0`). Ограничения:

- **QoS-класс не может измениться** (проверено: `Pod QOS Class may not change as a result of resizing`);
- уменьшение лимита памяти ниже текущего потребления kubelet не применит: spec изменится, а в status останется старый лимит и условие `PodResizeInProgress=True` с причиной `Error` (проверено, шаг 5) — ядро не может «отобрать» занятую память без OOM;
- `resizePolicy` контейнера задаёт, нужен ли рестарт (`NotRequired` по умолчанию; `RestartContainer` для рантаймов, которые читают лимит при старте — JVM);
- Deployment так не меняется: правка шаблона Deployment всё равно создаёт новые поды. Resize — инструмент VPA (in-place mode) и ручной «пожарной» правки.

## 8. Ephemeral storage 🟡

Диск узла — тоже ресурс: логи контейнеров, слой записи контейнера, `emptyDir`. `requests/limits.ephemeral-storage` работают иначе, чем память: ядро их не ограничивает, kubelet **периодически измеряет** потребление и выселяет под при превышении (проверено, лимит 50Mi, запись 100 MiB — выселен через ~20 с):

```
Pod ephemeral local storage usage exceeds the total limit of containers 50Mi.
```

Под в статусе `Failed`, `reason: Evicted`; при этом `kubectl get pod` в колонке STATUS показывает `Error` — ищите `Evicted` в `-o yaml` или `describe`.

---

## 🔧 Лаба

Цель: увидеть своими глазами, во что превращаются `resources` — cgroup, QoS, OOM, троттлинг, отказы квоты и admission.

Все команды — с хоста, `kubectl` с контекстом `kind-lab` (00-1). Выводы ниже — со стенда автора: kind 0.32.0, Kubernetes 1.36.1, containerd 2.3.1, ядро 6.18, у узлов по 12 CPU и ~15,5Gi. Ваши номера процессов, имена узлов и миллисекунды будут другими — сверяйте порядок величин.

### Шаг 0. Подготовка

```bash
kubectl config use-context kind-lab
kubectl top nodes                            # metrics-server работает
kubectl create ns lab-05-1
kubectl config set-context --current --namespace=lab-05-1
kubectl get node lab-worker -o jsonpath='{.status.allocatable}{"\n"}'
```

Проверено:

```
NAME                CPU(cores)   CPU(%)   MEMORY(bytes)   MEMORY(%)
lab-control-plane   95m          0%       646Mi           4%
lab-worker          15m          0%       134Mi           0%
...
{"cpu":"12","ephemeral-storage":"102626232Ki",...,"memory":"16315248Ki","pods":"110"}
```

Обратите внимание: allocatable = capacity. Узлы kind — контейнеры на одном хосте, каждый видит **все** 12 CPU и 16 ГБ, резервов нет. В реальном кластере allocatable меньше capacity на kube-reserved/system-reserved и порог eviction.

### Шаг 1. Три QoS-класса и их cgroup

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata: {name: guaranteed}
spec:
  containers:
  - name: app
    image: python:3.12-slim
    command: ["sleep", "infinity"]
    resources:
      requests: {cpu: 500m, memory: 256Mi}
      limits:   {cpu: 500m, memory: 256Mi}
---
apiVersion: v1
kind: Pod
metadata: {name: burstable}
spec:
  containers:
  - name: app
    image: python:3.12-slim
    command: ["sleep", "infinity"]
    resources:
      requests: {cpu: 250m, memory: 128Mi}
      limits:   {memory: 256Mi}
---
apiVersion: v1
kind: Pod
metadata: {name: besteffort}
spec:
  containers:
  - name: app
    image: python:3.12-slim
    command: ["sleep", "infinity"]
EOF
kubectl wait --for=condition=Ready pod --all --timeout=90s

for p in guaranteed burstable besteffort; do
  echo "== $p qos=$(kubectl get pod $p -o jsonpath='{.status.qosClass}')"
  kubectl exec $p -- sh -c 'echo cpu.max=$(cat /sys/fs/cgroup/cpu.max) cpu.weight=$(cat /sys/fs/cgroup/cpu.weight) \
    memory.max=$(cat /sys/fs/cgroup/memory.max) memory.min=$(cat /sys/fs/cgroup/memory.min) \
    oom.group=$(cat /sys/fs/cgroup/memory.oom.group) oom_score_adj=$(cat /proc/1/oom_score_adj) nproc=$(nproc)'
done
```

Проверено:

```
== guaranteed qos=Guaranteed
cpu.max=50000 100000 cpu.weight=59 memory.max=268435456 memory.min=0 oom.group=1 oom_score_adj=-997 nproc=12
== burstable qos=Burstable
cpu.max=max 100000 cpu.weight=35 memory.max=268435456 memory.min=0 oom.group=1 oom_score_adj=992 nproc=12
== besteffort qos=BestEffort
cpu.max=max 100000 cpu.weight=1 memory.max=max memory.min=0 oom.group=1 oom_score_adj=1000 nproc=12
```

Что видно: CPU-лимит есть только у guaranteed (`50000 100000`); request памяти нигде не попал в cgroup (`memory.min=0`); у BestEffort нет потолка памяти; `nproc` у всех 12. Посчитайте `oom_score_adj` burstable сами: `1000 − 1000 × 128Mi / 15933Mi ≈ 992`.

Сколько «занято» на узле с точки зрения scheduler'а:

```bash
kubectl describe node $(kubectl get pod burstable -o jsonpath='{.spec.nodeName}') | sed -n '/Allocated resources/,/Events/p'
```

Проверено (на этом узле оказались burstable и системные поды):

```
  Resource           Requests    Limits
  cpu                350m (2%)   100m (0%)
  memory             178Mi (1%)  306Mi (1%)
```

### Шаг 2. OOMKilled

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata: {name: oom}
spec:
  containers:
  - name: app
    image: python:3.12-slim
    command: ["python", "-c", "import time; print('allocating 200 MiB', flush=True); b = bytearray(200*1024*1024); time.sleep(3600)"]
    resources:
      requests: {memory: 64Mi}
      limits:   {memory: 128Mi}
EOF
sleep 45
kubectl get pod oom
kubectl get pod oom -o jsonpath='{.status.containerStatuses[0].lastState}{"\n"}'
kubectl get events --field-selector involvedObject.name=oom -o custom-columns=REASON:.reason,COUNT:.count,MSG:.message
```

Проверено:

```
NAME   READY   STATUS      RESTARTS      AGE
oom    0/1     OOMKilled   3 (30s ago)   45s
{"terminated":{"containerID":"containerd://e58d…","exitCode":137,"finishedAt":"2026-10-14T07:53:47Z","reason":"OOMKilled","startedAt":"2026-10-14T07:53:47Z"}}
REASON      COUNT   MSG
Scheduled   1       Successfully assigned lab-05-1/oom to lab-worker3
Pulled      4       Container image "python:3.12-slim" already present on machine ...
Created     4       Container created
Started     4       Container started
BackOff     3       Back-off restarting failed container app in pod oom_lab-05-1(...)
```

Событий про OOM нет — смотрите `lastState`. Журнал ядра (на узле kind — `docker exec lab-worker3 dmesg`, на обычном узле — `sudo dmesg` или `journalctl -k`):

```bash
docker exec $(kubectl get pod oom -o jsonpath='{.spec.nodeName}') dmesg | grep -iE 'out of memory|oom.group' | tail -2
```

Проверено:

```
Memory cgroup out of memory: Killed process 874590 (python) total-vm:218992kB, anon-rss:129904kB, file-rss:5540kB, shmem-rss:0kB, UID:0 pgtables:320kB oom_score_adj:996
Tasks in /system.slice/docker-…scope/kubelet.slice/kubelet-kubepods.slice/kubelet-kubepods-burstable.slice/kubelet-kubepods-burstable-pode5e9….slice/cri-containerd-fa1a….scope are going to be killed due to memory.oom.group set
```

`anon-rss:129904kB` — ровно лимит 128Mi; `oom_score_adj:996` — Burstable с request 64Mi.

Попробуйте `kubectl logs oom --previous`. На стенде в момент между перезапусками команда несколько раз вернула `unable to retrieve container logs for containerd://…` — kubelet уже удалил лог предыдущего экземпляра. Повтор через несколько секунд или после следующего старта показывает лог. При разборе OOM полагайтесь на `lastState`, а не на логи: процесс, убитый SIGKILL, ничего не успевает записать.

### Шаг 3. Как растёт пауза CrashLoopBackOff

Связано с OOM: контейнер, который падает снова и снова, kubelet перезапускает с растущей паузой.

```bash
kubectl delete pod oom --now
kubectl run crash --image=python:3.12-slim -- python -c 'print("boom"); raise SystemExit(3)'
# каждую секунду печатать момент, когда вырос restartCount (~7 минут)
prev=-1; t0=$(date +%s); while [ $(( $(date +%s)-t0 )) -lt 420 ]; do
  r=$(kubectl get pod crash -o jsonpath='{.status.containerStatuses[0].restartCount}')
  [ "$r" != "$prev" ] && echo "t=+$(( $(date +%s)-t0 ))s restarts=$r" && prev=$r; sleep 1; done
kubectl logs crash --previous
kubectl get pod crash -o jsonpath='{.status.containerStatuses[0].lastState.terminated.exitCode}{"\n"}'
```

Проверено:

```
t=+0s restarts=0
t=+1s restarts=1
t=+15s restarts=2
t=+46s restarts=3
t=+104s restarts=4
t=+187s restarts=5
t=+360s restarts=6
boom
3
```

Интервалы 14, 31, 58, 83, 173 с — это back-off 10, 20, 40, 80, 160 с плюс несколько секунд на старт и цикл kubelet. Дальше пауза упирается в потолок 5 минут. Счётчик back-off сбрасывается, если контейнер проработал 10 минут без падения. Подробнее про жизненный цикл — 02-1.

### Шаг 4. Троттлинг CPU

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata: {name: cpu-limited}
spec:
  containers:
  - name: app
    image: python:3.12-slim
    command: ["sleep", "infinity"]
    resources:
      requests: {cpu: 200m, memory: 64Mi}
      limits:   {cpu: 200m, memory: 128Mi}
---
apiVersion: v1
kind: Pod
metadata: {name: cpu-free}
spec:
  containers:
  - name: app
    image: python:3.12-slim
    command: ["sleep", "infinity"]
    resources:
      requests: {cpu: 200m, memory: 64Mi}
      limits:   {memory: 128Mi}
EOF
kubectl wait --for=condition=Ready pod/cpu-limited pod/cpu-free --timeout=60s

cat > /tmp/work.py <<'EOF'
import time
def job():                      # ~100 мс CPU на «запрос»
    s = 0
    for i in range(2_000_000): s += i
t = time.perf_counter(); job(); print(f"one request: {(time.perf_counter()-t)*1000:.0f} ms")
EOF
for p in cpu-free cpu-limited; do
  echo "== $p"; kubectl cp /tmp/work.py $p:/tmp/work.py
  kubectl exec $p -- sh -c 'grep throttled /sys/fs/cgroup/cpu.stat; for i in 1 2 3; do python /tmp/work.py; done; grep throttled /sys/fs/cgroup/cpu.stat'
done
```

Проверено:

```
== cpu-free
nr_throttled 0
throttled_usec 0
one request: 100 ms
one request: 93 ms
one request: 93 ms
nr_throttled 0
throttled_usec 0
== cpu-limited
nr_throttled 0
throttled_usec 0
one request: 512 ms
one request: 414 ms
one request: 501 ms
nr_throttled 2
throttled_usec 43016
```

Задержка ×5 — а счётчик контейнера показывает всего 43 мс троттлинга. Посмотрите cgroup **пода** на узле:

```bash
N=$(kubectl get pod cpu-limited -o jsonpath='{.spec.nodeName}')
U=$(kubectl get pod cpu-limited -o jsonpath='{.metadata.uid}' | tr - _)
docker exec $N sh -c "d=\$(find /sys/fs/cgroup -type d -name '*pod${U}.slice'); \
  echo pod: \$(cat \$d/cpu.max); grep -E 'nr_periods|nr_throttled|throttled_usec' \$d/cpu.stat; \
  for c in \$d/cri-containerd-*; do echo ctr: \$(cat \$c/cpu.max); grep -E 'nr_periods|nr_throttled|throttled_usec' \$c/cpu.stat; done"
```

Проверено:

```
pod: 20000 100000
nr_periods 27
nr_throttled 19
throttled_usec 1375470
ctr: 20000 100000
nr_periods 22
nr_throttled 2
throttled_usec 43016
ctr: max 100000
nr_periods 0
nr_throttled 0
throttled_usec 0
```

Реальный троттлинг — 19 из 27 периодов и 1,4 с простоя — учтён на уровне пода. Второй `ctr` без лимита — pause-контейнер. На обычном узле путь `/sys/fs/cgroup/kubepods.slice/kubepods-burstable.slice/kubepods-burstable-pod<uid>.slice/` (без префикса `kubelet-` и `docker-…scope`, которые есть только в kind).

Теперь «всплеск» — четыре запроса одновременно. Сначала поднимите лимит до 500m без перезапуска (§7):

```bash
kubectl patch pod cpu-limited --subresource resize \
  --patch '{"spec":{"containers":[{"name":"app","resources":{"requests":{"cpu":"500m"},"limits":{"cpu":"500m"}}}]}}'
kubectl get pod cpu-limited -o jsonpath='restarts={.status.containerStatuses[0].restartCount} spec={.spec.containers[0].resources.limits.cpu} status={.status.containerStatuses[0].resources.limits.cpu}{"\n"}'
kubectl exec cpu-limited -- cat /sys/fs/cgroup/cpu.max
for p in cpu-free cpu-limited; do echo "== $p"; kubectl exec $p -- sh -c 'for i in 1 2 3 4; do python /tmp/work.py & done; wait'; done
```

Проверено:

```
pod/cpu-limited patched
restarts=0 spec=500m status=500m
50000 100000
== cpu-free
one request: 97 ms
one request: 97 ms
one request: 97 ms
one request: 102 ms
== cpu-limited
one request: 798 ms
one request: 903 ms
one request: 1092 ms
one request: 1100 ms
```

Без лимита четыре запроса ушли на четыре свободных ядра — по 100 мс. С лимитом 500m им досталось 50 мс CPU на 100 мс времени на всех — 0,8–1,1 с на запрос.

### Шаг 5. Resize: что нельзя

```bash
# req=lim и по CPU, и по памяти → класс стал бы Guaranteed
kubectl patch pod cpu-limited --subresource resize \
  --patch '{"spec":{"containers":[{"name":"app","resources":{"limits":{"memory":"64Mi"}}}]}}'
# класс остаётся Burstable — пройдёт
kubectl patch pod cpu-limited --subresource resize \
  --patch '{"spec":{"containers":[{"name":"app","resources":{"limits":{"memory":"100Mi"}}}]}}'
kubectl exec cpu-limited -- cat /sys/fs/cgroup/memory.max
```

Проверено:

```
The Pod "cpu-limited" is invalid: spec: Invalid value: "Burstable": Pod QOS Class may not change as a result of resizing
pod/cpu-limited patched
104857600
```

Уменьшить лимит ниже того, что процесс уже занял:

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata: {name: hold}
spec:
  containers:
  - name: app
    image: python:3.12-slim
    command: ["python", "-c", "import time; b = bytearray(100*1024*1024); time.sleep(3600)"]
    resources:
      requests: {memory: 64Mi}
      limits:   {memory: 200Mi}
EOF
kubectl wait --for=condition=Ready pod/hold --timeout=60s
kubectl exec hold -- cat /sys/fs/cgroup/memory.current          # ~111 MiB
kubectl patch pod hold --subresource resize \
  --patch '{"spec":{"containers":[{"name":"app","resources":{"limits":{"memory":"80Mi"}}}]}}'
sleep 15
kubectl get pod hold -o jsonpath='restarts={.status.containerStatuses[0].restartCount} spec={.spec.containers[0].resources.limits.memory} status={.status.containerStatuses[0].resources.limits.memory}{"\n"}{range .status.conditions[?(@.type=="PodResizeInProgress")]}{.type}={.status} {.reason} {.message}{"\n"}{end}'
kubectl exec hold -- cat /sys/fs/cgroup/memory.max
```

Проверено:

```
116695040
pod/hold patched
restarts=0 spec=80Mi status=200Mi
PodResizeInProgress=True Error cannot decrease memory limits: attempting to set container "app" memory limit (83886080) below current usage (0)
209715200
```

Через минуту то же условие (проверено):

```
PodResizeInProgress=True Error cannot decrease memory limits: [attempting to set pod memory limit (83886080) below current usage (109793280), attempting to set container "app" memory limit (83886080) below current usage (109793280)]
```

Spec говорит 80Mi, а действует по-прежнему 200Mi: status и cgroup не изменились. Разбирая «почему под живёт с потреблением выше лимита в манифесте», сравнивайте `spec` с `status.containerStatuses[].resources`. В первой попытке kubelet 1.36 написал `current usage (0)` — статистика ещё не была собрана; при следующей проверке в сообщении реальные 109793280 байт и для пода, и для контейнера.

### Шаг 6. Планирование по requests, а не по limits

```bash
kubectl run big --image=python:3.12-slim --overrides='{"spec":{"containers":[{"name":"big","image":"python:3.12-slim","command":["sleep","infinity"],"resources":{"requests":{"memory":"20Gi"}}}]}}'
kubectl run greedy --image=python:3.12-slim --overrides='{"spec":{"containers":[{"name":"greedy","image":"python:3.12-slim","command":["sleep","infinity"],"resources":{"requests":{"memory":"64Mi"},"limits":{"memory":"40Gi"}}}]}}'
sleep 5; kubectl get pod big greedy
kubectl get events --field-selector involvedObject.name=big,reason=FailedScheduling -o jsonpath='{.items[0].message}{"\n"}'
kubectl delete pod big greedy --now
```

Проверено:

```
NAME     READY   STATUS    RESTARTS   AGE
big      0/1     Pending   0          5s
greedy   1/1     Running   0          5s
0/4 nodes are available: 1 node(s) had untolerated taint(s), 3 Insufficient memory. no new claims to deallocate, preemption: 0/4 nodes are available: 4 Preemption is not helpful for scheduling.
```

Request 20Gi не помещается ни на один узел. Лимит 40Gi при request 64Mi помещается — scheduler лимит не смотрит.

### Шаг 7. ResourceQuota и LimitRange

```bash
kubectl create ns lab-05-1q
kubectl -n lab-05-1q apply -f - <<'EOF'
apiVersion: v1
kind: ResourceQuota
metadata: {name: team-quota}
spec:
  hard:
    requests.cpu: "1"
    requests.memory: 1Gi
    limits.memory: 2Gi
    pods: "10"
EOF
kubectl -n lab-05-1q run nores --image=python:3.12-slim -- sleep infinity     # отказ

kubectl -n lab-05-1q apply -f - <<'EOF'
apiVersion: v1
kind: LimitRange
metadata: {name: defaults}
spec:
  limits:
  - type: Container
    defaultRequest: {cpu: 100m, memory: 128Mi}
    default:        {memory: 256Mi}
    max:            {memory: 1Gi}
EOF
kubectl -n lab-05-1q run nores --image=python:3.12-slim -- sleep infinity     # теперь пройдёт
kubectl -n lab-05-1q get pod nores -o jsonpath='{.spec.containers[0].resources}{"\n"}'

kubectl -n lab-05-1q create deploy many --image=python:3.12-slim --replicas=12 -- sleep infinity
sleep 8; kubectl -n lab-05-1q get deploy many
kubectl -n lab-05-1q describe rs | grep -m1 'exceeded quota'
kubectl -n lab-05-1q get resourcequota team-quota

kubectl -n lab-05-1q run huge --image=python:3.12-slim \
  --overrides='{"spec":{"containers":[{"name":"huge","image":"python:3.12-slim","resources":{"limits":{"memory":"2Gi"}}}]}}'
```

Проверено:

```
Error from server (Forbidden): pods "nores" is forbidden: failed quota: team-quota: must specify limits.memory for: nores; requests.cpu for: nores; requests.memory for: nores
limitrange/defaults created
pod/nores created
{"limits":{"memory":"256Mi"},"requests":{"cpu":"100m","memory":"128Mi"}}
NAME   READY   UP-TO-DATE   AVAILABLE   AGE
many   7/12    7            7           8s
  Warning  FailedCreate  8s  replicaset-controller  Error creating: pods "many-66f9556c95-kzsd5" is forbidden: exceeded quota: team-quota, requested: limits.memory=256Mi,requests.memory=128Mi, used: limits.memory=2Gi,requests.memory=1Gi, limited: limits.memory=2Gi,requests.memory=1Gi
NAME         REQUEST                                                      LIMIT                    AGE
team-quota   pods: 8/10, requests.cpu: 800m/1, requests.memory: 1Gi/1Gi   limits.memory: 2Gi/2Gi   9s
Error from server (Forbidden): pods "huge" is forbidden: maximum memory usage per Container is 1Gi, but limit is 2Gi
```

Квота закончилась по памяти (1Gi/1Gi) раньше, чем по числу подов (8/10): `nores` + 7 реплик × 128Mi = 1Gi. Deployment создан, но доступны только 7 реплик из 12.

### Шаг 8. Ephemeral storage

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata: {name: disk}
spec:
  restartPolicy: Never
  containers:
  - name: app
    image: python:3.12-slim
    command: ["sh", "-c", "dd if=/dev/zero of=/tmp/fill bs=1M count=100 && echo written && sleep infinity"]
    resources:
      requests: {ephemeral-storage: 20Mi}
      limits:   {ephemeral-storage: 50Mi}
EOF
sleep 30; kubectl get pod disk
kubectl get pod disk -o jsonpath='{.status.phase}/{.status.reason}: {.status.message}{"\n"}'
```

Проверено (выселен примерно через 20–25 с):

```
NAME   READY   STATUS   RESTARTS   AGE
disk   0/1     Error    0          22s
Failed/Evicted: Pod ephemeral local storage usage exceeds the total limit of containers 50Mi.
```

### Уборка

```bash
kubectl config set-context --current --namespace=default
kubectl delete ns lab-05-1 lab-05-1q
rm -f /tmp/work.py
```

---

## 🔥 Кейс из прода: «добавили лимиты — p99 вырос в пять раз»

**Контекст.** Платформенная команда ввела правило: у каждого контейнера должны быть requests и limits. Для orders-api поставили `cpu: 500m` в requests и limits — по данным мониторинга сервис в среднем потреблял 150m. После выкатки p99 `/api/orders` вырос с 120 мс до 600–900 мс, средняя загрузка CPU пода — 20–25% от лимита, перезапусков нет, ошибок в логах нет.

**Разбор.**
1. `kubectl top pod` — 120–180m, «до лимита далеко». Это среднее за окно метрик (около 15 с у metrics-server) — оно не показывает, что происходит внутри 100-мс периода.
2. Метрика троттлинга контейнера `container_cpu_cfs_throttled_periods_total` росла слабо (на этом ядре троттлинг учитывался на cgroup пода — см. §3).
3. На узле в cgroup пода: `nr_throttled / nr_periods` ≈ 70%. Сервис на uvicorn с 8 воркерами (число задали по `os.cpu_count()` на узле с 32 ядрами, у контейнера — 0,5 ядра). Пачка из нескольких одновременных запросов съедала 50 мс квоты за 10–15 мс, остаток периода все воркеры стояли.
4. Воспроизведение на стенде — шаг 4 лабы: 4 одновременных «запроса» по 100 мс CPU под лимитом 500m выполняются 0,8–1,1 с, без лимита — 0,1 с.

**Фикс.**
- CPU limit сняли, request оставили 250m (с запасом над средним) — вес при конкуренции сохранился, всплески используют простаивающие ядра узла;
- число воркеров задали явно (2) переменной окружения, не по числу ядер узла;
- в правило платформы вписали: memory — request и limit обязательны; CPU — request обязателен, limit — по согласованию; защита от «шумного соседа» — квоты namespace и requests;
- в дашборд добавили троттлинг на уровне пода и p99 рядом.

**Что запомнить.**
- Квота CPU считается за каждые 100 мс по всем потокам — среднее потребление ниже лимита не значит, что троттлинга нет.
- Троттлинг ищут в `cpu.stat` (`nr_throttled`/`nr_periods`) — на уровне контейнера **и** пода.
- Рантайм видит ядра узла, а не лимит: пулы потоков и воркеров настраивают явно.

---

## 💼 Вопросы с собеседования

### 🟢 Junior

**1. Чем requests отличаются от limits?**
Requests — сколько гарантировано; scheduler ставит под на узел, где сумма requests помещается в allocatable. Limits — потолок, который держит ядро через cgroup: CPU сверх лимита — троттлинг (квота за 100 мс), память сверх лимита — OOMKilled. Limits при планировании не учитываются.

**2. Под перезапускается со статусом OOMKilled. Что это и что делать?**
Процесс превысил `limits.memory`, OOM killer cgroup убил его (SIGKILL, код 137), kubelet перезапустил. Смотреть `kubectl describe pod` → Last State, реальное потребление (`kubectl top`, метрики working set), настройки рантайма (heap JVM, `GOMEMLIMIT`). Решение — поднять лимит до реального пика или найти утечку; не убирать лимит памяти.

**3. Что значит `500m` и `256Mi`?**
0,5 ядра CPU и 256 мебибайт (256 × 2^20 байт). `256M` — мегабайты (10^6), на 5% меньше.

### 🟡 Middle

**4. Какие QoS-классы бывают и как их получить?**
Guaranteed — у всех контейнеров requests = limits по CPU и памяти; Burstable — что-то задано, но не Guaranteed; BestEffort — ничего. Класс задаёт `oom_score_adj` (−997 / 2…999 / 1000) и порядок вытеснения kubelet'ом при давлении на узле: BestEffort первым, Guaranteed последним.

**5. Под Pending, `Insufficient cpu`, а узлы загружены на 10%. Почему?**
Scheduler считает сумму requests, а не реальную загрузку. Requests у подов завышены (или выставлены «на всякий случай») — узлы «заняты» по бумагам. Смотреть `kubectl describe node` → Allocated resources; снижать requests по реальному потреблению (VPA в режиме рекомендаций), а не добавлять узлы.

**6. Зачем ResourceQuota и LimitRange и как они связаны?**
Quota ограничивает сумму ресурсов и число объектов в namespace; LimitRange подставляет значения по умолчанию и проверяет min/max для контейнера. Если в квоте есть `requests.cpu` и т. п., под без этих полей отклоняется — поэтому LimitRange с дефолтами ставят вместе с квотой. Квота отказывает созданию пода: Deployment создаётся, ReplicaSet не добирает реплики — причина в событиях ReplicaSet.

**7. Что происходит при превышении лимита CPU и почему это хуже, чем кажется?**
Процесс не убивают, а приостанавливают до конца 100-мс периода, когда квота исчерпана. Квота общая на все потоки: 4 потока под лимитом 1 CPU исчерпывают её за 25 мс и стоят 75 мс. Среднее потребление в мониторинге низкое, а p99 растёт. Видно в `cpu.stat` (`nr_throttled`, `throttled_usec`).

### 🔴 Senior

**8. Ставить ли CPU limits? Аргументируйте.**
Зависит. Против: троттлинг на всплесках ломает хвост задержек, простаивающие ядра узла не используются; защиту от «шумного соседа» даёт вес CPU через requests. За: строгая мультиарендность, предсказуемость (бенчмарки, SLA с гарантией верхней границы), CPU Manager static (нужен Guaranteed — значит, лимит = request и целые ядра), лицензирование. Типичная политика: requests CPU обязательны, limits CPU — по исключению; память — request и limit обязательны, обычно равны.

**9. Как kubelet и ядро ведут себя при OOM в контейнере с несколькими процессами?**
На cgroup v2 с Kubernetes 1.32+ kubelet ставит `memory.oom.group=1` — при OOM ядро убивает все процессы контейнера, контейнер завершается целиком, статус OOMKilled. Раньше убивался один процесс (с максимальным oom_score) — контейнер мог продолжить работу без воркера, и OOM в статусе не появлялся. Старое поведение — `singleProcessOOMKill: true` в конфиге kubelet.

**10. Можно ли поменять ресурсы пода без перезапуска?**
Да, in-place resize — stable с 1.35: `kubectl patch pod --subresource resize`. Kubelet меняет cgroup на лету; `resizePolicy` задаёт, нужен ли рестарт контейнера. Нельзя менять QoS-класс; уменьшение памяти ниже потребления не применится. Для Deployment правка шаблона всё равно создаёт новые поды; resize использует VPA in-place.

**11. Почему метрика троттлинга может показывать ноль при явном троттлинге?**
Квоту kubelet ставит и на cgroup пода, и на контейнер; ядро может учитывать троттлинг на родительском уровне — счётчики контейнера (cAdvisor `container_cpu_cfs_throttled_*`) при этом почти не растут. Проверять `cpu.stat` слайса пода на узле. Второй источник «нуля» — сэмплирование: средние за 15–60 с не показывают всплесков внутри 100-мс периодов.

---

## ⚠️ Подводные камни

- `limits` без `requests` — request становится равным limit. Поставили «только лимит 4Gi на всякий случай» — scheduler резервирует 4Gi на каждый под.
- `memory: 256M` вместо `256Mi` — на 5% меньше; `cpu: 0.1` и `100m` — одно и то же, а `cpu: 1m` — тысячная ядра (опечатка «1m» вместо «1» встречается).
- Квота с `requests.*` без LimitRange — любые поды без ресурсов (включая Job'ы из чужих чартов) не создаются.
- Отказ квоты виден в событиях ReplicaSet/Job, а не Deployment/CronJob.
- OOMKilled не создаёт событие — ищите в `lastState`/`describe`; `logs --previous` после SIGKILL обычно пустой и может быть недоступен в момент перезапуска.
- `kubectl top` — среднее за окно; троттлинг и короткие пики памяти в нём не видны.
- Рантайм видит все ядра узла (`nproc`, `os.cpu_count()`): размер пулов потоков и воркеров задавайте явно.
- Heap JVM/Node без настройки растёт до лимита cgroup — контейнер убивает ядро вместо GC.
- В kind allocatable = capacity хоста, у каждого узла: опыты «узел переполнен по памяти» на kind не воспроизводятся без настройки резервов (05-4).
- Evicted по ephemeral-storage в `kubectl get` выглядит как `Error`.
- Resize не меняет QoS и не работает для шаблона Deployment.

---

## Чеклист

- [ ] Могу объяснить, кто использует requests (scheduler, kubelet, `cpu.weight`) и кто limits (`cpu.max`, `memory.max`).
- [ ] Умею найти, сколько ресурсов «занято» на узле, и прочитать сообщение `Insufficient memory` от scheduler'а.
- [ ] Умею определить QoS пода и объяснить `oom_score_adj` для каждого класса.
- [ ] Могу по `lastState` и `dmesg` доказать, что контейнер убит OOM, и назвать код 137.
- [ ] Умею измерить троттлинг в `cpu.stat` контейнера и пода и объяснить, почему CPU limit бьёт по p99.
- [ ] Умею настроить ResourceQuota с LimitRange и найти, почему Deployment не добирает реплики.
- [ ] Умею изменить ресурсы пода через `--subresource resize` и знаю, что нельзя.
- [ ] Объясню на собеседовании, ставить ли CPU limits, с аргументами за и против.

---

## Задание со звёздочкой

Подберите requests и limits для orders-api по данным, а не на глаз:

1. Разверните orders-api (00-1) без CPU-лимита, с request 100m и лимитом памяти 512Mi.
2. Дайте нагрузку (`hey` или цикл `curl` из пода в namespace) на 3 минуты, снимайте каждые 5 с `kubectl top pod` и `cpu.stat`/`memory.current` из cgroup пода на узле.
3. Посчитайте p95 потребления CPU и максимум working set памяти. Поставьте request CPU = p95 + 20%, request = limit памяти = максимум + 25%.
4. Повторите нагрузку с CPU-лимитом = request и без него, сравните p99 задержки `/api/orders` и `nr_throttled/nr_periods`.
5. Оформите результат в виде таблицы и короткой рекомендации для команды сервиса: какой вариант и почему.

---

→ Следующая часть: **05-2. Scheduler** — nodeSelector, affinity и anti-affinity, taints и tolerations, topologySpreadConstraints, PriorityClass и вытеснение; читаем сообщения scheduler'а и разносим реплики orders-api по узлам так, чтобы отказ одного узла не ронял сервис.
