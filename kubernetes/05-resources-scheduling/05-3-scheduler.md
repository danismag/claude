# 05-2. Scheduler

> Модуль 5 «Ресурсы и планирование» · часть 2 из 4 · 🟢🟡🔴 · ~1,5 ч чтения + ~45 мин лабы · Нужно: стенд 00-1; в лабе узлам временно ставятся метки зон и taint

---

## Зачем это DevOps-у

«Все три реплики оказались на одном узле — узел упал, сервис лёг», «под Pending два часа», «после добавления anti-affinity деплой завис», «узлы под базы занимает чужая мелочь» — всё это настройки планирования. Scheduler делает ровно то, что написано в манифесте, и молча — то, что не написано. На собеседовании: «taint и affinity — в чём разница», «как разнести реплики по зонам», «что такое preemption».

В сквозном сценарии orders-api (2 реплики) и PostgreSQL сейчас размещены как получилось. В этой части — как сделать, чтобы отказ одного узла или зоны не ронял сервис.

---

## 1. Как scheduler выбирает узел 🟡

Для каждого пода без `nodeName`:

1. **Фильтрация** (Filter) — отбросить узлы, где под не может работать: ресурсы (requests, 05-1), `nodeSelector`/required affinity, taints без tolerations, порты hostPort, тома (зона/узел PV, 04-2), anti-affinity, topology spread с `DoNotSchedule`, лимит подов.
2. **Оценка** (Score) — расставить оставшиеся: свободные ресурсы, preferred affinity, spread с `ScheduleAnyway`, образ уже на узле.
3. **Привязка** (Bind) — записать `spec.nodeName`.

