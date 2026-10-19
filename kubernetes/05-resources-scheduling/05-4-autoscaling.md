# 05-4. Автомасштабирование

> Модуль 05 «Ресурсы и планирование» · часть 4 из 5 · ~1,5 ч чтения + ~1 ч лабы (из них ~15 мин ожидание масштабирования) · Нужно: стенд 00-1 (контекст `kind-lab`, metrics-server, Helm), образ `python:3.12-slim`, доступ к `ghcr.io` для KEDA · Опирается на: 05-1 (requests), 02-2 (Deployment), 05-3 (Pending-поды)

## Где мы на карте

Эта часть показывает, как кластер сам меняет число подов, их размер и число узлов. Она опирается на 05-1: каждое решение автоскейлера строится на **requests** — запросах ресурсов из манифеста пода. Ещё нужны 02-2 (Deployment и поле `replicas`) и 05-3 (почему под остаётся Pending). Источник метрик — metrics-server со стенда (00-1); как он устроен, разбирает 11-1.

Следующая часть, 05-5, посвящена вытеснению подов: на него опираются и уменьшение числа узлов, и перезапуск подов под новый размер.

```
нагрузка растёт
   │
   ▼
HPA / KEDA            меняют число подов                    §2, §3
   │ новым подам не хватило места
   ▼
Pending ──► Cluster Autoscaler / Karpenter: добавляют узел  §2
VPA                   меняет размер пода (requests)         §2
```

Схема 1. Три уровня автомасштабирования: число подов, число узлов и размер пода. Уровни связаны через Pending-поды и requests.

---

## 1. Какую задачу решает автомасштабирование

Автомасштабирование подгоняет ёмкость кластера под нагрузку без участия человека. Разберём, что именно оно меняет, чем три уровня отличаются и как они зацеплены друг за друга.

### Ручные числа устаревают

Число реплик, размер пода и число узлов в манифесте — это догадка о будущей нагрузке. Завышенная догадка оставляет кластер простаивать и стоит денег, а заниженная топит сервис в пик. **Автомасштабирование** (autoscaling) заменяет догадку обратной связью: контроллер измеряет нагрузку и сам меняет число или размер.

Обратная связь не мгновенна. От роста нагрузки до нового пода проходят десятки секунд, до нового узла — минуты, поэтому запас всё равно нужен (§5).

### Три оси масштабирования

Каждый автоскейлер меняет одну величину и смотрит на свои сигналы.

- **HPA** (Horizontal Pod Autoscaler) — встроенный контроллер, который меняет число реплик Deployment, StatefulSet или другого объекта с подресурсом `scale`.
- **KEDA** (Kubernetes Event-driven Autoscaling) — надстройка над HPA, которая берёт сигналы из очередей, расписаний и внешних систем и умеет доводить число подов до нуля.
- **VPA** (Vertical Pod Autoscaler) — отдельный проект SIG Autoscaling, который по истории потребления подбирает requests и limits пода.
- **Cluster Autoscaler** (CA) и **Karpenter** — программы, которые добавляют и убирают узлы через API облака или Cluster API.

В kind узлы добавить некому: нет облачного API, поэтому узлы в этой части разобраны теорией, а HPA, KEDA и VPA — на стенде или по документации.

### Цепочка requests, HPA и узлов

Три оси работают как цепочка, и requests стоят в её начале и в конце. HPA считает загрузку в процентах от requests, scheduler (05-3) ищет место по сумме requests, а CA и Karpenter добавляют узел, когда место не нашлось.

```
 requests в манифесте
    │ знаменатель                     │ размер пода для scheduler
    ▼                                 ▼
 HPA: загрузка = usage / requests     scheduler: сумма requests на узле
    │ больше реплик                    │ не помещается
    ▼                                 ▼
 новые поды ─────────────────────► Pending (FailedScheduling)
                                      │
                                      ▼
                          CA / Karpenter: новый узел (минуты)
```

Схема 2. Путь от нагрузки до нового узла. Слабое звено — requests: от них зависят и проценты HPA, и решения про узлы.

Завышенные requests прячут нагрузку от HPA и заставляют CA держать пустые узлы. Заниженные включают HPA слишком рано и перегружают узлы. Поэтому калибровка requests (VPA в режиме `Off`, §3) идёт перед настройкой автоскейлеров.

---

## 2. Как устроено автомасштабирование

Устройство делится на четыре части: как HPA считает реплики, откуда он берёт метрики, как KEDA и VPA дополняют его и как работают автоскейлеры узлов.

### HPA: формула и метрики

**HPA** — контроллер в kube-controller-manager, который раз в 15 секунд (флаг `--horizontal-pod-autoscaler-sync-period`) читает метрики цели и пишет в её подресурс `scale` новое число реплик. Желаемое число он считает по формуле:

```
desiredReplicas = ceil( currentReplicas × currentMetric / targetMetric )
```

Для CPU в режиме `Utilization` метрика — процент от requests пода, а не от ядра узла. Поэтому под с requests 100m, который жжёт целое ядро, показывает 1000 %. Без `requests.cpu` процент посчитать нельзя, и HPA перестаёт работать (§5).

Из формулы вытекают четыре правила:

1. Допуск (**tolerance**) по умолчанию 10 %: если отношение метрики к цели лежит между 0,9 и 1,1, число реплик не меняется.
2. Поды без метрик при росте считаются как 0 %, а при падении — как 100 %, чтобы шумные данные не раздували и не обрушивали масштаб.
3. Неготовые поды при росте тоже считаются как 0 %, а первые 5 минут после старта CPU неготового пода вообще не учитывается.
4. При нескольких метриках берётся максимум желаемых реплик, и итог ограничен значениями `minReplicas` и `maxReplicas`.

Теперь о данных. HPA сам ничего не измеряет, а читает метрики через **агрегированные API** — расширения kube-apiserver, которые обслуживают отдельные программы. Таких API три, и тип метрики в манифесте выбирает, какой из них будет вызван.

```
HPA ──► kube-apiserver ──┬─► metrics.k8s.io           metrics-server: CPU и память подов
                         ├─► custom.metrics.k8s.io    адаптер (Prometheus Adapter): метрики объектов
                         └─► external.metrics.k8s.io  адаптер (KEDA): метрики вне кластера
                         
 Resource / ContainerResource ──► metrics.k8s.io
 Pods / Object               ──► custom.metrics.k8s.io
 External                    ──► external.metrics.k8s.io
```

Схема 3. Три источника метрик HPA. Если нужного API нет, в `describe hpa` появляется ошибка `FailedGet…Metric`.

Типов метрики пять:

