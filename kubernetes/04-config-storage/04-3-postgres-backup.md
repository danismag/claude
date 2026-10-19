# 04-3. Данные в кластере: PostgreSQL, бэкап и восстановление

> Модуль 4 «Конфигурация и данные» · часть 3 из 3 · 🟡🔴 · ~1 ч чтения + ~45 мин лабы · Нужно: стенд 00-1 со сквозным сценарием (namespace `orders`). В лабе БД сквозного сценария **удаляется и восстанавливается из бэкапа**.

---

## Зачем это DevOps-у

«Бэкапы были, восстановиться не смогли» — один из самых дорогих инцидентов, и почти всегда он про то, что восстановление никто не проверял: дамп пустой, лежит на том же диске, не читается новой версией, процедура не описана. Бэкап, который не восстанавливали, — гипотеза. На собеседовании: «как бэкапить БД в Kubernetes», «что такое RPO и RTO», «стоит ли держать БД в кластере».

Сквозной сценарий: PostgreSQL orders-api (StatefulSet, PVC local-path) получает бэкап-CronJob, затем мы теряем его том целиком и восстанавливаем сервис, засекая RPO и RTO.

---

## 1. RPO, RTO и виды бэкапов 🟡

- **RPO** (Recovery Point Objective) — сколько данных можно потерять: время от последней точки восстановления до аварии.
- **RTO** (Recovery Time Objective) — сколько сервис может лежать: время от аварии до работы.

| Способ | RPO | Скорость восстановления | Консистентность | Переносимость |
|---|---|---|---|---|
| логический дамп (`pg_dump`) | интервал между дампами | медленно на больших БД (пересоздание индексов) | согласован внутри дампа | между версиями PostgreSQL, между кластерами |
| снапшот тома (CSI VolumeSnapshot, облачный диск) | интервал снапшотов | быстро (секунды на создание, минуты на диск) | crash-consistent без заморозки | только тот же тип хранилища |
| физический бэкап + WAL (pgBackRest, WAL-G, Barman, оператор) | секунды–минуты (PITR) | быстро + проигрывание WAL | точный | та же мажорная версия |
| реплика | ~0 | переключение | | не бэкап: `DROP TABLE` реплицируется мгновенно |

Для маленьких сервисов — дамп по расписанию; для прод-БД — физический бэкап с WAL в объектное хранилище (PITR, «вернуться на 14:32:10, до кривой миграции») — обычно через оператор (CloudNativePG, 09-1) или managed-БД.

**3-2-1**: три копии, на двух разных носителях, одна — вне площадки. В Kubernetes это значит: бэкап **не в том же PVC, не на том же узле, не в том же кластере** и желательно не в том же облачном аккаунте.

## 2. Бэкап-CronJob 🟡

Манифест (`~/lab/k8s/orders-api/k8s/extra/backup.yaml`) учитывает всё из 02-4:

```yaml
spec:
  schedule: "*/15 * * * *"
  timeZone: Europe/Moscow
  concurrencyPolicy: Forbid
  startingDeadlineSeconds: 300
  jobTemplate:
    spec:
      backoffLimit: 1
      activeDeadlineSeconds: 600          # зависший дамп не заблокирует следующие (кейс 02-4)
      ttlSecondsAfterFinished: 86400
      template:
        spec:
          containers:
          - name: dump
            image: postgres:17.6-alpine   # версия клиента = версия сервера (или новее)
            env: [PGHOST, PGUSER, PGPASSWORD, PGDATABASE из Secret postgres, PGCONNECT_TIMEOUT=10]
            command:
            - sh
            - -ec
            - |
              f=/backups/orders-$(date -u +%Y%m%dT%H%M%SZ).dump
              pg_dump --format=custom --no-owner --file="$f.tmp"
              mv "$f.tmp" "$f"                                  # атомарно: недописанный дамп не выглядит готовым
              pg_restore --list "$f" > /dev/null                # дамп читается
              ls -1t /backups/*.dump | tail -n +8 | xargs -r rm  # хранить 7 последних
```

Проверено (запуск вручную — `kubectl create job --from=cronjob/pg-backup backup-manual-1`):

```
backup job took 8s
backup ok: /backups/orders-20261014T103535Z.dump 4.0K
-rw-r--r--    1 root     root          2706 Oct 14 10:35 orders-20261014T103535Z.dump
```

