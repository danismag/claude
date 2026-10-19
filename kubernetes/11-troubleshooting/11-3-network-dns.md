# 11-2. Сеть и DNS: пошагово

> Модуль 11 «Диагностика» · часть 2 из 3 · 🟢🟡🔴 · ~45 мин чтения + ~1 ч тренажёров · Нужно: стенд 00-1 с orders (02-x), Envoy Gateway (03-4). Опирается на 03-1…03-5.

---

## Зачем это DevOps-у

«Сайт отдаёт 503» — на звонке не скажешь «где-то в сети». Сильный ответ: «запрос проходит Gateway → HTTPRoute → Service → EndpointSlice → под, а под ходит в DNS и БД. Код ответа и время подсказывают слой, проверяю его одной командой». Такой подход и проверяют на собеседовании, и он же сокращает инцидент с часа до пяти минут.

Сквозной запрос — `curl http://orders.localhost:8088/api/orders`. Ниже восемь поломок на этом пути. Каждая проверена на стенде: код, время и текст ответа Envoy.

---

## 1. Путь запроса и слой по симптому 🟢

```
клиент → NodePort 30080 → Envoy (Gateway lab) → HTTPRoute (hostnames, matches, backendRefs)
      → Service orders-api (selector, port → targetPort) → EndpointSlice (ready-адреса)
      → под :8000 (NetworkPolicy ingress) → приложение
      → DNS (kube-dns 10.96.0.10, search/ndots) → postgres.orders (NetworkPolicy egress) → БД
```

Сводка тренажёров (Envoy Gateway 1.9.2, kindnet, проверено):

| # | Поломка | Код | Время | Тело/признак | Слой |
|---|---|---|---|---|---|
| n1 | selector Service не совпадает | 503 | 1 мс | пустое; EndpointSlice без адресов | Service |
| n2 | неверный `targetPort` | 503 | 1 мс | `upstream connect error … reset reason: remote connection failure` | Service → под |
| n3 | чужой `Host` | 404 | 1 мс | пустое | HTTPRoute hostnames |
| n4 | `backendRef` на несуществующий Service | 500 | 1 мс | пустое; `ResolvedRefs=False BackendNotFound` | HTTPRoute |
| n5 | NetworkPolicy закрыла ingress пода | 503 | **10 с** | `… reset reason: connection timeout`; поды при этом `1/1` | NetworkPolicy |
| n6 | egress разрешён только к БД, без DNS | 504 | **15 с** | `upstream request timeout`; поды `0/1` | NetworkPolicy/DNS |
| n7 | короткое имя `postgres` из другого ns | — | — | `not found`; `postgres.orders` работает | DNS search |
| n8 | CoreDNS 0 реплик | 504 | 15 с | `upstream request timeout`; поды `0/1` | DNS |

Как читать:
- **мгновенный 503 с пустым телом** — бэкенду некуда идти (нет эндпоинтов);
- **мгновенный 503 `remote connection failure`** — адрес есть, порт закрыт (RST);
- **503 через 10 с `connection timeout`** — пакеты пропадают: NetworkPolicy, маршрутизация, узел. 10 с — это connect timeout кластера в Envoy Gateway;
- **504 через 15 с** — соединение установлено, но приложение не успело ответить: 15 с — таймаут маршрута по умолчанию в Envoy Gateway. Дальше смотрим, что тормозит в самом приложении (DNS, БД);
- **404** — маршрут не совпал (Host, path), **500 с `ResolvedRefs=False`** — маршрут ссылается на несуществующий объект.

## 2. Проверка по слоям 🟡