- `Resource` — CPU или память всего пода;
- `ContainerResource` — один контейнер пода, так sidecar не искажает цифры;
- `Pods` — своя метрика каждого пода;
- `Object` — метрика другого объекта кластера;
- `External` — внешняя величина, например длина очереди.

Разрешение у metrics-server — 15 секунд (флаг `--metric-resolution`), и kubelet тоже обновляет статистику контейнеров примерно раз в 15 секунд. Поэтому первая реакция HPA на всплеск занимает около 25 секунд (шаг 3 лабораторной работы 2).

### behavior: окна и политики

Раздел `behavior` в манифесте HPA ограничивает скорость изменений отдельно для роста (`scaleUp`) и падения (`scaleDown`). У каждого направления есть **окно стабилизации** (stabilization window) — время, за которое HPA запоминает свои прошлые рекомендации. При падении он берёт максимальную рекомендацию за окно, при росте — минимальную. Так реплики не прыгают вверх и вниз на каждом колебании.

Кроме окна, есть **политики** (policies) — потолок на размер шага: не больше N подов или M процентов за период. Если политик несколько, выбирает `selectPolicy`: `Max` (по умолчанию) берёт самую щедрую, `Min` — самую строгую, `Disabled` запрещает направление совсем.

```
рекомендации HPA во времени:   10  10  10  4  3  4  3  3
окно 300 с (scaleDown): берётся максимум за окно ──► остаётся 10
окно 0 с  (scaleUp):    применяется сразу, но шаг ограничен политикой
```

Схема 4. Окно стабилизации сглаживает падение: пока в окне есть большая рекомендация, реплики не сокращаются.

Допуск тоже настраивается по направлениям. Поле `tolerance` внутри `scaleUp` и `scaleDown` заменяет глобальные 10 % на своё значение, например 0,05 для быстрого роста и 0,3 для осторожного сжатия. Функция `HPAConfigurableTolerance` появилась в 1.33 (alpha), в 1.35 стала beta и включена по умолчанию, поэтому на стенде 1.36 поле работает. В 1.37 она стала GA.

### KEDA: HPA с расширенными сигналами

**KEDA** состоит из трёх частей: оператора, адаптера метрик и admission-вебхуков. Пользователь описывает цель в объекте **ScaledObject**, а внутри него перечисляет **триггеры** (triggers) — источники сигнала. Для каждого типа источника есть готовый **скейлер** (scaler): cron, Prometheus-запрос, Kafka, RabbitMQ, SQS и десятки других.

```
ScaledObject ──► оператор KEDA
                   ├─ 0 ↔ 1: сам включает и выключает Deployment
                   └─ 1 → N: создаёт HPA keda-hpa-<имя>
                                     │ читает external.metrics.k8s.io
                                     ▼
                           адаптер метрик KEDA ◄── скейлер (cron, Kafka, …)
```

Схема 5. Разделение труда в KEDA: переход между нулём и одним подом делает оператор, всё остальное — обычный HPA.

KEDA вводит два тайминга. **pollingInterval** — как часто оператор опрашивает источник (по умолчанию 30 секунд). **cooldownPeriod** — сколько секунд после последнего активного сигнала ждать перед сжатием до нуля (по умолчанию 300 секунд). Свой HPA на ту же цель ставить нельзя: два контроллера будут бороться за `replicas`.

Встроенная альтернатива появилась позже. Для HPA минимум `minReplicas: 0` требует функцию `HPAScaleToZero` и хотя бы одной метрики типа `Object` или `External`. На 1.36 она выключена по умолчанию, в 1.37 стала beta и включена. Выбор между ними такой: встроенный нуль не тянет с собой дополнительный оператор, а KEDA даёт готовые скейлеры.

### VPA: три компонента и четыре режима

**VPA** — набор из трёх программ, которые ставят в кластер отдельно (в Kubernetes их нет). **Recommender** следит за потреблением и считает рекомендацию. **Updater** выбирает поды, чьи requests сильно отличаются от рекомендации, и применяет новые. **Admission-controller** подставляет рекомендацию в новые поды при создании.

Режим работы задаёт поле `updateMode`:

- **Off** — только рекомендации в `status`, под не трогается;
- **Initial** — рекомендация применяется только при создании пода;
- **Recreate** — updater вытесняет под (с учётом PDB, 05-5), и контроллер создаёт новый с новыми requests;
- **InPlaceOrRecreate** — updater сначала пробует изменить requests живого пода без перезапуска (in-place resize, 05-2) и вытесняет под, только если не вышло.

Режим `Auto` устарел с VPA 1.5: вместо него выбирают `Recreate` или `InPlaceOrRecreate`. `InPlaceOrRecreate` стал GA в VPA 1.6.0 (февраль 2026) и включён по умолчанию. На кластере 1.36 resize на месте уже GA (с 1.35).

В рекомендации четыре числа: `lowerBound`, `target`, `upperBound` и `uncappedTarget`. Стоит ставить `target`, а `uncappedTarget` показывает значение до ограничений из `resourcePolicy`.

### Автоскейлеры узлов

Оба автоскейлера узлов реагируют на **Pending-под, которому не хватило ресурсов**, и убирают узлы, которые простаивают. Различаются они способом, каким подбирают узел.

**Cluster Autoscaler** (CA) работает с готовыми **группами узлов** (node group): ASG, node pool или MachineDeployment в Cluster API. Для Pending-пода он проверяет в симуляции, поместится ли под на новом узле каждой группы, и увеличивает размер выбранной. Версия CA совпадает с минорной версией Kubernetes.

**Karpenter** обходится без заранее заданных групп. Он смотрит на все Pending-поды сразу и подбирает под них подходящий тип узла (**bin packing**, упаковка подов в минимальное число узлов). Узел он создаёт напрямую через API облака. Правила описываются объектами **NodePool** (ограничения и политика уборки) и класса узлов провайдера, а созданный узел отражён объектом **NodeClaim**.

```
                    Cluster Autoscaler                    Karpenter
вверх:     Pending-под ─► увеличить размер группы   Pending-поды ─► создать узел под них
вниз:      узел < 50 % requests 10 мин ─► убрать    консолидация: заменить/убрать узел
блокирует: PDB, локальный том, под без контроллера   PDB, аннотация do-not-disrupt
```

Схема 6. Сравнение двух подходов. Оба решают по requests, а не по реальному потреблению.

Karpenter 1.x умеет и вытеснять поды ради экономии, а для расчёта цены есть объект NodeOverlay (опциональная функция). Подробности NodePool меняются от версии к версии и зависят от провайдера, поэтому свериться с документацией своей версии полезнее, чем запоминать поля.

