# 02-5. Probes и graceful shutdown

> Модуль 2 «Workloads» · часть 5 из 5 · 🟢🟡🔴 · ~1,5 ч чтения + ~1 ч лабы · Нужно: стенд 00-1 (Gateway `lab`)

---

## Зачем это DevOps-у

«Каждый деплой даёт всплеск 502», «медленно стартующий сервис уходит в CrashLoop», «БД моргнула на минуту — все поды API перезапустились, и восстановление заняло десять минут» — это три классические ошибки с probes и завершением подов. Они не видны на тестовом стенде без нагрузки и проявляются в проде, поэтому их любят на собеседованиях: «чем liveness отличается от readiness», «почему нельзя проверять БД в liveness», «как сделать деплой без ошибок».

В сквозном сценарии: orders-api за Envoy Gateway, 4 реплики, 4 потока клиентов; считаем ошибки при `rollout restart` в трёх вариантах — без graceful shutdown, с `preStop`, с задержкой в приложении.

---

## 1. Три пробы 🟢

| Проба | Вопрос | Не прошла → |
|---|---|---|
| **startupProbe** | приложение уже запустилось? | пока не прошла — liveness и readiness не выполняются; провалилась `failureThreshold` раз — контейнер убит (как liveness) |
| **livenessProbe** | процесс жив и не завис? | контейнер **перезапускается** |
| **readinessProbe** | можно слать трафик? | под убирается из endpoints Service (и из Gateway); контейнер не трогают |

Виды проверок: `httpGet` (2xx/3xx — успех), `tcpSocket` (порт принимает соединение), `exec` (код 0), `grpc` (gRPC Health Checking Protocol).

Дефолты (проверено, `kubectl get pod … -o jsonpath='{.spec.containers[0].livenessProbe}'` на поде, где задан только путь):

```
{"failureThreshold":3,"httpGet":{"path":"/health","port":"http","scheme":"HTTP"},"periodSeconds":10,"successThreshold":1,"timeoutSeconds":1}
```

| Параметр | Дефолт | Ловушка |
|---|---|---|
| `initialDelaySeconds` | 0 | вместо большого `initialDelaySeconds` используйте startupProbe |
| `periodSeconds` | 10 | реакция readiness на сбой — до `period × failureThreshold` = 30 с |
| `timeoutSeconds` | **1** | ответ дольше 1 секунды — провал; под нагрузкой (GC, троттлинг, 05-1) liveness начинает убивать живые поды |
| `failureThreshold` | 3 | |
| `successThreshold` | 1 | для liveness и startup может быть только 1 |
| `terminationGracePeriodSeconds` у пробы | из пода | можно задать короче для убийства по liveness |

Проверено: liveness на ручку, которая отвечает 1,5 с (`/work?ms=1500`), при `timeoutSeconds: 1`:

```
slow-endpoint     0/1     CrashLoopBackOff   6 (32s ago)   4m4s
20      Liveness probe failed: Get "http://10.244.2.80:8000/work?ms=1500": context deadline exceeded (Client.Timeout exceeded while awaiting headers)
```

Приложение живо — его убивают за медленный ответ.

## 2. startupProbe и медленный старт 🟡

orders-api с `STARTUP_DELAY=40` (40 с не открывает порт, как JVM-сервис с прогревом или приложение с миграциями на старте). Проверено, 4 минуты:

| Конфигурация | Результат |
|---|---|
| только liveness с дефолтами | `RESTARTS 3` за 4 минуты: liveness убивает после 3 провалов × 10 с; иногда новый экземпляр успевает за счёт сдвига первой пробы — сервис **то поднимается, то нет**. `Last State: Error/137` |
| startupProbe `periodSeconds: 2, failureThreshold: 60` (до 120 с на старт) + та же liveness | `RESTARTS 0`, Ready через 42 с после старта |

Почему код 137, а не 143: пока приложение «стартует» (`time.sleep` до установки обработчика сигналов), SIGTERM для процесса с PID 1 **игнорируется ядром** (для PID 1 в namespace действия сигналов по умолчанию не работают) — kubelet ждёт grace period и шлёт SIGKILL. Подробнее о PID 1 — `git-docker` 02-4.