```bash
# Gateway и маршрут
kubectl get gateway -A; kubectl -n orders get httproute orders-api -o jsonpath='{range .status.parents[0].conditions[*]}{.type}={.status} {.reason}: {.message}{"\n"}{end}'
# Service → EndpointSlice
kubectl -n orders get svc orders-api -o jsonpath='{.spec.selector} {.spec.ports}{"\n"}'
kubectl -n orders get endpointslice -l kubernetes.io/service-name=orders-api -o jsonpath='{range .items[0].endpoints[*]}{.addresses[0]} {.conditions}{"\n"}{end}'
kubectl -n orders get pods -l app=orders-api -o wide --show-labels
# под напрямую, минуя Service (с узла или из debug-пода)
docker exec lab-worker2 curl -s -w ' %{http_code} %{time_total}s\n' http://<podIP>:8000/api/orders
# Service изнутри кластера
kubectl run t --rm -it --image=busybox:1.37 --restart=Never -- wget -qO- -T 3 http://orders-api.orders/api/orders
# NetworkPolicy
kubectl -n orders get networkpolicy; kubectl -n orders describe networkpolicy
# DNS из пода (getent — тот же резолвер, что у приложения)
kubectl -n orders exec <pod> -- getent hosts postgres
kubectl -n orders exec <pod> -- cat /etc/resolv.conf
kubectl -n kube-system get pods -l k8s-app=kube-dns; kubectl -n kube-system logs -l k8s-app=kube-dns --tail=20
```

Правило: **двигайтесь от пода наружу, а не снаружи внутрь.** Если `curl podIP:8000` работает, а через Service нет — дело в Service. Если через Service работает, а через Gateway нет — в маршруте. Каждый шаг отсекает половину пути.

## 3. Разбор тренажёров 🟡

**n1. Selector.** EndpointSlice `endpoints: null`, Envoy сразу отдаёт 503. Сравните `svc.spec.selector` с `--show-labels` подов. Типичный повод — переименовали метку в Deployment (или в Helm-шаблоне) и забыли про Service.

**n2. targetPort.** `targetPort: 8080`, а контейнер слушает 8000: EndpointSlice получает порт 8080, SYN упирается в закрытый порт, RST → `remote connection failure`. Именованный `targetPort: http` устойчивее (03-2): он берётся из `containerPort` с этим именем.

**n3. Host.** `orders.local` → 404, `ORDERS.localhost` → 200 (имя хоста регистронезависимо, проверено). Проверьте `hostnames` и заголовок `Host`, который реально приходит. За балансировщиком/CDN он может быть переписан.

**n4. backendRef.** Маршрут принят (`Accepted=True`), но `ResolvedRefs=False BackendNotFound: … service orders/orders-ap not found` → 500. Сюда же: ссылка на Service в другом namespace без `ReferenceGrant` (`RefNotPermitted`, 03-4).

**n5. Ingress закрыт.** Все поды `1/1`: kubelet проверяет probes с узла, а kindnet трафик с узла не режет. Снаружи при этом 503 через 10 с. «Поды Ready, а сервис недоступен, и ответ приходит ровно через таймаут» — почти всегда NetworkPolicy или маршрутизация. Ищите политики, которые выбирают под: `kubectl get netpol -o wide`.

**n6. Egress без DNS.** Классика при внедрении default-deny (03-5): разрешили к БД, забыли UDP/TCP 53 к kube-dns. Изнутри пода: `getaddrinfo('postgres')` → `gaierror [Errno -3] Temporary failure in name resolution` через **20 с** (таймауты резолвера × попытки × search-домены). При этом TCP по IP к БД проходит за 3 мс (проверено). Readiness `/ready` проверяет БД, поэтому поды стали `0/1`. Фикс — правило egress к `k8s-app=kube-dns` в `kube-system` на порт 53 UDP+TCP.

**n7. Короткое имя.** В поде из `lab-11-2` (проверено, `getent hosts`):

```
postgres                           -> not found
postgres.orders                    -> 10.244.2.250
postgres.orders.svc.cluster.local  -> 10.244.2.250
orders-api.orders                  -> 10.96.100.97
kubernetes.default                 -> 10.96.0.1
```

Короткое имя ищется только в своём namespace (`search lab-11-2.svc.cluster.local svc.cluster.local cluster.local`). ⚠️ busybox `nslookup` проходит search-домены иначе, чем glibc: на стенде `nslookup postgres.orders` отвечал `NXDOMAIN`, хотя имя работает. Проверяйте `getent hosts` или из образа самого приложения.

