# 05-3. Автоскейлинг

> Модуль 5 «Ресурсы и планирование» · часть 3 из 4 · 🟡🔴 · ~1 ч чтения + ~1 ч лабы (из них ~15 мин — ожидание масштабирования) · Нужно: стенд 00-1 (metrics-server), KEDA ставится в лабе

---

## Зачем это DevOps-у

Автоскейлинг — то, что должно спасать в пик и экономить ночью, а на практике чаще всего «не масштабирует» (нет requests или метрик), «масштабирует поздно» (минута до первого пода, плюс старт), «пилит» (вверх-вниз каждые несколько минут) или упирается в узлы, которых нет. На собеседовании: «как работает HPA», «почему HPA не видит метрики», «HPA vs VPA», «что делает Cluster Autoscaler».

В сквозном сценарии у orders-api есть ручка `/work?ms=N` — она жжёт CPU, как тяжёлый запрос. Нагружаем её и смотрим, как HPA реагирует, с цифрами.

---

## 1. Три уровня масштабирования 🟢

| Что масштабируется | Инструмент | По чему |
|---|---|---|
| число подов | **HPA** (встроен), **KEDA** (поверх HPA) | CPU/память (metrics-server), свои метрики (Prometheus Adapter), внешние события (очереди, cron) |
| ресурсы пода | **VPA** (отдельный проект SIG Autoscaling) | история потребления → requests/limits; in-place resize (05-1) |
| число узлов | **Cluster Autoscaler**, **Karpenter** | Pending-поды, которым не хватает места; пустые узлы |

Они работают вместе: HPA добавляет поды → не хватает места → поды Pending → CA/Karpenter добавляет узел. И порознь не работают: HPA без запаса узлов создаёт Pending-поды, CA без правильных requests добавляет узлы не тогда.

## 2. HPA: формула и требования 🟡

Каждые 15 с (`--horizontal-pod-autoscaler-sync-period`) контроллер считает:

```
desiredReplicas = ceil( currentReplicas × currentMetric / targetMetric )
```

Для CPU в режиме `Utilization` метрика — **процент от requests** пода. Отсюда главное требование: **без `requests.cpu` HPA не работает** (проверено):

```
NAME    REFERENCE          TARGETS              MINPODS   MAXPODS   REPLICAS
noreq   Deployment/noreq   cpu: <unknown>/50%   1         5         1
ScalingActive=False FailedGetResourceMetric: the HPA was unable to compute the replica count: failed to get cpu utilization: missing request for cpu in container orders-api of Pod noreq-95cdd95d4-rz85h
```

Ещё правила формулы: допуск ±10% (при отношении 0,9–1,1 ничего не происходит); неготовые поды и поды без метрик при росте считаются как 0% (чтобы не раздувать масштаб из-за стартующих), при падении — как 100%; при нескольких метриках берётся **максимум** желаемых реплик.

## 3. Замер: вверх и вниз с дефолтами 🟡

Deployment `api` (requests CPU 100m), HPA 1–8 реплик, цель 50%. Нагрузка — 6 потоков на `/work?ms=40` (больше, чем 8 реплик по 100m могут переварить — специально). Проверено:

```
t=+11s   cpu=%      desired=0 current=1
t=+27s   cpu=1003%  desired=4 current=1        ← метрика пришла: 1 под жжёт целое ядро (10× request)
t=+42s   cpu=1004%  desired=8 current=4
t=+58s   cpu=687%   desired=8 current=8        ← упёрлись в maxReplicas
...
t=+184s  LOAD STOPPED
t=+239s  cpu=1%     desired=8 current=8        ← нагрузки нет, а реплик 8
t=+522s  cpu=1%     desired=1 current=8
t=+538s  cpu=1%     desired=1 current=1
```

Что видно:

- **Первая реакция — ~25 с**: окно metrics-server (~15 с у kubelet/cAdvisor) + цикл HPA (15 с). Плюс старт подов и readiness. Под резкий пик HPA всегда опаздывает — запас по `minReplicas` и быстрый старт приложения важнее «умных» настроек.
- **Вверх — ступенями**: формула просила 1 → 11 (ceil(1×1003/50) = 21, ограничено max 8), но дефолтная политика `scaleUp` разрешает за 15 с не больше **max(+4 пода, +100%)**: 1 → 4 → 8.
- **Вниз — через 5 минут**: от снятия нагрузки до 1 реплики **354 с**. Дефолт `scaleDown.stabilizationWindowSeconds: 300` — HPA берёт максимум рекомендаций за 5 минут, чтобы не «пилить» на колебаниях. И затем сразу до 1: дефолтная политика вниз — до 100% за 15 с.

