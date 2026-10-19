# 05-5. Прерывания и вытеснение

> Модуль 05 «Ресурсы и планирование» · часть 5 из 5 · ~1,5 ч чтения + ~1 ч лабы · Нужно: стенд 00-1 (контекст `kind-lab`, узлы `lab-worker`, `lab-worker2`, `lab-worker3`), `jq` и Docker на хосте, доступ узлов к образам `python:3.12-slim` и `registry.k8s.io/pause:3.10` · Опирается на: 01-2 (kubelet), 02-2 (Deployment), 02-5 (остановка пода), 04-2 (local-тома), 05-1 (QoS, OOM), 05-2 (swap), 05-3 (приоритеты, taints), 05-4 (автоскейлеры)

## Где мы на карте

Эта часть закрывает модуль 05. Мы разобрали, сколько ресурсов просит под (05-1, 05-2) и куда его ставит scheduler (05-3), а теперь выясняем, как поды покидают узлы и кто это разрешает. Поды уходят с узла по двум причинам. Администратор или автоскейлер выводит узел на обслуживание, и тогда бюджет PodDisruptionBudget решает, сколько подов можно выселить одновременно. Либо узлу не хватает памяти или диска, и kubelet выселяет поды сам, не спрашивая бюджет.

Автоскейлеры из 05-4 выселяют поды тем же Eviction API, поэтому бюджет защищает сервис и от них. Часть разбирает `drain` целиком: обновление узлов в 10-4 ссылается сюда и не повторяет механику. Приоритеты и вытеснение со стороны scheduler (preemption) остались в 05-3, а завершение отдельного пода (SIGTERM, grace period) — в 02-5.

```
                      поды покидают узел
        ┌──────────────────────┴───────────────────────┐
   добровольно                                    недобровольно
   drain, автоскейлер, Eviction API               kubelet при нехватке ресурсов,
   │                                              отказ узла, OOM
   ▼                                              ▼
   PodDisruptionBudget проверяет                  бюджет не проверяется
   (§2, лабораторные 1 и 2)                       (§2, лабораторная 3)
```

Схема 1. Две ветки прерываний: PDB стоит только на добровольной, поэтому для второй ветки защитой служат requests и приоритеты.

---

## 1. Какую задачу решают бюджеты прерываний

Кластер постоянно убирает поды с узлов: обновляет узлы, сжимает группу, перезагружает машины. Бюджет прерываний отвечает на вопрос, сколько реплик сервиса можно убрать одновременно, чтобы сервис остался доступным. Разберём, какие бывают прерывания и кто их запускает.

### Добровольные и недобровольные прерывания

**Прерывание** (disruption) — любое событие, после которого под исчезает с узла не по воле его владельца. **Добровольное прерывание** (voluntary disruption) запускает человек или контроллер: `kubectl drain`, автоскейлер узлов, обновление группы узлов в облаке. **Недобровольное прерывание** (involuntary disruption) происходит само: отказ железа, паника ядра, исчезновение узла из сети, нехватка памяти на узле.

Бюджет защищает только от добровольных прерываний. Причина простая: проверить бюджет можно лишь там, где выселение проходит через API, а отказ узла никого не спрашивает. Удаление пода командой `kubectl delete pod`, rollout Deployment и удаление namespace бюджет тоже не проверяют: у Deployment собственный «бюджет» в поле `maxUnavailable` (02-2).

### Кто выселяет поды

**Выселение** (eviction) — завершение пода по решению компонента кластера, а не владельца пода. Источников несколько, и бюджет учитывают не все.

| Источник | Вид | Бюджет учитывается | Часть |
|---|---|---|---|
| `kubectl drain`, автоскейлер узлов | добровольное | да, всегда | эта |
| scheduler (preemption) | добровольное | по возможности, не гарантирует | 05-3 |
| kubelet при нехватке ресурсов | недобровольное | нет | эта |
| taint NoExecute при отказе узла | недобровольное | нет | 01-2, 05-3 |
| отказ узла, OOM ядра | недобровольное | нет | 05-1 |

Первая строка — главный сценарий части. Остальные показывают, где бюджет бессилен, поэтому для них нужны другие меры: правильные requests, приоритеты и резервы на узле.

В курсе «вытеснением» называют и preemption у scheduler (05-3), и node-pressure eviction у kubelet. Различайте их по тому, кто удаляет под: scheduler или kubelet.

### Что даёт бюджет

**PodDisruptionBudget** (PDB, бюджет прерываний) — объект, который задаёт, сколько подов из набора должны оставаться доступными при добровольных прерываниях. Он решает конфликт двух интересов: оператору нужно освободить узел, а сервису нужно сохранить достаточно реплик. Без бюджета `drain` выселит все реплики сервиса с узла сразу, и сервис пропадёт на время их пересоздания.

У бюджета есть и обратная сторона: слишком строгий бюджет не даёт освободить узел совсем. Такой бюджет блокирует обновление кластера, и с него начинаются почти все разборы в §5.

---

## 2. Как устроены бюджет, Eviction API, drain и вытеснение kubelet

Добровольное выселение складывается из трёх звеньев: бюджет хранит правило, **Eviction API** проверяет его, а `drain` вызывает проверку для каждого пода. Вытеснение kubelet работает отдельно и устроено по-другому.

### PodDisruptionBudget: бюджет и селектор

Бюджет состоит из селектора подов и одного из двух чисел: `minAvailable` (сколько подов должно остаться) или `maxUnavailable` (сколько можно убрать). Задать нужно ровно одно из них, значением служит число или процент. Проценты округляются вверх, и для подов нестандартных контроллеров они не работают, там годится только целое `minAvailable`. Пустой селектор `{}` выбирает все поды namespace, а отсутствующий — ни одного.

Контроллер бюджета в controller-manager пересчитывает **статус** бюджета по четырём числам.

- **expectedPods** — сколько подов должно быть: число реплик Deployment, StatefulSet или ReplicaSet либо число найденных подов.
- **currentHealthy** — сколько подов сейчас готовы (условие `Ready=True`).
- **desiredHealthy** — сколько должно быть готово: `minAvailable` либо `expectedPods − maxUnavailable`.
- **disruptionsAllowed** — сколько подов можно выселить сейчас: `currentHealthy − desiredHealthy`, но не меньше нуля.

```
Deployment web, replicas: 3, PDB minAvailable: 2

 expectedPods = 3     currentHealthy = 3     desiredHealthy = 2
                                     │
              disruptionsAllowed = 3 − 2 = 1   → выселить можно один под
```

Схема 2. Арифметика бюджета: при трёх готовых репликах и `minAvailable: 2` выселение разрешено для одного пода; пока он не станет Ready заново, бюджет равен нулю.

Для одной реплики и `minAvailable: 1` получается `1 − 1 = 0`: выселять нельзя никогда. Один под не может сохранить доступность, потому что его выселение и есть недоступность.

### Eviction API: проверка перед удалением

**Eviction API** — подресурс пода `pods/<имя>/eviction`, через который выселяют под вместо прямого удаления. Клиент отправляет на него POST с объектом `Eviction`. API-сервер находит бюджет пода, проверяет `disruptionsAllowed` и только после этого удаляет под, уважая его `terminationGracePeriodSeconds` и `preStop` (02-5).

Ответ зависит от результата проверки.

- **Успех** — код 200 или 201, под получил команду на остановку, а бюджет уменьшился на единицу.
- **429 Too Many Requests** — выселение нарушило бы бюджет. Клиент должен повторить запрос позже.
- **500** — ошибка настройки: на под нацелено несколько бюджетов сразу.

```
kubectl drain ──► POST pods/X/eviction ──► API-сервер: есть ли disruptionsAllowed > 0?
                                              │ да            │ нет
                                              ▼               ▼
                                         удалить под      429, повторить через 5 с
```

Схема 3. Eviction API стоит между клиентом и удалением; именно код 429 выглядит как «зависший» drain.

Поды в фазах Pending, Succeeded и Failed, а также поды, которые уже удаляются, API выселяет без проверки бюджета: их выселение не снижает доступность.