**n8. CoreDNS 0 реплик.** У Service kube-dns нет эндпоинтов. В поде без приложения `getaddrinfo` падает мгновенно (`0.0 s`): нет эндпоинтов → kube-proxy отвечает отказом, а не тишиной. А `orders-api` при этом отвечал 503 через **10 с** (`OperationalError … Temporary failure in name resolution`, запрос прямо в под, проверено): у драйвера БД свой цикл попыток. Снаружи — 504 через 15 с. Уже открытые соединения продолжают работать, ломаются новые резолвы. Поэтому падение DNS часто выглядит как «тормозит часть запросов».

**Что пишет Envoy в access-лог** (проверено, поля `response_code`, `response_flags`, `response_code_details`):

| Тренажёр | Код | Флаг | Детали |
|---|---|---|---|
| n1 нет эндпоинтов | 503 | `-` | `direct_response` — Envoy Gateway сам вписывает ответ в маршрут, когда у бэкенда нет адресов |
| n4 нет Service | 500 | `-` | `direct_response` — то же для невалидного backendRef |
| n3 чужой Host | 404 | `NR` | `route_not_found` |
| n2 порт закрыт | 503 | `UF` | `upstream_reset_before_response_started{remote_connection_failure\|delayed_connect_error:_Connection_refused}` |
| n5 пакеты режутся | 503 | `UF` | `…{connection_timeout}` |
| n6, n8 приложение не ответило | 504 | `UT` | `response_timeout` |

`direct_response` в логе — подсказка смотреть на конфигурацию (Service, EndpointSlice, статус HTTPRoute), а не на сеть.

⚠️ **Наблюдение на стенде (n6, n8):** когда поды становились `0/1` (EndpointSlice `ready:false`), Envoy продолжал отправлять им запросы и отдавал 504 через 15 с, а не мгновенный 503, как при пустом EndpointSlice (n1). Вероятная причина — panic mode Envoy: если доля здоровых хостов ниже 50 %, Envoy балансирует по всем. В среде агента не проверено. Вывод для диагностики: «504 и поды NotReady» не противоречат друг другу.

## 4. DNS: ndots и цена коротких имён 🔴

`ndots:5`: имя с менее чем пятью точками сначала пробуется со всеми search-доменами. Для `example.com` это три запроса `example.com.<search>` (каждый с A и AAAA), и только потом абсолютный. На стенде первый «холодный» резолв `example.com` занял 1331 мс. Повторные запросы берутся из кэша CoreDNS: `example.com` 0,6–4,8 мс, `example.com.` (с точкой) 0,2 мс (проверено). Под нагрузкой это умножение QPS к CoreDNS и conntrack-записей UDP (03-3).

Что делать:
- внешние имена в конфиге — FQDN с точкой (`api.github.com.`), внутренние — `svc.ns.svc.cluster.local`;
- `dnsConfig.options: [{name: ndots, value: "2"}]` для подов, которые ходят во внешний мир;
- NodeLocal DNSCache — кэш на каждом узле (03-3), снимает нагрузку и проблему conntrack UDP;
- CoreDNS: ≥ 2 реплики, anti-affinity, PDB, autoscaler по числу узлов; алерт на `coredns_dns_responses_total{rcode="SERVFAIL"}`.

## 5. Инструменты 🟡

| Задача | Инструмент |
|---|---|
| HTTP изнутри кластера | `kubectl run --rm -it --image=busybox:1.37 -- wget -qO- -T 3 …`, `curl -w '%{http_code} %{time_total}'` |
| сеть пода без shell в образе | `kubectl debug -it <pod> --image=nicolaka/netshoot --target=<c>` (тот же network namespace) |
| пакеты | `tcpdump -i any port 5432` в debug-контейнере или `kubectl debug node/…` (11-3) |
| conntrack/iptables узла | `docker exec lab-worker conntrack -L`, `iptables-save \| grep orders-api` (03-2) |
| статус маршрутов | `status.parents[].conditions` у HTTPRoute, `kubectl -n envoy-gateway-system logs deploy/envoy-gateway` |
| логи Envoy | `kubectl -n envoy-gateway-system logs -l gateway.envoyproxy.io/owning-gateway-name=lab -c envoy` — JSON с `response_flags` и `response_code_details` (см. §3, таблица флагов) |

