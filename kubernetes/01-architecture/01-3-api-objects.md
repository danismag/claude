# 01-3. API-объекты и kubectl под капотом

> Модуль 1 «Архитектура» · часть 3 из 3 · 🟢🟡🔴 · ~1,5 ч чтения + ~45 мин лабы · Нужно: стенд 00-1

---

## Зачем это DevOps-у

Почти все «магические» эффекты в кластере объясняются устройством объектов API. «Применил манифест — HPA сбросился», «Argo CD и Helm перетягивают поле», «удалил Deployment — поды остались», «namespace неделю в Terminating», «поменял status — ничего не изменилось» — это field managers, ownerReferences, finalizers и подресурсы. Middle-собеседование почти наверняка спросит, чем `apply` отличается от `create`/`replace`, что такое finalizer и как работает каскадное удаление.

В сквозном сценарии это объясняет, почему orders-api под HPA нельзя деплоить манифестом с `replicas:` (кейс части) и почему GitOps-инструменты (08-1) так внимательны к тому, кто владеет каким полем.

---

## 1. Анатомия объекта 🟢

```yaml
apiVersion: apps/v1          # группа/версия API: /apis/apps/v1
kind: Deployment
metadata:
  name: orders-api           # уникально в namespace и типе
  namespace: orders
  uid: 8b93054a-…            # уникален навсегда; новый объект с тем же именем — новый uid
  resourceVersion: "3429"    # ревизия etcd (01-1)
  generation: 2              # счётчик изменений spec (status не увеличивает)
  labels: {app: orders-api}  # для выборки: selectors, kubectl -l
  annotations: {…}           # для произвольных данных: инструменты, заметки
  ownerReferences: […]       # кто владелец (§4)
  finalizers: […]            # что должно случиться до удаления (§5)
  managedFields: […]         # кто каким полем владеет (§3)
spec: {…}                    # желаемое — пишут люди и инструменты
status:                      # фактическое — пишет контроллер
  observedGeneration: 2      # до какого generation контроллер дошёл
```

`status.observedGeneration < metadata.generation` — контроллер ещё не обработал последнее изменение spec. Так `kubectl rollout status` понимает, что rollout не закончен.

### Labels и selectors 🟢

Labels — пары ключ-значение для **выборки**; на них держатся связи: Service → поды, Deployment → ReplicaSet → поды, NetworkPolicy, PDB, `topologySpreadConstraints`.

```bash
kubectl get pods -l app=orders-api                 # равенство
kubectl get pods -l 'app in (orders-api,web),tier!=db'
kubectl get pods -L app,pod-template-hash          # показать метки колонками
```

Рекомендуемые метки `app.kubernetes.io/name`, `instance`, `version`, `component`, `part-of`, `managed-by` — их понимают Helm, Argo CD, дашборды. Annotations для выборки не используются; их читают инструменты (`kubectl.kubernetes.io/last-applied-configuration`, `prometheus.io/scrape`, аннотации Gateway/Ingress-контроллеров).

### Группы и версии API 🟡

`/api/v1` — ядро (pods, services, configmaps), `/apis/<group>/<version>` — остальное. На стенде 24 группы (проверено, `kubectl get --raw /apis`): `apps/v1`, `batch/v1`, `autoscaling/v2`, `networking.k8s.io/v1`, `policy/v1`, `rbac…/v1`, `resource.k8s.io/v1`, `flowcontrol…/v1`, плюс CRD: `gateway.networking.k8s.io/v1`, `gateway.envoyproxy.io/v1alpha1`, `metrics.k8s.io/v1beta1`.

Политика устаревания: beta-API удаляются не раньше чем через 3 релиза после замены, стабильные (`v1`) не удаляются в рамках мажорной версии, но могут быть объявлены устаревшими. Устаревшее API работает, но сервер присылает предупреждение (проверено):

```
$ kubectl get cs
Warning: v1 ComponentStatus is deprecated in v1.19+
$ kubectl -n orders get endpoints
Warning: v1 Endpoints is deprecated in v1.33+; use discovery.k8s.io/v1 EndpointSlice
```

И считает обращения — до обновления кластера ищите, кто пользуется устаревшим (10-2):

