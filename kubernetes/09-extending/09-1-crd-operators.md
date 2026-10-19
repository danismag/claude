# 09-1. CRD и операторы

> Модуль 9 «Расширение API» · часть 1 из 2 · 🟡🔴 · ~1,5 ч чтения + ~1 ч лабы · Нужно: стенд 00-1; CloudNativePG 1.30.1 ставится в лабе (образы с ghcr.io — до 5–10 минут на загрузку)

---

## Зачем это DevOps-у

Половина того, что установлено в кластере, — операторы: cert-manager, Envoy Gateway, Argo CD, KEDA, операторы БД и брокеров. Каждый приносит свои ресурсы (CRD) и свой контроллер. В работе: «что это за объект и кто его обрабатывает», «почему мой CR не применяется», «удалили CRD — пропали все объекты», «оператор упал — что теперь с БД». На собеседовании: «что такое оператор», «чем CRD отличается от ConfigMap», «когда оператор оправдан».

Сквозной сценарий: PostgreSQL orders-api — одна реплика без failover (01-2: потеря узла = 503). Здесь — тот же PostgreSQL под управлением CloudNativePG: три экземпляра, автоматический failover, замер окна недоступности записи.

---

## 1. CRD: свой тип в API 🟡

CustomResourceDefinition регистрирует новый ресурс в apiserver: `kubectl get`, RBAC, watch, etcd, `kubectl explain` — всё работает «как у встроенных». Без контроллера CR — просто запись в etcd (как Ingress без контроллера, 03-4).

CRD стенда — политика хранения данных:

```yaml
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata: {name: retentionpolicies.ops.lab.local}
spec:
  group: ops.lab.local
  names: {kind: RetentionPolicy, plural: retentionpolicies, shortNames: [rp]}
  scope: Namespaced
  versions:
  - name: v1
    served: true
    storage: true
    subresources: {status: {}}
    additionalPrinterColumns:
    - {name: Keep, type: integer, jsonPath: .spec.keepDays}
    - {name: Target, type: string, jsonPath: .spec.target}
    - {name: Phase, type: string, jsonPath: .status.phase}
    schema:
      openAPIV3Schema:
        type: object
        properties:
          spec:
            type: object
            required: [target, keepDays]
            properties:
              target: {type: string, enum: [orders-db, logs, backups]}
              keepDays: {type: integer, minimum: 1, maximum: 365}
              archive: {type: boolean, default: false}
              minKeepDays: {type: integer, minimum: 1}
            x-kubernetes-validations:
            - rule: "!has(self.minKeepDays) || self.minKeepDays <= self.keepDays"
              message: "minKeepDays не может быть больше keepDays"
          status:
            type: object
            properties: {phase: {type: string}}
```

Валидация выполняется в apiserver до записи (проверено):

```
spec.target: Unsupported value: "cache": supported values: "orders-db", "logs", "backups"
spec.keepDays: Invalid value: 900: spec.keepDays in body should be less than or equal to 365
spec.keepDays: Required value
spec: Invalid value: minKeepDays не может быть больше keepDays          ← правило CEL
{"archive":false,"keepDays":30,"target":"orders-db"}                       ← default подставлен
NAME       KEEP   TARGET      PHASE
rp-21812   30     orders-db   Applied                                      ← printer columns
```

- **Подресурс status** (`subresources.status`): обычный patch `status` игнорирует (проверено — `phase` осталась `Applied` после попытки записать `Hacked`), менять его можно только через `/status` — права контроллера отдельно от прав пользователей (01-3 §6).
- Без схемы (`x-kubernetes-preserve-unknown-fields: true` на всё) API принимает любой мусор — ошибки всплывают в контроллере, а не при `kubectl apply`.
- Версии: `served` (отдаётся API), `storage` (в какой хранится в etcd — одна); переход v1beta1 → v1 — conversion webhook или совместимые схемы; `kubectl get crd <имя> -o jsonpath='{.status.storedVersions}'` — какие версии лежат в etcd (важно перед удалением старой версии, 10-2).

### Удалить CRD = удалить все объекты 🔴

Проверено: два CR, `kubectl delete crd retentionpolicies.ops.lab.local`:

```
CRs before CRD delete: 2
Error from server (NotFound): Unable to list "ops.lab.local/v1, Resource=retentionpolicies": … could not find the requested resource
```

