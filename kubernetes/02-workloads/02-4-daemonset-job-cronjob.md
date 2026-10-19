# 02-4. DaemonSet, Job, CronJob

> Модуль 2 «Workloads» · часть 4 из 5 · 🟢🟡🔴 · ~1 ч чтения + ~40 мин лабы (из них ~4 мин ожидания CronJob) · Нужно: стенд 00-1

---

## Зачем это DevOps-у

DaemonSet — это агенты на каждом узле: сбор логов и метрик, CNI, kube-proxy, CSI-драйверы, сканеры безопасности. Job и CronJob — миграции БД, бэкапы, отчёты, очистка. В DaemonSet ошибаются с tolerations («на control-plane агента нет — логов оттуда тоже»), в Job — с ретраями и таймаутами («миграция ретраится шесть раз и портит данные»), в CronJob — с параллельными запусками («бэкап молча не запускался неделю» — кейс этой части). На собеседовании просят объяснить `concurrencyPolicy`, `backoffLimit` и зачем `activeDeadlineSeconds`.

В сквозном сценарии CronJob будет делать бэкап PostgreSQL orders-api (04-3); здесь — на чём такой бэкап ломается.

---

## 1. DaemonSet 🟢🟡

По поду на каждый подходящий узел; новый узел — новый под, узел удалён — под удалён. Поды DaemonSet планирует обычный scheduler (через node affinity к конкретному узлу), поэтому на них действуют taints, `nodeSelector`, affinity.

Проверено: без tolerations DaemonSet встал на 3 worker'а — у `lab-control-plane` taint `node-role.kubernetes.io/control-plane:NoSchedule`. С toleration — на все 4:

```
NAME         DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE
node-agent   3         3         3       3            3          ← без toleration
node-agent   4         4         4       4            4          ← tolerations: [{key: node-role.kubernetes.io/control-plane, operator: Exists, effect: NoSchedule}]
```

Контроллер DaemonSet сам добавляет подам tolerations (проверено):

```
{"effect":"NoExecute","key":"node.kubernetes.io/not-ready","operator":"Exists"}
{"effect":"NoExecute","key":"node.kubernetes.io/unreachable","operator":"Exists"}
{"effect":"NoSchedule","key":"node.kubernetes.io/disk-pressure","operator":"Exists"}
{"effect":"NoSchedule","key":"node.kubernetes.io/memory-pressure","operator":"Exists"}
{"effect":"NoSchedule","key":"node.kubernetes.io/pid-pressure","operator":"Exists"}
{"effect":"NoSchedule","key":"node.kubernetes.io/unschedulable","operator":"Exists"}
```

Сравните с обычным подом (01-2): там `not-ready`/`unreachable` с `tolerationSeconds: 300`. У DaemonSet — **без срока**: с NotReady-узла его поды не выселяются (переезжать им некуда — на каждом узле свой). `unschedulable` — поэтому `kubectl cordon` не мешает DaemonSet, а `kubectl drain` их пропускает (`--ignore-daemonsets`, 05-4).

