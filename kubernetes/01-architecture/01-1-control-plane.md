# 01-1. Control plane и путь запроса

> Модуль 1 «Архитектура» · часть 1 из 3 · 🟢🟡🔴 · ~1,5 ч чтения + ~1 ч лабы · Нужно: стенд 00-1

---

## Зачем это DevOps-у

«Деплой не проходит», «под висит в Pending», «HPA не масштабирует», «изменение в кластере применилось и откатилось» — у всех этих жалоб одна и та же основа: какой компонент кластера отвечает за этот шаг и жив ли он. Если вы знаете путь от `kubectl apply` до запущенного контейнера, вы за минуту отличаете «scheduler не видит места» от «controller-manager не работает» и от «kubelet не может стянуть образ».

На собеседовании вопрос «что происходит, когда вы делаете `kubectl apply`» — аналог сетевого «что происходит, когда вводишь адрес в браузере». Отвечать нужно по шагам и с механикой: authn → authz → admission → etcd → watch → контроллеры → scheduler → kubelet. Вторая частая тема — что продолжает работать, если control plane упал.

В сквозном сценарии мы ломаем control plane стенда по частям и проверяем, что `curl http://orders.localhost:8088/api/orders` при этом продолжает отвечать.

---

## 1. Компоненты 🟢

| Компонент | Где на стенде | Что делает | Если не работает |
|---|---|---|---|
| **kube-apiserver** | static pod на `lab-control-plane` | единственная точка входа в API: аутентификация, авторизация, admission, валидация, чтение/запись etcd, watch | любые изменения и чтения через API невозможны; работающие поды живут |
| **etcd** | static pod | хранилище всего состояния кластера (key-value, Raft) | apiserver не может читать и писать — то же, что выше |
| **kube-scheduler** | static pod | для каждого пода без `spec.nodeName` выбирает узел и записывает binding | новые поды висят в Pending без событий |
| **kube-controller-manager** | static pod | ~40 контроллеров: Deployment, ReplicaSet, Node, Job, EndpointSlice, ServiceAccount… | ничего не создаётся и не удаляется «само»: реплики, endpoints, вытеснение с мёртвых узлов |
| **kubelet** | systemd-сервис на каждом узле | запускает поды, назначенные узлу, через CRI; probes; статусы | поды узла не обновляются, узел через ~50 с NotReady |
| **kube-proxy** | DaemonSet | правила iptables/nftables для Service | новые Service и endpoints не работают на узле |
| CoreDNS, CNI | Deployment, DaemonSet | DNS имён сервисов, сеть подов | модуль 3 |

Static pod — под, которого kubelet создаёт сам по файлу в `/etc/kubernetes/manifests`, без apiserver. Так kubeadm (и kind) запускает control plane: курица и яйцо решены тем, что apiserver запускается не через apiserver. В API static pod виден как **mirror pod** — только для чтения.

```bash
docker exec lab-control-plane ls /etc/kubernetes/manifests
# etcd.yaml  kube-apiserver.yaml  kube-controller-manager.yaml  kube-scheduler.yaml
```

## 2. Декларативная модель и reconcile 🟢

Вы описываете **желаемое состояние** (`spec`), контроллеры приводят к нему **фактическое** (`status`). Никто не выполняет «команду создать 3 пода» — ReplicaSet-контроллер в цикле видит «нужно 3, есть 2» и создаёт один. Удалили под — цикл снова видит расхождение. Это **reconcile loop** (цикл согласования):

```
наблюдать (watch) → сравнить желаемое с фактическим → действовать → обновить status → повторить
```

Следствия, которые встречаются в работе:

- «Удалил под, а он вернулся» — им владеет контроллер; удалять надо владельца (Deployment) или менять `replicas`.
- «Поправил руками в кластере, а через минуту откатилось» — объектом управляет кто-то ещё (Argo CD, оператор, Helm при следующем upgrade) — 08-1.
- Status пишет контроллер. Если контроллер стоит — status **врёт** (проверено в лабе: Deployment показывал `READY 2/4`, а живой под был один).

## 3. Путь `kubectl apply` 🟡

