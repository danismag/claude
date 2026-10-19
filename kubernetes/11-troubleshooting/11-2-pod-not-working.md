# 11-1. Под не работает

> Модуль 11 «Диагностика» · часть 1 из 3 · 🟢🟡🔴 · ~45 мин чтения + ~1 ч тренажёров · Нужно: стенд 00-1. Опирается на 02-1 (состояния пода), 05-1 (ресурсы), 05-2 (планирование), 04-2 (тома), 02-5 (probes).

---

## Зачем это DevOps-у

«Под не стартует» — самая частая жалоба разработчиков и самый частый вопрос live-собеседования: дают кластер со сломанным подом и смотрят, как вы ищете причину. Важна не память на все ошибки, а **методика**: за 2–3 команды понять, на каком шаге жизни пода он застрял — планирование, образ, конфигурация, запуск процесса, работа приложения, готовность — и чья это проблема: платформы или приложения.

В этой части — методика и десять тренажёров на стенде; в 11-2 — тот же подход для сети, в 11-3 — для узлов и control plane.

---

## 1. Методика 🟢

```
kubectl get pod <p> -o wide            1. STATUS, READY, RESTARTS, NODE — на каком шаге?
kubectl describe pod <p>               2. Events (внизу) и Last State контейнеров — почему?
kubectl logs <p> [-c c] [--previous]   3. что говорит приложение (если процесс запускался)
kubectl get events --sort-by=.lastTimestamp   (контекст: узел, PVC, ReplicaSet)
kubectl debug <p> --copy-to=… / -it --target  4. руками внутри (00-2 §6)
```

По STATUS сразу понятен шаг:

| STATUS | Шаг | Чья проблема | Где смотреть |
|---|---|---|---|
| `Pending` (NODE пусто) | планирование | платформа/манифест | событие `FailedScheduling` |
| `Pending` / `ContainerCreating` (NODE есть) | тома, сеть, образ | платформа | события пода: `FailedMount`, `FailedCreatePodSandBox` |
| `ErrImagePull` / `ImagePullBackOff` | образ | манифест/реестр | `state.waiting.message` |
| `CreateContainerConfigError` | конфигурация | манифест | `state.waiting.message` |
| `RunContainerError`, `StartError` (exit 128) | запуск процесса | образ/команда | `lastState.terminated.message` |
| `CrashLoopBackOff`, `Error` | процесс падает | приложение | `logs`, `lastState.exitCode` |
| `OOMKilled` (137) | память | приложение/лимиты | `lastState`, 05-1 |
| `Running`, READY `0/1` | готовность | приложение/проба | событие `Unhealthy` |
| `Terminating` долго | остановка | grace/finalizer | 02-5, 09-2 |

## 2. Десять тренажёров 🟡

Проверено на стенде — сводка `kubectl get pods` через 50 секунд после `apply`:

```
t01-bad-tag      0/1   ImagePullBackOff             0
t02-no-registry  0/1   ImagePullBackOff             0
t03-crash        0/1   Error                        3
t04-no-cm        0/1   CreateContainerConfigError   0
t05-oom          0/1   OOMKilled                    2
t06-too-big      0/1   Pending                      0
t07-selector     0/1   Pending                      0
t08-pvc          0/1   Pending                      0
t09-not-ready    0/1   Running                      0
t10-bad-cmd      0/1   RunContainerError            3
```

Разбор (сообщения — проверено):

**t01 — тега нет в реестре.** `state.waiting.message`: `… failed to resolve reference "localhost:5001/orders-api:9.9": localhost:5001/orders-api:9.9: not found`. Проверить теги в реестре, ошибку в CI, где тег должен был появиться.

**t02 — реестр недоступен.** `failed to do request: Head "https://registry.invalid.lab/v2/app/manifests/1.0…`: DNS/сеть/TLS до реестра. Отличие от t01 — ошибка **до** реестра, а не «не найдено». Сюда же — `401/403` (нет или неверный `imagePullSecrets`) и `429` (лимиты Docker Hub, ECR Public — 08-1).

**t03 — приложение падает.** STATUS `Error`/`CrashLoopBackOff`, `lastState: Error/1`. Логи (проверено): `kubectl logs t03-crash` → `db config missing`. В период back-off **`kubectl logs` без `--previous`** показывает вывод последнего упавшего экземпляра; `--previous` на стенде отвечал `unable to retrieve container logs` (то же было в 05-1). Если логов нет вовсе — termination message (02-1 §7).