Обновление: `updateStrategy` по умолчанию `RollingUpdate` с `maxUnavailable: 1, maxSurge: 0` (проверено) — узел за узлом, на каждом узле под сначала удаляется, потом создаётся. В кластере на 300 узлов это 300 последовательных шагов; ускоряют `maxUnavailable: 10%`. `maxSurge: 1` (при `maxUnavailable: 0`) — новый под рядом со старым, без окна, когда на узле нет агента (важно для CNI и log-shipper'ов, но два экземпляра должны уметь сосуществовать: порты, файлы). `OnDelete` — обновление вручную, узел за узлом (CNI в осторожных кластерах).

## 2. Job 🟢🟡

Job запускает поды до тех пор, пока нужное число не завершится успешно. Ключевые поля:

| Поле | Дефолт | Что делает |
|---|---|---|
| `completions` | 1 | сколько успешных завершений нужно |
| `parallelism` | 1 | сколько подов одновременно |
| `backoffLimit` | 6 | сколько неудачных подов допустимо, затем Job `Failed` (`BackoffLimitExceeded`) |
| `activeDeadlineSeconds` | — | общий лимит времени Job'а, затем все поды убиты, `DeadlineExceeded` |
| `ttlSecondsAfterFinished` | — | удалить Job (и его поды) через N секунд после завершения |
| `podFailurePolicy` | — | правила по кодам выхода и условиям подов: `FailJob`, `Ignore`, `Count` |
| `completionMode: Indexed` | `NonIndexed` | каждый под получает `JOB_COMPLETION_INDEX` 0…N-1 |
| `restartPolicy` пода | — | `Never` (новый под на каждую попытку) или `OnFailure` (перезапуск в том же поде) |

Проверено (все Job'ы запущены одновременно, состояние через 75 с):

```
NAME       STATUS     COMPLETIONS   DURATION   AGE
flaky      Failed     0/1           75s        75s
deadline   Failed     0/1           75s        75s
policy     Failed     0/1           75s        75s
parallel   Complete   6/6           18s        75s
Error from server (NotFound): jobs.batch "ttl" not found       ← удалён через 10 с после завершения

flaky: FailureTarget=True/BackoffLimitExceeded Failed=True/BackoffLimitExceeded failed=3
deadline: FailureTarget=True/DeadlineExceeded Failed=True/DeadlineExceeded failed=1
policy: FailureTarget=True/PodFailurePolicy Failed=True/PodFailurePolicy failed=1
```

- `flaky` (`backoffLimit: 2`, всегда `exit 1`) — 3 пода, старты 09:29:17, 09:29:27, 09:29:47: паузы 10 и 20 с, тот же экспоненциальный back-off до 6 минут.
- `deadline` (`activeDeadlineSeconds: 10`, `sleep 60`) — убит через 10 с. Лимит **общий**, включая все ретраи и ожидание образа.
- `policy` (`exit 42` с правилом `FailJob` для кода 42) — Job провален после **первого** пода, хотя `backoffLimit: 6`. Так отличают «ошибку конфигурации, повтор бесполезен» от «временного сбоя».
- `parallel` (`completions: 6, parallelism: 2, Indexed`, `sleep 3`) — пары подов стартовали в 09:29:17, :23, :29, индексы 0…5; 18 с вместо 6×3.

Что важно при выборе:

- `restartPolicy: OnFailure` перезапускает контейнер в том же поде: счётчик `backoffLimit` идёт по рестартам, логи прошлых попыток теряются (видна только `--previous`). `Never` — по поду на попытку, все логи на месте, но поды копятся (их убирает `ttlSecondsAfterFinished` или история CronJob).
- `podFailurePolicy` требует `restartPolicy: Never`. Правило `Ignore` для условия `DisruptionTarget` — не считать попыткой выселение при drain/preemption.
- Job **не идемпотентен сам по себе**: под может быть запущен дважды (узел потерян, под пересоздан, хотя первый ещё работал). Миграции и бэкапы должны выдерживать повтор и параллельный запуск (блокировка в БД, `pg_advisory_lock`).

## 3. CronJob 🟡

CronJob создаёт Job по расписанию. Имя Job'а — `<cronjob>-<время запуска в минутах от эпохи>`: `backup-ok-29866170`.

| Поле | Что делает |
|---|---|
| `schedule` | cron-выражение; `@hourly`, `@daily` тоже можно |
| `timeZone` | IANA-зона (`Europe/Moscow`); без неё — часовой пояс controller-manager (обычно UTC) |
| `concurrencyPolicy` | `Allow` (дефолт) — запускать, даже если прошлый не закончился; `Forbid` — пропустить запуск; `Replace` — убить прошлый и запустить новый |
| `startingDeadlineSeconds` | насколько можно опоздать с запуском (controller был недоступен, CronJob был suspended); опоздал больше — запуск пропущен |
| `suspend` | приостановить расписание |
| `successfulJobsHistoryLimit` / `failedJobsHistoryLimit` | сколько завершённых Job'ов хранить (3 и 1) |

Проверено (три CronJob'а `* * * * *`, через 3 минуты; у `backup-forbid` и `backup-replace` задача `sleep 3600`):

```
NAME             SCHEDULE    TIMEZONE        SUSPEND   ACTIVE   LAST SCHEDULE   AGE
backup-forbid    * * * * *   <none>          False     1        2m2s            2m57s
backup-ok        * * * * *   Europe/Moscow   False     1        2s              2m57s
backup-replace   * * * * *   <none>          False     1        2s              2m57s

backup-forbid-29866170    Running    0/1           2m3s
backup-ok-29866170        Complete   1/1           2s
backup-ok-29866171        Complete   1/1           2s
backup-ok-29866172        Complete   1/1           2s
backup-replace-29866172   Running    0/1           3s

backup-forbid    JobAlreadyActive   Not starting job because prior execution is running and concurrency policy is Forbid
backup-replace-29866171-v5t5r   Killing   Stopping container backup

lastSchedule=2026-10-14T09:30:00Z lastSuccessful= active=backup-forbid-29866170
```

`Forbid` с зависшим Job'ом: **ни одного нового запуска**, `LAST SCHEDULE` растёт, `lastSuccessfulTime` пуст, единственный след — событие `JobAlreadyActive` типа `Normal` (не Warning!), которое живёт 1 час. `Replace` убил предыдущий запуск (`Killing`) — бэкап, который длится дольше интервала, при `Replace` не закончится никогда.

### Пропущенные запуски 🔴

Если CronJob пропустил запуски (controller-manager лежал, `suspend: true` сняли, часы сдвинулись), контроллер считает пропущенные времена с `lastScheduleTime`:

- без `startingDeadlineSeconds` — и пропущенных больше 100 — CronJob перестаёт запускаться совсем с событием `too many missed start times` (⚠️ не воспроизводилось на стенде: нужно ~2 часа простоя минутного CronJob'а; поведение — по документации CronJob controller);
- с `startingDeadlineSeconds: 300` — считаются только пропуски за последние 5 минут; запустится один Job (последний пропущенный), остальные пропущены.

Ставьте `startingDeadlineSeconds` всегда — это и защита от «лавины» запусков после простоя, и от вечной остановки.

## 4. Что выбрать 🟢

| Задача | Объект |
|---|---|
| агент на каждом узле (логи, метрики, CNI, CSI, node-exporter) | DaemonSet |
| агент на подмножестве узлов (GPU-драйвер) | DaemonSet + `nodeSelector`/affinity |
| одноразовая задача: миграция, загрузка данных, пересчёт | Job (из CI — с уникальным именем или `generateName`) |
| параллельная обработка N кусков | Job с `completions`/`parallelism`, `Indexed` |
| регулярная задача: бэкап, очистка, отчёт | CronJob |
| «демон», который должен работать всегда | Deployment, не Job |

---

## 🔧 Лаба

### Шаг 0. Подготовка

```bash
kubectl config use-context kind-lab
kubectl create ns lab-02-4
kubectl config set-context --current --namespace=lab-02-4
```

### Шаг 1. CronJob'ы (запустите первыми — им нужно время)

```bash
kubectl apply -f - <<'EOF'
apiVersion: batch/v1
kind: CronJob
metadata: {name: backup-forbid}
spec:
  schedule: "* * * * *"
  concurrencyPolicy: Forbid
  jobTemplate:
    spec:
      template:
        spec:
          restartPolicy: Never
          containers:
          - {name: backup, image: busybox:1.37, command: ["sh", "-c", "echo backup started; sleep 3600"]}
---
apiVersion: batch/v1
kind: CronJob
metadata: {name: backup-replace}
spec:
  schedule: "* * * * *"
  concurrencyPolicy: Replace
  jobTemplate:
    spec:
      template:
        spec:
          restartPolicy: Never
          containers:
          - {name: backup, image: busybox:1.37, command: ["sh", "-c", "echo backup started; sleep 3600"]}
---
apiVersion: batch/v1
kind: CronJob
metadata: {name: backup-ok}
spec:
  schedule: "* * * * *"
  timeZone: "Europe/Moscow"
  jobTemplate:
    spec:
      ttlSecondsAfterFinished: 600
      template:
        spec:
          restartPolicy: Never
          containers:
          - {name: backup, image: busybox:1.37, command: ["sh", "-c", "date; echo ok"]}
EOF
```

### Шаг 2. Job'ы

```bash
kubectl apply -f - <<'EOF'
apiVersion: batch/v1
kind: Job
metadata: {name: flaky}
spec:
  backoffLimit: 2
  template:
    spec:
      restartPolicy: Never
      containers: [{name: job, image: busybox:1.37, command: ["sh", "-c", "date +%T; exit 1"]}]
---
apiVersion: batch/v1
kind: Job
metadata: {name: deadline}
spec:
  activeDeadlineSeconds: 10
  template:
    spec:
      restartPolicy: Never
      containers: [{name: job, image: busybox:1.37, command: ["sleep", "60"]}]
---
apiVersion: batch/v1
kind: Job
metadata: {name: policy}
spec:
  backoffLimit: 6
  podFailurePolicy:
    rules:
    - action: FailJob
      onExitCodes: {containerName: job, operator: In, values: [42]}
    - action: Ignore
      onPodConditions: [{type: DisruptionTarget}]
  template:
    spec:
      restartPolicy: Never
      containers: [{name: job, image: busybox:1.37, command: ["sh", "-c", "echo bad config; exit 42"]}]
---
apiVersion: batch/v1
kind: Job
metadata: {name: parallel}
spec:
  completions: 6
  parallelism: 2
  completionMode: Indexed
  template:
    spec:
      restartPolicy: Never
      containers: [{name: job, image: busybox:1.37, command: ["sh", "-c", "echo index=$JOB_COMPLETION_INDEX; sleep 3"]}]
---
apiVersion: batch/v1
kind: Job
metadata: {name: ttl}
spec:
  ttlSecondsAfterFinished: 10
  template:
    spec:
      restartPolicy: Never
      containers: [{name: job, image: busybox:1.37, command: ["true"]}]
EOF
sleep 75
kubectl get jobs flaky deadline policy parallel; kubectl get job ttl
for j in flaky deadline policy; do kubectl get job $j -o jsonpath="$j: {range .status.conditions[*]}{.type}={.status}/{.reason} {end}failed={.status.failed}{\"\n\"}"; done
kubectl get pods -l batch.kubernetes.io/job-name=flaky -o custom-columns=POD:.metadata.name,STARTED:.status.startTime --sort-by=.status.startTime
kubectl get pods -l batch.kubernetes.io/job-name=parallel -o custom-columns=POD:.metadata.name,IDX:.metadata.annotations.batch\\.kubernetes\\.io/job-completion-index,START:.status.startTime --sort-by=.status.startTime
```

Проверено: вывод в §2.

### Шаг 3. Что стало с CronJob'ами

Через 3 минуты после шага 1:

```bash
kubectl get cronjobs
kubectl get jobs --sort-by=.metadata.creationTimestamp | grep backup
kubectl get events --sort-by=.lastTimestamp -o custom-columns=OBJ:.involvedObject.name,REASON:.reason,MSG:.message | grep -E 'backup-(forbid|replace)' | tail -8
kubectl get cronjob backup-forbid -o jsonpath='lastSchedule={.status.lastScheduleTime} lastSuccessful={.status.lastSuccessfulTime} active={.status.active[*].name}{"\n"}'
kubectl logs $(kubectl get pods -o name | grep backup-ok | tail -1)      # date внутри пода — в UTC
kubectl delete cronjob --all; kubectl delete job --all
```

Проверено: вывод в §3. `timeZone` меняет **когда** запускать, а не часовой пояс внутри контейнера: `date` в поде печатает UTC (проверено: `Wed Oct 14 09:34:07 UTC 2026`; часовой пояс процесса задают переменной `TZ` или файлом `/etc/localtime` в образе).

### Шаг 4. DaemonSet

```bash
kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: DaemonSet
metadata: {name: node-agent}
spec:
  selector: {matchLabels: {app: node-agent}}
  template:
    metadata: {labels: {app: node-agent}}
    spec:
      terminationGracePeriodSeconds: 1
      containers:
      - name: agent
        image: busybox:1.37
        command: ["sh", "-c", "echo agent v1 on $NODE; sleep infinity"]
        env: [{name: NODE, valueFrom: {fieldRef: {fieldPath: spec.nodeName}}}]
        resources: {requests: {cpu: 10m, memory: 16Mi}}
EOF
kubectl rollout status ds/node-agent
kubectl get ds node-agent; kubectl get pods -l app=node-agent -o wide
kubectl get pod -l app=node-agent -o jsonpath='{.items[0].spec.tolerations}' | jq -c '.[]'
kubectl get node lab-control-plane -o jsonpath='{.spec.taints}{"\n"}'
kubectl patch ds node-agent --type=merge -p '{"spec":{"template":{"spec":{"tolerations":[{"key":"node-role.kubernetes.io/control-plane","operator":"Exists","effect":"NoSchedule"}]}}}}'
kubectl rollout status ds/node-agent; kubectl get ds node-agent
kubectl get ds node-agent -o jsonpath='{.spec.updateStrategy}{"\n"}'
kubectl cordon lab-worker2; kubectl get pods -l app=node-agent -o wide | grep lab-worker2; kubectl uncordon lab-worker2
```

Проверено: вывод в §1; на cordon'нутом узле под агента остаётся.

### Уборка

```bash
kubectl config set-context --current --namespace=default
kubectl delete ns lab-02-4
```

---

## 🔥 Кейс из прода: «CronJob бэкапа молча не запускался неделю»

**Контекст.** Ночной бэкап PostgreSQL — CronJob `0 2 * * *` с `concurrencyPolicy: Forbid` («чтобы два бэкапа не шли одновременно»). Через неделю понадобилось восстановление — последнему дампу 7 дней. Алертов не было: мониторинг проверял, что CronJob существует и не `suspend`.

**Разбор.**
1. `kubectl get cronjob backup` — `LAST SCHEDULE 7d`, `ACTIVE 1`.
2. `kubectl get jobs` — один Job недельной давности в `Running`, его под висит на `pg_dump`: БД была недоступна минуту в ночь первого сбоя, клиент повис на TCP-соединении без таймаута.
3. С тех пор каждую ночь контроллер видел активный Job и пропускал запуск — `JobAlreadyActive` (шаг 3 лабы). Событие типа `Normal`, живёт час, никто его не видел.

**Фикс.**
- `activeDeadlineSeconds: 3600` в `jobTemplate` — зависший бэкап убивается через час, следующий запуск не блокируется. `backoffLimit: 2`.
- `startingDeadlineSeconds: 600` — после простоя control plane CronJob не накопит 100 пропусков и не остановится навсегда.
- Таймауты в самом бэкапе: `PGCONNECT_TIMEOUT=10`, `statement_timeout`.
- Мониторинг по факту, а не по объекту: алерт, если `kube_cronjob_status_last_successful_time` старше 26 часов; плюс проверка свежести файла бэкапа в хранилище и регулярное тестовое восстановление (04-3).

**Что запомнить.**
- `Forbid` + зависший Job = CronJob больше не запускается, без ошибок.
- У каждого Job'а — `activeDeadlineSeconds`; у каждого CronJob'а — `startingDeadlineSeconds`.
- Мониторят `lastSuccessfulTime` и результат (файл бэкапа), а не существование CronJob'а.

---

## 💼 Вопросы с собеседования

### 🟢 Junior

**1. Зачем нужен DaemonSet? Примеры.**
По поду на каждый (подходящий) узел: агенты логов и метрик (Fluent Bit, node-exporter), CNI, kube-proxy, CSI-драйверы, сканеры безопасности. Новый узел — автоматически новый под.

**2. Чем Job отличается от Deployment?**
Job выполняет работу до успешного завершения нужного числа подов и останавливается; Deployment держит поды работающими всегда. В Job `restartPolicy` — `Never` или `OnFailure`, в Deployment — только `Always`.

**3. Почему DaemonSet не запустился на control-plane узле?**
У узла taint `node-role.kubernetes.io/control-plane:NoSchedule`; нужен toleration в шаблоне пода.

### 🟡 Middle

**4. Что делают `backoffLimit` и `activeDeadlineSeconds`?**
`backoffLimit` — сколько неудачных попыток (подов или рестартов) допустимо, затем Job `Failed` с `BackoffLimitExceeded`; паузы между попытками растут 10 → 20 → 40 с. `activeDeadlineSeconds` — общий лимит времени всего Job'а, включая ретраи; по истечении поды убиваются, причина `DeadlineExceeded`.

**5. Чем отличаются `concurrencyPolicy` Allow, Forbid, Replace?**
Allow — новый Job запускается, даже если прошлый работает (риск параллельных бэкапов). Forbid — запуск пропускается, пока прошлый активен (риск: зависший Job блокирует все следующие). Replace — прошлый убивается, запускается новый (риск: длинная задача никогда не завершится).

**6. Как не дать Job'у бесконечно ретраить ошибку конфигурации?**
`podFailurePolicy` с правилом `FailJob` для кодов выхода, означающих «повтор бесполезен» (и `Ignore` для `DisruptionTarget`, чтобы drain не тратил попытки); `restartPolicy: Never`. Плюс разумный `backoffLimit`.

### 🔴 Senior

**7. Почему CronJob может перестать запускаться навсегда и как этого избежать?**
Без `startingDeadlineSeconds` после долгого простоя контроллера (или снятия suspend) он считает пропуски с `lastScheduleTime`; больше 100 — CronJob перестаёт планировать запуски. Другой сценарий — Forbid и зависший Job. Защита: `startingDeadlineSeconds`, `activeDeadlineSeconds` в jobTemplate, алерт по `lastSuccessfulTime`.

**8. Job может выполниться дважды? Как с этим жить?**
Да: при потере узла под может быть пересоздан, пока первый ещё работает; CronJob с Allow запускает параллельно; ручной повтор. Задачи должны быть идемпотентными (upsert, проверка «уже сделано») и защищёнными блокировкой (advisory lock в БД, lease), а не полагаться на «Kubernetes запустит ровно один раз».

**9. Как обновлять DaemonSet в большом кластере, не оставив узлы без агента?**
`RollingUpdate` с `maxSurge: 1, maxUnavailable: 0` — новый под рядом со старым на каждом узле (агент должен уметь сосуществовать: порты, hostPath, лок-файлы); скорость — `maxUnavailable` в процентах для агентов, которым окно не страшно. Для CNI — `OnDelete` и волнами по узлам с проверкой.

---

## ⚠️ Подводные камни

- `concurrencyPolicy: Forbid` + зависший Job = CronJob молча не запускается; событие `JobAlreadyActive` — `Normal` и живёт час.
- Без `startingDeadlineSeconds` более 100 пропусков останавливают CronJob навсегда.
- `timeZone` влияет на расписание, но не на время внутри контейнера.
- `activeDeadlineSeconds` — на весь Job, включая ожидание образа и ретраи.
- `restartPolicy: OnFailure` — логи прошлых попыток теряются; `Never` — копятся поды (нужен `ttlSecondsAfterFinished`).
- Sidecar в `containers` не даёт Job'у завершиться (02-1).
- DaemonSet без toleration не встанет на control-plane и узлы с вашими taint'ами — «дыры» в сборе логов.
- Поды DaemonSet не выселяются с NotReady-узлов и не мешают `cordon`; `drain` требует `--ignore-daemonsets`.
- Имя Job из CI — уникальное: повторный `kubectl apply` того же Job'а с изменённым шаблоном падает — `spec.template` Job'а неизменяем.

---

## Чеклист

- [ ] Поставлю DaemonSet на все узлы, включая control-plane, и объясню его tolerations.
- [ ] Выберу стратегию обновления DaemonSet под тип агента.
- [ ] Настрою Job с `backoffLimit`, `activeDeadlineSeconds`, `podFailurePolicy`, `ttlSecondsAfterFinished`.
- [ ] Запущу параллельный Indexed Job.
- [ ] Объясню три `concurrencyPolicy` и их риски; поставлю `startingDeadlineSeconds`.
- [ ] Построю мониторинг CronJob по `lastSuccessfulTime`, а не по факту существования.

---

## Задание со звёздочкой

Соберите «правильный» бэкап-CronJob для PostgreSQL сквозного сценария (сам бэкап и восстановление — 04-3):

1. `schedule: "*/5 * * * *"`, `timeZone`, `concurrencyPolicy: Forbid`, `startingDeadlineSeconds: 120`, `activeDeadlineSeconds: 240`, `backoffLimit: 1`, `ttlSecondsAfterFinished`.
2. Образ `postgres:17.6-alpine`, команда `pg_dump` в emptyDir с таймаутом подключения из Secret `postgres`.
3. Сломайте БД на 6 минут (`kubectl -n orders scale sts postgres --replicas=0`) и убедитесь, что после возвращения CronJob продолжает работать.
4. Добавьте `podFailurePolicy`: код 2 у `pg_dump` (ошибка аутентификации) — `FailJob` сразу. Как проверить?

---

→ Следующая часть: **02-5. Probes и graceful shutdown** — liveness, readiness и startup с дефолтами и цифрами, SIGTERM → grace period → SIGKILL, гонка «под удалён, а endpoints ещё нет»: 502 при каждом деплое и как preStop их убирает; liveness, проверяющая БД, — каскадный рестарт.
