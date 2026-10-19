# 02-2. Deployment и ReplicaSet

> Модуль 2 «Workloads» · часть 2 из 5 · 🟢🟡🔴 · ~1,5 ч чтения + ~1 ч лабы · Нужно: стенд 00-1, образы `orders-api:2.0` и `2.1` в реестре стенда

---

## Зачем это DevOps-у

Deployment — то, чем выкатывают 90% сервисов. В работе с ним три класса проблем: «деплой прошёл, а в кластере старая версия» (CI не дождался rollout), «деплой завис и наполовину выкатился» (плохой образ, readiness), «у части подов другая версия при том же теге» (изменяемые теги и кэш образов на узлах). Все три мы воспроизведём. На собеседовании спрашивают, как работает rolling update, что дают `maxSurge`/`maxUnavailable`, как откатиться и чем Deployment отличается от ReplicaSet.

Сквозной сценарий: выкатываем orders-api 2.0 → 2.1 под нагрузкой и считаем ошибки клиентов.

---

## 1. Deployment → ReplicaSet → Pod 🟢

- **ReplicaSet** держит N подов по шаблону и селектору. Ничего не знает о версиях — только «сколько».
- **Deployment** управляет ReplicaSet'ами: на каждое изменение `spec.template` создаёт новый RS и по стратегии переводит реплики со старого на новый. Старые RS остаются с `replicas: 0` — это история для отката (`revisionHistoryLimit`, дефолт 10).

Связь RS с шаблоном — метка `pod-template-hash` (хэш шаблона) в селекторе и подах. Проверено:

```
NAME                   DESIRED   CURRENT   READY   ...   IMAGES                          SELECTOR
orders-api-6b8fc9fdf   0         0         0       ...   localhost:5001/orders-api:2.0   app=orders-api,pod-template-hash=6b8fc9fdf
orders-api-c5cffb4fd   4         4         4       ...   localhost:5001/orders-api:2.1   app=orders-api,pod-template-hash=c5cffb4fd
```

Rollout запускает **только изменение шаблона пода**. `replicas`, `strategy`, `minReadySeconds`, метки самого Deployment — нет. Перезапустить поды без изменений: `kubectl rollout restart` (меняет аннотацию `kubectl.kubernetes.io/restartedAt` в шаблоне).

`spec.selector` **неизменяем** (проверено: `spec.selector: Invalid value: … field is immutable`). Сменить — только пересоздать Deployment; без простоя — `--cascade=orphan` (01-3 §4).

## 2. Стратегии 🟢🟡

| | RollingUpdate (дефолт) | Recreate |
|---|---|---|
| Как | поднимает новые и гасит старые постепенно | гасит все старые, потом поднимает новые |
| Простой | нет (при правильных probes и shutdown — 02-5) | есть |
| Две версии одновременно | да — API и схема БД должны быть совместимы | нет |
| Когда | почти всегда | приложение не может работать в двух версиях (эксклюзивный доступ к тому RWO, несовместимая миграция) |

Замер на стенде — 4 реплики, нагрузка 4 потока клиентов (лаба, шаги 2–3):

| Стратегия | Длительность rollout | Ошибки клиентов |
|---|---|---|
| RollingUpdate 25%/25% | 3 с | 0 из 7573 |
| Recreate | 7 с | 30 из 3960, окно ошибок **9,7 с** |

У orders-api в стенде `SHUTDOWN_DELAY=5`: после SIGTERM под ещё 5 секунд отвечает на запросы (02-5). Без этого и rolling update даёт ошибки.

### maxSurge и maxUnavailable 🟡

- `maxSurge` — сколько подов **сверх** `replicas` можно создать во время rollout;
- `maxUnavailable` — сколько подов **из** `replicas` может быть недоступно.

Проценты округляются: surge — вверх, unavailable — вниз. Дефолт 25%/25%: для 4 реплик — +1 / −1. Оба 0 запрещено (проверено: `maxUnavailable: Invalid value: 0: may not be 0 when maxSurge is 0`).

Последовательность событий при 25%/25% и 4 репликах (проверено):

