# 07-2. Helm в работе: чужие чарты

> Модуль 7 «Пакетирование» · часть 2 из 3 · 🟡🔴 · ~1 ч чтения + ~45 мин лабы · Нужно: стенд 00-1, Helm 4.2.2, доступ к `registry-1.docker.io` (чарт и образ Bitnami PostgreSQL)

---

## Зачем это DevOps-у

Свои чарты пишут реже, чем ставят чужие: базы, брокеры, мониторинг, ingress-контроллеры, операторы. Чужой чарт — это 2000 строк values, десятки шаблонов и решения, принятые за вас: теги образов, генерация паролей, PVC, сетевые политики. В работе: «что этот чарт создаёт», «какой шаблон рождает это поле», «почему после переустановки БД не пускает», «что сломается при обновлении мажорной версии». На собеседовании это звучит как «как вы разбираетесь в чужом чарте» и «как ведёте values по окружениям».

Сквозной сценарий: вместо своего StatefulSet PostgreSQL (00-1) пробуем публичный чарт Bitnami PostgreSQL в отдельном namespace — и находим, где он отличается от ожиданий.

---

## 1. Разведка чарта до установки 🟢🟡

```bash
helm show chart  oci://registry-1.docker.io/bitnamicharts/postgresql --version 18.12.4   # версии чарта и приложения
helm show values oci://registry-1.docker.io/bitnamicharts/postgresql --version 18.12.4 > defaults.yaml
helm show readme …                                                                       # документация параметров
helm pull oci://registry-1.docker.io/bitnamicharts/postgresql --version 18.12.4          # архив для изучения и офлайн-установки
```

Проверено: чарт `18.12.4`, приложение `18.6.0`; `values.yaml` — **2030 строк**. Что смотреть в первую очередь:

| Раздел values | Вопрос |
|---|---|
| `image.*` | какой тег по умолчанию? (здесь — `latest`, §2) |
| `auth.*`, `*.existingSecret` | генерирует ли чарт пароли и что будет при переустановке (§3) |
| `*.persistence.*` | размер, StorageClass, судьба PVC при удалении |
| `resources`, `resourcesPreset` | есть ли requests/limits по умолчанию |
| `networkPolicy`, `pdb`, `serviceAccount` | какие ещё объекты создаёт чарт |
| `metrics`, `*.sidecars` | дополнительные контейнеры |

Список объектов — по комментариям `# Source:` в выводе `helm template` (проверено): `networkpolicy.yaml`, `pdb.yaml`, `statefulset.yaml`, `svc-headless.yaml`, `svc.yaml`, `serviceaccount.yaml` в `templates/primary/`. Чарт сам ставит NetworkPolicy и PDB — это нужно знать до установки (03-5, 05-4).

**Какой шаблон рождает поле** — `--show-only`:

```bash
helm template db ./postgresql-18.12.4.tgz -f values.yaml --show-only templates/primary/statefulset.yaml | grep -nE 'storage:|memory:|image:'
```

Проверено:

```
69:          image: registry-1.docker.io/bitnami/postgresql@sha256:e2815ea7…
152:              memory: 512Mi
155:              memory: 256Mi
191:            storage: "1Gi"
```

Ошибка рендера — `helm template --debug` выводит итоговый YAML даже с ошибкой, чтобы найти строку.

### Helm 4 и OCI: лишние строки в выводе 🟡

Проверено: `helm template` прямо из `oci://…` печатает в **stdout** строки `Pulled: registry-1.docker.io/bitnamicharts/postgresql:18.12.4` и `Digest: sha256:…` перед манифестами — `kubectl diff -f -` на них падает (`Object 'Kind' is missing`). Практика: сначала `helm pull` в файл (заодно фиксируется точная версия и дайджест чарта), потом `helm template ./postgresql-18.12.4.tgz` — вывод чистый.

## 2. Теги образов в чужих чартах 🟡

Проверено: чарт по умолчанию использует `bitnami/postgresql:latest`, `bitnami/postgres-exporter:latest`, `bitnami/os-shell:latest` и сам предупреждает при установке:

```
WARNING: Rolling tag detected (bitnami/postgresql:latest), please note that it is strongly recommended to avoid using rolling tags in a production environment.
```