## 4. behavior: управляем скоростью 🟡🔴

```yaml
behavior:
  scaleUp:
    stabilizationWindowSeconds: 0
    policies: [{type: Pods, value: 2, periodSeconds: 30}]        # не больше +2 пода за 30 с
  scaleDown:
    stabilizationWindowSeconds: 30
    policies: [{type: Percent, value: 50, periodSeconds: 15}]    # не больше −50% за 15 с
```

Проверено (тот же сценарий):

```
t=+32s  cpu=711%  desired=3 current=1
t=+63s  cpu=776%  desired=5 current=3
t=+90s  cpu=637%  desired=7 current=5
t=+121s cpu=521%  desired=8 current=7
t=+153s LOAD STOPPED
t=+213s cpu=1%    desired=4 current=8
t=+224s cpu=1%    desired=2 current=4
t=+239s cpu=1%    desired=1 current=2
```

Вверх — медленнее (+2 за 30 с), вниз — ~100 с вместо ~6 минут, плавно 8 → 4 → 2 → 1. Типичные настройки: быстрый подъём (сервис под нагрузкой страдает), медленный и плавный спуск (не уронить на следующей волне), `selectPolicy: Disabled` для scaleDown — у сервисов, которые сами по себе не должны сжиматься (кэш-прогрев), но тогда сжатие — ручное.

## 5. HPA на других метриках 🔴

- **Память** — плохая метрика для HPA большинства приложений: рантаймы не отдают память (JVM, Go, Python), реплики добавляются и не уходят.
- **Свои метрики** (RPS, задержка, длина очереди) — `type: Pods`/`Object` через custom metrics API (Prometheus Adapter) — ⚠️ на стенде не настраивался.
- **Внешние события** — `type: External`; проще через **KEDA**: десятки готовых «скейлеров» (Kafka lag, RabbitMQ, SQS, Prometheus-запрос, cron, HTTP) и **масштабирование до нуля**, которого у HPA нет (`minReplicas: 0` у HPA — только за feature gate).

### KEDA: cron и scale-to-zero (проверено)

```yaml
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
    metadata: {timezone: Europe/Moscow, start: "17 14 * * *", end: "19 14 * * *", desiredReplicas: "3"}
```

```
14:15:57 replicas=0/ready= active=False        ← вне окна — ноль подов
14:17:29 replicas=1/ready=1 active=True        ← 0 → 1 делает оператор KEDA (активация)
14:17:41 replicas=3/ready=3 active=True        ← 1 → 3 делает HPA, созданный KEDA (keda-hpa-api)
14:19:30 replicas=0/ready= active=False        ← конец окна + cooldownPeriod 30 с
```

KEDA создаёт и ведёт обычный HPA (`keda-hpa-api`), а переход 0 ↔ 1 делает сам. Свой HPA на тот же Deployment ставить нельзя — два контроллера будут воевать за `replicas` (01-3). Установка KEDA 2.21.0 Helm-чартом на стенде заняла больше 5 минут — образы с ghcr.io тянулись медленно; это вне нашего контроля, но учитывайте при планировании лабы.

Scale-to-zero для HTTP — не бесплатен: первый запрос после нуля ждёт старт пода (секунды); нужен буфер запросов (KEDA HTTP add-on, Knative) — иначе первые запросы получат 503.

## 6. VPA 🟡

Vertical Pod Autoscaler смотрит историю потребления и рекомендует (или выставляет) requests/limits. Режимы: `Off` (только рекомендации — самый полезный старт), `Initial` (при создании пода), `Recreate` (пересоздаёт поды), `InPlaceOrRecreate` (использует in-place resize — 05-1 §7, без рестарта, где возможно). ⚠️ На стенде VPA не ставился.

HPA и VPA **по одной метрике** вместе использовать нельзя: VPA поднимает request → утилизация (% от request) падает → HPA убирает поды → нагрузка на под растёт → VPA поднимает request… Допустимо: HPA по CPU + VPA только по памяти, или HPA по своей метрике (RPS) + VPA по ресурсам.