```
apiserver_requested_deprecated_apis{group="",removed_release="",resource="componentstatuses",subresource="",version="v1"} 1
apiserver_requested_deprecated_apis{group="",removed_release="",resource="endpoints",subresource="",version="v1"} 1
```

Пустой `removed_release` — дата удаления не назначена.

## 2. create, replace, patch, apply 🟢🟡

| Команда | Что отправляет | Если объект есть | Если нет |
|---|---|---|---|
| `kubectl create -f` | POST | ошибка `AlreadyExists` | создаёт |
| `kubectl replace -f` | PUT всего объекта с `resourceVersion` | заменяет целиком; устарел — 409 | ошибка |
| `kubectl patch` | PATCH (strategic merge / JSON merge / JSON patch) | меняет указанные поля | ошибка |
| `kubectl apply -f` (client-side) | GET, расчёт трёхстороннего diff, PATCH | меняет то, что изменилось в файле | POST |
| `kubectl apply --server-side` | PATCH `application/apply-patch+yaml` | сервер сливает поля по владельцам | создаёт |

**Client-side apply** хранит прошлую версию файла в аннотации `kubectl.kubernetes.io/last-applied-configuration` и считает трёхсторонний diff: файл сейчас ↔ файл прошлого раза ↔ объект в кластере. Поле, которое есть в файле, kubectl считает своим и при каждом apply возвращает к значению из файла — даже если его поменял кто-то другой (кейс части).

**Server-side apply (SSA)** — расчёт на сервере. Каждое поле принадлежит **field manager'у** (`managedFields`). Apply одного менеджера не может молча изменить поле, которым владеет другой, — сервер вернёт конфликт.

## 3. Field managers и конфликты 🟡🔴

`kubectl get … --show-managed-fields -o yaml` показывает владельцев. После `kubectl apply` и масштабирования HPA (проверено):

```
{"manager":"kube-controller-manager","operation":"Update","subresource":"scale"}
{"manager":"kubectl-client-side-apply","operation":"Update","subresource":null}
{"manager":"kube-controller-manager","operation":"Update","subresource":"status"}
```

HPA меняет `replicas` через подресурс `scale` — kube-controller-manager. kubectl владеет полями из файла, включая `replicas`.

Конфликт SSA (проверено): `kubectl` применил манифест с `replicas: 3`, второй менеджер `hpa-like` — с `replicas: 4`:

```
error: Apply failed with 1 conflict: conflict with "kubectl": .spec.replicas
Please review the fields above--they currently have other managers. Here
are the ways you can resolve this warning:
* If you intend to manage all of these fields, please re-run the apply
  command with the `--force-conflicts` flag.
* If you do not intend to manage all of the fields, please edit your
  manifest to remove references to the fields that should keep their
  current managers.
```

`--force-conflicts` забирает поле себе. После этого (проверено):

```
{"manager":"kubectl","operation":"Apply","spec":["f:selector","f:template"]}
{"manager":"hpa-like","operation":"Apply","spec":["f:replicas","f:selector","f:template"]}
```

Что происходит, если убрать поле из своего манифеста (проверено, два случая):

| Кто ещё владеет полем | Убрали `replicas` из манифеста kubectl и сделали SSA | Результат |
|---|---|---|
| никто | поле удаляется из объекта → дефолт | `replicas=1` |
| `hpa-like` (после force) | kubectl отказывается от владения | `replicas=4` — остаётся значение второго владельца |

Правило для HPA, Argo CD, операторов: **не держите в манифесте поля, которыми управляет кто-то другой** — либо уберите их (SSA корректно передаст владение), либо настройте инструмент их игнорировать (`ignoreDifferences` в Argo CD, 08-1).

## 4. ownerReferences и каскадное удаление 🟡

Под Deployment'а принадлежит ReplicaSet'у, ReplicaSet — Deployment'у (проверено):

```
[{"apiVersion":"apps/v1","blockOwnerDeletion":true,"controller":true,"kind":"ReplicaSet","name":"api-756bbf9595","uid":"76e68e0d-…"}]
```

Garbage collector в controller-manager удаляет объекты, владелец которых исчез. Режимы удаления:

| `--cascade` | Что происходит | Когда нужно |
|---|---|---|
| `background` (дефолт) | владелец удаляется сразу, зависимые — GC в фоне | обычно |
| `foreground` | у владельца ставится `deletionTimestamp` и finalizer `foregroundDeletion`; он остаётся в API, пока не удалены все зависимые с `blockOwnerDeletion` | нужно дождаться, что всё ушло |
| `orphan` | владелец удалён, зависимые остаются, ownerReferences снимаются | пересоздать владельца без остановки подов (например, поменять неизменяемый selector) |

Проверено:

```
$ kubectl delete deploy api --cascade=orphan
deployment.apps "api" deleted from lab-01-3 namespace
replicaset.apps/api-756bbf9595   3     3     3     1s
pod/api-756bbf9595-d2dmn   1/1   Running   0     1s
…
rs ownerRefs=""                                      ← ReplicaSet стал «ничьим»
$ kubectl delete rs -l app=api --cascade=foreground --wait=false
finalizers=["foregroundDeletion"] deletionTimestamp=2026-10-14T09:02:00Z
api-756bbf9595-d2dmn   1/1   Terminating   0     3s     ← RS висит, пока поды завершаются
```

Сироту-ReplicaSet подхватит новый Deployment с тем же selector'ом — так меняют то, что в Deployment неизменяемо.

Ограничения: владелец и зависимый — в одном namespace (или владелец cluster-scoped). Ссылка на владельца из другого namespace — объект считается сиротой и удаляется GC.

## 5. Finalizers 🟡🔴

Finalizer — строка в `metadata.finalizers`, обещание «перед удалением этого объекта кто-то должен сделать работу». `kubectl delete` при наличии finalizer'ов **не удаляет** объект, а ставит `deletionTimestamp`; объект становится только для чтения в части spec (можно менять metadata, снимать finalizer'ы) и исчезает, когда список finalizer'ов опустеет.

Проверено:

```
$ kubectl delete cm guarded --wait=false
configmap "guarded" deleted from lab-01-3 namespace           ← сообщение врёт: он ещё есть
deletionTimestamp=2026-10-14T08:56:22Z finalizers=["example.com/cleanup"]
$ kubectl patch cm guarded --type=json -p '[{"op":"remove","path":"/metadata/finalizers"}]'
configmap/guarded patched
$ kubectl get cm guarded
Error from server (NotFound): configmaps "guarded" not found
```

Типовые finalizer'ы: `kubernetes.io/pvc-protection` (PVC не удалится, пока используется подом), `kubernetes.io/pv-protection`, `foregroundDeletion`, `kubernetes` у namespace (удалить всё содержимое), finalizer'ы операторов (удалить облачный балансировщик, бакет, БД).

Объект «висит в Terminating» — значит, тот, кто должен снять finalizer, не может или не работает: оператор удалён раньше своих объектов, webhook недоступен, облачный ресурс не удаляется. **Снимать finalizer руками — последнее средство**: вы обходите очистку, и внешний ресурс (диск, LB) останется висеть, оплачиваемый. Сначала найдите владельца finalizer'а (09-2).

## 6. Подресурсы: status, scale и другие 🟡

У многих типов есть подресурсы — отдельные эндпоинты с отдельными правами RBAC:

| Подресурс | Кто пишет | Зачем |
|---|---|---|
| `/status` | контроллеры, kubelet | чтобы пользователи с правом update на spec не могли подделать status, а контроллеры не трогали spec |
| `/scale` | HPA, `kubectl scale` | единый интерфейс масштабирования для Deployment, StatefulSet, ReplicaSet, CRD |
| `/log`, `/exec`, `/attach`, `/portforward` | kubectl | доступ к контейнеру; отдельные права (`pods/exec` = shell во всех подах namespace) |
| `/eviction` | `kubectl drain` | выселение с учётом PDB (05-4) |
| `/resize` | вы, VPA | изменение ресурсов работающего пода (05-1) |
| `/binding` | scheduler | назначение узла |

Попытка поменять status обычным patch игнорируется (проверено):