```
Scaled up replica set orders-api-c5cffb4fd from 0 to 1
Scaled down replica set orders-api-6b8fc9fdf from 4 to 3
Scaled up replica set orders-api-c5cffb4fd from 1 to 2
Scaled down replica set orders-api-6b8fc9fdf from 3 to 2
...
Scaled down replica set orders-api-6b8fc9fdf from 1 to 0
```

| Настройка | Поведение | Когда |
|---|---|---|
| `maxSurge: 25%, maxUnavailable: 25%` | быстро, временно −25% мощности | дефолт |
| `maxSurge: 1, maxUnavailable: 0` | никогда не меньше `replicas` готовых; медленнее; нужен запас ресурсов на +1 под | сервисы под нагрузкой |
| `maxSurge: 0, maxUnavailable: 1` | без лишних ресурсов, −1 под на время | нет места в кластере, лицензии «по подам» |
| `maxSurge: 100%` | новая версия поднимается целиком рядом (почти blue-green) | быстрый rollout с двойным запасом ресурсов |

## 3. Готовность и сроки: minReadySeconds, progressDeadlineSeconds 🟡

**Под считается доступным** (available), когда он Ready не меньше `minReadySeconds` (дефолт 0). Это защита от подов, которые проходят readiness и падают через несколько секунд: rollout не идёт дальше, пока новый под не «продержался». Цена — время (проверено): `maxSurge=1, maxUnavailable=0` для 4 реплик — **4 с** без `minReadySeconds` и **41 с** с `minReadySeconds: 10`.

**`progressDeadlineSeconds`** (дефолт 600) — если rollout не продвигается дольше этого времени, condition `Progressing` становится `False` с причиной `ProgressDeadlineExceeded`. Rollout **не откатывается** сам — Deployment просто сообщает о проблеме. `kubectl rollout status` при этом выходит с кодом 1 — на это и должен опираться CI.

Проверено (`progressDeadlineSeconds: 30`, образ с несуществующим тегом `2.9`):

```
Waiting for deployment "orders-api" rollout to finish: 2 out of 4 new replicas have been updated...
error: deployment "orders-api" exceeded its progress deadline
rollout status exit=1 after 32s

NAME         READY   UP-TO-DATE   AVAILABLE   AGE
orders-api   3/4     2            3           6m33s

orders-api-5fbc95fb6-px7fq 0/1 ErrImagePull
orders-api-5fbc95fb6-r75sh 0/1 ErrImagePull
orders-api-6b8fc9fdf-hqdhz 1/1 Running
orders-api-6b8fc9fdf-qcqqs 1/1 Running
orders-api-6b8fc9fdf-sb74t 1/1 Running

Available=True MinimumReplicasAvailable: Deployment has minimum availability.
Progressing=False ProgressDeadlineExceeded: ReplicaSet "orders-api-5fbc95fb6" has timed out progressing.
```

Что произошло: `maxUnavailable: 25%` разрешил убить один старый под, `maxSurge: 25%` — создать один новый сверх; оба новых не стартовали; осталось 3 старых. Сервис работает (945 из 945 запросов успешны), но **на 75% мощности** — и будет так, пока кто-то не откатит. С `maxUnavailable: 0` мощность не упала бы.

## 4. Откат и история 🟡

```bash
kubectl rollout history deploy/orders-api
kubectl rollout history deploy/orders-api --revision=6      # шаблон ревизии
kubectl rollout undo deploy/orders-api                      # на предыдущую
kubectl rollout undo deploy/orders-api --to-revision=4
kubectl rollout pause / resume deploy/orders-api            # серия правок одним rollout'ом
```

Проверено:

```
REVISION  CHANGE-CAUSE
4         image 2.0, Recreate
5         image 2.0, Recreate
6         image 2.9 (нет такого тега)

Warning: resource deployments/orders-api was previously managed with 'kubectl apply'. Rolling back will not update the kubectl.kubernetes.io/last-applied-configuration annotation, ...
deployment.apps/orders-api rolled back
undo took 1s

REVISION  CHANGE-CAUSE
4         image 2.0, Recreate
6         image 2.9 (нет такого тега)
7         image 2.0, Recreate
```