---

## 3. Как управлять автомасштабированием

Управление сводится к манифесту автоскейлера и к нескольким правилам совместной работы. Разберём HPA, затем `behavior` и допуск, затем KEDA и VPA, затем сочетания.

### Манифест HPA

В манифесте `autoscaling/v2` указывают цель, границы и метрики. Версия `v2` стала GA в 1.23 и заменяет `v1`, у которой была только метрика CPU.

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata: {name: api}
spec:
  scaleTargetRef: {apiVersion: apps/v1, kind: Deployment, name: api}
  minReplicas: 1           # по умолчанию 1; ноль запрещён без HPAScaleToZero
  maxReplicas: 8           # обязательное поле
  metrics:
  - type: Resource
    resource:
      name: cpu
      target: {type: Utilization, averageUtilization: 50}
```

Фрагмент манифеста: цель 50 % от requests, при превышении HPA добавит реплики до восьми.

Выбор метрики определяет качество результата. CPU подходит сервису, который упирается в процессор. Память — плохой сигнал: рантаймы (JVM, Go, Python) редко отдают память системе, реплики добавляются и не уходят. Сервису, который ждёт базу, нужна своя метрика: число запросов на под, задержка или длина очереди.

### behavior и допуск

Поведение настраивается в том же манифесте. Пример: быстрый подъём, медленный и плавный спуск.

```yaml
behavior:
  scaleUp:
    stabilizationWindowSeconds: 0
    tolerance: 0.05                                       # реагировать на 5 %, а не на 10 %
    policies: [{type: Pods, value: 2, periodSeconds: 30}] # не больше +2 пода за 30 с
  scaleDown:
    stabilizationWindowSeconds: 30
    policies: [{type: Percent, value: 50, periodSeconds: 15}]  # не больше −50 % за 15 с
```

Фрагмент манифеста: рост ограничен шагом в 2 пода раз в 30 секунд, падение — вдвое раз в 15 секунд после окна в 30 секунд.

Поле `selectPolicy: Disabled` в направлении `scaleDown` запрещает автоматическое сжатие: так делают для кэшей, которые долго прогреваются, но тогда сжимают вручную.

### Одно поле replicas — один владелец

Если в манифесте Deployment задано `replicas`, то каждый `kubectl apply` возвращает это число и сбрасывает работу HPA (01-3, 02-2). Поэтому у цели HPA поле `replicas` из манифеста убирают или оставляют только в первоначальном создании. То же правило действует для KEDA: ScaledObject и свой HPA на одну цель дадут два владельца.

### KEDA и VPA в манифестах

ScaledObject указывает цель, границы и триггеры; в примере — расписание.

```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata: {name: api}
spec:
  scaleTargetRef: {name: api}     # Deployment в том же namespace
  minReplicaCount: 0              # ноль подов вне окна
  maxReplicaCount: 5
  cooldownPeriod: 30              # по умолчанию 300 с
  triggers:
  - type: cron
    metadata: {timezone: Europe/Moscow, start: "0 9 * * *", end: "0 19 * * *", desiredReplicas: "3"}
```

Фрагмент манифеста: с 9:00 до 19:00 по Москве три пода, вне окна — ни одного. Лабораторная работа 3 запускает такой ScaledObject.

VPA задаётся объектом с целью и режимом. Начинать стоит с `Off`: рекомендация видна, поведение кластера не меняется.

```yaml
apiVersion: autoscaling.k8s.io/v1
kind: VerticalPodAutoscaler
metadata: {name: api}
spec:
  targetRef: {apiVersion: apps/v1, kind: Deployment, name: api}
  updatePolicy: {updateMode: "Off"}   # рекомендации без изменений в подах
  resourcePolicy:
    containerPolicies:
    - containerName: "*"
      minAllowed: {cpu: 50m, memory: 64Mi}
      maxAllowed: {cpu: "2", memory: 2Gi}
