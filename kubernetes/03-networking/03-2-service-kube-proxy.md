# 03-2. Service и kube-proxy

> Модуль 3 «Сеть» · часть 2 из 5 · 🟢🟡🔴 · ~1,5 ч чтения + ~1 ч лабы · Нужно: стенд 00-1, `nicolaka/netshoot:v0.13` (03-1). База — networks 08-3: типы Service, цепочки iptables kube-proxy по шагам, conntrack и балансировка, NodePort и client IP, headless и ExternalName. Здесь — диагностика и настройки, которые встречаются в эксплуатации.

---

## Зачем это DevOps-у

«Service есть, а curl висит или отказывает» — одна из самых частых жалоб. Причины всегда в одном из звеньев: selector → EndpointSlice → readiness → `targetPort` → kube-proxy → политика трафика. На собеседовании: «как Service находит поды», «что делает kube-proxy», «почему за NodePort не видно IP клиента», «как распределяется трафик между зонами».

Сквозной сценарий: Service `orders-api` и вход через Gateway — на стенде мы уже наступили на `externalTrafficPolicy: Local` у сервиса Envoy (00-1 §6): запросы на `:8088` висели до таймаута.

---

## 1. Из чего состоит Service 🟢

```
Service (selector app=orders-api, port 80 → targetPort http)
   │ контроллер EndpointSlice: поды по selector'у → адреса + conditions
EndpointSlice(ы) ─── до 100 адресов в одном slice
   │ watch
kube-proxy на каждом узле ─── правила iptables / nftables / ipvs: ClusterIP:80 → IP пода:8000
Envoy/Ingress/mesh ───────── читают EndpointSlice сами и балансируют напрямую на IP подов
```

ClusterIP не принадлежит никакому интерфейсу — это «адрес-приманка» для правил DNAT на каждом узле (networks 08-3 §4.5). Пинговать его бесполезно.

EndpointSlice заменил объект Endpoints (проверено: `kubectl get endpoints` в 1.36 печатает `Warning: v1 Endpoints is deprecated in v1.33+; use discovery.k8s.io/v1 EndpointSlice`). У каждого адреса — условия:

| Условие | Значит | Кто использует |
|---|---|---|
| `ready` | под Ready и не завершается | kube-proxy, все балансировщики |
| `serving` | под проходит readiness (даже если завершается) | балансировщики, умеющие «дослать» соединения |
| `terminating` | у пода `deletionTimestamp` | |

Проверено — под удаляется, у него `preStop: sleep 8`:

```
{"pod":"xcktj","ready":true,"serving":true,"terminating":false}
{"pod":"fl22g","ready":false,"serving":true,"terminating":true}     ← уходит, но ещё отвечает
{"pod":"sxwfr","ready":true,"serving":true,"terminating":false}
{"pod":"qmt9p","ready":true,"serving":true,"terminating":false}     ← замена
```

Для новых соединений он уже не выбирается (`ready: false`). Если завершаются **все** поды Service, kube-proxy использует `serving`-адреса — чтобы не обрывать трафик целиком.

## 2. «Service не отвечает»: диагностика по звеньям 🟢🟡

**Опечатка в selector.** Проверено: kind 0.32.0, Kubernetes 1.36.1, kube-proxy `mode: iptables`.

```bash
kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata: {name: orders}
spec:
  replicas: 2
  selector: {matchLabels: {app: orders}}
  template:
    metadata: {labels: {app: orders}}
    spec:
      containers:
      - name: api
        image: python:3.12-slim
        command: ["python", "-m", "http.server", "8000"]
        ports: [{name: http, containerPort: 8000}]
        readinessProbe: {httpGet: {path: /, port: http}, periodSeconds: 2}
---
apiVersion: v1
kind: Service
metadata: {name: orders}
spec:
  selector: {app: order}          # опечатка: order вместо orders
  ports: [{port: 80, targetPort: http}]
EOF
kubectl rollout status deploy/orders
kubectl get svc,endpointslice
kubectl describe svc orders | grep -E 'Selector|Endpoints'
```

