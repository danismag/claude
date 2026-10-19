# 03-4. Gateway API, Ingress и TLS

> Модуль 3 «Сеть» · часть 4 из 5 · 🟡🔴 · ~1,5 ч чтения + ~1 ч лабы · Нужно: стенд 00-1 (Envoy Gateway 1.9.2, Gateway `lab`), cert-manager ставится в лабе. База — networks 08-5: полная цепочка внешнего трафика, Ingress и ingress-nginx на kind, MetalLB, первый взгляд на Gateway API; TLS и PKI — networks 05-4.

---

## Зачем это DevOps-у

L7-вход в кластер — то, через что идёт весь пользовательский трафик. В 2026 году это ещё и **миграция**: ingress-nginx, самый популярный Ingress-контроллер, в марте 2026 закончил сопровождение — без исправлений безопасности. Команды переходят на Gateway API (Envoy Gateway, Istio, Cilium, NGINX Gateway Fabric, Traefik). В работе: маршруты не применяются («Accepted=False»), canary весами, перенос аннотаций ingress-nginx, сертификаты и их продление. На собеседовании: «Ingress vs Gateway API», «как сделать canary без mesh», «как устроен cert-manager».

Сквозной сценарий уже идёт через Gateway API: `curl http://orders.localhost:8088/api/orders` → Gateway `lab` → HTTPRoute `orders-api` (00-1). Здесь — как это устроено и что ещё умеет.

---

## 1. Ingress и Gateway API 🟡

| | Ingress (`networking.k8s.io/v1`) | Gateway API (`gateway.networking.k8s.io/v1`) |
|---|---|---|
| Объекты | Ingress, IngressClass | GatewayClass → Gateway → HTTPRoute / GRPCRoute / TLSRoute / TCPRoute / UDPRoute |
| Роли | один объект на всё | платформа: GatewayClass, Gateway (порты, TLS, кто может цепляться); приложение: Route |
| Возможности в стандарте | хост, путь, TLS | плюс заголовки, query, методы, веса, зеркалирование, редиректы, rewrite, таймауты, cross-namespace с разрешениями |
| Всё остальное | **аннотации контроллера** (у ingress-nginx — сотни, несовместимы между контроллерами) | в стандарте или в типизированных расширениях (Policy-объекты) |
| Статус | заморожен: новых функций не будет | развивается: на стенде v1.6.1 (bundle), канал experimental |

Проверено: Ingress без контроллера — просто объект в etcd. На стенде нет ни одного `IngressClass` (`No resources found`), Ingress с `ingressClassName: nginx` создаётся, `ADDRESS` пуст, `status={"loadBalancer":{}}`, трафик на `legacy.localhost` получает 404 от Envoy (такого хоста нет ни в одном HTTPRoute). Аннотация `nginx.ingress.kubernetes.io/rewrite-target` никого не интересует.

## 2. Gateway стенда изнутри 🟡

```
GatewayClass eg (controllerName: gateway.envoyproxy.io/gatewayclass-controller, parametersRef → EnvoyProxy nodeport)
   └─ Gateway lab (ns envoy-gateway-system), listener http:80, allowedRoutes: All namespaces
        ├─ HTTPRoute orders-api (ns orders)   hostnames: orders.localhost
        └─ HTTPRoute shop (ns lab-03-4)       hostnames: shop.localhost
Envoy Gateway (контроллер) → Deployment envoy-…-lab (прокси) + Service NodePort 80:30080
```

Контроллер читает Gateway и Route, генерирует конфигурацию Envoy и отдаёт её прокси по xDS. Состояние смотрят в `status`:

```bash
kubectl -n envoy-gateway-system get gateway lab -o jsonpath='{range .status.listeners[*]}{.name}: attachedRoutes={.attachedRoutes} {range .conditions[*]}{.type}={.status} {end}{"\n"}{end}'
```

Проверено: `http: attachedRoutes=1 Programmed=True Accepted=True ResolvedRefs=True` (на пустом стенде — один маршрут orders-api).

Условия Route — первое, куда смотреть, когда «маршрут не работает»:

| Условие | False означает |
|---|---|
| `Accepted` | Gateway не принял маршрут: namespace не разрешён `allowedRoutes`, hostname не совпал ни с одним listener, нет такого Gateway/listener |
| `ResolvedRefs` | бэкенд не найден или запрещён: нет Service/порта, ссылка в другой namespace без ReferenceGrant |