```
kubectl ──HTTPS──► kube-apiserver
                    1. аутентификация (x509-сертификат, токен SA, OIDC)          → 401
                    2. авторизация (Node, RBAC)                                   → 403
                    3. mutating admission (дефолты, вебхуки, MutatingAdmissionPolicy)
                    4. валидация схемы
                    5. validating admission (квоты, PodSecurity, вебхуки, VAP)    → 403/422
                    6. запись в etcd (resourceVersion = ревизия etcd)
                        │
              watch ◄───┘ (все подписанные клиенты получают событие)
                │
  ┌─────────────┼──────────────────────────────┐
  Deployment-контроллер → создаёт ReplicaSet
  ReplicaSet-контроллер → создаёт Pod (без nodeName)
  kube-scheduler        → выбирает узел, POST binding (spec.nodeName)
  kubelet узла          → видит «свой» под: sandbox (pause) → CNI (IP) → pull образа → контейнеры
                        → пишет status (Running, Ready) в apiserver
  EndpointSlice-контроллер → добавляет IP готового пода в Service
  kube-proxy            → правила iptables на всех узлах
```

Ключевые свойства:

- **В etcd ходит только apiserver.** Контроллеры, scheduler, kubelet — клиенты API, как и вы.
- **Компоненты не вызывают друг друга.** Scheduler не «сообщает» kubelet'у — он пишет `nodeName`, kubelet узнаёт об этом по watch.
- На стенде под `busybox` прошёл весь путь за ~1 секунду (проверено по `status.conditions`): создан, назначен и инициализирован в 08:47:59, контейнер запущен и Ready в 08:48:00. Образ был в кэше узла; с pull это секунды–минуты.

Что делает kubectl, видно с `-v=6` (проверено, сокращено):

```
# первый apply: объекта нет
"Response" verb="GET"  url=".../api/v1/namespaces/lab-01-1/configmaps/demo2"  status="404 Not Found"
"Response" verb="POST" url=".../api/v1/namespaces/lab-01-1/configmaps?fieldManager=kubectl-client-side-apply&fieldValidation=Strict"  status="201 Created"
# повторный apply с изменением: прочитать, посчитать разницу, отправить патч
"Response" verb="GET"   url=".../configmaps/demo2"  status="200 OK"
"Response" verb="PATCH" url=".../configmaps/demo2?fieldManager=kubectl-client-side-apply&fieldValidation=Strict"  status="200 OK"
```

Плюс в начале два GET `/openapi/v3` — kubectl берёт схему для валидации и расчёта патча. Client-side и server-side apply — 01-3.

## 4. etcd и resourceVersion 🟡

Объекты лежат в etcd под ключами `/registry/<ресурс>/<namespace>/<имя>`. Значение — protobuf с префиксом `k8s\0` (проверено, `od -c`):

```
0000000   k   8   s  \0  \n 017  \n 002   v   1 022  \t   C   o   n   f
0000020   i   g   M   a   p 022 263 001  \n 241 001  \n 004   d   e   m
```

`metadata.resourceVersion` объекта — это **ревизия etcd** последнего изменения ключа (`mod_revision`). Проверено: ConfigMap создан → `resourceVersion=4306`, в etcd `create_revision 4306 mod_revision 4306 version 1`; после patch → `4307` и `mod_revision 4307 version 2`.

Что из этого следует:

- `resourceVersion` — не номер версии объекта, а глобальная ревизия кластера: между двумя изменениями одного объекта она может вырасти на сотни. Сравнивать их можно только на равенство; клиенты не должны вычислять с ними.
- На пустом стенде в etcd 838 ключей, из них 402 — события (`/registry/events`). Events — самый частый источник роста etcd и нагрузки на него; у них TTL 1 час (`--event-ttl`).

### Optimistic concurrency 🟡

Каждое обновление несёт `resourceVersion`, от которого оно сделано. Если объект с тех пор изменился — apiserver отвечает **409 Conflict** (проверено):

```
Error from server (Conflict): error when replacing "cm-old.yaml": Operation cannot be fulfilled on configmaps "demo": the object has been modified; please apply your changes to the latest version and try again
```

Блокировок нет: кто записал первым — тот и прав, остальные перечитывают и повторяют. Так два контроллера не затирают друг друга молча. `kubectl apply` и `patch` конфликта обычно не видят — патч применяется к свежей версии на сервере; `replace` и `edit` по устаревшему файлу — видят.

## 5. Watch: как компоненты узнают об изменениях 🟡🔴

Клиент делает **list** (получить всё и `resourceVersion` списка), затем **watch** с этой версии — долгий HTTP-запрос, в котором сервер присылает события `ADDED`, `MODIFIED`, `DELETED`. Проверено:

```bash
kubectl get --raw '/api/v1/namespaces/lab-01-1/configmaps?watch=1&resourceVersion=4307&timeoutSeconds=5'
```

```
MODIFIED demo rv=4330 {'color': 'red'}
MODIFIED demo rv=4336 {'color': 'black'}
DELETED demo rv=4338 {'color': 'black'}
```

Watch с давно ушедшей версии (etcd периодически делает compaction — по умолчанию apiserver запрашивает её каждые 5 минут):

```
{"type":"ERROR","object":{"kind":"Status",…,"message":"too old resource version: 10 (2942)","reason":"Expired","code":410}}
```

Клиент обязан сделать новый list. В клиентских библиотеках это прячут **informers**: list + watch + локальный кэш + переподключение. Контроллеры читают из своего кэша, а не из apiserver, — поэтому 40 контроллеров не убивают API запросами.

🔴 Нагрузка на apiserver — это в первую очередь **тяжёлые list'ы** (все поды кластера без пагинации, все секреты) и тысячи watch-соединений. Защиты:

- **watch cache** в apiserver: list с `resourceVersion=0` и consistent reads (1.31+) отдаются из памяти, не из etcd;
- пагинация `limit`/`continue`;
- **API Priority and Fairness (APF)** — очереди запросов по приоритетам. Проверено на стенде (`kubectl get flowschemas,prioritylevelconfigurations`):

```
flowschema                     priority level     порядок
exempt                         exempt             1
system-leader-election         leader-election    100
system-node-high               node-high          400
system-nodes                   system             500
kube-controller-manager        workload-high      800
kube-scheduler                 workload-high      800
service-accounts               workload-low       9000
global-default                 global-default     9900
catch-all                      catch-all          10000
```

Запросы ваших CI и операторов (ServiceAccount) попадают в `workload-low`, kubelet'ов — в `system`. Если какой-нибудь оператор начинает заваливать API, APF отвечает ему 429, а узлы и leader election продолжают работать. Метрики: `apiserver_flowcontrol_rejected_requests_total`, `apiserver_flowcontrol_current_inqueue_requests`.

## 6. Leader election и высокая доступность 🔴

В проде control plane — 3 узла (или 5). apiserver'ы работают все одновременно за балансировщиком (stateless). etcd — кластер Raft: нужен кворум, `⌊N/2⌋+1` (для 3 — 2, для 5 — 3; подробно 10-1). Scheduler и controller-manager работают в режиме **один активный**: экземпляры соревнуются за объект Lease, держатель — лидер.

```bash
kubectl -n kube-system get lease
```

Проверено:

```
NAME                                   HOLDER                                                   AGE
apiserver-55kg5nn6wbzocjpo7s4jkzs2um   apiserver-55kg5nn6wbzocjpo7s4jkzs2um_fc3e832c-…          6m10s
kube-controller-manager                lab-control-plane_33ab5799-346d-478e-84c1-6d53ba170932   19m
kube-scheduler                         lab-control-plane_c3379c1d-162c-49c2-b7c5-8a7fe8d9737d   19m
```

Дефолты leader election: lease 15 с, продление каждые 10 с, повтор 2 с. Новый экземпляр после рестарта ждёт, пока старая аренда истечёт, — на стенде controller-manager после возврата навёл порядок за 21 с (лаба, шаг 5). Lease узлов (`kube-node-lease`) — это heartbeat kubelet'ов (01-2).

## 7. Что происходит при отказе частей control plane 🟡

Проверено на стенде (лаба, шаги 4–6):

| Остановлен | Работающие поды | Новые поды/изменения | Что видно |
|---|---|---|---|
| kube-scheduler | работают | создаются, но **Pending** без событий; после возврата назначены за 2 с | в событиях только `SuccessfulCreate` от replicaset-controller |
| kube-controller-manager | работают | `scale` и удаление подов ничего не меняют; status устаревает | Deployment `READY 2/4`, RS `CURRENT 2`, реально под один |
| kube-apiserver (и etcd) | работают и **обслуживают трафик** (`curl` через Gateway — 200) | kubectl: `connection refused` | kubelet сам перезапустил убитый контейнер (ATTEMPT 1), status в API обновился через ~13 с после возврата apiserver |

Чего не будет без control plane, хотя поды живут:

- перезапуска подов **на другом узле** при падении узла (это делает контроллер, через 300 с по умолчанию);
- обновления endpoints: новые/упавшие поды не добавятся и не уберутся из Service;
- HPA, CronJob, Job, ротации токенов ServiceAccount (часовые bound-токены продлевает kubelet через API — при долгой недоступности приложения, которые ходят в API, начнут получать 401);
- деплоя — то есть и отката.

---

## 🔧 Лаба

Цель: увидеть путь запроса изнутри и проверить, что ломается при отказе каждого компонента control plane.

### Шаг 0. Подготовка

```bash
kubectl config use-context kind-lab
kubectl create ns lab-01-1
kubectl config set-context --current --namespace=lab-01-1
E='etcdctl --endpoints=https://127.0.0.1:2379 --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt --key=/etc/kubernetes/pki/etcd/server.key'
```

### Шаг 1. Объект в etcd и resourceVersion

```bash
kubectl create configmap demo --from-literal=color=blue
kubectl get cm demo -o jsonpath='rv={.metadata.resourceVersion} uid={.metadata.uid}{"\n"}'
kubectl -n kube-system exec etcd-lab-control-plane -- $E get /registry/configmaps/lab-01-1/demo -w json \
  | jq -c '{rev: .header.revision, create: .kvs[0].create_revision, mod: .kvs[0].mod_revision, version: .kvs[0].version}'
kubectl -n kube-system exec etcd-lab-control-plane -- $E get /registry/configmaps/lab-01-1/demo --print-value-only | od -c | head -4
kubectl patch cm demo -p '{"data":{"color":"green"}}'
kubectl get cm demo -o jsonpath='rv={.metadata.resourceVersion}{"\n"}'
kubectl -n kube-system exec etcd-lab-control-plane -- $E get /registry/configmaps/lab-01-1/demo -w json | jq -c '.kvs[0] | {mod_revision, version}'
```

Проверено:

```
rv=4306 uid=c19775aa-7307-4e80-85cd-4af79e6571aa
{"rev":4306,"create":4306,"mod":4306,"version":1}
0000000   k   8   s  \0  \n 017  \n 002   v   1 022  \t   C   o   n   f
0000020   i   g   M   a   p 022 263 001  \n 241 001  \n 004   d   e   m
0000040   o 022  \0 032  \b   l   a   b   -   0   1   -   1   "  \0   *
0000060   $   c   1   9   7   7   5   a   a   -   7   3   0   7   -   4
rv=4307
{"mod_revision":4307,"version":2}
```

При повторном прогоне (проверено) версия выросла с 5263 до 5265 за одно изменение: между ними кто-то ещё записал в etcd (lease узла, событие) — глобальная ревизия общая на весь кластер.

Сколько и чего лежит в etcd:

```bash
kubectl -n kube-system exec etcd-lab-control-plane -- $E get /registry --prefix --keys-only | grep -v '^$' | wc -l
kubectl -n kube-system exec etcd-lab-control-plane -- $E get /registry --prefix --keys-only | grep -v '^$' \
  | cut -d/ -f3 | sort | uniq -c | sort -rn | head -5
```

Проверено:

```
838
    402 events
     77 clusterroles
     64 clusterrolebindings
     53 serviceaccounts
     28 apiregistration.k8s.io
```

### Шаг 2. 409 Conflict

```bash
kubectl get cm demo -o yaml > /tmp/cm-old.yaml               # «снимок» с resourceVersion 4307
kubectl patch cm demo -p '{"data":{"color":"red"}}'           # кто-то другой изменил объект
sed -i 's/color: green/color: yellow/' /tmp/cm-old.yaml
kubectl replace -f /tmp/cm-old.yaml
```

Проверено:

```
Error from server (Conflict): error when replacing "/tmp/cm-old.yaml": Operation cannot be fulfilled on configmaps "demo": the object has been modified; please apply your changes to the latest version and try again
```

### Шаг 3. Watch своими глазами

```bash
RV=$(kubectl get cm demo -o jsonpath='{.metadata.resourceVersion}')
kubectl get --raw "/api/v1/namespaces/lab-01-1/configmaps?watch=1&resourceVersion=$RV&timeoutSeconds=10" &
sleep 1
kubectl patch cm demo -p '{"data":{"color":"black"}}'
kubectl delete cm demo
wait
kubectl get --raw '/api/v1/namespaces/lab-01-1/configmaps?watch=1&resourceVersion=10&timeoutSeconds=3'
```

Проверено (события в JSON, сокращено до типа, имени, версии и данных):