Проверено:

```
deployment "orders" successfully rolled out
NAME             TYPE        CLUSTER-IP     EXTERNAL-IP   PORT(S)   AGE
service/orders   ClusterIP   10.96.88.241   <none>        80/TCP    1s

NAME                                          ADDRESSTYPE   PORTS     ENDPOINTS   AGE
endpointslice.discovery.k8s.io/orders-9vf5b   IPv4          <unset>   <unset>     1s
Selector:                 app=order
Endpoints:
```

Deployment здоров, оба пода Ready, у Service есть ClusterIP — и пустой EndpointSlice. Первое, что проверяют при «Service не отвечает»: **есть ли endpoints**.

**Как это выглядит для клиента.**

```bash
kubectl run client --image=python:3.12-slim --restart=Never --command -- sleep infinity
kubectl wait --for=condition=Ready pod/client
kubectl exec client -- python -c '
import socket, time
t = time.time()
try:
    socket.create_connection(("orders", 80), timeout=5); print("connected")
except Exception as e:
    print(type(e).__name__, e)
print(f"{time.time()-t:.3f}s")'
```

Проверено:

```
ConnectionRefusedError [Errno 111] Connection refused
0.020s
```

Отказ мгновенный, а не таймаут: DNS отработал (имя `orders` резолвится в ClusterIP), а kube-proxy для сервиса без endpoints ставит правило REJECT. Его видно на любом узле:

```bash
docker exec lab-worker iptables-save | grep 'lab-03-2/orders'
```

Проверено:

```
-A KUBE-SERVICES -d 10.96.88.241/32 -p tcp -m comment --comment "lab-03-2/orders has no endpoints" -m tcp --dport 80 -j REJECT --reject-with icmp-port-unreachable
```

Сравните с курсом `networks`: `Connection refused` за миллисекунды — ответ «порт закрыт» (здесь — ICMP port unreachable от iptables), таймаут — пакеты теряются (NetworkPolicy, маршрутизация, 03-5).

**Исправить selector — и сломать порт.**

```bash
kubectl patch svc orders -p '{"spec":{"selector":{"app":"orders"}}}'
kubectl get endpointslice -l kubernetes.io/service-name=orders
kubectl exec client -- python -c 'import urllib.request as u; print(u.urlopen("http://orders", timeout=5).status)'

kubectl patch svc orders --type=json -p '[{"op":"replace","path":"/spec/ports/0/targetPort","value":8080}]'
kubectl get endpointslice -l kubernetes.io/service-name=orders
kubectl exec client -- python -c '
import socket
try:
    socket.create_connection(("orders", 80), timeout=5); print("connected")
except Exception as e:
    print(type(e).__name__, e)'
```

Проверено:

```
service/orders patched
NAME           ADDRESSTYPE   PORTS   ENDPOINTS                AGE
orders-9vf5b   IPv4          8000    10.244.3.8,10.244.2.10   12s
200
service/orders patched
NAME           ADDRESSTYPE   PORTS   ENDPOINTS                AGE
orders-9vf5b   IPv4          8080    10.244.2.10,10.244.3.8   15s
ConnectionRefusedError [Errno 111] Connection refused
```

Симптом тот же — `Connection refused`, но причина другая: endpoints есть, пакет доходит до пода, а на порту 8080 никто не слушает — отказ шлёт уже ядро пода. Отличаем по EndpointSlice: пусто → selector или readiness; адреса есть, порт не тот → `targetPort`. Поэтому `targetPort` лучше задавать **именем** порта (`http`), а не числом: имя переживёт смену порта в контейнере.

Итоговая последовательность проверок:

```bash
kubectl get svc <svc> -o wide                         # selector, порты
kubectl get endpointslice -l kubernetes.io/service-name=<svc> -o wide   # есть ли адреса и порт
kubectl get pods -l <selector> -o wide                 # совпадает ли selector, Ready ли поды
kubectl exec <client> -- curl -sv http://<podIP>:<port>/   # под отвечает напрямую? (минуя Service)
kubectl exec <client> -- curl -sv http://<svc>/           # через ClusterIP
docker exec <узел> iptables-save | grep '<ns>/<svc>'   # правила kube-proxy (networks 08-3)
```

## 3. externalTrafficPolicy и IP клиента 🟡

Трафик снаружи (NodePort, LoadBalancer) приходит на **любой** узел. Дальше:

| `externalTrafficPolicy` | Куда идёт | IP клиента в поде | Узел без подов |
|---|---|---|---|
| `Cluster` (дефолт) | на любой под кластера, возможно на другом узле | **потерян**: SNAT в адрес узла | принимает и пересылает |
| `Local` | только на поды этого узла | **сохранён** | отбрасывает (правило `has no local endpoints … DROP`) |

Проверено (Deployment `echo`, 2 пода, оба на `lab-worker`, NodePort 30081):

```
eTP=Cluster node=lab-worker(172.20.0.3)  -> 200
eTP=Cluster node=lab-worker2(172.20.0.5) -> 200
eTP=Local   node=lab-worker(172.20.0.3)  -> 200
eTP=Local   node=lab-worker2(172.20.0.5) -> 000       ← таймаут: подов на узле нет

client=172.20.0.8/16
[pod/echo-…-f7zb9/api] 172.20.0.8 "GET /version?local HTTP/1.1" 200 -      ← Local: реальный IP клиента
[pod/echo-…-f7zb9/api] 10.244.2.1 "GET /version?cluster HTTP/1.1" 200 -    ← Cluster: адрес узла после SNAT
```

`Local` используют, когда нужен IP клиента (rate limiting, geo, аудит) и нет L7-прокси с `X-Forwarded-For`. Тогда внешний балансировщик **обязан** знать, на каких узлах есть поды: для `type: LoadBalancer` kube-proxy открывает `healthCheckNodePort`, и облачный LB проверяет по нему узлы. У NodePort такого порта нет (проверено: `healthCheckNodePort` пуст) — внешний балансировщик, который шлёт на все узлы, будет терять запросы.

Ровно это случилось на стенде: Envoy Gateway по умолчанию создаёт свой Service с `externalTrafficPolicy: Local` (для LoadBalancer это правильно), а kind пробрасывает `127.0.0.1:8088` на узел control-plane, где пода Envoy нет. Решение в `lab-up.sh` — `EnvoyProxy` с `externalTrafficPolicy: Cluster` (00-1 §6).

`internalTrafficPolicy: Local` — то же для трафика изнутри кластера: под ходит только к экземплярам на своём узле (node-local агенты, DaemonSet-кэши).

## 4. Сессии и распределение по топологии 🟡🔴

### sessionAffinity

kube-proxy балансирует **соединения**, а не запросы: keepalive-клиент (HTTP/1.1 пул, gRPC) прилипает к одному поду на всё время соединения. Без keepalive — случайный выбор на каждое соединение. Проверено (60 запросов, каждый — новое соединение):

```
no affinity:       {'xcktj': 24, 'fl22g': 22, 'sxwfr': 14}
ClientIP affinity: {'fl22g': 60}
```

`sessionAffinity: ClientIP` (таймаут 3 часа по умолчанию, `sessionAffinityConfig.clientIP.timeoutSeconds`) — все соединения с одного IP в один под. Ограничения: за SNAT все клиенты имеют один IP узла; при Cluster-политике снаружи — IP узла, а не клиента; при перезапуске пода «сессия» теряется. Настоящие сессии — в приложении (Redis) или в L7-балансировщике (cookie).