```
$ kubectl patch deploy api2 -p '{"status":{"replicas":99}}'
deployment.apps/api2 patched (no change)
after main patch status.replicas=4
$ kubectl get --raw /apis/apps/v1/namespaces/lab-01-3/deployments/api2/scale
{"kind":"Scale","spec":{"replicas":4},"status":{"replicas":4,"selector":"app=api2"}}
```

---

## 🔧 Лаба

### Шаг 0. Подготовка

```bash
kubectl config use-context kind-lab
kubectl create ns lab-01-3
kubectl config set-context --current --namespace=lab-01-3
mkdir -p /tmp/lab-01-3 && cd /tmp/lab-01-3
```

### Шаг 1. Client-side apply против масштабирования

```bash
cat > d1.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata: {name: api, namespace: lab-01-3}
spec:
  replicas: 3
  selector: {matchLabels: {app: api}}
  template:
    metadata: {labels: {app: api}}
    spec:
      containers: [{name: web, image: busybox:1.37, command: ["sleep","infinity"]}]
EOF
kubectl apply -f d1.yaml
kubectl scale deploy api --replicas=5
kubectl get deploy api -o jsonpath='after scale: {.spec.replicas}{"\n"}'
kubectl apply -f d1.yaml
kubectl get deploy api -o jsonpath='after re-apply: {.spec.replicas}{"\n"}'
kubectl get deploy api -o jsonpath='{.metadata.annotations.kubectl\.kubernetes\.io/last-applied-configuration}' | cut -c1-120; echo
```

Проверено:

```
deployment.apps/api created
after scale: 5
after re-apply: 3
{"apiVersion":"apps/v1","kind":"Deployment","metadata":{"annotations":{},"name":"api","namespace":"lab-01-3"},"spec":{"r
```

### Шаг 2. Server-side apply и конфликт владельцев

```bash
sed 's/name: api,/name: api2,/; s/app: api/app: api2/g' d1.yaml > d2.yaml
sed 's/replicas: 3/replicas: 4/' d2.yaml > d2b.yaml
kubectl apply --server-side -f d2.yaml
kubectl apply --server-side --field-manager=hpa-like -f d2b.yaml          # конфликт
kubectl apply --server-side --field-manager=hpa-like --force-conflicts -f d2b.yaml
kubectl get deploy api2 -o json --show-managed-fields | jq -c '.metadata.managedFields[] | {manager, operation, spec: (.fieldsV1."f:spec" // {} | keys)}'
grep -v replicas d2.yaml > d2c.yaml
kubectl apply --server-side -f d2c.yaml
kubectl get deploy api2 -o jsonpath='replicas={.spec.replicas}{"\n"}'
```

Проверено: конфликт `conflict with "kubectl": .spec.replicas` (текст в §3), после force — владельцы как в §3, `replicas=4`.

Повторите без шага с `hpa-like` (удалите `api2`, примените `d2.yaml`, затем `d2c.yaml`) — получите `replicas=1`: kubectl был единственным владельцем, поле удалено и стало дефолтным.

### Шаг 3. kubectl apply против HPA

```bash
cat > hpa.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata: {name: shop, namespace: lab-01-3}
spec:
  replicas: 1
  selector: {matchLabels: {app: shop}}
  template:
    metadata: {labels: {app: shop}}
    spec:
      containers:
      - {name: web, image: busybox:1.37, command: ["sleep","infinity"], resources: {requests: {cpu: 10m}}}
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata: {name: shop, namespace: lab-01-3}
spec:
  scaleTargetRef: {apiVersion: apps/v1, kind: Deployment, name: shop}
  minReplicas: 3
  maxReplicas: 5
  metrics: [{type: Resource, resource: {name: cpu, target: {type: Utilization, averageUtilization: 80}}}]
EOF
kubectl apply -f hpa.yaml
until [ "$(kubectl get deploy shop -o jsonpath='{.spec.replicas}')" = 3 ]; do sleep 2; done; echo "HPA set replicas=3"
kubectl get deploy shop --show-managed-fields -o json | jq -c '.metadata.managedFields[] | {manager, operation, subresource}'
t0=$(date +%s); kubectl apply -f hpa.yaml
for i in $(seq 1 25); do r=$(kubectl get deploy shop -o jsonpath='{.spec.replicas}/{.status.replicas}')
  echo "t=+$(( $(date +%s)-t0 ))s spec/status=$r"; [ "${r%/*}" = 3 ] && [ $i -gt 1 ] && break; sleep 2; done
kubectl get events --field-selector involvedObject.name=shop --sort-by=.lastTimestamp -o custom-columns=REASON:.reason,MSG:.message | tail -4
```

