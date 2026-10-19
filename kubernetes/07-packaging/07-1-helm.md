# 07-1. Helm: чарты и релизы

> Модуль 7 «Пакетирование» · часть 1 из 3 · 🟢🟡🔴 · ~1,5 ч чтения + ~1 ч лабы · Нужно: стенд 00-1, Helm 4.2.2 (00-2), образы `orders-api:2.0` и `2.1`

---

## Зачем это DevOps-у

Helm — способ, которым ставится почти всё в кластере: от ingress-контроллеров и cert-manager до ваших сервисов. В работе с ним три класса проблем: «шаблон не рендерится / рендерится не то», «релиз завис: another operation is in progress», «upgrade прошёл, а в кластере не то» (не ждали готовности, конфликты полей, ручные правки). На собеседовании: «как устроен релиз», «как откатиться», «что делать с pending-upgrade», «зачем `--wait`». В 2025 году вышел Helm 4 — дефолты изменились, и рецепты из Helm 3 работают иначе (проверено ниже).

Сквозной сценарий: упаковываем orders-api в чарт и ставим вторую копию сервиса релизом `shop` рядом с основной (в namespace `lab-07-1`, БД — общая из `orders`).

---

## 1. Термины 🟢

| Что | Это |
|---|---|
| **chart** | пакет: `Chart.yaml` (имя, версия чарта, `appVersion`), `values.yaml` (параметры по умолчанию), `templates/` (Go-шаблоны манифестов), `charts/` (зависимости) |
| **values** | параметры: `values.yaml` чарта ← `-f my.yaml` ← `--set` (правее — важнее) |
| **release** | установленный экземпляр чарта с именем, в namespace; у каждого изменения — ревизия |
| **repository / OCI** | откуда брать чарты: HTTP-репозиторий с `index.yaml` или OCI-реестр (`oci://…`, как у Envoy Gateway и cert-manager в этом курсе) |

`version` — версия **чарта** (меняется при любом изменении шаблонов), `appVersion` — версия приложения (у нас — тег образа по умолчанию).

## 2. Чарт orders-api 🟡

Структура (`~/lab/k8s/charts/orders-api`):

```
Chart.yaml           values.yaml
templates/_helpers.tpl     метки, селектор, имя образа (тег или дайджест)
templates/configmap.yaml   config.json из values
templates/deployment.yaml  replicas только без HPA, checksum/config, required для secretName
templates/service.yaml     templates/hpa.yaml     templates/httproute.yaml
templates/migration-job.yaml   hook pre-install/pre-upgrade
templates/NOTES.txt
```

Ключевые приёмы, которые встречаются в любом зрелом чарте:

```yaml
# не держать replicas, когда работает HPA (01-3, кейс)
{{- if not .Values.autoscaling.enabled }}
replicas: {{ .Values.replicaCount }}
{{- end }}
# перезапуск подов при изменении конфигурации (04-1)
annotations:
  checksum/config: {{ include (print $.Template.BasePath "/configmap.yaml") . | sha256sum }}
# обязательные параметры — ошибка рендера, а не битый объект
name: {{ required "database.secretName обязателен" .Values.database.secretName }}
# тег по умолчанию — appVersion, дайджест важнее тега (02-2)
{{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}
```

Проверено: `helm lint` — `1 chart(s) linted, 0 chart(s) failed` (с советом добавить `icon`); пустой `secretName`:

```
Error: execution error at (orders-api/templates/deployment.yaml:24:46): database.secretName обязателен
```

Полный текст чарта — в лабе, шаг 1.

## 3. Где живёт релиз 🟡

Helm хранит каждую ревизию релиза в **Secret** в namespace релиза (проверено):

```
sh.helm.release.v1.shop.v1   helm.sh/release.v1   modifiedAt=…,name=shop,owner=helm,status=deployed,version=1
```

Внутри — сжатый JSON: values, отрендеренный манифест, статус, hooks. Отсюда:

- `helm list/history/get values/get manifest` — читают эти Secret'ы; права на них = права «видеть релиз» (и все values, включая пароли, если их передали через `--set`);
- удалили Secret'ы — Helm «забыл» релиз, объекты в кластере остались;
- `--history-max` (по умолчанию 10) ограничивает число хранимых ревизий.

Проверено: `helm get values shop` показывает **только** переданные пользователем значения (`USER-SUPPLIED VALUES`); `helm get manifest` — 4 объекта (ConfigMap, Service, Deployment, HTTPRoute), hook-Job в манифест не входит — hooks хранятся отдельно.

## 4. Helm 4: что изменилось 🟡🔴

Проверено на стенде (Helm v4.2.2):

| | Helm 3 | Helm 4 |
|---|---|---|
| применение объектов | client-side three-way merge | **server-side apply**, `--server-side=auto` (по методу прошлого релиза, для новых — SSA). В `managedFields` менеджер `helm`, операция `Apply` |
| ожидание готовности | без `--wait` не ждёт | без `--wait` — стратегия `hookOnly`: ждёт только hooks; `--wait` = `watcher` (kstatus) |
| откат при ошибке | `--atomic` | `--rollback-on-failure` (флага `--atomic` нет) |
| конфликты полей | перезаписывал | конфликт SSA, `--force-conflicts` |

### Без --wait «успех» ничего не значит

Проверено — upgrade на несуществующий тег `2.9` без `--wait`:

```
STATUS: deployed
REVISION: 2
took 1s
```

Helm записал `deployed`, а в кластере новый под в `ErrImagePull`. То же, что `kubectl apply` без `rollout status` (02-2, кейс). С `--wait --timeout 30s`:

```
Error: UPGRADE FAILED: resource Deployment/lab-07-1/shop not ready. status: InProgress, message: Updated: 1/2
--wait: took 31s; status=failed
   shop-6584744848-6j8gd Running
   shop-6584744848-h58hj Running
   shop-6b598d6f8b-vmh7c ErrImagePull        ← сломанный под остался
```

Релиз `failed`, но кластер в промежуточном состоянии. С `--rollback-on-failure`:

```
Error: UPGRADE FAILED: release shop failed, and has been rolled back due to rollback-on-failure being set: resource Deployment/lab-07-1/shop not ready…
4  deployed  Rollback to 1
image now: localhost:5001/orders-api:2.0
```

В CI — всегда `--wait` (или `--rollback-on-failure`, который включает ожидание) и `--timeout` с запасом над `progressDeadlineSeconds` (02-2).

### Ручная правка ломает следующий upgrade 🔴

Проверено: после ручного `kubectl rollout undo deploy/shop` следующий `helm upgrade` упал:

```
Error: UPGRADE FAILED: conflict occurred while applying object lab-07-1/shop apps/v1, Kind=Deployment: Apply failed with 2 conflicts: conflicts with "kubectl" using apps/v1: …
```

Server-side apply видит, что полями шаблона пода теперь владеет менеджер `kubectl` (`{"manager":"kubectl","operation":"Update"}` в `managedFields`), и отказывается затирать чужое (01-3 §3). `--force-conflicts` проходит, но след ручного менеджера остаётся, и конфликт возвращался на последующих upgrade'ах без флага. Правило: объекты релиза меняют **только через Helm**; экстренный откат — `helm rollback`, а не `kubectl rollout undo`; в CI для обновления существующих релизов, которые могли трогать руками, — `--force-conflicts` осознанно.

## 5. «another operation is in progress» 🟡

Helm ставит релизу статус `pending-install`/`pending-upgrade`/`pending-rollback` на время операции. Если процесс helm убит (отменили CI-job, кончился таймаут раннера, упал узел), статус остаётся. Проверено (`timeout -s KILL 5 helm upgrade … --wait`):

```
helm killed, exit=137
status: pending-upgrade
Error: UPGRADE FAILED: another operation (install/upgrade/rollback) is in progress
5   pending-upgrade   Preparing upgrade
sh.helm.release.v1.shop.v4   deployed
sh.helm.release.v1.shop.v5   pending-upgrade
```