Детали, которые встречаются в работе:

- **Undo не создаёт новый RS**, если шаблон совпадает со старым: ревизия 5 стала 7 (тот же ReplicaSet поднят снова). Откат быстрый — образ уже на узлах.
- **`CHANGE-CAUSE` — просто аннотация** `kubernetes.io/change-cause` Deployment'а, копируемая в новый RS. Поставили её после `set image` — она «прилипла» и к следующей ревизии (4 и 5 — одинаковые подписи у разных ревизий). Флаг `--record` удалён; ставьте аннотацию в том же apply, что и изменение.
- **Undo расходится с Git.** Предупреждение kubectl — об этом: в кластере теперь ревизия 7, а в манифесте (и в `last-applied`) — то, что вы применили последним. Следующий `kubectl apply` из CI вернёт плохую версию. В GitOps откат делают **в Git** (revert коммита), а не `rollout undo` (08-1).

## 5. Теги, дайджесты и кэш образов 🟡🔴

`imagePullPolicy` по умолчанию: `Always` для тега `latest` или без тега, `IfNotPresent` — для любого другого тега и дайджеста. При `IfNotPresent` kubelet берёт образ **из кэша узла**, если там есть образ с таким именем и тегом, — не сверяясь с реестром.

Опыт (лаба, шаг 6): тег `2.1` перезаписан новой сборкой (`APP_VERSION=2.1-hotfix`), с одного узла кэш удалён, `kubectl rollout restart`. Проверено:

```
orders-api-dd6b8699c-5jg27   lab-worker    053e1ef2…   ← старая 2.1 из кэша
orders-api-dd6b8699c-7x4rz   lab-worker3   053e1ef2…
orders-api-dd6b8699c-d2q52   lab-worker    053e1ef2…
orders-api-dd6b8699c-dm6cf   lab-worker2   02d5d91c…   ← новая 2.1 из реестра

requests=655 ok=654 errors=1 ... versions={'2.1-hotfix': 178, '2.1': 476}
```

Один и тот же Deployment с одним и тем же `image:` отдаёт две разные версии — в зависимости от того, на каком узле под. Хуже того, это проявляется не сразу, а при перепланировании подов (drain, масштабирование).

Лечение — **деплоить по дайджесту**: `image: localhost:5001/orders-api@sha256:02d5…`. Проверено: после `set image …@sha256:02d5d91c…` все 4 пода с одним дайджестом, 759 из 759 ответов — `2.1-hotfix`. Дайджест берут из вывода сборки/push в CI (курс `cicd`, 03-1: промоушен по дайджесту) или `crane digest`/`skopeo inspect`. Тег можно оставить для людей: `orders-api:2.1@sha256:…` — используется дайджест.

`imagePullPolicy: Always` тоже решает проблему, но ценой зависимости каждого старта пода от реестра (и лимитов Docker Hub); при `Always` kubelet всё равно не качает слои заново, если дайджест совпал, — сверяет только манифест.

`status.containerStatuses[].imageID` — фактический дайджест запущенного образа. Это первое, на что смотреть при «у части подов не та версия».

## 6. Масштабирование и HPA 🟢

`kubectl scale deploy/orders-api --replicas=6` меняет `replicas` через подресурс `scale`, не создавая ревизию. С HPA `replicas` в манифесте не держат (01-3, кейс). Масштабирование RS напрямую бесполезно — Deployment вернёт число.

При масштабировании во время rollout (`proportional scaling`) Deployment распределяет добавленные реплики между старым и новым RS пропорционально — чтобы не увеличивать долю непроверенной версии.

---

## 🔧 Лаба

### Шаг 0. Подготовка

Нужны образы `localhost:5001/orders-api:2.0` (00-1) и `2.1`:

```bash
cd ~/lab/k8s/orders-api
docker build -t localhost:5001/orders-api:2.1 --build-arg APP_VERSION=2.1 . && docker push localhost:5001/orders-api:2.1

kubectl create ns lab-02-2
kubectl config set-context --current --namespace=lab-02-2
kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata: {name: orders-api, namespace: lab-02-2}
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
        env: [{name: SHUTDOWN_DELAY, value: "5"}]
        readinessProbe: {httpGet: {path: /ready, port: http}, periodSeconds: 2}
        resources: {requests: {cpu: 50m, memory: 32Mi}, limits: {memory: 128Mi}}
---
apiVersion: v1
kind: Service
metadata: {name: orders-api, namespace: lab-02-2}
spec:
  selector: {app: orders-api}
  ports: [{name: http, port: 80, targetPort: http}]
EOF
kubectl rollout status deploy/orders-api
```

orders-api здесь без `DATABASE_URL` — данные из памяти; БД в этой части не нужна.

Клиент нагрузки: 4 потока ходят на `/version`, считают коды, версии и окно ошибок (от первой до последней ошибки):

```bash
kubectl run client --image=python:3.12-slim --command -- sleep infinity
kubectl wait --for=condition=Ready pod/client
cat > /tmp/load.py <<'EOF'
import sys, time, urllib.request, collections, threading
dur = float(sys.argv[1]); url = sys.argv[2] if len(sys.argv) > 2 else "http://orders-api/version"
stats = collections.Counter(); versions = collections.Counter(); t_end = time.time() + dur; errs = []
def worker():
    while time.time() < t_end:
        try:
            with urllib.request.urlopen(url, timeout=2) as r:
                stats[r.status] += 1; versions[r.read().decode().split('"version": "')[1].split('"')[0]] += 1
        except urllib.error.HTTPError as e: stats[e.code] += 1; errs.append(time.time())
        except Exception as e: stats[type(e).__name__] += 1; errs.append(time.time())
        time.sleep(0.02)
ts = [threading.Thread(target=worker) for _ in range(4)]
[t.start() for t in ts]; [t.join() for t in ts]
total = sum(stats.values()); errors = total - stats[200]
win = f"{max(errs)-min(errs):.1f}s" if errs else "0s"
print(f"requests={total} ok={stats[200]} errors={errors} error_window={win} detail={dict(stats)} versions={dict(versions)}")
EOF
kubectl cp /tmp/load.py client:/tmp/load.py
kubectl exec client -- python /tmp/load.py 5
```

Проверено: `requests=940 ok=940 errors=0 … versions={'2.0': 940}`.

### Шаг 1. Rolling update под нагрузкой

```bash
kubectl exec client -- python /tmp/load.py 40 > /tmp/r1.txt &
sleep 3; t0=$(date +%s)
kubectl set image deploy/orders-api api=localhost:5001/orders-api:2.1
kubectl annotate deploy/orders-api kubernetes.io/change-cause="image 2.1" --overwrite
kubectl rollout status deploy/orders-api; echo "rollout took $(( $(date +%s)-t0 ))s"
kubectl get events --field-selector involvedObject.kind=Deployment --sort-by=.lastTimestamp -o custom-columns=MSG:.message | tail -8
wait; cat /tmp/r1.txt
kubectl get rs -o wide
```

Проверено: rollout 3 с, `requests=7573 ok=7573 errors=0 … versions={'2.0': 1077, '2.1': 6496}`; события и RS — в §1–§2.

### Шаг 2. Recreate

```bash
kubectl patch deploy orders-api -p '{"spec":{"strategy":{"type":"Recreate","rollingUpdate":null}}}'
kubectl exec client -- python /tmp/load.py 25 > /tmp/r2.txt &
sleep 3
kubectl set image deploy/orders-api api=localhost:5001/orders-api:2.0
kubectl annotate deploy/orders-api kubernetes.io/change-cause="image 2.0, Recreate" --overwrite
kubectl rollout status deploy/orders-api
wait; cat /tmp/r2.txt
```

Проверено: `requests=3960 ok=3930 errors=30 error_window=9.7s detail={200: 3930, 'ConnectionResetError': 3, 'URLError': 27}`. Окно ~10 с = 5 с `SHUTDOWN_DELAY` старых подов + старт и readiness новых.