Проверено:

```
HPA set replicas=3
{"manager":"kube-controller-manager","operation":"Update","subresource":"scale"}
{"manager":"kubectl-client-side-apply","operation":"Update","subresource":null}
{"manager":"kube-controller-manager","operation":"Update","subresource":"status"}
deployment.apps/shop configured
horizontalpodautoscaler.autoscaling/shop unchanged
t=+1s spec/status=1/1
...
t=+12s spec/status=1/1
t=+14s spec/status=3/3
ScalingReplicaSet   Scaled down replica set shop-5bcf84c5cb from 3 to 1
SuccessfulRescale   New size: 3; reason: Current number of replicas below Spec.MinReplicas
ScalingReplicaSet   Scaled up replica set shop-5bcf84c5cb from 1 to 3
```

Обычный `kubectl apply` без единого изменения в файле убил два пода из трёх; 14 секунд сервис работал на одной реплике. HPA синхронизируется раз в 15 с (`--horizontal-pod-autoscaler-sync-period`).

Исправление — убрать `replicas` из манифеста Deployment и перейти на SSA:

```bash
sed -i '/replicas: 1/d' hpa.yaml
kubectl apply --server-side --force-conflicts -f hpa.yaml   # force — один раз, чтобы забрать поля у client-side apply
kubectl apply --server-side -f hpa.yaml
kubectl get deploy shop -o jsonpath='{.spec.replicas}{"\n"}'   # остаётся 3
kubectl get deploy shop --show-managed-fields -o json | jq -c '.metadata.managedFields[] | {manager, subresource, replicas: (.fieldsV1."f:spec"."f:replicas" != null)}'
```

Проверено:

```
3
{"manager":"kubectl-last-applied","subresource":null,"replicas":false}
{"manager":"kubectl","subresource":null,"replicas":false}
{"manager":"kube-controller-manager","subresource":"scale","replicas":true}
{"manager":"kube-controller-manager","subresource":"status","replicas":false}
```

Теперь `replicas` принадлежит только HPA (через `scale`); `kubectl-last-applied` — след миграции с client-side apply, он ничем не владеет.

### Шаг 4. Каскадное удаление

```bash
kubectl apply -f d1.yaml && kubectl rollout status deploy/api
kubectl get pods -l app=api -o jsonpath='{.items[0].metadata.ownerReferences[0].kind}/{.items[0].metadata.ownerReferences[0].name} blockOwnerDeletion={.items[0].metadata.ownerReferences[0].blockOwnerDeletion}{"\n"}'
kubectl delete deploy api --cascade=orphan
kubectl get deploy,rs,pods -l app=api
kubectl get rs -l app=api -o jsonpath='rs ownerRefs="{.items[0].metadata.ownerReferences}"{"\n"}'
kubectl delete rs -l app=api --cascade=foreground --wait=false
kubectl get rs -l app=api -o jsonpath='finalizers={.items[0].metadata.finalizers} deletionTimestamp={.items[0].metadata.deletionTimestamp}{"\n"}'
kubectl get pods -l app=api
```

Проверено: вывод в §4. ReplicaSet исчез после того, как завершились все поды (~30 с: `sleep` в роли PID 1 игнорирует SIGTERM, kubelet ждёт `terminationGracePeriodSeconds` и шлёт SIGKILL — 02-5).

### Шаг 5. Finalizer

```bash
kubectl create cm guarded --from-literal=a=1
kubectl patch cm guarded -p '{"metadata":{"finalizers":["example.com/cleanup"]}}'
kubectl delete cm guarded --wait=false
kubectl get cm guarded -o jsonpath='deletionTimestamp={.metadata.deletionTimestamp} finalizers={.metadata.finalizers}{"\n"}'
kubectl patch cm guarded --type=json -p '[{"op":"remove","path":"/metadata/finalizers"}]'
kubectl get cm guarded
```