**t04 — нет ConfigMap.** `configmap "app-config" not found`. Создать объект или исправить имя; под оживёт сам без пересоздания (02-1), но не мгновенно: kubelet повторяет попытку с back-off, и через 6 с после создания ConfigMap на стенде под ещё был в `CreateContainerConfigError` (проверено) — ждите до следующей попытки (десятки секунд) или пересоздайте под.

**t05 — OOM.** `lastState: OOMKilled/137`. Событий про OOM нет — смотрите `describe` → Last State и журнал ядра узла (05-1 §4).

**t06 — не хватает ресурсов.** `0/4 nodes are available: 1 node(s) had untolerated taint(s), 3 Insufficient cpu.` — request больше любого узла (здесь 64 CPU). Снизить request или добавить узлы; проверить, не «съели» ли allocatable requests других подов (05-1 §2).

**t07 — нет подходящих узлов.** `3 node(s) didn't match Pod's node affinity/selector` — `nodeSelector: {disktype: nvme}`, а такой метки нет ни у одного узла. Метки узлов: `kubectl get nodes --show-labels` (05-2).

**t08 — PVC не создан.** У пода — `pod has unbound immediate PersistentVolumeClaims`; у PVC — `storageclass.storage.k8s.io "fast-ssd" not found`. Причина в PVC, а не в поде: смотрите события PVC (04-2).

**t09 — работает, но не готов.** `Running`, `0/1`, событие `Readiness probe failed: HTTP probe failed with statuscode: 404` — проба на `/healthz`, а приложение отдаёт `/ready`. Под не получает трафик (03-2), рестартов нет (02-5).

**t10 — нечего запускать.** `RunContainerError`, `lastState: StartError/128`, `exec: "/app/server": stat /app/server: no such file or directory`. Проверка копией пода с другой командой (проверено):

```bash
kubectl debug t10-bad-cmd --copy-to=t10-debug --container=app -- sh -c 'ls -la /app; which server; sleep 3600'
kubectl logs t10-debug          # ls: /app: No such file or directory
```

Каталога в образе нет — не тот образ или неверный `command`. Отличие от `127` (02-1 §3): там shell запустился и не нашёл команду, здесь не запустился сам процесс.

## 3. Приложение или платформа 🟡

| Признак | Скорее платформа | Скорее приложение |
|---|---|---|
| несколько разных сервисов на одном узле сломаны одновременно | ✓ (узел, CNI, диск — 11-3) | |
| ошибки до старта процесса (Pending, ImagePull, ContainerCreating) | ✓ (или манифест) | |
| процесс стартует и падает с понятным сообщением в логах | | ✓ |
| работало вчера, сегодня новый образ | | ✓ (сравнить `imageID`, 02-2) |
| работало вчера, образ тот же, сломалось у всех | ✓ (зависимость, DNS, сеть, секрет) | |
| `OOMKilled` | лимит занижен (обсуждается) | утечка/рост (обсуждается) |

Привычка, которая экономит часы: первым делом `kubectl get pods -A --field-selector=status.phase!=Running -o wide` — один это под или все поды узла/namespace.

## 4. Под без shell и «внутри» 🟡

- `kubectl debug -it <pod> --image=busybox:1.37 --target=<c>` — инструменты рядом с живым контейнером (00-2 §6).
- `kubectl debug <pod> --copy-to=<new> --container=<c> -- <команда>` — копия падающего пода с другой командой (`sleep`), чтобы зайти и запустить приложение руками.
- `kubectl debug node/<узел>` — узел: `crictl logs`, `journalctl -u kubelet`, файловая система (11-3).
- `kubectl exec <pod> -- env`, `cat /etc/resolv.conf`, проверка доступа к зависимостям изнутри (11-2).

---

## 🔧 Лаба

### Шаг 0. Тренажёры

