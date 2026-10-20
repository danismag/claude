# 01-3. API-объекты и kubectl под капотом

> Модуль 01 «Архитектура» · часть 3 из 3 · ~1,5 ч чтения + ~1 ч лабы · Нужно: стенд 00-1 (контекст `kind-lab`), kubectl и jq из 00-2, доступ узлов к образу `busybox:1.37` · Опирается на: 01-1 (API-сервер и etcd), 01-2 (узел и kubelet)

## Где мы на карте

В 01-1 мы разобрали, как запрос доходит до etcd, а в 01-2 — как kubelet превращает объект пода в процессы на узле. Эта часть закрывает модуль 01 и описывает сам объект: то, что API-сервер хранит, а контроллеры читают и правят. Здесь же объясняется, что делает `kubectl apply` и почему два инструмента могут «воевать» за одно поле.

Следующие модули пользуются этим устройством постоянно. Deployment и его ReplicaSet связаны ссылками на владельца (02-2), а HPA меняет число реплик через подресурс (05-4). Helm и Argo CD решают, кто владеет полем (07-1, 08-1), а операторы вешают на свои объекты finalizer (09-2).

```
   kubectl / Helm / Argo CD / контроллеры          клиенты
                    │  create, patch, apply, delete
                    ▼
   ┌────────────────────────────────────────────────────────┐
   │ API-сервер: группа/версия → тип → объект → подресурс   │  эта часть
   │   объект = metadata + spec + status                    │
   │   metadata: uid, ownerReferences, finalizers,          │
   │             managedFields                              │
   └───────────────────────────┬────────────────────────────┘
                               ▼
                         etcd (01-1)
```

Схема 1. Клиенты меняют объекты только через API-сервер. Эта часть описывает содержимое рамки: поля объекта и правила их изменения.

---

## 1. Какую задачу решает модель объектов

Kubernetes хранит всё в одном виде — как объекты с общей структурой. Благодаря этому один набор правил работает для подов, Service, Deployment и для типов, которые вы добавите сами. Разберём, что лежит в объекте и зачем его делят на части.

### Объект как запись о желаемом и фактическом

**Объект** (object) — запись в API, которая описывает, что должно быть в кластере и что там есть сейчас. Желаемое лежит в поле `spec` (specification), фактическое — в поле `status`. `spec` пишут люди и инструменты, а `status` — компонент, который обслуживает объект: контроллер или kubelet.

Контроллер (01-1) сравнивает два поля и сводит разницу к нулю. На этом построена вся система: вы не командуете «запусти три пода», а записываете «должно быть три».

### Зачем разделены spec и status

Разделение защищает от подмены: пользователь с правом менять `spec` не должен подделать `status`, а контроллер не должен переписывать `spec`. Для этого у типов есть **подресурсы** (subresources) — отдельные точки API у объекта, например `/status` и `/scale`. У каждого подресурса свои права в RBAC (06-1), подробно они разобраны в §2.

### Общая структура для любых типов

У всех объектов одни и те же служебные поля в `metadata`, поэтому kubectl, сборщику мусора и механизму владения полями не важно, какой тип перед ними. Они работают с `metadata`, а не с содержимым `spec`. Поэтому тот же `kubectl apply` работает с **CRD** (CustomResourceDefinition) — типом, который вы добавили в API сами (09-1).

---

## 2. Как устроен объект

Объект состоит из служебных полей `metadata`, желаемого `spec` и фактического `status`. Метаданные несут связи между объектами, метки, счётчики изменений и записи о владении полями.

### Поля metadata

Ниже сокращённый Deployment, а комментарии показывают, зачем нужно каждое поле.

```yaml
apiVersion: apps/v1          # группа/версия API: /apis/apps/v1
kind: Deployment
metadata:
  name: orders-api           # уникально в namespace и типе
  namespace: orders
  uid: 8b93054a-…            # уникален навсегда; новый объект с тем же именем получит другой
  resourceVersion: "3429"    # ревизия etcd (01-1)
  generation: 2              # счётчик изменений spec
  labels: {app: orders-api}  # для выборки
  annotations: {…}           # произвольные данные для инструментов
  ownerReferences: […]       # кто владелец объекта (§3)
  finalizers: […]            # что должно случиться до удаления (§3)
  managedFields: […]         # кто каким полем владеет (§3)
spec: {…}
status:
  observedGeneration: 2      # до какого generation дошёл контроллер
```

Фрагмент объекта. Поля `ownerReferences`, `finalizers` и `managedFields` добавляет не автор манифеста, а API-сервер и контроллеры.

Namespace (пространство имён, 01-1) — логическая область в кластере: имена объектов уникальны внутри неё, к ней привязываются квоты и права. **uid** — идентификатор, который сервер присваивает объекту при создании; если удалить объект и создать такой же, uid будет новым. Ссылки между объектами хранят uid, а не имя, поэтому новый объект с тем же именем владельцем старых зависимых не считается.

Имя можно не задавать самому. Поле **generateName** (генерация имени) — префикс, к которому сервер добавляет случайный суффикс, как у подов `api-756bbf9595-d2dmn`. С версии 1.32 сервер сам повторяет попытку, если сгенерированное имя уже занято.

### generation и observedGeneration

**generation** — счётчик, который растёт при каждом изменении `spec`, а изменения `status` и `metadata` его не увеличивают. **observedGeneration** — поле в `status`: номер generation, до которого контроллер уже дошёл. У Deployment и других контроллеров эта пара есть давно, а у пода она стала стабильной в 1.35 (02-1).

```
вы меняете spec:       generation  1 ──► 2
контроллер читает:     status.observedGeneration = 1   ← ещё не обработал
контроллер закончил:   status.observedGeneration = 2   ← догнал
```

Схема 2. Пока `observedGeneration` меньше `generation`, последнее изменение spec не обработано. Так `kubectl rollout status` понимает, что обновление не закончено.

### Labels, selectors и annotations

**Label** (метка) — пара «ключ=значение» на объекте, по которой объекты выбирают. **Selector** (селектор) — условие на метки. На селекторах держатся связи Service с подами, Deployment с ReplicaSet и подами, а также NetworkPolicy и PDB (05-5).

```bash
kubectl get pods -l app=orders-api                   # равенство
kubectl get pods -l 'app in (orders-api,web),tier!=db'  # множество и неравенство
kubectl get pods -L app,pod-template-hash            # показать метки колонками
```

Разбор:

1. `-l` фильтрует по селектору, `-L` только добавляет колонки с метками.
2. Условия через запятую объединяются по «И».
3. Тот же синтаксис принимают Service и Deployment в полях `selector`.