Детали, которые отличают рабочий бэкап от «как бы»:

- `sh -e` — любая ошибка `pg_dump` валит Job (иначе пустой файл и «успех»);
- `--format=custom` — сжатие, выборочное восстановление, `pg_restore --list` как проверка целостности;
- запись во временный файл и `mv` — неполный дамп при обрыве не подменяет хороший;
- ротация — и проверка, что ротация не удаляет последний удачный, если новые падают;
- `kubectl create job --from=cronjob/…` — запуск по требованию (перед миграцией, перед рискованным деплоем).

## 3. Авария и восстановление: замер 🟡

Сценарий (лаба, шаг 3): после бэкапа добавлена запись `after-backup`, затем удалены StatefulSet и PVC `data-postgres-0` — эквивалент потери диска. Восстановление по процедуре: остановить приложение → создать пустой PostgreSQL → `pg_restore` последнего дампа → вернуть приложение. Проверено:

```
before disaster: ["book","pen","lamp","mug","desk","after-backup"]
disaster at t=0: sts+pvc deleted (1s)
api during outage: 503
t=+13s new empty postgres ready
t=+16s restore done: restoring /backups/orders-20261014T103535Z.dump 5
t=+18s API OK: ["book","pen","lamp","mug","desk"]
```

- **RTO = 18 с** — на крошечной БД, с образом в кэше узла и отрепетированными командами. На реальной БД в 200 ГБ логическое восстановление идёт часами (индексы, ограничения) — именно поэтому для больших БД нужны физические бэкапы.
- **RPO** — запись `after-backup` потеряна: всё, что после последнего дампа. При расписании `*/15` — до 15 минут данных.
- Почему приложение остановлено на время восстановления: orders-api при старте видит пустую БД и пишет в неё «начальные» заказы (`init_db`), а клиенты — новые; после `pg_restore --clean` их бы не стало. Восстановление — с остановленными писателями.

## 4. Проверка бэкапа — автоматически 🔴

Job (`backup-verify.yaml`), который берёт последний дамп, поднимает **временный PostgreSQL в том же поде**, восстанавливает дамп и проверяет данные:

```sh
f=$(ls -1t /backups/*.dump | head -1)
age=$(( $(date +%s) - $(stat -c %Y "$f") ))
[ "$age" -lt 3600 ] || { echo "FAIL: backup older than 1h"; exit 1; }
docker-entrypoint.sh postgres >/tmp/pg.log 2>&1 &
until pg_isready -q -h 127.0.0.1; do sleep 1; done
createdb -h 127.0.0.1 verify
pg_restore -h 127.0.0.1 --no-owner --exit-on-error -d verify "$f"
rows=$(psql -h 127.0.0.1 -d verify -tAc "select count(*) from orders")
[ "$rows" -ge "$MIN_ROWS" ] && echo "VERIFY OK"
```

Проверено:

```
verify took 6s
latest: /backups/orders-20261014T103535Z.dump, age 54s
restored rows: 5
VERIFY OK
```

Проверяется три вещи: свежесть, читаемость, правдоподобность содержимого. Такой Job по расписанию + алерт на его провал — это и есть «проверенное восстановление». Раз в квартал — учения с замером RTO на полноразмерной копии.

## 5. Где лежит бэкап 🔴

Проверено на стенде:

```
pg-backups PV node=lab-worker
postgres-0 node=lab-worker
```

PVC с бэкапами — на **том же узле**, что и БД (local-path, WaitForFirstConsumer: оба PVC создались там, где их впервые использовали). Потеря узла = потеря и БД, и бэкапов. На стенде это лечится копированием за пределы кластера (лаба, шаг 5 — `kubectl cp` на хост, sha256 совпали). В проде:

- дамп сразу в объектное хранилище (S3/MinIO/YC Object Storage) с версионированием и Object Lock (защита от удаления — в том числе злоумышленником с доступом к кластеру);
- отдельные учётные данные «только запись» для бэкапа, чтение — другим ключом;
- шифрование дампа (`age`, `gpg`) или хранилища;
- хранение по политике (дневные 7, недельные 4, месячные 12) — настройками жизненного цикла бакета.

## 6. БД в Kubernetes: да или нет 🔴

