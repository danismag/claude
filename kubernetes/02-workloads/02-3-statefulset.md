# 02-3. StatefulSet

> Модуль 2 «Workloads» · часть 3 из 5 · 🟡🔴 · ~1 ч чтения + ~45 мин лабы · Нужно: стенд 00-1

---

## Зачем это DevOps-у

StatefulSet — способ запускать то, у чего есть **идентичность**: базы данных, брокеры, кластеры с выбором лидера (PostgreSQL, Kafka, ZooKeeper, etcd, Elasticsearch). В работе с ним всплывают вопросы, которых у Deployment нет: «почему после удаления StatefulSet диски остались и место кончилось», «почему обновление встало и не идёт дальше даже после исправления», «почему под не переезжает с упавшего узла» (01-2). На собеседовании: чем StatefulSet отличается от Deployment, зачем headless Service, что происходит с PVC.

В сквозном сценарии PostgreSQL orders-api — это StatefulSet `postgres` с PVC `data-postgres-0` и DNS-именем `postgres-0.postgres.orders.svc.cluster.local`.

---

## 1. Что даёт StatefulSet 🟡

| | Deployment | StatefulSet |
|---|---|---|
| Имена подов | случайный суффикс: `orders-api-6d54d4c46b-fvq75` | порядковый номер: `web-0`, `web-1`, `web-2` |
| Пересоздание пода | новое имя, любой узел, новый том (если есть) | **то же имя**, тот же PVC; IP новый |
| DNS | только Service | плюс имя на каждый под: `web-0.web.<ns>.svc.cluster.local` (нужен headless Service) |
| Тома | общий PVC на все поды или без томов | `volumeClaimTemplates` — свой PVC на каждый под: `data-web-0`… |
| Порядок | все одновременно | по умолчанию по одному: создание 0→N, удаление и обновление N→0 |
| Гарантия | «не меньше N» | «не больше одного пода с этим именем» — at-most-once |

Проверено: удалили `web-1` — вернулся под с тем же именем, на тот же узел (там его PV local-path), с тем же файлом на томе; сменились IP и UID:

```
web-1 09:22:54                                                         ← файл /data/born, записан при первом старте
before: ip=10.244.1.30 node=lab-worker3 uid=14cf5dcf-f80e-4392-abe8-f24e8783cebd
after:  ip=10.244.1.31 node=lab-worker3 uid=6b03c0bf-80b5-4528-b709-ef204e5fe352
web-1 09:22:54
```

StatefulSet **не делает** базу данных отказоустойчивой: он не настраивает репликацию, не выбирает лидера, не делает failover. Это работа приложения или оператора (09-1). StatefulSet только даёт стабильные имена и тома.

## 2. Headless Service и DNS 🟡

`clusterIP: None` — Service без виртуального IP. DNS по имени сервиса возвращает IP **всех готовых подов**, а для StatefulSet ещё и записи на каждый под (проверено):

```
Name:	web.lab-02-3.svc.cluster.local
Address: 10.244.1.30
Name:	web.lab-02-3.svc.cluster.local
Address: 10.244.2.38
Name:	web.lab-02-3.svc.cluster.local
Address: 10.244.3.35

10.244.1.30     web-1.web.lab-02-3.svc.cluster.local      ← getent hosts web-1.web
```

`spec.serviceName` StatefulSet'а должен указывать на этот Service — иначе записей на поды не будет. Клиенты БД ходят на `postgres-0.postgres` (primary) или на отдельный Service для реплик.

Неготовые поды из DNS headless Service **исключаются** (`publishNotReadyAddresses: false` по умолчанию) — именно поэтому в 01-2 orders-api потерял БД, когда узел с `postgres-0` стал `Unknown`. Для кластеров, которым нужно найти друг друга до готовности (выборы лидера, etcd), ставят `publishNotReadyAddresses: true`.

Ловушка отладки (проверено): `nslookup web-1.web` в busybox вернул `127.0.53.53` — busybox-nslookup **не применяет search-домены** из `resolv.conf`, запрос ушёл как `web-1.web.` в публичный DNS, а `.web` — реальный домен верхнего уровня, отвечающий «адресом-предупреждением» ICANN о коллизии имён. Приложения резолвят через libc и search-домены — `getent hosts web-1.web` дал правильный `10.244.1.30`. Проверяйте DNS `getent` или полным именем; подробнее — 03-3.

