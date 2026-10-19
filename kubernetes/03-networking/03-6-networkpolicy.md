# 03-5. NetworkPolicy

> Модуль 3 «Сеть» · часть 5 из 5 · 🟡🔴 · ~1 ч чтения + ~45 мин лабы · Нужно: стенд 00-1 (kindnet реализует NetworkPolicy). База — networks 08-6: модель NetworkPolicy, ограничения стандарта и расширения Calico/Cilium, защита metadata-сервиса, отладка на Calico с логом дропов.

---

## Зачем это DevOps-у

По умолчанию в Kubernetes любой под может открыть соединение к любому поду любого namespace — включая базу данных. NetworkPolicy — штатный способ это закрыть, и его требуют аудиторы и безопасники. Ломается всё на одних и тех же местах: забыли DNS в egress, перепутали AND и OR в селекторах, политика «не работает», потому что CNI её не поддерживает, или работает «странно», потому что установленные соединения не рвутся. На собеседовании: «как изолировать namespace», «почему после default deny сломался DNS».

В сквозном сценарии закроем namespace `orders`: снаружи — только через Gateway, к PostgreSQL — только orders-api, наружу — только DNS.

---

## 1. Модель — коротко 🟡

Подробно — networks 08-6 §1. Главное для эксплуатации:

- Политика выбирает поды (`podSelector`) и типы (`Ingress`, `Egress`). Под, выбранный хотя бы одной политикой данного типа, становится **изолированным** по этому типу: разрешено только то, что разрешено явно.
- Политики **аддитивны**: только разрешения, запретов нет. Порядка нет — итог = объединение всех разрешений.
- Правила — по IP подов **после DNAT**: «разрешить Service» нельзя, разрешают поды за ним (проверено: egress на поды `app=api` открыл и прямой IP пода, и ClusterIP Service).
- Действует только при поддержке CNI. kindnet стенда поддерживает (таблица nftables `inet kindnet-network-policies` на узлах); Flannel без дополнений — **нет**: политики создаются и молча игнорируются.

### AND и OR в `from`/`to` 🟡

Самая частая ошибка — один дефис:

```yaml
from:                                   # ОДИН элемент: namespace И метка пода
- namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: lab-03-5-other}}
  podSelector: {matchLabels: {role: client}}

from:                                   # ДВА элемента: namespace ИЛИ метка пода (в своём namespace)
- namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: lab-03-5-other}}
- podSelector: {matchLabels: {role: client}}
```

Проверено:

| Источник | AND (один элемент) | OR (два элемента) |
|---|---|---|
| `lab-03-5-other`, `role=client` | 200 | 200 |
| `lab-03-5-other`, `role=other` | timeout | **200** |
| `lab-03-5`, `role=client` | timeout | 200 |

`podSelector` без `namespaceSelector` — поды **своего** namespace: клиент с той же меткой из другого namespace не проходит (проверено в шаге 2 лабы). Для выбора namespace по имени — метка `kubernetes.io/metadata.name`, её ставит сам Kubernetes на каждый namespace.

## 2. Default deny и что он ломает 🟡

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: default-deny-ingress}
spec:
  podSelector: {}
  policyTypes: [Ingress]
```

Проверено — матрица доступа к Service `api` (лаба, шаг 2):

```
== baseline
  same-ns client   -> api: 200 (0.0s)
  same-ns stranger -> api: 200 (0.0s)
  other-ns client  -> api: 200 (0.0s)
  via gateway      -> api: 200
== default deny ingress
  same-ns client   -> api: URLError:timed out (3.0s)
  same-ns stranger -> api: URLError:timed out (3.0s)
  other-ns client  -> api: URLError:timed out (3.0s)
  via gateway      -> api: 000
== allow gateway OR same-ns role=client
  same-ns client   -> api: 200 (0.0s)
  same-ns stranger -> api: URLError:timed out (3.0s)
  other-ns client  -> api: URLError:timed out (3.0s)
  via gateway      -> api: 200