Правило: startupProbe — с запасом на худший старт (`period × failureThreshold`), liveness — короткая и дешёвая, после startupProbe.

## 3. Readiness: кто на неё смотрит 🟡

Readiness — единственный сигнал «слать ли трафик». От неё зависят:

- EndpointSlice (`conditions.ready`) → kube-proxy на всех узлах, Envoy Gateway, Ingress-контроллеры, mesh;
- `rollout status` и `maxUnavailable` у Deployment (02-2), `minReadySeconds`;
- PDB (05-4) — считает только Ready-поды;
- DNS headless Service (02-3).

Что проверять в readiness: «могу ли я сейчас обслужить запрос» — прогрет кэш, загружена конфигурация, открыт пул к **обязательным** зависимостям. orders-api: `/ready` → 503 до окончания старта, при недоступной БД и после SIGTERM.

## 4. Liveness, которая проверяет БД, — каскад 🔴

Liveness отвечает на вопрос «надо ли **перезапустить** процесс». Перезапуск не поможет, если не работает БД, — но liveness с проверкой БД именно это и сделает, причём со всеми подами сразу.

Проверено: два Deployment'а по 2 реплики, PostgreSQL выключен на 60 с:

| | `readiness-only` (liveness `/health`) | `liveness-db` (liveness `/ready` — проверяет БД) |
|---|---|---|
| во время простоя БД | `0/1 Running`, `RESTARTS 0` — выпали из Service | `0/1 CrashLoopBackOff`, `RESTARTS 3` за минуту |
| после возвращения БД | Ready через **3 с** | Ready через **20 с**, `RESTARTS 4` |

20 секунд — это back-off после трёх рестартов. Простой БД на 10 минут дал бы паузы до 5 минут (02-1), и сервис поднимался бы ещё минуты после того, как БД вернулась. Плюс каждый рестарт — холодный старт, сброс кэшей, всплеск соединений к только что поднявшейся БД («thundering herd»).

Правило: **liveness проверяет только сам процесс** (отвечает ли HTTP-сервер, не завис ли event loop), без внешних зависимостей. Зависимости — в readiness, и то только обязательные (иначе каскад readiness: 01-2, кейс).

## 5. Graceful shutdown: что происходит при удалении пода 🟡🔴

Удаление пода (rollout, scale down, drain, eviction) запускает **два параллельных** процесса:

```
kubectl delete pod / rollout          apiserver ставит deletionTimestamp
          │
          ├──► kubelet:                         ├──► EndpointSlice-контроллер:
          │    1. preStop (если есть)           │    под → ready=false / удалён из slice
          │    2. SIGTERM в PID 1               │         │
          │    3. ждёт до terminationGrace…     │         ├─► kube-proxy на каждом узле переписывает правила
          │       (30 с, включая preStop)       │         ├─► Envoy Gateway получает xDS-обновление
          │    4. SIGKILL                       │         └─► Ingress / mesh / внешний LB
```

Ветки не синхронизированы. Если приложение по SIGTERM сразу закрывает порт, а kube-proxy и Envoy ещё не узнали об удалении — запросы уходят в закрытый порт: `Connection refused`, у Envoy — 503. Эта гонка и есть «502 при каждом деплое».

Замер (лаба, шаг 2): `rollout restart` 4 реплик за 30 с нагрузки, два пути — через Gateway (Envoy) и напрямую через Service (kube-proxy):

| Вариант | Через Gateway | Через Service |
|---|---|---|
| **A**: приложение закрывается сразу по SIGTERM (`SHUTDOWN_DELAY=0`), без preStop | 10 и 19 ошибок (два прогона): `503: 17`, `TimeoutError: 2` | 12 и 7: `Connection refused: 3`, `timed out: 4` |
| **B**: `preStop: {sleep: {seconds: 5}}` | 0 и 0 | 2 и 0 (разовые `URLError` в первом прогоне) |
| **C**: приложение после SIGTERM 5 с продолжает обслуживать и отдаёт readiness 503 (`SHUTDOWN_DELAY=5`), без preStop | 0 | 0 |