## 3. Тома: volumeClaimTemplates и судьба PVC 🟡🔴

Для каждого пода создаётся PVC `<имя-шаблона>-<имя-пода>`: `data-web-0`, `data-web-1`, `data-web-2` (проверено). PVC **переживают** поды и по умолчанию — сам StatefulSet:

| Событие | PVC по умолчанию (`Retain`) | С `persistentVolumeClaimRetentionPolicy` |
|---|---|---|
| удалён под | остаётся, новый под берёт его | — |
| scale down 3 → 1 | `data-web-1`, `data-web-2` **остаются** (проверено) | `whenScaled: Delete` — удаляются (проверено: после 3→2 остались только `data-web-0`, `data-web-1`) |
| scale up обратно | поды получают старые PVC со старыми данными (проверено: `web-2 09:22:58` — старый файл) | новые пустые PVC (проверено: `web-2 09:24:15` — новый файл) |
| удалён StatefulSet | все PVC остаются (проверено) | `whenDeleted: Delete` — удаляются |

Политика stable с 1.32. Дефолт `Retain/Retain` — безопасный: данные не пропадут из-за опечатки в `replicas`. Цена — «осиротевшие» PVC копятся, а с ними диски в облаке, за которые платят. Мониторьте PVC без подов.

Ещё одно: старые данные при scale up — сюрприз для приложений-кластеров. Реплика Kafka или Elasticsearch, вернувшаяся с данными недельной давности, начнёт догонять (и может упереться в удалённые сегменты лидера) — для них `whenScaled: Delete` осмысленнее.

## 4. Порядок: podManagementPolicy 🟡

`OrderedReady` (дефолт): под N+1 создаётся только после того, как под N стал Ready; при удалении — наоборот. Проверено (создание 3 подов):

```
POD     NODE          CREATED                READY
web-0   lab-worker    2026-10-14T09:22:45Z   2026-10-14T09:22:49Z
web-1   lab-worker3   2026-10-14T09:22:50Z   2026-10-14T09:22:55Z
web-2   lab-worker2   2026-10-14T09:22:55Z   2026-10-14T09:22:58Z
```

Scale down 3 → 1 (проверено): сначала `web-2` в Terminating, через ~3 с — `web-1`; всего 6 с.

`Parallel`: все поды создаются и удаляются одновременно (проверено: все три — `09:26:26`, Ready за 8 с против 14 с у `OrderedReady`). На **обновление** политика не влияет — rolling update всё равно по одному, N→0. Parallel — для приложений, которым порядок не нужен (свой механизм discovery), при больших `replicas`.

## 5. Обновление: RollingUpdate, partition, OnDelete 🟡🔴

`updateStrategy.type: RollingUpdate` (дефолт) — поды пересоздаются по одному, от старшего номера к младшему, каждый следующий — после Ready предыдущего. Ревизии — объекты `ControllerRevision`, у подов метка `controller-revision-hash`.

**`partition: N`** — обновляются только поды с номером ≥ N. Это встроенная канарейка: `partition: 2` при 3 репликах — обновился только `web-2` (проверено):

```
web-0 web-6748f5ff5 v1
web-1 web-6748f5ff5 v1
web-2 web-56b64f656 v2
current=web-6748f5ff5 update=web-56b64f656 updated=1
partitioned roll out complete: 1 new pods have been updated...
```

Проверили `web-2` — снимаем partition (`partition: 0`), и остальные обновляются по очереди: `web-1`, затем `web-0` (6 с на стенде).

**`OnDelete`** — StatefulSet не трогает поды сам, новая ревизия применяется, когда вы удаляете под. Для БД, где обновление каждого узла — ручная процедура (switchover перед обновлением primary).

### Ловушка: сломанная ревизия не откатывается сама 🔴

Проверено: шаблон заменили на падающий (`exit 1`) — `web-2` в `CrashLoopBackOff`, rollout остановился (web-0 и web-1 не тронуты — порядок спас от полного падения). Вернули шаблон на рабочую версию — через 45 с:

```
web-0 1/1 Running 0
web-1 1/1 Running 0
web-2 0/1 CrashLoopBackOff 3
current=web-56b64f656 update=web-56b64f656 ready=2
web-2 revision=web-9459b4595                  ← под всё ещё на сломанной ревизии
```