| За | Против |
|---|---|
| одинаковая поставка для всего, GitOps | stateful-нагрузка требует зрелости: хранилище, бэкапы, обновления, failover |
| операторы (CloudNativePG, Zalando, Crunchy) закрывают репликацию, PITR, switchover | ошибки планирования (05-2), вытеснения (05-4), drain узлов бьют по БД |
| локальные NVMe и TopoLVM дают скорость bare metal | local-хранилище привязывает под к узлу (04-2) |
| нет зависимости от облачного managed-сервиса, дешевле на bare metal | managed-БД (RDS, Cloud SQL, YC MDB) снимают с вас бэкапы, патчи, failover |

Практичный ответ на собеседовании — «зависит»: dev/стенды и небольшие сервисы — StatefulSet или оператор; прод с жёсткими RPO/RTO — оператор с проверенными бэкапами и учениями или managed-сервис; без людей, готовых дежурить по БД, — managed. И в любом варианте: бэкапы вне кластера и проверка восстановления.

---

## 🔧 Лаба

### Шаг 0. Подготовка

```bash
kubectl config use-context kind-lab
kubectl -n orders get sts,pvc,pods
curl -s http://orders.localhost:8088/api/orders | jq -c '[.orders[].item]'
```

### Шаг 1. Бэкап-CronJob

```bash
mkdir -p ~/lab/k8s/orders-api/k8s/extra
cat > ~/lab/k8s/orders-api/k8s/extra/backup.yaml <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: pg-backups, namespace: orders}
spec:
  accessModes: [ReadWriteOnce]
  resources: {requests: {storage: 1Gi}}
---
apiVersion: batch/v1
kind: CronJob
metadata: {name: pg-backup, namespace: orders}
spec:
  schedule: "*/15 * * * *"
  timeZone: Europe/Moscow
  concurrencyPolicy: Forbid
  startingDeadlineSeconds: 300
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      backoffLimit: 1
      activeDeadlineSeconds: 600
      ttlSecondsAfterFinished: 86400
      template:
        spec:
          restartPolicy: Never
          containers:
          - name: dump
            image: postgres:17.6-alpine
            env:
            - {name: PGHOST, value: postgres}
            - {name: PGUSER, valueFrom: {secretKeyRef: {name: postgres, key: POSTGRES_USER}}}
            - {name: PGPASSWORD, valueFrom: {secretKeyRef: {name: postgres, key: POSTGRES_PASSWORD}}}
            - {name: PGDATABASE, valueFrom: {secretKeyRef: {name: postgres, key: POSTGRES_DB}}}
            - {name: PGCONNECT_TIMEOUT, value: "10"}
            command:
            - sh
            - -ec
            - |
              f=/backups/orders-$(date -u +%Y%m%dT%H%M%SZ).dump
              pg_dump --format=custom --no-owner --file="$f.tmp"
              mv "$f.tmp" "$f"
              pg_restore --list "$f" > /dev/null
              ls -1t /backups/*.dump | tail -n +8 | xargs -r rm
              echo "backup ok: $f $(du -h "$f" | cut -f1)"; ls -l /backups
            volumeMounts: [{name: backups, mountPath: /backups}]
          volumes: [{name: backups, persistentVolumeClaim: {claimName: pg-backups}}]
EOF
kubectl apply -f ~/lab/k8s/orders-api/k8s/extra/backup.yaml
kubectl -n orders exec postgres-0 -- psql -U orders -d orders -c "INSERT INTO orders (item, qty) VALUES ('mug', 3), ('desk', 1)"
kubectl -n orders create job --from=cronjob/pg-backup backup-manual-1
kubectl -n orders wait --for=condition=Complete job/backup-manual-1 --timeout=180s
kubectl -n orders logs job/backup-manual-1
```

Проверено: вывод в §2 (в манифесте лабы переменные расписаны полностью; в §2 — сокращённо).

### Шаг 2. Проверка бэкапа