### Drain: cordon и выселение

**Cordon** — пометка узла как неподходящего для новых подов: поле `spec.unschedulable: true` и taint `node.kubernetes.io/unschedulable:NoSchedule`. Существующие поды остаются на месте. **Drain** — это cordon плюс выселение всех подов узла через Eviction API.

Порядок работы `kubectl drain` такой: пометить узел, отобрать поды, выселить каждый, дождаться удаления. При ответе 429 команда повторяет запрос каждые 5 секунд, пока не истечёт `--timeout`. По умолчанию таймаут равен нулю, то есть команда ждёт бесконечно. При ошибке `drain` не снимает cordon: узел остаётся недоступным для планирования.

При отборе подов `drain` отказывается трогать три группы и требует флагов. Первая группа — поды DaemonSet: контроллер вернёт их на тот же узел. Вторая — поды без контроллера, которые после выселения не вернутся. Третья — поды с `emptyDir`, чьи данные пропадут. Статические поды (static pods, 01-2) `drain` пропускает всегда: ими управляет kubelet по файлам, а в API лежит только их зеркальная копия.

### Вытеснение kubelet: сигналы и пороги

**Node-pressure eviction** (вытеснение по давлению) — выселение подов kubelet'ом, когда ресурсов узла остаётся меньше порога. Kubelet сверяет **сигналы** (eviction signals) — измеряемые значения ресурсов узла — с порогами раз в `housekeeping-interval`, по умолчанию каждые 10 секунд. Основных сигналов на Linux шесть: `memory.available`, `nodefs.available`, `nodefs.inodesFree`, `imagefs.available`, `imagefs.inodesFree` и `pid.available`. **nodefs** — файловая система с каталогами kubelet и логами, **imagefs** — файловая система образов и слоёв контейнеров. Ещё два сигнала, `containerfs.available` и `containerfs.inodesFree`, появляются только при разделённой файловой системе образов (feature gate `KubeletSeparateDiskGC`, пока только с CRI-O).

**Порог** (threshold) — значение сигнала, при котором kubelet начинает действовать. Порогов два вида.

- **Жёсткий** (`evictionHard`) — выселять сразу, с нулевым grace period, то есть под получает команду на остановку без ожидания.
- **Мягкий** (`evictionSoft`) — выселять, если сигнал ниже порога дольше `evictionSoftGracePeriod`. Под получает меньшее из двух значений: свой grace period или `evictionMaxPodGracePeriod`; если максимум не задан, kubelet убивает под сразу.

Жёсткие пороги по умолчанию на Linux такие: `memory.available` — 100Mi, `nodefs.available` — 10%, `nodefs.inodesFree` — 5%, `imagefs.available` — 15%, `imagefs.inodesFree` — 5%. Мягких порогов по умолчанию нет. Параметр `evictionMinimumReclaim` задаёт, сколько ресурса освободить сверх порога, чтобы узел не «дребезжал» на границе; по умолчанию он равен нулю.

```
сигнал memory.available:   ──────── норма ────────┬─── ниже порога ───►
                                                   │
                      порог evictionHard ──────────┘
                              │
        состояние узла MemoryPressure=True, taint memory-pressure:NoSchedule,
        kubelet выселяет по одному поду, пока сигнал не вернётся выше порога
```

Схема 4. Реакция на порог: сначала меняется состояние узла, затем выселяются поды, пока ресурса снова не хватает.

При срабатывании порога kubelet выставляет **условие узла** (node condition): `MemoryPressure`, `DiskPressure` или `PIDPressure`. Одновременно узел получает taint `node.kubernetes.io/memory-pressure:NoSchedule` или аналогичный, поэтому scheduler перестаёт ставить на него новые поды. Условие держится минимум 5 минут после выхода из давления: это значение `evictionPressureTransitionPeriod`, оно защищает от мигания. Control plane сам добавляет подам, которые не BestEffort, toleration на `memory-pressure`, поэтому новые BestEffort-поды на такой узел не попадают, а остальные попадают. Подам DaemonSet контроллер добавляет tolerations на все три вида давления.

При нехватке диска kubelet сначала освобождает ресурсы узла без выселения: удаляет мёртвые контейнеры и неиспользуемые образы. Выселение начинается, если этого мало.

### Порядок выселения и связь с allocatable

Для нехватки памяти kubelet сортирует поды по трём признакам по очереди и выселяет первого в списке.

1. Превышает ли потребление пода его request по этому ресурсу: превышающие идут первыми.
2. Приоритет пода (05-3): меньший приоритет выселяется раньше.
3. Насколько потребление превышает request: больше превышение — раньше.

QoS-класс (05-1) в порядке не участвует напрямую, но результат похож. У BestEffort request равен нулю, поэтому он почти всегда превышает request сильнее всех. Guaranteed не превышает request никогда, потому что лимит у него равен request. Под, который не вышел за свой request, выселяется в последнюю очередь, как и поды с критичным приоритетом.

Allocatable (05-1 §2) уже вычитает порог вытеснения. Здесь важна сама величина: это жёсткий порог `evictionHard`, и scheduler не отдаёт подам память, которую kubelet освободил бы выселением.

```
allocatable = capacity − kube-reserved − system-reserved − evictionHard
```

Схема 5. Жёсткий порог вычитается из allocatable: scheduler не займёт память, которую kubelet освободил бы выселением. Резервы `kube-reserved` и `system-reserved` по умолчанию равны нулю.

---

## 3. Как управлять прерываниями

Управление состоит из четырёх действий: задать бюджет, вывести узел, настроить пороги kubelet и включить корректное выключение узла. У каждого действия есть типичная ошибка, поэтому после манифеста идут правила.

### Задать бюджет

Команда создаёт бюджет для Deployment `web` с тремя репликами: можно убрать не больше одной реплики, а неготовые поды выселяются всегда.

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: web
spec:
  maxUnavailable: 1
  selector:
    matchLabels: {app: web}
  unhealthyPodEvictionPolicy: AlwaysAllow
```

Разбор:

| Поле | Значение |
|---|---|
| `maxUnavailable: 1` | одновременно недоступна не больше одна реплика |
| `selector` | поды, на которые действует бюджет |
| `unhealthyPodEvictionPolicy` | можно ли выселять неготовые поды (§5) |

Правила выбора значений:

- Берите `maxUnavailable: 1` вместо `minAvailable: N−1`: число недоступных не зависит от числа реплик и не превращается в ноль при масштабировании.
- Для сервиса с одной репликой бюджет не ставят: любое строгое значение блокирует drain. Нужна доступность — делайте две реплики.
- Для кворумных систем (etcd, ZooKeeper, Kafka) ставят `maxUnavailable: 1`, чтобы drain не унёс кворум.
- Во все бюджеты добавляйте `unhealthyPodEvictionPolicy: AlwaysAllow` (GA с 1.31), если нет причин поступить иначе.

Значение по умолчанию у этого поля — `IfHealthyBudget`: неготовый под выселяется, только если приложение не пострадает, то есть `currentHealthy ≥ desiredHealthy`. `AlwaysAllow` разрешает выселять неготовые поды в любом случае, потому что их выселение доступность не снижает.

### Вывести узел

Обслуживание узла идёт тремя командами: остановить планирование, освободить узел и вернуть его в строй. Перед drain полезно проверить, какие бюджеты уже равны нулю.

```bash
kubectl get pdb -A
kubectl drain NODE --ignore-daemonsets --delete-emptydir-data --timeout=120s
# работа на узле
kubectl uncordon NODE
```

| Часть команды | Значение |
|---|---|
| `get pdb -A` | бюджеты всех namespace; ищем `ALLOWED DISRUPTIONS` равный 0 |
| `drain NODE` | пометить узел и выселить поды |
| `--ignore-daemonsets` | пропустить поды DaemonSet |
| `--delete-emptydir-data` | разрешить выселять поды с `emptyDir` |
| `--timeout=120s` | остановиться через две минуты, а не ждать вечно |
| `uncordon NODE` | снять cordon, узел снова принимает поды |

Остальные флаги `drain` перечислены в таблице.

| Флаг | Что делает | Риск |
|---|---|---|
| `--force` | выселяет поды без контроллера | они не вернутся |
| `--grace-period=N` | заменяет grace period подов | под убивают раньше срока |
| `--disable-eviction` | удаляет поды вместо выселения | обходит бюджет |
| `--pod-selector=…` | выселяет только поды по метке | нет |
| `--dry-run=server` | показывает, что было бы выселено | нет |

Единственный по-настоящему опасный флаг — `--disable-eviction`: он делает ровно то, от чего бюджет защищал. Автоскейлеры узлов тоже используют Eviction API и уважают бюджеты; чтобы не трогать конкретный под, у Cluster Autoscaler есть аннотация `cluster-autoscaler.kubernetes.io/safe-to-evict: "false"`, а у Karpenter — `karpenter.sh/do-not-disrupt: "true"`.

### Настроить пороги kubelet

Пороги и резервы задаются в конфигурации kubelet (`KubeletConfiguration`), на узлах kubeadm она лежит в `/var/lib/kubelet/config.yaml`. После правки kubelet перезапускают, а контейнеры подов при этом продолжают работать. Пример ниже показывает форму полей, значения подбирают под узел.

```yaml
evictionHard:
  memory.available: "200Mi"
  nodefs.available: "10%"