`currentRevision` и `updateRevision` совпадают (обе — рабочая v2), но `web-2` так и остался на сломанной ревизии и не будет заменён: при `OrderedReady` контроллер ждёт, пока под станет Ready, прежде чем что-то делать дальше, — а сломанный под Ready не станет никогда. Документированное поведение («forced rollback»): после отката шаблона **удалите вручную поды, которые уже запустились со сломанной конфигурацией**. Проверено: `kubectl delete pod web-2` — новый `web-2` на ревизии `web-56b64f656`, `v2`, Ready.

У Deployment такой проблемы нет: исправленный шаблон просто создаёт новый ReplicaSet.

## 6. StatefulSet против оператора 🔴

| | StatefulSet вручную | Оператор (CloudNativePG, Strimzi, ECK) |
|---|---|---|
| Имена, тома, порядок | да | да (оператор сам создаёт StatefulSet или поды) |
| Репликация, выбор primary, failover | писать самим (скрипты, Patroni) | встроено |
| Бэкапы и PITR | CronJob, свои скрипты (04-3) | декларативно в CR |
| Обновление версии БД | `OnDelete` + runbook | автоматизировано с switchover |
| Сложность | понятнее, меньше движущихся частей | ещё один компонент со своими багами |

Правило: одиночная БД для dev/стенда — StatefulSet достаточно (как в нашем стенде); прод-кластер БД — оператор или managed-сервис вне Kubernetes (решение «БД в кластере или нет» — 04-3, 12-3).

---

## 🔧 Лаба

### Шаг 0. Подготовка

```bash
kubectl config use-context kind-lab
kubectl create ns lab-02-3
kubectl config set-context --current --namespace=lab-02-3
mkdir -p /tmp/lab-02-3 && cd /tmp/lab-02-3
cat > sts.yaml <<'EOF'
apiVersion: v1
kind: Service
metadata: {name: web, namespace: lab-02-3}
spec:
  clusterIP: None
  selector: {app: web}
  ports: [{name: http, port: 80}]
---
apiVersion: apps/v1
kind: StatefulSet
metadata: {name: web, namespace: lab-02-3}
spec:
  serviceName: web
  replicas: 3
  selector: {matchLabels: {app: web}}
  template:
    metadata: {labels: {app: web}}
    spec:
      terminationGracePeriodSeconds: 2
      containers:
      - name: web
        image: busybox:1.37
        command: ["sh", "-c", "[ -f /data/born ] || echo \"$(hostname) $(date +%T)\" > /data/born; echo v1 > /data/version; httpd -f -p 80 -h /data"]
        readinessProbe: {httpGet: {path: /born, port: 80}, periodSeconds: 2}
        volumeMounts: [{name: data, mountPath: /data}]
  volumeClaimTemplates:
  - metadata: {name: data}
    spec:
      accessModes: [ReadWriteOnce]
      resources: {requests: {storage: 100Mi}}
EOF
```

Каждый под при первом старте пишет в свой том файл `born` с именем и временем — по нему видно, «тот же» ли том.

### Шаг 1. Порядок создания, PVC, DNS

```bash
kubectl apply -f sts.yaml
kubectl rollout status sts/web
kubectl get pods -o 'custom-columns=POD:.metadata.name,NODE:.spec.nodeName,CREATED:.metadata.creationTimestamp,READY:.status.conditions[?(@.type=="Ready")].lastTransitionTime'
kubectl get pvc
kubectl run dns --image=python:3.12-slim --restart=Never --command -- sh -c 'cat /etc/resolv.conf; getent ahostsv4 web | awk "{print \$1}" | sort -u; getent hosts web-1.web'
sleep 8; kubectl logs dns
kubectl run dns-bb --image=busybox:1.37 --restart=Never --command -- nslookup web-1.web
sleep 5; kubectl logs dns-bb
```

Проверено: создание по одному (§4), три PVC `data-web-0…2` Bound; `getent` — адреса подов и `web-1.web.lab-02-3.svc.cluster.local`; busybox `nslookup web-1.web` — `127.0.53.53` (§2).

### Шаг 2. Идентичность пода