```bash
cat > ~/lab/k8s/orders-api/k8s/extra/backup-verify.yaml <<'EOF'
apiVersion: batch/v1
kind: Job
metadata: {name: pg-backup-verify, namespace: orders}
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 600
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: verify
        image: postgres:17.6-alpine
        env:
        - {name: POSTGRES_PASSWORD, value: verify-only}
        - {name: PGUSER, value: postgres}
        - {name: PGPASSWORD, value: verify-only}
        - {name: MIN_ROWS, value: "2"}
        command:
        - sh
        - -ec
        - |
          f=$(ls -1t /backups/*.dump | head -1)
          age=$(( $(date +%s) - $(stat -c %Y "$f") ))
          echo "latest: $f, age ${age}s"
          [ "$age" -lt 3600 ] || { echo "FAIL: backup older than 1h"; exit 1; }
          docker-entrypoint.sh postgres >/tmp/pg.log 2>&1 &
          until pg_isready -q -h 127.0.0.1; do sleep 1; done
          createdb -h 127.0.0.1 verify
          pg_restore -h 127.0.0.1 --no-owner --exit-on-error -d verify "$f"
          rows=$(psql -h 127.0.0.1 -d verify -tAc "select count(*) from orders")
          echo "restored rows: $rows"
          [ "$rows" -ge "$MIN_ROWS" ] && echo "VERIFY OK" || { echo "FAIL: too few rows"; exit 1; }
        volumeMounts: [{name: backups, mountPath: /backups, readOnly: true}]
      volumes: [{name: backups, persistentVolumeClaim: {claimName: pg-backups}}]
EOF
kubectl apply -f ~/lab/k8s/orders-api/k8s/extra/backup-verify.yaml
kubectl -n orders wait --for=condition=Complete job/pg-backup-verify --timeout=180s
kubectl -n orders logs job/pg-backup-verify
```

Проверено: вывод в §4. Проверку можно запускать сразу после шага 1: PVC RWO смонтирован Job'ом верификации на том же узле — read-only второго потребителя на узле RWO допускает (04-2).

### Шаг 3. Авария и восстановление

```bash
api() { curl -s -m 3 http://orders.localhost:8088/api/orders; }
kubectl -n orders exec postgres-0 -- psql -U orders -d orders -c "INSERT INTO orders (item, qty) VALUES ('after-backup', 9)"
echo "before disaster: $(api | jq -c '[.orders[].item]')"
T0=$(date +%s)
kubectl -n orders delete sts postgres; kubectl -n orders delete pvc data-postgres-0
kubectl -n orders wait --for=delete pod/postgres-0 --timeout=60s
curl -s -o /dev/null -w 'api during outage: %{http_code}\n' http://orders.localhost:8088/api/orders

# процедура восстановления
kubectl -n orders scale deploy orders-api --replicas=0                        # 1. остановить писателей
kubectl apply -f ~/lab/k8s/orders-api/k8s/postgres.yaml                       # 2. пустая БД
kubectl -n orders rollout status sts/postgres --timeout=180s; echo "t=+$(( $(date +%s)-T0 ))s new empty postgres ready"
kubectl apply -f - <<'EOF'
apiVersion: batch/v1
kind: Job
metadata: {name: pg-restore, namespace: orders}
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: restore
        image: postgres:17.6-alpine
        env:
        - {name: PGHOST, value: postgres}
        - {name: PGUSER, valueFrom: {secretKeyRef: {name: postgres, key: POSTGRES_USER}}}
        - {name: PGPASSWORD, valueFrom: {secretKeyRef: {name: postgres, key: POSTGRES_PASSWORD}}}
        - {name: PGDATABASE, valueFrom: {secretKeyRef: {name: postgres, key: POSTGRES_DB}}}
        command:
        - sh
        - -ec
        - |
          f=$(ls -1t /backups/*.dump | head -1); echo "restoring $f"
          pg_restore --clean --if-exists --no-owner --exit-on-error --dbname="$PGDATABASE" "$f"
          psql -tAc "select count(*) from orders"
        volumeMounts: [{name: backups, mountPath: /backups}]
      volumes: [{name: backups, persistentVolumeClaim: {claimName: pg-backups}}]
EOF
kubectl -n orders wait --for=condition=Complete job/pg-restore --timeout=180s     # 3. восстановить
echo "t=+$(( $(date +%s)-T0 ))s restore done: $(kubectl -n orders logs job/pg-restore | tr '\n' ' ')"
kubectl -n orders scale deploy orders-api --replicas=2                         # 4. вернуть приложение
kubectl -n orders rollout status deploy/orders-api
until api | grep -q orders; do sleep 1; done; echo "t=+$(( $(date +%s)-T0 ))s API OK: $(api | jq -c '[.orders[].item]')"
```