Проверено: вывод в §5. Без `--wait=false` команда `delete` висела бы, пока не снимут finalizer.

### Шаг 6. Подресурсы и устаревшие API

```bash
kubectl patch deploy api2 -p '{"status":{"replicas":99}}'
kubectl get deploy api2 -o jsonpath='status.replicas={.status.replicas}{"\n"}'
kubectl get --raw /apis/apps/v1/namespaces/lab-01-3/deployments/api2/scale | jq -c '{kind, spec, status}'
kubectl get cs; kubectl -n orders get endpoints
kubectl get --raw /metrics | grep '^apiserver_requested_deprecated_apis'
```

### Уборка

```bash
cd ~ && rm -rf /tmp/lab-01-3
kubectl config set-context --current --namespace=default
kubectl delete ns lab-01-3
```

---

## 🔥 Кейс из прода: «`kubectl apply` затирает HPA — каждый деплой роняет сервис до одной реплики»

**Контекст.** orders-api под HPA (min 6, max 30). Деплой из CI — `kubectl apply -f k8s/` с манифестом, где осталось `replicas: 2` из времён до HPA. В часы пик после каждого деплоя — всплеск 5xx и задержек на 15–30 секунд, затем всё нормализуется. Команда грешила на «прогрев» приложения.

**Разбор.**
1. События Deployment во время деплоя: `Scaled down replica set … from 14 to 2`, через 15 с `SuccessfulRescale New size: 14` — HPA и kubectl перетягивают `replicas`.
2. `--show-managed-fields`: `replicas` в `kubectl-client-side-apply` (поле есть в файле) и в `kube-controller-manager` через `scale`. Client-side apply возвращает поле к значению из файла при каждом применении.
3. Воспроизведение — шаг 3 лабы: apply без изменений файла убивает поды, HPA через ≤15 с возвращает число реплик.

**Фикс.**
- Убрали `replicas` из манифеста Deployment (и из Helm-шаблона: `{{- if not .Values.autoscaling.enabled }}replicas: …{{- end }}` — стандартный приём чартов).
- Перевели деплой на `kubectl apply --server-side` (один раз с `--force-conflicts`, чтобы забрать поля у старого client-side менеджера).
- В CI добавили проверку: если для Deployment есть HPA, в манифесте не должно быть `spec.replicas`.

**Что запомнить.**
- Поле в манифесте = заявка на владение этим полем.
- HPA, VPA, операторы и GitOps — другие владельцы; их поля не держат в манифестах.
- `--show-managed-fields` отвечает на вопрос «кто поменял это поле».

---

## 💼 Вопросы с собеседования

### 🟢 Junior

**1. Чем labels отличаются от annotations?**
Labels — для выборки (селекторы Service, Deployment, `kubectl -l`), ограничены по формату и длине. Annotations — произвольные данные для инструментов и людей, по ним не выбирают.

**2. Чем `kubectl apply` отличается от `kubectl create`?**
`create` создаёт объект и падает, если он есть. `apply` декларативен: создаёт или обновляет так, чтобы объект соответствовал файлу; хранит прошлую версию (client-side) или владение полями (server-side) и умеет удалять поля, которые вы убрали из файла.

**3. Что такое namespace и какие объекты вне namespaces?**
Логическое разделение имён, квот, RBAC и политик. Cluster-scoped: Node, PersistentVolume, StorageClass, ClusterRole/Binding, Namespace, CRD, IngressClass/GatewayClass — `kubectl api-resources --namespaced=false`.

### 🟡 Middle

**4. Что такое finalizer и почему объект может висеть в Terminating?**
Строка в `metadata.finalizers` — обещание выполнить очистку до удаления. `delete` ставит `deletionTimestamp`, объект живёт, пока список finalizer'ов не опустеет. Висит — значит, контроллер, который должен снять finalizer, не работает или не может сделать очистку. Снимать вручную — последнее средство: внешние ресурсы останутся.

**5. Как работает каскадное удаление и что даёт `--cascade=orphan`?**
Зависимые объекты указывают владельца в `ownerReferences`; GC удаляет их, когда владелец исчез (background), или владелец ждёт их удаления (foreground). Orphan удаляет только владельца и снимает ссылки — поды продолжают работать; так пересоздают Deployment с изменённым неизменяемым полем без простоя.