gRPC и HTTP/2 через Service: одно долгое соединение → вся нагрузка клиента на один под. Балансировать на L7 (Envoy, mesh, клиентская балансировка через headless Service).

### trafficDistribution

В многозонных кластерах межзонный трафик стоит денег и добавляет задержку. `spec.trafficDistribution` просит kube-proxy (и совместимые балансировщики) предпочитать близкие endpoints. Проверено (зоны размечены вручную: `lab-worker` → `zone-a`, остальные → `zone-b`; клиент на `lab-worker`):

```
default:                          {'sxwfr': 21, 'xcktj': 23, 'qmt9p': 16}
Warning: spec.trafficDistribution: "PreferClose" is deprecated; use "PreferSameZone"
PreferClose (client in zone-a):   {'sxwfr': 60}
PreferSameZone:                   {'sxwfr': 60}
PreferSameNode (client on lab-worker): {'sxwfr': 60}

{"pod":"xcktj","node":"lab-worker3","hints":{"forNodes":[{"name":"lab-worker3"}],"forZones":[{"name":"zone-b"}]}}
{"pod":"sxwfr","node":"lab-worker","hints":{"forNodes":[{"name":"lab-worker"}],"forZones":[{"name":"zone-a"}]}}
```

В 1.36 `PreferClose` устарел (сервер предупреждает), значения — `PreferSameZone` и `PreferSameNode`. Это «предпочтение»: если в зоне нет готовых endpoints, трафик идёт в другие. Риск — перекос нагрузки: в зоне-a один под принимает весь трафик клиентов зоны-a. Нужны равномерные реплики по зонам (05-2, topology spread).

## 5. Режимы kube-proxy 🟡🔴

| Режим | Как | Масштаб | Статус |
|---|---|---|---|
| `iptables` | цепочки на каждый Service и endpoint, вероятностный выбор | обновление правил — O(всех правил), на 10k+ Service — секунды и CPU | дефолт много лет; на стенде |
| `nftables` | verdict maps: поиск Service за O(1), атомарные обновления | рассчитан на большие кластеры | stable с 1.33 |
| `ipvs` | IPVS в ядре, хэш-таблицы, разные алгоритмы | хорошо масштабируется | устаревает в пользу nftables |
| без kube-proxy | eBPF в CNI (Cilium kube-proxy replacement) | | вне kube-proxy |

Проверено: переключение стенда на nftables (`mode: nftables` в ConfigMap `kube-proxy` + `rollout restart ds/kube-proxy`):

```
"Using nftables Proxier"
table ip kube-proxy
table ip6 kube-proxy
  10.96.126.27 . tcp . 80 : goto service-6LFQCZ4Y-lab-03-2/echo-np/tcp/http,
  10.96.210.228 . tcp . 80 : goto service-POAEMLRC-lab-03-2/echo/tcp/,
  tcp . 30081 : goto external-6LFQCZ4Y-lab-03-2/echo-np/tcp/http }
iptables rules for echo: 0                   ← iptables-правила kube-proxy убраны
200                                          ← Service работает
```

Сервисы — элементы одной map (`ClusterIP . протокол . порт : goto цепочка`), а не сотни цепочек. Обратно на iptables (проверено): таблицы `kube-proxy` в nftables удалены, iptables-правил для `echo` снова 19, Service и сквозной сценарий — 200. При первом старте в nftables-режиме в логе `Failed to list existing nftables objects` — таблицы ещё нет, безвредно.

Переключение режима на проде — с окном: при рестарте kube-proxy соединения через conntrack сохраняются, но новые правила появляются не мгновенно на всех узлах. В kind заметна таблица `inet kindnet-network-policies` — kindnet реализует NetworkPolicy через nftables (03-5).

---

## 🔧 Лаба

### Шаг 0. Подготовка

```bash
kubectl config use-context kind-lab
kubectl create ns lab-03-2
kubectl config set-context --current --namespace=lab-03-2
```

### Шаг 1. Service без endpoints и неверный порт