evictionSoft:
  memory.available: "500Mi"
evictionSoftGracePeriod:
  memory.available: "1m30s"
evictionMinimumReclaim:
  memory.available: "100Mi"
kubeReserved: {cpu: 100m, memory: 200Mi}
systemReserved: {cpu: 100m, memory: 200Mi}
```

Разбор:

1. Жёсткий порог 200Mi: ниже него kubelet выселяет сразу.
2. Мягкий порог 500Mi с паузой 1 минута 30 секунд даёт подам время успокоить нагрузку.
3. Для каждого мягкого порога обязателен свой `evictionSoftGracePeriod`.
4. `evictionMinimumReclaim` не даёт узлу сразу вернуться под порог.
5. Резервы оставляют память и CPU kubelet'у и системным службам; без них узел «встаёт в ноль» из-за системных процессов, а не из-за подов.

### Включить корректное выключение узла

**Graceful node shutdown** — режим, в котором kubelet при выключении узла сам останавливает поды по порядку, а не умирает вместе с ними. Для этого kubelet берёт у systemd **блокировку задержки** (delay inhibitor lock) и успевает остановить контейнеры, пока система ждёт. Режим включают двумя полями.

```yaml
shutdownGracePeriod: 30s
shutdownGracePeriodCriticalPods: 10s
```

Первое поле задаёт общее время на выключение, второе — часть этого времени, зарезервированную для критичных подов. Здесь обычные поды получают 20 секунд, а критичные — последние 10. Поле `shutdownGracePeriodByPodPriority` делит время по приоритетам подов точнее.

Значения по умолчанию — `0s`, и режим выключен: при перезагрузке узла kubelet не участвует в остановке, поэтому preStop и grace period подов не соблюдаются. Задержку ограничивает параметр logind `InhibitDelayMaxSec`. На Ubuntu пакет unattended-upgrades задаёт его равным 30 секундам, и при `shutdownGracePeriod` больше 30 секунд kubelet не получает блокировку.

Если узел выключился без предупреждения и kubelet ничего не успел сообщить, поды висят в состоянии Terminating, а тома не отсоединяются. Оператор, убедившись, что узел выключен, ставит taint `node.kubernetes.io/out-of-service=nodeshutdown:NoExecute` (GA с 1.28): поды удаляются принудительно, тома отсоединяются. Ставить taint на живой узел нельзя, иначе два экземпляра приложения запишут в один том.

---

## 4. Как увидеть состояние

Состояние прерываний видно в четырёх местах: в статусе бюджета, в узле, в событиях и в метриках. Начинают с бюджета, потому что именно его нулевое значение чаще всего объясняет зависший drain.

### Бюджет

Команда показывает все бюджеты namespace и сколько подов можно выселить прямо сейчас.

```bash
kubectl get pdb
```

Результат для трёх реплик `web` с `minAvailable: 2` и одной реплики `single` с `minAvailable: 1`:

```
NAME     MIN AVAILABLE   MAX UNAVAILABLE   ALLOWED DISRUPTIONS
single   1               N/A               0
web      2               N/A               1
```

Что в выводе:

1. `single` — `ALLOWED DISRUPTIONS` равен нулю: выселить под нельзя никогда.
2. `web` — разрешено выселить один под из трёх.
3. Колонка `N/A` показывает, что второе поле бюджета не задано.

Точные числа статуса (`currentHealthy`, `desiredHealthy`, `expectedPods`) выводит `kubectl get pdb NAME -o yaml`, раздел `status`. В Prometheus бюджет отдаёт kube-state-metrics: метрика `kube_poddisruptionbudget_status_pod_disruptions_allowed` показывает бюджеты с нулём.

### Узел во время обслуживания

Команда показывает узлы и признак cordon.

```bash
kubectl get nodes
kubectl get node lab-worker -o jsonpath='{.spec.unschedulable}{"\n"}'
```

Что смотреть: у cordon'нутого узла в колонке STATUS стоит `Ready,SchedulingDisabled`, а `jsonpath` выводит `true`. Taints узла видны в `kubectl describe node`. Поды, которые ждут места после drain, показывают причину в событиях: `kubectl get events --field-selector reason=FailedScheduling`.

### Давление на узле

Давление видно в условиях узла, в статистике kubelet и в событиях. Команда ниже читает условия и свободную память по данным самого kubelet.

```bash
kubectl describe node lab-worker3 | grep -A6 Conditions
kubectl get --raw /api/v1/nodes/lab-worker3/proxy/stats/summary | jq '.node.memory'
```

Что смотреть: в условиях строка `MemoryPressure True` означает, что порог пройден. В статистике поле `availableBytes` — это тот же сигнал `memory.available`, по которому kubelet принимает решение. В журнале kubelet (`journalctl -u kubelet` на узле) решение о выселении записано словами «eviction manager». Счётчик выселений по сигналам — метрика kubelet `kubelet_evictions`.

PSI (05-1 §4) ведётся не только для cgroup, но и для всего узла: файлы `/proc/pressure/cpu`, `/proc/pressure/memory` и `/proc/pressure/io`. Строки `some` и `full` читаются так же, как в 05-1. Kubelet отдаёт PSI контейнеров метриками (GA с 1.36) и не использует PSI для выселения. Для практики это значит: рост `memory.pressure` показывает нехватку памяти до того, как `memory.available` дойдёт до порога.

### Кто и почему выселен

Выселенный kubelet'ом под получает фазу `Failed` и причину `Evicted`; в `kubectl get pods` он выглядит как `Evicted` или `ContainerStatusUnknown`. Причина записана в поле `status.message`.

```bash
kubectl get pods \
  -o jsonpath='{range .items[*]}{.metadata.name}: {.status.phase}/{.status.reason}{"\n"}{end}'
kubectl get events --field-selector reason=Evicted
```

Что смотреть: сообщение содержит порог, фактический остаток ресурса и потребление пода относительно его request. Пример из лабораторной работы 3 приведён там.

---

## 5. Что ломается и как найти причину

Поломки делятся на две группы: бюджет блокирует обслуживание или kubelet выселяет не тех. В обоих случаях диагностика идёт от симптома к числу в статусе.

### Drain завис

Симптом: `kubectl drain` повторяет `Cannot evict pod as it would violate the pod's disruption budget`. Причина — `ALLOWED DISRUPTIONS` равен нулю. Команда `kubectl get pdb -A` покажет такие бюджеты, а три причины перебирают по порядку.

1. Единственная реплика с `minAvailable: 1`: бюджет нулевой всегда.
2. `minAvailable` равен числу реплик или больше: так бывает после масштабирования вниз.
3. Часть реплик не Ready: `currentHealthy` ниже `desiredHealthy`.