### Шаг 3. Зависший rollout

```bash
kubectl patch deploy orders-api -p '{"spec":{"progressDeadlineSeconds":30,"strategy":{"type":"RollingUpdate","rollingUpdate":{"maxSurge":"25%","maxUnavailable":"25%"}}}}'
kubectl rollout status deploy/orders-api
t0=$(date +%s)
kubectl set image deploy/orders-api api=localhost:5001/orders-api:2.9
kubectl annotate deploy/orders-api kubernetes.io/change-cause="image 2.9 (нет такого тега)" --overwrite
kubectl rollout status deploy/orders-api --timeout=120s; echo "rollout status exit=$? after $(( $(date +%s)-t0 ))s"
kubectl get deploy orders-api
kubectl get pods -L pod-template-hash
kubectl get deploy orders-api -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}: {.message}{"\n"}{end}'
kubectl exec client -- python /tmp/load.py 5
```

Проверено: вывод в §3.

### Шаг 4. Откат

```bash
kubectl rollout history deploy/orders-api
kubectl rollout undo deploy/orders-api
kubectl rollout status deploy/orders-api
kubectl rollout history deploy/orders-api
kubectl get deploy orders-api -o jsonpath='image={.spec.template.spec.containers[0].image}{"\n"}'
```

Проверено: вывод в §4, `image=localhost:5001/orders-api:2.0`.

### Шаг 5. Цена minReadySeconds

```bash
kubectl patch deploy orders-api -p '{"spec":{"minReadySeconds":10,"strategy":{"rollingUpdate":{"maxSurge":1,"maxUnavailable":0}}}}'
kubectl rollout status deploy/orders-api
t0=$(date +%s); kubectl set image deploy/orders-api api=localhost:5001/orders-api:2.1; kubectl rollout status deploy/orders-api; echo "$(( $(date +%s)-t0 ))s"
kubectl patch deploy orders-api -p '{"spec":{"minReadySeconds":0}}'; kubectl rollout status deploy/orders-api
t0=$(date +%s); kubectl set image deploy/orders-api api=localhost:5001/orders-api:2.0; kubectl rollout status deploy/orders-api; echo "$(( $(date +%s)-t0 ))s"
kubectl patch deploy orders-api -p '{"spec":{"strategy":{"rollingUpdate":{"maxSurge":0,"maxUnavailable":0}}}}'
```

Проверено: 41 с с `minReadySeconds: 10`, 4 с без; последняя команда — `may not be 0 when maxSurge is 0`.

### Шаг 6. Один тег — две версии

```bash
kubectl set image deploy/orders-api api=localhost:5001/orders-api:2.1 && kubectl rollout status deploy/orders-api
# перезаписать тег 2.1 другой сборкой
cd ~/lab/k8s/orders-api
docker build -t localhost:5001/orders-api:2.1 --build-arg APP_VERSION=2.1-hotfix . && docker push localhost:5001/orders-api:2.1
# на одном узле «забыть» образ — как будто под туда попал впервые
docker exec lab-worker2 crictl rmi localhost:5001/orders-api:2.1
kubectl rollout restart deploy/orders-api && kubectl rollout status deploy/orders-api
kubectl get pods -l app=orders-api --field-selector=status.phase=Running \
  -o custom-columns=POD:.metadata.name,NODE:.spec.nodeName,IMAGEID:.status.containerStatuses[0].imageID
kubectl exec client -- python /tmp/load.py 4
```

Проверено: вывод в §5 — `versions={'2.1-hotfix': 178, '2.1': 476}`. Закрепите дайджест (подставьте свой из вывода `docker push`):

```bash
DIG=sha256:02d5d91c120fe1a5743bbc1875788e5ed92e873f7d6a39bc1f32420477c29c90
kubectl set image deploy/orders-api api=localhost:5001/orders-api@$DIG && kubectl rollout status deploy/orders-api
kubectl exec client -- python /tmp/load.py 4
```