Выход (проверено): `helm rollback shop` → `Rollback was a success!`, релиз `deployed rev 6`, дальше upgrade работает. Если rollback невозможен (первая установка в `pending-install`) — удалить Secret зависшей ревизии (`kubectl delete secret sh.helm.release.v1.<релиз>.v<N>`) и повторить; объекты в кластере проверить вручную. Профилактика: в CI не убивать helm по таймауту раннера раньше, чем истечёт `--timeout` самого helm; запрет параллельных деплоев одного релиза (`resource_group` в GitLab — курс `cicd` 02-6).

## 6. Hooks 🟡

Аннотации `helm.sh/hook: pre-install, pre-upgrade, post-upgrade, pre-delete, …` превращают объект в hook: он создаётся в нужный момент и **не входит** в релиз. Типовой — Job миграций БД перед upgrade:

```yaml
annotations:
  "helm.sh/hook": pre-install,pre-upgrade
  "helm.sh/hook-weight": "0"
  "helm.sh/hook-delete-policy": before-hook-creation,hook-succeeded
```

Проверено: upgrade с `migration.enabled=true` — Job отработал до обновления Deployment (`schema_version` = 8 — номер ревизии), удалён после успеха (`No resources found`). Hook упал — upgrade не продолжается. Подводные камни: hooks не откатываются при `helm rollback` (миграция вперёд останется — схема должна быть совместима с предыдущей версией, курс `cicd` 05-2 expand/contract); Job без `activeDeadlineSeconds` подвесит upgrade; `before-hook-creation` нужен, иначе повторный upgrade упадёт на «Job уже существует». В GitOps hooks Helm транслируются в sync hooks Argo CD (08-1).

---

## 🔧 Лаба

### Шаг 0. Подготовка

```bash
kubectl config use-context kind-lab
kubectl create ns lab-07-1
kubectl -n lab-07-1 create secret generic postgres --from-literal=DATABASE_URL=postgresql://orders:orders-lab-pass@postgres.orders:5432/orders
```

### Шаг 1. Чарт