Ошибок мало в абсолютных цифрах (~0,2–0,4%), но это **на каждом деплое** и при каждом scale down HPA — а в проде с сотнями RPS это сотни ошибок.

### Как убрать гонку

1. **preStop sleep** — kubelet сначала спит, потом шлёт SIGTERM; за это время все потребители endpoints успевают убрать под. С 1.33 есть нативное действие (stable) — не нужен `sleep` в образе (distroless):
   ```yaml
   lifecycle:
     preStop:
       sleep: {seconds: 5}
   ```
   Для образов без `sleep` и кластеров старше — `exec: {command: ["sleep", "5"]}` (нужен бинарник в образе).
2. **Задержка в приложении** — по SIGTERM перестать отвечать 200 на readiness, продолжать обслуживать N секунд, затем закрыть listener и дождаться текущих запросов (как orders-api с `SHUTDOWN_DELAY`).
3. **`terminationGracePeriodSeconds`** ≥ preStop + время завершения запросов + запас. preStop **входит** в grace period: preStop 25 с при дефолтных 30 с оставляет приложению 5 с.

Сколько ждать: время распространения изменений endpoints — секунды (kube-proxy `minSyncPeriod` 1 с, xDS у Envoy — около секунды), но внешние балансировщики облака перечитывают цели с интервалом проверок 10–30 с. Для сервисов за облачным LB — 10–15 с preStop и/или `externalTrafficPolicy` с health-check'ами (03-2).

### Grace period и SIGKILL 🟡

Проверено: под, чей PID 1 обрабатывает SIGTERM (`trap … exit 0`), удалён за 2,1 с; под с `sleep infinity` в роли PID 1 (сигнал игнорируется) — за **30,8 с**, после SIGKILL. Каждый такой под задерживает rollout, drain и scale down на 30 секунд. Признак в статусе — `exitCode: 137, reason: Error` (не OOMKilled).

---

## 🔧 Лаба

### Шаг 0. Подготовка

```bash
kubectl config use-context kind-lab
kubectl create ns lab-02-5
kubectl config set-context --current --namespace=lab-02-5
kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata: {name: orders-api, namespace: lab-02-5}
spec:
  replicas: 4
  selector: {matchLabels: {app: orders-api}}
  template:
    metadata: {labels: {app: orders-api}}
    spec:
      containers:
      - name: api
        image: localhost:5001/orders-api:2.0
        ports: [{name: http, containerPort: 8000}]
        env: [{name: SHUTDOWN_DELAY, value: "0"}]
        readinessProbe: {httpGet: {path: /ready, port: http}, periodSeconds: 2}
        resources: {requests: {cpu: 50m, memory: 32Mi}, limits: {memory: 128Mi}}
---
apiVersion: v1
kind: Service
metadata: {name: orders-api, namespace: lab-02-5}
spec:
  selector: {app: orders-api}
  ports: [{name: http, port: 80, targetPort: http}]
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: orders-api, namespace: lab-02-5}
spec:
  parentRefs: [{name: lab, namespace: envoy-gateway-system}]
  hostnames: ["lab025.localhost"]
  rules: [{backendRefs: [{name: orders-api, port: 80}]}]
EOF
kubectl rollout status deploy/orders-api
```

Клиент — `load.py` из 02-2 (шаг 0) с двумя дополнениями: третий аргумент — заголовок `Host`, и в ошибке печатается причина. Возьмите файл из 02-2 и замените в нём две строки:

```bash
sed -i 's|^dur = float(sys.argv\[1\]).*|&\nhost = sys.argv[3] if len(sys.argv) > 3 else None|' /tmp/load.py
sed -i 's|            with urllib.request.urlopen(url, timeout=2) as r:|            req = urllib.request.Request(url, headers={"Host": host} if host else {})\n            with urllib.request.urlopen(req, timeout=2) as r:|' /tmp/load.py
sed -i 's|stats\[type(e).__name__\] += 1; errs|stats[type(e).__name__ + ":" + str(getattr(e, "reason", e))[:40]] += 1; errs|' /tmp/load.py
kubectl run client --image=python:3.12-slim --command -- sleep infinity
kubectl wait --for=condition=Ready pod/client
kubectl cp /tmp/load.py client:/tmp/load.py
GW=$(kubectl -n envoy-gateway-system get svc -l gateway.envoyproxy.io/owning-gateway-name=lab -o jsonpath='{.items[0].metadata.name}').envoy-gateway-system
kubectl exec client -- python /tmp/load.py 3 http://$GW/version lab025.localhost
```

Проверено: `requests=544 ok=544 errors=0`.

### Шаг 1. Функция замера

```bash
run() {
  kubectl exec client -- python /tmp/load.py 30 http://$GW/version lab025.localhost > /tmp/gw.txt &
  kubectl exec client -- python /tmp/load.py 30 http://orders-api/version > /tmp/svc.txt &
  sleep 3; kubectl rollout restart deploy/orders-api; kubectl rollout status deploy/orders-api
  wait; echo "$1"; echo "  via gateway: $(cat /tmp/gw.txt)"; echo "  via service: $(cat /tmp/svc.txt)"
}
```

### Шаг 2. Три варианта завершения

```bash
run "A: SHUTDOWN_DELAY=0, no preStop"

kubectl patch deploy orders-api --type=json -p '[{"op":"add","path":"/spec/template/spec/containers/0/lifecycle","value":{"preStop":{"sleep":{"seconds":5}}}}]'
kubectl rollout status deploy/orders-api; sleep 5
run "B: SHUTDOWN_DELAY=0, preStop sleep 5"

kubectl patch deploy orders-api --type=json -p '[{"op":"remove","path":"/spec/template/spec/containers/0/lifecycle"},{"op":"replace","path":"/spec/template/spec/containers/0/env/0/value","value":"5"}]'
kubectl rollout status deploy/orders-api; sleep 5
run "C: SHUTDOWN_DELAY=5"
```

Проверено (прогоны A и B повторялись дважды):

```
A: SHUTDOWN_DELAY=0, no preStop
  via gateway: requests=5108 ok=5098 errors=10 error_window=2.9s detail={200: 5098, 503: 6, 'TimeoutError': 4}
  via service: requests=5099 ok=5087 errors=12 error_window=9.5s detail={200: 5087, 'ConnectionResetError': 3, 'URLError': 9}
A2 via gateway: requests=5287 ok=5268 errors=19 error_window=3.1s detail={200: 5268, 503: 17, 'TimeoutError:timed out': 2}
A2 via service: requests=5280 ok=5273 errors=7 error_window=2.1s detail={200: 5273, 'URLError:[Errno 111] Connection refused': 3, 'URLError:timed out': 4}
B: SHUTDOWN_DELAY=0, preStop sleep 5
  via gateway: requests=5468 ok=5468 errors=0 error_window=0s
  via service: requests=5476 ok=5474 errors=2 error_window=14.0s detail={200: 5474, 'URLError': 2}
B2: preStop sleep 5 (repeat)
  via gateway: requests=5469 ok=5469 errors=0 error_window=0s
  via service: requests=5656 ok=5656 errors=0 error_window=0s
C: SHUTDOWN_DELAY=5 (app keeps serving after SIGTERM, readiness 503)
  via gateway: requests=5477 ok=5477 errors=0 error_window=0s
  via service: requests=5652 ok=5652 errors=0 error_window=0s
```

### Шаг 3. Grace period

```bash
kubectl run stubborn --image=busybox:1.37 -- sleep infinity
kubectl run polite --image=busybox:1.37 -- sh -c 'trap "echo got TERM; exit 0" TERM; while true; do sleep 1; done'
kubectl wait --for=condition=Ready pod/stubborn pod/polite
for p in polite stubborn; do s=$(date +%s%N); kubectl delete pod $p; echo "$p deleted in $(( ($(date +%s%N)-s)/1000000 )) ms"; done
```