Лечение зависит от причины: поправить бюджет, добавить реплику или починить сервис. Обход через `--disable-eviction` — крайняя мера, которая лишает бюджет смысла. Без `--timeout` drain висит часами; управляемые группы узлов облака ждут свой лимит, а затем удаляют узел принудительно вместе с подами, которым бюджет «гарантировал» доступность.

### Нездоровые поды блокируют выселение

Если все поды сервиса не Ready (сломанный релиз, CrashLoop), то `currentHealthy` равен нулю и `disruptionsAllowed` равен нулю. Политика по умолчанию `IfHealthyBudget` запрещает выселять такие поды, потому что приложение уже ниже бюджета. В итоге drain узла висит из-за сервиса, который и так не работает. Политика `AlwaysAllow` снимает ловушку: неготовые поды выселяются независимо от бюджета. Лабораторная работа 2 показывает оба ответа API.

### Узел с локальными данными

Под, который держит `local-path` том, привязан к узлу через node affinity тома (04-2): PV существует только на этом узле. После drain такой под остаётся Pending, потому что другие узлы не подходят, а текущий закрыт cordon'ом. Для PostgreSQL стенда это означает простой до возвращения узла. Поэтому у баз на локальных томах работают так: реплика на другом узле, бюджет, который не даёт выселить primary, и порядок «сначала переключить primary, потом drain».

### Вытеснение kubelet без предупреждения

Вытеснение недобровольное, поэтому бюджет его не останавливает. Под выселяют, если он превысил request и узлу не хватило ресурса; под в пределах request выселяют последним. Три вывода для практики:

- Выселенный голый под не вернётся, а под контроллера пересоздаётся на другом узле.
- Объекты выселенных подов остаются в статусе `Failed`, пока их не удалит сборщик мусора (порог по умолчанию — 12 500 завершённых подов в кластере). Вычистить их в namespace можно командой `kubectl delete pod --field-selector=status.phase=Failed`.
- Если память растёт быстрее, чем kubelet успевает выселять, вмешивается OOM killer ядра (05-1): он убивает процессы по `oom_score_adj`, без учёта бюджетов и порогов.

Защита от лишних выселений состоит из правильных requests, приоритетов (05-3) и резервов `kube-reserved` и `system-reserved`.

---

## 6. Пределы и значения по умолчанию

Прерывания подчиняются нескольким числам, и все они задаются явно. Сначала сведём значения по умолчанию, затем разберём особенности стенда и влияние swap.

### Значения по умолчанию

Таблица собирает числа, которые определяют поведение drain и вытеснения.

| Параметр | По умолчанию | Где задаётся |
|---|---|---|
| `drain --timeout` | 0s (ждать бесконечно) | kubectl |
| повтор eviction при 429 | каждые 5 с | kubectl |
| `unhealthyPodEvictionPolicy` | IfHealthyBudget | PDB |
| `memory.available` | 100Mi | kubelet, жёсткий порог |
| `nodefs.available` | 10% | kubelet, жёсткий порог |
| `nodefs.inodesFree` | 5% | kubelet, жёсткий порог |
| `imagefs.available` | 15% | kubelet, жёсткий порог |
| `imagefs.inodesFree` | 5% | kubelet, жёсткий порог |
| мягкие пороги | не заданы | kubelet, evictionSoft |
| `evictionMinimumReclaim` | 0 | kubelet |
| `evictionMaxPodGracePeriod` | 0 (убить сразу) | kubelet |
| проверка порогов | каждые 10 с | kubelet, интервал проверки |
| `evictionPressureTransitionPeriod` | 5 минут | kubelet |
| `kube-reserved`, `system-reserved` | 0 | kubelet |
| `shutdownGracePeriod` | 0s | kubelet |
| порог GC завершённых подов | 12 500 | controller-manager |

Версии: политика `unhealthyPodEvictionPolicy` стала GA в 1.31, taint `out-of-service` — в 1.28. В Kubernetes 1.37 появилась alpha-функция условий узла для обслуживания (node lifecycle conditions), на стенд она не берётся.

### Особенности kind

Стенд kind отличается от прода тремя вещами. Конфигурация kubelet задаёт пороги диска `0%`, и тогда kubelet обнуляет остальные пороги, включая память (00-1). Сохранить значения по умолчанию для незаданных порогов позволяет поле `mergeDefaultEvictionSettings: true`, но kind его не задаёт. Пока порог не задан вручную, kubelet на узле не выселяет никого. 

Кроме того, kubelet в контейнере-узле считает `memory.available` от лимита своего контейнера, то есть от всей памяти хоста. Он видит 15–16 ГБ свободными, даже когда на хосте свободно 8 ГБ. Узлы kind не видят давления хоста, а на VM и железе сигнал честный. 

Наконец, graceful shutdown выключен: оба поля равны `0s`. При остановке контейнера узла kubelet не останавливает поды по порядку, поэтому в лабораторных работах этот режим только описан.

### Swap и вытеснение

Swap (05-2) на узле включается вручную: нужны `failSwapOn: false` и `memorySwap.swapBehavior: LimitedSwap`, и тогда его получают только поды класса Burstable.

Для вытеснения это важно: память, ушедшая в swap, уходит из рабочего множества пода, поэтому сигнал `memory.available` падает позже. Kubelet выселяет с запозданием, а узел к тому времени уже тормозит из-за обращений к диску. Поэтому на узлах со swap следите за PSI (§4), а не только за порогами.

---

## Лабораторные работы

Работы идут на стенде 00-1 в namespace `lab-05-5`. Работы выполняют по порядку. Работа 1 выводит из строя узел `lab-worker` на несколько минут, а работа 3 временно меняет конфигурацию kubelet на `lab-worker3`: прочитайте блоки «Риски» до начала.

Хост работы не меняют, кроме текущего namespace в `~/.kube/config`; его возвращает уборка последней, третьей работы. Образы узлы тянут из реестра стенда (`localhost:5001/orders-api:2.0`) и из интернета (`registry.k8s.io/pause:3.10`, `python:3.12-slim`).

Кластер готовят один раз: выбирают контекст стенда, создают namespace, делают его текущим и каталог для файлов.

```bash
kubectl config use-context kind-lab
kubectl create ns lab-05-5
kubectl config set-context --current --namespace=lab-05-5
mkdir -p ~/lab/k8s/05-5
```

| Часть команды | Значение |
|---|---|
| `use-context kind-lab` | работать с кластером стенда, а не с рабочим |
| `create ns lab-05-5` | создать namespace с именем части |
| `set-context --current` | изменить текущий контекст kubectl |
| `mkdir -p ~/lab/k8s/05-5` | каталог для файлов работ |

Результат:

```
Switched to context "kind-lab".
namespace/lab-05-5 created
Context "kind-lab" modified.
```

Разбор:

1. Контекст переключён на стенд, поэтому команды не попадут в рабочий кластер.
2. Namespace `lab-05-5` создан и пока пуст.
3. Дальше команды без `-n` попадают в `lab-05-5`.

### Лабораторная работа 1. Drain и PDB

**Риски.** Работа выводит узел из эксплуатации и останавливает PostgreSQL стенда.

- **Что меняется:** узел `lab-worker` получает cordon и освобождается от подов; `postgres-0` остаётся без узла, и orders-api отвечает ошибкой.
- **Надолго ли:** до `uncordon` в шаге 5; на стенде автора простой занял около 2 секунд после снятия cordon.
- **Безопасность:** привилегии администратора кластера; привилегированных контейнеров нет.
- **Влияние на систему:** простой `orders` на 1–2 минуты, поды из других namespace с узла переезжают на другие узлы.
- **Откат:** `kubectl uncordon lab-worker`; при зависании проверьте `kubectl -n orders get pods` и `kubectl get nodes`. Если `orders` не поднялся, выполните `kubectl apply -f ~/lab/k8s/orders-api/k8s/`.

**Цель.** Вывести узел из работы командой `drain`, увидеть, как бюджет останавливает выселение, и измерить, что происходит с PostgreSQL на local-томе.