## 7. Cluster Autoscaler и Karpenter 🔴

⚠️ Не проверено на стенде: в kind нельзя добавлять узлы (нужен облачный провайдер или Cluster API). Механика по документации:

| | Cluster Autoscaler | Karpenter |
|---|---|---|
| Триггер вверх | Pending-поды с `FailedScheduling` из-за ресурсов | то же |
| Как добавляет | увеличивает размер существующей группы узлов (ASG, node pool) | создаёт узел подходящего типа под конкретные поды (bin packing) |
| Вниз | узел с низкой утилизацией (по **requests**, порог 50%) дольше 10 минут, поды которого можно переселить | консолидация: замена/удаление узлов, если поды помещаются дешевле |
| Что блокирует удаление узла | PDB, локальные тома, поды без контроллера, `cluster-autoscaler.kubernetes.io/safe-to-evict: "false"` | PDB, `karpenter.sh/do-not-disrupt` |
| Время нового узла | 1–3 минуты (облако) + pull образов | так же, но точнее тип |

Следствия для эксплуатации:

- Масштабирование узлов опирается на **requests**: завышены — платите за пустые узлы; занижены — узлы перегружены, а новые не появляются.
- Время реакции цепочки HPA → Pending → новый узел → pull образа → старт — **минуты**. Для пиков — запас (overprovisioning: низкоприоритетные «пустышки», которые вытесняются реальными подами — 05-2 §6).
- PDB с `maxUnavailable: 0` или одной репликой блокирует удаление узла навсегда (05-4).

---

## 🔧 Лаба

### Шаг 0. Подготовка

```bash
kubectl config use-context kind-lab
kubectl create ns lab-05-3
kubectl config set-context --current --namespace=lab-05-3
kubectl top nodes        # metrics-server работает
```

### Шаг 1. HPA без requests

```bash
kubectl create deploy noreq --image=localhost:5001/orders-api:2.0 --port=8000
kubectl autoscale deploy noreq --cpu-percent=50 --min=1 --max=5
sleep 45; kubectl get hpa noreq
kubectl get hpa noreq -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}: {.message}{"\n"}{end}'
kubectl delete hpa noreq; kubectl delete deploy noreq
```

Проверено: вывод в §2. В новых kubectl флаг `--cpu-percent` может быть заменён на `--cpu=50%` — смотрите `kubectl autoscale --help`.

### Шаг 2. HPA под нагрузкой

```bash
kubectl apply -f - <<'EOF'
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
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata: {name: api}
spec:
  scaleTargetRef: {apiVersion: apps/v1, kind: Deployment, name: api}
  minReplicas: 1
  maxReplicas: 8
  metrics: [{type: Resource, resource: {name: cpu, target: {type: Utilization, averageUtilization: 50}}}]
EOF
kubectl rollout status deploy/api
load() { kubectl run load --image=python:3.12-slim --command -- python -c "
import urllib.request, threading, time
def w():
    while True:
        try: urllib.request.urlopen('http://api/work?ms=40', timeout=5).read()
        except Exception: time.sleep(0.1)
for _ in range(6): threading.Thread(target=w, daemon=True).start()
time.sleep(100000)"; }
# mon <секунд всего> <когда снять нагрузку>
mon() { t0=$(date +%s); prev=""; stopped=0
  while [ $(( $(date +%s)-t0 )) -lt $1 ]; do t=$(( $(date +%s)-t0 ))
    if [ $stopped = 0 ] && [ $t -ge $2 ]; then kubectl delete pod load --now >/dev/null; echo "t=+${t}s LOAD STOPPED"; stopped=1; fi
    s=$(kubectl get hpa api -o jsonpath='{.status.currentMetrics[0].resource.current.averageUtilization}% desired={.status.desiredReplicas} current={.status.currentReplicas}')
    [ "$s" != "$prev" ] && echo "t=+${t}s cpu=$s" && prev=$s; sleep 5; done; }
load; mon 600 180
```

Проверено: вывод в §3 (10 минут).

### Шаг 3. behavior