Все объекты этого типа во всех namespace удалены вместе с CRD. Для операторов БД это значит: удаление CRD `clusters.postgresql.cnpg.io` удалит все кластеры PostgreSQL (а их finalizer'ы и owner-ссылки потянут за собой StatefulSet'ы/поды/PVC — в зависимости от оператора). Поэтому Helm-чарты операторов по умолчанию **не удаляют CRD** при `helm uninstall`, а «почистить кластер от лишних CRD» — операция с ревью.

## 2. Оператор: контроллер + знание предметной области 🟡

Оператор = CRD + контроллер, который в цикле reconcile (01-1 §2) приводит мир к описанному в CR — с «операционным знанием»: как развернуть, обновить, сделать бэкап, переключить primary.

```
CR Cluster (instances: 3) ──watch──► оператор
                                       ├─ создаёт поды/PVC/Service/Secret'ы
                                       ├─ следит за ролями (primary/replica), здоровьем
                                       ├─ при отказе primary — промоутит реплику, переключает Service -rw
                                       └─ пишет status: currentPrimary, readyInstances, conditions
```

Уровни зрелости (Operator Capability Levels): установка → обновления → полный жизненный цикл (бэкапы, восстановление) → глубокая наблюдаемость → автопилот (автомасштаб, авто-тюнинг). Большинство полезных операторов БД — уровень 3–4.

## 3. CloudNativePG: PostgreSQL с failover 🟡🔴

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata: {name: orders-db}
spec:
  instances: 3
  imageName: ghcr.io/cloudnative-pg/postgresql:17.6
  storage: {size: 1Gi}
  resources: {requests: {cpu: 100m, memory: 256Mi}, limits: {memory: 512Mi}}
  bootstrap:
    initdb: {database: orders, owner: orders}