**Что понадобится.**

- Стенд 00-1 с namespace `orders`: PostgreSQL (`postgres-0`) на `lab-worker` (проверим в шаге 1).
- Namespace `lab-05-5` из подготовки.
- Около 45 минут.

**Схема опыта.**

```
lab-worker                         lab-worker2
  web (1-2 пода)  PDB web: min 2     web (1-2 пода)
  single          PDB single: min 1  ← бюджет 0, выселить нельзя
  bare            без контроллера
  postgres-0      local-том (orders) ← привязан к узлу
```

Схема 6. Расположение подов на момент drain: `single` блокирует выселение, `bare` требует `--force`, `postgres-0` не сможет переехать.

На `lab-worker` и `lab-worker2` живут три реплики `web` с бюджетом 2, на `lab-worker` — единственный под `single` с бюджетом 1 и голый под `bare`. Drain выселяет поды по очереди и упирается в `single`.

#### Шаг 1. Создать нагрузку и бюджеты

Команда создаёт Deployment `web` из трёх реплик с бюджетом 2, Deployment `single` из одной реплики с бюджетом 1 и голый под `bare`. Затем она показывает, где что запущено.

```bash
kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata: {name: web}
spec:
  replicas: 3
  selector: {matchLabels: {app: web}}
  template:
    metadata: {labels: {app: web}}
    spec:
      terminationGracePeriodSeconds: 5
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - {key: kubernetes.io/hostname, operator: In, values: [lab-worker, lab-worker2]}
      containers:
      - name: c
        image: localhost:5001/orders-api:2.0
        readinessProbe:
          httpGet: {path: /ready, port: 8000}
          periodSeconds: 2
          initialDelaySeconds: 3
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata: {name: web}
spec:
  minAvailable: 2
  selector: {matchLabels: {app: web}}
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: single}
spec:
  replicas: 1
  selector: {matchLabels: {app: single}}
  template:
    metadata: {labels: {app: single}}
    spec:
      nodeSelector: {kubernetes.io/hostname: lab-worker}
      containers:
      - {name: c, image: "registry.k8s.io/pause:3.10"}
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata: {name: single}
spec:
  minAvailable: 1
  selector: {matchLabels: {app: single}}
EOF
kubectl rollout status deploy/web
kubectl rollout status deploy/single
kubectl run bare --image=registry.k8s.io/pause:3.10 \
  --overrides='{"spec":{"nodeName":"lab-worker"}}'
kubectl get pdb
kubectl -n orders get pods -o wide
```

| Часть команды | Значение |
|---|---|
| `values: [lab-worker, lab-worker2]` | реплики `web` только на этих двух узлах |
| `minAvailable: 2` | у `web` из трёх подов должны остаться два |
| `nodeSelector` у `single` | единственный под строго на `lab-worker` |
| `--overrides='{"spec":{"nodeName":…}}'` | поставить `bare` на `lab-worker` в обход scheduler |
| `get pods -o wide` в `orders` | узнать, где работает `postgres-0` |

Результат:

```
NAME     MIN AVAILABLE   MAX UNAVAILABLE   ALLOWED DISRUPTIONS
single   1               N/A               0
web      2               N/A               1
```

Разбор:

1. Бюджет `single` равен нулю: один под не может сохранить доступность при выселении.
2. Бюджет `web` равен единице: из трёх готовых подов можно выселить один, потому что два останутся.
3. В выводе `kubectl -n orders get pods -o wide` найдите узел `postgres-0`. Работа рассчитана на `lab-worker`. Если база на другом узле, подставьте его имя во все команды работы.

#### Шаг 2. Выполнить drain без флагов

Команда пытается освободить `lab-worker` без разрешающих флагов. Drain откажется, но cordon он успеет поставить.

```bash
kubectl drain lab-worker --timeout=20s
kubectl get node lab-worker \
  -o jsonpath='unschedulable after refused drain: {.spec.unschedulable}{"\n"}'
```

| Часть команды | Значение |
|---|---|
| `drain lab-worker` | пометить узел и выселить поды |
| `--timeout=20s` | сдаться через 20 секунд |
| `jsonpath='…{.spec.unschedulable}'` | прочитать признак cordon |

Результат (служебные строки между первой и третьей опущены):

```
node/lab-worker cordoned
…
cannot delete DaemonSet-managed Pods (use --ignore-daemonsets to ignore): kube-system/kindnet-…, …
cannot delete Pods that declare no controller (use --force to override): lab-05-5/bare
unschedulable after refused drain: true
```

Разбор:

1. Первая строка показывает, что узел помечен до проверки подов.
2. Drain отказался: поды DaemonSet (`kindnet`, `kube-proxy`) нельзя выселять без флага.
3. Голый под `bare` не вернётся после удаления, поэтому нужен `--force`.
4. Последняя строка подтверждает: после отказа узел остался cordon'нутым.

#### Шаг 3. Выполнить drain с флагами и упереться в бюджет

Команда разрешает пропуск DaemonSet, удаление emptyDir и поды без контроллера, ограничивает время 45 секундами и сворачивает повторяющиеся строки.

```bash
kubectl drain lab-worker --ignore-daemonsets --delete-emptydir-data --force \
  --timeout=45s 2>&1 | grep -vE '^evicting pod|^pod/' | sort | uniq -c
kubectl get pods -o wide
```

| Часть команды | Значение |
|---|---|
| `--ignore-daemonsets` | пропустить поды DaemonSet |
| `--delete-emptydir-data` | разрешить выселять поды с emptyDir |
| `--force` | удалить поды без контроллера |
| `2>&1 \| grep -vE … \| sort \| uniq -c` | убрать однотипные строки и посчитать повторы |

Результат (оставлены две значимые строки, вывод `kubectl get pods` описан в разборе):

```
      9 error when evicting pods/"single-674944c7bd-zkjjs" -n "lab-05-5" (will retry after 5s): …
      1 error: unable to drain node "lab-worker" due to error: … global timeout reached: 45s
```

Разбор:

1. Девять повторов: drain каждые 5 секунд повторял выселение пода `single` и получал отказ из-за бюджета.
2. Последняя строка: через 45 секунд он сдался, потому что в команде задан `--timeout`. Без него команда висела бы бесконечно.
3. Поды `web` на `lab-worker` выселены и пересозданы на `lab-worker2`, а `bare` удалён навсегда. Под `single` остался на месте.

#### Шаг 4. Посмотреть, что стало с PostgreSQL

Команда показывает `orders`, причину в событии и ответ приложения.

```bash
kubectl -n orders get pods
curl -s -o /dev/null -w 'orders api: %{http_code}\n' http://orders.localhost:8088/api/orders
kubectl -n orders get events \
  --field-selector involvedObject.name=postgres-0,reason=FailedScheduling \
  -o jsonpath='{.items[-1:].message}{"\n"}'
```

| Часть команды | Значение |
|---|---|
| `curl -w '%{http_code}'` | напечатать только код ответа |
| `orders.localhost:8088` | вход в стенд через Gateway (00-1) |
| `reason=FailedScheduling` | события, где scheduler не нашёл узел |
| `{.items[-1:].message}` | текст последнего такого события |

Результат (строки сокращены до значимых):

```
orders/postgres-0   Pending
orders api: 503
0/4 nodes are available: 1 node(s) had untolerated taint(s), 1 node(s) were unschedulable,
2 node(s) didn't match PersistentVolume's node affinity.
```

Разбор:

1. `postgres-0` остался в Pending: бюджета у него нет, поэтому его выселили.
2. Сообщение называет три причины: один узел занят taint'ом (control-plane), один закрыт cordon'ом, два не подходят по node affinity тома.
3. Том local-path привязан к `lab-worker` (04-2), а узел закрыт, поэтому базе некуда встать.
4. orders-api отвечает 503, пока база недоступна.

#### Шаг 5. Вернуть узел и измерить простой

Команда снимает cordon и считает секунды до первого ответа 200.