```

Фрагмент манифеста: границы `minAllowed` и `maxAllowed` не дают рекомендации выйти за разумные пределы.

### Что с чем сочетать

На одну цель ставят один горизонтальный автоскейлер: HPA или KEDA. VPA и HPA нельзя включать на одну метрику, потому что они мешают друг другу. VPA поднимает requests, процент загрузки падает, HPA убирает поды, нагрузка на оставшиеся растёт, и VPA снова поднимает requests.

Допустимы две пары. HPA по CPU вместе с VPA только по памяти (`controlledResources: [memory]`). Или HPA по своей метрике (запросы в секунду, очередь) вместе с VPA по любым ресурсам.

---

## 4. Как увидеть состояние автоскейлера

Состояние читают в самом автоскейлере: у него есть текущие значения, условия и события. Метрики и узловые автоскейлеры смотрят отдельно.

### Таблица HPA и условия

Команда выводит все HPA namespace и колонку `TARGETS` в виде «текущее/цель».

```bash
kubectl get hpa
kubectl describe hpa api
```

Колонка `TARGETS` с `<unknown>` значит, что метрики нет. Причина записана в блоке `Conditions` вывода `describe`:

- **AbleToScale** — контроллер может менять число реплик; `False` значит, что изменение сейчас запрещено;
- **ScalingActive** — метрики читаются и пригодны для расчёта; `False` почти всегда означает отсутствие requests или метрик;
- **ScalingLimited** — желаемое число упёрлось в `minReplicas`, `maxReplicas` или политику `behavior`.

Блок `Events` показывает решения: `SuccessfulRescale` (число реплик изменилось и по какой метрике) и ошибки `FailedGetResourceMetric`, `FailedComputeMetricsReplicas`, `FailedGetScale`.

### Метрики

Метрики проверяют отдельно, чтобы понять, виноват ли HPA или источник данных.

```bash
kubectl top pods                                      # то, что видит HPA для Resource
kubectl get --raw /apis/metrics.k8s.io/v1beta1/namespaces/lab-05-4/pods
kubectl get apiservice v1beta1.metrics.k8s.io         # колонка Available должна быть True
```

Первая команда показывает потребление подов, вторая — сырые данные Metrics API, третья — готов ли агрегированный API. В 1.37 `metrics.k8s.io` получил версию `v1` (GA, KEP-5207).

### KEDA, VPA и узлы

У KEDA смотрят на ScaledObject: колонки `READY` и `ACTIVE` в `kubectl get scaledobject` и события оператора. У VPA рекомендации находятся в `status`: `kubectl describe vpa api` печатает блок `Recommendation` с числами `Lower Bound`, `Target`, `Upper Bound`.

Узловые автоскейлеры оставляют след на подах и узлах. CA пишет события `TriggeredScaleUp` на Pending-под и `ScaleDown` на узел, а подробное состояние ведёт в ConfigMap `cluster-autoscaler-status` в `kube-system`. У Karpenter следы видны в объектах NodeClaim (`kubectl get nodeclaim`) и в событиях пода. Динамику во времени (число реплик, достижение `maxReplicas`) собирают метриками kube-state-metrics, например `kube_horizontalpodautoscaler_status_current_replicas` (11-1).

---

## 5. Что ломается и как найти причину

Поломки автоскейлеров делятся на три типа: не видит метрики, не растёт и не сжимается или нестабилен. Для каждой работает свой порядок поиска.

### В TARGETS стоит unknown

Колонка `TARGETS` с `<unknown>` означает, что HPA не может посчитать загрузку. Читают `Conditions` в `describe hpa`, и дальше причин три:

1. `missing request for cpu in container …` — requests нет хотя бы у одного контейнера пода. Для `Utilization` они нужны у всех, включая sidecar. Решение: добавить requests или перейти на `ContainerResource` с именем основного контейнера.
2. `unable to get metrics for resource cpu` — не работает metrics-server или недоступен агрегированный API; проверяют `kubectl top pods` и `get apiservice`.
3. `no matches for kind` или `FailedGetScale` — цель названа неверно или у объекта нет подресурса `scale`.

Опыт с первой причиной — лабораторная работа 1.

### Реплики не растут

Если нагрузка есть, а реплик не прибавляется, идут от HPA к узлам.

- `ScalingLimited=True` с причиной `TooManyReplicas` — желаемое число упёрлось в `maxReplicas`; уровень нужен выше или нагрузку надо снижать.
- Рост идёт ступенями — работает политика `scaleUp` (по умолчанию не больше +4 пода или +100 % за 15 с); это норма, а не поломка.
- Реплики появились, но поды Pending — не хватает места (05-3), и решать это должны узлы (CA, Karpenter) или освобождение ресурсов.
- Реплики не создаются, в ReplicaSet события `FailedCreate` — namespace упёрся в ResourceQuota (05-2).

Для резкого пика все эти задержки складываются: HPA опаздывает на десятки секунд, новый узел — на минуты. Запас делают поднятым `minReplicas`, расписанием (KEDA cron) и **overprovisioning** — подами-пустышками с низким приоритетом, которые занимают место и уступают его настоящим подам (приоритеты и вытеснение — 05-3).

### Реплики не уходят вниз или прыгают

Если нагрузка спала, а реплик по-прежнему много, смотрят три места: окно `scaleDown` (по умолчанию 300 секунд, §6), метрику (память почти не падает) и `minReplicas`. Если реплики пилят вверх и вниз, это **флаппинг** (flapping): колебания метрики около цели. Лечат его окном стабилизации побольше, допуском побольше и более гладкой метрикой.

### Два владельца одного поля

Реплики скачут к одному числу независимо от нагрузки — значит, у `replicas` два владельца. Типичные пары: `kubectl apply` с `replicas` в манифесте и HPA; свой HPA и ScaledObject на одной цели; HPA по CPU и VPA по CPU. Ищут второго владельца командами `kubectl get hpa,scaledobject,vpa` и проверкой `managedFields` (01-3).

### Узлы не добавляются и не убираются

В облаке причины для CA и Karpenter другие, чем у HPA. Узлы не добавляются в трёх случаях: под не помещается ни на один тип узла (requests больше узла), `nodeSelector` не подходит ни к одной группе, либо достигнут лимит группы или квота облака.

Узлы не убираются, если в узле есть под, которого нельзя выселить:

- под, чьё выселение нарушит PDB (05-5);
- под с локальным томом;
- под без контроллера;
- под с аннотацией `cluster-autoscaler.kubernetes.io/safe-to-evict: "false"` у CA или `karpenter.sh/do-not-disrupt: "true"` у Karpenter.

PDB с `maxUnavailable: 0` или с одной репликой блокирует удаление узла навсегда.

---

## 6. Пределы и значения по умолчанию

Ниже собраны числа этой части. Значения HPA, KEDA и VPA взяты из документации к версиям стенда (Kubernetes 1.36, KEDA 2.21.0), числа про опыт — из прогона на стенде.

### HPA

- Период пересчёта — 15 с (`--horizontal-pod-autoscaler-sync-period`).
- Допуск по умолчанию — 10 % (`--horizontal-pod-autoscaler-tolerance`, на поле `tolerance` с 1.33 alpha).
- Рост по умолчанию: окно 0 с; не больше +4 пода или +100 % за 15 с, выбирается большее.
- Падение по умолчанию: окно 300 с (`--horizontal-pod-autoscaler-downscale-stabilization`); не больше −100 % за 15 с.
- Окно инициализации CPU — 5 минут (`--horizontal-pod-autoscaler-cpu-initialization-period`), задержка готовности — 30 с.
- `minReplicas` по умолчанию 1; ноль требует `HPAScaleToZero` и метрики Object или External.

На стенде с настройками по умолчанию первая реакция пришла через 27 с после старта нагрузки. Сжатие до одной реплики заняло 354 с после остановки нагрузки (лабораторная работа 2).

### KEDA

- `pollingInterval` — 30 с, `cooldownPeriod` — 300 с.
- `minReplicaCount` — 0, `maxReplicaCount` — 100.
- Версия в курсе — 2.21.0. Версия 2.20 переключила события на `events.k8s.io`, и операторам нужны права на эту группу. В 2.21 закрыта уязвимость CVE-2026-77524: проверка аудитории токена в TriggerAuthentication стала строже, поэтому обновляться с более ранних версий нужно по руководству. KEDA 2.18 вышла из поддержки 1 июня 2026.

### VPA, CA и Karpenter

- VPA: `InPlaceOrRecreate` GA в 1.6.0, режим `Auto` устарел; минимум рекомендации — 25m CPU и 250 МиБ памяти (флаги recommender).
- CA: порог сжатия — 50 % requests на узле, время простоя перед удалением — 10 минут, цикл — 10 с (`--scan-interval`), ожидание нового узла — до 15 минут (`--max-node-provision-time`).
- Karpenter: версия API v1; политика консолидации и пауза `consolidateAfter` задаются в NodePool.
- Время появления нового узла — 1–3 минуты в облаке плюс скачивание образов. Это ориентир документации, на стенде не мерилось.

### Что изменилось в 1.37

В 1.37 `HPAConfigurableTolerance` стал GA, `HPAScaleToZero` — beta и включён по умолчанию, а Metrics API получил версию `v1`. Стенд остаётся на 1.36, поэтому все опыты проходят без этих изменений.

---

## Лабораторные работы

Работы идут на стенде 00-1 в namespace `lab-05-4`. Хост не меняют, кроме списка репозиториев Helm в работе 3, а всё остальное остаётся внутри кластера kind. Образ `orders-api:2.0` берётся из реестра стенда, образ нагрузки `python:3.12-slim` узлы тянут из Docker Hub.

Если Docker Hub с узлов недоступен, положите образ в реестр стенда на хосте командами ниже и замените `python:3.12-slim` на `localhost:5001/lab-05-4/python:3.12-slim`.

```bash
docker pull python:3.12-slim
docker tag python:3.12-slim localhost:5001/lab-05-4/python:3.12-slim
docker push localhost:5001/lab-05-4/python:3.12-slim
```

Команды скачивают образ, дают ему имя с адресом реестра стенда и загружают в реестр. Подготовку кластера делают один раз: выбирают контекст, создают namespace и каталог для файлов и проверяют metrics-server.

```bash
kubectl config use-context kind-lab
kubectl create ns lab-05-4
kubectl config set-context --current --namespace=lab-05-4
mkdir -p ~/lab/k8s/05-4
kubectl top nodes
```

Первые три команды выбирают кластер стенда, создают namespace и делают его текущим для kubectl. Четвёртая создаёт каталог для манифестов, а `kubectl top nodes` должна показать CPU и память узлов: значит, metrics-server работает и HPA получит метрики. Namespace и каталог удаляет уборка последней работы.

### Лабораторная работа 1. HPA без requests

**Цель.** Увидеть, что HPA с метрикой в процентах не работает без requests, прочитать условие с причиной и починить.

**Что понадобится.** Стенд 00-1, namespace `lab-05-4`, образ `localhost:5001/orders-api:2.0`.

**Схема опыта.**

```
Deployment noreq (без requests) ◄── scaleTargetRef ── HPA noreq (cpu 50 %)
        │                                                   │
        └── metrics-server: usage есть ─────────────────────┤
            процента нет: делить не на что ─► TARGETS <unknown>, ScalingActive=False