```
MODIFIED demo rv=4336 {'color': 'black'}
DELETED demo rv=4338 {'color': 'black'}
{"type":"ERROR","object":{"kind":"Status","apiVersion":"v1","metadata":{},"status":"Failure","message":"too old resource version: 10 (2942)","reason":"Expired","code":410}}
```

Так же работает `kubectl get pods -w`, и так узнают об изменениях все контроллеры.

### Шаг 4. Остановить scheduler

Static pod останавливается удалением файла манифеста — kubelet следит за каталогом.

```bash
docker exec lab-control-plane mv /etc/kubernetes/manifests/kube-scheduler.yaml /root/
sleep 10
kubectl create deploy web --image=busybox:1.37 --replicas=2 -- sleep infinity
sleep 15
kubectl get pods -o wide
kubectl get events --sort-by=.lastTimestamp -o custom-columns=OBJ:.involvedObject.name,REASON:.reason,FROM:.source.component
kubectl -n orders get pods
```

Проверено:

```
NAME                   READY   STATUS    RESTARTS   AGE   IP       NODE     NOMINATED NODE   READINESS GATES
web-78bbb77d7c-k8v4m   0/1     Pending   0          15s   <none>   <none>   <none>           <none>
web-78bbb77d7c-p5d9f   0/1     Pending   0          15s   <none>   <none>   <none>           <none>
OBJ              REASON              FROM
web-78bbb77d7c   SuccessfulCreate    replicaset-controller
web-78bbb77d7c   SuccessfulCreate    replicaset-controller
web              ScalingReplicaSet   deployment-controller
NAME                         READY   STATUS    RESTARTS        AGE
orders-api-96bfbd985-7vtzv   1/1     Running   0               70s
orders-api-96bfbd985-hhxph   1/1     Running   0               68s
postgres-0                   1/1     Running   1 (6m37s ago)   15m
```

Pending **без единого события** про планирование — признак того, что scheduler не работает вовсе. Если scheduler жив, но места нет, будет событие `FailedScheduling` с причиной (05-1, 05-2). Mirror pod планировщика при этом остаётся в API в статусе `Completed` — не верьте ему, смотрите на узле `crictl ps --name kube-scheduler`.

```bash
docker exec lab-control-plane mv /root/kube-scheduler.yaml /etc/kubernetes/manifests/
kubectl get pods -o wide -w      # Ctrl-C, когда оба получат NODE
```

Проверено: оба пода получили узлы через 2 с после возврата файла (`lab-worker2`, `lab-worker3`).

### Шаг 5. Остановить controller-manager

```bash
docker exec lab-control-plane mv /etc/kubernetes/manifests/kube-controller-manager.yaml /root/
sleep 10
kubectl scale deploy web --replicas=4
kubectl delete pod $(kubectl get pods -o jsonpath='{.items[0].metadata.name}')
sleep 20
kubectl get deploy,rs,pods
```

Проверено:

```
NAME                  READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/web   2/4     2            2           87s

NAME                             DESIRED   CURRENT   READY   AGE
replicaset.apps/web-78bbb77d7c   2         2         2       87s

NAME                       READY   STATUS    RESTARTS   AGE
pod/web-78bbb77d7c-p5d9f   1/1     Running   0          87s
```

Три наблюдения: `scale` принят (desired = 4 у Deployment), но ReplicaSet не получил новое значение; удалённый под не пересоздан; status Deployment и ReplicaSet **устарел** — показывает два готовых пода, хотя жив один. Status — это не «правда», а последний отчёт контроллера.

```bash
docker exec lab-control-plane mv /root/kube-controller-manager.yaml /etc/kubernetes/manifests/
until [ "$(kubectl get deploy web -o jsonpath='{.status.readyReplicas}')" = 4 ]; do sleep 1; done; kubectl get deploy web
```

Проверено: `web 4/4` через 21 с — из них ~15 с новый экземпляр ждал истечения lease предыдущего лидера.

### Шаг 6. Остановить apiserver

```bash
docker exec lab-control-plane mv /etc/kubernetes/manifests/kube-apiserver.yaml /root/
sleep 15
kubectl get nodes
curl -s http://orders.localhost:8088/api/orders        # сквозной сценарий
```

Проверено (запрос сквозного сценария — из сети kind, см. 00-1 §4.4):

```
The connection to the server lab-control-plane:6443 was refused - did you specify the right host or port?
{"orders": [{"id": 1, "item": "book", "qty": 2}, {"id": 2, "...
```