```

Проверено — 3 экземпляра готовы за 79 с:

```
NAME        AGE   INSTANCES   READY   STATUS                     PRIMARY
orders-db   80s   3           3       Cluster in healthy state   orders-db-1
orders-db-1 Running lab-worker  primary
orders-db-2 Running lab-worker3 replica
orders-db-3 Running lab-worker2 replica
orders-db-rw  orders-db-ro  orders-db-r                         ← Service'ы: запись, только реплики, любые
orders-db-app  orders-db-ca  orders-db-replication  orders-db-server   ← Secret'ы: приложение, CA, TLS
```

Что CNPG делает иначе, чем StatefulSet (02-3): управляет **подами напрямую** (без StatefulSet), имена `orders-db-N`, каждый со своим PVC; реплики — потоковая репликация PostgreSQL; TLS между экземплярами и для клиентов из коробки; Secret приложения с готовым `uri`; разносит экземпляры по узлам (anti-affinity по умолчанию — на стенде все три на разных worker'ах).

### Failover: замер 🔴

Клиент пишет в `orders-db-rw` каждые 0,5 с; под primary удалён (лаба, шаг 4). Проверено:

```
primary=orders-db-2 deleted at 15:02:41
new primary=orders-db-1 after 5s
     11 ok 10.244.1.17/32
      2 FAIL psql: error: connection to server at "orders-db-rw.lab-09-1" (10.96.17…
     77 ok 10.244.2.233/32
first FAIL 15:02:42.161, last FAIL 15:02:44.692
101|3                                             ← 101 строка от трёх разных primary (по адресам), потерь нет
orders-db-2 Running replica                       ← бывший primary вернулся репликой
```

Окно ошибок записи — **~2,5 с** (две неудачные попытки), status оператора сменил `currentPrimary` за 5 с. Для сравнения: потеря узла с одиночным PostgreSQL на local-томе — 503 до возвращения узла (01-2, 05-4).

**Первый прогон** показал не менее важное (проверено): клиент без таймаутов **повис навсегда** на первой же попытке после удаления primary — `psql` открыл соединение к адресу, которого больше нет, и ждал без `connect_timeout`. Failover на стороне БД прошёл за секунды, а клиент так и не узнал. Отсюда требования к приложениям:

- таймаут подключения (`connect_timeout`, `PGCONNECT_TIMEOUT`) и запросов (`statement_timeout`), TCP keepalive;
- переподключение и повтор идемпотентных операций в пуле соединений;
- ходить в Service `-rw`, а не в конкретный под.

orders-api делает переподключение на каждый запрос и ставит `connect_timeout=2` (00-1, функция `db()`) — поэтому переживает failover; многие реальные пулы — нет, пока их не настроить.

### Что ещё даёт оператор (⚠️ на стенде не проверялось)

- бэкапы в объектное хранилище (базовые + WAL) и PITR — через плагин Barman Cloud (в новых версиях CNPG бэкапы вынесены в плагины);
- плановый switchover (без потери) — `kubectl cnpg promote` (плагин kubectl);
- rolling update минорных версий PostgreSQL: сначала реплики, потом switchover и старый primary;
- пул соединений `Pooler` (PgBouncer) как отдельный CR;
- мониторинг: метрики на каждом экземпляре.

## 4. Когда оператор оправдан 🔴

| За | Против |
|---|---|
| сложный жизненный цикл (БД, брокеры, поиск): failover, бэкапы, обновления | простое stateless-приложение — Deployment и Helm хватает |
| операция повторяется на десятках экземпляров | ещё один компонент со своими багами, CRD и обновлениями |
| зрелый проект с сообществом (CNCF/вендор) | самописный оператор «для одного сервиса» — дорого поддерживать |

Риски эксплуатации: оператор — точка отказа управления (упал — не будет failover, но работающая БД продолжит обслуживать); обновление оператора меняет поведение всех управляемых объектов; webhook'и оператора с `failurePolicy: Fail` могут заблокировать изменения в кластере (09-2); удаление оператора и CRD — удаление данных.

---

## 🔧 Лаба

### Шаг 0. Подготовка

```bash
kubectl config use-context kind-lab
kubectl create ns lab-09-1
kubectl config set-context --current --namespace=lab-09-1
```

### Шаг 1. Свой CRD

Создайте CRD из §1 (`kubectl apply -f - <<'EOF' … EOF`) и проверьте валидацию:

```bash
for spec in '{"target":"orders-db","keepDays":30}' '{"target":"cache","keepDays":30}' '{"target":"logs","keepDays":900}' \
            '{"target":"logs"}' '{"target":"backups","keepDays":7,"minKeepDays":14}'; do
  echo "{\"apiVersion\":\"ops.lab.local/v1\",\"kind\":\"RetentionPolicy\",\"metadata\":{\"name\":\"rp-$RANDOM\"},\"spec\":$spec}" | kubectl apply -f - 2>&1 | head -2
done
kubectl get rp; kubectl get rp -o jsonpath='{.items[0].spec}{"\n"}'
R=$(kubectl get rp -o name | head -1)
kubectl patch $R --subresource=status --type=merge -p '{"status":{"phase":"Applied"}}'
kubectl patch $R --type=merge -p '{"status":{"phase":"Hacked"}}'
kubectl get rp
kubectl explain retentionpolicy.spec
```

Проверено: вывод в §1.

### Шаг 2. Удаление CRD

```bash
kubectl apply -f - <<'EOF'
apiVersion: ops.lab.local/v1
kind: RetentionPolicy
metadata: {name: logs}
spec: {target: logs, keepDays: 14}
EOF
kubectl get rp -A
kubectl delete crd retentionpolicies.ops.lab.local
kubectl get rp -A
```

Проверено: 2 объекта → NotFound.

### Шаг 3. CloudNativePG

```bash
mkdir -p /tmp/lab-09-1 && cd /tmp/lab-09-1
curl -fL --retry 3 -o cnpg.yaml https://github.com/cloudnative-pg/cloudnative-pg/releases/download/v1.30.1/cnpg-1.30.1.yaml
wc -c cnpg.yaml                                   # ~1,29 МБ; меньше — файл недокачан, не применяйте
# образы с ghcr.io тянутся медленно — заранее на хост и в узлы kind
for img in ghcr.io/cloudnative-pg/cloudnative-pg:1.30.1 ghcr.io/cloudnative-pg/postgresql:17.6; do
  docker pull $img && kind load docker-image $img --name lab; done
kubectl apply --server-side -f cnpg.yaml
kubectl -n cnpg-system rollout status deploy/cnpg-controller-manager
kubectl apply -f - <<'EOF'
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata: {name: orders-db}
spec:
  instances: 3
  imageName: ghcr.io/cloudnative-pg/postgresql:17.6
  storage: {size: 1Gi}
  resources: {requests: {cpu: 100m, memory: 256Mi}, limits: {memory: 512Mi}}
  bootstrap:
    initdb: {database: orders, owner: orders}
EOF
until [ "$(kubectl get cluster orders-db -o jsonpath='{.status.readyInstances}')" = 3 ]; do sleep 5; done
kubectl get cluster orders-db
kubectl get pods -L cnpg.io/instanceRole -o wide
kubectl get svc,secret
```

Проверено: вывод в §3. Агент на первой попытке получил обрезанный манифест (таймаут curl посередине загрузки — 1,07 МБ из 1,29 МБ) и ошибки CRD `must have exactly one version marked as storage version` — проверяйте размер файла и код возврата curl до `apply`. Загрузка образа PostgreSQL заняла 181 с.

### Шаг 4. Failover

```bash
kubectl run writer --image=ghcr.io/cloudnative-pg/postgresql:17.6 --restart=Never --overrides='{"spec":{"containers":[{"name":"writer","image":"ghcr.io/cloudnative-pg/postgresql:17.6",
 "env":[{"name":"URI","valueFrom":{"secretKeyRef":{"name":"orders-db-app","key":"uri"}}},{"name":"PGCONNECT_TIMEOUT","value":"2"}],
 "command":["sh","-c","psql \"$URI\" -qc \"create table if not exists ticks(ts timestamptz default now(), host text)\"; while true; do if out=$(timeout 3 psql \"$URI\" -qtAc \"insert into ticks(host) select inet_server_addr()::text returning host\" 2>&1); then echo \"$(date +%T.%N | cut -c1-12) ok $out\"; else echo \"$(date +%T.%N | cut -c1-12) FAIL $(echo $out | cut -c1-70)\"; fi; sleep 0.5; done"]}]}}'