```bash
kubectl exec web-1 -- cat /data/born
kubectl get pod web-1 -o jsonpath='before: ip={.status.podIP} node={.spec.nodeName} uid={.metadata.uid}{"\n"}'
kubectl delete pod web-1
kubectl wait --for=condition=Ready pod/web-1
kubectl get pod web-1 -o jsonpath='after:  ip={.status.podIP} node={.spec.nodeName} uid={.metadata.uid}{"\n"}'
kubectl exec web-1 -- cat /data/born
```

Проверено: вывод в §1.

### Шаг 3. Scale down/up и PVC

```bash
kubectl scale sts web --replicas=1
kubectl get pods -w          # Ctrl-C, когда останется web-0: сначала уходит web-2, потом web-1
kubectl get pvc              # все три на месте
kubectl scale sts web --replicas=3 && kubectl rollout status sts/web
for p in web-1 web-2; do kubectl exec $p -- cat /data/born; done     # старые файлы

kubectl patch sts web -p '{"spec":{"persistentVolumeClaimRetentionPolicy":{"whenScaled":"Delete","whenDeleted":"Retain"}}}'
kubectl scale sts web --replicas=2; sleep 12; kubectl get pvc          # data-web-2 удалён
kubectl scale sts web --replicas=3 && kubectl rollout status sts/web
kubectl exec web-2 -- cat /data/born                                    # новое время
```

Проверено: значения в таблице §3.

### Шаг 4. Partition

```bash
kubectl patch sts web -p '{"spec":{"updateStrategy":{"type":"RollingUpdate","rollingUpdate":{"partition":2}}}}'
kubectl patch sts web --type=json -p '[{"op":"replace","path":"/spec/template/spec/containers/0/command/2","value":"[ -f /data/born ] || echo \"$(hostname) $(date +%T)\" > /data/born; echo v2 > /data/version; httpd -f -p 80 -h /data"}]'
sleep 15
for p in web-0 web-1 web-2; do echo "$p $(kubectl get pod $p -o jsonpath='{.metadata.labels.controller-revision-hash}') $(kubectl exec $p -- cat /data/version)"; done
kubectl get sts web -o jsonpath='current={.status.currentRevision} update={.status.updateRevision} updated={.status.updatedReplicas}{"\n"}'
kubectl rollout status sts/web --timeout=5s
kubectl patch sts web -p '{"spec":{"updateStrategy":{"rollingUpdate":{"partition":0}}}}'
kubectl rollout status sts/web
kubectl get controllerrevisions
```

Проверено: вывод в §5; после `partition: 0` весь rollout — 6 с.

### Шаг 5. Сломанная ревизия

```bash
kubectl patch sts web --type=json -p '[{"op":"replace","path":"/spec/template/spec/containers/0/command/2","value":"echo v3 broken; exit 1"}]'
sleep 30; kubectl get pods -l app=web
# «откатываем» шаблон на v2
kubectl patch sts web --type=json -p '[{"op":"replace","path":"/spec/template/spec/containers/0/command/2","value":"[ -f /data/born ] || echo \"$(hostname) $(date +%T)\" > /data/born; echo v2 > /data/version; httpd -f -p 80 -h /data"}]'
sleep 45; kubectl get pods -l app=web
kubectl get sts web -o jsonpath='current={.status.currentRevision} update={.status.updateRevision} ready={.status.readyReplicas}{"\n"}'
kubectl get pod web-2 -o jsonpath='web-2 revision={.metadata.labels.controller-revision-hash}{"\n"}'
kubectl delete pod web-2 && kubectl wait --for=condition=Ready pod/web-2
kubectl get pod web-2 -o jsonpath='web-2 revision={.metadata.labels.controller-revision-hash}{"\n"}'; kubectl exec web-2 -- cat /data/version
```

Проверено: вывод в §5; после удаления — `web-2 revision=web-56b64f656`, `v2`.

### Шаг 6. Parallel против OrderedReady

```bash
kubectl delete sts web; kubectl get pvc      # PVC остались
kubectl delete pvc --all
sed 's/^  serviceName: web$/  serviceName: web\n  podManagementPolicy: Parallel/' sts.yaml > sts-par.yaml
t0=$(date +%s); kubectl apply -f sts-par.yaml; kubectl rollout status sts/web; echo "Parallel: $(( $(date +%s)-t0 ))s"
kubectl get pods -l app=web -o custom-columns=POD:.metadata.name,CREATED:.metadata.creationTimestamp
kubectl delete sts web && kubectl delete pvc --all
t0=$(date +%s); kubectl apply -f sts.yaml; kubectl rollout status sts/web; echo "OrderedReady: $(( $(date +%s)-t0 ))s"
```