```bash
kubectl patch hpa api --type=merge -p '{"spec":{"behavior":{"scaleUp":{"stabilizationWindowSeconds":0,"policies":[{"type":"Pods","value":2,"periodSeconds":30}]},"scaleDown":{"stabilizationWindowSeconds":30,"policies":[{"type":"Percent","value":50,"periodSeconds":15}]}}}}'
load; kubectl wait --for=condition=Ready pod/load; mon 300 150
kubectl describe hpa api | sed -n '/Events/,$p' | tail -8
```

Проверено: вывод в §4.

### Шаг 4. KEDA: cron и ноль подов

```bash
kubectl delete hpa api
helm repo add kedacore https://kedacore.github.io/charts && helm repo update kedacore
helm upgrade --install keda kedacore/keda --version 2.21.0 -n keda --create-namespace
kubectl -n keda wait --for=condition=Ready pod --all --timeout=600s      # у автора — ~10 минут (pull с ghcr.io)
S1=$(TZ=Europe/Moscow date -d '+2 min' +'%M %H'); E1=$(TZ=Europe/Moscow date -d '+4 min' +'%M %H')
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
prev=""; for i in $(seq 1 72); do
  s="replicas=$(kubectl get deploy api -o jsonpath='{.spec.replicas}')/ready=$(kubectl get deploy api -o jsonpath='{.status.readyReplicas}') active=$(kubectl get scaledobject api -o jsonpath='{.status.conditions[?(@.type=="Active")].status}')"
  [ "$s" != "$prev" ] && echo "$(TZ=Europe/Moscow date +%H:%M:%S) $s" && prev=$s; sleep 5; done
kubectl get hpa      # keda-hpa-api — HPA, созданный KEDA
```

Проверено: вывод в §5. На Manjaro/Ubuntu `date -d '+2 min'` — GNU date; в busybox так нельзя (курс `cicd`).

### Уборка

```bash
kubectl delete scaledobject api
helm -n keda uninstall keda
kubectl delete ns keda
kubectl get crd -o name | grep keda.sh | xargs -r kubectl delete
kubectl config set-context --current --namespace=default
kubectl delete ns lab-05-3
```

---

## 🔥 Кейс из прода: «HPA не масштабирует, а сервис тонет»

**Контекст.** Распродажа, рост трафика в 5 раз за 10 минут. orders-api с HPA (2–20 реплик, цель CPU 70%). Реплик осталось 2, задержки выросли до секунд, часть запросов — 503. Дежурный видит в `kubectl get hpa`: `cpu: <unknown>/70%`.

**Разбор.**
1. `describe hpa` — `FailedGetResourceMetric: missing request for cpu in container istio-proxy`. В namespace месяц назад включили инъекцию sidecar'а mesh'а без requests.
2. Для `Utilization` нужны requests **у всех контейнеров пода** — один контейнер без requests ломает расчёт для всего HPA (шаг 1 лабы — тот же текст ошибки).
3. Когда requests добавили, HPA сработал ступенями (+4/+100% за 15 с, §3), но новые поды висели Pending: узлов не хватало, Cluster Autoscaler добавлял их по 2–3 минуты.

**Фикс.**
- Requests у sidecar'а через аннотации mesh'а; политика (06-2): контейнер без requests не допускается.
- Для HPA с sidecar'ами — метрика `ContainerResource` (`type: ContainerResource, container: api`): масштабирование по CPU основного контейнера, sidecar не влияет.
- Алерт на `ScalingActive=False` и на `kube_horizontalpodautoscaler_status_current_replicas == spec.max_replicas`.
- Перед известными пиками — поднятый `minReplicas` (или KEDA cron) и запас узлов (overprovisioning низкоприоритетными подами).

**Что запомнить.**
- `<unknown>` в HPA — почти всегда нет requests или метрик; читайте `conditions`.
- Requests нужны у всех контейнеров пода (или `ContainerResource`).
- HPA + CA реагируют за минуты; к предсказуемым пикам готовятся заранее.

---

## 💼 Вопросы с собеседования

### 🟢 Junior

**1. Что делает HPA?**
Меняет число реплик Deployment/StatefulSet по метрикам (CPU, память, свои), каждые 15 с, в пределах min/max.

**2. Почему HPA показывает `<unknown>`?**
Нет метрик (metrics-server не работает) или нет requests по ресурсу хотя бы у одного контейнера пода — процент утилизации не посчитать. Подробности — в `kubectl describe hpa`, условие `ScalingActive`.

### 🟡 Middle