Проверено: `requests=759 ok=759 errors=0 … versions={'2.1-hotfix': 759}`.

### Уборка

```bash
kubectl config set-context --current --namespace=default
kubectl delete ns lab-02-2
rm -f /tmp/load.py /tmp/r1.txt /tmp/r2.txt
# вернуть тегу 2.1 исходное содержимое (02-x и далее используют 2.1 как «просто следующую версию»)
cd ~/lab/k8s/orders-api && docker build -t localhost:5001/orders-api:2.1 --build-arg APP_VERSION=2.1 . && docker push localhost:5001/orders-api:2.1
```

---

## 🔥 Кейс из прода: «CI зелёный, а в кластере старая версия»

**Контекст.** Пайплайн деплоя: `kubectl apply -f k8s/` → job зелёный за 4 секунды. Команда выкатила исправление бага, закрыла тикет; через день баг повторился у клиента. В кластере: 3 пода из 5 — старая версия, 2 пода нового ReplicaSet в `CrashLoopBackOff` (новая версия падала на отсутствующей переменной окружения). Deployment в состоянии `Progressing=False, ProgressDeadlineExceeded` уже 23 часа.

**Разбор.**
1. `kubectl apply` возвращает успех, когда apiserver **принял** объект. Rollout идёт потом и асинхронно — CI об этом не знал.
2. Дефолт 25%/25% убил один старый под и создал один новый сверх; дальше rollout встал — ровно как в шаге 3 лабы. Сервис работал на 4/5 мощности, никто не заметил: алерта на `ProgressDeadlineExceeded` не было.
3. 503 пользователи не видели: сломанные поды не прошли readiness и в Service не попали. Все запросы обслуживали старые поды — с багом.

**Фикс.**
- В CI после apply — `kubectl rollout status deploy/<имя> --timeout=<progressDeadlineSeconds+запас>`; ненулевой код — job красный и автоматический `rollout undo` (или revert в Git для GitOps).
- `progressDeadlineSeconds` сократили до 300 с (дольше 5 минут старт не занимает), `maxUnavailable: 0` — плохой релиз не снижает мощность.
- Алерт на `kube_deployment_status_condition{condition="Progressing",status="false"}` и на расхождение `kube_deployment_status_replicas_updated` с `spec.replicas` дольше 15 минут.
- Образ в манифесте — по дайджесту из сборки: «какая версия в кластере» отвечает `imageID`, а не тег.

**Что запомнить.**
- `kubectl apply` ≠ «выкатилось»; ждать `rollout status`, который выходит с 1 при `ProgressDeadlineExceeded`.
- Deployment не откатывается сам — только сообщает.
- `maxUnavailable: 0` — плохой релиз не отнимает мощность.

---

## 💼 Вопросы с собеседования

### 🟢 Junior

**1. Чем Deployment отличается от ReplicaSet?**
ReplicaSet поддерживает N одинаковых подов. Deployment управляет ReplicaSet'ами: на каждое изменение шаблона создаёт новый RS и переводит реплики по стратегии, хранит старые RS для отката. Напрямую ReplicaSet почти не используют.

**2. Как откатить неудачный деплой?**
`kubectl rollout undo deploy/<имя>` (или `--to-revision=N`); история — `rollout history`. В GitOps — revert коммита, иначе следующая синхронизация вернёт плохую версию.

**3. Что запускает rollout?**
Изменение `spec.template` (образ, переменные, ресурсы, метки пода). Изменение `replicas` — нет. Перезапуск без изменений — `kubectl rollout restart`.

### 🟡 Middle

**4. Что делают maxSurge и maxUnavailable? Что даст `maxSurge: 1, maxUnavailable: 0`?**
Сколько подов можно создать сверх `replicas` и сколько может быть недоступно во время rollout (проценты: surge вверх, unavailable вниз). 1/0 — готовых подов никогда не меньше `replicas`, нужен запас ресурсов на +1 под, rollout медленнее; плохая версия не снижает мощность.