```

Схема 7. Метрика использования есть, но без requests процент не считается.

#### Шаг 1. Создать Deployment без requests и HPA

Команды создают Deployment без блока `resources` и HPA с целью 50 % CPU, а затем ждут 45 секунд, пока контроллер сделает первый расчёт.

```bash
kubectl create deploy noreq --image=localhost:5001/orders-api:2.0 --port=8000
cat > ~/lab/k8s/05-4/noreq-hpa.yaml <<'EOF'
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata: {name: noreq}
spec:
  scaleTargetRef: {apiVersion: apps/v1, kind: Deployment, name: noreq}
  minReplicas: 1
  maxReplicas: 5
  metrics:
  - type: Resource
    resource:
      name: cpu
      target: {type: Utilization, averageUtilization: 50}
EOF
kubectl apply -f ~/lab/k8s/05-4/noreq-hpa.yaml
sleep 45; kubectl get hpa noreq
```

| Часть команды | Значение |
|---|---|
| `create deploy noreq … --port=8000` | Deployment из одного пода без requests |
| `scaleTargetRef` | цель HPA — Deployment `noreq` |
| `averageUtilization: 50` | цель 50 % от requests пода |
| `sleep 45` | подождать первый цикл HPA и метрики |

Результат:

```
NAME    REFERENCE          TARGETS              MINPODS   MAXPODS   REPLICAS
noreq   Deployment/noreq   cpu: <unknown>/50%   1         5         1
```

Разбор:

1. `TARGETS` `cpu: <unknown>/50%` — слева текущая загрузка (её нет), справа цель.
2. `REPLICAS 1` — HPA ничего не меняет, пока не может посчитать.

#### Шаг 2. Прочитать условие с причиной

Команда печатает условия HPA в виде «тип=статус причина: сообщение».

```bash
CJ='{range .status.conditions[*]}{.type}={.status} {.reason}: {.message}{"\n"}{end}'
kubectl get hpa noreq -o jsonpath="$CJ"
```

| Часть команды | Значение |
|---|---|
| `CJ` и `-o jsonpath="$CJ"` | перебрать все условия |
| `{.type}={.status}` | имя и статус условия |
| `{.reason}: {.message}` | причина и текст ошибки |

Результат (сокращён до значимой строки):

```
ScalingActive=False FailedGetResourceMetric: the HPA was unable to compute the replica count: failed to get cpu utilization: missing request for cpu in container orders-api of Pod noreq-95cdd95d4-rz85h
```

Разбор:

1. `ScalingActive=False` — HPA не может работать.
2. `FailedGetResourceMetric` — ошибка при чтении метрики ресурса.
3. `missing request for cpu in container orders-api` — HPA называет контейнер, у которого нет requests. Имя пода у вас другое.

#### Шаг 3. Добавить requests и проверить результат

Команда задаёт requests CPU 100m, Deployment пересоздаёт под, и через минуту HPA читает метрики.

```bash
kubectl set resources deploy noreq --requests=cpu=100m
kubectl rollout status deploy/noreq
sleep 60; kubectl get hpa noreq
```

| Часть команды | Значение |
|---|---|
| `set resources … --requests=cpu=100m` | записать requests в шаблон пода |
| `rollout status` | дождаться нового пода |
| `sleep 60` | дать metrics-server собрать данные нового пода |

Ожидаемый результат (по документации; число процентов у вас будет другим):

```
NAME    REFERENCE          TARGETS            MINPODS   MAXPODS   REPLICAS
noreq   Deployment/noreq   cpu: <число>%/50%  1         5         1
```

Разбор: вместо `<unknown>` стоит число, потому что теперь есть знаменатель. Простаивающий под показывает единицы процентов, и реплика остаётся одна.

**Итог.**

| Что узнали | Где видно |
|---|---|
| Без requests процент загрузки не считается | шаг 1, `<unknown>` |
| Причину HPA пишет в условие `ScalingActive` | шаг 2, `FailedGetResourceMetric` |
| Достаточно добавить requests | шаг 3 |

**Уборка.** Удаляем HPA и Deployment этой работы.

```bash
kubectl delete hpa noreq
kubectl delete deploy noreq
rm -f ~/lab/k8s/05-4/noreq-hpa.yaml
```

**Вопросы для самопроверки.**

1. Почему HPA не работает, если requests есть у основного контейнера, но нет у sidecar?
2. Где HPA записывает причину, по которой не масштабирует?
3. Чем `ContainerResource` отличается от `Resource`?

<details>
<summary>Ответы</summary>

1. Для `Utilization` HPA суммирует requests всех контейнеров пода. Если хотя бы у одного их нет, процент для пода не считается.
2. В условиях `status.conditions` объекта HPA, главное из них — `ScalingActive`. Тот же текст виден в `describe hpa`.
3. `Resource` считает загрузку всего пода, `ContainerResource` — одного контейнера по имени, поэтому sidecar не влияет на результат.

</details>

---

### Лабораторная работа 2. HPA под нагрузкой и behavior

**Цель.** Измерить, как HPA растёт и сжимается с настройками по умолчанию, затем изменить `behavior` и сравнить скорость.

**Что понадобится.** Стенд 00-1, namespace `lab-05-4`, образы `orders-api:2.0` и `python:3.12-slim`, около 20 минут из-за ожидания масштабирования.

**Схема опыта.**

```
Pod load (6 потоков) ──► Service api ──► Deployment api (requests 100m) ◄── HPA api (1…8, 50 %)
                              /work?ms=40 жжёт CPU                          считает раз в 15 с