**Field selector** (селектор по полям) — условие не на метки, а на поля объекта, например `--field-selector status.phase=Running`. Встроенные типы поддерживают только часть полей, а у CRD с 1.32 их можно объявить в `selectableFields` (09-1).

**Annotation** (аннотация) — пара «ключ=значение» для произвольных данных. По аннотациям не выбирают, их читают инструменты: например, `prometheus.io/scrape` и `kubectl.kubernetes.io/last-applied-configuration`. Рекомендуемые метки `app.kubernetes.io/name`, `instance`, `version`, `component`, `part-of` и `managed-by` понимают Helm, Argo CD и дашборды, а без них инструменты не сгруппируют объекты.

### Группы и версии API

Тип объекта адресуется тройкой «группа / версия / ресурс». Ядро API живёт в `/api/v1` (pods, services, configmaps, namespaces), остальное — в `/apis/<группа>/<версия>`, например `/apis/apps/v1` и `/apis/batch/v1`. В поле `apiVersion` манифеста стоит `группа/версия`, а для ядра — просто `v1`.

Версии различаются по стабильности. Встроенные `v1alpha1` выключены по умолчанию и могут исчезнуть без предупреждения. Встроенные `v1beta1` почти готовы, но тоже выключены по умолчанию, кроме beta-API, появившихся до 1.22; `v1` — стабильная версия. Одну группу сервер может отдавать в нескольких версиях сразу и сам конвертирует объекты между ними.

### Подресурсы

Подресурс — отдельный адрес у объекта вида `/apis/apps/v1/namespaces/<ns>/deployments/<имя>/scale`. Основные подресурсы перечислены ниже.

- **`/status`** — пишут контроллеры и kubelet. Обычное обновление объекта игнорирует `status`.
- **`/scale`** — единый интерфейс масштабирования для Deployment, StatefulSet, ReplicaSet и CRD. Им пользуются HPA и `kubectl scale`.
- **`/log`, `/exec`, `/attach`, `/portforward`** — доступ к контейнеру. Право `pods/exec` равно оболочке в любом поде namespace.
- **`/eviction`** — выселение пода с учётом PDB, его вызывает `kubectl drain` (05-5).
- **`/resize`** — изменение ресурсов работающего пода (05-2).
- **`/binding`** — назначение пода на узел, его вызывает scheduler.

С версии 1.33 kubectl умеет обращаться к `status`, `scale` и `resize` напрямую ключом `--subresource`, например `kubectl get deploy api --subresource=scale`.

---

## 3. Как управлять объектами

Объект меняют пятью способами: создать, заменить, пропатчить, применить на клиенте и применить на сервере. На удаление влияют ещё два механизма — владелец объекта и finalizer, который удаление откладывает.

### create, replace, patch

Три простые команды соответствуют трём HTTP-запросам к API-серверу.

- **`kubectl create -f`** — запрос POST. Создаёт объект, а если он есть, возвращает `AlreadyExists`.
- **`kubectl replace -f`** — запрос PUT с `resourceVersion`. Заменяет объект целиком. Если объект успели изменить, сервер вернёт `409 Conflict` (01-1 §3).
- **`kubectl patch`** — запрос PATCH. Меняет только указанные поля; форматов три: strategic merge, JSON merge и JSON patch.

Эти команды императивны: вы сообщаете действие, а не итог. Чтобы хранить конфигурацию в Git и приводить кластер к файлу, нужен `apply`.

### Client-side apply

**Client-side apply** — режим `kubectl apply -f`, в котором изменения рассчитывает сам kubectl. Он хранит прошлую версию файла в аннотации `kubectl.kubernetes.io/last-applied-configuration` и считает трёхсторонний diff.

```
 файл сейчас ──────────┐
 файл прошлого раза ───┼──► diff ──► PATCH на сервер
 объект в кластере ────┘
```

Схема 3. Три источника client-side apply. Поле, которое было в прошлом файле и пропало в новом, kubectl удаляет, а поле из файла возвращает к значению из файла при каждом запуске.

Второе правило важно для §5: если другой компонент поменял такое поле, следующий `apply` затрёт его правку, даже когда сам файл не менялся.

### Server-side apply и владение полями

**Server-side apply** (SSA) — режим `kubectl apply --server-side`, в котором объекты сливает сервер. Запрос идёт методом PATCH с типом `application/apply-patch+yaml`, и аннотация last-applied для расчёта не нужна.

Сервер хранит, кто какое поле записал. **Field manager** — имя клиента, который меняет объект: `kubectl`, `kube-controller-manager` или любое имя из ключа `--field-manager`. **managedFields** — список в `metadata`, где на каждого менеджера и операцию (`Apply` или `Update`) есть запись с перечнем его полей.

```
metadata.managedFields
 ├─ manager: kubectl             op: Apply    владеет: spec.selector, spec.template, spec.replicas
 └─ manager: kube-controller-manager
                                 op: Update   подресурс scale: spec.replicas
```

Схема 4. Условный пример записей managedFields. Два менеджера претендуют на `spec.replicas`, и что сделает сервер, зависит от значений (ниже).

Правила простые. Если менеджер пишет другое значение в поле, которым владеет другой менеджер, сервер возвращает **конфликт** (conflict). Если значение совпало, поле становится общим, а ключ `--force-conflicts` забирает поле целиком. Если менеджер убрал поле из своего манифеста, возможны два исхода:

- у поля больше нет владельцев — сервер удаляет поле, значение становится дефолтным;
- у поля есть другой владелец — значение остаётся, менеджер лишь отказывается от владения.

Переход с client-side на server-side apply документация описывает отдельно. При менеджере `kubectl` владение полями переходит к SSA без конфликтов, потому что сервер берёт список полей из аннотации last-applied. Конфликт дадут только поля, которые меняли вне `apply`, например `replicas` после `kubectl scale`.

### Владельцы и каскадное удаление

**ownerReference** (ссылка на владельца) — запись в `metadata.ownerReferences`, которая по uid указывает объект-владелец. Под принадлежит ReplicaSet, а ReplicaSet — Deployment. **Garbage collector** (сборщик мусора) — часть kube-controller-manager, которая удаляет объекты, чей владелец исчез.

```
Deployment api ──owns──► ReplicaSet api-756bbf9595 ──owns──► Pod api-756bbf9595-d2dmn
        └───────────────────── каскад удаления идёт вниз ─────────────────────►
```

Схема 5. Цепочка владельцев. При удалении верхнего объекта сборщик мусора идёт вниз по ссылкам.