```

Запрещённое соединение — **таймаут**, а не отказ: пакеты отбрасываются молча (сравните с мгновенным REJECT при пустом Service — 03-2). Таймаут — признак, что нужно смотреть политики. Gateway — это поды Envoy в namespace `envoy-gateway-system`: без разрешения от него маршрут превращается в таймаут.

### Ловушка: egress и DNS 🟡

Egress-политика для клиента «только к поду `app=api`, порт 8000» (проверено):

```
dns gaierror (20.0s); http://api.lab-03-5/version -> URLError:[Errno -3] Temporary failure i (20.0s)
dns gaierror (20.0s); http://10.244.2.136:8000/version -> 200 (0.0s)       ← по IP пода работает
dns gaierror (20.0s); http://10.96.187.232/version -> 200 (0.0s)           ← по ClusterIP тоже
```

По IP всё работает, по имени — 20 секунд ожидания и ошибка: запросы к CoreDNS (под в `kube-system`, порт 53) не разрешены. Добавили правило:

```yaml
- to: [{namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: kube-system}}, podSelector: {matchLabels: {k8s-app: kube-dns}}}]
  ports: [{port: 53, protocol: UDP}, {port: 53, protocol: TCP}]
```

— `dns ok (0.0s); … -> 200`. TCP 53 обязателен: большие ответы и повторы идут по TCP. Если используется NodeLocal DNSCache (03-3), разрешать нужно его адрес `169.254.20.10` через `ipBlock`.

Почему «через минуту после включения»: приложения кэшируют DNS и держат пулы соединений — сначала всё работает, ломается при следующем резолвинге или переподключении (кейс networks 08-6).

## 3. Установленные соединения 🔴

Проверено (долгое TCP-соединение клиент → echo-сервер, на 4-й секунде удалена разрешающая политика):

```
t=0s established: ping
...
t=13s established: ping          ← соединение живёт
new connection: TimeoutError     ← новое — запрещено
```

Политика проверяется на **новых** соединениях; установленные пропускаются по conntrack. Так ведут себя kindnet (первый пакет нового соединения отправляется на проверку в userspace через NFQUEUE, дальше соединение помечается меткой conntrack и пропускается — видно в `nft list table inet kindnet-network-policies`) и большинство CNI. Последствие: после закручивания политик старые соединения (пулы к БД, WebSocket, gRPC-стримы) работают до разрыва — проверять политику нужно **новыми** соединениями и после рестарта клиентов; «вчера включили, сегодня ночью после рестарта всё легло» — классика.

Отличие в тестах: HTTP-сервер orders-api работает по HTTP/1.0 и закрывает соединение после каждого ответа — каждый запрос = новое соединение, политика срабатывает сразу. Сервисы с keepalive отреагируют позже.

## 4. Трафик от узла и probes 🟡

Kubelet делает probes с адреса узла. Большинство CNI (Calico, kindnet) пропускают трафик от своего узла к локальным подам независимо от политик — проверено: после default deny в `orders` и `rollout restart` поды orders-api стали Ready, readiness проходит. Но это поведение реализации, не стандарта: в Cilium с `policy-enforcement: always` и в ряде облачных CNI host-трафик нужно разрешать явно — иначе после default deny все поды «падают» по probes.

## 5. Политики для orders 🟡

Проверенный набор (лежит в `~/lab/k8s/orders-api/k8s/extra/networkpolicy.yaml` после лабы):

```yaml
default-deny:  podSelector: {}, policyTypes: [Ingress, Egress]
allow-dns:     egress всех подов → kube-system/kube-dns :53 UDP+TCP
orders-api:    ingress из ns envoy-gateway-system :8000; egress → app=postgres :5432
postgres:      ingress из app=orders-api :5432
```

Проверено:

```
gateway -> 200 (×3)
lab-03-5/client -> orders-api: URLError          ← чужой namespace — нет
lab-03-5/client -> postgres: TimeoutError         ← к БД — только orders-api
orders-api -> internet: URLError                  ← наружу — нет
after restart gateway -> 200                       ← probes kubelet проходят
```

Что ещё обычно добавляют: egress к внешним API через `ipBlock` (CIDR провайдера, `except` для metadata-сервиса облака `169.254.169.254/32` — networks 08-6 §2), ingress от Prometheus (namespace мониторинга, порт метрик), egress к Vault/брокеру.

## 6. Отладка: «почему не проходит» 🟡

1. Симптом: таймаут, а не refused → подозрение на политику.
2. `kubectl get networkpolicy -A -o wide` — какие политики выбирают под-источник (Egress) и под-получатель (Ingress): `kubectl get netpol -n <ns> -o json | jq '.items[] | {name: .metadata.name, sel: .spec.podSelector, types: .spec.policyTypes}'`.
3. Сравнить метки: `kubectl get pod --show-labels`, `kubectl get ns --show-labels` — селекторы совпадают? AND/OR?
4. Порт — **порт пода** (`targetPort`), не Service.
5. DNS разрешён в egress?
6. На узле: правила реализации (`nft list table inet kindnet-network-policies`, у Calico — `calicoctl`/лог-правила, у Cilium — `cilium monitor --type drop`, `hubble observe`).
7. Проверять новым соединением.

Дальше стандарта: AdminNetworkPolicy/BaselineAdminNetworkPolicy (кластерные политики платформы с приоритетами и явными deny — SIG Network, на стенде CRD не установлены, ⚠️ не проверялось), политики L7 и по DNS-именам — Cilium/Calico (networks 08-6 §2).

---

## 🔧 Лаба

### Шаг 0. Подготовка

```bash
kubectl config use-context kind-lab
kubectl create ns lab-03-5; kubectl create ns lab-03-5-other
kubectl config set-context --current --namespace=lab-03-5
kubectl create deploy api --image=localhost:5001/orders-api:2.0 --port=8000
kubectl expose deploy api --port=80 --target-port=8000
kubectl run client --image=python:3.12-slim --labels=role=client --command -- sleep infinity
kubectl run stranger --image=python:3.12-slim --labels=role=stranger --command -- sleep infinity
kubectl -n lab-03-5-other run client --image=python:3.12-slim --labels=role=client --command -- sleep infinity
kubectl -n lab-03-5-other run other-any --image=python:3.12-slim --labels=role=other --command -- sleep infinity
kubectl apply -f - <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: api}
spec:
  parentRefs: [{name: lab, namespace: envoy-gateway-system}]
  hostnames: ["np.localhost"]
  rules: [{backendRefs: [{name: api, port: 80}]}]