Выполните команды §2: «опечатка в selector → пустой EndpointSlice → REJECT» и «неверный targetPort → endpoints есть, но connection refused» (там же проверенный вывод).

### Шаг 2. externalTrafficPolicy и IP клиента

```bash
kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata: {name: echo}
spec:
  replicas: 2
  selector: {matchLabels: {app: echo}}
  template:
    metadata: {labels: {app: echo}}
    spec:
      nodeSelector: {kubernetes.io/hostname: lab-worker}
      containers:
      - name: api
        image: localhost:5001/orders-api:2.0
        ports: [{name: http, containerPort: 8000}]
        readinessProbe: {httpGet: {path: /ready, port: http}, periodSeconds: 2}
---
apiVersion: v1
kind: Service
metadata: {name: echo-np}
spec:
  type: NodePort
  externalTrafficPolicy: Cluster
  selector: {app: echo}
  ports: [{name: http, port: 80, targetPort: http, nodePort: 30081}]
EOF
kubectl rollout status deploy/echo
for etp in Cluster Local; do
  kubectl patch svc echo-np -p "{\"spec\":{\"externalTrafficPolicy\":\"$etp\"}}"; sleep 3
  for n in lab-worker lab-worker2; do
    IP=$(docker inspect -f '{{.NetworkSettings.Networks.kind.IPAddress}}' $n)
    echo "eTP=$etp node=$n($IP) -> $(docker run --rm --network kind curlimages/curl:8.11.1 -s -m 3 -o /dev/null -w '%{http_code}' http://$IP:30081/version)"
  done
done
IP=$(docker inspect -f '{{.NetworkSettings.Networks.kind.IPAddress}}' lab-worker)
kubectl patch svc echo-np -p '{"spec":{"externalTrafficPolicy":"Local"}}'
docker run --rm --network kind alpine:3.20 sh -c "ip -4 -o addr show eth0 | awk '{print \"client=\"\$4}'; wget -q -O /dev/null http://$IP:30081/version?local"
kubectl patch svc echo-np -p '{"spec":{"externalTrafficPolicy":"Cluster"}}'; sleep 2
docker run --rm --network kind alpine:3.20 wget -q -O /dev/null http://$IP:30081/version?cluster
kubectl logs -l app=echo --tail=50 --prefix | grep -E 'version\?(local|cluster)'
docker exec lab-worker2 iptables-save | grep 'has no local endpoints' | head -2
```

Клиент — контейнер в docker-сети `kind` («снаружи» кластера, как внешний LB). Проверено: вывод в §3.

### Шаг 3. Завершающийся под в EndpointSlice

```bash
kubectl patch deploy echo --type=json -p '[{"op":"remove","path":"/spec/template/spec/nodeSelector"},{"op":"replace","path":"/spec/replicas","value":3},{"op":"add","path":"/spec/template/spec/containers/0/lifecycle","value":{"preStop":{"sleep":{"seconds":8}}}}]'
kubectl rollout status deploy/echo
kubectl expose deploy echo --name=echo --port=80 --target-port=http
kubectl delete pod $(kubectl get pods -l app=echo -o jsonpath='{.items[0].metadata.name}') --wait=false; sleep 2
kubectl get endpointslice -l kubernetes.io/service-name=echo -o json | jq -c '.items[].endpoints[] | {pod: .targetRef.name[-5:], ready: .conditions.ready, serving: .conditions.serving, terminating: .conditions.terminating}'
```

Проверено: вывод в §1.

### Шаг 4. sessionAffinity и trafficDistribution