```bash
C=~/lab/k8s/charts/orders-api; mkdir -p $C/templates; cd $C
cat > Chart.yaml <<'E'
apiVersion: v2
name: orders-api
description: orders-api — сквозной сценарий курса kubernetes
type: application
version: 0.1.0
appVersion: "2.0"
E
cat > values.yaml <<'E'
replicaCount: 2
image:
  repository: localhost:5001/orders-api
  tag: ""              # пусто — берётся appVersion из Chart.yaml
  digest: ""           # если задан — деплой по дайджесту (02-2)
autoscaling:
  enabled: false
  minReplicas: 2
  maxReplicas: 6
  targetCPU: 70
database:
  secretName: postgres      # Secret с ключом DATABASE_URL (00-1)
config:
  discount_percent: 0
  banner: welcome
resources:
  requests: {cpu: 100m, memory: 64Mi}
  limits: {memory: 256Mi}
route:
  enabled: true
  hostname: orders.localhost
  gateway: {name: lab, namespace: envoy-gateway-system}
migration:
  enabled: false
E
cat > templates/_helpers.tpl <<'E'
{{- define "orders-api.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Values.image.tag | default .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end }}
{{- define "orders-api.selector" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
{{- define "orders-api.image" -}}
{{- if .Values.image.digest -}}
{{ .Values.image.repository }}@{{ .Values.image.digest }}
{{- else -}}
{{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}
{{- end -}}
{{- end }}
E
cat > templates/configmap.yaml <<'E'
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ .Release.Name }}-config
  labels: {{- include "orders-api.labels" . | nindent 4 }}
data:
  config.json: {{ .Values.config | toJson | quote }}
E
cat > templates/deployment.yaml <<'E'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .Release.Name }}
  labels: {{- include "orders-api.labels" . | nindent 4 }}
spec:
  {{- if not .Values.autoscaling.enabled }}
  replicas: {{ .Values.replicaCount }}
  {{- end }}
  selector:
    matchLabels: {{- include "orders-api.selector" . | nindent 6 }}
  template:
    metadata:
      labels: {{- include "orders-api.selector" . | nindent 8 }}
      annotations:
        checksum/config: {{ include (print $.Template.BasePath "/configmap.yaml") . | sha256sum }}
    spec:
      containers:
      - name: api
        image: {{ include "orders-api.image" . }}
        ports: [{name: http, containerPort: 8000}]
        env:
        - name: DATABASE_URL
          valueFrom: {secretKeyRef: {name: {{ required "database.secretName обязателен" .Values.database.secretName }}, key: DATABASE_URL}}
        - {name: SHUTDOWN_DELAY, value: "5"}
        readinessProbe: {httpGet: {path: /ready, port: http}, periodSeconds: 2}
        livenessProbe: {httpGet: {path: /health, port: http}, periodSeconds: 10}
        resources: {{- toYaml .Values.resources | nindent 10 }}
        volumeMounts: [{name: config, mountPath: /etc/orders}]
      volumes:
      - name: config
        configMap: {name: {{ .Release.Name }}-config}
E
cat > templates/service.yaml <<'E'
apiVersion: v1
kind: Service
metadata:
  name: {{ .Release.Name }}
  labels: {{- include "orders-api.labels" . | nindent 4 }}
spec:
  selector: {{- include "orders-api.selector" . | nindent 4 }}
  ports: [{name: http, port: 80, targetPort: http}]
E
cat > templates/hpa.yaml <<'E'
{{- if .Values.autoscaling.enabled }}
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: {{ .Release.Name }}
  labels: {{- include "orders-api.labels" . | nindent 4 }}
spec:
  scaleTargetRef: {apiVersion: apps/v1, kind: Deployment, name: {{ .Release.Name }}}
  minReplicas: {{ .Values.autoscaling.minReplicas }}
  maxReplicas: {{ .Values.autoscaling.maxReplicas }}
  metrics: [{type: Resource, resource: {name: cpu, target: {type: Utilization, averageUtilization: {{ .Values.autoscaling.targetCPU }}}}}]
{{- end }}
E
cat > templates/httproute.yaml <<'E'
{{- if .Values.route.enabled }}
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: {{ .Release.Name }}
  labels: {{- include "orders-api.labels" . | nindent 4 }}
spec:
  parentRefs: [{name: {{ .Values.route.gateway.name }}, namespace: {{ .Values.route.gateway.namespace }}}]
  hostnames: [{{ .Values.route.hostname | quote }}]
  rules: [{backendRefs: [{name: {{ .Release.Name }}, port: 80}]}]
{{- end }}
E
cat > templates/migration-job.yaml <<'E'
{{- if .Values.migration.enabled }}
apiVersion: batch/v1
kind: Job
metadata:
  name: {{ .Release.Name }}-migrate-{{ .Release.Revision }}
  labels: {{- include "orders-api.labels" . | nindent 4 }}
  annotations:
    "helm.sh/hook": pre-install,pre-upgrade
    "helm.sh/hook-weight": "0"
    "helm.sh/hook-delete-policy": before-hook-creation,hook-succeeded
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 120
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: migrate
        image: postgres:17.6-alpine
        env: [{name: DATABASE_URL, valueFrom: {secretKeyRef: {name: {{ .Values.database.secretName }}, key: DATABASE_URL}}}]
        command: ["sh", "-c", "psql \"$DATABASE_URL\" -c 'CREATE TABLE IF NOT EXISTS schema_version (v int); INSERT INTO schema_version VALUES ({{ .Release.Revision }})'"]
{{- end }}
E
cat > templates/NOTES.txt <<'E'
orders-api {{ include "orders-api.image" . }} — релиз {{ .Release.Name }}, ревизия {{ .Release.Revision }}.
{{- if .Values.route.enabled }}
Проверка: curl http://{{ .Values.route.hostname }}:8088/api/orders
{{- end }}
E
helm lint .
helm template t . --set database.secretName=
cd ..
```