EOF
kubectl rollout status deploy/api; kubectl wait --for=condition=Ready pod --all; kubectl -n lab-03-5-other wait --for=condition=Ready pod --all

probe() { kubectl -n $1 exec $2 -- python -c "
import urllib.request,time
t=time.perf_counter()
try: r=str(urllib.request.urlopen('$3',timeout=3).status)
except Exception as e: r=type(e).__name__+':'+str(getattr(e,'reason',e))[:28]
print(f'{r} ({time.perf_counter()-t:.1f}s)')"; }
check() {
  echo "  same-ns client   -> api: $(probe lab-03-5 client http://api.lab-03-5/version)"
  echo "  same-ns stranger -> api: $(probe lab-03-5 stranger http://api.lab-03-5/version)"
  echo "  other-ns client  -> api: $(probe lab-03-5-other client http://api.lab-03-5/version)"
  echo "  via gateway      -> api: $(curl -s -m 3 -o /dev/null -w '%{http_code}' -H 'Host: np.localhost' http://127.0.0.1:8088/version)"
}
echo "== baseline"; check
```

### Шаг 1. Default deny и выборочное разрешение

```bash
kubectl apply -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: default-deny-ingress}
spec:
  podSelector: {}
  policyTypes: [Ingress]
EOF
sleep 3; echo "== default deny ingress"; check
kubectl apply -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: api-allow}
spec:
  podSelector: {matchLabels: {app: api}}
  policyTypes: [Ingress]
  ingress:
  - from:
    - namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: envoy-gateway-system}}
    - podSelector: {matchLabels: {role: client}}
    ports: [{port: 8000}]