```bash
kubectl delete pod client --ignore-not-found      # клиент из §2 — на случайном узле, нужен на lab-worker
kubectl run client --image=python:3.12-slim --overrides='{"spec":{"nodeName":"lab-worker"}}' --command -- sleep infinity
kubectl wait --for=condition=Ready pod/client
cnt() { kubectl exec client -- python -c "
import urllib.request, collections, json
c=collections.Counter(json.loads(urllib.request.urlopen('http://echo/version').read())['pod'][-5:] for _ in range(60)); print(dict(c))"; }
kubectl get pods -l app=echo -o wide            # нужен под на lab-worker; если нет — kubectl delete pod одного из подов, пока не встанет
echo "no affinity: $(cnt)"
kubectl patch svc echo -p '{"spec":{"sessionAffinity":"ClientIP"}}'; sleep 2; echo "ClientIP: $(cnt)"
kubectl patch svc echo -p '{"spec":{"sessionAffinity":"None"}}'

kubectl label node lab-worker topology.kubernetes.io/zone=zone-a
kubectl label node lab-worker2 lab-worker3 topology.kubernetes.io/zone=zone-b
echo "default: $(cnt)"
kubectl patch svc echo -p '{"spec":{"trafficDistribution":"PreferClose"}}'; sleep 3; echo "PreferClose: $(cnt)"
kubectl patch svc echo -p '{"spec":{"trafficDistribution":"PreferSameZone"}}'; sleep 3; echo "PreferSameZone: $(cnt)"
kubectl patch svc echo -p '{"spec":{"trafficDistribution":"PreferSameNode"}}'; sleep 3; echo "PreferSameNode: $(cnt)"
kubectl get endpointslice -l kubernetes.io/service-name=echo -o json | jq -c '.items[].endpoints[] | {pod: .targetRef.name[-5:], node: .nodeName, hints}'
```

Проверено: вывод в §4.