### Шаг 2. Установка и где лежит релиз

```bash
helm install shop ./orders-api -n lab-07-1 --set route.hostname=lab071.localhost --wait --timeout 2m
helm list -n lab-07-1
kubectl -n lab-07-1 get secret -l owner=helm --show-labels
kubectl -n lab-07-1 get deploy shop --show-managed-fields -o json | jq -c '.metadata.managedFields[] | {manager, operation}'
curl -s http://lab071.localhost:8088/api/orders | jq -c '{n: (.orders|length), pod}'
```

Проверено: `STATUS: deployed`, Secret `sh.helm.release.v1.shop.v1`, менеджер `helm` / `Apply`, `{"n":5,"pod":"shop-…"}`.

### Шаг 3. Ожидание и откат

```bash
helm upgrade shop ./orders-api -n lab-07-1 --reuse-values --set image.tag=2.9                     # «успех» за 1 с
kubectl -n lab-07-1 get pods
helm rollback shop -n lab-07-1
helm upgrade shop ./orders-api -n lab-07-1 --reuse-values --set image.tag=2.9 --wait --timeout 30s
kubectl -n lab-07-1 get pods
helm upgrade shop ./orders-api -n lab-07-1 --reuse-values --set image.tag=2.9 --rollback-on-failure --timeout 30s
helm history shop -n lab-07-1
kubectl -n lab-07-1 get deploy shop -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
```

Проверено: вывод в §4.

### Шаг 4. Ручная правка и конфликт SSA

```bash
kubectl -n lab-07-1 rollout undo deploy/shop
helm upgrade shop ./orders-api -n lab-07-1 --reuse-values --set image.tag=2.0 --wait --timeout 60s        # конфликт
kubectl -n lab-07-1 get deploy shop --show-managed-fields -o json | jq -c '.metadata.managedFields[] | {manager, operation}'
helm upgrade shop ./orders-api -n lab-07-1 --reuse-values --set image.tag=2.0 --force-conflicts --wait --timeout 60s
```

Проверено: `conflicts with "kubectl"` (§4). Чтобы полностью убрать след — переустановка релиза (`helm uninstall` + `install`) или удаление записи менеджера `kubectl` из `managedFields` патчем; в лабе — переустановка:

```bash
helm uninstall shop -n lab-07-1 --wait
helm install shop ./orders-api -n lab-07-1 --set route.hostname=lab071.localhost --wait --timeout 2m
```

### Шаг 5. Зависший pending-upgrade

```bash
timeout -s KILL 5 helm upgrade shop ./orders-api -n lab-07-1 --reuse-values --set image.tag=2.9 --wait --timeout 2m
helm status shop -n lab-07-1 -o json | jq -r .info.status
helm upgrade shop ./orders-api -n lab-07-1 --reuse-values --set image.tag=2.1
helm history shop -n lab-07-1 --max 2
helm rollback shop -n lab-07-1
helm upgrade shop ./orders-api -n lab-07-1 --reuse-values --set image.tag=2.1 --wait --timeout 60s
curl -s http://lab071.localhost:8088/version
```

Проверено: вывод в §5; в конце `{"version": "2.1", "pod": "shop-…"}`.

### Шаг 6. Hook миграции и checksum конфигурации

```bash
H1=$(kubectl -n lab-07-1 get deploy shop -o jsonpath='{.spec.template.metadata.annotations.checksum/config}')
helm upgrade shop ./orders-api -n lab-07-1 --reuse-values --set config.discount_percent=10 --set migration.enabled=true --wait --timeout 90s
H2=$(kubectl -n lab-07-1 get deploy shop -o jsonpath='{.spec.template.metadata.annotations.checksum/config}')
echo "${H1:0:12} -> ${H2:0:12}"
kubectl -n lab-07-1 get jobs
kubectl -n orders exec postgres-0 -- psql -U orders -d orders -tAc "select v from schema_version"
curl -s http://lab071.localhost:8088/config
helm get values shop -n lab-07-1
helm get manifest shop -n lab-07-1 | grep '^kind:'
```