---

## 🔧 Лаба

Тренажёры ломают `orders` по одному; после каждого — откат и проверка 200. Функция проверки (в среде агента запрос идёт изнутри docker-сети; у вас — `curl http://orders.localhost:8088/api/orders`):

```bash
C(){ curl -s -m 20 -o /tmp/b -w '%{http_code} %{time_total}s ' -H "Host: ${1:-orders.localhost}" http://127.0.0.1:8088/api/orders; head -c 120 /tmp/b; echo; }
C     # 200 0.009s {"orders": [...
```

### n1 — selector

```bash
kubectl -n orders patch svc orders-api -p '{"spec":{"selector":{"app":"orders-apl"}}}'
sleep 4; kubectl -n orders get endpointslice -l kubernetes.io/service-name=orders-api -o jsonpath='{.items[*].endpoints}'; echo; C
# null
# 503 0.001124s
kubectl -n orders patch svc orders-api -p '{"spec":{"selector":{"app":"orders-api"}}}'
```

### n2 — targetPort

```bash
kubectl -n orders patch svc orders-api --type=json -p '[{"op":"replace","path":"/spec/ports/0/targetPort","value":8080}]'
sleep 4; C
# 503 0.001320s upstream connect error or disconnect/reset before headers. reset reason: remote connection failure
kubectl -n orders patch svc orders-api --type=json -p '[{"op":"replace","path":"/spec/ports/0/targetPort","value":"http"}]'
```

### n3, n4 — маршрут

```bash
C orders.local       # 404 0.001001s
C ORDERS.localhost   # 200
kubectl -n orders patch httproute orders-api --type=json -p '[{"op":"replace","path":"/spec/rules/0/backendRefs/0/name","value":"orders-ap"}]'
sleep 5; C           # 500 0.001076s
kubectl -n orders get httproute orders-api -o jsonpath='{range .status.parents[0].conditions[*]}{.type}={.status} {.reason}: {.message}{"\n"}{end}'
# Accepted=True Accepted: Route is accepted
# ResolvedRefs=False BackendNotFound: Failed to process route rule 0 backendRef 0: service orders/orders-ap not found.
kubectl -n orders patch httproute orders-api --type=json -p '[{"op":"replace","path":"/spec/rules/0/backendRefs/0/name","value":"orders-api"}]'
```

### n5 — ingress закрыт

```bash
kubectl -n orders apply -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: t-deny-ingress}
spec:
  podSelector: {matchLabels: {app: orders-api}}
  policyTypes: [Ingress]
EOF
sleep 5; C; kubectl -n orders get pods -l app=orders-api
# 503 10.001259s upstream connect error or disconnect/reset before headers. reset reason: connection timeout
# оба пода 1/1
kubectl -n orders delete networkpolicy t-deny-ingress
```

### n6 — egress без DNS

```bash
kubectl -n orders apply -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: t-egress-db-only}
spec:
  podSelector: {matchLabels: {app: orders-api}}
  policyTypes: [Egress]
  egress:
  - to: [{podSelector: {matchLabels: {app: postgres}}}]
    ports: [{port: 5432, protocol: TCP}]
EOF
sleep 15; C; kubectl -n orders get pods -l app=orders-api
# 504 15.002503s upstream request timeout       поды 0/1
P=$(kubectl -n orders get pod -l app=orders-api -o name | head -1)
kubectl -n orders exec $P -- python -c "import socket; print(socket.getaddrinfo('postgres',5432)[0][4])"
# socket.gaierror: [Errno -3] Temporary failure in name resolution   (через 20 с)
kubectl -n orders get events --field-selector reason=Unhealthy --sort-by=.lastTimestamp | tail -1
# Readiness probe failed: … context deadline exceeded (Client.Timeout exceeded while awaiting headers)
```