Контекст: с 2025 года бесплатные образы Bitnami публикуются только с тегом `latest`; версионированные теги ушли в платный каталог, старые — в архивный `bitnamilegacy` (проверено: `docker.io/bitnamilegacy/postgresql:17.6.0-debian-12-r4` доступен, `docker.io/bitnami/postgresql:latest` — тоже). Для стабильности — фиксация по **дайджесту** (02-2):

```yaml
image:
  digest: "sha256:e2815ea79b38b77696bb189605a1f2e95a0bd3f70d419385500fc03d20d23c37"   # docker buildx imagetools inspect …:latest
```

Проверено: под запущен с `registry-1.docker.io/bitnami/postgresql@sha256:e2815ea7…`. Тег `latest` + `IfNotPresent` дал бы разные версии БД на разных узлах (02-2, §5). Для прода — зеркало образов в своём реестре (курс `cicd`, 03-2) и обновление дайджеста осознанно.

## 3. Пароли, PVC и переустановка 🔴

Чарт без `existingSecret` генерирует случайный пароль в Secret при **каждой установке**. А PVC StatefulSet при `helm uninstall` остаётся (02-3). Проверено:

```
after uninstall: data-db-postgresql-0 Bound secrets=0           ← PVC с данными есть, Secret удалён
password hash before=fb4afdaa after=4719a113                    ← после install — новый пароль
psql: error: … FATAL:  password authentication failed for user "postgres"
pod: 1/1 Running                                                 ← под «здоров»: probes не проверяют пароль
```

Новый пароль в Secret, старый — внутри данных на PVC (PostgreSQL задаёт пароль только при инициализации пустого каталога). Под зелёный, приложения не могут подключиться. Лечится только знанием старого пароля или удалением данных.

Правильно — свой Secret и `auth.existingSecret` (проверено: подключение с паролем из `pg-auth` к базе `shop` работает). То же для всех чартов с генерируемыми секретами (Redis, RabbitMQ, Keycloak…): пароль — во внешнем источнике (ESO, SOPS — 08-2), чарт его только читает.

Предупреждения чарта не всегда точны: после перехода на `existingSecret` NOTES выдали `WARNING: PostgreSQL has been configured without authentication` — при этом неверный пароль сервер отвергает (см. выше). Проверяйте поведение, а не текст.

## 4. Values по окружениям 🟡

```
charts/values/
  postgresql-common.yaml     # одинаковое везде: existingSecret, digest, metrics
  postgresql-staging.yaml    # 1Gi, маленькие requests
  postgresql-prod.yaml       # 100Gi, StorageClass ssd, requests по замерам, PDB
helm upgrade --install db ./postgresql-18.12.4.tgz -f postgresql-common.yaml -f postgresql-prod.yaml
```

Правила:

- переопределяйте **только нужное** — копия всех 2000 строк values не даст увидеть, что вы изменили, и сломается на обновлении чарта;
- версия чарта — в коде деплоя (`--version` или архив в репозитории), не «последняя»;
- `--reuse-values` при обновлении чарта не подхватывает новые дефолты — передавайте свои файлы целиком (`-f`), как в CI;
- секретов в values-файлах нет — только ссылки на Secret.

Values-файл стенда (проверено, `~/lab/k8s/charts/values/postgresql-lab.yaml`):

```yaml
image:
  digest: "sha256:e2815ea79b38b77696bb189605a1f2e95a0bd3f70d419385500fc03d20d23c37"
auth:
  existingSecret: pg-auth
  database: shop
primary:
  persistence: {size: 1Gi}
  resources:
    requests: {cpu: 100m, memory: 256Mi}
    limits: {memory: 512Mi}
metrics: {enabled: false}
```

## 5. Изменение и обновление: смотреть до применения 🟡🔴

Diff изменения — до upgrade (проверено, лимит памяти 512Mi → 768Mi):

```bash
helm template db ./postgresql-18.12.4.tgz -n lab-07-2 -f new-values.yaml | kubectl -n lab-07-2 diff -f -
```

```
-            memory: 512Mi
+            memory: 768Mi
```

Плагин `helm diff` делает то же с учётом релиза (⚠️ на стенде не ставился). Upgrade (проверено): `STATUS: deployed`, под пересоздан с `limit=768Mi`, данные (таблица `keep`) на месте.

**Мажорное обновление чарта** (18 → 19) — отдельная процедура:

1. прочитать раздел Upgrading в README чарта: Bitnami и другие крупные чарты меняют структуру values, имена объектов, селекторы;
2. `helm template` новой версии с теми же values → diff с текущим `helm get manifest`; особенно — `selector` StatefulSet/Deployment (неизменяем — upgrade упадёт), `volumeClaimTemplates` (неизменяемы), имена PVC;
3. мажорная версия **приложения** (PostgreSQL 17 → 18) — не апгрейд чарта, а миграция данных (pg_upgrade / dump-restore, 04-3);
4. бэкап и проверка восстановления перед обновлением.

## 6. Зависимости и subcharts 🟡

```yaml
# Chart.yaml «зонтичного» чарта
dependencies:
- name: postgresql
  version: 18.12.4
  repository: oci://registry-1.docker.io/bitnamicharts
  condition: postgresql.enabled
```

`helm dependency update` скачивает зависимости в `charts/`. Values subchart'а задаются под его именем (`postgresql.auth.existingSecret`), общие — в `global.*`. Зонтичный чарт «приложение + БД» удобен для стендов и плох для прода: БД обновляется вместе с приложением и удаляется вместе с ним.

---

## 🔧 Лаба

### Шаг 0. Подготовка и разведка

```bash
kubectl config use-context kind-lab
kubectl create ns lab-07-2
mkdir -p /tmp/lab-07-2 && cd /tmp/lab-07-2
CH=oci://registry-1.docker.io/bitnamicharts/postgresql
helm show chart $CH --version 18.12.4 | grep -E '^(version|appVersion)'
helm show values $CH --version 18.12.4 > defaults.yaml; wc -l < defaults.yaml
grep -A4 '^image:' defaults.yaml
helm pull $CH --version 18.12.4
```

### Шаг 1. Установка «как есть»

```bash
helm install db ./postgresql-18.12.4.tgz -n lab-07-2 --set primary.persistence.size=1Gi \
  --set primary.resources.requests.cpu=100m --set primary.resources.requests.memory=256Mi --wait --timeout 5m
kubectl -n lab-07-2 get pods,pvc,secret
```

Проверено: `STATUS: deployed` за 31 с и три предупреждения о `latest`.

### Шаг 2. Переустановка и пароль

```bash
pw() { kubectl -n lab-07-2 get secret db-postgresql -o jsonpath='{.data.postgres-password}' | base64 -d; }
q()  { kubectl -n lab-07-2 exec db-postgresql-0 -- env PGPASSWORD="$(pw)" psql -h 127.0.0.1 -U postgres -tAc "$1"; }
q "create table t(x int); insert into t values (42); select x from t"
P1=$(pw | sha256sum | cut -c1-8)
helm uninstall db -n lab-07-2 --wait
kubectl -n lab-07-2 get pvc,secret
helm install db ./postgresql-18.12.4.tgz -n lab-07-2 --set primary.persistence.size=1Gi \
  --set primary.resources.requests.cpu=100m --set primary.resources.requests.memory=256Mi --wait --timeout 5m
echo "before=$P1 after=$(pw | sha256sum | cut -c1-8)"
q "select x from t"
kubectl -n lab-07-2 get pod db-postgresql-0
```

Проверено: вывод в §3. Хэш пароля печатается, сам пароль — нет.

### Шаг 3. Правильная установка

```bash
helm uninstall db -n lab-07-2 --wait; kubectl -n lab-07-2 delete pvc data-db-postgresql-0
kubectl -n lab-07-2 create secret generic pg-auth --from-literal=postgres-password="$(head -c 18 /dev/urandom | base64)"
DIG=$(docker buildx imagetools inspect docker.io/bitnami/postgresql:latest --format '{{json .Manifest.Digest}}' | tr -d '"')
mkdir -p ~/lab/k8s/charts/values
cat > ~/lab/k8s/charts/values/postgresql-lab.yaml <<EOF
image:
  digest: "$DIG"
auth:
  existingSecret: pg-auth
  database: shop
primary:
  persistence:
    size: 1Gi
  resources:
    requests: {cpu: 100m, memory: 256Mi}
    limits: {memory: 512Mi}
metrics:
  enabled: false
EOF
helm install db ./postgresql-18.12.4.tgz -n lab-07-2 -f ~/lab/k8s/charts/values/postgresql-lab.yaml --wait --timeout 5m
kubectl -n lab-07-2 get pod db-postgresql-0 -o jsonpath='{.spec.containers[0].image}{"\n"}'
PW="$(kubectl -n lab-07-2 get secret pg-auth -o jsonpath='{.data.postgres-password}' | base64 -d)"
kubectl -n lab-07-2 exec db-postgresql-0 -- env PGPASSWORD="$PW" psql -h 127.0.0.1 -U postgres -d shop -tAc 'select current_database()'
```