EOF
sleep 3; echo "== allow gateway OR same-ns role=client"; check
docker exec lab-worker sh -c 'nft list table inet kindnet-network-policies | head -30'
```

Проверено: матрица в §2 (запрос «via gateway» агент делал из сети kind на `lab-control-plane:30080`).

### Шаг 2. AND против OR

```bash
for variant in AND OR; do
  if [ $variant = AND ]; then FROM='[{"namespaceSelector":{"matchLabels":{"kubernetes.io/metadata.name":"lab-03-5-other"}},"podSelector":{"matchLabels":{"role":"client"}}}]'
  else FROM='[{"namespaceSelector":{"matchLabels":{"kubernetes.io/metadata.name":"lab-03-5-other"}}},{"podSelector":{"matchLabels":{"role":"client"}}}]'; fi
  kubectl patch networkpolicy api-allow --type=json -p "[{\"op\":\"replace\",\"path\":\"/spec/ingress/0/from\",\"value\":$FROM}]"; sleep 3
  echo "== $variant"
  echo "  other-ns role=client -> $(probe lab-03-5-other client http://api.lab-03-5/version)"
  echo "  other-ns role=other  -> $(probe lab-03-5-other other-any http://api.lab-03-5/version)"
  echo "  same-ns role=client  -> $(probe lab-03-5 client http://api.lab-03-5/version)"
done
```

Проверено: таблица в §1.

### Шаг 3. Egress и DNS

```bash
kubectl apply -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: client-egress}
spec:
  podSelector: {matchLabels: {role: client}}
  policyTypes: [Egress]
  egress:
  - to: [{podSelector: {matchLabels: {app: api}}}]
    ports: [{port: 8000}]