## 3. Маршрутизация, веса и приоритет правил 🟡🔴

Маршрут лабы (две версии orders-api по 2 реплики):

```yaml
spec:
  parentRefs: [{name: lab, namespace: envoy-gateway-system}]
  hostnames: ["shop.localhost"]
  rules:
  - matches: [{path: {type: PathPrefix, value: /api}, headers: [{name: x-canary, value: "true"}]}]
    backendRefs: [{name: api-2-1, port: 80}]
  - matches: [{path: {type: PathPrefix, value: /api}}]
    backendRefs:
    - {name: api-2-0, port: 80, weight: 90}
    - {name: api-2-1, port: 80, weight: 10}
  - matches: [{path: {type: PathPrefix, value: /}}]
    filters: [{type: RequestRedirect, requestRedirect: {path: {type: ReplaceFullPath, replaceFullPath: /api/orders}, statusCode: 302}}]
```

Проверено (1000 запросов на `/api/orders`, клиент в сети kind):

```
weights 90/10 over 1000: {'api-2-1': 99, 'api-2-0': 901}
x-canary: true -> {'api-2-1': 20}
GET / -> 302 http://shop.localhost/api/orders
unknown host -> 404
```

Веса работают на уровне запросов (Envoy — L7), а не соединений, как у kube-proxy (03-2). Это и есть canary без mesh: меняете веса 90/10 → 50/50 → 0/100 правкой одного объекта (вручную, из CI или Argo Rollouts/Flagger с анализом метрик).

### Ловушка приоритета 🔴

Первая версия маршрута содержала правило **только с заголовком** (без `path`). Проверено:

```
x-canary: true -> {'api-2-0': 19, 'api-2-1': 1}
```

Заголовок «не работал»: запросы с `x-canary: true` уходили в общий канал 90/10. Причина — правила Gateway API применяются не по порядку в YAML, а по **приоритету**: точный путь > самый длинный префикс > метод > больше совпадений по заголовкам > больше по query. Правило без `path` считается `PathPrefix: /` и проигрывает правилу `/api`. После добавления `path: /api` к правилу с заголовком — 20 из 20 в `api-2-1`. В ingress-nginx canary делался аннотациями на отдельном Ingress — при миграции такие правила нужно переписать и **проверить**.

Ещё одна мелочь, пойманная на стенде: Envoy нормализует путь — `/api/orders/../../version` превращается в `/version` до маршрутизации (защита от обхода правил путями).

## 4. Чужой namespace: ReferenceGrant 🟡

Route в `lab-03-4` ссылается на Service `orders-api` в namespace `orders`. Проверено:

```
Accepted=True Accepted: Route is accepted
ResolvedRefs=False RefNotPermitted: Failed to process route rule 0 backendRef 0: Backend ref to Service orders/orders-api not permitted by any ReferenceGrant.
cross.localhost -> 500
```

Владелец целевого namespace разрешает доступ явно:

```yaml
apiVersion: gateway.networking.k8s.io/v1      # v1 в Gateway API 1.6 (раньше — v1beta1)
kind: ReferenceGrant
metadata: {name: allow-lab-03-4, namespace: orders}
spec:
  from: [{group: gateway.networking.k8s.io, kind: HTTPRoute, namespace: lab-03-4}]
  to: [{group: "", kind: Service, name: orders-api}]
```

После него — `ResolvedRefs=True`, `200`. Модель безопасности: команда может опубликовать маршрут на общем Gateway, но не может направить трафик в чужие сервисы без согласия их владельца. В Ingress такой защиты нет. Тот же механизм нужен Gateway, чтобы взять TLS-секрет из другого namespace.

## 5. TLS: cert-manager 🟡🔴