```bash
t0=$(date +%s); kubectl uncordon lab-worker
until [ "$(curl -s -o /dev/null -w '%{http_code}' \
  http://orders.localhost:8088/api/orders)" = 200 ]; do sleep 1; done
echo "200 after $(( $(date +%s)-t0 ))s"
```

| Часть команды | Значение |
|---|---|
| `t0=$(date +%s)` | запомнить время начала |
| `uncordon lab-worker` | снять cordon |
| `until … = 200` | опрашивать API раз в секунду, пока не придёт 200 |

Результат:

```
node/lab-worker uncordoned
200 after 2s
```

Разбор:

1. Узел снова принимает поды, и `postgres-0` встаёт на свой узел.
2. На стенде автора ответ 200 вернулся через 2 секунды.
3. Простой длился всё время, пока узел был закрыт: drain узла с локальными данными — это простой, а не перенос.

**Итог.**

| Что узнали | Где видно |
|---|---|
| Drain без флагов отказывает, но ставит cordon | `unschedulable after refused drain: true` |
| Бюджет 0 держит drain до таймаута | девять повторов с отказом |
| Поды без контроллера требуют `--force` и не возвращаются | `bare` удалён |
| Узел с local-томом даёт простой | `Pending` и `503` |

**Уборка.** Удаляем нагрузку работы. Узел уже раскрыт в шаге 5, поэтому проверяем его состояние и `orders`.

```bash
kubectl delete deploy web single
kubectl delete pdb --all
kubectl delete pod bare --now --ignore-not-found
kubectl get nodes
kubectl -n orders get pods
```

Ожидаемый результат: четыре узла в состоянии `Ready` без `SchedulingDisabled`, `postgres-0` в `Running`. Если `orders` не поднялся, выполните `kubectl apply -f ~/lab/k8s/orders-api/k8s/`.

**Вопросы для самопроверки.**

1. Почему отказавший drain оставляет узел cordon'нутым и что с этим делать?
2. Почему бюджет `minAvailable: 1` для одной реплики блокирует drain навсегда?
3. Почему `postgres-0` не переехал на другой узел?

<details>
<summary>Ответы</summary>

1. Cordon ставится до выселения и не снимается при ошибке. После разбора причины узел возвращают командой `kubectl uncordon`, а если причина устранена — повторяют drain.
2. Допустимое число выселений равно `currentHealthy − desiredHealthy`, то есть `1 − 1 = 0`. Eviction API отвечает 429, и drain повторяет запрос каждые 5 секунд до таймаута.
3. PV типа local-path привязан к узлу через node affinity. На других узлах тома нет, а текущий узел закрыт cordon'ом, поэтому под остаётся Pending до `uncordon`.

</details>

### Лабораторная работа 2. PDB и нездоровые поды

**Цель.** Показать, что бюджет с политикой по умолчанию не даёт выселить даже неработающие поды, и снять блокировку политикой `AlwaysAllow`.

**Что понадобится.**

- Стенд 00-1, namespace `lab-05-5`.
- Образ `localhost:5001/orders-api:2.0`.
- Около 20 минут.

**Схема опыта.**

```
sick-1, sick-2: Running, но не Ready (проба /nope → 404)
        currentHealthy = 0 < desiredHealthy = 1  →  disruptionsAllowed = 0

политика IfHealthyBudget (по умолчанию): evict → 429
политика AlwaysAllow:                    evict → успех
```

Схема 7. Одно и то же выселение дважды: до и после смены политики.

Deployment `sick` из двух подов, у которых проба готовности всегда падает. Бюджет `minAvailable: 1` не выполняется с самого начала, и мы запрашиваем выселение напрямую через Eviction API.

#### Шаг 1. Создать нездоровый сервис с бюджетом

Команда создаёт Deployment `sick` с проверкой готовности на несуществующий путь и бюджет на него, ждёт 15 секунд и показывает бюджет.

```bash
kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata: {name: sick}
spec:
  replicas: 2
  selector: {matchLabels: {app: sick}}
  template:
    metadata: {labels: {app: sick}}
    spec:
      terminationGracePeriodSeconds: 1
      containers:
      - name: c
        image: localhost:5001/orders-api:2.0
        readinessProbe:
          httpGet: {path: /nope, port: 8000}
          periodSeconds: 2
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata: {name: sick}
spec:
  minAvailable: 1
  selector: {matchLabels: {app: sick}}
EOF
sleep 15; kubectl get pdb sick
```

| Часть команды | Значение |
|---|---|
| `path: /nope` | путь, которого нет в приложении: проба получает 404 |
| `terminationGracePeriodSeconds: 1` | быстрое завершение подов |
| `minAvailable: 1` | должен остаться один готовый под |

Ожидаемый результат (по документации, в старой версии работы вывод этого шага не сохранился):

```
NAME   MIN AVAILABLE   MAX UNAVAILABLE   ALLOWED DISRUPTIONS
sick   1               N/A               0
```

Разбор:

1. Оба пода Running, но не Ready, поэтому `currentHealthy` равен нулю.
2. `ALLOWED DISRUPTIONS` равен нулю: бюджет уже «нарушен», и выселять нечего.

#### Шаг 2. Выселить под при политике по умолчанию

Функция формирует объект `Eviction` для первого пода `sick` и отправляет его на подресурс `eviction`.

```bash
ev() {
  V=$(kubectl get pods -l app=sick -o jsonpath='{.items[0].metadata.name}')
  echo "{\"apiVersion\":\"policy/v1\",\"kind\":\"Eviction\",\
\"metadata\":{\"name\":\"$V\",\"namespace\":\"lab-05-5\"}}" > ~/lab/k8s/05-5/ev.json
  kubectl create --raw /api/v1/namespaces/lab-05-5/pods/$V/eviction \
    -f ~/lab/k8s/05-5/ev.json
  echo
}
ev
```

| Часть команды | Значение |
|---|---|
| `V=$(kubectl get pods …)` | имя первого пода `sick` |
| `"kind":"Eviction"` | тело запроса к Eviction API |
| `create --raw …/eviction` | отправить POST на подресурс пода |
| `-f ev.json` | файл с телом запроса |

Результат:

```
Error from server (TooManyRequests): Cannot evict pod as it would violate the pod's
disruption budget.
```

Разбор:

1. Код `TooManyRequests` — это ответ 429 на нарушение бюджета.
2. Под неработающий, но выселить его нельзя: бюджет считает здоровыми только Ready-поды, а `IfHealthyBudget` защищает приложение, которое уже ниже бюджета.

#### Шаг 3. Включить AlwaysAllow и повторить

Команда меняет политику бюджета на лету и повторяет выселение той же функцией.

```bash
kubectl patch pdb sick -p '{"spec":{"unhealthyPodEvictionPolicy":"AlwaysAllow"}}'
ev
kubectl get pdb sick -o jsonpath=\
'currentHealthy={.status.currentHealthy} allowed={.status.disruptionsAllowed}{"\n"}'
```

| Часть команды | Значение |
|---|---|
| `patch pdb sick -p '{…}'` | изменить поле политики в готовом бюджете |
| `unhealthyPodEvictionPolicy: AlwaysAllow` | разрешить выселять неготовые поды |
| `ev` | повторить то же выселение |

Результат:

```
poddisruptionbudget.policy/sick patched
{"kind":"Status","apiVersion":"v1","metadata":{},"status":"Success","code":201}
currentHealthy=0 allowed=0
```

Разбор:

1. Ответ `Success`, код 201: выселение принято.
2. `disruptionsAllowed` по-прежнему равен нулю, но неготовый под выселяется всё равно: политика обходит бюджет для подов, которые доступность не обеспечивают.
3. Deployment создаст под вместо выселенного; вывод показывает политику, а не лечение сервиса.

**Итог.**

| Что узнали | Где видно |
|---|---|
| Нарушение бюджета — ответ 429 | `TooManyRequests` |
| Неготовые поды при `IfHealthyBudget` не выселить | первое выселение отказано |
| `AlwaysAllow` снимает блокировку | второе выселение принято, код 201 |