**6. Почему после `kubectl apply` HPA «сбросился»?**
В манифесте есть `spec.replicas`; client-side apply возвращает его к значению из файла, HPA через ≤15 с масштабирует обратно — на это время реплик меньше. Убрать `replicas` из манифеста, использовать server-side apply.

### 🔴 Senior

**7. Как server-side apply решает конфликты и чем он лучше client-side?**
Владение каждым полем хранится в `managedFields` по менеджерам. Apply менеджера, который пытается изменить чужое поле, получает конфликт; `--force-conflicts` забирает владение. Если менеджер убрал поле из своего манифеста, а им владеет кто-то ещё — значение остаётся; если владельцев больше нет — поле удаляется. Нет аннотации last-applied (лимит 256 КБ на аннотации), расчёт на сервере одинаков для всех клиентов, видно, кто чем владеет.

**8. Зачем подресурсы `status` и `scale`?**
Разделение прав и ответственности: пользователь с update на spec не может подделать status, контроллер пишет только status. `scale` — общий интерфейс для HPA и `kubectl scale` к любому масштабируемому типу, включая CRD; права на `deployments/scale` можно дать без прав на весь Deployment.

**9. Как подготовиться к удалению API-версии при обновлении кластера?**
Метрика `apiserver_requested_deprecated_apis` и предупреждения в ответах (заголовок `Warning`) показывают, кто ходит в устаревшее; аудит-лог — какой клиент. Манифесты в Git и Helm-релизы проверяют `kubectl convert`/`pluto`/`kubent`; объекты в etcd apiserver переписывает в новую версию сам, ломаются клиенты и шаблоны (10-2).

---

## ⚠️ Подводные камни

- `kubectl delete … --wait=false` при finalizer'е печатает `deleted`, но объект живёт.
- Поле в манифесте = владение; client-side apply возвращает его при каждом применении.
- Переход с client-side на server-side apply: первый раз нужен `--force-conflicts`, иначе конфликты с `kubectl-client-side-apply`.
- Аннотация `last-applied-configuration` раздувает объекты; у больших ConfigMap/CRD она упирается в лимит 256 КБ на все аннотации — `apply` падает, SSA работает.
- `generation` не растёт при изменении `status` и `metadata`; `observedGeneration` < `generation` — изменение ещё не обработано.
- ownerReference на объект из другого namespace — объект будет удалён GC как сирота.
- Снятый вручную finalizer оператора оставляет облачные ресурсы, за которые платят.
- `kubectl get endpoints` и `componentstatuses` устарели — используйте EndpointSlice и `/readyz` компонентов.

---

## Чеклист

- [ ] Объясню поля metadata: uid, resourceVersion, generation, ownerReferences, finalizers, managedFields.
- [ ] Отличу create/replace/patch/apply и client-side от server-side apply.
- [ ] Найду, какой менеджер владеет полем, и воспроизведу конфликт SSA.
- [ ] Объясню, почему apply сбрасывает HPA, и исправлю манифест.
- [ ] Удалю владельца с orphan/foreground и объясню разницу.
- [ ] Разберу «объект висит в Terminating» через finalizers.
- [ ] Найду, кто пользуется устаревшими API.

---

## Задание со звёздочкой

Смоделируйте конфликт двух инструментов, управляющих одним объектом:

1. Примените ConfigMap `shared` через SSA с менеджером `team-a` (ключи `a`, `b`) и с менеджером `team-b` (ключ `c`).
2. Пусть `team-b` попробует изменить ключ `a` без force и с force. Посмотрите `managedFields` после каждого шага.
3. `team-a` применяет манифест без ключа `b`, а потом без ключа `a`. Что осталось в объекте и почему?
4. Опишите, как настроить Argo CD (08-1) и HPA так, чтобы они не воевали за `replicas`, — двумя способами.

---

→ Следующая часть: **02-1. Pod** — жизненный цикл и фазы, init-контейнеры и нативные sidecar'ы, restartPolicy и коды выхода, CrashLoopBackOff без логов, `terminationMessage`, ephemeral containers и downward API; модуль «Workloads».