Проверено: вывод в §3. Новый `postgres-0` создаст PVC там, где окажется под; `pg-backups` должен быть смонтирован Job'ом восстановления на своём узле — scheduler сам поставит Job туда (04-2).

### Шаг 4. RPO своими словами

Сравните списки «до аварии» и «после восстановления»: потеряно ровно то, что записано после времени в имени дампа. Посчитайте свой RPO при расписании `*/15` и при ежесуточном. Что нужно, чтобы RPO стал минутным? (Ответ — §1: WAL-архив.)

### Шаг 5. Копия вне кластера

```bash
mkdir -p ~/lab/k8s/backups
kubectl -n orders run bk-copy --image=busybox:1.37 --restart=Never \
  --overrides='{"spec":{"containers":[{"name":"c","image":"busybox:1.37","command":["sleep","300"],"volumeMounts":[{"name":"b","mountPath":"/backups","readOnly":true}]}],"volumes":[{"name":"b","persistentVolumeClaim":{"claimName":"pg-backups"}}]}}'
kubectl -n orders wait --for=condition=Ready pod/bk-copy
F=$(kubectl -n orders exec bk-copy -- sh -c 'ls -1t /backups/*.dump | head -1')
kubectl -n orders cp bk-copy:$F ~/lab/k8s/backups/$(basename $F)
sha256sum ~/lab/k8s/backups/*.dump; kubectl -n orders exec bk-copy -- sha256sum $F
kubectl -n orders delete pod bk-copy --now
```

Проверено: хэши совпадают (`0a55d369…`). `kubectl cp` использует `tar` в контейнере — образ должен его содержать (в distroless нет).

### Уборка

```bash
kubectl delete -f ~/lab/k8s/orders-api/k8s/extra/backup-verify.yaml
kubectl -n orders delete job pg-restore backup-manual-1 --ignore-not-found
kubectl delete -f ~/lab/k8s/orders-api/k8s/extra/backup.yaml          # CronJob и PVC с бэкапами
curl -s http://orders.localhost:8088/api/orders | jq -c '[.orders[].item]'   # данные восстановлены — сквозной сценарий продолжает работать
```

Дамп в `~/lab/k8s/backups/` остаётся (удаляется `lab-down.sh --purge`).

---

## 🔥 Кейс из прода: «бэкапы были, восстановиться не смогли»

**Контекст.** PostgreSQL в StatefulSet, ночной CronJob `pg_dump > /backups/dump.sql` на PVC того же StorageClass. Через полгода ошибочная миграция удалила столбец с данными клиентов. Попытка восстановления: последний «успешный» дамп — 0 байт; предыдущие — перезаписаны (одно имя файла); PVC с бэкапами — на том же узле и в том же namespace, что и БД.

**Разбор.**
1. Команда без `set -e`: `pg_dump` падал на аутентификации (пароль сменили три месяца назад), shell-перенаправление создавало пустой файл, Job завершался с кодом 0.
2. Мониторинг смотрел на «CronJob успешен» — он и был успешен.
3. Одно имя файла — ни одной старой копии. Восстановление никто никогда не пробовал.
4. Данные частично восстановили из WAL-логов на диске — повезло, что том был цел.

**Фикс.**
- `sh -e`, формат `custom`, атомарная запись и `pg_restore --list` (шаг 1 лабы); имена с меткой времени и ротация.
- Автоматическая проверка восстановления по расписанию (шаг 2) с алертом; метрика «возраст последнего проверенного бэкапа».
- Бэкапы — в объектное хранилище другого аккаунта с версионированием и Object Lock.
- Для прод-БД — оператор с WAL-архивированием и PITR; квартальные учения восстановления с замером RTO.

**Что запомнить.**
- Код 0 у бэкап-Job'а не значит, что бэкап есть.
- Бэкап, который не восстанавливали, — не бэкап.
- Бэкап на том же узле/томе/кластере не переживёт ту же аварию.

---

## 💼 Вопросы с собеседования

### 🟢 Junior

**1. Что такое RPO и RTO?**
RPO — сколько данных можно потерять (время от последней точки восстановления до аварии). RTO — сколько сервис может быть недоступен до восстановления.