```bash
kubectl config use-context kind-lab
kubectl create ns lab-11-1
kubectl config set-context --current --namespace=lab-11-1
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata: {name: t01-bad-tag}
spec: {containers: [{name: app, image: "localhost:5001/orders-api:9.9"}]}
---
apiVersion: v1
kind: Pod
metadata: {name: t02-no-registry}
spec: {containers: [{name: app, image: "registry.invalid.lab/app:1.0"}]}
---
apiVersion: v1
kind: Pod
metadata: {name: t03-crash}
spec: {containers: [{name: app, image: "python:3.12-slim", command: ["python", "-c", "import sys; print('db config missing', file=sys.stderr); sys.exit(1)"]}]}
---
apiVersion: v1
kind: Pod
metadata: {name: t04-no-cm}
spec: {containers: [{name: app, image: "busybox:1.37", command: ["sleep","3600"], envFrom: [{configMapRef: {name: app-config}}]}]}
---
apiVersion: v1
kind: Pod
metadata: {name: t05-oom}
spec: {containers: [{name: app, image: "python:3.12-slim", command: ["python","-c","b=b'x'*(300*2**20)"], resources: {limits: {memory: 128Mi}}}]}
---
apiVersion: v1
kind: Pod
metadata: {name: t06-too-big}
spec: {containers: [{name: app, image: "busybox:1.37", command: ["sleep","3600"], resources: {requests: {cpu: "64"}}}]}
---
apiVersion: v1
kind: Pod
metadata: {name: t07-selector}
spec: {nodeSelector: {disktype: nvme}, containers: [{name: app, image: "busybox:1.37", command: ["sleep","3600"]}]}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: t08-pvc}
spec: {storageClassName: fast-ssd, accessModes: [ReadWriteOnce], resources: {requests: {storage: 1Gi}}}
---
apiVersion: v1
kind: Pod
metadata: {name: t08-pvc}
spec: {containers: [{name: app, image: "busybox:1.37", command: ["sleep","3600"], volumeMounts: [{name: d, mountPath: /d}]}], volumes: [{name: d, persistentVolumeClaim: {claimName: t08-pvc}}]}
---
apiVersion: v1
kind: Pod
metadata: {name: t09-not-ready}
spec: {containers: [{name: app, image: "localhost:5001/orders-api:2.0", readinessProbe: {httpGet: {path: /healthz, port: 8000}, periodSeconds: 3}}]}
---
apiVersion: v1
kind: Pod
metadata: {name: t10-bad-cmd}
spec: {containers: [{name: app, image: "busybox:1.37", command: ["/app/server"]}]}
EOF
sleep 50; kubectl get pods -o wide
```

### Шаг 1. Разбор без подсказок

Для каждого пода, **не читая §2**: определите шаг по STATUS (таблица §1), найдите сообщение (`describe`, `get … -o jsonpath='{.status.containerStatuses[0].state.waiting.message}'`, события) и сформулируйте исправление одной фразой. Затем сверьтесь с §2.

Подсказки-команды:

```bash
for p in t01-bad-tag t02-no-registry t04-no-cm t10-bad-cmd; do echo "$p: $(kubectl get pod $p -o jsonpath='{.status.containerStatuses[0].state.waiting.message}')"; done
for p in t03-crash t05-oom t10-bad-cmd; do echo "$p: $(kubectl get pod $p -o jsonpath='{.status.containerStatuses[0].lastState.terminated.reason}/{.status.containerStatuses[0].lastState.terminated.exitCode}')"; done
for p in t06-too-big t07-selector t08-pvc; do kubectl get events --field-selector involvedObject.name=$p,reason=FailedScheduling -o jsonpath='{.items[-1:].message}{"\n"}'; done
kubectl get events --field-selector involvedObject.kind=PersistentVolumeClaim
kubectl logs t03-crash
kubectl get events --field-selector involvedObject.name=t09-not-ready,reason=Unhealthy
```

### Шаг 2. Исправить

```bash
kubectl create configmap app-config --from-literal=MODE=prod; kubectl get pod t04-no-cm -w   # Running без пересоздания, но не сразу (см. ниже)
kubectl debug t10-bad-cmd --copy-to=t10-debug --container=app -- sh -c 'ls -la /app; which server; sleep 3600'
kubectl logs t10-debug
```

Остальные — пересоздайте с исправленным манифестом (тег `2.0`, request `100m`, без `nodeSelector`, StorageClass `standard`, проба `/ready`, лимит памяти 512Mi) и убедитесь, что все `Running 1/1`.

### Уборка

```bash
kubectl config set-context --current --namespace=default
kubectl delete ns lab-11-1
```

---

## 🔥 Кейс из прода: «Pending два часа — а дело в зоне диска»

**Контекст.** После планового обновления узлов StatefulSet поиска (3 реплики) — одна реплика `Pending` два часа. Дежурный добавил узлы (Cluster Autoscaler тоже добавил) — не помогло.

**Разбор.**
1. `describe pod` → `FailedScheduling`: `0/12 nodes are available: 4 Insufficient memory, 8 node(s) had volume node affinity conflict.`
2. PVC реплики — облачный диск в зоне `b`. В зоне `b` четыре узла, и на всех не хватает памяти; новые узлы автоскейлер создал в зонах `a` и `c` (там дешевле/был запас квоты).
3. Сообщение scheduler'а прямо говорило обе причины, но читали только первую часть.