Проверено: polite удалён за 2,1 с, stubborn — за 30,8 с.

### Шаг 4. startupProbe и таймаут пробы

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata: {name: slow-no-startup}
spec:
  containers:
  - name: api
    image: localhost:5001/orders-api:2.0
    env: [{name: STARTUP_DELAY, value: "40"}]
    ports: [{name: http, containerPort: 8000}]
    livenessProbe: {httpGet: {path: /health, port: http}}
---
apiVersion: v1
kind: Pod
metadata: {name: slow-startup}
spec:
  containers:
  - name: api
    image: localhost:5001/orders-api:2.0
    env: [{name: STARTUP_DELAY, value: "40"}]
    ports: [{name: http, containerPort: 8000}]
    startupProbe: {httpGet: {path: /health, port: http}, periodSeconds: 2, failureThreshold: 60}
    livenessProbe: {httpGet: {path: /health, port: http}}
---
apiVersion: v1
kind: Pod
metadata: {name: slow-endpoint}
spec:
  containers:
  - name: api
    image: localhost:5001/orders-api:2.0
    ports: [{name: http, containerPort: 8000}]
    livenessProbe:
      httpGet: {path: "/work?ms=1500", port: http}
      periodSeconds: 5
EOF
kubectl get pod slow-no-startup -o jsonpath='{.spec.containers[0].livenessProbe}{"\n"}'
sleep 240
kubectl get pods slow-no-startup slow-startup slow-endpoint
kubectl get events --field-selector involvedObject.name=slow-endpoint,reason=Unhealthy -o custom-columns=COUNT:.count,MSG:.message | tail -1
kubectl get pod slow-no-startup -o jsonpath='lastState={.status.containerStatuses[0].lastState.terminated.reason}/{.status.containerStatuses[0].lastState.terminated.exitCode}{"\n"}'
kubectl delete pod slow-no-startup slow-startup slow-endpoint --now
```

Проверено (`path` с `?` в YAML — в кавычках, иначе flow-mapping не парсится):

```
slow-no-startup   1/1     Running            3 (60s ago)   4m
slow-startup      1/1     Running            0             4m
slow-endpoint     0/1     CrashLoopBackOff   6 (32s ago)   4m4s
20      Liveness probe failed: Get "http://10.244.2.80:8000/work?ms=1500": context deadline exceeded (Client.Timeout exceeded while awaiting headers)
lastState=Error/137
```

### Шаг 5. Liveness на БД

```bash
kubectl delete deploy orders-api
# PostgreSQL этого namespace — на emptyDir, без PVC
sed 's/namespace: orders/namespace: lab-02-5/' ~/lab/k8s/orders-api/k8s/postgres.yaml \
  | sed '/volumeClaimTemplates:/,$d' \
  | sed 's|        volumeMounts: \[{name: data, mountPath: /var/lib/postgresql/data}\]|&\n      volumes: [{name: data, emptyDir: {}}]|' \
  | kubectl apply -f -
kubectl rollout status sts/postgres
for v in readiness-only liveness-db; do LP=/health; [ $v = liveness-db ] && LP=/ready
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata: {name: $v}
spec:
  replicas: 2
  selector: {matchLabels: {app: $v}}
  template:
    metadata: {labels: {app: $v}}
    spec:
      containers:
      - name: api
        image: localhost:5001/orders-api:2.0
        ports: [{name: http, containerPort: 8000}]
        env: [{name: DATABASE_URL, valueFrom: {secretKeyRef: {name: postgres, key: DATABASE_URL}}}]
        readinessProbe: {httpGet: {path: /ready, port: http}, periodSeconds: 2}
        livenessProbe: {httpGet: {path: $LP, port: http}, periodSeconds: 5, failureThreshold: 3}