Проверено: образ по дайджесту, `shop`. Дайджест у вас будет другим — `latest` меняется.

### Шаг 4. Источник поля и diff

```bash
V=~/lab/k8s/charts/values/postgresql-lab.yaml
helm template db ./postgresql-18.12.4.tgz -n lab-07-2 -f $V | grep '^# Source:' | sort | uniq -c
helm template db ./postgresql-18.12.4.tgz -n lab-07-2 -f $V --show-only templates/primary/statefulset.yaml | grep -nE 'storage:|memory:|image:'
sed 's/limits: {memory: 512Mi}/limits: {memory: 768Mi}/' $V > new.yaml
helm template db ./postgresql-18.12.4.tgz -n lab-07-2 -f new.yaml | kubectl -n lab-07-2 diff -f - | grep -E '^[-+] ' | grep -v generation
helm template db $CH --version 18.12.4 -n lab-07-2 -f new.yaml | head -2         # Pulled:/Digest: в stdout
```

Проверено: вывод в §1 и §5.

### Шаг 5. Upgrade и данные

```bash
kubectl -n lab-07-2 exec db-postgresql-0 -- env PGPASSWORD="$PW" psql -h 127.0.0.1 -U postgres -d shop -tAc "create table keep(x int); insert into keep values (7)"
helm upgrade db ./postgresql-18.12.4.tgz -n lab-07-2 -f new.yaml --wait --timeout 5m
kubectl -n lab-07-2 get pod db-postgresql-0 -o jsonpath='limit={.spec.containers[0].resources.limits.memory}{"\n"}'
kubectl -n lab-07-2 exec db-postgresql-0 -- env PGPASSWORD="$PW" psql -h 127.0.0.1 -U postgres -d shop -tAc "select x from keep"
unset PW
```

Проверено: `limit=768Mi`, `7`.

### Уборка

```bash
helm uninstall db -n lab-07-2 --wait
kubectl delete ns lab-07-2              # вместе с PVC и Secret pg-auth
cd ~ && rm -rf /tmp/lab-07-2
```

---

## 🔥 Кейс из прода: «переустановили Keycloak — никто не может войти»

**Контекст.** Keycloak с PostgreSQL как subchart в одном Helm-релизе; пароль БД генерировался чартом. Для «чистого» обновления мажорной версии команда сделала `helm uninstall` и `helm install` новой версии. Keycloak в CrashLoopBackOff: `password authentication failed for user "bn_keycloak"`.

**Разбор.**
1. `helm uninstall` удалил Secret с паролем, но не PVC PostgreSQL (StatefulSet, `Retain` по умолчанию — 02-3).
2. Новая установка сгенерировала новый пароль; база на PVC инициализирована со старым — ровно шаг 2 лабы.
3. Старого пароля нет нигде: Secret удалён, бэкапа Secret'ов не было.

**Фикс.**
- Восстановили доступ: под PostgreSQL временно запущен с `trust` в pg_hba для локальных подключений, пароль пользователя сменён на значение из нового Secret, `trust` убран.
- Пароли всех чартов — через `existingSecret` из внешнего менеджера секретов; Helm только читает.
- БД — отдельным релизом (или оператор), не subchart'ом приложения; обновление приложения не трогает БД.
- Мажорные обновления — `helm upgrade` по процедуре §5, не uninstall/install.

**Что запомнить.**
- Генерируемые чартом пароли + сохраняющийся PVC = поломка при переустановке.
- `helm uninstall` не удаляет PVC StatefulSet, но удаляет Secret'ы.
- Под «Running» не значит «приложения могут подключиться».

---

## 💼 Вопросы с собеседования

### 🟢 Junior