Режим каскада задаёт ключ `--cascade` у `kubectl delete`:

- **`background`** (по умолчанию) — владелец удаляется сразу, зависимых убирает сборщик мусора позже.
- **`foreground`** — владелец остаётся в API с `deletionTimestamp` и finalizer `foregroundDeletion`, пока не исчезнут зависимые с `blockOwnerDeletion: true`.
- **`orphan`** — владелец удаляется, у зависимых снимаются ссылки, и они остаются «ничьими».

Режим `orphan` нужен, когда владельца надо пересоздать без остановки подов. Сироту-ReplicaSet подхватит новый Deployment с тем же селектором, и так меняют поле, которое в Deployment неизменяемо.

### Finalizers

**Finalizer** — строка в `metadata.finalizers`, обещание, что перед удалением объекта кто-то выполнит очистку. Пока список непуст, API-сервер не удаляет объект: он ставит `deletionTimestamp`, отвечает кодом 202 и ждёт.

```
 delete ─► deletionTimestamp = T, finalizers = [A, B]
              │       объект виден, новый finalizer добавить нельзя
              ├─ владелец A закончил очистку → снимает A
              ├─ владелец B закончил очистку → снимает B
              ▼
        finalizers = []  ─► API-сервер удаляет объект из etcd
```

Схема 6. Объект исчезает, когда снят последний finalizer. После `deletionTimestamp` finalizer'ы можно только снимать, само время удаления не меняется, а отменить удаление нельзя. Свои finalizer'ы обязаны иметь имя с доменом, например `example.com/cleanup`, иначе сервер отклонит запись.

Ниже типовые finalizer'ы.

- **`kubernetes.io/pvc-protection`** — PersistentVolumeClaim не удалится, пока его использует под (04-2).
- **`kubernetes.io/pv-protection`** — то же для PersistentVolume.
- **`foregroundDeletion`** — ставится при foreground-каскаде.
- **у namespace** — finalizer `kubernetes` в `spec.finalizers`: сначала должно удалиться всё содержимое; с 1.34 поды удаляются раньше остальных объектов, например раньше NetworkPolicy.
- **у операторов** — свои, например «удалить облачный балансировщик, диск, базу» (09-2).

---

## 4. Как увидеть состояние объекта

У объекта видно три слоя: что в нём записано, кто его менял и какая версия API отвечает. Для каждого слоя есть своя команда.

### Владельцы полей

Ключ `--show-managed-fields` выводит `managedFields`, которые по умолчанию скрыты, и работает вместе с `-o yaml` или `-o json`. Фильтр `jq` сокращает вывод до менеджера, операции и подресурса.

```bash
kubectl get deploy shop --show-managed-fields -o json \
  | jq -c '.metadata.managedFields[] | {manager, operation, subresource}'
```

В выводе по строке на менеджера, а поле `subresource` отличает запись через `scale` или `status` от обычной. Так отвечают на вопрос «кто поменял это поле».

### Ссылки на владельца и удаление

Ссылку на владельца читают из `metadata.ownerReferences`. Состояние удаления видно по `metadata.deletionTimestamp` и `metadata.finalizers`: если время есть, а объект ещё жив, значит, он ждёт finalizer.

```bash
kubectl get pod <имя> -o jsonpath='{.metadata.ownerReferences}'
kubectl get cm <имя> -o jsonpath='{.metadata.deletionTimestamp} {.metadata.finalizers}'
```

Первая команда показывает владельца с полями `controller` и `blockOwnerDeletion`, вторая — время удаления и список ожидаемых очисток.

### Версии API и устаревшее

Группы, которые отдаёт сервер, видны через `kubectl get --raw /apis`, а список типов с группами, версиями и признаком namespace даёт `kubectl api-resources`. Поля объекта объясняет `kubectl explain`, например `kubectl explain deployment.spec.strategy`.

Устаревшее API работает, но к каждому ответу сервер добавляет заголовок `Warning`, и kubectl его печатает. Факт обращения сервер отмечает в метрике `apiserver_requested_deprecated_apis`. Её метка `removed_release` показывает релиз, в котором версию удалят, а пустое значение значит, что дата не назначена. Эту метрику смотрят перед обновлением кластера (10-3).

### Ревизии и события

`resourceVersion` меняется при каждой записи, а `generation` — только при изменении spec. Сравнение `generation` и `observedGeneration` показывает, дошёл ли контроллер до вашей правки. События объекта в `kubectl describe` показывают, что именно сделали контроллеры (01-1).

---

## 5. Что ломается и как найти причину

Большинство проблем с объектами сводится к четырём вопросам: кто владеет полем, кто владеет объектом, что задерживает удаление и в какой версии API вы работаете.

### apply возвращает поле, которым управляет другой

Симптом такой: после каждого деплоя число реплик падает до значения из манифеста, а через несколько секунд возвращается. Причина в том, что в файле осталось `replicas` и client-side apply считает поле своим, а HPA поддерживает другое число через `/scale`.

Диагноз по шагам:

1. События Deployment и HPA: `Scaled down … to N`, а в пределах 15 с — `SuccessfulRescale`.
2. `--show-managed-fields`: `replicas` числится сразу за `kubectl-client-side-apply` и за `kube-controller-manager` через `scale`.
3. Повторите `apply` без изменений файла: поды исчезают, а HPA возвращает число (лабораторная работа 1).

Лечение — убрать `replicas` из манифеста Deployment и перейти на SSA. В Helm-чартах для этого поле оборачивают в условие по `autoscaling.enabled` (07-1), а в Argo CD настраивают игнорирование поля (08-1).

### Конфликт при server-side apply

Сообщение `Apply failed with N conflict` называет менеджера и поле: другой менеджер уже владеет этим полем с другим значением. Выходов три: убрать поле из манифеста, привести значение к текущему или забрать поле ключом `--force-conflicts`. Забирайте поле, только если решили, что оно ваше, иначе начнётся война с HPA или оператором.

### Объект висит в Terminating

Объект с `deletionTimestamp` ждёт finalizer, потому что тот, кто обещал очистку, не работает. Обычные причины: оператор удалён раньше своих объектов, webhook недоступен, облачный ресурс не удаляется. Сначала узнайте по имени, чей это finalizer, и почините владельца (09-2).

Снять finalizer руками можно, но это последнее средство: очистка не выполнится, и внешний ресурс вроде диска или балансировщика останется оплачиваемым. Для namespace причины зависания читают в его `status.conditions`.

### Дочерние объекты исчезли или остались