**3. Как HPA считает число реплик?**
`ceil(текущие × текущая метрика / целевая)`, с допуском ±10%; для CPU-Utilization метрика — процент от requests. При нескольких метриках — максимум. Ограничения скорости — `behavior` (дефолт вверх: max(+4 пода, +100%) за 15 с; вниз: окно стабилизации 5 минут).

**4. Почему после пика реплики не уменьшаются 5 минут?**
`scaleDown.stabilizationWindowSeconds: 300` по умолчанию: HPA берёт максимальную рекомендацию за окно, чтобы не сжиматься на временном спаде. Настраивается в `behavior` (на стенде: 354 с с дефолтом, ~100 с с окном 30 с и −50% за 15 с).

**5. HPA или VPA?**
HPA — горизонтально, для stateless-сервисов с переменной нагрузкой. VPA — подбор requests, для сервисов, которые не масштабируются горизонтально, и для калибровки requests (режим Off). Вместе по одной метрике — нельзя (зацикливание), по разным — можно.

### 🔴 Senior

**6. Как масштабировать по длине очереди и до нуля?**
KEDA: ScaledObject со скейлером брокера (Kafka lag, RabbitMQ, SQS) — KEDA создаёт HPA на внешнюю метрику и сама переводит 0 ↔ 1. Для HTTP до нуля нужен буфер запросов (KEDA HTTP add-on, Knative), иначе первые запросы теряются на старте пода.

**7. Как работает Cluster Autoscaler и что мешает ему убирать узлы?**
Вверх — при Pending-подах с нехваткой ресурсов: увеличивает группу узлов, где под поместится. Вниз — узел с утилизацией по requests ниже порога (50%) дольше ~10 минут, если его поды можно переселить. Мешают: PDB без запаса, локальные тома, поды без контроллера, аннотация safe-to-evict false, системные поды без PDB. Решает он только по requests.

**8. Как подготовить сервис к резкому пику?**
Быстрый старт приложения и readiness; поднятый `minReplicas` или KEDA cron перед известным пиком; `behavior` с быстрым scaleUp; запас узлов (overprovisioning: низкоприоритетные поды-заглушки, вытесняемые реальными); правильные requests (иначе CA и HPA считают неверно); нагрузочный тест с замером времени масштабирования.

---

## ⚠️ Подводные камни

- Без requests (у любого контейнера пода, включая sidecar) — HPA по Utilization не работает.
- Метрика CPU — процент от requests: завышенные requests = HPA «не видит» нагрузку.
- Первая реакция HPA ~25 с + старт подов; на резкий пик он опаздывает.
- Вниз — через 5 минут по умолчанию.
- HPA по памяти почти всегда не сжимается обратно.
- HPA + VPA по CPU — зацикливание.
- Свой HPA на Deployment под KEDA — война контроллеров.
- `replicas` в манифесте + HPA — сброс при каждом apply (01-3).
- CA и Karpenter решают по requests и не видят реальной загрузки.

---

## Чеклист

- [ ] Объясню формулу HPA и почему без requests он не работает.
- [ ] Замерю время масштабирования вверх и вниз и настрою `behavior`.
- [ ] Масштабирую по cron/очереди и до нуля через KEDA.
- [ ] Объясню, почему HPA и VPA по одной метрике нельзя.
- [ ] Расскажу, как CA/Karpenter добавляют и удаляют узлы и что им мешает.

---

## Задание со звёздочкой

Масштабируйте orders-api по RPS, а не по CPU:

1. Добавьте в orders-api счётчик запросов в формате Prometheus на `/metrics` (`orders_requests_total`) и соберите `orders-api:2.2`.
2. Поставьте KEDA со скейлером `prometheus` (Prometheus в кластере — kube-prometheus-stack или одиночный Prometheus с `kubernetes_sd`; ⚠️ на стенде не проверялось) и ScaledObject с порогом 20 RPS на под.
3. Сравните время реакции с CPU-HPA шага 2. Какая метрика правильнее для сервиса, который ждёт ответа БД, а не жжёт CPU?

---

→ Следующая часть: **05-4. Disruptions: PDB, drain, eviction** — PodDisruptionBudget и `kubectl drain`, drain, который не проходит, вытеснение kubelet'ом по давлению памяти на узле (с настроенным порогом в kind) и порядок вытеснения по QoS.