```

Схема 8. Под `load` бьёт в ручку `/work`, которая нагружает CPU, а HPA наблюдает за Deployment.

#### Шаг 1. Создать приложение и HPA

Команды записывают два манифеста: Deployment с Service и HPA на 1–8 реплик с целью 50 %.

```bash
cat > ~/lab/k8s/05-4/api.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata: {name: api}
spec:
  replicas: 1
  selector: {matchLabels: {app: api}}
  template:
    metadata: {labels: {app: api}}
    spec:
      containers:
      - name: api
        image: localhost:5001/orders-api:2.0
        ports: [{name: http, containerPort: 8000}]
        readinessProbe: {httpGet: {path: /ready, port: http}, periodSeconds: 2}
        resources: {requests: {cpu: 100m, memory: 32Mi}, limits: {memory: 128Mi}}
---
apiVersion: v1
kind: Service
metadata: {name: api}
spec:
  selector: {app: api}
  ports: [{port: 80, targetPort: http}]
EOF
cat > ~/lab/k8s/05-4/hpa.yaml <<'EOF'
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata: {name: api}
spec:
  scaleTargetRef: {apiVersion: apps/v1, kind: Deployment, name: api}
  minReplicas: 1
  maxReplicas: 8
  metrics:
  - type: Resource
    resource:
      name: cpu
      target: {type: Utilization, averageUtilization: 50}
EOF
kubectl apply -f ~/lab/k8s/05-4/api.yaml -f ~/lab/k8s/05-4/hpa.yaml
kubectl rollout status deploy/api
```

| Часть команды | Значение |
|---|---|
| `requests: {cpu: 100m …}` | знаменатель для процентов HPA |
| `limits: {memory: 128Mi}` | лимит памяти без лимита CPU, чтобы не было троттлинга (05-1) |
| `readinessProbe` с `periodSeconds: 2` | быстро включать новые поды в Service |
| `-f … -f …` | применить оба файла одной командой |

Результат:

```
deployment "api" successfully rolled out
```

Разбор: Deployment готов, HPA запущен. Пока нагрузки нет, реплика одна.

#### Шаг 2. Описать нагрузку и наблюдение

Нужны две функции оболочки. Функция `load` запускает под, который шлёт запросы в `/work?ms=40` шестью потоками. Функция `mon` раз в 5 секунд читает загрузку и число реплик и печатает строку при изменении. Функции живут в текущем окне терминала, поэтому все шаги работы выполняют в нём.

```bash
load() { kubectl run load --image=python:3.12-slim --command -- python -c "
import urllib.request, threading, time
def w():
    while True:
        try: urllib.request.urlopen('http://api/work?ms=40', timeout=5).read()
        except Exception: time.sleep(0.1)
for _ in range(6): threading.Thread(target=w, daemon=True).start()
time.sleep(100000)"; }
JP='{.status.currentMetrics[0].resource.current.averageUtilization}%'
JP="$JP desired={.status.desiredReplicas} current={.status.currentReplicas}"
# mon <секунд всего> <через сколько секунд снять нагрузку>
mon() { t0=$(date +%s); prev=""; stopped=0
  while [ $(( $(date +%s)-t0 )) -lt $1 ]; do t=$(( $(date +%s)-t0 ))
    if [ $stopped = 0 ] && [ $t -ge $2 ]; then
      kubectl delete pod load --now >/dev/null; echo "t=+${t}s LOAD STOPPED"; stopped=1
    fi
    s=$(kubectl get hpa api -o jsonpath="$JP")
    [ "$s" != "$prev" ] && echo "t=+${t}s cpu=$s" && prev=$s
    sleep 5
  done; }
```

| Часть команды | Значение |
|---|---|
| `kubectl run load … python -c` | под, который запускает Python с шестью потоками |
| `/work?ms=40` | ручка orders-api, которая 40 мс жжёт CPU |
| `JP` | шаблон jsonpath: загрузка, желаемые и текущие реплики |
| `mon 600 180` | наблюдать 600 с, на 180-й секунде удалить `load` |

Результат: вывода нет, функции только определены. Проверить можно командой `type mon | head -n 1`.

#### Шаг 3. Нагрузка с настройками по умолчанию

Команда запускает нагрузку и наблюдает десять минут; нагрузка снимается на 180-й секунде. Нагрузка выше, чем 8 реплик по 100m могут переварить, поэтому HPA упрётся в `maxReplicas`.

```bash
load; mon 600 180
```

Результат (сокращён):

```
t=+11s   cpu=% desired=0 current=1
t=+27s   cpu=1003% desired=4 current=1
t=+42s   cpu=1004% desired=8 current=4
t=+58s   cpu=687% desired=8 current=8
…
t=+184s  LOAD STOPPED
t=+239s  cpu=1% desired=8 current=8
t=+522s  cpu=1% desired=1 current=8
t=+538s  cpu=1% desired=1 current=1
```

Разбор:

1. До +27 с метрики нет, `desired=0`: первые данные приходят через окно metrics-server (около 15 с) и цикл HPA (15 с).
2. На +27 с один под показывает 1003 % — целое ядро при requests 100m. Формула даёт ceil(1 × 1003 / 50) = 21, потолок `maxReplicas` — 8, но политика роста позволяет только +4 за 15 с, поэтому `desired=4`.
3. На +42 с формула снова просит больше восьми (4 × 1004 / 50 ≈ 81), и разрешено +4: `desired=8`.
4. Нагрузку сняли на +184 с, а реплик всё ещё 8 на +239 с: окно `scaleDown` 300 с хранит максимальную рекомендацию.
5. До одной реплики сжатие дошло на +538 с, то есть через 354 с после остановки: 300 с окна и два цикла HPA. Затем сжатие идёт сразу до 1: политика падения по умолчанию — до 100 % за 15 с.

#### Шаг 4. Изменить behavior и повторить

Команда накладывает на HPA ограничение: рост не больше +2 пода за 30 с, падение не больше −50 % за 15 с с окном 30 с. Затем нагрузка запускается снова, и опыт длится 5 минут.

```bash
kubectl patch hpa api --type=merge -p '{"spec":{"behavior":{
  "scaleUp":{"stabilizationWindowSeconds":0,
             "policies":[{"type":"Pods","value":2,"periodSeconds":30}]},
  "scaleDown":{"stabilizationWindowSeconds":30,
               "policies":[{"type":"Percent","value":50,"periodSeconds":15}]}}}}'