Исправьте сами: добавьте в политику второе правило egress к kube-dns (`namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: kube-system}}` + `podSelector: {matchLabels: {k8s-app: kube-dns}}`, порты 53/UDP и 53/TCP). Убедитесь, что поды стали `1/1` и `C` → 200. Затем `kubectl -n orders delete networkpolicy t-egress-db-only`.

### n7 — имя из другого namespace

```bash
kubectl create ns lab-11-2
kubectl -n lab-11-2 run py --image=python:3.12-slim --restart=Never -- sleep 3600
kubectl -n lab-11-2 wait --for=condition=Ready pod/py
kubectl -n lab-11-2 exec py -- cat /etc/resolv.conf
for n in postgres postgres.orders postgres.orders.svc.cluster.local; do kubectl -n lab-11-2 exec py -- getent hosts $n || echo "$n not found"; done
```

### n8 — CoreDNS лежит

```bash
kubectl -n kube-system scale deploy coredns --replicas=0; sleep 10
C                                    # 504 15.000679s upstream request timeout
kubectl -n lab-11-2 exec py -- getent hosts postgres.orders || echo fail   # мгновенно
kubectl -n orders get pods -l app=orders-api                                # 0/1
kubectl -n kube-system scale deploy coredns --replicas=2
kubectl -n kube-system rollout status deploy coredns; sleep 6; C            # 200
```

### Уборка

```bash
kubectl -n orders get networkpolicy          # No resources found
kubectl delete ns lab-11-2
C                                             # 200
```

---

## 🔥 Кейс из прода: «каждый пятый запрос ждёт 5 секунд»

**Контекст.** После переезда на новые узлы p99 латентности сервиса вырос с 80 мс до 5,1 с, p50 не изменился. Сервис ходит во внешний платёжный API по короткому имени `api.payments.example`.

**Разбор.**
1. Задержка кратна 5 с — это `timeout:5` резолвера, значит DNS.
2. `tcpdump port 53` в debug-контейнере: на каждое имя — 4 пары A/AAAA (ndots:5 × search). Иногда ответ на AAAA не приходит.
3. Известная гонка conntrack (03-3): A и AAAA уходят с одного сокета параллельно, одна запись теряется при вставке в conntrack, и glibc ждёт 5 с до повтора. На старых узлах стоял NodeLocal DNSCache, на новых его забыли.

**Фикс.**
- NodeLocal DNSCache на новых узлах (DaemonSet в базовых аддонах платформы, проверка в чеклисте узла).
- Имя в конфиге — FQDN с точкой; `ndots: 2` для подов с внешними вызовами.
- Временно, до раскатки кэша — `options single-request-reopen` в `dnsConfig` (glibc).

**Что запомнить.**
- Задержка кратна 5 с — значит DNS-таймаут, пока не доказано обратное.
- p99 растёт, а p50 нет — проблема в доле запросов: потеря пакетов, гонка, один плохой эндпоинт.
- Аддоны узла (DNS-кэш, CNI, агенты) должны быть частью образа или пула узлов, а не ручной установкой.

---

## 💼 Вопросы с собеседования

### 🟢 Junior

**1. Под работает, Service есть, но запросы не доходят. С чего начнёте?**
`kubectl get endpointslice -l kubernetes.io/service-name=<svc>`: пусто — selector не совпал с метками или поды не Ready. Есть адреса — проверить `targetPort` (`curl podIP:port`), затем NetworkPolicy.

**2. Как обратиться к Service из другого namespace?**
`<svc>.<ns>` или полное `<svc>.<ns>.svc.cluster.local`. Короткое имя резолвится только в своём namespace (search-домены `/etc/resolv.conf`).

### 🟡 Middle

**3. Gateway отвечает 503. Как понять причину по ответу?**
Мгновенно и пусто — нет эндпоинтов (selector, readiness). Мгновенно с `connection failure` — порт закрыт (`targetPort`). Через connect timeout (10 с у Envoy Gateway) — пакеты теряются (NetworkPolicy, маршрутизация). 504 через 15 с — приложение не отвечает в таймаут маршрута. В логе Envoy: `direct_response` (нет эндпоинтов/бэкенда), `UF` (подключение), `UT` (таймаут), `NR` (нет маршрута).

