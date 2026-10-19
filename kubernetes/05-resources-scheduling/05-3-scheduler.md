# 05-3. Планировщик

> Модуль 05 «Ресурсы и планирование» · часть 3 из 5 · ~1,5 ч чтения + ~1 ч лабы · Нужно: стенд 00-1 (контекст `kind-lab`, три worker), образ `registry.k8s.io/pause:3.10` · Опирается на: 01-1 (scheduler), 01-2 (taint'ы узла), 05-1 (requests) · Работы временно ставят метки и taint'ы на узлы стенда

## Где мы на карте

Эта часть разбирает kube-scheduler: как он выбирает узел для пода и какие правила размещения ему можно задать. Она опирается на три части. В 01-1 scheduler назван компонентом control plane, в 01-2 разобраны taint'ы узла и вытеснение с `tolerationSeconds`, в 05-1 requests названы единственными числами, по которым scheduler считает место на узле.

Следующие части используют то, что здесь решает scheduler. Автомасштабирование (05-4) реагирует на поды, для которых не нашлось узла, а drain и PodDisruptionBudget (05-5) перемещают поды, и scheduler снова выбирает им места.

```
 Pod без узла ─► очередь ─► фильтры ─► оценка ─► привязка (spec.nodeName записан)
                   ▲           │ узлов не осталось
                   │           ▼
          подсказки QueueingHints   вытеснение (§3) ─► Pending + событие FailedScheduling
```

Схема 1. Путь пода через scheduler: слева вход, справа результат; нижняя ветка показывает, что происходит, когда узла нет.

---

## 1. Какую задачу решает планировщик

Планировщик отвечает на вопрос, на каком узле запустить под. Разберём, из чего он выбирает, что о кластере знает и почему решение принимает один раз.

### Выбор узла для пода

**Планировщик** (scheduler, процесс `kube-scheduler`) берёт каждый под без поля `spec.nodeName` и записывает в него имя узла. Выбор идёт в три действия: отбросить узлы, где под не сможет работать, оценить оставшиеся и привязать под к лучшему. Kubelet на выбранном узле видит свой новый под и запускает его (01-2).

Узлы отбрасывают по правилам пяти видов: хватает ли свободных requests (05-1), совпадают ли метки, пускает ли taint, подходит ли топология и доступны ли том и устройство. Всё остальное, например образ или язык приложения, scheduler не проверяет.

### Что планировщик знает и чего не знает

Scheduler видит только то, что записано в объектах API: requests подов, метки и taint'ы узлов, тома, адреса и устройства. Реальную загрузку CPU, диска и сети он не видит. Узел с requests 90 % и нулевой нагрузкой для него занят, а узел с requests 10 % и 100 % загрузки CPU свободен.

Поэтому правила размещения описывают намерение, а не измерение. Если оно не записано в манифесте, scheduler его не знает и поставит под туда, где свободнее по requests.

### Решение принимается один раз

Scheduler решает при создании пода и больше его не пересматривает. Если вы добавили узлы, слили часть подов или уменьшили число реплик, распределение остаётся прежним, даже когда стало плохим. Исправляют его пересозданием подов: rollout или **descheduler** (отдельный компонент, который выселяет поды с нарушенными правилами; в Kubernetes его нет). Документация прямо предупреждает: после удаления подов ограничения spread не гарантируются.

---

## 2. Как устроен планировщик

Внутри scheduler работает по очередям и плагинам. Разберём цикл обработки пода, плагины фильтрации и оценки, механизм повторных попыток и новый способ описывать устройства.

### Два цикла и три очереди

Каждый под проходит два цикла. **Цикл планирования** (scheduling cycle) выбирает узел, и циклы разных подов идут строго по очереди. **Цикл привязки** (binding cycle) записывает выбор в кластер, и такие циклы могут идти параллельно. Если на любом шаге узла нет или случилась ошибка, под возвращается в очередь.

Подов ждут три очереди. В **активной очереди** (active queue) лежат поды, готовые к попытке. В **очереди отсрочки** (backoff queue) поды ждут перед повторной попыткой: пауза растёт от 1 до 10 секунд. В списке **неподходящих подов** (unschedulable pods) лежат поды, для которых узла нет и которые ждут события, способного это изменить.

```
 новый под ─► PreEnqueue ─► активная очередь ─► Filter ─► Score ─► Reserve ─► Permit ─► Bind
                  │ (gate)         ▲              │ пусто
                  ▼                │              ▼
          держит под вне         подсказка    PostFilter (вытеснение)
          очереди                 события        │ не помогло
                                   │              ▼
                         список неподходящих ◄── Pending
```

Схема 2. Точки расширения scheduler (жирные названия плагинов в документации): PreEnqueue пускает под в очередь, Filter и Score выбирают узел, PostFilter включается, когда узлов нет.

### Фильтры и оценка

На шаге **Filter** плагины отбрасывают узлы, а на шаге **Score** выставляют оставшимся баллы. Каждое правило размещения из §3 реализует один плагин.

| Плагин | Фильтр | Оценка |
|---|---|---|
| NodeResourcesFit | хватает requests | меньше загружен — выше балл |
| NodeAffinity | required affinity и nodeSelector | preferred affinity |
| TaintToleration | taint без toleration | меньше непереносимых PreferNoSchedule |
| InterPodAffinity | pod affinity и anti-affinity | preferred-правила |
| PodTopologySpread | spread с DoNotSchedule | spread с ScheduleAnyway |
| VolumeBinding | том доступен на узле | близость к тому |
| DynamicResources | устройство для claim есть | нет |

Если кандидатов много, scheduler оценивает не все. Параметр `percentageOfNodesToScore` по умолчанию подбирается сам: в кластере меньше 100 узлов проверяются все узлы, в большом доля падает до 5 %. Узел для оценки отбирается по кругу, чтобы нагрузка не липла к началу списка.

### Повторные попытки и подсказки QueueingHints

Под в списке неподходящих ждёт события, которое может помочь. Раньше любое событие кластера (новый узел, удалённый под) возвращало в очередь все такие поды, и scheduler тратил время на заведомо бесполезные попытки. Теперь каждый плагин сообщает **подсказку** (QueueingHint): помогает ли это событие именно этому поду.

Пример: под отброшен из-за taint, и плагин TaintToleration возвращает его в очередь только при событии «у узла изменились taint'ы», а удаление чужого пода его не интересует. Подсказки включены всегда, они стали GA в 1.34, а настройки у них нет. Если событий нет, под всё равно возвращается в очередь не позже чем через 5 минут.

### Scheduling gates: под, который ждёт разрешения

**Scheduling gate** (шлюз планирования) — строка в `spec.schedulingGates`, пока она есть, scheduler под не рассматривает. Плагин PreEnqueue держит такой под вне активной очереди, поэтому в нём нет события `FailedScheduling`, а статус показывает `SchedulingGated`. Шлюз можно задать только при создании пода и только снять: любой контроллер, например очередь заданий Kueue, снимает его, когда готовы квота или данные. С версии 1.30 функция stable.

Пока под ждёт, его можно только сузить: добавить в `nodeSelector` или в required affinity новые условия, но не ослабить старые.

### Устройства: Dynamic Resource Allocation

Для GPU и других устройств у Kubernetes есть второй механизм, **DRA** (Dynamic Resource Allocation, динамическое выделение ресурсов). Старый путь, device plugin, умеет только запросить число устройств: `nvidia.com/gpu: 1`. DRA позволяет выбрать устройство по свойствам, поделить его между подами и описать настройку устройства в самой заявке. Основная часть функции стала GA в 1.34 и в 1.35 включена окончательно, группа API называется `resource.k8s.io/v1`.

Объектов пять, и они похожи на тома (04-2): драйвер публикует ресурсы, администратор описывает классы, под просит заявку.

- **ResourceSlice** — список устройств на узле или в пуле: имя, атрибуты, ёмкость; его создаёт драйвер, а не человек.
- **DeviceClass** — категория устройств с CEL-условием отбора; её создаёт администратор или драйвер.
- **ResourceClaim** — заявка на конкретные устройства из класса; создаётся вручную, чтобы поды делили устройство.
- **ResourceClaimTemplate** — шаблон, по которому для каждого пода создаётся своя заявка и удаляется вместе с ним.
- **CEL** (Common Expression Language) — язык выражений, которым заявки и классы фильтруют устройства по атрибутам.

```
  драйвер на узле ──► ResourceSlice (gpu-0, gpu-1: type=gpu, memory=64Gi)
                              │ scheduler читает
  DeviceClass ──► ResourceClaim ──► Pod: resourceClaims → resources.claims
  (отбор CEL)     (выбор из класса)   scheduler выбирает узел И устройство в одном цикле
```

Схема 3. Цепочка DRA: драйвер публикует устройства, класс и заявка отбирают их, scheduler выбирает узел вместе с устройством.

Заявка на одно устройство выглядит так: класс задаёт `deviceClassName`, а условие CEL выбирает по атрибутам. Манифесты ниже взяты из документации Kubernetes и показывают структуру, на стенде их применить нельзя, потому что устройств нет.

```yaml
apiVersion: resource.k8s.io/v1
kind: ResourceClaimTemplate
metadata: {name: gpu-claim}
spec:
  spec:
    devices:
      requests:
      - name: gpu
        exactly:
          deviceClassName: example-device-class
          selectors:
          - cel:
              expression: device.attributes["driver.example.com"].type == "gpu"
```

Разбор:

1. `ResourceClaimTemplate` создаёт отдельную заявку для каждого пода, а обычный `ResourceClaim` общий для нескольких подов.
2. В `devices.requests` перечислены запросы; `exactly` просит устройства из одного класса, а по умолчанию число устройств равно 1.
3. В `selectors.cel` условие по атрибутам, которые опубликовал драйвер в ResourceSlice.

Под подключает заявку двумя полями: `spec.resourceClaims` объявляет заявку у пода, а `resources.claims` в контейнере называет её по имени.

```yaml
spec:
  resourceClaims:
  - name: gpu
    resourceClaimTemplateName: gpu-claim
  containers:
  - name: app
    resources:
      claims:
      - name: gpu
```

Разбор: первая секция связывает имя `gpu` с шаблоном, вторая даёт контейнеру устройство из этой заявки. Остальные возможности DRA собраны в §6 с версиями, а здесь важны три:

- **Prioritized list** — запрос с перечнем запасных вариантов: scheduler берёт первый, который можно выделить (GA в 1.36).
- **Extended resource** — класс получает `extendedResourceName`, и под просит устройство старым способом `example.com/gpu: 2` (GA в 1.37).
- **Device taints** — taint на устройстве работает как taint на узле: NoSchedule не пускает новые поды, NoExecute выселяет работающие (GA в 1.37).

Одно ограничение стоит запомнить: scheduler не вытесняет работающие поды ради устройства. Под с высоким приоритетом остаётся Pending, пока устройство не освободится.

---

## 3. Как управлять размещением

Размещением управляют полями пода: куда можно, рядом с кем, как равномерно, каких не пускать и кто важнее. Каждое правило бывает жёстким (фильтр) или мягким (вес в оценке).

### Куда можно: nodeSelector и node affinity

`nodeSelector` — простейшее правило: под идёт только на узлы с указанными метками. **Node affinity** (привязка к узлам) умеет больше: выражения вместо равенства и мягкие предпочтения с весами.

```yaml
affinity:
  nodeAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      nodeSelectorTerms:
      - matchExpressions:
        - {key: topology.kubernetes.io/zone, operator: In, values: [zone-a, zone-b]}
    preferredDuringSchedulingIgnoredDuringExecution:
    - weight: 50
      preference:
        matchExpressions:
        - {key: node.kubernetes.io/instance-type, operator: In, values: [m6i.large]}
```

Разбор:

1. `required…` — фильтр: под не пойдёт на узел вне зон `zone-a` и `zone-b`.
2. `preferred…` с весом от 1 до 100 — добавка к баллам; без подходящего узла под всё равно встанет.
3. `IgnoredDuringExecution` в названии значит: если метку снять с работающего узла, под не тронут.

Операторы: `In`, `NotIn`, `Exists`, `DoesNotExist`, `Gt`, `Lt`. Стандартные метки узла — `kubernetes.io/hostname`, `topology.kubernetes.io/zone` и `region`, `node.kubernetes.io/instance-type`, `kubernetes.io/arch`; на смешанных кластерах amd64 и arm64 без `arch` образ может попасть не на ту архитектуру.

### Рядом и врозь: pod affinity и anti-affinity

**Pod affinity** (привязка к подам) тянет под к узлу или зоне, где уже есть нужные поды, а **pod anti-affinity** (отталкивание от подов) не пускает туда, где они есть. Область действия задаёт `topologyKey`: метка узла, значение которой определяет «домен» (по hostname домен — один узел, по зоне — вся зона).

```yaml
affinity:
  podAntiAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
    - labelSelector: {matchLabels: {app: anti}}
      topologyKey: kubernetes.io/hostname
```

Это правило жёстко запрещает ставить на узел второй под с меткой `app=anti`. Реплик больше, чем узлов, значит, лишние остаются Pending, а при отказе узла замене некуда встать. Поэтому required anti-affinity оставляют для действительно эксклюзивных случаев (брокер, etcd), а для остальных сервисов берут мягкий вариант `preferred…` или spread.

Поля `matchLabelKeys` и `mismatchLabelKeys` (GA с 1.33) подставляют в селектор значения меток самого пода. Так anti-affinity можно ограничить одной ревизией Deployment через `pod-template-hash`. Pod affinity — самое дорогое правило: scheduler сравнивает под со всеми подами домена, и в кластерах на тысячи узлов оно заметно замедляет планирование.

### Равномерно: topologySpreadConstraints

**Topology spread** (равномерное распределение) держит число подов в доменах примерно равным. **Домен** (topology domain) — группа узлов с одним значением метки `topologyKey`. **Skew** (перекос) — разница между числом подов в этом домене и в домене с наименьшим числом подов.

```yaml
topologySpreadConstraints:
- maxSkew: 1
  topologyKey: lab-05-3/zone
  whenUnsatisfiable: DoNotSchedule
  labelSelector: {matchLabels: {app: zspread}}
  matchLabelKeys: [pod-template-hash]
  nodeTaintsPolicy: Honor
```

Разбор:

1. `maxSkew: 1` — перекос не больше одного пода.
2. `whenUnsatisfiable` — `DoNotSchedule` делает правило фильтром, `ScheduleAnyway` оставляет весом в оценке.
3. `labelSelector` — какие поды считать; под должен подходить под собственный селектор, иначе он себя не посчитает.
4. `matchLabelKeys` — добавляет к селектору значения этих меток из самого пода, так счёт ведётся по ревизиям.
5. `nodeTaintsPolicy: Honor` — узлы с непереносимым taint не входят в домены.

Без правил работает только встроенное мягкое распределение: по узлам `maxSkew: 3` и по зонам `maxSkew: 5`, оба с `ScheduleAnyway`. Оно применяется к подам Service, ReplicaSet и StatefulSet и считает нормой даже расклад 3/2/1. Для жёсткого баланса по зонам и мягкого по узлам ставят два правила: зона с `DoNotSchedule`, узел с `ScheduleAnyway`.

Три поля уточняют расчёт доменов:

- **`minDomains`** — минимальное число доменов (только с `DoNotSchedule`): пока доменов меньше, считается, что в недостающих по нулю подов.
- **`nodeAffinityPolicy`** — учитывать ли `nodeSelector` и affinity пода при подсчёте доменов; по умолчанию учитывать (`Honor`).
- **`nodeTaintsPolicy`** — учитывать ли taint'ы; по умолчанию `Ignore`, то есть узлы с taint'ом остаются доменами, даже если под туда не попадёт.

Оба поля политик стали GA в 1.33.

### Запреты: taints и tolerations

**Taint** (метка-запрет на узле) отталкивает поды, а **toleration** (терпимость в поде) разрешает игнорировать taint. Taint состоит из ключа, значения и эффекта.

| Эффект | Новые поды без toleration | Работающие поды без toleration |
|---|---|---|
| NoSchedule | не планируются | остаются |
| PreferNoSchedule | избегаются по возможности | остаются |
| NoExecute | не планируются | выселяются сразу или через tolerationSeconds |

Toleration только разрешает: она не притягивает под на узел. Для выделенных узлов нужны оба правила: taint, чтобы чужие поды не пришли, и nodeSelector или affinity, чтобы свои шли именно туда.

```yaml
tolerations:
- key: lab-05-3/dedicated
  operator: Equal
  value: db
  effect: NoExecute
  tolerationSeconds: 20
```

Разбор:

1. `operator: Equal` сравнивает значение; `Exists` проверяет только наличие ключа, а пустой ключ с `Exists` терпит любые taint'ы.
2. `effect` ограничивает toleration одним эффектом; без него она подходит ко всем.
3. `tolerationSeconds` работает только с `NoExecute`: под остаётся на узле 20 секунд после появления taint и затем выселяется.

Системные taint'ы ставит сам Kubernetes: `node.kubernetes.io/not-ready` и `unreachable` (01-2; под терпит их 300 секунд), `memory-pressure`, `disk-pressure` и `pid-pressure` (05-5), `unschedulable` при cordon и `node-role.kubernetes.io/control-plane`. Свои taint'ы называют с префиксом организации, например `dedicated=db:NoSchedule`.

### Важнее других: PriorityClass и вытеснение

**PriorityClass** (класс приоритета) — объект кластера с числом: чем оно больше, тем важнее поды. Под называет класс в `priorityClassName`, а число копируется в `spec.priority`. Поды без класса получают приоритет 0, если ни у одного класса нет `globalDefault: true`.

Когда подходящего узла нет, включается **вытеснение** (preemption). Scheduler ищет узел, на котором удаление подов с меньшим приоритетом освободит место, и удаляет минимально нужные поды: по правилам graceful shutdown и с учётом PodDisruptionBudget по мере возможности (05-5). Новому поду записывается `status.nominatedNodeName`, чтобы место за ним сохранилось, пока жертвы завершаются. С версии 1.33 вытеснение асинхронное (beta, включено): цикл планирования не ждёт удаления.

```yaml
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata: {name: batch-low}
value: 100
preemptionPolicy: Never
description: "Фоновые задачи: сами не вытесняют, но вытесняются"
```

Разбор: `value` — приоритет класса; `preemptionPolicy: Never` запрещает поду вытеснять других, но не защищает его от вытеснения. Встроенные `system-cluster-critical` (2000000000) и `system-node-critical` (2000001000) нужны компонентам кластера, а своим классам разрешены значения до 1000000000. На практике хватает трёх-четырёх классов: критичные сервисы, обычные, фоновые задачи.

---

## 4. Как увидеть решение планировщика

Решение scheduler видно в событиях, условиях пода и метриках. Начинают с событий, потому что в них записана причина по каждому узлу.

### События и условия пода

Первым делом смотрят события пода и namespace: успешный выбор даёт событие `Scheduled`, неудача — `FailedScheduling` с причиной по каждому узлу. Условие `PodScheduled` в `status.conditions` повторяет итог: `True` после привязки, `False` с причиной `Unschedulable` или `SchedulingGated`.

```bash
kubectl describe pod web-0
kubectl get events --field-selector reason=FailedScheduling
kubectl get pods -o wide
```

Разбор команд:

| Команда | Что показывает |
|---|---|
| `describe pod` | события пода, внизу — причина `FailedScheduling` |
| `get events --field-selector` | все события одной причины в namespace |
| `get pods -o wide` | колонки NODE и NOMINATED NODE |

Что смотреть в выводе:

1. Столбец STATUS: `Pending` — узла нет, `SchedulingGated` — под ждёт снятия шлюза.
2. Столбец NODE: пусто, пока под не привязан.
3. Столбец NOMINATED NODE: заполнен, пока вытеснение идёт и место ещё не освободилось.

### Узлы и приоритеты

Чтобы понять, почему узел не подошёл, смотрят на сам узел: его метки, taint'ы и сумму requests.

```bash
kubectl describe node lab-worker3 | grep -A3 -E 'Taints|Allocated resources'
kubectl get nodes -L lab-05-3/zone
kubectl get pods -o custom-columns=POD:.metadata.name,NODE:.spec.nodeName,PRIO:.spec.priority
kubectl get priorityclass
```

Разбор команд:

| Команда | Что показывает |
|---|---|
| `describe node … grep` | taint'ы узла и сумму requests подов на нём |
| `get nodes -L метка` | значение метки узла отдельной колонкой |
| `custom-columns` | узел и приоритет каждого пода |
| `get priorityclass` | классы приоритета и их значения |

### Метрики и журнал

Метрики scheduler доступны на порту 10259 (HTTPS) самого процесса. Две полезны при диагностике: `scheduler_pending_pods` с меткой `queue` (`active`, `backoff`, `unschedulable`, `gated`) показывает, где застряли поды, а `scheduler_schedule_attempts_total` считает попытки по результатам. Полный журнал выбора на стенде читается командой `kubectl -n kube-system logs kube-scheduler-lab-control-plane`; уровень подробности задаётся флагом `-v` в статическом поде (01-1). Сбор метрик в Prometheus — вне курса.

---

## 5. Что ломается и как найти причину

Под не нашёл узел по одной из пяти причин: нехватка места, правила пода, правила узла, ловушка в spread или остановленный scheduler. Начинать надо с текста события `FailedScheduling`.

### Читаем событие FailedScheduling

Событие перечисляет узлы группами: сначала общее число, затем причина для каждой группы узлов, а после точки — итог попытки вытеснения. Вот реальное событие четвёртой реплики с anti-affinity на кластере 1 control-plane и 3 worker (лабораторная работа 1):

```
0/4 nodes are available: 1 node(s) had untolerated taint(s), 3 node(s) didn't match pod
anti-affinity rules. no new claims to deallocate, preemption: 0/4 nodes are available:
1 Preemption is not helpful for scheduling, 3 No preemption victims found for incoming pod.
```

Разбор: control-plane не подошёл из-за taint, три worker'а — из-за anti-affinity, а вытеснение не поможет: убирать нечего. Типичные фрагменты:

| Фрагмент сообщения | Причина | Где смотреть |
|---|---|---|
| Insufficient cpu / memory | requests не помещаются | 05-1, `describe node` |
| had untolerated taint(s) | у узла taint без toleration | `describe node` |
| didn't match Pod's node affinity/selector | нет подходящей метки узла | `get nodes --show-labels` |
| didn't match pod anti-affinity rules | узлы заняты подами из правила | селектор правила |
| didn't match pod topology spread constraints | нарушится maxSkew | §5, правило spread |
| had volume node affinity conflict | том привязан к другому узлу | 04-2 |
| Too many pods | достигнут лимит подов на узле | maxPods kubelet, 110 |

Если событий нет совсем, причину ищут не в правилах: scheduler остановлен (01-1), в `schedulerName` опечатка, и под ждёт несуществующий scheduler, или под в состоянии `SchedulingGated`.

### Spread вешает rollout

Rollout Deployment с жёстким spread по узлам зависает, хотя места хватает. При `maxSurge` 25 % Deployment создаёт сначала лишний под новой ревизии, а старые ещё работают. Старые и новый поды подходят под один `labelSelector`, поэтому scheduler считает их вместе.

На стенде с тремя репликами, `maxSkew: 1` по hostname и тремя worker'ами случилось так. Каждый worker держит по одному старому поду, а control-plane остаётся доменом без подов, потому что при `nodeTaintsPolicy: Ignore` его taint в расчёте не участвует. Новый под, куда бы он ни встал, даёт на worker'е 2 пода при минимуме 0 на control-plane, и перекос равен 2. Узла для него нет, и rollout стоит.

```
 домен          lab-worker  lab-worker2  lab-worker3  control-plane
 старые поды        1           1            1             0         (минимум = 0)
 новый под на worker'е: 2 - 0 = перекос 2  >  maxSkew 1  ─►  Pending
```

Схема 4. Счёт доменов при зависшем rollout: нулевой минимум на control-plane не даёт поставить четвёртый под ни на один worker.

Способов лечения три. `matchLabelKeys: [pod-template-hash]` считает поды отдельно для каждой ревизии: старые не мешают новым. `nodeTaintsPolicy: Honor` исключает control-plane из доменов, и минимум становится равен 1. Третий вариант, `maxSurge: 0` с `maxUnavailable: 1`, обходит ловушку, но снижает доступность на время обновления. В лабораторной работе 2 проверены `matchLabelKeys` и зависание, а `Honor` — в работе 5.

### Узел с taint'ом остаётся доменом

Вариант той же ловушки встречается при отказе узла (01-2). Отказавший узел получает taint `unreachable`, но при `Ignore` остаётся доменом без подов. Замена пода на другом узле нарушает перекос и висит в Pending, пока узел не вернётся. `nodeTaintsPolicy: Honor` убирает такие узлы из расчёта.

### Вытеснение и каскады

Приоритеты ломаются двумя способами. Без PriorityClass у всех подов приоритет 0, и вытеснение не работает вовсе: под с большим request не вытеснит ничего. А классы без дисциплины дают каскады: вытесненный под пересоздаётся контроллером, и если он тоже важнее чьей-то мелочи, она вытесняется следом.

Вытесненный под не пропадает: его ReplicaSet создаёт замену, и она остаётся Pending, если места нет и вытеснять некого (лабораторная работа 4). Поэтому классы выдают немногим службам, а фоновые задачи получают низкий класс и `preemptionPolicy: Never`.

---

## 6. Пределы и значения по умолчанию

Ниже числа, которые определяют поведение scheduler, и статус функций части в версиях 1.30–1.37. Стенд работает на Kubernetes 1.36.1.

### Числа

- **Spread по умолчанию** — по hostname `maxSkew: 3`, по зоне `maxSkew: 5`, оба `ScheduleAnyway`.
- **Лимит подов на узле** — 110 (поле `maxPods` kubelet).
- **Приоритет без класса** — 0; своим классам разрешены значения до 1000000000.
- **Системные классы** — `system-cluster-critical` 2000000000, `system-node-critical` 2000001000.
- **Toleration от admission** — `not-ready` и `unreachable` с `tolerationSeconds` 300 (01-2).
- **Очередь отсрочки** — пауза от 1 до 10 секунд, неподходящий под возвращается не позже чем через 5 минут.
- **Выборка узлов** — кластер до 100 узлов оценивается целиком.

### Статус функций

| Функция | Статус | Версия |
|---|---|---|
| Scheduling readiness (шлюзы) | GA | 1.30 |
| minDomains в spread | GA | 1.30 |
| nodeAffinityPolicy, nodeTaintsPolicy | GA | 1.33 |
| matchLabelKeys в affinity | GA | 1.33 |
| matchLabelKeys в spread | beta, включена | 1.27 |
| Асинхронное вытеснение | beta, включено | 1.33 |
| QueueingHints | GA | 1.34 |
| DRA, группа resource.k8s.io/v1 | GA | 1.34 |
| Prioritized list, admin access | GA | 1.36 |
| Extended resource, device taints (DRA) | GA | 1.37 |

Версия 1.37 на стенд не берётся: функции DRA из последней строки на стенде 1.36 в beta и включены, но проверять их без устройств нельзя.

### Чего планировщик не делает

Scheduler не перепланирует работающие поды, не измеряет нагрузку и не вытесняет поды ради устройств DRA. Групповое планирование (**gang scheduling**, все поды задания стартуют вместе или никто) в ядре Kubernetes пока в beta, для заданий машинного обучения его дают очереди вроде Kueue. Перекос после массовых операций исправляют descheduler с политикой `RemovePodsViolatingTopologySpreadConstraint` или rollout.

---

## Лабораторные работы

Работы идут на стенде 00-1 в namespace `lab-05-3`. **Namespace** — область имён, и его удаление удаляет всё внутри. Метки и taint'ы узлов в этой части называются с префиксом `lab-05-3/`, а манифесты лежат в `~/lab/k8s/05-3/`. Работы 1, 3 и 5 меняют узлы стенда, поэтому блоки «Риски» стоит прочитать до начала. Хост они не меняют, кроме текущего namespace в `~/.kube/config`.

Подготовка делается один раз: выбрать контекст, создать namespace и каталог и определить две функции оболочки. Функции живут только в вашем терминале, поэтому в новом окне определите их заново.

```bash
kubectl config use-context kind-lab
kubectl create ns lab-05-3
kubectl config set-context --current --namespace=lab-05-3
mkdir -p ~/lab/k8s/05-3
```

Разбор команд:

| Часть команды | Значение |
|---|---|
| `use-context kind-lab` | работать с кластером стенда |
| `create ns lab-05-3` | создать namespace части |
| `set-context --current --namespace=…` | подставлять его, если флаг `-n` не указан |
| `mkdir -p ~/lab/k8s/05-3` | каталог для манифестов части |

Результат:

```
Switched to context "kind-lab".
namespace/lab-05-3 created
Context "kind-lab" modified.
```

Разбор вывода: контекст переключён, namespace создан и пуст, а команды без `-n` попадают в `lab-05-3`.

Функция `where` показывает, на каких узлах стоят поды приложения, а `mkd` создаёт Deployment из пода `pause` с нагрузкой 10m CPU. Дополнительные поля шаблона пода `mkd` читает со стандартного ввода.

```bash
where() {
  kubectl get pods -l app=$1 -o custom-columns=N:.spec.nodeName,S:.status.phase \
    --no-headers | sort | uniq -c | awk '{printf "%s:%s×%s ", $2, $3, $1}'
  echo
}
mkd() {
  f=~/lab/k8s/05-3/$1.yaml
  cat > $f <<EOF
apiVersion: apps/v1
kind: Deployment
metadata: {name: $1}
spec:
  replicas: $2
  selector: {matchLabels: {app: $1}}
  template:
    metadata: {labels: {app: $1}}
    spec:
      terminationGracePeriodSeconds: 1
$(cat)
      containers:
      - name: c
        image: registry.k8s.io/pause:3.10
        resources: {requests: {cpu: 10m}}
EOF
  kubectl apply -f $f
}
```

Разбор функций:

| Часть | Значение |
|---|---|
| `where` | считает поды приложения по узлам и фазам |
| `uniq -c` | счётчик одинаковых пар «узел, фаза» |
| `mkd имя N` | Deployment с `N` репликами и меткой `app=имя` |
| `$(cat)` | вставляет в шаблон поля из стандартного ввода |
| `terminationGracePeriodSeconds: 1` | под удаляется за секунду |

Образ `pause` — контейнер, который ничего не делает и занимает 10m CPU requests: так scheduler видит поды, а узлы не нагружаются.

### Лабораторная работа 1. Anti-affinity и spread по зонам

**Цель.** Увидеть, как scheduler расставляет реплики без правил, с жёсткой anti-affinity и с spread по зонам, и прочитать событие `FailedScheduling`.

**Что понадобится.**

- Стенд 00-1: control-plane и три worker, контекст `kind-lab`.
- Namespace `lab-05-3`, функции `where` и `mkd` из подготовки.
- Около 15 минут.

**Схема опыта.** Узлам ставят метку зоны: `lab-worker` в `zone-a`, два других в `zone-b`. Control-plane зоны не получает и поэтому в расчёте spread по зонам не участвует.

```
 zone-a:  lab-worker
 zone-b:  lab-worker2   lab-worker3        control-plane: без метки зоны, с taint
 plain  (6 реплик, без правил)         ─► смотрим расклад
 anti   (4 реплики, required по узлу)  ─► 3 + 1 Pending, читаем событие
 zspread(6 реплик, maxSkew 1 по зоне)  ─► 3 в zone-a, 3 в zone-b
```

Схема показывает три опыта на одних узлах: каждый следующий добавляет жёсткое правило.

**Риски.** Работа ставит метки на три worker'а стенда.

- **Что меняется:** на `lab-worker`, `lab-worker2` и `lab-worker3` появляется метка `lab-05-3/zone`; в namespace `lab-05-3` создаются три Deployment.
- **Надолго ли:** до уборки; метка не влияет на чужие поды, потому что на неё никто не ссылается.
- **Безопасность:** привилегий не нужно; образ `pause` с 10m CPU не создаёт нагрузки.
- **Влияние на систему:** другие namespaces не затрагиваются; 16 подов по 10m не заметны для узлов.
- **Откат:** блок «Уборка» снимает метки и удаляет Deployment.

#### Шаг 1. Разметить зоны

Задаём узлам значения зон. Метка с префиксом `lab-05-3/` не пересекается с метками стенда.

```bash
kubectl label node lab-worker lab-05-3/zone=zone-a
kubectl label node lab-worker2 lab-worker3 lab-05-3/zone=zone-b
kubectl get nodes -L lab-05-3/zone
```

Разбор команды:

| Часть команды | Значение |
|---|---|
| `label node … lab-05-3/zone=zone-a` | поставить метку на узел |
| `-L lab-05-3/zone` | показать значение метки отдельной колонкой |

Результат:

```
node/lab-worker labeled
node/lab-worker2 labeled
node/lab-worker3 labeled
NAME                 STATUS   ROLES           …   ZONE
lab-control-plane    Ready    control-plane   …
lab-worker           Ready    <none>          …   zone-a
```

Разбор вывода:

1. Три узла помечены; колонка в выводе называется по метке.
2. У control-plane значение пусто, поэтому домена зоны для него нет.

#### Шаг 2. Шесть реплик без правил

Запускаем шесть подов без правил и смотрим расклад. Пауза 6 секунд нужна, чтобы scheduler успел привязать все поды.

```bash
mkd plain 6 </dev/null
sleep 6; where plain
```

Разбор команд:

| Часть команды | Значение |
|---|---|
| `mkd plain 6` | Deployment `plain` на 6 реплик |
| `</dev/null` | без дополнительных полей в шаблоне |
| `where plain` | расклад по узлам |

Результат:

```
lab-worker2:Running×1 lab-worker3:Running×2 lab-worker:Running×3
```

Разбор вывода:

1. Записи идут в виде «узел:фаза×число»; здесь расклад 3/2/1.
2. Встроенное мягкое распределение считает такой расклад нормой (`maxSkew: 3` по узлам).
3. Ни один узел не пустует, но и баланса нет: правило не жёсткое.

#### Шаг 3. Anti-affinity с четырьмя репликами

Просим четыре реплики и запрещаем два пода на одном узле. Worker'ов три, поэтому одна реплика не найдёт места. Затем читаем последнее событие `FailedScheduling` у Pending-пода.

```bash
mkd anti 4 <<'EOF'
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
          - labelSelector: {matchLabels: {app: anti}}
            topologyKey: kubernetes.io/hostname
EOF
sleep 6; where anti
```

Результат:

```
lab-worker2:Running×1 lab-worker3:Running×1 lab-worker:Running×1 <none>:Pending×1
```

Разбор вывода: три реплики стоят по одной на узле, а четвёртая без узла (`<none>`) в фазе Pending. Теперь прочитаем причину.

```bash
P=$(kubectl get pods -l app=anti --field-selector=status.phase=Pending -o name | head -1)
kubectl get events \
  --field-selector involvedObject.name=${P#pod/},reason=FailedScheduling \
  -o jsonpath='{.items[-1:].message}{"\n"}'
```

Разбор команд:

| Часть команды | Значение |
|---|---|
| `-o name \| head -1` | имя первого Pending-пода |
| `${P#pod/}` | имя без приставки `pod/` |
| `reason=FailedScheduling` | только события неудач планирования |
| `.items[-1:].message` | текст последнего события |

Результат:

```
0/4 nodes are available: 1 node(s) had untolerated taint(s), 3 node(s) didn't match pod
anti-affinity rules. no new claims to deallocate, preemption: 0/4 nodes are available:
1 Preemption is not helpful for scheduling, 3 No preemption victims found for incoming pod.
```

Разбор вывода:

1. `1 node(s) had untolerated taint(s)` — control-plane отброшен taint'ом, под терпимости не имеет.
2. `3 node(s) didn't match pod anti-affinity rules` — на каждом worker'е уже стоит реплика.
3. `Preemption is not helpful` — вытеснение control-plane ничего не даст; `No preemption victims found` — на worker'ах нет подов, которые можно убрать.

#### Шаг 4. Spread по зонам

Просим шесть реплик и жёсткий баланс по зонам: разница между зонами не больше одного пода.

```bash
mkd zspread 6 <<'EOF'
      topologySpreadConstraints:
      - maxSkew: 1
        topologyKey: lab-05-3/zone
        whenUnsatisfiable: DoNotSchedule
        labelSelector: {matchLabels: {app: zspread}}
EOF
sleep 6; where zspread
```

Результат:

```
lab-worker2:Running×2 lab-worker3:Running×1 lab-worker:Running×3
```

Разбор вывода:

1. `lab-worker` — единственный узел `zone-a` — получил 3 пода, два узла `zone-b` вместе получили тоже 3: баланс по зонам соблюдён.
2. Внутри `zone-b` расклад 2/1: правило считает зоны и ничего не говорит про узлы внутри зоны. Для баланса по узлам нужно второе правило с `ScheduleAnyway`.
3. Control-plane не получил подов: у него нет метки зоны, поэтому он не домен этого правила.

**Итог.**

| Что делали | Что увидели | Вывод |
|---|---|---|
| 6 реплик без правил | расклад 3/2/1 | встроенный spread мягкий |
| 4 реплики, required anti-affinity | 3 Running, 1 Pending | реплик больше узлов — лишние ждут |
| Событие FailedScheduling | причина по каждой группе узлов | читать по группам и итогу вытеснения |
| 6 реплик, maxSkew 1 по зоне | 3 в `zone-a`, 3 в `zone-b` | spread считает домены, а не узлы |

**Уборка.**

```bash
kubectl delete deploy plain anti zspread
kubectl label node lab-worker lab-worker2 lab-worker3 lab-05-3/zone-
kubectl get nodes -L lab-05-3/zone
```

В последней команде колонка зоны должна быть пустой у всех узлов.

**Вопросы для самопроверки.**

1. Почему control-plane не получил подов при spread по зоне? <details><summary>Ответ</summary>У него нет метки зоны, и он не входит ни в один домен правила; кроме того, scheduler не пускает на него поды из-за taint.</details>
2. Как сделать баланс и по зонам, и по узлам? <details><summary>Ответ</summary>Два правила: по зоне с `DoNotSchedule`, по hostname с `ScheduleAnyway`.</details>
3. Что произойдёт с anti-affinity при отказе одного из трёх узлов и трёх репликах? <details><summary>Ответ</summary>Замене некуда встать: на двух живых узлах уже стоят реплики, и новая реплика остаётся Pending, пока узел не вернётся.</details>

### Лабораторная работа 2. Spread и зависший rollout

**Цель.** Воспроизвести зависание rollout из-за жёсткого spread по узлам и вылечить его через `matchLabelKeys`.

**Что понадобится.**

- Стенд 00-1, три worker'а, namespace `lab-05-3`.
- Функции `where` и `mkd` из подготовки.
- Около 15 минут.

**Схема опыта.** Два одинаковых Deployment по три реплики с `maxSkew: 1` по hostname: у `hs-plain` обычный селектор, у `hs-mlk` добавлен `matchLabelKeys`. Оба перезапускаем.

```
 hs-plain  3 реплики ─ rollout restart ─► surge-под не находит узла ─► rollout стоит
 hs-mlk    3 реплики ─ rollout restart ─► ревизии считаются отдельно ─► rollout проходит
```

Схема сравнивает два варианта одного правила: единственное различие — одна строка `matchLabelKeys`.

Работа не меняет узлы и хост: все объекты живут в namespace `lab-05-3`.

#### Шаг 1. Создать Deployment с жёстким spread

Запускаем Deployment с тремя репликами и ждём, пока он развернётся: один под на worker'е.

```bash
mkd hs-plain 3 <<'EOF'
      topologySpreadConstraints:
      - maxSkew: 1
        topologyKey: kubernetes.io/hostname
        whenUnsatisfiable: DoNotSchedule
        labelSelector: {matchLabels: {app: hs-plain}}
EOF
kubectl rollout status deploy/hs-plain
where hs-plain
```

Разбор команд:

| Часть команды | Значение |
|---|---|
| `topologyKey: kubernetes.io/hostname` | домен — один узел |
| `maxSkew: 1` | разница между узлами не больше одного пода |
| `DoNotSchedule` | жёсткое правило |
| `rollout status` | ждать завершения развёртывания |

Результат:

```
deployment "hs-plain" successfully rolled out
lab-worker2:Running×1 lab-worker3:Running×1 lab-worker:Running×1
```

Разбор вывода: по одному поду на worker'е, первое развёртывание прошло без проблем, потому что тогда нет старой ревизии.

#### Шаг 2. Перезапустить и увидеть зависание

Запускаем rollout и ждём 40 секунд. Новый под не должен найти узел, поэтому `rollout status` завершится по таймауту с ошибкой.

```bash
kubectl rollout restart deploy/hs-plain
kubectl rollout status deploy/hs-plain --timeout=40s
kubectl get pods -l app=hs-plain -o custom-columns=POD:.metadata.name,S:.status.phase
```

Результат:

```
hs-plain-c47c4cd5b-cbkn8 Pending
hs-plain-df77c4f58-h6f97 Running
hs-plain-df77c4f58-jg5q5 Running
hs-plain-df77c4f58-ngj2v Running
```

Разбор вывода:

1. `c47c4cd5b` — новая ревизия: её единственный под (surge-под) в Pending.
2. Три старых пода `df77c4f58` работают, и сервис не прерывался.
3. Deployment не удалит старый под, пока новый не станет готовым: `maxUnavailable` у него 25 %, то есть ни одного пода в округлении.

Причина записана в событии. Читаем его.

```bash
kubectl get events --field-selector reason=FailedScheduling \
  -o jsonpath='{.items[-1:].message}{"\n"}'
```

Результат (сокращён):

```
0/4 nodes are available: … 3 node(s) didn't match pod topology spread constraints. …
```

Разбор вывода: три worker'а отброшены правилом spread. Старые и новый поды считаются вместе, на worker'е вышло бы 2 пода при минимуме 0 на control-plane, то есть перекос 2 против допустимого 1 (§5).

#### Шаг 3. Вылечить через matchLabelKeys

Создаём второй Deployment с `matchLabelKeys: [pod-template-hash]` и перезапускаем его так же.

```bash
mkd hs-mlk 3 <<'EOF'
      topologySpreadConstraints:
      - maxSkew: 1
        topologyKey: kubernetes.io/hostname
        whenUnsatisfiable: DoNotSchedule
        labelSelector: {matchLabels: {app: hs-mlk}}
        matchLabelKeys: [pod-template-hash]
EOF
kubectl rollout status deploy/hs-mlk
kubectl rollout restart deploy/hs-mlk
kubectl rollout status deploy/hs-mlk --timeout=40s
```

Разбор команд:

| Часть команды | Значение |
|---|---|
| `matchLabelKeys: [pod-template-hash]` | к селектору добавляется метка ревизии пода |
| `rollout restart` | новая ревизия с той же схемой |
| `--timeout=40s` | не ждать дольше 40 секунд |

Результат:

```
deployment "hs-mlk" successfully rolled out
```

Разбор вывода: rollout дошёл до конца. Поды новой ревизии считаются отдельно от старых, поэтому три новых пода по одному на узел не нарушают перекос.

**Итог.**

| Что делали | Что увидели | Вывод |
|---|---|---|
| rollout при `maxSkew: 1` по узлам | surge-под Pending, rollout стоит | старые и новые поды считаются вместе |
| Событие FailedScheduling | `didn't match pod topology spread constraints` | правило spread отбрасывает все worker'ы |
| То же с `matchLabelKeys` | rollout проходит | счёт ведётся по ревизиям |

**Уборка.**

```bash
kubectl delete deploy hs-plain hs-mlk
```

**Вопросы для самопроверки.**

1. Почему первое развёртывание прошло, а перезапуск завис? <details><summary>Ответ</summary>Первый раз старых подов нет. При перезапуске surge-под считается вместе со старыми, и перекос превышает `maxSkew`.</details>
2. Что делает `matchLabelKeys: [pod-template-hash]`? <details><summary>Ответ</summary>Добавляет в селектор значение метки `pod-template-hash` самого пода, и поды разных ревизий считаются отдельно.</details>
3. Какие ещё способы обхода есть? <details><summary>Ответ</summary>`maxSurge: 0` с `maxUnavailable: 1`, `whenUnsatisfiable: ScheduleAnyway` или `nodeTaintsPolicy: Honor` (работа 5).</details>

### Лабораторная работа 3. Taints и tolerations

**Цель.** Сравнить эффекты NoSchedule и NoExecute и увидеть, как `tolerationSeconds` задерживает вытеснение.

**Что понадобится.**

- Стенд 00-1, узел `lab-worker3`, namespace `lab-05-3`.
- Около 15 минут.

**Схема опыта.** На `lab-worker3` запускают три пода, потом вешают taint сначала с эффектом NoSchedule, затем с NoExecute.

```
 lab-worker3:  t-plain (без toleration)   t-tol (терпит)   t-tol20 (терпит 20 с)
 + NoSchedule  ─► t-new (новый) Pending;  работающие остаются
 + NoExecute   ─► t-plain выселен сразу;  t-tol20 через 20 с;  t-tol остаётся
```

Схема показывает, что NoSchedule влияет только на новые поды, а NoExecute — и на работающие.

**Риски.** Работа ставит taint на узел стенда, причём эффект NoExecute выселяет поды.

- **Что меняется:** на `lab-worker3` появляется taint `lab-05-3/dedicated=db` сначала с NoSchedule, затем с NoExecute.
- **Надолго ли:** NoExecute держится около 30 секунд; шаг 4 снимает оба taint'а.
- **Безопасность:** привилегий не нужно.
- **Влияние на систему:** NoExecute выселяет с узла все поды без toleration, в том числе из других namespaces, например `orders`; Deployment создаст их заново на других узлах, а под с томом local-path (04-2) останется Pending до снятия taint. Перед шагом 3 посмотрите, что стоит на узле: `kubectl get pods -A -o wide | grep lab-worker3`. Если там важные поды, возьмите другой worker.
- **Откат:** шаг 4 и блок «Уборка».

#### Шаг 1. Запустить три пода на lab-worker3

Три пода закрепляем за узлом по hostname. У `t-tol` и `t-tol20` есть toleration для NoExecute, у второго с ограничением в 20 секунд.

```bash
cat > ~/lab/k8s/05-3/taint-pods.yaml <<'EOF'
apiVersion: v1
kind: List
items:
- apiVersion: v1
  kind: Pod
  metadata: {name: t-plain}
  spec:
    terminationGracePeriodSeconds: 1
    nodeSelector: {kubernetes.io/hostname: lab-worker3}
    containers: [{name: c, image: "registry.k8s.io/pause:3.10"}]
- apiVersion: v1
  kind: Pod
  metadata: {name: t-tol}
  spec:
    terminationGracePeriodSeconds: 1
    nodeSelector: {kubernetes.io/hostname: lab-worker3}
    tolerations:
    - {key: lab-05-3/dedicated, operator: Equal, value: db, effect: NoExecute}
    containers: [{name: c, image: "registry.k8s.io/pause:3.10"}]
- apiVersion: v1
  kind: Pod
  metadata: {name: t-tol20}
  spec:
    terminationGracePeriodSeconds: 1
    nodeSelector: {kubernetes.io/hostname: lab-worker3}
    tolerations:
    - {key: lab-05-3/dedicated, operator: Equal, value: db, effect: NoExecute,
       tolerationSeconds: 20}
    containers: [{name: c, image: "registry.k8s.io/pause:3.10"}]
EOF
kubectl apply -f ~/lab/k8s/05-3/taint-pods.yaml
kubectl wait --for=condition=Ready pod/t-plain pod/t-tol pod/t-tol20
```

Разбор команд:

| Часть команды | Значение |
|---|---|
| `nodeSelector: {kubernetes.io/hostname: …}` | закрепить под за узлом |
| `tolerations … effect: NoExecute` | терпеть taint с этим эффектом |
| `tolerationSeconds: 20` | терпеть 20 секунд после появления taint |
| `kubectl wait --for=condition=Ready` | ждать готовности трёх подов |

Результат:

```
pod/t-plain created
pod/t-tol created
pod/t-tol20 created
pod/t-plain condition met
pod/t-tol condition met
pod/t-tol20 condition met
```

Разбор вывода: все три пода работают на `lab-worker3`.

#### Шаг 2. Повесить NoSchedule и запустить новый под

Вешаем taint NoSchedule и запускаем четвёртый под без toleration.

```bash
kubectl taint node lab-worker3 lab-05-3/dedicated=db:NoSchedule
kubectl run t-new --image=registry.k8s.io/pause:3.10 \
  --overrides='{"spec":{"nodeSelector":{"kubernetes.io/hostname":"lab-worker3"}}}'
sleep 4; kubectl get pods
kubectl delete pod t-new --now
```

Разбор команд:

| Часть команды | Значение |
|---|---|
| `taint node … key=value:NoSchedule` | запретить новые поды без toleration |
| `kubectl run t-new` | новый под, закреплённый за тем же узлом |
| `delete pod t-new --now` | убрать Pending-под сразу |

Результат (сокращён):

```
t-new Pending
t-plain Running
t-tol Running
t-tol20 Running
```

Разбор вывода:

1. `t-new` не встал: nodeSelector разрешает только `lab-worker3`, а taint его не пускает.
2. Три работающих пода остались: NoSchedule на них не действует.

#### Шаг 3. Повесить NoExecute и записать выселения

Добавляем taint с эффектом NoExecute и 30 секунд записываем изменения статуса подов с отметкой времени.

```bash
t0=$(date +%s)
kubectl taint node lab-worker3 lab-05-3/dedicated=db:NoExecute
for i in $(seq 1 30); do
  s=$(kubectl get pods --no-headers | awk '{printf "%s:%s ", $1, $3}')
  [ "$s" != "$prev" ] && echo "t=+$(( $(date +%s)-t0 ))s $s" && prev=$s
  sleep 1
done
```

Разбор команд:

| Часть команды | Значение |
|---|---|
| `taint … :NoExecute` | выселять поды без toleration |
| `t0=$(date +%s)` | момент добавления taint |
| цикл `seq 1 30` | раз в секунду читать статусы, печатать изменения |

Результат (сокращён):

```
t=+0s t-plain:Completed
t=+20s t-tol20:Terminating
t-tol:Running
```

Разбор вывода:

1. В момент +0 с `t-plain` без toleration выселен сразу.
2. Через 20 секунд выселен `t-tol20`: именно столько указано в `tolerationSeconds`.
3. `t-tol` с бессрочной toleration остался на узле.

#### Шаг 4. Снять taint'ы

Снимаем taint по ключу. Команда с `-` в конце удаляет все taint'ы с этим ключом, оба эффекта сразу.

```bash
kubectl taint node lab-worker3 lab-05-3/dedicated-
kubectl get nodes -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints
```

Результат (сокращён):

```
node/lab-worker3 untainted
NAME                TAINTS
lab-control-plane   [map[effect:NoSchedule key:node-role.kubernetes.io/control-plane]]
lab-worker3         <none>
```

Разбор вывода: у `lab-worker3` taint'ов нет, остался только штатный taint control-plane.

**Итог.**

| Что делали | Что увидели | Вывод |
|---|---|---|
| NoSchedule | новый под Pending, старые остались | влияет только на новые поды |
| NoExecute | `t-plain` выселен сразу | работающие поды без toleration уходят |
| `tolerationSeconds: 20` | выселен через 20 секунд | задержка считается от появления taint |
| Toleration без секунд | под остался | терпимость бессрочная |

**Уборка.**

```bash
kubectl delete pod --all --now
kubectl taint node lab-worker3 lab-05-3/dedicated- 2>/dev/null
kubectl get nodes -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints
```

Taint'ы должны остаться только у control-plane.

**Вопросы для самопроверки.**

1. Чем NoSchedule отличается от NoExecute? <details><summary>Ответ</summary>NoSchedule не пускает новые поды, NoExecute дополнительно выселяет работающие поды без toleration.</details>
2. Почему одной toleration мало для выделенных узлов? <details><summary>Ответ</summary>Toleration только разрешает, но не притягивает. Нужен ещё nodeSelector или node affinity.</details>
3. Что делает `taint node … ключ-`? <details><summary>Ответ</summary>Снимает все taint'ы с этим ключом, независимо от эффекта.</details>

### Лабораторная работа 4. Приоритеты и вытеснение

**Цель.** Увидеть, как под высокого приоритета вытесняет под низкого, и прочитать события вытеснения.

**Что понадобится.**

- Стенд 00-1, три worker'а, namespace `lab-05-3`.
- Около 10 минут.

**Схема опыта.** Три пода `batch` с низким приоритетом занимают по 10 CPU на worker'е (kind показывает каждому узлу все 12 CPU хоста, 05-1). Под `critical` с высоким приоритетом просит те же 10 CPU.

```
 lab-worker   lab-worker2   lab-worker3        control-plane: taint, не подходит
 batch        batch         batch              (по 10 CPU requests, приоритет 100)
 critical (10 CPU, приоритет 100000) ─► вытесняет один batch на lab-worker3
 вытесненный batch ─► пересоздан ReplicaSet'ом ─► Pending (вытеснять некого)
```

Схема показывает вытеснение: жертва выбирается среди подов с меньшим приоритетом.

**Риски.** Работа создаёт два PriorityClass уровня кластера и поды с запросом 10 CPU.

- **Что меняется:** два объекта `PriorityClass` с префиксом `lab-05-3-`; Deployment `batch` и под `critical` в `lab-05-3`.
- **Надолго ли:** до уборки; классы удаляет она же.
- **Безопасность:** привилегий не нужно.
- **Влияние на систему:** вытеснение может затронуть поды других namespaces на том же узле, если они приоритетом ниже 100000. Scheduler убирает минимум подов: на узле с batch хватает его одного. Поды стенда не должны занимать узлы целиком, но перед работой полезно проверить `kubectl get pods -A -o wide`.
- **Откат:** блок «Уборка».

#### Шаг 1. Создать классы и три низкоприоритетных пода

Создаём два класса и Deployment `batch` на три реплики, по 10 CPU в requests.

```bash
kubectl apply -f - <<'EOF'
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata: {name: lab-05-3-low}
value: 100
---
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata: {name: lab-05-3-high}
value: 100000
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: batch}
spec:
  replicas: 3
  selector: {matchLabels: {app: batch}}
  template:
    metadata: {labels: {app: batch}}
    spec:
      priorityClassName: lab-05-3-low
      terminationGracePeriodSeconds: 1
      containers:
      - name: c
        image: registry.k8s.io/pause:3.10
        resources: {requests: {cpu: "10"}}
EOF
kubectl rollout status deploy/batch
kubectl get pods -l app=batch -o custom-columns=POD:.metadata.name,NODE:.spec.nodeName,PRIO:.spec.priority
```

Разбор команд:

| Часть команды | Значение |
|---|---|
| `value: 100` / `value: 100000` | приоритеты двух классов |
| `priorityClassName: lab-05-3-low` | под принадлежит низкому классу |
| `requests: {cpu: "10"}` | под занимает 10 из 12 CPU узла |
| `custom-columns … PRIO` | приоритет, скопированный в `spec.priority` |

Результат (сокращён):

```
POD                      NODE          PRIO
batch-55c5fc9bfc-drfgg   lab-worker3   100
…
```

Разбор вывода: каждый worker держит один под `batch` с приоритетом 100, свободных CPU почти не осталось.

#### Шаг 2. Запустить critical и найти вытесненный под

Запускаем под с высоким приоритетом, просящий 10 CPU. Свободного места нет нигде, поэтому scheduler включает вытеснение.

```bash
kubectl run critical --image=registry.k8s.io/pause:3.10 --overrides='{"spec":{
  "priorityClassName":"lab-05-3-high","containers":[{"name":"critical",
  "image":"registry.k8s.io/pause:3.10","resources":{"requests":{"cpu":"10"}}}]}}'
kubectl wait --for=condition=Ready pod/critical
kubectl get events --field-selector reason=Preempted -o custom-columns=OBJ:.involvedObject.name,MSG:.message
kubectl get pods -l app=batch
```

Разбор команд:

| Часть команды | Значение |
|---|---|
| `priorityClassName: lab-05-3-high` | под принадлежит высокому классу |
| `kubectl wait --for=condition=Ready` | ждать запуска под |
| `reason=Preempted` | события вытеснения |
| `get pods -l app=batch` | что стало с низкоприоритетными подами |

Результат (сокращён):

```
critical Ready after 1s on lab-worker3
batch-55c5fc9bfc-drfgg   Preempted by pod d93570d8-… on node lab-worker3
batch-55c5fc9bfc-9x8g8   Pending — 3 Insufficient cpu ... 1 No preemption victims found for incoming pod
```

Разбор вывода:

1. `critical` стал готовым за 1 секунду на `lab-worker3`: удаление одного пода `batch` освободило 10 CPU.
2. Событие `Preempted` называет вытесненный под, под-вытеснитель и узел.
3. Замена вытесненного пода висит Pending: `Insufficient cpu` на трёх worker'ах, а вытеснять некого — у `batch` самый низкий приоритет.

**Итог.**

| Что делали | Что увидели | Вывод |
|---|---|---|
| Три `batch` по 10 CPU | узлы заполнены | вытеснение нужно, когда места нет |
| `critical` с большим приоритетом | готов за 1 с, один batch вытеснен | жертва — под с меньшим приоритетом |
| Событие `Preempted` | указан под-вытеснитель | вытеснение видно в событиях |
| Замена вытесненного пода | Pending | вытеснение не создаёт места навсегда |

**Уборка.**

```bash
kubectl delete deploy batch
kubectl delete pod critical --now
kubectl delete priorityclass lab-05-3-low lab-05-3-high
```

**Вопросы для самопроверки.**

1. Почему поды без PriorityClass не вытесняют никого? <details><summary>Ответ</summary>У всех приоритет 0, а вытеснять можно только поды с меньшим приоритетом.</details>
2. Защищает ли `preemptionPolicy: Never` под от вытеснения? <details><summary>Ответ</summary>Нет. Он запрещает поду вытеснять других, но сам под вытеснить можно.</details>
3. Почему вытесненный под остался Pending? <details><summary>Ответ</summary>Его создал ReplicaSet, но места нет, а ниже его приоритета никого нет.</details>

### Лабораторная работа 5. Scheduling gate, nodeTaintsPolicy и DRA без устройств

Эту работу вы выполняете сами, результаты в ней — ожидаемые.

**Цель.** Подержать под шлюзом планирования, проверить `nodeTaintsPolicy: Honor` на ловушке из §5 и убедиться, что DRA включён, но устройств в кластере нет.

**Что понадобится.**

- Стенд 00-1, три worker'а, namespace `lab-05-3`.
- Функции `where` и `mkd` из подготовки.
- Около 15 минут.

**Схема опыта.**

```
 gated   ─ schedulingGates ─► SchedulingGated ─ снять шлюз ─► Running
 sp-ignore (4 реплики, Ignore) ─► 3 Running + 1 Pending   (control-plane = домен с 0)
 sp-honor  (4 реплики, Honor)  ─► 4 Running (2/1/1)        (control-plane не домен)
 kubectl get deviceclasses     ─► No resources found       (DRA включён, устройств нет)
```

Схема показывает три независимых опыта: шлюз, политика taint'ов и проверка DRA.

Работа не ставит taint'ов и меток на узлы и хост не меняет.

#### Шаг 1. Создать под со шлюзом

Создаём под с одним шлюзом. Шлюз можно задать только при создании.

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata: {name: gated}
spec:
  terminationGracePeriodSeconds: 1
  schedulingGates:
  - name: lab-05-3/hold
  containers:
  - {name: c, image: "registry.k8s.io/pause:3.10"}
EOF
kubectl get pod gated
kubectl get events --field-selector involvedObject.name=gated
```

Разбор команд:

| Часть команды | Значение |
|---|---|
| `schedulingGates: [{name: …}]` | шлюз: scheduler не рассматривает под |
| `get pod gated` | статус пода |
| `get events … involvedObject.name=gated` | события, связанные с подом |

Ожидаемый результат:

```
NAME    READY   STATUS            RESTARTS   AGE
gated   0/1     SchedulingGated   0          5s
No resources found in lab-05-3 namespace.
```

Разбор ожидаемого вывода: статус `SchedulingGated`, события `FailedScheduling` нет: scheduler под даже не пробовал.

#### Шаг 2. Снять шлюз

Убираем поле `schedulingGates`. Это роль внешнего контроллера, здесь её играете вы.

```bash
kubectl patch pod gated --type=json \
  -p '[{"op":"remove","path":"/spec/schedulingGates"}]'
kubectl wait --for=condition=Ready pod/gated --timeout=60s
kubectl get pod gated -o wide
```

Ожидаемый результат (сокращён):

```
pod/gated patched
pod/gated condition met
NAME    READY   STATUS    …   NODE
gated   1/1     Running   …   lab-worker2
```

Разбор ожидаемого вывода: после снятия шлюза под прошёл обычный цикл и получил узел (какой именно, зависит от оценки).

#### Шаг 3. Сравнить Ignore и Honor

Запускаем два Deployment по четыре реплики с жёстким spread по hostname. У `sp-honor` добавлена политика `Honor`. Worker'ов три, поэтому с `Ignore` четвёртой реплике не хватит места из-за control-plane.

```bash
mkd sp-ignore 4 <<'EOF'
      topologySpreadConstraints:
      - maxSkew: 1
        topologyKey: kubernetes.io/hostname
        whenUnsatisfiable: DoNotSchedule
        labelSelector: {matchLabels: {app: sp-ignore}}
EOF
mkd sp-honor 4 <<'EOF'
      topologySpreadConstraints:
      - maxSkew: 1
        topologyKey: kubernetes.io/hostname
        whenUnsatisfiable: DoNotSchedule
        nodeTaintsPolicy: Honor
        labelSelector: {matchLabels: {app: sp-honor}}
EOF
sleep 8; where sp-ignore; where sp-honor
```

Разбор команд:

| Часть команды | Значение |
|---|---|
| `mkd sp-ignore 4` | политика по умолчанию (`Ignore`) |
| `nodeTaintsPolicy: Honor` | узлы с непереносимым taint не считаются доменами |
| `where …` | расклад по узлам |

Ожидаемый результат:

```
lab-worker2:Running×1 lab-worker3:Running×1 lab-worker:Running×1 <none>:Pending×1
lab-worker2:Running×1 lab-worker3:Running×1 lab-worker:Running×2
```

Разбор ожидаемого вывода:

1. У `sp-ignore` control-plane остаётся доменом с нулём подов (минимум 0), поэтому второй под на worker'е дал бы перекос 2, и четвёртая реплика Pending.
2. У `sp-honor` control-plane не считается, минимум равен 1, и четвёртая реплика встаёт на любой worker (перекос 1). Какой именно worker получит два пода, определяет оценка.

#### Шаг 4. Проверить, что DRA включён

Запрашиваем у API классы и срезы DRA. Драйверов и устройств в kind нет, поэтому списки пусты, но сами типы существуют.

```bash
kubectl get deviceclasses
kubectl get resourceslices
```

Ожидаемый результат:

```
No resources found
No resources found
```

Разбор ожидаемого вывода: группа `resource.k8s.io/v1` включена. Если вместо этого `the server doesn't have a resource type "deviceclasses"`, группа API отключена. Опыт с реальными устройствами возможен только с драйвером; на стенде этой части драйвера нет.

**Итог.**

| Что делали | Что ожидаем | Вывод |
|---|---|---|
| Под со шлюзом | `SchedulingGated`, событий нет | шлюз держит под вне очереди |
| Снятие шлюза | под получает узел | снимает шлюз внешний контроллер |
| Spread с `Ignore` | 3 Running, 1 Pending | control-plane считается доменом |
| Spread с `Honor` | 4 Running | узлы с taint'ом не считаются |
| `get deviceclasses` | `No resources found` | DRA включён, устройств нет |

**Уборка.**

```bash
kubectl delete deploy sp-ignore sp-honor
kubectl delete pod gated --now
kubectl config set-context --current --namespace=default
kubectl delete ns lab-05-3
kubectl get nodes -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints
kubectl get nodes -L lab-05-3/zone
rm -rf ~/lab/k8s/05-3
```

Namespace и каталог удалены, текущий namespace контекста вернулся в `default`, на узлах остался только штатный taint control-plane и нет меток зоны.

**Вопросы для самопроверки.**

1. Почему у пода со шлюзом нет события `FailedScheduling`? <details><summary>Ответ</summary>Плагин PreEnqueue не пускает его в активную очередь, и scheduler не пытается выбрать узел.</details>
2. Что можно менять в gated-поде? <details><summary>Ответ</summary>Только сужать размещение: добавлять условия в `nodeSelector` и required node affinity; шлюзы можно снимать, но не добавлять.</details>
3. Чем `Honor` лечит ловушку из §5? <details><summary>Ответ</summary>Он исключает из доменов узлы с непереносимым taint, поэтому минимум считается по worker'ам и четвёртый под не нарушает перекос.</details>

---

## → Дальше

Scheduler решает один раз и по requests, поэтому поды, для которых места нет, остаются Pending. Следующая часть, 05-4, показывает, как кластер реагирует на это автоматически: HPA меняет число реплик по нагрузке, а Cluster Autoscaler и Karpenter добавляют узлы для подов, которые scheduler не смог разместить. Без понимания requests и условия `Unschedulable`, разобранных здесь, не понять, чем сигнал к масштабированию отличается от обычной задержки старта.