Проверено: Parallel — 8 с, все поды созданы в одну секунду; OrderedReady — 14 с.

### Шаг 7. PostgreSQL сквозного сценария

```bash
kubectl -n orders get sts,pvc,svc
kubectl -n orders get pod postgres-0 -o jsonpath='{.spec.hostname}.{.spec.subdomain}{"\n"}'
kubectl -n orders exec postgres-0 -- sh -c 'df -h /var/lib/postgresql/data | tail -1'
```

Проверено:

```
postgres-0.postgres
/dev/nvme0n1p2           97.9G     79.2G     13.6G  85% /etc/hosts
```

`hostname`/`subdomain` пода — `postgres-0.postgres`: из них и складывается DNS-имя. А `df` показывает не «1Gi» из PVC, а весь диск хоста: том local-path — это просто каталог на диске узла, размер из PVC **не ограничивается** (и `df` в kind-узле видит точку монтирования `/etc/hosts` того же диска). PostgreSQL может съесть весь диск узла — подробнее о провижинерах и ёмкости в 04-2.

### Уборка

```bash
kubectl config set-context --current --namespace=default
kubectl delete ns lab-02-3          # PVC namespace удаляются вместе с ним
cd ~ && rm -rf /tmp/lab-02-3
```

---

## 🔥 Кейс из прода: «удалили StatefulSet, пересоздали — данные на месте, а место кончилось»

**Контекст.** Команда разворачивала временные стенды: Helm-релиз с Kafka (StatefulSet, 3 брокера × 200 ГБ) на каждую ветку. Стенды удаляли `helm uninstall`. Через два месяца облачный счёт за диски вырос в 6 раз, а квота дисков в регионе закончилась — новые PVC в `Pending`.

**Разбор.**
1. `kubectl get pvc -A | grep -c data-kafka` — 270 PVC, из них живых подов — 12.
2. `helm uninstall` удаляет StatefulSet, но PVC, созданные из `volumeClaimTemplates`, Helm'у не принадлежат — их создал контроллер StatefulSet, и по умолчанию (`whenDeleted: Retain`) они остаются (шаг 6 лабы: «PVC остались»).
3. У StorageClass `reclaimPolicy: Delete` — диски удалились бы вместе с PVC, но PVC никто не удалял.

**Фикс.**
- Для временных стендов — `persistentVolumeClaimRetentionPolicy: {whenDeleted: Delete, whenScaled: Delete}` в чарте; для прода оставили `Retain`.
- Удаление стенда — удаление **namespace** целиком (PVC namespace удаляются с ним), а не только релиза.
- Отчёт и алерт: PVC, на которые не ссылается ни один под дольше 7 дней (`kube_persistentvolumeclaim_info` без `kube_pod_spec_volumes_persistentvolumeclaims_info`).
- Разовая уборка: удалили PVC без подов после проверки владельцев.

**Что запомнить.**
- PVC из `volumeClaimTemplates` переживают и поды, и StatefulSet — по умолчанию.
- `helm uninstall` их не удаляет; удалить namespace — удаляет.
- `persistentVolumeClaimRetentionPolicy` — осознанный выбор: Retain для прода, Delete для эфемерных стендов.

---

## 💼 Вопросы с собеседования

### 🟢 Junior

**1. Чем StatefulSet отличается от Deployment?**
Стабильные имена подов (`web-0`, `web-1`), свой PVC на каждый под через `volumeClaimTemplates`, DNS-имя на каждый под через headless Service, упорядоченные создание, удаление и обновление, гарантия не больше одного пода с данным именем.

**2. Что такое headless Service?**
Service с `clusterIP: None`: без виртуального IP, DNS возвращает IP готовых подов напрямую; для StatefulSet — ещё и записи `<pod>.<service>`. Нужен клиентам, которые сами выбирают экземпляр (primary БД, брокер).

### 🟡 Middle

**3. Что произойдёт с данными при удалении пода StatefulSet? При scale down? При удалении StatefulSet?**
Под пересоздаётся с тем же именем и тем же PVC — данные на месте. При scale down и удалении StatefulSet PVC по умолчанию остаются (`Retain`); при scale up поды подхватывают старые PVC. `persistentVolumeClaimRetentionPolicy` (`whenScaled`/`whenDeleted: Delete`) меняет это.