EOF
done
kubectl rollout status deploy/readiness-only; kubectl rollout status deploy/liveness-db
kubectl scale sts postgres --replicas=0; sleep 60
kubectl get pods -l 'app in (readiness-only,liveness-db)'
kubectl scale sts postgres --replicas=1; kubectl rollout status sts/postgres
kubectl get pods -l 'app in (readiness-only,liveness-db)' -w     # засеките, кто быстрее станет 1/1
```

Проверено: таблица в §4.

### Уборка

```bash
kubectl config set-context --current --namespace=default
kubectl delete ns lab-02-5
rm -f /tmp/gw.txt /tmp/svc.txt
```

---

## 🔥 Кейс из прода: «каждый деплой — всплеск 502»

**Контекст.** orders-api, 12 реплик за Ingress-контроллером, 400 RPS. На каждом деплое и при каждом scale down HPA — 50–200 ответов 502/503 в логах Ingress за 5–10 секунд. Readiness настроена, rollout `maxUnavailable: 0`. Команда считала это «нормой Kubernetes».

**Разбор.**
1. Ошибки только у запросов, попавших в поды в состоянии `Terminating` (сопоставили IP upstream в логах Ingress с подами).
2. Приложение (Go, `http.Server`) по SIGTERM сразу вызывало `Shutdown()` — listener закрыт мгновенно. Ingress-контроллер узнавал об удалении пода из EndpointSlice через ~1 с и ещё держал пул keepalive-соединений к старому поду.
3. Воспроизвели на стенде — шаг 2, вариант A: 503 от Envoy и `Connection refused` через Service.

**Фикс.**
- `preStop: {sleep: {seconds: 10}}` (у Ingress за облачным LB — запас на обновление его целей) и `terminationGracePeriodSeconds: 40`.
- В приложении по SIGTERM: readiness → 503, ещё 5 с обслуживать, затем `Shutdown(ctx)` с таймаутом 25 с на текущие запросы; закрытие keepalive-соединений (`Connection: close` в ответах после SIGTERM).
- Проверка в CI на нагрузочном стенде: rollout под нагрузкой, ошибок — 0 (как вариант B/C лабы).

**Что запомнить.**
- Удаление пода и удаление его из endpoints идут параллельно — без задержки гонка неизбежна.
- preStop sleep входит в `terminationGracePeriodSeconds`.
- «Ошибки при деплое» — не норма, а отсутствие graceful shutdown.

---

## 💼 Вопросы с собеседования

### 🟢 Junior

**1. Чем liveness отличается от readiness?**
Liveness не прошла — контейнер перезапускается. Readiness не прошла — под убирается из endpoints (трафик не идёт), контейнер работает. Liveness — «процесс жив?», readiness — «готов обслуживать запросы?».

**2. Зачем startupProbe?**
Для медленно стартующих приложений: пока она не прошла, liveness и readiness не выполняются. Даёт приложению время на старт (`period × failureThreshold`), не ослабляя liveness на всё время работы.

**3. Какие дефолты у пробы?**
`periodSeconds: 10`, `timeoutSeconds: 1`, `failureThreshold: 3`, `successThreshold: 1`, `initialDelaySeconds: 0`. Таймаут в 1 секунду — частая причина ложных рестартов под нагрузкой.

### 🟡 Middle

**4. Почему нельзя проверять БД в liveness?**
Перезапуск приложения не починит БД; при её сбое liveness перезапустит все поды сразу, они уйдут в CrashLoopBackOff с растущими паузами и поднимутся позже, чем вернулась БД (на стенде: 20 с против 3 с при простое БД в минуту), с холодными кэшами и шквалом подключений. Зависимости — в readiness.

**5. Что происходит при удалении пода?**
deletionTimestamp → параллельно: kubelet выполняет preStop, шлёт SIGTERM, ждёт до `terminationGracePeriodSeconds` (30 с, включая preStop), затем SIGKILL; контроллер EndpointSlice убирает под из endpoints, kube-proxy и балансировщики обновляют правила. Порядок между ветками не гарантирован.

**6. Откуда 502 при rolling update и как их убрать?**
Приложение закрывает порт по SIGTERM раньше, чем kube-proxy/Ingress/Envoy убрали под из балансировки. Лечение: preStop sleep 5–10 с (или задержка в приложении: readiness 503 + продолжить обслуживание), достаточный grace period, корректное завершение текущих запросов и keepalive.

### 🔴 Senior

**7. Как подобрать preStop и terminationGracePeriodSeconds?**
preStop — не меньше времени распространения изменений endpoints до всех балансировщиков: секунды для kube-proxy и Envoy, 10–30 с для облачных LB с health-check'ами. Grace period ≥ preStop + максимальная длительность запроса/дренажа соединений + запас. Проверять rollout'ом под нагрузкой с подсчётом ошибок.

**8. Под удаляется 30 секунд. Почему?**
PID 1 не обрабатывает SIGTERM: shell-обёртка без `exec`, `sleep` или приложение без обработчика (для PID 1 действия сигналов по умолчанию не применяются); kubelet ждёт grace period и шлёт SIGKILL (exit 137). Решения: `exec` в entrypoint, tini/`--init`, обработчик сигналов; `shareProcessNamespace` меняет PID 1 на pause.

**9. Liveness убивает поды под нагрузкой. Что проверяете?**
Таймаут пробы (дефолт 1 с) против p99 ручки под нагрузкой; CPU-троттлинг (05-1) и паузы GC; не делает ли liveness тяжёлую работу или ходит в зависимости. Решение: лёгкий отдельный эндпоинт без зависимостей, таймаут 3–5 с, `failureThreshold` повыше; liveness вообще не обязательна, если процесс сам падает при зависании.

---

## ⚠️ Подводные камни

- `timeoutSeconds: 1` по умолчанию — медленная ручка в liveness убивает живой сервис.
- Liveness с проверкой БД/зависимостей — каскадный рестарт всех подов при сбое зависимости.
- Без startupProbe медленный старт даёт «плавающий» CrashLoop.
- Без preStop/задержки в приложении — ошибки на каждом rollout и scale down.
- preStop входит в grace period; preStop 30 с при дефолтном grace оставляет приложению 0 с.
- `preStop: exec: sleep` не работает в distroless — используйте `preStop: sleep:` (1.33+).
- PID 1 игнорирует SIGTERM без обработчика — 30 с на каждое удаление и exit 137.
- `?` в пути пробы в flow-YAML (`{path: /work?ms=1}`) ломает парсинг — кавычки.
- Readiness, зависящая от необязательной зависимости, выводит из строя весь сервис.

---

## Чеклист

- [ ] Объясню назначение трёх проб и их дефолты.
- [ ] Настрою startupProbe для медленного старта.
- [ ] Объясню каскад от liveness на БД и воспроизведу его.
- [ ] Нарисую параллельные ветки удаления пода и найду гонку.
- [ ] Уберу ошибки при rollout preStop'ом или задержкой в приложении и докажу это замером.
- [ ] Найду причину «под удаляется 30 секунд».

---

## Задание со звёздочкой

Перенесите graceful shutdown в сквозной сценарий и докажите его на внешнем пути:

1. В `~/lab/k8s/orders-api/k8s/orders-api.yaml` добавьте `preStop: {sleep: {seconds: 5}}`, `terminationGracePeriodSeconds: 20`, startupProbe и уберите зависимость liveness от чего-либо, кроме процесса.
2. Запустите нагрузку на `http://orders.localhost:8088/api/orders` с хоста (цикл `curl -s -o /dev/null -w '%{http_code}\n'`) и сделайте `kubectl -n orders rollout restart deploy/orders-api` 5 раз подряд. Посчитайте не-200.
3. Повторите со `SHUTDOWN_DELAY=0` и без preStop. Разница?
4. Добавьте `?sleep=` в `/work` (длинный запрос 3 с) и проверьте, дожидается ли приложение текущих запросов при остановке. Что нужно поменять в orders-api, чтобы дожидалось?

---

→ Следующая часть: **03-1. Сеть подов и CNI** — модуль «Сеть»: у каждого пода свой IP, маршруты между узлами kind, veth и tcpdump на узле, MTU и оверлеи, исчерпание podCIDR; со ссылками на курс `networks`.