load; kubectl wait --for=condition=Ready pod/load; mon 300 150
```

| Часть команды | Значение |
|---|---|
| `patch hpa api --type=merge` | добавить `behavior` в существующий HPA |
| `scaleUp … Pods 2 / 30` | не больше +2 пода за 30 с |
| `scaleDown … window 30` | окно сжатия 30 с вместо 300 |
| `scaleDown … Percent 50 / 15` | не больше −50 % за 15 с |
| `mon 300 150` | наблюдать 300 с, снять нагрузку на 150-й |

Результат (сокращён):

```
t=+32s  cpu=711% desired=3 current=1
t=+63s  cpu=776% desired=5 current=3
t=+90s  cpu=637% desired=7 current=5
t=+121s cpu=521% desired=8 current=7
t=+153s LOAD STOPPED
t=+213s cpu=1% desired=4 current=8
t=+224s cpu=1% desired=2 current=4
t=+239s cpu=1% desired=1 current=2
```

Разбор:

1. Рост идёт шагами по +2 (1 → 3 → 5 → 7 → 8): политика `Pods 2 / 30` работает.
2. Восьми реплик достигли на +121 с, а не на +58 с, как с настройками по умолчанию. Медленнее, но без скачка.
3. После остановки нагрузки на +153 с реплики сжимаются плавно: 8 → 4 → 2 → 1 вместо одного прыжка. До одной реплики прошло 86 с вместо 354 с.
4. Каждое сжатие вдвое — это политика `Percent 50 / 15`, а первая пауза в 60 с — окно 30 с плюс задержка метрик.

**Итог.**

| Что узнали | Где видно |
|---|---|
| Первая реакция HPA занимает около 25 с | шаг 3, +27 с |
| Рост по умолчанию ограничен +4 пода за 15 с | шаг 3, 1 → 4 → 8 |
| Сжатие по умолчанию ждёт 5 минут | шаг 3, 354 с |
| `behavior` управляет скоростью роста и спуска | шаг 4 |

**Уборка.** Удаляем HPA, приложение и нагрузку. Файлы манифестов остаются для работы 3.

```bash
kubectl delete -f ~/lab/k8s/05-4/hpa.yaml -f ~/lab/k8s/05-4/api.yaml
kubectl delete pod load --ignore-not-found --now
```

**Вопросы для самопроверки.**

1. Почему формула просила 21 реплику, а HPA поставил 4?
2. Почему после остановки нагрузки реплик по-прежнему 8 через минуту?
3. Что произойдёт при `selectPolicy: Disabled` в `scaleDown`?
4. Чем отличается окно стабилизации роста от окна падения?

<details>
<summary>Ответы</summary>

1. Желаемое число ограничено `maxReplicas` 8, а политика роста по умолчанию разрешает не больше +4 пода или +100 % за 15 с. С одной реплики это даёт 4.
2. Окно `scaleDown` по умолчанию 300 с: HPA берёт максимум рекомендаций за пять минут, чтобы не сжиматься на временном спаде.
3. Автоматическое сжатие выключено: реплики растут, но уменьшать их можно только вручную.
4. Для роста берётся минимальная рекомендация за окно (по умолчанию окно 0 с, рост сразу), для падения — максимальная (по умолчанию 300 с).

</details>

---

### Лабораторная работа 3. KEDA: cron и ноль подов

Установка KEDA тянет образы с `ghcr.io`, и у автора она заняла больше 5 минут. Результат шага 2 — реальный, а в шагах 1 и 3 строки ожидаемые.

**Риски.**

- Что меняется: в кластер ставятся Helm-релиз `keda` в namespace `keda`, CRD `keda.sh`, APIService `v1beta1.external.metrics.k8s.io` и admission-вебхуки. На хосте Helm добавляет репозиторий `kedacore` в свою конфигурацию.
- Надолго ли: до уборки этой работы.
- Безопасность и влияние: KEDA ставится с правами на чтение и изменение объектов Deployment во всём кластере. Чужие нагрузки она не трогает, пока на них нет ScaledObject. Образы идут с `ghcr.io`, версия закреплена (2.21.0).
- Откат: удаление релиза, namespace `keda` и CRD (см. «Уборка»).

**Цель.** Установить KEDA, настроить расписание, при котором вне окна подов ноль, и проследить, кто переводит 0 → 1 и 1 → 3.

**Что понадобится.** Стенд 00-1, Helm и доступ с узлов к `ghcr.io`. Нужен файл `~/lab/k8s/05-4/api.yaml` из работы 2; если его нет, создайте по шагу 1 работы 2. Работа занимает около 15 минут, из них до 10 на установку.

**Схема опыта.**

```
ScaledObject api (cron 2 мин) ──► оператор KEDA ──► Deployment api: 0 ⇄ 1
                                       │
                                       └──► keda-hpa-api (HPA) ──► Deployment api: 1 → 3