kubectl wait --for=condition=Ready pod/writer; sleep 5
PRIM=$(kubectl get cluster orders-db -o jsonpath='{.status.currentPrimary}'); kubectl delete pod $PRIM --wait=false
until [ "$(kubectl get cluster orders-db -o jsonpath='{.status.currentPrimary}')" != "$PRIM" ]; do sleep 1; done
kubectl get cluster orders-db -o jsonpath='new primary: {.status.currentPrimary}{"\n"}'
sleep 40; kubectl logs writer | awk '{print $2, $3}' | uniq -c
kubectl logs writer | grep FAIL
NEW=$(kubectl get cluster orders-db -o jsonpath='{.status.currentPrimary}')
kubectl exec $NEW -c postgres -- psql -U postgres -d orders -tAc "select count(*), count(distinct host) from ticks"
kubectl get pods -L cnpg.io/instanceRole
```

Проверено: вывод в §3. Уберите `PGCONNECT_TIMEOUT` и `timeout 3` — и писатель повиснет на первой попытке после удаления primary (так было в первом прогоне).

### Уборка

```bash
kubectl delete pod writer --now
kubectl delete cluster orders-db                 # оператор удалит поды и PVC кластера
kubectl config set-context --current --namespace=default
kubectl delete ns lab-09-1
kubectl delete -f /tmp/lab-09-1/cnpg.yaml        # оператор и его CRD — после удаления всех Cluster
rm -rf /tmp/lab-09-1
for n in lab-control-plane lab-worker lab-worker2 lab-worker3; do docker exec $n crictl rmi --prune; done
```

---

## 🔥 Кейс из прода: «удалили CRD — исчезли все объекты»

**Контекст.** При переезде на новый мажорный релиз оператора Redis команда удалила старый Helm-релиз оператора, «потому что новая версия ставит свои CRD». Старый чарт был настроен с `crds.keep: false` (кто-то когда-то включил «полную уборку»). Через минуту пропали все 14 кластеров Redis во всех namespace; приложения получили `connection refused`.

**Разбор.**
1. `helm uninstall` удалил CRD (`kubectl get crd | grep redis` — пусто).
2. Удаление CRD удаляет все объекты типа (шаг 2 лабы); у CR были owner-ссылки на StatefulSet'ы, GC удалил и их, а PVC — по `reclaimPolicy: Delete` вместе с дисками.
3. Восстановление — из бэкапов RDB, которые были не у всех экземпляров (кэш «не надо бэкапить» оказался сессионным хранилищем).

**Фикс.**
- Политика: CRD операторов не удаляются Helm'ом (`crds.keep: true` по умолчанию у большинства чартов — не трогать), удаление CRD — отдельная процедура с проверкой `kubectl get <тип> -A`.
- Admission-политика (06-2): запрет `DELETE` на CRD для всех, кроме роли платформенной команды.
- Обновление оператора — по инструкции вендора (обычно поверх, без удаления), сначала на стенде.
- PV ценных данных — `Retain` (04-2), бэкапы всего, что «вроде кэш».

**Что запомнить.**
- Удаление CRD удаляет все объекты этого типа во всём кластере.
- `helm uninstall` оператора может удалить CRD — проверяйте настройки чарта.
- Оператор и его CRD — часть данных, а не «просто софт».

---

## 💼 Вопросы с собеседования

### 🟢 Junior

**1. Что такое CRD?**
Определение нового типа ресурса в API Kubernetes: группа, версии, схема. После создания с объектами работают как со встроенными (`kubectl get`, RBAC, watch).

**2. Что такое оператор?**
Контроллер, который управляет приложением через CR: создаёт и обновляет ресурсы, выполняет операции (бэкапы, failover, обновления) в цикле reconcile — «автоматизированный дежурный».

### 🟡 Middle

**3. Чем CRD лучше ConfigMap для хранения конфигурации приложения?**
Схема и валидация в apiserver (типы, enum, CEL), отдельные права RBAC на тип, printer columns, status-подресурс для обратной связи от контроллера, watch по типу. ConfigMap — неструктурированные строки без проверки.

**4. Что будет, если удалить CRD?**
Удалятся все объекты этого типа во всех namespace; дальше — каскадное удаление по ownerReferences (поды, StatefulSet'ы, иногда PVC). Поэтому чарты операторов не удаляют CRD по умолчанию.

**5. Что происходит с БД под оператором, если упал сам оператор?**
Работающие экземпляры продолжают обслуживать запросы (как поды без control plane, 01-1); не будет failover, бэкапов, обновлений и реакции на изменения CR, пока оператор не вернётся. Оператору нужны реплики/лидер-элекшн и мониторинг.

### 🔴 Senior

**6. Как CloudNativePG делает failover и что нужно от приложения?**
Оператор видит недоступный primary, промоутит наиболее продвинутую реплику, переключает Service `-rw` на новый primary, старый после возврата становится репликой. На стенде окно ошибок записи — ~2,5 с. Приложению нужны таймауты подключения и запросов, переподключение пула, повтор идемпотентных операций и подключение через `-rw`, а не к поду; без таймаутов клиент может повиснуть навсегда (проверено).

**7. Писать свой оператор или нет?**
Только если есть повторяющаяся сложная операционная логика, которую нельзя закрыть существующими операторами, Helm/Kustomize и CronJob'ами, и есть команда, готовая сопровождать (обновления API, controller-runtime, тесты, RBAC). Иначе — зрелый оператор сообщества или managed-сервис.

**8. Как безопасно обновить оператор?**
Прочитать release notes (изменения CRD, поведения, дефолтов), обновить на стенде с такими же CR, обновлять поверх (без удаления CRD), проверить `storedVersions` и миграции версий CR, следить за rolling-обновлением управляемых экземпляров (оператор может перезапустить всё), иметь бэкапы.

---

## ⚠️ Подводные камни

- CR без контроллера — просто запись; ничего не происходит.
- CRD без схемы принимает мусор — ошибка всплывёт в контроллере.
- Удаление CRD удаляет все объекты типа; `helm uninstall` оператора может удалить CRD.
- Обрезанный манифест оператора (таймаут загрузки) даёт невалидные CRD — проверяйте файл до apply.
- Образы операторов с ghcr.io/quay.io/ECR тянутся медленно и упираются в лимиты — зеркалируйте.
- Клиент БД без таймаутов не переживёт failover, даже если оператор отработал за секунды.
- Оператор — точка отказа управления; его webhook'и — точка отказа API (09-2).
- Обновление оператора может перезапустить все управляемые экземпляры.

---

## Чеклист

- [ ] Напишу CRD со схемой, CEL-правилом, printer columns и status.
- [ ] Объясню, что произойдёт при удалении CRD, и как от этого защититься.
- [ ] Объясню устройство оператора и уровни зрелости.
- [ ] Разверну CloudNativePG и найду primary, Service'ы и Secret'ы.
- [ ] Измерю failover и назову требования к клиентам.
- [ ] Аргументирую «оператор или нет».

---

## Задание со звёздочкой

Переведите сквозной сценарий на CloudNativePG:

1. Создайте `Cluster orders-db` (3 экземпляра) в namespace `orders`, перенесите данные из старого PostgreSQL (`pg_dump`/`pg_restore`, 04-3; или `bootstrap.import` CNPG).
2. Переключите `DATABASE_URL` orders-api на Secret `orders-db-app` (ключ `uri`).
3. Повторите опыт 01-2 «узел теряет kubelet» на узле с primary: сколько секунд `curl http://orders.localhost:8088/api/orders` отвечает 503? Сравните с одиночным StatefulSet.
4. Поставьте плагин Barman Cloud с MinIO (04-3, задание) и сделайте восстановление на момент времени (PITR).

---

→ Следующая часть: **09-2. Admission webhooks и finalizers** — сломанный validating webhook с `failurePolicy: Fail` блокирует создание подов во всём кластере, `namespaceSelector` и `timeoutSeconds`; namespace, который висит в Terminating, — как найти, какой finalizer и какой контроллер его держат.