**4. Как обновить только один под StatefulSet для проверки?**
`updateStrategy.rollingUpdate.partition: N` — обновятся поды с номером ≥ N. Проверили — уменьшаем partition до 0. Или `OnDelete` и ручное удаление нужного пода.

**5. Зачем `podManagementPolicy: Parallel`?**
Создавать и удалять поды одновременно, без ожидания Ready предыдущего, — быстрее при больших `replicas`, если приложению не нужен порядок старта. На rolling update не влияет.

### 🔴 Senior

**6. Обновление StatefulSet упало на сломанном образе, вы откатили шаблон, а под всё равно в CrashLoopBackOff. Почему и что делать?**
При `OrderedReady` контроллер ждёт Ready текущего пода, прежде чем двигаться; под со сломанной ревизией никогда не станет Ready, и контроллер его не заменит даже после отката шаблона. Нужно вручную удалить поды, уже запущенные на сломанной ревизии, — они пересоздадутся с текущей.

**7. Почему StatefulSet не пересоздаёт под с упавшего узла автоматически?**
Гарантия at-most-once: контроллер не знает, мёртв узел или только потерял связь; два пода с одним именем на одном томе — порча данных. Под остаётся в Terminating до подтверждения от kubelet, удаления объекта Node, `--force` или taint `node.kubernetes.io/out-of-service`.

**8. Делает ли StatefulSet базу данных отказоустойчивой?**
Нет. Он даёт имена, тома и порядок. Репликацию, выбор primary, failover, бэкапы делает приложение (Patroni, встроенный Raft) или оператор (CloudNativePG, Strimzi). Без этого StatefulSet с одной репликой — единая точка отказа, а с тремя — три независимые БД.

---

## ⚠️ Подводные камни

- `spec.serviceName` должен совпадать с именем headless Service, иначе нет DNS-записей подов.
- Неготовые поды исключены из DNS headless Service — кластеры, которым нужно «найти друг друга» до готовности, требуют `publishNotReadyAddresses: true`.
- busybox `nslookup` не использует search-домены; проверяйте DNS через `getent` или FQDN.
- PVC переживают StatefulSet по умолчанию — копятся и стоят денег.
- Scale up после scale down возвращает старые данные — неожиданно для кластерных приложений.
- Сломанная ревизия при OrderedReady блокирует rollout; после отката шаблона удалите сломанные поды вручную.
- `volumeClaimTemplates` неизменяемы — увеличение размера тома делается через PVC напрямую (если StorageClass разрешает расширение, 04-2), а не через шаблон.
- local-path и local PV привязывают под к узлу — StatefulSet не переедет при отказе узла.

---

## Чеклист

- [ ] Объясню, что StatefulSet даёт и чего не даёт по сравнению с Deployment.
- [ ] Настрою headless Service и найду под по DNS-имени.
- [ ] Предскажу судьбу PVC при удалении пода, scale down и удалении StatefulSet; настрою retention policy.
- [ ] Обновлю StatefulSet через partition.
- [ ] Выведу StatefulSet из зависшего rollout после сломанной ревизии.
- [ ] Объясню, когда StatefulSet достаточно, а когда нужен оператор.

---

## Задание со звёздочкой

Сделайте из `web` «кластер», который знает своих участников до готовности:

1. Добавьте в под readiness, которая проходит, только если под видит по DNS **всех** соседей (`getent hosts web-0.web web-1.web web-2.web`).
2. Запустите с `OrderedReady` — что произойдёт и почему кластер никогда не соберётся?
3. Почините двумя способами: `publishNotReadyAddresses: true` у Service и `podManagementPolicy: Parallel`. Какой способ правильнее для etcd/ZooKeeper и почему нужны оба?
4. Посмотрите, как это решено в чарте любого кластерного приложения (Bitnami etcd, Kafka) — найдите обе настройки.

---

→ Следующая часть: **02-4. DaemonSet, Job, CronJob** — по поду на узел и tolerations для control-plane, Job с `backoffLimit`, `activeDeadlineSeconds`, `podFailurePolicy` и `ttlSecondsAfterFinished`, CronJob с `concurrencyPolicy` и `startingDeadlineSeconds`; бэкап, который молча не запускался неделю.