У вас ошибка kubectl будет про `127.0.0.1:<порт>`. Трафик идёт: Envoy, kube-proxy, поды и PostgreSQL от apiserver не зависят.

Теперь убейте процесс контейнера на узле — без API:

```bash
for W in lab-worker lab-worker2 lab-worker3; do C=$(docker exec $W crictl ps --name '^busybox$' -q | head -1); [ -n "$C" ] && break; done
echo "$W $C"
docker exec $W kill -9 $(docker exec $W crictl inspect -o go-template --template '{{.info.pid}}' $C)
sleep 12
docker exec $W crictl ps -a --name '^busybox$'
```

Проверено (контейнер `busybox` — имя по образу, `kubectl create deploy` так называет контейнер):

```
CONTAINER           IMAGE               CREATED             STATE               NAME                ATTEMPT             POD ID              POD                    NAMESPACE
03f257e41fa60       30ecbe1509090       11 seconds ago      Running             busybox             1                   38afa08f62a22       web-78bbb77d7c-p5d9f   lab-01-1
0923431263e46       30ecbe1509090       3 minutes ago       Exited              busybox             0                   38afa08f62a22       web-78bbb77d7c-p5d9f   lab-01-1
```

Kubelet перезапустил контейнер сам — restartPolicy исполняет узел, не control plane.

```bash
docker exec lab-control-plane mv /root/kube-apiserver.yaml /etc/kubernetes/manifests/
until kubectl get --raw /readyz >/dev/null 2>&1; do sleep 1; done
for i in 1 2 3; do sleep 10; kubectl get pods --no-headers | grep p5d9f; done
```

Проверено: apiserver готов через 3 с; сразу после этого под ещё показывает `RESTARTS 0`, через ~10 с — `1 (39s ago)`. Kubelet досылает накопленные статусы, когда API возвращается.

### Шаг 7. Время пути и кто писал объект

```bash
kubectl run timing --image=busybox:1.37 --restart=Never -- sleep 3600
kubectl wait --for=condition=Ready pod/timing
kubectl get pod timing -o jsonpath='created={.metadata.creationTimestamp}{"\n"}{range .status.conditions[*]}{.type}={.lastTransitionTime}{"\n"}{end}'
kubectl get pod timing -o jsonpath='{.metadata.managedFields[*].manager}{"\n"}'
docker exec lab-control-plane grep -E 'enable-admission|authorization-mode|etcd-servers' /etc/kubernetes/manifests/kube-apiserver.yaml
```

Проверено:

```
created=2026-10-14T08:47:59Z
PodReadyToStartContainers=2026-10-14T08:48:00Z
Initialized=2026-10-14T08:47:59Z
Ready=2026-10-14T08:48:00Z
ContainersReady=2026-10-14T08:48:00Z
PodScheduled=2026-10-14T08:47:59Z
kubectl-run kubelet
    - --authorization-mode=Node,RBAC
    - --enable-admission-plugins=NodeRestriction
    - --etcd-servers=https://127.0.0.1:2379
```

Объект писали двое: `kubectl-run` (spec) и `kubelet` (status). В `--enable-admission-plugins` указан только NodeRestriction — остальные (NamespaceLifecycle, LimitRanger, ServiceAccount, ResourceQuota, PodSecurity, вебхуки…) включены по умолчанию и в флаге не перечисляются.

### Уборка

```bash
docker exec lab-control-plane ls /etc/kubernetes/manifests    # все четыре файла на месте!
kubectl get pods -n kube-system -l tier=control-plane
kubectl config set-context --current --namespace=default
kubectl delete ns lab-01-1
rm -f /tmp/cm-old.yaml
```

---

## 🔥 Кейс из прода: «control plane упал — прод работает, а деплой и автоскейлинг встали»

**Контекст.** Self-hosted кластер, 3 узла control plane, etcd на тех же узлах. Ночью на двух из трёх узлов control plane закончилось место на диске (логи аудита без ротации). Утром дежурный видит: сайт работает, мониторинг приложений зелёный, но CI падает на `kubectl apply` с таймаутом, а HPA не реагирует на рост нагрузки. Через час — частичная деградация: один worker перезагрузился после обновления ядра, и его поды так и не появились на других узлах.