**2. Как сделать бэкап PostgreSQL в Kubernetes?**
CronJob с `pg_dump` (формат custom) в надёжное хранилище вне кластера, с проверкой результата; для прод-БД — физические бэкапы с WAL через оператор или managed-сервис.

### 🟡 Middle

**3. Почему реплика БД — не бэкап?**
Реплика повторяет все изменения, включая ошибочные (`DROP TABLE`, кривая миграция) — почти мгновенно. Она защищает от отказа узла, но не от потери данных по ошибке. Нужна точка во времени до ошибки — бэкап/PITR.

**4. Чем логический бэкап отличается от снапшота тома?**
Дамп — согласованный, переносимый между версиями и кластерами, но медленный на восстановлении больших БД. Снапшот — быстрый, но привязан к хранилищу и без заморозки БД crash-consistent. Часто используют оба.

**5. Как проверить, что бэкап рабочий?**
Регулярно восстанавливать его автоматически во временную БД и проверять: свежесть, читаемость, правдоподобность данных (число строк, контрольные запросы); алерт на провал. Периодически — полные учения с замером RTO.

### 🔴 Senior

**6. Как получить RPO в минуты для PostgreSQL в кластере?**
Непрерывное архивирование WAL в объектное хранилище (WAL-G, pgBackRest, Barman, CloudNativePG) плюс периодические базовые бэкапы; восстановление на произвольный момент (PITR). RPO определяется частотой отправки WAL-сегментов (`archive_timeout`), обычно минута и меньше.

**7. Держать ли прод-БД в Kubernetes?**
Зависит от зрелости команды и требований: с оператором (репликация, failover, PITR), надёжным хранилищем и отрепетированными восстановлениями — да; без людей, умеющих дежурить по БД, и при жёстких RPO/RTO — managed-сервис. В обоих случаях бэкапы вне кластера и учения.

**8. Почему при восстановлении нужно останавливать приложение?**
Иначе оно пишет в пустую или частично восстановленную БД: свои начальные данные, новые заказы клиентов, миграции схемы — всё это будет затёрто `--clean` или конфликтует с восстановленными данными. Процедура: остановить писателей (scale 0 / режим обслуживания), восстановить, проверить, вернуть.

---

## ⚠️ Подводные камни

- `pg_dump > file` без `set -e` и проверки — пустой файл и код 0.
- Одно имя файла — перезапись единственной копии.
- Бэкап на том же узле, PVC или в том же кластере.
- Версия `pg_dump` старше сервера — дамп не сделается.
- Восстановление при работающем приложении — смешанные или потерянные данные.
- Логическое восстановление большой БД — часы; RTO надо мерить на реальном объёме.
- `kubectl cp` требует `tar` в образе.
- Реплика не защищает от логических ошибок.
- Мониторинг «CronJob успешен» вместо «последний проверенный бэкап свежий».

---

## Чеклист

- [ ] Объясню RPO/RTO и выберу способ бэкапа под требования.
- [ ] Напишу бэкап-CronJob с проверками и ротацией.
- [ ] Автоматически проверю бэкап восстановлением во временную БД.
- [ ] Восстановлю сервис после потери тома и замерю RPO и RTO.
- [ ] Вынесу бэкап за пределы узла и кластера.
- [ ] Аргументирую «БД в Kubernetes или managed».

---

## Задание со звёздочкой

Вынесите бэкапы в объектное хранилище:

1. Поднимите MinIO в namespace `minio` (Deployment + PVC, образ `minio/minio` с закреплённым тегом) и создайте бакет `pg-backups` с версионированием.
2. Перепишите CronJob: дамп в emptyDir → загрузка `mc cp` в бакет с меткой времени; учётные данные — из отдельного Secret с правами только на запись.
3. Удалите namespace `orders` целиком (!), восстановите сквозной сценарий с нуля по 00-1 §4 и данные из MinIO. Замерьте RTO.
4. Что изменится, если MinIO в том же кластере сломается вместе с ним? Как бы вы сделали «вне кластера» на стенде?

---

→ Следующая часть: **05-1. Requests, limits и QoS** — пробная часть курса, уже написана: QoS-классы и их cgroup, OOMKilled и `memory.oom.group`, троттлинг CPU на cgroup пода, квоты, resize без рестарта. Дальше — 05-2 Scheduler.