Проверено: checksum сменился (`3a12bfdf1e09 -> b300b04a65b2`) и создал новый ReplicaSet; Job удалён после успеха; `schema_version` = номер ревизии; `/config` отдаёт `discount_percent: 10`.

### Уборка

```bash
helm uninstall shop -n lab-07-1 --wait
kubectl -n orders exec postgres-0 -- psql -U orders -d orders -c "DROP TABLE IF EXISTS schema_version"
kubectl delete ns lab-07-1
```

Чарт `~/lab/k8s/charts/orders-api` остаётся — он нужен в 07-2, 07-3 и модуле 8.

---

## 🔥 Кейс из прода: «helm upgrade зелёный, сервис лежит; следующий upgrade — another operation is in progress»

**Контекст.** CI-пайплайн: `helm upgrade --install app ./chart` без `--wait`, таймаут job'а GitLab 10 минут. После миграции раннеров на Helm 4 команда добавила `--wait`, но не `--timeout`. Новый релиз с ошибкой в конфиге стартовал и падал readiness. Через 10 минут GitLab убил job, следующий запуск пайплайна упал с `another operation (install/upgrade/rollback) is in progress`, ночной деплой хотфикса — тоже.

**Разбор.**
1. Без `--timeout` Helm ждал 5 минут по умолчанию на каждый ресурс и hooks — суммарно дольше таймаута job'а (у них было несколько Deployment'ов).
2. Job убит сигналом — Helm не успел записать `failed`; ревизия осталась `pending-upgrade` (шаг 5 лабы).
3. До `--wait` пайплайн годами отчитывался «зелёным» сразу после apply — сломанные релизы замечали пользователи (шаг 3 лабы: `deployed` за 1 с при несуществующем образе).