**Разбор.**
1. `kubectl get nodes` — таймаут. `curl -k https://<cp>:6443/readyz` на каждом узле control plane: на двух — нет ответа, на третьем — `etcd failed`.
2. На узлах: `crictl ps -a | grep etcd` — etcd на двух узлах в `Exited`, лог `no space left on device`. Кворум 2 из 3 потерян: оставшийся etcd не может принимать записи и отвечает ошибкой; apiserver без etcd не работает.
3. Почему сайт жив: поды, kube-proxy и сеть не зависят от API (как в лабе, шаг 6). Почему поды перезагруженного узла не переехали: перенос делает controller-manager, а он без API не работает. Почему HPA стоит — то же.
4. Почему CI «завис», а не упал сразу: kubectl ждал ответа балансировщика API, который продолжал слать запросы на мёртвые бэкенды без health-check `/readyz`.

**Фикс.**
- Освободили место (ротация логов аудита), etcd поднялся, кворум восстановился, apiserver'ы — следом. Поды упавшего узла пересоздал controller-manager через несколько минут.
- Логи аудита — на отдельный том с ротацией (`--audit-log-maxsize`, `--audit-log-maxbackup`); etcd — на отдельный быстрый диск.
- Алерты: свободное место на узлах control plane, `etcd_server_has_leader`, `up{job="apiserver"}`; health-check балансировщика API по `/readyz`.
- В runbook: «поды живы ≠ кластер жив» — что перестаёт работать без control plane (таблица §7).

**Что запомнить.**
- Данные плоскость (поды, сеть) переживает отказ control plane; управление (деплой, масштабирование, самовосстановление) — нет.
- etcd — первое, что проверяют при недоступном API; кворум теряется при отказе большинства узлов.
- Status объектов в такой ситуации устаревает — верить надо узлам (`crictl`), а не API.

---

## 💼 Вопросы с собеседования

### 🟢 Junior

**1. Из каких компонентов состоит control plane и что делает каждый?**
kube-apiserver — единственная точка входа в API, authn/authz/admission, пишет в etcd. etcd — хранилище всего состояния кластера (key-value, Raft). kube-scheduler — выбирает узел для подов без `nodeName`. kube-controller-manager — набор контроллеров (ReplicaSet, Deployment, Node, Job…), приводящих фактическое к желаемому. На узлах — kubelet (запускает поды через CRI) и kube-proxy (правила для Service).

**2. Что значит «декларативная модель»?**
Вы описываете желаемое состояние (`spec`), а не шаги. Контроллеры в цикле сравнивают `spec` со `status` и действуют, пока не совпадёт. Удалили под Deployment'а — ReplicaSet-контроллер создаст новый, потому что желаемое число реплик не изменилось.

**3. Что такое static pod?**
Под, который kubelet запускает по файлу в `/etc/kubernetes/manifests` без участия apiserver; в API виден как mirror pod только для чтения. Так kubeadm запускает сам control plane.

### 🟡 Middle

**4. Что происходит после `kubectl apply -f deploy.yaml`?**
kubectl → HTTPS-запрос к apiserver → аутентификация → авторизация (RBAC) → mutating admission → валидация схемы → validating admission → запись в etcd. Deployment-контроллер (watch) создаёт ReplicaSet, ReplicaSet-контроллер — поды без узла; scheduler (watch) выбирает узел и пишет `nodeName` (binding); kubelet узла (watch) видит под, через CRI создаёт pause-контейнер, сеть (CNI), контейнеры; статус пишет обратно в apiserver. Ни один компонент, кроме apiserver, не ходит в etcd.

**5. Что будет с работающими подами, если упадёт apiserver или etcd?**
Поды продолжают работать и обслуживать трафик: kubelet, контейнеры и kube-proxy от apiserver в рантайме не зависят; kubelet даже перезапускает упавшие контейнеры локально. Перестают работать изменения: деплой и откат, масштабирование и HPA, перенос подов с упавшего узла, обновление endpoints, Job/CronJob.

**6. Под висит в Pending и в событиях пусто. О чём это говорит?**
Scheduler не обработал под вообще: не работает, не стал лидером или под предназначен другому scheduler'у (`schedulerName`). Если бы scheduler работал и не нашёл места, было бы событие `FailedScheduling` с причиной по каждому узлу.

**7. Как контроллеры узнают об изменениях, не опрашивая apiserver постоянно?**
List + watch: один раз получить список и `resourceVersion`, затем держать watch-поток и получать события ADDED/MODIFIED/DELETED. В клиентах это informers с локальным кэшем; при устаревшей версии (410 Gone после compaction) — повторный list.