**Уборка.** Удаляем Deployment, бюджет и файл запроса.

```bash
kubectl delete deploy sick
kubectl delete pdb sick
rm ~/lab/k8s/05-5/ev.json
```

Ожидаемый результат: три строки `deleted` без ошибок.

**Вопросы для самопроверки.**

1. Какие поды PDB считает здоровыми?
2. Чем `AlwaysAllow` отличается от `--disable-eviction`?
3. Почему `disruptionsAllowed` остался нулём, а выселение прошло?

<details>
<summary>Ответы</summary>

1. Только поды с условием `Ready=True`. Под Running, но не Ready (провалена проба готовности), в бюджете недоступен.
2. `AlwaysAllow` обходит бюджет только для неготовых подов, чьё выселение не снижает доступность. `--disable-eviction` удаляет любые поды в обход бюджета, включая готовые.
3. Политика проверяется до арифметики бюджета: для неготового пода API-сервер выселение разрешает независимо от `disruptionsAllowed`.

</details>

### Лабораторная работа 3. Вытеснение kubelet по памяти

**Риски.** Работа правит конфигурацию kubelet и создаёт давление памяти на узле.

- **Что меняется:** файл `/var/lib/kubelet/config.yaml` внутри контейнера `lab-worker3` и его перезапуск; узел получает условие `MemoryPressure` и taint `node.kubernetes.io/memory-pressure`.
- **Надолго ли:** до уборки; уборка возвращает файл и перезапускает kubelet.
- **Безопасность:** новых контейнеров с привилегиями работа не создаёт. Команды `docker exec` выполняются от root внутри контейнера-узла kind, а он сам работает привилегированным, поэтому вводите их точно и только для `lab-worker3`.
- **Влияние на систему:** контейнеры подов при перезапуске kubelet продолжают работать. Порог действует на все поды узла, поэтому kubelet может выселить и чужой под, превышающий свой request; под контроллера пересоздастся на другом узле, голый под пропадёт. Новые поды на узел не планируются, пока висит taint. Память хоста работа почти не использует: поды занимают около 700 МиБ.
- **Откат:** уборка работы. Если kubelet не поднялся после правки, верните копию командами `docker exec lab-worker3 cp /root/lab-05-5-config.yaml.bak /var/lib/kubelet/config.yaml` и `docker exec lab-worker3 systemctl restart kubelet`. Копия лежит внутри контейнера-узла; если стенд пересоздан, она не нужна, потому что kind пишет исходную конфигурацию заново.

**Цель.** Включить порог вытеснения по памяти на одном узле, увидеть, что порог вычитается из allocatable, и проследить, какой из трёх подов kubelet выселит первым.

**Что понадобится.**

- Стенд 00-1, узел `lab-worker3`, namespace `lab-05-5`.
- Образ `python:3.12-slim` на узле (скачается при первом запуске).
- `jq` и `docker` на хосте.
- Около 40 минут.

**Схема опыта.**

```
свободно узлу: 15473Mi ──► порог memory.available = 14900Mi
три пода: guaranteed (200Mi, request 300Mi)
          besteffort (200Mi, request 0)
          burstable  (300Mi, request 1Mi)
          └─► свободно < 14900Mi → MemoryPressure → выселен один под
```

Схема 8. Порог лежит вблизи текущей свободной памяти, поэтому три пода пересекают его за секунды.

В kind пороги памяти выключены (§6), поэтому порог задаём вручную чуть ниже текущей свободной памяти узла. Три пода занимают память на этом узле, и порог срабатывает.

#### Шаг 1. Выбрать порог

Команда читает, сколько памяти kubelet считает свободной на узле, и сравнивает с хостом. Порог берём чуть ниже этого значения.

```bash
W=lab-worker3
kubectl get --raw /api/v1/nodes/$W/proxy/stats/summary \
  | jq -c '.node.memory | {availableMi: (.availableBytes/1048576|floor),
                           workingSetMi: (.workingSetBytes/1048576|floor)}'
free -m | awk 'NR==2{print "host available="$7"Mi"}'
```

| Часть команды | Значение |
|---|---|
| `proxy/stats/summary` | статистика kubelet узла |
| `.availableBytes/1048576` | байты в мегабайты |
| `workingSetBytes` | память, занятая узлом и подами |
| `free -m` | свободная память хоста |

Результат на стенде автора (значения у вас другие):

```
{"availableMi":15473,"workingSetMi":…}
host available=…Mi
```

Разбор:

1. `availableMi` — это сигнал `memory.available` глазами kubelet: 15473 МиБ на стенде автора.
2. В kind он считается от лимита контейнера-узла, то есть от памяти всего хоста, и расходится со значением хоста: у автора свободное на хосте было около 8 ГБ.
3. Порог выбирают на 550–600 МиБ ниже `availableMi`: у автора 15473 → 14900Mi.

#### Шаг 2. Задать порог и перезапустить kubelet

Команда копирует конфигурацию kubelet, вставляет порог в `evictionHard` и перезапускает kubelet. Подставьте свой порог в переменную `TH`.

```bash
TH=14900Mi
docker exec $W cp /var/lib/kubelet/config.yaml /root/lab-05-5-config.yaml.bak
docker exec $W sed -i "s/^evictionHard:\$/evictionHard:\n  memory.available: $TH/" \
  /var/lib/kubelet/config.yaml
docker exec $W systemctl restart kubelet
sleep 15; kubectl wait --for=condition=Ready node/$W
kubectl get --raw /api/v1/nodes/$W/proxy/configz | jq -c '.kubeletconfig.evictionHard'
```

| Часть команды | Значение |
|---|---|
| `cp … config.yaml …bak` | сохранить исходный файл для отката |
| `sed -i "s/^evictionHard:\$/…"` | дописать ключ после строки `evictionHard:` |
| `\n  memory.available: $TH` | новая строка с отступом в два пробела |
| `systemctl restart kubelet` | перечитать конфигурацию |
| `proxy/configz` | действующая конфигурация kubelet |

Ожидаемый результат (ключи выведены по алфавиту; три нулевых порога — из конфигурации kind, видны в выводе уборки):

```
node/lab-worker3 condition met
{"imagefs.available":"0%","memory.available":"14900Mi","nodefs.available":"0%",…}
```

Разбор:

1. Узел вернулся в Ready после перезапуска kubelet.
2. В `evictionHard` появился ключ `memory.available` рядом с нулевыми порогами kind.

#### Шаг 3. Увидеть, что порог съел allocatable

Команда сравнивает ёмкость узла с allocatable и показывает, сколько памяти уже занято запросами.

```bash
kubectl get node $W \
  -o jsonpath='capacity={.status.capacity.memory} allocatable={.status.allocatable.memory}{"\n"}'
kubectl describe node $W | grep -A6 'Allocated resources'
```

| Часть команды | Значение |
|---|---|
| `status.capacity.memory` | вся память узла |
| `status.allocatable.memory` | память, доступная подам |
| `grep -A6 'Allocated resources'` | сумма requests и limits подов на узле |

Результат на стенде автора:

```
capacity=16315248Ki allocatable=1057648Ki
  memory             1028Mi (99%)  776Mi (75%)
```

Разбор:

1. Allocatable упал с 16315248Ki до 1057648Ki: порог 14900Mi вычтен из ёмкости.
2. Requests уже занимают 99 % allocatable, поэтому под с request 64Mi сюда не поместится.
3. Это та же арифметика, что в проде: `capacity − kube-reserved − system-reserved − evictionHard`.

#### Шаг 4. Создать давление и дождаться выселения

Команда запускает три пода, которые занимают память: Guaranteed (200 МиБ при request 300Mi), BestEffort (200 МиБ) и Burstable (300 МиБ при request 1Mi). Затем она следит за узлом каждые 2 секунды.