**1. Как узнать параметры чужого чарта?**
`helm show values` (все параметры по умолчанию с комментариями), `helm show readme`, `helm show chart`; `helm template` с вашими values — посмотреть, что получится.

**2. Как зафиксировать версию чарта?**
`--version` при установке или архив чарта (`helm pull`) в репозитории; в Chart.yaml зависимостей — точная версия.

### 🟡 Middle

**3. Как найти, какой шаблон чарта создаёт нужное поле?**
`helm template … | grep '# Source:'` — список шаблонов; `helm template … --show-only templates/<путь>` — один шаблон; затем сам шаблон в распакованном чарте. Ошибки рендера — `--debug`.

**4. Как вести values по окружениям?**
Общий файл + файл окружения, переопределяющие только нужное; версия чарта зафиксирована; секреты — ссылками (`existingSecret`); в CI — `-f` с полным набором, не `--reuse-values`; diff перед применением.

**5. Почему после переустановки чарта БД не принимает пароль?**
Чарт сгенерировал новый пароль в Secret, а данные на сохранившемся PVC инициализированы со старым. Решение — `existingSecret` с постоянным паролем, восстановление старого пароля или смена пароля в БД.

### 🔴 Senior

**6. Как безопасно обновить мажорную версию чужого чарта?**
README → изменения values и объектов; рендер новой версии с вашими values и diff с текущим манифестом; проверить неизменяемые поля (selector, volumeClaimTemplates) и имена PVC; бэкап и проверка восстановления; обновление на стенде; мажорная версия самого ПО (БД) — отдельная миграция данных.

**7. Чем плох зонтичный чарт «приложение + БД» в проде?**
Жизненные циклы связаны: обновление/откат/удаление приложения трогает БД, hooks и пароли общие, PVC и секреты удаляются вместе с релизом или остаются рассинхронизированными. Для прода — отдельный релиз БД, оператор или managed-сервис.

**8. Что делать с чартами, где по умолчанию `latest`?**
Фиксировать дайджест образа в values, зеркалировать образы в свой реестр, обновлять дайджест осознанно (с проверкой на стенде); политика admission против `latest` (06-2) поймает забытые места.

---

## ⚠️ Подводные камни

- Тег `latest` по умолчанию в популярных чартах (Bitnami с 2025 года — только `latest` бесплатно).
- Генерируемые пароли + PVC, переживающий `helm uninstall`.
- Под `Running` при неработающей аутентификации — probes не проверяют пароль.
- Предупреждения NOTES чарта могут быть неточными.
- `helm template oci://…` в Helm 4 пишет `Pulled:/Digest:` в stdout.
- Полная копия values чарта прячет ваши изменения и ломается при обновлении.
- `--reuse-values` не подхватывает новые дефолты.
- Чарт может создать NetworkPolicy, PDB, ServiceAccount, о которых вы не знали.
- Мажорная версия чарта ≠ мажорная версия приложения; второе — миграция данных.

---

## Чеклист

- [ ] Разберу чужой чарт до установки: values, объекты, теги, секреты, PVC.
- [ ] Найду шаблон, который рождает поле, и посмотрю diff перед upgrade.
- [ ] Зафиксирую версию чарта и дайджест образа.
- [ ] Настрою `existingSecret` и объясню, что ломается без него.
- [ ] Организую values по окружениям.
- [ ] Опишу процедуру мажорного обновления чарта.

---

## Задание со звёздочкой

Переведите сквозной сценарий на чарт:

1. Разверните Bitnami PostgreSQL в namespace `orders-chart` с `existingSecret`, базой `orders`, пользователем `orders` (параметры `auth.username`, `auth.secretKeys.userPasswordKey`).
2. Установите свой чарт orders-api (07-1) в тот же namespace с `database.secretName`, указывающим на Secret с `DATABASE_URL` к новой БД.
3. Перенесите данные из `orders` через `pg_dump`/`pg_restore` (04-3) и переключите HTTPRoute на новый релиз.
4. Напишите, что изменится в бэкапах (04-3) и в обслуживании узлов (05-4) — и стало ли лучше, чем свой StatefulSet.

---

→ Следующая часть: **07-3. Kustomize и выбор инструмента** — base и overlays для orders-api, strategic merge и JSON 6902 патчи, configMapGenerator с хэшем в имени и перезапуск подов, `images:`; Helm + Kustomize вместе и когда что выбирать.