**5. Rollout завис. Как это понять и что Kubernetes сделает сам?**
`kubectl rollout status` (выйдет с 1 после `progressDeadlineSeconds`), condition `Progressing=False, ProgressDeadlineExceeded`, новые поды не Ready (`describe`: образ, probes, конфиг). Сам Kubernetes ничего не откатывает — откат делает человек или CI.

**6. Зачем minReadySeconds?**
Под считается доступным, только если был Ready непрерывно N секунд; rollout не идёт дальше, пока новый под не «продержался». Защищает от версий, падающих через несколько секунд после старта. Цена — время rollout (4 реплики, 10 с → +37 с на стенде).

### 🔴 Senior

**7. Почему у подов одного Deployment с одним тегом образа может быть разная версия?**
Тег перезаписан в реестре, а `imagePullPolicy: IfNotPresent` (дефолт для не-latest) берёт образ из кэша узла. Узлы, где образ был, запускают старое содержимое, новые узлы тянут новое. Проверять `status.containerStatuses[].imageID`; лечить деплоем по дайджесту и неизменяемыми тегами в реестре.

**8. Почему `rollout undo` опасен в паре с CI или GitOps?**
Он меняет объект в кластере, но не источник: манифест в Git и `last-applied-configuration` остаются с плохой версией. Следующий `apply` или sync Argo CD вернёт её. Откат — через источник истины (revert), `undo` — только как экстренная мера с немедленным revert.

**9. Что происходит при масштабировании Deployment посреди rollout?**
Proportional scaling: добавленные (или убранные) реплики распределяются между старым и новым ReplicaSet пропорционально их текущему размеру, с учётом maxSurge, чтобы не увеличить долю непроверенной версии сверх запланированной.

---

## ⚠️ Подводные камни

- `kubectl apply` успешен, когда объект принят, а не когда rollout завершён.
- `progressDeadlineSeconds` только сообщает о проблеме; откатывать надо самим.
- Дефолт 25%/25% при плохом релизе снижает мощность на 25% — надолго, если никто не смотрит.
- Изменяемый тег + `IfNotPresent` = разные версии на разных узлах; деплойте по дайджесту.
- `CHANGE-CAUSE` — аннотация, копируется в каждый новый RS; ставьте её вместе с изменением, `--record` больше нет.
- `rollout undo` расходится с Git и `last-applied-configuration`.
- `spec.selector` неизменяем — продумайте метки заранее.
- `revisionHistoryLimit: 0` отключает откат.
- Recreate — гарантированный простой; оправдан только при несовместимости версий или томе RWO на один под.

---

## Чеклист

- [ ] Объясню связку Deployment → ReplicaSet → Pod и роль `pod-template-hash`.
- [ ] Выберу maxSurge/maxUnavailable под ситуацию и объясню цену.
- [ ] Воспроизведу зависший rollout и найду его по `rollout status` и conditions.
- [ ] Откачу деплой и объясню, почему это надо повторить в Git.
- [ ] Найду, какой образ на самом деле запущен (`imageID`), и задеплою по дайджесту.
- [ ] Измерю ошибки клиентов во время rollout.

---

## Задание со звёздочкой

Сделайте «автоматический откат» на уровне CI без внешних инструментов:

1. Напишите в Markdown шаг пайплайна (курс `cicd`, 05-1): `kubectl apply` → `kubectl rollout status --timeout=…` → при ошибке `kubectl rollout undo` и ненулевой код job'а.
2. Проверьте его на стенде с образом `2.9` (нет тега) и с образом, который проходит readiness, но падает через 15 секунд после старта (`command: ["sh","-c","python -m app.main & sleep 15; kill %1"]`). Поймает ли его ваш шаг без `minReadySeconds`? А с `minReadySeconds: 20`?
3. Чем такой откат хуже canary с анализом метрик (03-4, Argo Rollouts)? Сформулируйте в трёх пунктах.

---

→ Следующая часть: **02-3. StatefulSet** — стабильные имена и DNS через headless Service, `volumeClaimTemplates`, порядок создания и удаления, partition rollout, судьба PVC при удалении и scale down; PostgreSQL сквозного сценария — изнутри.