**Фикс.**
- Добавили ёмкость именно в зону `b` (отдельная группа узлов на зону; CA с `balance-similar-node-groups`).
- Для StatefulSet с зональными дисками — topology spread по зонам и запас ёмкости в каждой зоне (05-2, 04-2).
- В runbook «Pending»: читать сообщение `FailedScheduling` целиком — каждая группа узлов и её причина.

**Что запомнить.**
- `FailedScheduling` перечисляет причины по всем узлам — читать полностью.
- Под с PVC зонального диска может планироваться только в зону диска.
- Добавить узлы «куда-нибудь» не помогает подам с привязкой к зоне.

---

## 💼 Вопросы с собеседования

### 🟢 Junior

**1. Под в CrashLoopBackOff — ваши действия?**
`describe pod` (Last State: код выхода, reason, message; события), `kubectl logs` (в период back-off — вывод последнего упавшего экземпляра) и `--previous`. По коду: 1 и прочие — ошибка приложения (логи), 137 — OOM или kill, 127/128 — нет команды/бинарника. Затем `kubectl debug --copy-to` с `sleep`.

**2. Под в ImagePullBackOff?**
`state.waiting.message`: `not found` — нет тега; `401/403` — секреты реестра; `429` — лимиты; ошибка DNS/TLS — недоступен реестр. Проверить имя образа, тег, `imagePullSecrets`, доступ узла к реестру.

### 🟡 Middle

**3. Под Pending. Где смотреть?**
Событие `FailedScheduling`: ресурсы (`Insufficient`), taints, affinity/selector, тома (`unbound PVC`, `volume node affinity conflict`), spread. Нет событий — scheduler не работает или чужой `schedulerName` (01-1). Причины PVC — в событиях самого PVC.

**4. Под Running, но не Ready. Что это значит?**
Процесс работает, readiness не проходит — под исключён из Service. Событие `Unhealthy` с причиной (код, таймаут), проверка пути/порта пробы и зависимостей, которые проверяет readiness (02-5).

**5. Как отличить проблему приложения от проблемы платформы?**
Масштаб (один под или все поды узла/namespace), шаг жизни пода (до старта процесса — чаще платформа/манифест, после — приложение), что изменилось (новый образ — приложение; ничего — зависимости/платформа), `imageID` и события узлов.

### 🔴 Senior

**6. Под падает без логов и без shell в образе. Как найдёте причину?**
Termination message/`FallbackToLogsOnError`, код выхода и reason в `lastState`; `kubectl debug --copy-to` с заменой команды на `sleep` и тем же образом; при distroless — копия с образом-отладчиком и общим PID-namespace (`--share-processes`), запуск бинарника руками; журнал ядра узла (OOM, seccomp), `crictl inspect` на узле.

---

## ⚠️ Подводные камни

- `kubectl logs --previous` в момент перезапуска может быть недоступен — пробуйте без `--previous` и повторно.
- OOM не создаёт событий — смотрите `lastState`.
- Ошибки PVC — в событиях PVC, а не пода.
- `CreateContainerConfigError` исправляется созданием объекта — пересоздавать под не нужно.
- `nodeName` в манифесте прячет ошибки scheduler'а (04-2).
- Ошибки admission и квот у подов контроллеров — в событиях ReplicaSet/Job (05-2, 06-3, 09-2).
- Сообщение `FailedScheduling` надо читать целиком.

---

## Чеклист

- [ ] По STATUS назову шаг жизни пода и где смотреть причину.
- [ ] Разберу все десять тренажёров без подсказок.
- [ ] Найду логи упавшего контейнера и причину без логов.
- [ ] Отлажу под без shell через `kubectl debug`.
- [ ] Отличу проблему приложения от проблемы платформы.

---

## Задание со звёздочкой

Соберите свой «тренажёр для коллег»:

1. Напишите 5 сломанных Deployment'ов (не подов!) с разными причинами: квота namespace, admission-политика (06-3), PDB при drain, неверный `targetPort` в Service (03-2), Secret без ключа.
2. Для каждого — спрятанная под спойлер (`<details>`) причина и исправление, как в 12-2.
3. Дайте коллеге и засеките время: какие ошибки находят дольше всего? Почему (подсказка: те, где проблема видна не у пода)?

---

→ Следующая часть: **11-2. Сеть и DNS: пошагово** — методика по слоям для сквозного запроса `orders.localhost → Gateway → HTTPRoute → Service → EndpointSlice → под → DNS → БД` и восемь сетевых поломок на стенде.