окно: [сейчас+2 мин … сейчас+4 мин] по Москве;  вне окна — 0 подов
```

Схема 9. Вне окна оператор держит Deployment на нуле, внутри включает под, а наращивает до 3 созданный им HPA.

#### Шаг 1. Установить KEDA 2.21.0

Команды подключают репозиторий чартов, ставят KEDA с закреплённой версией и ждут готовности всех подов.

```bash
helm repo add kedacore https://kedacore.github.io/charts
helm repo update kedacore
helm upgrade --install keda kedacore/keda --version 2.21.0 -n keda --create-namespace
kubectl -n keda wait --for=condition=Ready pod --all --timeout=600s
```

| Часть команды | Значение |
|---|---|
| `helm repo add kedacore …` | подключить репозиторий чартов KEDA |
| `upgrade --install … --version 2.21.0` | установить конкретную версию чарта |
| `-n keda --create-namespace` | отдельный namespace `keda` |
| `wait … --timeout=600s` | ждать до 10 минут, пока подтянутся образы |

Ожидаемый результат (суффиксы имён у вас другие):

```
pod/keda-admission-webhooks-… condition met
pod/keda-operator-… condition met
pod/keda-operator-metrics-apiserver-… condition met
```

Разбор: три пода — вебхуки, оператор и адаптер метрик. Если команда `wait` истекла, образы ещё скачиваются, и ей достаточно повторить запуск.

#### Шаг 2. Создать ScaledObject и наблюдать

Команды создают Deployment `api`, вычисляют окно (старт через 2 минуты, конец через 4) по московскому времени, создают ScaledObject и 6 минут печатают изменения. Команда `date -d` — это GNU date из Ubuntu и Manjaro.

```bash
kubectl apply -f ~/lab/k8s/05-4/api.yaml
S1=$(TZ=Europe/Moscow date -d '+2 min' +'%M %H')
E1=$(TZ=Europe/Moscow date -d '+4 min' +'%M %H')
kubectl apply -f - <<EOF
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata: {name: api}
spec:
  scaleTargetRef: {name: api}
  minReplicaCount: 0
  maxReplicaCount: 5
  cooldownPeriod: 30
  triggers:
  - type: cron
    metadata: {timezone: Europe/Moscow, start: "$S1 * * *", end: "$E1 * * *", desiredReplicas: "3"}
EOF
SO='{.status.conditions[?(@.type=="Active")].status}'
prev=""; for i in $(seq 1 72); do
  s="replicas=$(kubectl get deploy api -o jsonpath='{.spec.replicas}')"
  s="$s/ready=$(kubectl get deploy api -o jsonpath='{.status.readyReplicas}')"
  s="$s active=$(kubectl get scaledobject api -o jsonpath="$SO")"
  [ "$s" != "$prev" ] && echo "$(TZ=Europe/Moscow date +%H:%M:%S) $s" && prev=$s
  sleep 5
done
```

| Часть команды | Значение |
|---|---|
| `date -d '+2 min' +'%M %H'` | минута и час начала окна в формате cron |
| `minReplicaCount: 0` | вне окна подов ноль |
| `cooldownPeriod: 30` | ждать 30 с после конца окна перед сжатием до нуля |
| `type: cron … desiredReplicas: "3"` | в окне держать 3 пода |
| цикл на 72 итерации по 5 с | наблюдать 6 минут, печатать только изменения |

Результат:

```
14:15:57 replicas=0/ready= active=False
14:17:29 replicas=1/ready=1 active=True
14:17:41 replicas=3/ready=3 active=True
14:19:30 replicas=0/ready= active=False
```

Разбор:

1. `14:15:57` — окно ещё не началось, оператор сразу сжал Deployment до нуля: `replicas=0`.
2. `14:17:29` — окно началось (в 14:17), оператор включил один под: переход 0 → 1 делает сам оператор, `active=True`.
3. `14:17:41` — HPA, созданный KEDA, довёл число подов до трёх, это `desiredReplicas`.
4. `14:19:30` — окно закрылось в 14:19, прошло `cooldownPeriod` 30 с, и оператор вернул ноль.

#### Шаг 3. Посмотреть HPA, который создала KEDA

Команда показывает все HPA namespace с владельцем и целью.

```bash
kubectl get hpa -o custom-columns=NAME:.metadata.name,TARGET:.spec.scaleTargetRef.name,\
OWNER:.metadata.ownerReferences[0].kind
```

| Часть команды | Значение |
|---|---|
| `custom-columns=NAME:…` | вывести выбранные поля |
| `ownerReferences[0].kind` | вид объекта-владельца |

Ожидаемый результат (по документации KEDA):

```
NAME           TARGET   OWNER
keda-hpa-api   api      ScaledObject
```

Разбор: HPA создан и принадлежит ScaledObject, поэтому удалять или менять его вручную не нужно — KEDA вернёт его обратно. Ставить на этот Deployment свой HPA тоже нельзя: два контроллера будут бороться за `replicas` (§3).

**Итог.**

| Что узнали | Где видно |
|---|---|
| KEDA держит Deployment на нуле вне окна | шаг 2, `replicas=0` |
| Переход 0 → 1 делает оператор, 1 → 3 — HPA | шаг 2, 14:17:29 и 14:17:41 |
| Сжатие до нуля ждёт `cooldownPeriod` | шаг 2, 14:19:30 |
| HPA от KEDA принадлежит ScaledObject | шаг 3 |
| Встроенный HPA scale-to-zero (1.37 beta) не заменяет скейлеры KEDA | §2 |

**Уборка.** Удаляем ScaledObject и приложение, затем KEDA, её CRD и репозиторий Helm, потом namespace и каталог.

```bash
kubectl delete scaledobject api
kubectl delete -f ~/lab/k8s/05-4/api.yaml
helm -n keda uninstall keda
kubectl delete ns keda
kubectl get crd -o name | grep keda.sh | xargs -r kubectl delete
helm repo remove kedacore
kubectl config set-context --current --namespace=default
kubectl delete ns lab-05-4
rm -rf ~/lab/k8s/05-4
```

**Вопросы для самопроверки.**

1. Кто увеличивает число подов с 0 до 1, а кто с 1 до 3?
2. Почему на Deployment под управлением KEDA нельзя поставить свой HPA?
3. Что даёт HPA scale-to-zero, если у KEDA есть cron?
4. Почему scale-to-zero для HTTP-сервиса опасен без буфера запросов?

<details>
<summary>Ответы</summary>

1. 0 → 1 делает оператор KEDA. С 1 до 3 увеличивает HPA `keda-hpa-api`, который оператор создал по ScaledObject.
2. Оба контроллера пишут в `replicas` и перебивают друг друга, число подов скачет.
3. Встроенное сжатие до нуля не требует дополнительного оператора, но нужны функция `HPAScaleToZero` и метрика Object или External. KEDA даёт готовые скейлеры (cron, очереди) без своего адаптера.
4. Первый запрос после нуля попадает в Service, у которого ещё нет готовых подов, и получает ошибку. Нужен буфер запросов (KEDA HTTP add-on, Knative) или поднятый `minReplicaCount`.

</details>

---

## → Дальше

Автоскейлеры уменьшают число подов и узлов, а значит, вытесняют работающие поды: HPA при сжатии, VPA при смене requests, CA и Karpenter при освобождении узла. Все они упираются в одно: допустимо ли убрать этот под сейчас. Ответ даёт **PodDisruptionBudget** — бюджет прерываний, который 05-5 разбирает вместе с `kubectl drain` и вытеснением kubelet, и на нём опирается любая безопасная работа с узлами.