cert-manager — оператор, который выпускает и продлевает сертификаты: `Issuer`/`ClusterIssuer` (кто подписывает: ACME/Let's Encrypt, свой CA, Vault, облачные CA) → `Certificate` (что выпустить) → Secret `kubernetes.io/tls`. Установка на стенд (лаба, шаг 5) — Helm-чарт v1.21.2 с `enableGatewayAPI: true` (за 31 с).

Цепочка стенда: самоподписанный `ClusterIssuer selfsigned` → `Certificate lab-ca` (isCA) → `ClusterIssuer lab-ca` (тип CA). Для Gateway достаточно аннотации — cert-manager сам создаёт Certificate для каждого HTTPS-listener'а с hostname (gateway-shim):

```bash
kubectl -n envoy-gateway-system annotate gateway lab cert-manager.io/cluster-issuer=lab-ca
# + listener: {name: https-shop, protocol: HTTPS, port: 443, hostname: shop.localhost,
#              tls: {mode: Terminate, certificateRefs: [{name: shop-localhost-tls}]}}
```

Проверено:

```
certificate.cert-manager.io/shop-localhost-tls condition met
dnsNames=["shop.localhost"] issuer=lab-ca notAfter=2027-01-12T10:10:21Z renewal=2026-12-13T10:10:21Z
http: attachedRoutes=3 Programmed=True
https-shop: attachedRoutes=1 Programmed=True
80:30080 443:30708
```

Срок — 90 дней (дефолт cert-manager), продление за 1/3 до конца. Маршрут `shop` прицепился к обоим listener'ам — hostname совпал. Проверка (клиент в сети kind, CA из Secret `lab-ca`):

```
* SSL connection using TLSv1.3 / TLS_AES_256_GCM_SHA384 / x25519 / RSASSA-PSS
* ALPN: server accepted h2
*  subject:
*  expire date: Jan 12 10:10:21 2027 GMT
*  issuer: CN=lab-ca
https -> 200
no CA -> 000 SSL certificate problem: unable to get local issuer certificate
other SNI -> 000 Recv failure: Connection reset by peer
```

`subject` пустой — cert-manager кладёт имя только в SAN (CN устарел для серверных сертификатов). Запрос с SNI, которого нет ни у одного listener'а, Envoy сбрасывает на уровне TLS. HTTP/2 включился сам (ALPN).

В проде вместо своего CA — ACME (Let's Encrypt): `ClusterIssuer` с `acme` и решателем `http01` (через тот же Gateway — cert-manager создаёт временный HTTPRoute) или `dns01` (wildcard, закрытые кластеры). Что мониторить: `certmanager_certificate_expiration_timestamp_seconds`, условие `Ready` у Certificate, события `Issuing`/ошибки ACME. Срок жизни публичных сертификатов сокращается (CA/B Forum: до 200 дней с марта 2026 и далее вниз) — ручное продление больше не вариант (networks 05-4).

## 6. Миграция с ingress-nginx 🔴

ingress-nginx завершил сопровождение в марте 2026 (объявление Kubernetes SIG Network, ноябрь 2025): контроллер продолжит работать, но без исправлений, в том числе уязвимостей уровня CVE-2025-1974 («IngressNightmare» — RCE через admission webhook контроллера). План:

| Шаг | Что делать |
|---|---|
| инвентаризация | `kubectl get ingress -A -o json \| jq '[.items[].metadata.annotations // {} \| keys[]] \| group_by(.) \| map({(.[0]): length}) \| add'` — какие аннотации используются и сколько раз |
| выбор реализации | Gateway API-контроллер: Envoy Gateway, NGINX Gateway Fabric (тот же nginx), Istio, Cilium, Traefik, облачные (GKE, AWS Gateway Controller) |
| перевод объектов | `ingress2gateway` (инструмент SIG Network) генерирует Gateway/HTTPRoute из Ingress и части аннотаций (⚠️ в среде агента не запускался) |
| аннотации без аналога в стандарте | `rewrite-target` → фильтр `URLRewrite`; canary-аннотации → веса/заголовки в одном HTTPRoute (§3, проверьте приоритет!); rate limit, auth, CORS → Policy-объекты реализации (`BackendTrafficPolicy`, `SecurityPolicy` у Envoy Gateway); `configuration-snippet` — переписывать, это и был главный источник уязвимостей |
| параллельный запуск | новый Gateway с отдельным IP/LB, перенос DNS по одному хосту, сравнение логов и кодов ответов |
| TLS | cert-manager переходит с аннотаций Ingress на аннотацию Gateway (gateway-shim) |

Мелочи, на которых ломаются: ingress-nginx по умолчанию делал редирект HTTP→HTTPS и нормализовал слэши — в Gateway это явные правила; таймауты ingress-nginx (`proxy-read-timeout` 60 с по умолчанию) и вашей реализации Gateway API различаются — сверьте дефолты по её документации и задайте явно (`timeouts.request`/`backendRequest` в HTTPRoute; ⚠️ дефолты Envoy Gateway на стенде не измерялись); WebSocket-кейс — networks 08-5 §6.

---

## 🔧 Лаба

### Шаг 0. Подготовка: две версии orders-api

```bash
kubectl config use-context kind-lab
kubectl create ns lab-03-4
kubectl config set-context --current --namespace=lab-03-4
for v in 2.0 2.1; do n=api-${v/./-}; kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata: {name: $n}
spec:
  replicas: 2
  selector: {matchLabels: {app: $n}}
  template:
    metadata: {labels: {app: $n}}
    spec:
      containers:
      - name: api
        image: localhost:5001/orders-api:$v
        ports: [{name: http, containerPort: 8000}]
        readinessProbe: {httpGet: {path: /ready, port: http}, periodSeconds: 2}
---
apiVersion: v1
kind: Service
metadata: {name: $n}
spec:
  selector: {app: $n}
  ports: [{name: http, port: 80, targetPort: http}]
EOF
done
kubectl rollout status deploy/api-2-0; kubectl rollout status deploy/api-2-1
```

Клиент для замеров — скрипт в контейнере сети `kind` (с хоста те же запросы — `curl -H 'Host: shop.localhost' http://127.0.0.1:8088/...`):

```bash
mkdir -p /tmp/lab-03-4 && cat > /tmp/lab-03-4/gw.py <<'EOF'
import urllib.request, collections, json, sys
BASE = 'http://lab-control-plane:30080'
class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a): return None
op = urllib.request.build_opener(NoRedirect)
def get(path, host='shop.localhost', hdr={}):
    r = urllib.request.Request(BASE + path, headers={'Host': host, **hdr})
    try:
        resp = op.open(r, timeout=3); return resp.status, resp.read().decode(), resp.headers
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode(), e.headers
def ver(body): return json.loads(body)['pod'].rsplit('-', 2)[0]
c = collections.Counter(ver(get('/api/orders')[1]) for _ in range(1000)); print('weights 90/10 over 1000:', dict(c))
print('x-canary: true ->', dict(collections.Counter(ver(get('/api/orders', hdr={'x-canary': 'true'})[1]) for _ in range(20))))
code, _, h = get('/'); print('GET / ->', code, h['location'])
code, body, _ = get('/api/orders', host='unknown.localhost'); print('unknown host ->', code)
EOF
gw() { docker run --rm --network kind -v /tmp/lab-03-4:/w python:3.12-slim python /w/gw.py; }
```

### Шаг 1. Маршрут с ловушкой приоритета

```bash
kubectl apply -f - <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: shop}
spec:
  parentRefs: [{name: lab, namespace: envoy-gateway-system}]
  hostnames: ["shop.localhost"]
  rules:
  - matches: [{headers: [{name: x-canary, value: "true"}]}]
    backendRefs: [{name: api-2-1, port: 80}]
  - matches: [{path: {type: PathPrefix, value: /api}}]
    backendRefs:
    - {name: api-2-0, port: 80, weight: 90}
    - {name: api-2-1, port: 80, weight: 10}
  - matches: [{path: {type: PathPrefix, value: /}}]
    filters: [{type: RequestRedirect, requestRedirect: {path: {type: ReplaceFullPath, replaceFullPath: /api/orders}, statusCode: 302}}]
EOF
sleep 3
kubectl get httproute shop -o jsonpath='{range .status.parents[*].conditions[*]}{.type}={.status} {.reason}{"\n"}{end}'
gw
```

Проверено: `Accepted=True`, `ResolvedRefs=True`; веса 901/99; `x-canary: true -> {'api-2-0': 19, 'api-2-1': 1}` — заголовок не работает (§3); `GET / -> 302`; `unknown host -> 404`.

### Шаг 2. Починить приоритет

```bash
kubectl patch httproute shop --type=json -p '[{"op":"replace","path":"/spec/rules/0/matches/0","value":{"path":{"type":"PathPrefix","value":"/api"},"headers":[{"name":"x-canary","value":"true"}]}}]'
sleep 3; gw
```

Проверено: `x-canary: true -> {'api-2-1': 20}`.

### Шаг 3. Ссылка в чужой namespace

```bash
kubectl apply -f - <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: cross}
spec:
  parentRefs: [{name: lab, namespace: envoy-gateway-system}]
  hostnames: ["cross.localhost"]
  rules: [{backendRefs: [{name: orders-api, namespace: orders, port: 80}]}]
EOF
sleep 3
kubectl get httproute cross -o jsonpath='{range .status.parents[*].conditions[*]}{.type}={.status} {.reason}: {.message}{"\n"}{end}'
docker run --rm --network kind curlimages/curl:8.11.1 -s -o /dev/null -w '%{http_code}\n' -H 'Host: cross.localhost' http://lab-control-plane:30080/api/orders
kubectl apply -f - <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: ReferenceGrant
metadata: {name: allow-lab-03-4, namespace: orders}
spec:
  from: [{group: gateway.networking.k8s.io, kind: HTTPRoute, namespace: lab-03-4}]
  to: [{group: "", kind: Service, name: orders-api}]
EOF
sleep 4
kubectl get httproute cross -o jsonpath='{range .status.parents[*].conditions[*]}{.type}={.status} {.reason}{"\n"}{end}'
docker run --rm --network kind curlimages/curl:8.11.1 -s -o /dev/null -w '%{http_code}\n' -H 'Host: cross.localhost' http://lab-control-plane:30080/api/orders
kubectl -n orders delete referencegrant allow-lab-03-4
```

Проверено: вывод в §4 (`500` → `200`).

### Шаг 4. Ingress без контроллера

```bash
kubectl get ingressclass
kubectl apply -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: shop-legacy
  annotations: {nginx.ingress.kubernetes.io/rewrite-target: /}
spec:
  ingressClassName: nginx
  rules:
  - host: legacy.localhost
    http: {paths: [{path: /, pathType: Prefix, backend: {service: {name: api-2-0, port: {number: 80}}}}]}
EOF
kubectl get ingress shop-legacy; kubectl get ingress shop-legacy -o jsonpath='{.status}{"\n"}'
```

Проверено: `No resources found` для IngressClass, у Ingress пустой `ADDRESS`, `{"loadBalancer":{}}`.

### Шаг 5. TLS через cert-manager

```bash
cat > /tmp/lab-03-4/cm-values.yaml <<'EOF'
crds: {enabled: true}
config:
  apiVersion: controller.config.cert-manager.io/v1alpha1
  kind: ControllerConfiguration
  enableGatewayAPI: true
EOF
helm upgrade --install cert-manager oci://quay.io/jetstack/charts/cert-manager --version v1.21.2 \
  -n cert-manager --create-namespace -f /tmp/lab-03-4/cm-values.yaml --wait --timeout 5m
kubectl apply -f - <<'EOF'
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata: {name: selfsigned}
spec: {selfSigned: {}}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata: {name: lab-ca, namespace: cert-manager}
spec:
  isCA: true
  commonName: lab-ca
  secretName: lab-ca
  privateKey: {algorithm: ECDSA, size: 256}
  issuerRef: {name: selfsigned, kind: ClusterIssuer}
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata: {name: lab-ca}
spec: {ca: {secretName: lab-ca}}
EOF
kubectl -n cert-manager wait --for=condition=Ready certificate/lab-ca
kubectl -n envoy-gateway-system annotate gateway lab cert-manager.io/cluster-issuer=lab-ca
kubectl -n envoy-gateway-system patch gateway lab --type=json -p '[{"op":"add","path":"/spec/listeners/-","value":{"name":"https-shop","protocol":"HTTPS","port":443,"hostname":"shop.localhost","allowedRoutes":{"namespaces":{"from":"All"}},"tls":{"mode":"Terminate","certificateRefs":[{"name":"shop-localhost-tls"}]}}}]'
until kubectl -n envoy-gateway-system get certificate shop-localhost-tls 2>/dev/null; do sleep 2; done
kubectl -n envoy-gateway-system wait --for=condition=Ready certificate/shop-localhost-tls
kubectl -n envoy-gateway-system get certificate shop-localhost-tls -o jsonpath='dnsNames={.spec.dnsNames} notAfter={.status.notAfter} renewal={.status.renewalTime}{"\n"}'

kubectl -n cert-manager get secret lab-ca -o jsonpath='{.data.ca\.crt}' | base64 -d > /tmp/lab-03-4/lab-ca.crt
NP=$(kubectl -n envoy-gateway-system get svc -l gateway.envoyproxy.io/owning-gateway-name=lab -o jsonpath='{.items[0].spec.ports[?(@.port==443)].nodePort}')
IP=$(docker inspect -f '{{.NetworkSettings.Networks.kind.IPAddress}}' lab-control-plane)
docker run --rm --network kind -v /tmp/lab-03-4:/w curlimages/curl:8.11.1 -sv --cacert /w/lab-ca.crt \
  --resolve shop.localhost:$NP:$IP https://shop.localhost:$NP/api/orders -o /dev/null 2>&1 | grep -E 'SSL connection|issuer|expire|ALPN'
docker run --rm --network kind curlimages/curl:8.11.1 -s --resolve shop.localhost:$NP:$IP https://shop.localhost:$NP/ -o /dev/null -w '%{errormsg}\n'
```

Проверено: вывод в §5. Порт 443 Envoy получил случайный NodePort (30708) — на хост `kind.yaml` пробрасывает только 30080; HTTPS в лабе проверяем из сети kind.

### Уборка

```bash
kubectl -n envoy-gateway-system patch gateway lab --type=json -p '[{"op":"remove","path":"/spec/listeners/1"},{"op":"remove","path":"/metadata/annotations/cert-manager.io~1cluster-issuer"}]'
kubectl -n envoy-gateway-system delete certificate shop-localhost-tls; kubectl -n envoy-gateway-system delete secret shop-localhost-tls
kubectl delete clusterissuer selfsigned lab-ca
helm -n cert-manager uninstall cert-manager
kubectl delete ns cert-manager
kubectl get crd -o name | grep cert-manager.io | xargs kubectl delete
kubectl config set-context --current --namespace=default
kubectl delete ns lab-03-4
rm -rf /tmp/lab-03-4
curl -s -o /dev/null -w '%{http_code}\n' http://orders.localhost:8088/api/orders     # 200 — сквозной сценарий цел
```

---

## 🔥 Кейс из прода: «после переезда с ingress-nginx на Gateway API пропала канарейка»

**Контекст.** 40 сервисов переводили с ingress-nginx на Gateway API (Envoy Gateway) с помощью `ingress2gateway` и ручной доводки. У платёжного сервиса был canary через аннотации ingress-nginx: второй Ingress с `canary: "true"` и `canary-by-header: X-Canary`. После переезда QA с заголовком `X-Canary` попадали в стабильную версию, а 10% случайных пользователей — в canary, где шёл эксперимент с новым платёжным провайдером.

**Разбор.**
1. HTTPRoute после конвертации: правило с одним заголовком (без пути) и правило `/pay` с весами 90/10 — ровно как в шаге 1 лабы.
2. По приоритету Gateway API правило с путём `/pay` важнее правила без пути — заголовок не срабатывал. В ingress-nginx логика canary-аннотаций была другой: заголовок проверялся раньше весов.
3. Тесты миграции проверяли только «отвечает ли 200», а не «в какую версию попал запрос».

**Фикс.**
- В правило с заголовком добавили тот же `path`, что и у правила с весами (шаг 2 лабы).
- В приёмочные проверки миграции — распределение версий: 1000 запросов с заголовком и без, ожидаемые доли (скрипт как `gw.py`).
- Эксперимент с провайдером — не на весах, а на заголовке/cookie для конкретных пользователей.

**Что запомнить.**
- Gateway API выбирает правило по приоритету (путь → метод → заголовки → query), а не по порядку в YAML.
- Аннотации ingress-nginx при миграции — не «конвертируются», а переписываются и проверяются.
- Проверяйте маршрутизацию по содержимому ответа (версия, под), а не по коду 200.

---

## 💼 Вопросы с собеседования

### 🟢 Junior

**1. Зачем нужен Ingress или Gateway, если есть Service типа LoadBalancer?**
LoadBalancer — L4, один внешний IP на сервис. Ingress/Gateway — L7: один вход на много сервисов, маршрутизация по хосту и пути, TLS-терминация, редиректы, веса.

**2. Что нужно, чтобы Ingress заработал?**
Контроллер (ingress-nginx, Traefik и т. д.) и IngressClass; сам объект Ingress без контроллера ничего не делает.

### 🟡 Middle

**3. Чем Gateway API лучше Ingress?**
Разделение ролей (GatewayClass/Gateway — платформа, Route — команды), богатая маршрутизация в стандарте (заголовки, веса, rewrite, редиректы), протоколы кроме HTTP (gRPC, TCP, UDP, TLS passthrough), явные разрешения между namespace (ReferenceGrant), переносимость между реализациями без аннотаций.

**4. Как сделать canary 10% средствами Gateway API?**
Два `backendRefs` в одном правиле HTTPRoute с весами 90/10; для тестировщиков — отдельное правило с совпадением по заголовку **и тому же пути**. Веса — на уровне запросов. Автоматизация — Argo Rollouts/Flagger с анализом метрик.

**5. Маршрут создан, но трафик не идёт. Что смотрите?**
`status.parents[].conditions` маршрута: `Accepted=False` — namespace не разрешён `allowedRoutes`, не совпал hostname или имя listener'а; `ResolvedRefs=False` — нет Service/порта или нужен ReferenceGrant. Затем `status.listeners` Gateway (`attachedRoutes`, `Programmed`), логи контроллера и прокси.

### 🔴 Senior

**6. Как устроен выпуск и продление сертификатов cert-manager?**
Issuer/ClusterIssuer (ACME, CA, Vault…) → Certificate (dnsNames, срок, ключ) → CertificateRequest → подписанный Secret `kubernetes.io/tls`; контроллер продлевает за треть срока до окончания. Для ACME — решатели http01 (временный маршрут через Gateway/Ingress) или dns01 (wildcard, закрытые сети). Для Gateway — gateway-shim: аннотация на Gateway, Certificate на каждый HTTPS-listener с hostname. Мониторинг — срок и `Ready`.

**7. Как спланировать миграцию с ingress-nginx?**
Инвентаризация аннотаций и snippets; выбор реализации Gateway API; генерация HTTPRoute (`ingress2gateway`) и ручной перевод того, чего нет в стандарте (rate limit, auth — в Policy реализации); проверка приоритета правил и таймаутов; параллельный запуск на отдельном LB с переносом DNS по хостам; приёмка по содержимому ответов; перенос TLS на gateway-shim; вывод ingress-nginx.

**8. Зачем ReferenceGrant?**
Чтобы маршрут (или Gateway за TLS-секретом) в одном namespace не мог ссылаться на объекты другого без согласия владельца. Без него любая команда на общем Gateway могла бы направить трафик в чужой Service или вытащить чужой сертификат.

---

## ⚠️ Подводные камни

- Порядок правил в HTTPRoute не определяет выбор — приоритет по пути, методу, заголовкам, query.
- Правило без `path` = `PathPrefix: /` и проигрывает любым более длинным путям.
- Ingress без контроллера и IngressClass — молча ничего не делает.
- Ссылка на Service в чужом namespace без ReferenceGrant — `ResolvedRefs=False`, Envoy отвечает 500.
- Envoy нормализует пути (`..`, двойные слэши) до маршрутизации.
- Аннотации ingress-nginx (canary, rewrite, snippets) не переносятся 1:1.
- cert-manager с Gateway требует `enableGatewayAPI: true`; без него аннотация на Gateway игнорируется.
- `helm uninstall cert-manager` не удаляет CRD — удаляйте отдельно, иначе следующая установка конфликтует с остатками (или наоборот: удаление CRD удаляет все Certificate кластера).
- Таймауты разных контроллеров отличаются — переносите явно.

---

## Чеклист

- [ ] Объясню разницу Ingress и Gateway API и роли объектов Gateway API.
- [ ] Прочитаю статусы Gateway и HTTPRoute и найду причину непринятого маршрута.
- [ ] Настрою canary весами и заголовком с правильным приоритетом и измерю распределение.
- [ ] Разрешу ссылку в чужой namespace через ReferenceGrant.
- [ ] Выпущу сертификат cert-manager'ом для HTTPS-listener'а и проверю TLS.
- [ ] Составлю план миграции с ingress-nginx.

---

## Задание со звёздочкой

Автоматизируйте canary orders-api без внешних инструментов:

1. В namespace `orders` создайте `orders-api-canary` (образ 2.1, 1 реплика) и HTTPRoute с весами 100/0.
2. Напишите (в Markdown, как шаги CI) процедуру: веса 90/10 → проверка доли 5xx по логам Envoy (`kubectl -n envoy-gateway-system logs deploy/envoy-… | grep ' 5[0-9][0-9] '`) за 2 минуты → 50/50 → 0/100 или откат на 100/0.
3. Сломайте canary (образ отвечает 500 на `/api/orders`) и убедитесь, что процедура откатывает.
4. Сравните с Argo Rollouts + Gateway API plugin: что они делают сверх вашей процедуры?

---

→ Следующая часть: **03-5. NetworkPolicy** — kindnet стенда реализует NetworkPolicy через nftables: default deny в namespace, разрешение только из Gateway, ловушка с DNS в egress, отладка «почему не проходит»; база — networks 08-6 (Calico).