**Фикс.**
- `helm upgrade --install --rollback-on-failure --timeout 5m` (меньше таймаута job'а с запасом на rollback); `--wait-for-jobs`, если есть Job'ы.
- Перед upgrade — проверка статуса: если `pending-*` дольше N минут — `helm rollback` с алертом в чат.
- `resource_group` на деплой-job (курс `cicd` 02-6): два пайплайна не трогают один релиз одновременно.
- Мониторинг релизов: статус `failed`/`pending-*` в Secret'ах Helm (экспортер или проверка в CI).

**Что запомнить.**
- Без `--wait` Helm сообщает об успехе, не проверив ничего.
- Убитый helm оставляет `pending-*`; выход — `helm rollback`.
- Таймаут helm должен быть меньше таймаута CI-job'а.

---

## 💼 Вопросы с собеседования

### 🟢 Junior

**1. Что такое chart, values и release?**
Chart — пакет шаблонов манифестов и параметров по умолчанию. Values — параметры (из `values.yaml`, `-f`, `--set`). Release — установленный экземпляр чарта с именем и историей ревизий.

**2. Как откатить релиз?**
`helm history <релиз>` → `helm rollback <релиз> [ревизия]`. Создаётся новая ревизия с манифестом выбранной. Hooks (миграции) не откатываются.

### 🟡 Middle

**3. Где Helm хранит состояние релиза?**
В Secret'ах `sh.helm.release.v1.<релиз>.v<ревизия>` в namespace релиза: values, манифест, статус. Удаление Secret'ов «стирает» релиз из Helm, но не объекты.

**4. Что делать с «another operation is in progress»?**
Релиз застрял в `pending-*` — процесс helm прервали. `helm history` → `helm rollback` на последнюю deployed-ревизию; для `pending-install` — удалить Secret зависшей ревизии и повторить. Профилактика — `--timeout` меньше таймаута CI и запрет параллельных деплоев.

**5. Зачем `--wait` и `--rollback-on-failure`?**
Без ожидания Helm считает успехом принятие объектов API; с `--wait` — проверяет готовность ресурсов до `--timeout`, с `--rollback-on-failure` — при неудаче автоматически откатывает на предыдущую успешную ревизию. В Helm 4 `--atomic` заменён на `--rollback-on-failure`, дефолт ожидания — только hooks.

### 🔴 Senior

**6. Что меняет server-side apply в Helm 4 для эксплуатации?**
Helm — менеджер полей; ручные правки (`kubectl edit`, `rollout undo`, другие контроллеры) становятся владельцами полей, и следующий upgrade получает конфликт вместо тихой перезаписи. Это защищает от затирания чужих изменений (HPA, операторы), но ломает пайплайны с ручными вмешательствами: `--force-conflicts` осознанно, правки только через Helm, поля, которыми владеют другие, — не в шаблонах.

**7. Как обеспечить, чтобы изменение ConfigMap перезапускало поды?**
Аннотация в шаблоне пода с хэшем отрендеренного ConfigMap (`checksum/config: {{ include … | sha256sum }}`): изменение конфигурации меняет шаблон Deployment и запускает rollout.

**8. Чем опасны Helm hooks для миграций БД?**
Hook выполняется вне релиза и не откатывается — после `helm rollback` схема остаётся новой; падение hook'а останавливает upgrade, зависший Job — весь деплой. Нужны совместимые миграции (expand/contract), `activeDeadlineSeconds`, `before-hook-creation`, идемпотентность и блокировка от параллельного запуска.

---

## ⚠️ Подводные камни

- Helm 4 без `--wait`: `deployed` при неработающем релизе.
- `--wait` без `--rollback-on-failure`: релиз `failed`, кластер — в промежуточном состоянии.
- `--atomic` в Helm 4 нет — `--rollback-on-failure`.
- Ручные правки объектов релиза → конфликты SSA при следующем upgrade.
- Убитый helm оставляет `pending-*`.
- `--reuse-values` тянет старые values и не подхватывает новые дефолты чарта — для крупных изменений передавайте полный набор `-f`.
- Секреты через `--set` хранятся в Secret'е релиза и видны в `helm get values`.
- Hooks не входят в релиз и не откатываются.
- `replicas` в шаблоне при включённом HPA — сброс масштаба на каждом upgrade.

---

## Чеклист

- [ ] Напишу чарт с helpers, `required`, `checksum/config` и условным `replicas`.
- [ ] Найду Secret релиза и прочитаю values и манифест.
- [ ] Использую `--wait`, `--timeout`, `--rollback-on-failure` и объясню разницу.
- [ ] Выведу релиз из `pending-upgrade`.
- [ ] Объясню конфликт server-side apply после ручной правки и как его избежать.
- [ ] Напишу hook миграции с правильными политиками удаления.

---

## Задание со звёздочкой

Выпустите чарт как артефакт:

1. Упакуйте (`helm package`) и опубликуйте чарт в OCI-реестр стенда: `helm push orders-api-0.1.0.tgz oci://localhost:5001/charts` (⚠️ HTTP-реестр без TLS: проверьте флаг `--plain-http`).
2. Установите релиз из OCI (`helm install … oci://localhost:5001/charts/orders-api --version 0.1.0`).
3. Добавьте в чарт `values.schema.json` (тип `replicaCount` — integer ≥ 1, `image.repository` — обязательная строка) и убедитесь, что `--set replicaCount=abc` отклоняется до рендера.
4. Добавьте `templates/tests/` с `helm.sh/hook: test` — под, делающий `curl` на Service; запустите `helm test`.

---

→ Следующая часть: **07-2. Helm в работе: чужие чарты** — чарт PostgreSQL из публичного репозитория: `helm show values`, override-файлы по окружениям, поиск шаблона, который рождает поле, `helm template | kubectl diff`, мажорное обновление чарта и судьба PVC.