```bash
mkp() {  # имя пода, МиБ памяти, resources в виде YAML
  kubectl apply -f - <<YAML
apiVersion: v1
kind: Pod
metadata: {name: $1}
spec:
  nodeSelector: {kubernetes.io/hostname: $W}
  terminationGracePeriodSeconds: 1
  restartPolicy: Never
  containers:
  - name: $1
    image: python:3.12-slim
    command: ["python", "-c", "import time; b=b'x'*($2*2**20); time.sleep(1e6)"]
    resources: $3
YAML
}
mkp guaranteed 200 '{requests: {cpu: 50m, memory: 300Mi}, limits: {cpu: 50m, memory: 300Mi}}'
mkp besteffort 200 '{}'
kubectl wait --for=condition=Ready pod/guaranteed pod/besteffort; sleep 12
t0=$(date +%s)
mkp burstable 300 '{requests: {memory: 1Mi}, limits: {memory: 1Gi}}'
```

Продолжение: цикл наблюдения печатает строку только при изменении состояния.

```bash
prev=""
for i in $(seq 1 45); do
  av=$(kubectl get --raw /api/v1/nodes/$W/proxy/stats/summary \
    | jq '.node.memory.availableBytes/1048576|floor')
  mp=$(kubectl get node $W \
    -o jsonpath='{.status.conditions[?(@.type=="MemoryPressure")].status}')
  pods=$(kubectl get pods --no-headers | awk '{printf "%s:%s ", $1, $3}')
  s="MemoryPressure=$mp | $pods"
  [ "$s" != "$prev" ] && echo "t=+$(( $(date +%s)-t0 ))s avail=${av}Mi $s" && prev=$s
  sleep 2
done
```

| Часть команды | Значение |
|---|---|
| `b'x' * N` | заполнить память реально: `bytearray(N)` дал бы нулевые страницы, которые не считаются |
| `requests` и `limits` Guaranteed | равны, поэтому QoS-класс Guaranteed |
| `restartPolicy: Never` | выселенный или упавший под не перезапускается |
| `resources: {}` | QoS-класс BestEffort, request 0 |
| `requests: {memory: 1Mi}` | Burstable, почти всё потребление сверх request |
| `availableBytes` в цикле | сигнал kubelet, который сравнивается с порогом |

Результат на стенде автора:

```
t=+1s  avail=15045Mi MemoryPressure=False | besteffort:Running burstable:Running …
t=+12s avail=14949Mi MemoryPressure=True  | besteffort:ContainerStatusUnknown burstable:Running …
```

Разбор:

1. В начале узел свободен, `MemoryPressure=False`, все три пода работают.
2. Через 12 секунд свободная память упала ниже порога, и `MemoryPressure` стало `True`.
3. Статус `ContainerStatusUnknown` у `besteffort` означает, что kubelet его выселил. Guaranteed и Burstable не тронуты.

#### Шаг 5. Прочитать причину выселения

Команда выводит фазу и сообщение каждого пода, taint узла и события узла.

```bash
kubectl get pods -o jsonpath=\
'{range .items[*]}{.metadata.name}: {.status.phase}/{.status.reason} {.status.message}{"\n"}{end}'
kubectl get node $W -o jsonpath='{.spec.taints}{"\n"}'
kubectl get events --field-selector involvedObject.name=$W \
  -o custom-columns=REASON:.reason,MSG:.message | grep -iE 'memory|evict'
```

| Часть команды | Значение |
|---|---|
| `.status.phase/.status.reason` | фаза и причина завершения пода |
| `.status.message` | текст решения kubelet |
| `.spec.taints` | taints узла |
| `grep -iE 'memory\|evict'` | события узла про память и выселение |

Результат на стенде автора:

```
besteffort: Failed/Evicted The node was low on resource: memory. Threshold quantity: 14900Mi,
  available: 15089952Ki. Container besteffort was using 209476Ki, request is 0, has larger …
taints=[{"effect":"NoSchedule","key":"node.kubernetes.io/memory-pressure",…}]
EvictionThresholdMet        Attempting to reclaim memory
NodeHasInsufficientMemory   Node lab-worker3 status is now: NodeHasInsufficientMemory
```

Разбор:

1. Выселен BestEffort: он потреблял 209476Ki при request 0, а Burstable в этот момент ещё занимал память.
2. Фаза `Failed` и причина `Evicted`: под не перезапускают, голый под потерян.
3. Kubelet выселил один под и остановился, потому что свободная память вернулась к порогу.
4. Узел получил taint `memory-pressure:NoSchedule`, а события `EvictionThresholdMet` и `NodeHasInsufficientMemory` фиксируют решение.
5. Если Burstable успеет занять память раньше BestEffort, выселят его. Порядок задаётся превышением request на момент проверки.

**Итог.**

| Что узнали | Где видно |
|---|---|
| Порог вычитается из allocatable | `allocatable=1057648Ki` при `capacity=16315248Ki` |
| Первым выселяют под с наибольшим превышением request | `besteffort: Failed/Evicted` |
| Guaranteed не выселен | остался `Running` |
| Выселение сопровождается taint и событиями | `memory-pressure:NoSchedule`, `EvictionThresholdMet` |

**Уборка.** Удаляем namespace, возвращаем конфигурацию kubelet и контекст kubectl, проверяем результат. Пока конфигурация не возвращена, узел остаётся с заниженным allocatable.

```bash
W=lab-worker3
kubectl config set-context --current --namespace=default
kubectl delete ns lab-05-5
docker exec $W cp /root/lab-05-5-config.yaml.bak /var/lib/kubelet/config.yaml
docker exec $W rm /root/lab-05-5-config.yaml.bak
docker exec $W systemctl restart kubelet
sleep 15; kubectl wait --for=condition=Ready node/$W
kubectl get --raw /api/v1/nodes/$W/proxy/configz | jq -c '.kubeletconfig.evictionHard'
kubectl get node $W \
  -o jsonpath='allocatable={.status.allocatable.memory} taints={.spec.taints}{"\n"}'
curl -s -o /dev/null -w '%{http_code}\n' http://orders.localhost:8088/api/orders
rm -rf ~/lab/k8s/05-5
```

Результат на стенде автора:

```
{"imagefs.available":"0%","nodefs.available":"0%","nodefs.inodesFree":"0%"}
allocatable=16315248Ki taints=
200
```

Разбор:

1. В `evictionHard` нет `memory.available`: конфигурация вернулась к состоянию kind.
2. Allocatable равен ёмкости, а taint'ов нет.
3. Код 200 подтверждает, что `orders` и вход работают.

**Вопросы для самопроверки.**

1. Почему kubelet выселил BestEffort, а не Burstable с большим потреблением?
2. Почему вытеснение kubelet не останавливает PDB?
3. Почему без ручного порога опыт на kind не работает?
4. Как порог вытеснения связан с allocatable?

<details>
<summary>Ответы</summary>

1. Порядок задают превышение request, затем приоритет, затем размер превышения. На момент проверки BestEffort превышал request (0) сильнее, а Burstable ещё не набрал память. Если бы он успел, выселили бы его.
2. Это недобровольное прерывание: kubelet удаляет под сам, минуя Eviction API, где проверяется бюджет. Защита — requests, приоритеты и резервы на узле.
3. Kind задаёт пороги диска `0%`, и kubelet обнуляет остальные, включая память. К тому же kubelet в контейнере-узле видит память хоста целиком и не замечает давления.
4. Allocatable равен ёмкости минус резервы и жёсткий порог. Scheduler не ставит поды на память, которую kubelet всё равно освободил бы выселением. На стенде порог 14900Mi оставил подам около 1 ГиБ.

</details>

---

## → Дальше

Мы закончили модуль 05: поды получили ресурсы, место на узле и правила ухода с него. Но выселять может не каждый: `drain` и Eviction API требуют прав на узлы и на подресурс `pods/eviction`, а ошибка `forbidden` выглядит иначе, чем отказ бюджета. Поэтому следующая часть, 06-1, начинает модуль «Доступ и безопасность» с аутентификации и RBAC: кто и чем подтверждает себя API-серверу и какие права ему выдают. Обслуживание узлов целиком (сертификаты и порядок drain) разобрано в 10-4, и она ссылается на эту часть.