Если после фильтрации узлов нет — `FailedScheduling` с причинами **по каждому узлу** и попытка вытеснения (§5). Читать его надо целиком (проверено, anti-affinity и 3 worker'а):

```
0/4 nodes are available: 1 node(s) had untolerated taint(s), 3 node(s) didn't match pod anti-affinity rules.
no new claims to deallocate, preemption: 0/4 nodes are available: 1 Preemption is not helpful for scheduling, 3 No preemption victims found for incoming pod.
```

Перевод: control-plane — taint, три worker'а — anti-affinity; вытеснение не поможет.

Scheduler **не перепланирует** работающие поды. Распределение, ставшее плохим (узлы добавили, поды накопились на одних узлах), исправляет только пересоздание подов — rollout или descheduler.

## 2. Куда можно: nodeSelector и node affinity 🟢🟡

```yaml
nodeSelector: {disktype: nvme}                         # простое равенство меток
affinity:
  nodeAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:    # обязательно (фильтр)
      nodeSelectorTerms:
      - matchExpressions: [{key: topology.kubernetes.io/zone, operator: In, values: [zone-a, zone-b]}]
    preferredDuringSchedulingIgnoredDuringExecution:   # желательно (вес в оценке)
    - weight: 50
      preference: {matchExpressions: [{key: node.kubernetes.io/instance-type, operator: In, values: [m6i.large]}]}
```

`IgnoredDuringExecution` — если метку узла сняли, работающий под не тронут. Операторы: `In`, `NotIn`, `Exists`, `DoesNotExist`, `Gt`, `Lt`. Стандартные метки: `kubernetes.io/hostname`, `topology.kubernetes.io/zone` и `region`, `node.kubernetes.io/instance-type`, `kubernetes.io/arch` (на смешанных кластерах amd64/arm64 — обязательно).

## 3. Рядом и врозь: pod affinity и anti-affinity 🟡

Правила относительно **других подов**: «ставить рядом с подами redis» (affinity) или «не ставить на узел, где уже есть под этого приложения» (anti-affinity) — в пределах `topologyKey` (узел, зона).

Проверено — 4 реплики с required anti-affinity по `kubernetes.io/hostname` на 3 worker'ах:

```
lab-worker2:Running×1 lab-worker3:Running×1 lab-worker:Running×1 <none>:Pending×1
```

Required anti-affinity — «не больше одной реплики на узел», жёстко: реплик больше, чем узлов, — лишние Pending; при отказе узла замене некуда встать. Для большинства сервисов лучше **preferred** anti-affinity или topology spread. Required anti-affinity по узлу — для действительно эксклюзивных случаев (реплики etcd/ZooKeeper/брокера, которые не должны делить узел).

Pod affinity и anti-affinity — самые дорогие для scheduler'а правила (сравнение со всеми подами в топологии); в кластерах на тысячи узлов они заметно замедляют планирование.

## 4. Равномерно: topologySpreadConstraints 🟡🔴

Проверено — 6 реплик **без** правил:

```
lab-worker2:Running×1 lab-worker3:Running×2 lab-worker:Running×3
```

Встроенное распределение (системные default constraints: по узлам с `maxSkew: 3`, по зонам с `maxSkew: 5`, `ScheduleAnyway`) — только мягкий вес в оценке: 3/2/1 считается нормой.

С правилом:

```yaml
topologySpreadConstraints:
- maxSkew: 1
  topologyKey: topology.kubernetes.io/zone
  whenUnsatisfiable: DoNotSchedule          # жёстко; ScheduleAnyway — предпочтение
  labelSelector: {matchLabels: {app: zspread}}
```

Проверено (зоны: `lab-worker` → `zone-a`, остальные → `zone-b`):

```
lab-worker2:Running×2 lab-worker3:Running×1 lab-worker:Running×3     ← 3 в zone-a, 3 в zone-b
```

`maxSkew` — максимальная разница числа подов между доменами. Распределение по зонам ничего не говорит про узлы внутри зоны (в zone-b 2 и 1) — для обоих уровней ставят два правила: зона (`DoNotSchedule`) и узел (`ScheduleAnyway`).

### Ловушка: spread вешает rollout 🔴

Проверено — 3 реплики, `maxSkew: 1` по `kubernetes.io/hostname`, `DoNotSchedule`, 3 worker'а, `rollout restart`:

```
hs-plain: rollout STUCK
    hs-plain-c47c4cd5b-cbkn8 Pending       ← surge-под новой ревизии
    hs-plain-df77c4f58-h6f97 Running
    hs-plain-df77c4f58-jg5q5 Running
    hs-plain-df77c4f58-ngj2v Running
hs-mlk: rollout restart OK
```

Surge-под (maxSurge 25% → 1) считается вместе со старыми подами по `labelSelector`: куда ни поставь — на узле станет 2, у других 1, плюс узел без подов отсутствует — перекос нарушен. Лечение — `matchLabelKeys: [pod-template-hash]` (вариант `hs-mlk`): распределение считается **отдельно для каждой ревизии**, старые поды не мешают новым. Альтернативы — `maxSurge: 0, maxUnavailable: 1` или `ScheduleAnyway`. Та же ловушка встретилась в 03-2 и 01-2 (там узел с taint'ом считался доменом — `nodeTaintsPolicy: Honor` исключает такие узлы).

## 5. Узлы для своих: taints и tolerations 🟡

Taint на узле отталкивает поды без соответствующей toleration. Affinity — притягивает поды, taint — отталкивает остальных; для выделенных узлов нужны **оба**: taint (чужие не придут) + affinity/nodeSelector (свои пойдут именно туда, а не куда угодно).

| Эффект | Новые поды без toleration | Работающие поды без toleration |
|---|---|---|
| `NoSchedule` | не планируются | остаются |
| `PreferNoSchedule` | избегаются по возможности | остаются |
| `NoExecute` | не планируются | **выселяются** (сразу или через `tolerationSeconds`) |

Проверено (три пода на `lab-worker3`: без toleration, с toleration, с toleration на 20 с):

```
after NoSchedule:
   t-new Pending                 ← новый — не встал
   t-plain Running               ← работающие — остались
   t-tol Running
   t-tol20 Running
NoExecute:
  t=+0s t-plain:Completed        ← выселен сразу
  t=+20s t-tol20:Terminating     ← выселен через tolerationSeconds
  t-tol:Running                  ← остался
```

Системные taint'ы ставит сам Kubernetes: `node.kubernetes.io/not-ready`, `unreachable` (01-2), `memory-pressure`, `disk-pressure`, `pid-pressure` (05-4), `unschedulable` (cordon), `node-role.kubernetes.io/control-plane`. Ставьте свои с префиксом своей организации: `dedicated=db:NoSchedule`, `gpu=true:NoSchedule`.

## 6. Важнее других: PriorityClass и preemption 🟡🔴

Если пода нет куда поставить, scheduler ищет на узлах поды **с меньшим приоритетом**, удаление которых освободит место, и вытесняет их (graceful, с учётом PDB «по возможности»). Проверено: на трёх worker'ах — по поду `batch` с `lab-low` (100) и request 10 CPU; под `critical` с `lab-high` (100000) и request 10 CPU:

```
critical Ready after 1s on lab-worker3
batch-55c5fc9bfc-drfgg   Preempted by pod d93570d8-… on node lab-worker3
batch-55c5fc9bfc-9x8g8   Pending — 3 Insufficient cpu ... 1 No preemption victims found for incoming pod
```

Вытесненный `batch` пересоздан своим ReplicaSet'ом и висит Pending — вытеснить ему некого (его приоритет — самый низкий).

Встроенные классы — `system-cluster-critical` (2000000000) и `system-node-critical` (2000001000) для компонентов кластера (CoreDNS, CNI, kube-proxy); прикладным подам их не дают. Практика: 3–4 класса (критичные сервисы, обычные, batch/фоновые), batch с `preemptionPolicy: Never`, если он не должен никого вытеснять, а сам может быть вытеснен. Риск без классов: под с большим request «по умолчанию» вытесняет то, что важнее, — приоритет по умолчанию у всех 0, и вытеснение не работает вовсе; с классами без дисциплины — каскадные вытеснения.

## 7. Что ещё бывает 🔴

- **Несколько scheduler'ов** — `spec.schedulerName`; под с несуществующим именем вечно Pending без событий (как при остановленном scheduler'е, 01-1).
- **Scheduling gates** (`spec.schedulingGates`) — под создан, но планироваться не будет, пока внешний контроллер не снимет gate (квоты, очереди задач — Kueue).
- **Descheduler** — отдельный компонент, который выселяет поды для перепланирования (нарушенный spread, перекос загрузки). Встроенного перепланирования в Kubernetes нет.
- **Ресурсы, о которых scheduler не знает** — реальная загрузка CPU, диск, сеть. Он смотрит только на requests (05-1).

---

## 🔧 Лаба

### Шаг 0. Подготовка

```bash
kubectl config use-context kind-lab
kubectl create ns lab-05-2
kubectl config set-context --current --namespace=lab-05-2
kubectl label node lab-worker topology.kubernetes.io/zone=zone-a
kubectl label node lab-worker2 lab-worker3 topology.kubernetes.io/zone=zone-b
where() { kubectl get pods -l app=$1 -o custom-columns=N:.spec.nodeName,S:.status.phase --no-headers | sort | uniq -c | awk '{printf "%s:%s×%s ", $2, $3, $1}'; echo; }
# mkd <имя> <реплики> — Deployment из pause, доп. поля шаблона пода — со stdin
mkd() { kubectl apply -f - <<EOF
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
      containers: [{name: c, image: registry.k8s.io/pause:3.10, resources: {requests: {cpu: 10m}}}]
EOF
}
```

### Шаг 1. Без правил, anti-affinity, spread по зонам

```bash
mkd plain 6 </dev/null; sleep 6; where plain
mkd anti 4 <<'EOF'
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
          - labelSelector: {matchLabels: {app: anti}}
            topologyKey: kubernetes.io/hostname
EOF
sleep 6; where anti
P=$(kubectl get pods -l app=anti --field-selector=status.phase=Pending -o name | head -1)
kubectl get events --field-selector involvedObject.name=${P#pod/},reason=FailedScheduling -o jsonpath='{.items[-1:].message}{"\n"}'
mkd zspread 6 <<'EOF'
      topologySpreadConstraints:
      - {maxSkew: 1, topologyKey: topology.kubernetes.io/zone, whenUnsatisfiable: DoNotSchedule, labelSelector: {matchLabels: {app: zspread}}}
EOF
sleep 6; where zspread
```

Проверено: вывод в §1, §3, §4.

### Шаг 2. Spread и rollout

```bash
for v in plain mlk; do
  MLK=""; [ $v = mlk ] && MLK=", matchLabelKeys: [pod-template-hash]"
  kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata: {name: hs-$v}
spec:
  replicas: 3
  selector: {matchLabels: {app: hs-$v}}
  template:
    metadata: {labels: {app: hs-$v}}
    spec:
      terminationGracePeriodSeconds: 1
      topologySpreadConstraints:
      - {maxSkew: 1, topologyKey: kubernetes.io/hostname, whenUnsatisfiable: DoNotSchedule, labelSelector: {matchLabels: {app: hs-$v}}$MLK}
      containers: [{name: c, image: registry.k8s.io/pause:3.10, resources: {requests: {cpu: 10m}}}]
EOF
  kubectl rollout status deploy/hs-$v; kubectl rollout restart deploy/hs-$v
  kubectl rollout status deploy/hs-$v --timeout=40s && echo "hs-$v: OK" || { echo "hs-$v: STUCK"; kubectl get pods -l app=hs-$v; }
done
kubectl delete deploy plain anti zspread hs-plain hs-mlk
```

Проверено: вывод в §4.

### Шаг 3. Taints

```bash
for p in plain tol tol20; do
  T=""
  [ $p = tol ]   && T='"tolerations":[{"key":"dedicated","operator":"Equal","value":"db","effect":"NoExecute"}],'
  [ $p = tol20 ] && T='"tolerations":[{"key":"dedicated","operator":"Equal","value":"db","effect":"NoExecute","tolerationSeconds":20}],'
  kubectl run t-$p --image=registry.k8s.io/pause:3.10 --overrides="{\"spec\":{$T\"nodeSelector\":{\"kubernetes.io/hostname\":\"lab-worker3\"},\"terminationGracePeriodSeconds\":1}}"
done
kubectl wait --for=condition=Ready pod/t-plain pod/t-tol pod/t-tol20
kubectl taint node lab-worker3 dedicated=db:NoSchedule
kubectl run t-new --image=registry.k8s.io/pause:3.10 --overrides='{"spec":{"nodeSelector":{"kubernetes.io/hostname":"lab-worker3"}}}'
sleep 4; kubectl get pods; kubectl delete pod t-new --now
t0=$(date +%s); kubectl taint node lab-worker3 dedicated=db:NoExecute
for i in $(seq 1 30); do s=$(kubectl get pods --no-headers | awk '{printf "%s:%s ", $1, $3}'); [ "$s" != "$prev" ] && echo "t=+$(( $(date +%s)-t0 ))s $s" && prev=$s; sleep 1; done
kubectl taint node lab-worker3 dedicated-
```

Проверено: вывод в §5. `dedicated-` снимает все taint'ы с этим ключом (обоих эффектов).

### Шаг 4. Приоритеты и вытеснение

```bash
kubectl delete pod --all --now
kubectl apply -f - <<'EOF'
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata: {name: lab-low}
value: 100
---
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata: {name: lab-high}
value: 100000
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: batch, namespace: lab-05-2}
spec:
  replicas: 3
  selector: {matchLabels: {app: batch}}
  template:
    metadata: {labels: {app: batch}}
    spec:
      priorityClassName: lab-low
      terminationGracePeriodSeconds: 1
      containers: [{name: c, image: registry.k8s.io/pause:3.10, resources: {requests: {cpu: "10"}}}]
EOF
kubectl rollout status deploy/batch
kubectl get pods -l app=batch -o custom-columns=POD:.metadata.name,NODE:.spec.nodeName,PRIO:.spec.priority
kubectl run critical --image=registry.k8s.io/pause:3.10 --overrides='{"spec":{"priorityClassName":"lab-high","containers":[{"name":"critical","image":"registry.k8s.io/pause:3.10","resources":{"requests":{"cpu":"10"}}}]}}'
kubectl wait --for=condition=Ready pod/critical
kubectl get events --field-selector reason=Preempted -o custom-columns=OBJ:.involvedObject.name,MSG:.message
kubectl get pods -l app=batch
```

Request 10 CPU — потому что каждый узел kind видит все 12 CPU хоста (05-1): иначе «заполнить» узел не получится. Проверено: вывод в §6.

### Уборка

```bash
kubectl config set-context --current --namespace=default
kubectl delete ns lab-05-2
kubectl delete priorityclass lab-low lab-high
kubectl label node lab-worker lab-worker2 lab-worker3 topology.kubernetes.io/zone-
kubectl get nodes -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints   # только control-plane
```

---

## 🔥 Кейс из прода: «три реплики на одном узле — узел упал, сервис лёг»

**Контекст.** Сервис авторизации, 3 реплики Deployment, кластер 12 узлов. Ночью отказал один узел — авторизация недоступна 6 минут, пока поды не пересоздались на других узлах (01-2: ~5 мин 50 с до вытеснения). Все три реплики жили на этом узле.

**Разбор.**
1. Правил размещения не было. Встроенный spread — только вес (§4, 3/2/1 у шести реплик на стенде), и при массовом пересоздании (до этого был drain части узлов) scheduler сложил поды туда, где было свободнее.
2. PDB не было — drain выселил всё разом, распределение не восстановилось.
3. Анти-паттерн, который предложили сначала, — required anti-affinity по узлу — сломал бы масштабирование HPA выше 12 реплик и замену подов при отказах.

**Фикс.**
- `topologySpreadConstraints`: по зонам — `maxSkew: 1, DoNotSchedule`; по узлам — `maxSkew: 1, ScheduleAnyway`; оба с `matchLabelKeys: [pod-template-hash]` (иначе rollout зависает — шаг 2 лабы).
- PDB `minAvailable: 2` (05-4), чтобы drain не выносил все реплики разом.
- Descheduler с политикой `RemovePodsViolatingTopologySpreadConstraint` — исправляет перекос после массовых операций.
- Алерт: «все готовые реплики Deployment на одном узле/в одной зоне» (по `kube_pod_info` и `kube_deployment_spec_replicas`).

**Что запомнить.**
- Scheduler не гарантирует распределение без явных правил.
- Spread по зонам жёстко, по узлам мягко; `matchLabelKeys` от зависших rollout'ов.
- Required anti-affinity — для редких эксклюзивных случаев.

---

## 💼 Вопросы с собеседования

### 🟢 Junior

**1. Чем nodeSelector отличается от node affinity?**
nodeSelector — простое равенство меток узла. Node affinity — выражения (`In`, `NotIn`, `Exists`, `Gt`…), обязательные (`required…`) и желательные (`preferred…` с весами).

**2. Что такое taint и toleration?**
Taint на узле не пускает поды без соответствующей toleration (`NoSchedule`), предпочитает их не пускать (`PreferNoSchedule`) или выселяет работающие (`NoExecute`). Toleration в поде разрешает игнорировать taint.

### 🟡 Middle

**3. Как разнести реплики по узлам и зонам?**
`topologySpreadConstraints`: по `topology.kubernetes.io/zone` с `maxSkew: 1, DoNotSchedule`, по `kubernetes.io/hostname` — `ScheduleAnyway`; `matchLabelKeys: [pod-template-hash]`, чтобы rollout не зависал. Preferred anti-affinity — альтернатива попроще. Плюс PDB.

**4. Taint или affinity для выделенных узлов?**
Оба: taint, чтобы чужие поды туда не попадали; affinity/nodeSelector, чтобы «свои» шли именно туда (toleration только разрешает, но не притягивает).

**5. Под Pending. Как понять почему?**
`kubectl describe pod` → событие `FailedScheduling`: причина по каждой группе узлов (ресурсы, taints, affinity, тома, spread) и итог попытки вытеснения. Нет событий вообще — scheduler не работает или указан другой `schedulerName`.

### 🔴 Senior

**6. Почему после добавления topology spread завис rollout?**
Surge-под новой ревизии считается вместе со старыми подами по `labelSelector`; при `maxSkew: 1` и полном заполнении доменов его некуда поставить без нарушения перекоса. Решение — `matchLabelKeys: [pod-template-hash]` (распределение по ревизиям), `maxSurge: 0` или `ScheduleAnyway`.

**7. Как работает preemption и чем он опасен?**
Если под не помещается, scheduler ищет узел, где вытеснение подов с меньшим приоритетом освободит место, и удаляет их (graceful, PDB — по возможности). Опасности: без PriorityClass у всех 0 — не работает; с неаккуратными классами — каскады вытеснений и «голодание» низкоприоритетных; вытесненные поды пересоздаются и висят Pending. Для batch — низкий класс и `preemptionPolicy: Never`.

**8. Почему распределение подов со временем ухудшается и как исправить?**
Scheduler решает только при создании пода; добавление/удаление узлов, drain, масштабирование оставляют перекос. Исправление — пересоздание подов (rollout) или descheduler с политиками (нарушенный spread, перекос загрузки, дубликаты на узле).

---

## ⚠️ Подводные камни

- Встроенное распределение — мягкое: 3/2/1 считается нормой.
- Required anti-affinity: реплик больше узлов — Pending; отказ узла — замене некуда встать.
- Spread `DoNotSchedule` без `matchLabelKeys` вешает rollout.
- Узлы с taint'ом по умолчанию считаются доменами spread (`nodeTaintsPolicy: Ignore`).
- Toleration не притягивает под на узел — нужен ещё affinity.
- `NoExecute` выселяет работающие поды сразу (или через `tolerationSeconds`).
- Без PriorityClass вытеснение не работает; с классами — следите за каскадами.
- `schedulerName` с опечаткой — Pending без событий.
- Scheduler не видит реальной загрузки — только requests.

---

## Чеклист

- [ ] Прочитаю `FailedScheduling` и назову причину по каждому типу узлов.
- [ ] Настрою node affinity, pod anti-affinity и topology spread и объясню разницу.
- [ ] Починю зависший из-за spread rollout.
- [ ] Выделю узлы под нагрузку taint'ом и affinity.
- [ ] Покажу разницу NoSchedule и NoExecute и роль `tolerationSeconds`.
- [ ] Настрою PriorityClass и объясню вытеснение и его риски.

---

## Задание со звёздочкой

Сделайте размещение сквозного сценария устойчивым к отказу узла и зоны:

1. Разметьте узлы зонами (как в лабе). orders-api — 4 реплики с двумя правилами spread (зона — жёстко, узел — мягко) и `matchLabelKeys`.
2. PostgreSQL — на отдельном узле: taint `dedicated=db:NoSchedule` на `lab-worker3`, toleration и node affinity у StatefulSet. Что произойдёт с его PVC local-path (04-2) при переносе? Как перенести данные (04-3)?
3. Остановите kubelet на одном узле zone-b (01-2): сколько реплик orders-api останется и где появятся замены?
4. Верните всё как было: метки, taint, манифесты из `~/lab/k8s/orders-api/k8s/`.

---

→ Следующая часть: **05-3. Автоскейлинг** — HPA по CPU под нагрузкой на `/work`: формула, время реакции и обратного масштабирования, почему HPA «не видит метрики» без requests; VPA и in-place resize, KEDA; Cluster Autoscaler и Karpenter — теория.