### 🔴 Senior

**8. Два контроллера одновременно меняют один объект. Что не даст им затереть друг друга?**
Optimistic concurrency: update несёт `resourceVersion` (ревизию etcd), от которой сделан; если объект изменился — 409 Conflict, клиент перечитывает и повторяет. Для apply — server-side apply с field managers: каждое поле принадлежит менеджеру, попытка изменить чужое поле даёт конфликт (или перехват с `--force-conflicts`).

**9. Почему кластер «тормозит» при 5000 узлах и куче операторов, хотя CPU у apiserver есть?**
Нагрузка на apiserver — это тяжёлые list-запросы мимо кэша (cluster-wide list подов или секретов без пагинации) и тысячи watch'ей; они съедают память apiserver и упираются в etcd. Защита — API Priority and Fairness (очереди по приоритетам, 429 для шумных клиентов), list из watch cache (`resourceVersion=0`, consistent reads from cache), пагинация `limit/continue`, informers вместо опроса в операторах. Диагностика: `apiserver_request_duration_seconds` по verb/resource, `apiserver_flowcontrol_*`, аудит — кто делает тяжёлые list'ы.

**10. Как устроена отказоустойчивость control plane?**
apiserver — stateless, все экземпляры активны за балансировщиком с проверкой `/readyz`. etcd — Raft, нужен кворум ⌊N/2⌋+1, поэтому 3 или 5 членов. Scheduler и controller-manager — активный/резервные через Lease (15 с аренды, продление каждые 10 с): после отказа лидера резервный перехватывает работу примерно через 15 с.

---

## ⚠️ Подводные камни

- `resourceVersion` — ревизия etcd, а не счётчик версий объекта; сравнивать только на равенство.
- Status устаревает, если его владелец-контроллер не работает: `READY 2/4` может врать.
- Mirror pod остановленного static pod может висеть в API как `Completed`/`Running` — проверяйте `crictl ps` на узле.
- Удалить под, которым владеет контроллер, бесполезно — он вернётся; удаляйте или меняйте владельца.
- Watch с устаревшей версией → 410 Gone; самописные скрипты на `--watch` должны уметь переподключаться с новым list.
- Events занимают больше половины ключей etcd на тихом кластере; шумный контроллер с тысячами событий нагружает etcd.
- Ни в коем случае не оставляйте манифест static pod вне `/etc/kubernetes/manifests` после экспериментов — проверьте, что все четыре файла на месте.
- Балансировщик перед apiserver без health-check `/readyz` шлёт запросы на мёртвые экземпляры — kubectl «висит» вместо понятной ошибки.

---

## Чеклист

- [ ] Назову компоненты control plane и узла и что ломается без каждого.
- [ ] Расскажу путь `kubectl apply` от authn до запущенного контейнера.
- [ ] Покажу ключ объекта в etcd и объясню связь `resourceVersion` с ревизией etcd.
- [ ] Воспроизведу 409 Conflict и объясню optimistic concurrency.
- [ ] Прочитаю watch-поток и объясню 410 Gone и informers.
- [ ] Отличу «scheduler не работает» от «нет места» по событиям.
- [ ] Объясню, почему приложения живут без apiserver и что при этом перестаёт работать.

---

## Задание со звёздочкой

Измерьте, как долго кластер «не замечает» отказ лидера controller-manager:

1. Запустите в фоне цикл, который раз в секунду пишет время и `holderIdentity` из `kubectl -n kube-system get lease kube-controller-manager -o jsonpath='{.spec.holderIdentity} {.spec.renewTime}'`.
2. Остановите controller-manager (шаг 5) и сразу удалите один под Deployment `web`.
3. Верните манифест. Зафиксируйте: когда сменился holder, когда появился новый под, сколько прошло от остановки до восстановления `replicas`.
4. Повторите, поменяв в манифесте controller-manager `--leader-elect-lease-duration=5s --leader-elect-renew-deadline=3s`. Как изменилось время? Чем опасны слишком короткие значения в кластере с медленным etcd?

---

→ Следующая часть: **01-2. Узел: kubelet, CRI, CNI, kube-proxy** — что делает kubelet от binding до Running, pause-контейнер и CNI, cgroup-иерархия подов, static pods, статусы и lease узлов; останавливаем kubelet и замеряем, когда узел станет NotReady и когда поды начнут переезжать.