Попутная ловушка (проверено): попытка добавить в `echo` `topologySpreadConstraints` с `maxSkew: 1` по узлам при 3 репликах на 3 worker'ах **завесила rollout** — surge-под (maxSurge 25% → 1) не помещается никуда без нарушения перекоса: `3 node(s) didn't match pod topology spread constraints`. Лечится `maxSurge: 0, maxUnavailable: 1` или `whenUnsatisfiable: ScheduleAnyway` (05-2).

### Шаг 5. kube-proxy в режиме nftables

```bash
kubectl -n kube-system get cm kube-proxy -o json | jq '.data["config.conf"] |= sub("mode: iptables"; "mode: nftables")' | kubectl apply -f -
kubectl -n kube-system rollout restart ds/kube-proxy && kubectl -n kube-system rollout status ds/kube-proxy
kubectl -n kube-system logs ds/kube-proxy | grep -i 'Using'
docker exec lab-worker sh -c 'nft list tables; nft list table ip kube-proxy | grep -m3 "lab-03-2/echo"; echo "iptables: $(iptables-save | grep -c lab-03-2/echo)"'
kubectl exec client -- python -c "import urllib.request;print(urllib.request.urlopen('http://echo/version').status)"
# вернуть как было — остальные части курса рассчитаны на iptables
kubectl -n kube-system get cm kube-proxy -o json | jq '.data["config.conf"] |= sub("mode: nftables"; "mode: iptables")' | kubectl apply -f -
kubectl -n kube-system rollout restart ds/kube-proxy && kubectl -n kube-system rollout status ds/kube-proxy
docker exec lab-worker sh -c 'nft list tables | grep kube-proxy; echo "iptables: $(iptables-save | grep -c lab-03-2/echo)"'
curl -s -o /dev/null -w '%{http_code}\n' http://orders.localhost:8088/api/orders
```

Проверено: вывод в §5. `kubectl apply` ConfigMap'а выдаст предупреждение о `last-applied-configuration` — объект создан kubeadm, не apply.

### Уборка

```bash
kubectl label node lab-worker lab-worker2 lab-worker3 topology.kubernetes.io/zone-
kubectl config set-context --current --namespace=default
kubectl delete ns lab-03-2
kubectl -n kube-system get cm kube-proxy -o jsonpath='{.data.config\.conf}' | grep '^mode'    # mode: iptables
```

---

## 🔥 Кейс из прода: «за балансировщиком теряется 2/3 запросов после включения IP клиента»

**Контекст.** Self-hosted кластер, 6 узлов, внешний HAProxy балансирует на NodePort всех узлов. Безопасники попросили видеть реальные IP клиентов в логах Ingress-контроллера. Команда поставила `externalTrafficPolicy: Local` на Service Ingress-контроллера (2 реплики). Сразу после изменения — таймауты у двух третей пользователей.

**Разбор.**
1. С `Local` трафик на узлы без пода Ingress kube-proxy отбрасывает (правило `has no local endpoints … DROP`). Подов два, узлов шесть — 4 из 6 узлов «чёрные дыры».
2. HAProxy проверял узлы TCP-чеком на NodePort; при `DROP` чек висит до таймаута, а не падает сразу — узлы долго считались живыми.
3. Воспроизведение — шаг 2 лабы: `eTP=Local node=lab-worker2 -> 000`.

**Фикс.**
- Health-check HAProxy перенесли на `healthCheckNodePort` (для этого Service перевели в `type: LoadBalancer` с MetalLB; для NodePort этот порт не создаётся) — он отвечает 200 только на узлах с локальными подами.
- Альтернатива, которую выбрали для части сервисов: `Cluster` + PROXY protocol от HAProxy к Ingress (IP клиента передаётся в заголовке протокола, SNAT kube-proxy не мешает).
- Ingress-контроллер — DaemonSet на выделенных узлах: подов столько же, сколько узлов в пуле HAProxy.

**Что запомнить.**
- `Local` сохраняет IP клиента, но превращает узлы без подов в «чёрные дыры».
- Внешний балансировщик при `Local` обязан проверять узлы по `healthCheckNodePort` (или знать, где поды).
- Альтернатива — PROXY protocol/`X-Forwarded-For` на L7.

---

## 💼 Вопросы с собеседования

### 🟢 Junior

**1. Как Service находит свои поды?**
По `selector`: контроллер EndpointSlice собирает IP готовых подов с этими метками и портом `targetPort`; kube-proxy на каждом узле превращает ClusterIP:port в правила DNAT на эти адреса.

**2. Чем отличаются ClusterIP, NodePort и LoadBalancer?**
ClusterIP — виртуальный адрес внутри кластера. NodePort — плюс порт 30000–32767 на каждом узле. LoadBalancer — плюс внешний балансировщик облака (или MetalLB), который шлёт на NodePort'ы/поды. Подробно — networks 08-3.

**3. Service есть, curl к нему возвращает `Connection refused` мгновенно. Что проверите?**
EndpointSlice: если пуст — selector не совпадает или поды не Ready (kube-proxy ставит REJECT); если адреса есть — `targetPort` не тот, и отказывает уже сам под.

### 🟡 Middle

**4. Почему под за NodePort/LoadBalancer видит IP узла, а не клиента, и как это исправить?**
При `externalTrafficPolicy: Cluster` узел может переслать трафик на под другого узла и делает SNAT. `Local` сохраняет IP, но шлёт только на локальные поды — узлы без подов отбрасывают трафик, LB должен проверять `healthCheckNodePort`. Альтернатива — L7-заголовки (`X-Forwarded-For`) или PROXY protocol.

**5. Почему gRPC-клиент нагружает только один под из пяти?**
kube-proxy балансирует соединения на L4; gRPC держит одно долгое HTTP/2-соединение. Нужна L7-балансировка (Envoy, mesh) или клиентская балансировка по headless Service.

**6. Что происходит с под в EndpointSlice, когда его удаляют?**
`ready: false`, `serving: true` (пока проходит readiness), `terminating: true`. Новые соединения на него не идут; если все поды завершаются, kube-proxy использует serving-адреса, чтобы не обрывать трафик полностью.

### 🔴 Senior

**7. Чем nftables-режим kube-proxy лучше iptables и когда переходить?**
iptables: цепочки на каждый Service/endpoint, линейный проход и перезапись больших таблиц — на десятках тысяч Service обновления занимают секунды CPU и задерживают изменения endpoints. nftables: verdict maps с поиском за O(1), атомарные инкрементальные обновления. Stable с 1.33, ipvs устаревает. Переходить при больших кластерах и после проверки, что CNI/инструменты не завязаны на iptables-цепочки kube-proxy.

**8. Как снизить межзонный трафик внутри кластера и чем рискуете?**
`trafficDistribution: PreferSameZone` (в 1.36; `PreferClose` устарел) или `PreferSameNode` — kube-proxy предпочитает endpoints своей зоны/узла по hints в EndpointSlice. Риск — перекос нагрузки, если реплики распределены по зонам неравномерно; нужен topology spread и мониторинг нагрузки по зонам.

**9. Как отладить Service, который работает с одних узлов и не работает с других?**
Сравнить правила kube-proxy на узлах (`iptables-save`/`nft list table ip kube-proxy`), жив ли kube-proxy на проблемном узле и его логи (sync ошибки), `externalTrafficPolicy`/`internalTrafficPolicy: Local`, conntrack (`conntrack -L`), сеть между узлами (03-1). Разбор такого кейса — networks 08-3 §4.

---

## ⚠️ Подводные камни

- Пустой EndpointSlice → мгновенный `Connection refused` (REJECT), а не таймаут — не ищите проблему в сети.
- `targetPort` числом расходится с портом контейнера после изменения образа — задавайте именем.
- `externalTrafficPolicy: Local` без health-check'ов на `healthCheckNodePort` — «чёрные дыры» на узлах без подов; у NodePort такого порта нет.
- Envoy Gateway по умолчанию ставит своему Service `Local` (00-1 §6).
- `sessionAffinity: ClientIP` за SNAT превращается в «всё в один под».
- kube-proxy балансирует соединения, не запросы: keepalive и HTTP/2 прилипают к поду.
- `trafficDistribution: PreferClose` устарел в 1.36 — `PreferSameZone`/`PreferSameNode`.
- `port-forward svc/…` выбирает один под и не балансирует (00-2).
- ClusterIP не пингуется — это не адрес интерфейса.

---

## Чеклист

- [ ] Пройду цепочку selector → EndpointSlice → под → kube-proxy и найду разрыв.
- [ ] Отличу пустой EndpointSlice от неверного `targetPort` по симптомам.
- [ ] Выберу `externalTrafficPolicy` и объясню, что нужно внешнему LB при `Local`.
- [ ] Прочитаю условия ready/serving/terminating в EndpointSlice.
- [ ] Включу sessionAffinity и trafficDistribution и объясню их ограничения.
- [ ] Переключу kube-proxy между iptables и nftables и найду правила Service в обоих.

---

## Задание со звёздочкой

Сделайте вход стенда без SNAT и без «чёрных дыр»:

1. Поставьте в kind cloud-provider-kind (он реализует `type: LoadBalancer` для kind — ⚠️ на стенде не проверялось) или MetalLB в режиме L2 с пулом из подсети `kind`.
2. Переведите Service Envoy Gateway в `LoadBalancer` с `externalTrafficPolicy: Local` (через `EnvoyProxy`, 00-1 §3).
3. Проверьте, что `healthCheckNodePort` отвечает 200 только на узле с подом Envoy (`curl http://<узел>:<порт>/healthz`), и что orders-api видит IP клиента в логах.
4. Масштабируйте Envoy до 2 реплик и проверьте, как меняются ответы health-check'а.

---

→ Следующая часть: **03-3. DNS в кластере** — `ndots:5` и сколько запросов уходит в CoreDNS за одно внешнее имя (замер), FQDN с точкой, `dnsConfig`, кэш CoreDNS, ловушка busybox nslookup; база — networks 08-4.