**4. Внедрили default-deny egress — всё сломалось. Почему?**
Не разрешили DNS: UDP и TCP 53 к подам kube-dns в `kube-system`. Резолв падает после таймаутов (на стенде 20 с), readiness, зависящая от БД, проваливается, поды выпадают из Service.

**5. Поды Ready, а снаружи таймаут. Как так?**
Kubelet проверяет probes с узла, а трафик с узла политиками обычно не режется. Ingress NetworkPolicy может закрыть доступ от Gateway при зелёных пробах. Проверка — `curl podIP` из другого пода и `kubectl get netpol`, выбирающие под.

### 🔴 Senior

**6. p99 вырос до 5 с, p50 в норме. Гипотезы и проверки?**
Таймаут резолвера 5 с: гонка conntrack для параллельных A/AAAA, потеря UDP, перегруженный CoreDNS. Проверка: `tcpdump port 53`, метрики CoreDNS (latency, SERVFAIL), `conntrack -S` (insert_failed). Фикс: NodeLocal DNSCache, FQDN/ndots, `single-request-reopen`, масштабирование CoreDNS.

**7. Что произойдёт с работающим сервисом, если CoreDNS упадёт целиком?**
Уже открытые соединения и пулы продолжат работать, новые резолвы падают. Мгновенно, если у kube-dns нет эндпоинтов, или после таймаута, если поды есть, но не отвечают. Readiness, завязанная на зависимости, выводит поды из Service. Защита: ≥ 2 реплики с anti-affinity, PDB, NodeLocal DNSCache (кэш переживает короткие сбои), пулы соединений в приложении.

---

## ⚠️ Подводные камни

- busybox `nslookup` проходит search-домены иначе, чем glibc — проверяйте `getent hosts` или образом приложения.
- Зелёные readiness/liveness не доказывают сетевой доступ от Gateway и других подов.
- `ndots:5` умножает DNS-запросы к внешним именам в 4–5 раз.
- egress-политика без правила на DNS ломает всё, что резолвит имена, включая пробы, зависящие от БД.
- Envoy при всех NotReady-эндпоинтах может продолжать слать трафик (⚠️ panic mode): 504 вместо ожидаемого 503.
- Таймауты по умолчанию в Envoy Gateway (connect 10 с, маршрут 15 с) — следы в длительностях ответов; сверяйте с таймаутами клиента.
- Именованный `targetPort` устойчивее числового при смене порта в контейнере.

---

## Чеклист

- [ ] Нарисую путь сквозного запроса и назову, что проверять на каждом слое.
- [ ] По коду, времени и тексту ответа Envoy назову вероятный слой.
- [ ] Найду проблему selector/targetPort/backendRef за одну-две команды.
- [ ] Отличу NetworkPolicy от падения приложения по времени ответа.
- [ ] Объясню search/ndots и починю egress-политику без DNS.
- [ ] Объясню, что видит сервис при падении CoreDNS.

---

## Задание со звёздочкой

1. Включите в CoreDNS плагин `log` (через ConfigMap `coredns` в `kube-system`, `kubectl -n kube-system rollout restart deploy coredns`) и посчитайте, сколько запросов уходит в CoreDNS на один `getaddrinfo('example.com')` при `ndots:5` и при `ndots:2`.
2. Проверьте гипотезу panic mode: найдите в конфиге Envoy (`egctl config envoy-proxy cluster …` или admin-интерфейс Envoy через `port-forward`) параметр `healthy_panic_threshold` для кластера orders-api. Повторите n8 с одной неготовой репликой из трёх и с тремя из трёх.
3. Верните конфиг CoreDNS в исходное состояние.

---

→ Следующая часть: **11-3. Узел и control plane** — `NotReady` узла, давление на диск и eviction, kubelet и containerd через `journalctl`/`crictl`, недоступный apiserver, тормозящий etcd, и runbook «что смотреть, когда упало всё».