Если зависимые объекты удалились вместе с владельцем неожиданно, это сделал сборщик мусора, а если остались — удаление шло с `--cascade=orphan`. Ссылка на владельца из другого namespace не работает: владелец в namespace должен лежать в том же namespace, что и зависимый. Такую ссылку сервер считает отсутствующей, и зависимый удаляется как сирота с событием `OwnerRefInvalidNamespace`.

### Правка status не сохраняется

Обычный `patch` с телом `{"status":…}` не меняет `status` у типов с подресурсом `/status`: сервер молча отбрасывает эти поля и отвечает `patched (no change)`. Чтобы изменить `status`, нужен запрос к подресурсу, и право на него отдельное. Но даже правку через подресурс контроллер скоро перепишет своим значением.

---

## 6. Пределы и значения по умолчанию

Ниже собраны числа и правила, которые встречались в части. По ним видно, где механизм упирается в предел.

### Метки и аннотации

- Ключ метки — имя до 63 символов и необязательный префикс-домен до 253 символов.
- Значение метки — до 63 символов, может быть пустым.
- Аннотации объекта — не больше 256 КиБ в сумме, ключи и значения вместе.

Аннотация `last-applied-configuration` входит в этот лимит, поэтому большие ConfigMap и CRD в него упираются. Client-side apply на таких объектах падает с ошибкой, а SSA работает, потому что хранит владение в `managedFields`.

### Устаревание API

По политике устаревания Kubernetes стабильную версию `v1` можно объявить устаревшей, но нельзя удалить внутри мажорной версии. Beta-версия перестаёт обслуживаться через 9 месяцев или 3 минорных релиза после объявления об устаревании, смотря что дольше. Alpha-версию могут убрать в любой момент без предупреждения.

### Скорость и таймеры

- HPA пересчитывает число реплик раз в 15 с (`--horizontal-pod-autoscaler-sync-period`, значение по умолчанию).
- Каскад foreground ждёт завершения подов, а остановка пода по умолчанию занимает до 30 с (`terminationGracePeriodSeconds`, 02-5).
- Предупреждение `Warning` приходит в каждом ответе, пока клиент обращается к устаревшей версии.

### Размер объекта

Объект записывается в etcd целиком вместе с `managedFields`, а предел запроса к etcd по умолчанию — 1,5 МиБ (01-1 §6, 10-2). Поэтому большие объекты CRD с длинными списками управляемых полей могут упереться в этот предел.

---

## Лабораторные работы

Работы идут на стенде 00-1 в namespace `lab-01-3`, а файлы лежат в `~/lab/k8s/01-3`. Хост не меняется: контекст `kind-lab` и `~/.kube/config` остаются прежними, а namespace работ задаёт функция `k`. Namespace `orders` работы читают, но не меняют. Образ `busybox:1.37` узлы тянут из Docker Hub; если он недоступен, положите его в реестр стенда по схеме из начала лабораторных работ 00-2 под именем `localhost:5001/lab-01-3/busybox:1.37`.

Подготовку выполните один раз перед первой работой.

```bash
kubectl config use-context kind-lab
kubectl create ns lab-01-3
k() { kubectl -n lab-01-3 "$@"; }
mkdir -p ~/lab/k8s/01-3 && cd ~/lab/k8s/01-3
```

Разбор:

1. `use-context kind-lab` выбирает кластер стенда.
2. `create ns lab-01-3` создаёт namespace для работ.
3. `k() { kubectl -n lab-01-3 "$@"; }` определяет **функцию shell** (shell function) `k`: она запускает `kubectl -n lab-01-3` и передаёт ей остальные аргументы.
4. `mkdir -p … && cd …` создаёт рабочий каталог и переходит в него.

Функция живёт только в этом терминале, поэтому в новом терминале определите её снова.

### Лабораторная работа 1. Client-side и server-side apply, конфликт владельцев

**Риски.** Работа меняет только кластер стенда.

- **Что меняется:** создаются Deployment `api`, `api2`, `shop` и HPA `shop` в `lab-01-3`; `~/.kube/config` не меняется.
- **Надолго ли:** до уборки; функцию `k` и namespace удаляет уборка работы 3.
- **Безопасность:** привилегий не нужно, образ `busybox:1.37`.
- **Влияние на систему:** до 12 подов `sleep` на стенде, нагрузка ничтожна; другие namespace не затрагиваются.
- **Откат:** уборка в конце работы.

**Цель.** Увидеть, как `apply` возвращает поле к значению из файла, как server-side apply делит поля между менеджерами и почему обычный `apply` ломает Deployment под HPA.

**Что понадобится.** Стенд 00-1, namespace `lab-01-3`, `jq`, metrics-server стенда (нужен HPA).

**Схема опыта.**

```
Шаг 1: apply (3) ─► scale (5) ─► apply (3)         файл побеждает
Шаг 2: SSA kubectl (3) ─► SSA hpa-like (4)  конфликт ─► --force-conflicts
Шаг 3: убрать replicas из манифеста                отказ от поля: 1 или остаётся 4
Шаг 4: apply Deployment shop + HPA (min 3)         apply без изменений роняет поды
Шаг 5: SSA без replicas                            поле у HPA, apply его не трогает
```

Схема 7. Два опыта о владении полем: между людьми и инструментами (шаги 1–3) и между kubectl и HPA (шаги 4–5).

#### Шаг 1. Client-side apply против масштабирования

Команда создаёт Deployment с тремя репликами, вручную масштабирует его до пяти и применяет тот же файл ещё раз.

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
k apply -f d1.yaml
k scale deploy api --replicas=5
k get deploy api -o jsonpath='after scale: {.spec.replicas}{"\n"}'
k apply -f d1.yaml
k get deploy api -o jsonpath='after re-apply: {.spec.replicas}{"\n"}'
k get deploy api \
  -o jsonpath='{.metadata.annotations.kubectl\.kubernetes\.io/last-applied-configuration}' \
  | cut -c1-120 | fold -w 60; echo