EOF
sleep 3
tryc() { kubectl exec client -- python -c "
import urllib.request,time,socket
t=time.perf_counter()
try: socket.getaddrinfo('api.lab-03-5',80); d='dns ok'
except Exception as e: d='dns '+type(e).__name__
d+=f' ({time.perf_counter()-t:.1f}s)'
t=time.perf_counter()
try: r=str(urllib.request.urlopen('$1',timeout=3).status)
except Exception as e: r=type(e).__name__+':'+str(getattr(e,'reason',e))[:30]
print(f'{d}; $1 -> {r} ({time.perf_counter()-t:.1f}s)')"; }
tryc http://api.lab-03-5/version
tryc http://$(kubectl get pod -l app=api -o jsonpath='{.items[0].status.podIP}'):8000/version
tryc http://$(kubectl get svc api -o jsonpath='{.spec.clusterIP}')/version
kubectl patch networkpolicy client-egress --type=json -p '[{"op":"add","path":"/spec/egress/-","value":{"to":[{"namespaceSelector":{"matchLabels":{"kubernetes.io/metadata.name":"kube-system"}},"podSelector":{"matchLabels":{"k8s-app":"kube-dns"}}}],"ports":[{"port":53,"protocol":"UDP"},{"port":53,"protocol":"TCP"}]}}]'
sleep 3; tryc http://api.lab-03-5/version; tryc http://1.1.1.1
kubectl delete networkpolicy client-egress
```

Проверено: вывод в §2; `http://1.1.1.1 -> URLError:timed out` — наружу egress не разрешён.

### Шаг 4. Установленное соединение

```bash
kubectl run echo-tcp --image=python:3.12-slim --labels=app=api --command -- python -c "
import socketserver
class H(socketserver.StreamRequestHandler):
    def handle(self):
        for line in self.rfile: self.wfile.write(line)
socketserver.ThreadingTCPServer(('0.0.0.0',8000),H).serve_forever()"
kubectl wait --for=condition=Ready pod/echo-tcp
kubectl apply -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: api-allow}
spec:
  podSelector: {matchLabels: {app: api}}
  policyTypes: [Ingress]
  ingress:
  - from: [{podSelector: {matchLabels: {role: client}}}]
    ports: [{port: 8000}]
EOF
sleep 3; IP=$(kubectl get pod echo-tcp -o jsonpath='{.status.podIP}')
kubectl exec client -- python -c "
import socket,time
s=socket.create_connection(('$IP',8000),timeout=3)
for i in range(14):
    try: s.sendall(b'ping\n'); print(f't={i}s established: {s.recv(16).strip().decode()}', flush=True)
    except Exception as e: print(f't={i}s established: {type(e).__name__}', flush=True)
    time.sleep(1)" &
sleep 4; kubectl delete networkpolicy api-allow; wait
kubectl exec client -- python -c "
import socket
try: socket.create_connection(('$IP',8000),timeout=3); print('new connection: ok')
except Exception as e: print('new connection:', type(e).__name__)"
```

Проверено: вывод в §3.

### Шаг 5. Закрыть namespace orders

```bash
mkdir -p ~/lab/k8s/orders-api/k8s/extra
cat > ~/lab/k8s/orders-api/k8s/extra/networkpolicy.yaml <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: default-deny, namespace: orders}
spec:
  podSelector: {}
  policyTypes: [Ingress, Egress]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: allow-dns, namespace: orders}
spec:
  podSelector: {}
  policyTypes: [Egress]
  egress:
  - to: [{namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: kube-system}}, podSelector: {matchLabels: {k8s-app: kube-dns}}}]
    ports: [{port: 53, protocol: UDP}, {port: 53, protocol: TCP}]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: orders-api, namespace: orders}
spec:
  podSelector: {matchLabels: {app: orders-api}}
  policyTypes: [Ingress, Egress]
  ingress:
  - from: [{namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: envoy-gateway-system}}}]
    ports: [{port: 8000}]
  egress:
  - to: [{podSelector: {matchLabels: {app: postgres}}}]
    ports: [{port: 5432}]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: postgres, namespace: orders}
spec:
  podSelector: {matchLabels: {app: postgres}}
  policyTypes: [Ingress]
  ingress:
  - from: [{podSelector: {matchLabels: {app: orders-api}}}]
    ports: [{port: 5432}]
EOF
kubectl apply -f ~/lab/k8s/orders-api/k8s/extra/networkpolicy.yaml; sleep 4
for i in 1 2 3; do curl -s -o /dev/null -w '%{http_code}\n' http://orders.localhost:8088/api/orders; done
kubectl exec client -- python -c "
import urllib.request, socket
try: print('-> orders-api:', urllib.request.urlopen('http://orders-api.orders/api/orders',timeout=3).status)
except Exception as e: print('-> orders-api:', type(e).__name__)
try: socket.create_connection(('postgres.orders',5432),timeout=3); print('-> postgres: ok')
except Exception as e: print('-> postgres:', type(e).__name__)"
kubectl -n orders rollout restart deploy/orders-api && kubectl -n orders rollout status deploy/orders-api
curl -s -o /dev/null -w '%{http_code}\n' http://orders.localhost:8088/api/orders
```

Проверено: вывод в §5. Политики можно оставить — дальнейшие части учитывают их отсутствие, поэтому в уборке они удаляются; файл остаётся для задания и для 12-2.

### Уборка

```bash
kubectl delete -f ~/lab/k8s/orders-api/k8s/extra/networkpolicy.yaml
kubectl config set-context --current --namespace=default
kubectl delete ns lab-03-5 lab-03-5-other
curl -s -o /dev/null -w '%{http_code}\n' http://orders.localhost:8088/api/orders     # 200
```

---

## 🔥 Кейс из прода: «политики “не работают” — всё открыто»

**Контекст.** Аудит потребовал изоляции namespace с платёжными данными. Команда написала NetworkPolicy (default deny + разрешения), применила, проверила `kubectl get netpol` — объекты на месте. Пентестер через неделю спокойно подключился к PostgreSQL из пода в соседнем namespace.

**Разбор.**
1. CNI кластера — Flannel (VXLAN) без Calico/Canal. Flannel не реализует NetworkPolicy: объекты принимаются API (это просто ресурсы), но никто их не исполняет.
2. Проверка команды была «объекты созданы» вместо «запрещённое соединение не проходит».
3. На стенде аналог — пустой Ingress без контроллера (03-4): API принимает всё, исполняет — контроллер.

**Фикс.**
- Перешли на CNI с поддержкой политик (Calico в режиме policy-only поверх Flannel — Canal — как быстрый шаг, затем миграция на Cilium в плановом окне).
- Приёмочные проверки политик в CI стенда: матрица «откуда → куда → ожидаемый результат» (как `check()` в лабе), новыми соединениями.
- Тест «отрицательного» сценария — обязательная часть изменения политик.

**Что запомнить.**
- NetworkPolicy исполняет CNI; без поддержки — молчаливое «всё разрешено».
- Проверять политику нужно запрещённым соединением, а не наличием объекта.
- Таймаут вместо отказа — характерный признак работающей политики.

---

## 💼 Вопросы с собеседования

### 🟢 Junior

**1. Что такое NetworkPolicy?**
Правила, какие поды могут принимать (Ingress) и открывать (Egress) соединения: по меткам подов и namespace, IP-диапазонам и портам. Исполняет CNI.

**2. Что разрешено по умолчанию?**
Всё: любой под к любому поду. Под становится изолированным только когда его выбирает хотя бы одна политика соответствующего типа.

### 🟡 Middle

**3. Как изолировать namespace, оставив доступ только через Ingress/Gateway?**
Default deny (`podSelector: {}`, Ingress и Egress) + разрешение ingress из namespace контроллера (`namespaceSelector` по `kubernetes.io/metadata.name`) на порт пода + egress на DNS (kube-dns UDP/TCP 53) + нужные внутренние зависимости.

**4. Почему после default deny сломалось всё, но не сразу?**
Egress запрещает DNS: приложения работают, пока живы кэши DNS и установленные соединения; при следующем резолвинге или переподключении — ошибки. Нужно разрешить egress на CoreDNS по UDP и TCP 53.

**5. В чём разница между одним элементом `from` с namespaceSelector и podSelector и двумя элементами?**
Один элемент — AND (поды с меткой в выбранных namespace), два — OR (все поды выбранных namespace или поды с меткой в своём namespace). Ошибка в одном дефисе открывает доступ шире задуманного.

### 🔴 Senior

**6. Вы ужесточили политику, а соединения продолжают работать. Почему?**
Политика проверяется на новых соединениях, установленные пропускаются по conntrack. Долгие соединения (пулы БД, WebSocket, gRPC) работают до разрыва. Проверять новыми соединениями, планировать рестарт клиентов, учитывать при инцидентной изоляции.

**7. Чего не умеет стандартная NetworkPolicy?**
Явных deny и приоритетов, политик на уровне кластера (только namespace), L7 (HTTP-пути, методы), правил по DNS-именам, логирования дропов. Это закрывают AdminNetworkPolicy и расширения CNI (Calico GlobalNetworkPolicy, CiliumNetworkPolicy с L7 и FQDN).

**8. Как проверять сетевые политики в CI?**
Поднять стенд (kind с CNI, поддерживающим политики), применить манифесты, прогнать матрицу «источник → назначение → ожидание» новыми соединениями, включая отрицательные случаи; хранить матрицу рядом с политиками. Инструменты визуализации/симуляции политик дополняют, но не заменяют прогон.

---

## ⚠️ Подводные камни

- CNI без поддержки NetworkPolicy молча игнорирует политики.
- Default deny egress без DNS — ошибки резолвинга (20 с ожидания на стенде), всплывающие с задержкой.
- Один дефис меняет AND на OR.
- `podSelector` без `namespaceSelector` — только свой namespace.
- Порт в политике — порт пода, не Service.
- Политики работают с IP подов после DNAT; Service как объект разрешить нельзя.
- Установленные соединения не рвутся — проверяйте новыми.
- Host-трафик (probes kubelet) разрешён не во всех CNI.
- Запрещённое соединение — таймаут, а не refused: не путайте с проблемами Service.

---

## Чеклист

- [ ] Закрою namespace default deny и разрешу нужные потоки, включая DNS.
- [ ] Отличу AND от OR в селекторах и проверю на матрице.
- [ ] Объясню, почему старые соединения переживают новую политику.
- [ ] Проверю, что CNI вообще исполняет политики.
- [ ] Отлажу «почему не проходит» по шагам §6.

---

## Задание со звёздочкой

Сделайте политики платформы для всех namespace команд:

1. Напишите (в Markdown) набор «базовых» политик, который применяется в каждый новый namespace: default deny, DNS, ingress от Gateway и от Prometheus (namespace `monitoring`, порт `metrics`).
2. Подумайте, как раскатывать его автоматически: Kyverno `generate`, Helm-чарт namespace'а, ApplicationSet в Argo CD (08-2). Какой вариант переживёт удаление политики командой?
3. Если CRD AdminNetworkPolicy доступны в вашей реализации (kindnet их не реализует — ⚠️), перепишите default deny как BaselineAdminNetworkPolicy: что изменится для команд?

---

→ Следующая часть: **04-1. ConfigMap и Secret** — модуль «Конфигурация и данные»: env против тома, как и когда приложение видит изменения (замер), subPath, перезапуск по хэшу конфига, immutable, base64 — не шифрование, шифрование Secret в etcd.