```

| Часть команды | Значение |
|---|---|
| `apply -f d1.yaml` | создать объект и записать last-applied |
| `scale --replicas=5` | изменить число реплик через подресурс scale |
| `jsonpath='after scale: …'` | вывести `spec.replicas` с подписью |
| `\.` в jsonpath | экранирование точек в имени аннотации |
| `cut -c1-120` | показать первые 120 знаков аннотации |
| `fold -w 60` | перенести вывод по 60 знаков в строке |

Результат:

```
deployment.apps/api created
after scale: 5
after re-apply: 3
{"apiVersion":"apps/v1","kind":"Deployment","metadata":{"ann
otations":{},"name":"api","namespace":"lab-01-3"},"spec":{"r
```

Разбор:

1. `after scale: 5` — масштабирование вручную сработало.
2. `after re-apply: 3` — второй `apply` вернул поле к значению из файла, хотя файл не менялся.
3. Две последние строки — начало аннотации last-applied, копии файла, по которой kubectl считает diff. Поле `replicas` (`"spec":{"r…`) в ней есть, поэтому kubectl считает его своим.

#### Шаг 2. Server-side apply и конфликт владельцев

Команды создают Deployment `api2` через SSA от менеджера `kubectl`, а затем второй менеджер `hpa-like` пытается записать другое число реплик без force.

```bash
sed 's/name: api,/name: api2,/; s/app: api/app: api2/g' d1.yaml > d2.yaml
sed 's/replicas: 3/replicas: 4/' d2.yaml > d2b.yaml
k apply --server-side -f d2.yaml
k apply --server-side --field-manager=hpa-like -f d2b.yaml
```

| Часть команды | Значение |
|---|---|
| `sed … > d2.yaml` | копия манифеста с именем и меткой `api2` |
| `sed … > d2b.yaml` | та же копия с `replicas: 4` |
| `apply --server-side` | расчёт на сервере, менеджер `kubectl` |
| `--field-manager=hpa-like` | выступить как второй менеджер |

Результат второй команды:

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

Разбор:

1. `conflict with "kubectl": .spec.replicas` — поле принадлежит менеджеру `kubectl`, а `hpa-like` пытается записать другое значение.
2. Дальше сервер перечисляет выходы: забрать поле ключом `--force-conflicts` или убрать его из манифеста; первый вариант проверим сейчас.
3. Первая команда создала `api2` без ошибки и напечатала `deployment.apps/api2 serverside-applied`, в блоке эта строка опущена.

Теперь второй менеджер забирает поле силой, а мы смотрим, как изменились владельцы.

```bash
k apply --server-side --field-manager=hpa-like --force-conflicts -f d2b.yaml
k get deploy api2 -o json --show-managed-fields \
  | jq -c '.metadata.managedFields[]
      | {manager, operation, spec: (.fieldsV1."f:spec" // {} | keys)}'
```

| Часть команды | Значение |
|---|---|
| `--force-conflicts` | забрать спорные поля себе |
| `--show-managed-fields` | не скрывать `managedFields` |
| `.fieldsV1."f:spec" // {}` | поля spec менеджера, пусто если их нет |
| `keys` | вывести только имена полей |

Результат (вывод сокращён до значимых строк):

```
{"manager":"kubectl","operation":"Apply","spec":["f:selector","f:template"]}
{"manager":"hpa-like","operation":"Apply","spec":["f:replicas","f:selector","f:template"]}
```

Разбор:

1. `kubectl` потерял `f:replicas`: у него остались селектор и шаблон.
2. `hpa-like` владеет `f:replicas`, а ещё селектором и шаблоном: их значения совпали со значениями `kubectl`, и эти поля стали общими.
3. Значение `replicas` теперь 4.

#### Шаг 3. Что остаётся, если убрать поле из манифеста

Убираем `replicas` из манифеста менеджера `kubectl` и применяем его снова. У поля есть другой владелец, поэтому значение должно остаться.

```bash
grep -v replicas d2.yaml > d2c.yaml
k apply --server-side -f d2c.yaml
k get deploy api2 -o jsonpath='replicas={.spec.replicas}{"\n"}'
```

| Часть команды | Значение |
|---|---|
| `grep -v replicas` | вырезать строку с `replicas` |
| `apply --server-side -f d2c.yaml` | применить манифест без поля от менеджера `kubectl` |

Результат:

```
replicas=4
```

Разбор: значение осталось 4, потому что им владеет `hpa-like`, а `kubectl` лишь отказался от своей доли.

Повторите опыт без второго менеджера: удалите `api2`, примените `d2.yaml`, затем `d2c.yaml`. Тогда у поля один владелец, и после отказа от него сервер удалит поле, поэтому получится `replicas=1` — значение по умолчанию у Deployment.

#### Шаг 4. kubectl apply против HPA

Команды создают Deployment `shop` и HPA с минимумом 3 реплики, ждут, пока HPA поднимет число реплик, и применяют тот же файл ещё раз.

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
      - name: web
        image: busybox:1.37
        command: ["sleep","infinity"]
        resources: {requests: {cpu: 10m}}
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata: {name: shop, namespace: lab-01-3}
spec:
  scaleTargetRef: {apiVersion: apps/v1, kind: Deployment, name: shop}
  minReplicas: 3
  maxReplicas: 5
  metrics:
  - type: Resource
    resource: {name: cpu, target: {type: Utilization, averageUtilization: 80}}
EOF
k apply -f hpa.yaml
until [ "$(k get deploy shop -o jsonpath='{.spec.replicas}')" = 3 ]; do sleep 2; done
echo "HPA set replicas=3"
k get deploy shop --show-managed-fields -o json \
  | jq -c '.metadata.managedFields[] | {manager, operation, subresource}'
```

| Часть команды | Значение |
|---|---|
| `replicas: 1` | значение в файле, которое будет спорить с HPA |
| `minReplicas: 3` | HPA поднимет число реплик минимум до трёх |
| `until … do sleep 2; done` | ждать, пока HPA поменяет `spec.replicas` |
| `subresource` | каким адресом записан менеджер: `scale`, `status` или обычным |

Результат:

```
HPA set replicas=3
{"manager":"kube-controller-manager","operation":"Update","subresource":"scale"}
{"manager":"kubectl-client-side-apply","operation":"Update","subresource":null}
{"manager":"kube-controller-manager","operation":"Update","subresource":"status"}
```

Разбор:

1. HPA поднял `replicas` до 3 сам, через подресурс `scale`.
2. `kubectl-client-side-apply` — запись от вашего `apply`, и в ней есть `replicas`, потому что поле присутствует в файле.
3. Запись `status` — обновления состояния Deployment.

Теперь применяем тот же файл без единой правки и следим за числом реплик.

```bash
t0=$(date +%s); k apply -f hpa.yaml
for i in $(seq 1 25); do
  r=$(k get deploy shop -o jsonpath='{.spec.replicas}/{.status.replicas}')
  echo "t=+$(( $(date +%s)-t0 ))s spec/status=$r"
  [ "${r%/*}" = 3 ] && [ $i -gt 1 ] && break
  sleep 2
done
k get events --field-selector involvedObject.name=shop \
  --sort-by=.lastTimestamp -o custom-columns=REASON:.reason,MSG:.message | tail -4
```

| Часть команды | Значение |
|---|---|
| `t0=$(date +%s)` | запомнить время начала в секундах |
| `${r%/*}` | часть до `/`: желаемое число реплик |
| `[ … ] && break` | остановиться, когда желаемое снова равно 3 |
| `--field-selector involvedObject.name=shop` | события только про `shop` |
| `custom-columns=REASON:…,MSG:…` | две колонки: причина и сообщение |

Результат:

```
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

Разбор:

1. `shop configured` — `apply` изменил Deployment, хотя файл не менялся: он вернул `replicas: 1`.
2. `1/1` почти 14 секунд — поды ушли, остался один.
3. `3/3` на `t=+14s` — HPA вернул число реплик на ближайшем цикле, а цикл у него раз в 15 с.
4. События показывают тот же цикл: scale down до 1, `SuccessfulRescale` до 3, scale up.

Обычный `apply` без правок файла убил два пода из трёх, и 14 секунд сервис работал на одной реплике.

#### Шаг 5. Исправление: убрать replicas и перейти на SSA

Команды убирают `replicas` из манифеста Deployment и переводят управление на server-side apply.

```bash
sed -i '/replicas: 1/d' hpa.yaml
k apply --server-side --force-conflicts -f hpa.yaml
k apply --server-side -f hpa.yaml
k get deploy shop -o jsonpath='{.spec.replicas}{"\n"}'
k get deploy shop --show-managed-fields -o json \
  | jq -c '.metadata.managedFields[]
      | {manager, subresource, replicas: (.fieldsV1."f:spec"."f:replicas" != null)}'
```

| Часть команды | Значение |
|---|---|
| `sed -i '/replicas: 1/d'` | удалить строку `replicas: 1` из файла |
| `--force-conflicts` | один раз забрать поля у client-side менеджера |
| второй `apply --server-side` | обычное повторное применение для проверки |
| `replicas: (… != null)` | есть ли у менеджера поле `replicas` |

Результат (строки `serverside-applied` от первых двух команд опущены):

```
3
{"manager":"kubectl-last-applied","subresource":null,"replicas":false}
{"manager":"kubectl","subresource":null,"replicas":false}
{"manager":"kube-controller-manager","subresource":"scale","replicas":true}
{"manager":"kube-controller-manager","subresource":"status","replicas":false}
```

Разбор:

1. `3` — число реплик осталось тем, что поставил HPA, и повторный `apply` его не тронул.
2. `replicas: true` только у `kube-controller-manager` через `scale`: поле принадлежит HPA.
3. У `kubectl` поля `replicas` нет — вы его больше не заявляете.
4. `kubectl-last-applied` — след перехода с client-side apply, который ничем не владеет.

**Итог.**

| Что узнали | Где видно |
|---|---|
| Client-side apply возвращает поле из файла | шаг 1, `after re-apply: 3` |
| Конфликт SSA называет менеджера и поле | шаг 2 |
| Отказ от поля удаляет его или оставляет чужое значение | шаг 3, `1` и `4` |
| Поле в манифесте мешает HPA | шаг 4, `t=+14s` |
| Без поля в манифесте SSA и HPA не спорят | шаг 5 |

**Уборка.**

```bash
k delete deploy api api2 shop
k delete hpa shop
rm -f d1.yaml d2.yaml d2b.yaml d2c.yaml hpa.yaml
```

Первая команда удаляет Deployment сразу, а их поды завершаются в фоне около 30 с: `sleep` не обрабатывает SIGTERM. Вторая команда удаляет HPA, третья чистит файлы в рабочем каталоге.

**Вопросы для самопроверки.**

1. Почему второй `apply` на шаге 1 вернул `replicas` к 3?
2. Что значит `Apply failed with 1 conflict` и как его решить без force?
3. Почему `kubectl-last-applied` остался в managedFields, но владеет пустым набором?
4. Как в Helm-чарте сделать `replicas` безопасным для HPA?

<details>
<summary>Ответы</summary>

1. Поле было в файле и в last-applied, значит, kubectl считал его своим и привёл к файлу. Правку через `scale` он не учитывает.
2. Другой менеджер владеет полем с другим значением. Без force поле убирают из манифеста либо приводят значение к текущему.
3. Запись осталась от перехода с client-side apply. После SSA без `replicas` все поля либо перешли к менеджеру `kubectl`, либо принадлежат HPA, поэтому запись пуста.
4. Обернуть поле в условие: если включён autoscaling, строку `replicas` не рендерить (07-1).

</details>

### Лабораторная работа 2. Каскадное удаление

**Цель.** Проследить цепочку владельцев Deployment, ReplicaSet и Pod и сравнить режимы `orphan` и `foreground`.

**Что понадобится.** Стенд 00-1, namespace `lab-01-3`, образ `busybox:1.37`; манифест `d1.yaml` шаг 1 создаёт заново.

**Схема опыта.**

```
Deployment api ─► ReplicaSet ─► 3 пода
  шаг 2: delete --cascade=orphan      Deployment исчез, RS и поды живы, ссылки сняты
  шаг 3: delete rs --cascade=foreground
         RS остаётся с deletionTimestamp и finalizer, пока завершаются поды
```

Схема 8. Режим orphan рвёт связь владельца с зависимыми, а режим foreground задерживает владельца, пока не уйдут зависимые.

#### Шаг 1. Прочитать цепочку владельцев

Команда создаёт Deployment и показывает владельца пода.

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
k apply -f d1.yaml && k rollout status deploy/api
k get pods -l app=api -o jsonpath='{.items[0].metadata.ownerReferences}' | jq .
```

| Часть команды | Значение |
|---|---|
| `rollout status` | дождаться готовности Deployment |
| `items[0].metadata.ownerReferences` | ссылки на владельца первого пода |
| `jq .` | разложить JSON по строкам |

Результат (хвост с uid сокращён):

```
[
  {
    "apiVersion": "apps/v1",
    "blockOwnerDeletion": true,
    "controller": true,
    "kind": "ReplicaSet",
    "name": "api-756bbf9595",
    "uid": "76e68e0d-…"
  }
]
```

Разбор:

1. `kind: ReplicaSet`, `name: api-756bbf9595` — владелец пода.
2. `controller: true` — этот ReplicaSet управляет подом.
3. `blockOwnerDeletion: true` — при foreground-удалении владелец будет ждать этот под.
4. Владелец самого ReplicaSet — Deployment `api`, это видно такой же командой для `rs`.

#### Шаг 2. Удалить владельца с orphan

Удаляем Deployment, но оставляем зависимые объекты.

```bash
k delete deploy api --cascade=orphan
k get deploy,rs,pods -l app=api
k get rs -l app=api -o jsonpath='rs ownerRefs="{.items[0].metadata.ownerReferences}"{"\n"}'
```

| Часть команды | Значение |
|---|---|
| `--cascade=orphan` | удалить только владельца, оставить зависимых |
| `get deploy,rs,pods -l app=api` | показать три типа объектов по метке |
| `ownerReferences` | список ссылок на владельца у ReplicaSet |

Результат (вывод сокращён до значимых строк):

```
deployment.apps "api" deleted from lab-01-3 namespace
replicaset.apps/api-756bbf9595   3     3     3     1s
pod/api-756bbf9595-d2dmn   1/1   Running   0     1s
…
rs ownerRefs=""
```

Разбор:

1. Deployment удалён, а ReplicaSet с тремя готовыми подами остался.
2. Поды работают: удаление владельца их не затронуло.
3. `ownerRefs=""` — у ReplicaSet нет владельца, он стал «ничьим», и новый Deployment с тем же селектором может его подхватить.

#### Шаг 3. Удалить с foreground

Теперь удаляем сироту-ReplicaSet в режиме foreground и сразу смотрим на него.

```bash
k delete rs -l app=api --cascade=foreground --wait=false
j='finalizers={.items[0].metadata.finalizers}'
j+=' deletionTimestamp={.items[0].metadata.deletionTimestamp}{"\n"}'
k get rs -l app=api -o jsonpath="$j"
k get pods -l app=api
```

| Часть команды | Значение |
|---|---|
| `--cascade=foreground` | владелец остаётся, пока не удалены зависимые |
| `--wait=false` | не ждать завершения, вернуть управление сразу |
| `j=…`, `j+=…` | собрать длинный шаблон jsonpath в переменной |
| `metadata.finalizers` | список finalizer'ов у ReplicaSet |
| `metadata.deletionTimestamp` | время, когда запрошено удаление |

Результат:

```
finalizers=["foregroundDeletion"] deletionTimestamp=2026-10-14T09:02:00Z
api-756bbf9595-d2dmn   1/1   Terminating   0     3s
```

Разбор:

1. `foregroundDeletion` — finalizer, поставленный API-сервером на время каскада.
2. `deletionTimestamp` есть, а ReplicaSet ещё в API: он ждёт зависимых.
3. Под в `Terminating`, и отсюда виден порядок: сначала уходят поды, потом владелец.

Конец каскада проверим через 40 секунд. Поды уходят около 30 с: `sleep` в роли PID 1 игнорирует SIGTERM, и kubelet ждёт `terminationGracePeriodSeconds` (30 с) до SIGKILL (02-5).

```bash
sleep 40; k get rs,pods -l app=api
```

Результат (ожидаемый):

```
No resources found in lab-01-3 namespace.
```

**Итог.**

| Что узнали | Где видно |
|---|---|
| Под принадлежит ReplicaSet, связь по uid | шаг 1, `ownerReferences` |
| Orphan оставляет зависимые объекты без владельца | шаг 2, `ownerRefs=""` |
| Foreground держит владельца до ухода зависимых | шаг 3, finalizer и `Terminating` |

**Уборка.**

```bash
k delete deploy,rs -l app=api --ignore-not-found
rm -f d1.yaml
```

Первая команда удаляет остатки Deployment и ReplicaSet, если какой-то шаг не дошёл до конца, а вторая — файл манифеста.

**Вопросы для самопроверки.**

1. Что произойдёт с подами при обычном `kubectl delete deploy` и почему?
2. Чем foreground отличается от background по состоянию владельца?
3. Зачем нужен `--cascade=orphan` при смене неизменяемого поля Deployment?

<details>
<summary>Ответы</summary>

1. Сработает режим по умолчанию — background: Deployment исчезает сразу, а сборщик мусора находит ReplicaSet и поды без владельца и удаляет их.
2. При foreground владелец остаётся в API с `deletionTimestamp` и finalizer `foregroundDeletion`, пока не удалены зависимые с `blockOwnerDeletion`, а при background исчезает сразу.
3. Селектор Deployment нельзя изменить на месте. Deployment удаляют с orphan и создают заново, а новый объект принимает работающие ReplicaSet и поды без простоя.

</details>

### Лабораторная работа 3. Finalizer, подресурсы и устаревшие API

**Цель.** Повесить объект на finalizer и снять его, убедиться, что `status` не меняется обычным patch, и найти обращения к устаревшим API.

**Что понадобится.** Стенд 00-1, namespace `lab-01-3`, `jq`, доступ на чтение к namespace `orders`.

**Схема опыта.**

```
Шаг 1: ConfigMap с finalizer ─ delete ─► deletionTimestamp, объект жив ─ снять ─► исчез
Шаг 2: patch {"status":…} игнорируется; /scale отвечает на запрос с другим адресом
Шаг 3: get cs, get endpoints ─► Warning ─► метрика apiserver_requested_deprecated_apis
```

Схема 9. Три отдельных опыта с общей мыслью: у объекта есть служебные слои, которые обычная команда не видит.

#### Шаг 1. Finalizer и удаление

Команды создают ConfigMap, вешают на него finalizer и удаляют объект, не дожидаясь конца удаления.

```bash
k create cm guarded --from-literal=a=1
k patch cm guarded -p '{"metadata":{"finalizers":["example.com/cleanup"]}}'
k delete cm guarded --wait=false
j='deletionTimestamp={.metadata.deletionTimestamp}'
j+=' finalizers={.metadata.finalizers}{"\n"}'
k get cm guarded -o jsonpath="$j"
```

| Часть команды | Значение |
|---|---|
| `create cm guarded` | создать ConfigMap с ключом `a` |
| `patch … finalizers` | записать finalizer, у которого нет владельца |
| `delete --wait=false` | не ждать: иначе команда зависнет |
| `jsonpath="$j"` | показать время удаления и список finalizer'ов |

Результат:

```
configmap "guarded" deleted from lab-01-3 namespace
deletionTimestamp=2026-10-14T08:56:22Z finalizers=["example.com/cleanup"]
```

Разбор:

1. Сообщение `deleted` неточное: объект ещё в API, а команда лишь добилась установки `deletionTimestamp`.
2. Список finalizer'ов не пуст, поэтому объект ждёт очистки, которую никто не сделает: у `example.com/cleanup` нет контроллера.

Снимаем finalizer вручную, как делают, когда владелец finalizer'а недоступен, а внешних ресурсов за объектом нет.

```bash
k patch cm guarded --type=json -p '[{"op":"remove","path":"/metadata/finalizers"}]'
k get cm guarded
```

| Часть команды | Значение |
|---|---|
| `--type=json` | JSON patch: список операций над путями |
| `"op":"remove"` | удалить указанное поле |
| `"path":"/metadata/finalizers"` | поле со всем списком finalizer'ов |

Результат:

```
configmap/guarded patched
Error from server (NotFound): configmaps "guarded" not found
```

Разбор: когда список опустел, API-сервер сразу удалил объект. Без `--wait=false` команда `delete` висела бы, пока кто-то не снимет finalizer.

#### Шаг 2. Подресурсы status и scale

Команды создают Deployment с четырьмя репликами, пытаются изменить его `status` обычным patch и читают подресурс `scale`.

```bash
k create deployment api2 --image=busybox:1.37 --replicas=4 -- sleep infinity
k rollout status deploy/api2
k patch deploy api2 -p '{"status":{"replicas":99}}'
k get deploy api2 -o jsonpath='status.replicas={.status.replicas}{"\n"}'
kubectl get --raw /apis/apps/v1/namespaces/lab-01-3/deployments/api2/scale \
  | jq -c '{kind, spec, status}'
```

| Часть команды | Значение |
|---|---|
| `create deployment api2 --replicas=4` | Deployment из четырёх подов `sleep` |
| `patch … '{"status":…}'` | попытка записать status как обычное поле |
| `get --raw …/scale` | прямой запрос к подресурсу scale |
| `jq -c '{kind, spec, status}'` | компактный вывод трёх ключей |

Результат (строки `create` и `rollout status` опущены):

```
deployment.apps/api2 patched (no change)
status.replicas=4
{"kind":"Scale","spec":{"replicas":4},"status":{"replicas":4,"selector":"app=api2"}}
```

Разбор:

1. `patched (no change)` — сервер принял запрос и отбросил `status`: у Deployment есть подресурс `/status`, а обычная запись его не меняет.
2. `status.replicas=4`, а не 99: фактическое число по-прежнему пишет контроллер.
3. Ответ `/scale` — маленький объект `Scale` с желаемым и фактическим числом реплик. Через него HPA масштабирует любой тип, не зная его устройства; тот же объект покажет `kubectl get deploy api2 --subresource=scale -o json`.

#### Шаг 3. Устаревшие API

Команды считают группы API, обращаются к двум устаревшим API и затем читают метрику, которая отметила эти обращения.

```bash
kubectl get --raw /apis | jq '.groups | length'
kubectl get cs
kubectl -n orders get endpoints
kubectl get --raw /metrics | grep '^apiserver_requested_deprecated_apis' \
  | sed 's/^apiserver_requested_deprecated_apis//'
```

| Часть команды | Значение |
|---|---|
| `get --raw /apis` | список групп API, которые отдаёт сервер |
| `jq '.groups \| length'` | число групп |
| `get cs` | ComponentStatus, устаревший с 1.19 |
| `-n orders get endpoints` | Endpoints, устаревшие с 1.33 |
| `grep '^apiserver_…'` | оставить строки нужной метрики |
| `sed 's/^…//'` | убрать имя метрики, чтобы строка стала короче |

Результат (сами объекты `cs` и `endpoints` опущены):

```
24
Warning: v1 ComponentStatus is deprecated in v1.19+
Warning: v1 Endpoints is deprecated in v1.33+; use discovery.k8s.io/v1 EndpointSlice
{group="",removed_release="",resource="componentstatuses",subresource="",version="v1"} 1
{group="",removed_release="",resource="endpoints",subresource="",version="v1"} 1
```

Разбор:

1. `24` — столько групп на стенде вместе с CRD Gateway API и metrics-server, у вас число может отличаться.
2. Строки `Warning` приходят в ответе сервера, kubectl только печатает их.
3. Метрика — это gauge: значение 1 значит, что к `componentstatuses` и `endpoints` обращались с запуска API-сервера, а не число обращений. Пустой `removed_release` значит, что дата удаления не назначена.
4. Для EndpointSlice вместо Endpoints смотрите 03-2.

**Итог.**

| Что узнали | Где видно |
|---|---|
| Finalizer откладывает удаление | шаг 1, `deletionTimestamp` |
| Снятие последнего finalizer удаляет объект | шаг 1, `NotFound` |
| Обычный patch не меняет status | шаг 2, `no change` |
| Scale — отдельный адрес для масштабирования | шаг 2, объект `Scale` |
| Сервер предупреждает об устаревших API и считает их | шаг 3, `Warning` и метрика |

**Уборка.** Удаляем Deployment, файлы и namespace, а затем функцию `k`.

```bash
k delete deploy api2 --ignore-not-found
cd ~ && rmdir ~/lab/k8s/01-3
kubectl delete ns lab-01-3
kubectl get ns lab-01-3
unset -f k
```

Первая команда удаляет Deployment, а вторая — рабочий каталог; `rmdir` откажется удалять каталог, если в нём остались файлы. Третья удаляет `lab-01-3`. Удаление namespace ждёт завершения подов, поэтому может занять около 30 с, как в работе 2. Четвёртая команда должна ответить `NotFound`, а пятая удаляет функцию `k`.

**Вопросы для самопроверки.**

1. Почему `kubectl delete` написал `deleted`, а ConfigMap остался?
2. Что произойдёт с облачным диском, если снять finalizer оператора руками?
3. Зачем у Deployment отдельный подресурс `/status`?
4. Как узнать, кто в кластере ещё пользуется устаревшим API?

<details>
<summary>Ответы</summary>

1. Команда выполнила своё действие — поставила `deletionTimestamp`, а физически объект удаляется, когда список finalizer'ов опустеет.
2. Очистка не выполнится, и диск останется: он продолжит расходовать деньги, хотя объекта в кластере уже нет.
3. Чтобы разделить права: пользователь не подделает status, а контроллер пишет только его и не трогает spec.
4. Метрика `apiserver_requested_deprecated_apis` показывает, какие версии вызывали, а какой именно клиент — видно в аудит-логе (06-4).

</details>

---

## → Дальше

Модуль 02 сразу опирается на устройство объекта: Deployment создаёт ReplicaSet и ставит ссылки на владельца, а ReplicaSet создаёт поды. Начинать нужно с самого младшего объекта цепочки, поэтому следующая часть, 02-1, разбирает под — единицу, которую все контроллеры создают и удаляют. Deployment, ReplicaSet и обновления идут после неё, в 02-2.
