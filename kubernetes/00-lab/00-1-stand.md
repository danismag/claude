# 00-1. Стенд курса

> Модуль 0 «Стенд и инструменты» · часть 1 из 2 · 🟢 · ~30 мин чтения + ~20 мин запуска · Нужно: Docker 27+, 8 ГБ свободной RAM, 20 ГБ диска, kind, kubectl, helm

> Проверено: стенд поднят `lab/lab-up.sh` с нуля за 2 мин 9 с, повторный запуск идемпотентен (18 с), `lab-down.sh` (без `--purge`) → `lab-up.sh` восстанавливает кластер со всеми данными за 51 с; сквозной запрос к orders-api через Gateway отвечает данными из PostgreSQL. kind 0.32.0, Kubernetes 1.36.1, containerd 2.3.1, Envoy Gateway 1.9.2, metrics-server 0.8.0, Docker 29.7.2, Manjaro (ядро 6.18).

---

## Зачем это DevOps-у

Все лабы курса идут на одном кластере, который поднимается одной командой и пересоздаётся за пару минут. Кластер настоящий: те же kube-apiserver, etcd, kubelet и containerd, что в проде, только узлы — контейнеры Docker на вашей машине. Ломать его можно смело: в худшем случае `lab-down.sh --purge && lab-up.sh`.

Сквозной сценарий курса — сервис orders-api из курса `cicd`, теперь в Kubernetes, с PostgreSQL:

```
curl http://orders.localhost:8088/api/orders
```

Каждая часть возвращается к этому запросу: ломает или улучшает одно звено его пути.

---

## 1. Топология 🟢

```
хост (127.0.0.1)
 ├─ :6443x ────────► lab-control-plane    apiserver, etcd, scheduler, controller-manager (static pods),
 │                                         CoreDNS, local-path-provisioner
 ├─ :8088 ─────────►   :30080 (NodePort) ─► Envoy Gateway → HTTPRoute orders.localhost → Service orders-api
 │                   lab-worker            ┐
 │                   lab-worker2           ├ kubelet + containerd 2.3, kube-proxy (iptables), kindnet (CNI)
 │                   lab-worker3           ┘
 └─ :5001 ─────────► kind-registry         registry:2.8.3 — образы стенда, на хосте и в узлах: localhost:5001/…
                     (всё — в docker-сети kind)
```

| Компонент | Где | Зачем в курсе |
|---|---|---|
| kind, Kubernetes 1.36.1 | 4 контейнера `lab-*` | 1 control-plane + 3 worker: scheduling, drain, PDB, DaemonSet, отказ узла |
| kindnet | DaemonSet в `kube-system` | CNI: IP подам, маршруты между узлами (03-1) |
| kube-proxy, режим iptables | DaemonSet | Service → поды (03-2) |
| CoreDNS | Deployment в `kube-system` | имена сервисов (03-3) |
| local-path-provisioner | `local-path-storage`, StorageClass `standard` | PVC на диске узла (04-2) |
| metrics-server 0.8.0 | `kube-system` | `kubectl top`, HPA (05-1, 05-3) |
| Envoy Gateway 1.9.2 + CRD Gateway API | `envoy-gateway-system`, Gateway `lab` | вход в кластер по имени хоста (03-4) |
| реестр | контейнер `kind-registry` | свои образы, ImagePullBackOff, дайджесты |
| orders-api + PostgreSQL | namespace `orders` | сквозной сценарий |

Расширения (cert-manager, Argo CD, Gitea, CloudNativePG и т. п.) ставятся командами в начале своих лаб и удаляются в их конце.

Особенности kind, которые встречаются в лабах:

- **Узел = контейнер.** Зайти на узел — `docker exec -it lab-worker bash`; там `crictl`, `journalctl -u kubelet`, `iptables-save`, `/etc/kubernetes/manifests`.
- **Каждый узел видит все CPU и всю память хоста** (проверено: `cpu: 12`, `memory: 16315248Ki` у каждого из четырёх), резервов и порогов eviction нет. В 05-1 и 05-4 это оговаривается.
- **LoadBalancer нет** — Service типа LoadBalancer остаётся в `<pending>`. Вход в кластер — через NodePort 30080, проброшенный на `127.0.0.1:8088`.

## 2. Требования и установка инструментов 🟢

Ресурсы (замер `docker stats` на поднятом стенде с orders-api): control-plane 1,3 ГиБ, каждый worker 0,3–0,4 ГиБ, реестр 18 МиБ — около 2,5 ГиБ. С расширениями модулей 8–9 — до 5 ГиБ. Диск: образ узла kind ~1 ГБ, всего на стенд ~3 ГБ.

| Инструмент | 🐧 Ubuntu 24.04 | 🅼 Manjaro | Проверено на |
|---|---|---|---|
| Docker | `docker.io` или `docker-ce` (репозиторий Docker) | `sudo pacman -S docker` | 29.7.2 |
| kind | нет в apt: бинарник с GitHub-релиза (ниже) | `sudo pacman -S kind` | 0.32.0 |
| kubectl | репозиторий `pkgs.k8s.io` (ниже) | `sudo pacman -S kubectl` | 1.36.4 |
| helm | репозиторий Helm или бинарник с релиза | `sudo pacman -S helm` | 4.2.2 |

🐧 Ubuntu:

```bash
# kind — один статический бинарник
curl -Lo /tmp/kind https://kind.sigs.k8s.io/dl/v0.32.0/kind-linux-amd64
sudo install -m 0755 /tmp/kind /usr/local/bin/kind && rm /tmp/kind

# kubectl — официальный репозиторий, ветка минорной версии v1.36
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.36/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.36/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt-get update && sudo apt-get install -y kubectl

# helm — бинарник с релиза (версию сверьте с https://github.com/helm/helm/releases)
curl -fsSL https://get.helm.sh/helm-v4.2.2-linux-amd64.tar.gz | tar -xz -C /tmp linux-amd64/helm
sudo install -m 0755 /tmp/linux-amd64/helm /usr/local/bin/helm
```

⚠️ Установка на Ubuntu не проверялась в среде агента (стенд проверен на Manjaro); URL и имена пакетов — по документации kind, Kubernetes и Helm.

Версия kubectl должна отличаться от версии кластера не больше чем на одну минорную (1.35–1.37 для кластера 1.36) — это правило version skew (10-2).

**Лимиты inotify.** Каждый узел kind запускает systemd и kubelet, которые съедают inotify-экземпляры. При дефолтном `fs.inotify.max_user_instances = 128` (так на многих Ubuntu) кластер из 4 узлов падает с `too many open files` в логах kubelet или kube-proxy. На машине автора — 1024, ошибок нет. Поднимите заранее:

```bash
sysctl fs.inotify.max_user_instances fs.inotify.max_user_watches
sudo tee /etc/sysctl.d/99-kind.conf <<'EOF'
fs.inotify.max_user_instances = 512
fs.inotify.max_user_watches = 524288
EOF
sudo sysctl --system
```

## 3. Запуск 🟢

```bash
cd ~/ai/runbooks            # корень репозитория курсов
bash kubernetes/lab/lab-up.sh
```

Что делает скрипт (подробности — комментарии в самом `lab/lab-up.sh`):

1. Запускает реестр `kind-registry` на `127.0.0.1:5001` (том `kind-registry-data`).
2. Создаёт кластер `lab` по конфигу `~/lab/k8s/kind.yaml`: 1 control-plane + 3 worker, проброс `127.0.0.1:8088 → :30080` узла control-plane, containerd ищет настройки реестров в `/etc/containerd/certs.d`.
3. В каждом узле пишет `/etc/containerd/certs.d/localhost:5001/hosts.toml` → `http://kind-registry:5000`: внутри узла `localhost:5001` — это не хост, а сам узел, без этой настройки pull падает с `connection refused`.
4. Ставит metrics-server с флагом `--kubelet-insecure-tls` (у kubelet в kind самоподписанный сертификат).
5. Ставит Envoy Gateway Helm-чартом, создаёт `GatewayClass eg` и `Gateway lab` (порт 80, маршруты из любых namespace). Сервис Envoy — NodePort 30080 с `externalTrafficPolicy: Cluster`.

Проверено (конец вывода первого запуска, 2 мин 9 с):

```
== Envoy Gateway 1.9.2 (+ CRD Gateway API)
gateway.gateway.networking.k8s.io/lab condition met

== готово
NAME                STATUS   ROLES           AGE    VERSION
lab-control-plane   Ready    control-plane   2m2s   v1.36.1
lab-worker          Ready    <none>          108s   v1.36.1
lab-worker2         Ready    <none>          108s   v1.36.1
lab-worker3         Ready    <none>          108s   v1.36.1

Контекст: kind-lab · реестр: localhost:5001 · вход: http://<имя>.localhost:8088 (Gateway lab)
```

Скрипт переключает текущий контекст kubectl на `kind-lab`. Если у вас есть рабочие кластеры — проверяйте контекст перед каждой опасной командой (`kubectl config current-context`) или держите стенд в отдельном файле: `export KUBECONFIG=~/lab/k8s/kubeconfig` перед запуском скрипта.

## 4. Сквозной сценарий: orders-api 2.0 и PostgreSQL 🟢

Сервис из курса `cicd`, доработанный под Kubernetes:

| Путь | Что отвечает | Где используется |
|---|---|---|
| `/health` | 200, пока процесс жив | liveness (02-5) |
| `/ready` | 200, если старт закончен и БД отвечает; 503 после SIGTERM | readiness (02-5), Service и endpoints (03-2) |
| `/api/orders` | заказы из PostgreSQL (без `DATABASE_URL` — из памяти) + имя пода | сквозной запрос |
| `/version` | версия и имя пода | rollout, canary (02-2, 03-4) |
| `/config` | переменная `FEATURE_DISCOUNT` и содержимое `/etc/orders/config.json` | ConfigMap (04-1) |
| `/work?ms=N` | сжечь N мс CPU | троттлинг, HPA (05-1, 05-3) |

Переменные: `DATABASE_URL` (из Secret), `STARTUP_DELAY` (сколько секунд не открывать порт — для startupProbe), `SHUTDOWN_DELAY` (сколько ещё обслуживать запросы после SIGTERM — для graceful shutdown).

### 4.1. Код и образ

```bash
mkdir -p ~/lab/k8s/orders-api/{app,k8s} && cd ~/lab/k8s/orders-api
touch app/__init__.py

cat > app/main.py <<'E'
import json
import os
import signal
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

VERSION = os.environ.get("APP_VERSION", "dev")
DATABASE_URL = os.environ.get("DATABASE_URL")          # из Secret; без него — данные в памяти
CONFIG_FILE = os.environ.get("CONFIG_FILE", "/etc/orders/config.json")   # из ConfigMap (том)
STARTUP_DELAY = float(os.environ.get("STARTUP_DELAY", "0"))   # имитация медленного старта (02-5)
SHUTDOWN_DELAY = float(os.environ.get("SHUTDOWN_DELAY", "0")) # сколько ещё обслуживать после SIGTERM
STATIC_ORDERS = [{"id": 1, "item": "book", "qty": 2}, {"id": 2, "item": "pen", "qty": 5}]
state = {"ready": False, "terminating": False}


def db():
    import psycopg
    return psycopg.connect(DATABASE_URL, connect_timeout=2)


def init_db():
    with db() as conn:
        conn.execute("CREATE TABLE IF NOT EXISTS orders (id serial PRIMARY KEY, item text NOT NULL, qty int NOT NULL)")
        if conn.execute("SELECT count(*) FROM orders").fetchone()[0] == 0:
            conn.cursor().executemany("INSERT INTO orders (item, qty) VALUES (%s, %s)", [("book", 2), ("pen", 5)])


def get_orders():
    if not DATABASE_URL:
        return STATIC_ORDERS
    with db() as conn:
        rows = conn.execute("SELECT id, item, qty FROM orders ORDER BY id").fetchall()
    return [{"id": r[0], "item": r[1], "qty": r[2]} for r in rows]


def read_config():
    try:
        with open(CONFIG_FILE) as f:
            return json.load(f)
    except (OSError, ValueError) as e:
        return {"error": str(e)}


def burn(ms):                       # ~ms миллисекунд чистого CPU (05-1, 05-3)
    end = time.thread_time() + ms / 1000
    while time.thread_time() < end:
        pass


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        url = urlparse(self.path)
        try:
            if url.path == "/health":                 # liveness: процесс жив и отвечает
                self._send(200, {"status": "ok"})
            elif url.path == "/ready":                # readiness: готов принимать трафик
                if state["terminating"] or not state["ready"]:
                    self._send(503, {"ready": False, "terminating": state["terminating"]})
                else:
                    if DATABASE_URL:
                        with db() as conn:
                            conn.execute("SELECT 1")
                    self._send(200, {"ready": True})
            elif url.path == "/version":
                self._send(200, {"version": VERSION, "pod": os.environ.get("HOSTNAME", "")})
            elif url.path == "/api/orders":
                orders = get_orders()
                self._send(200, {"orders": orders, "total_items": sum(o["qty"] for o in orders),
                                 "pod": os.environ.get("HOSTNAME", "")})
            elif url.path == "/config":
                self._send(200, {"env_FEATURE_DISCOUNT": os.environ.get("FEATURE_DISCOUNT"), "file": read_config()})
            elif url.path == "/work":
                ms = int(parse_qs(url.query).get("ms", ["100"])[0])
                t = time.perf_counter()
                burn(ms)
                self._send(200, {"cpu_ms": ms, "wall_ms": round((time.perf_counter() - t) * 1000)})
            else:
                self._send(404, {"error": "not found"})
        except Exception as e:                        # БД недоступна и т. п.
            self._send(503, {"error": type(e).__name__, "detail": str(e)[:200]})

    def log_message(self, fmt, *args):
        print(f"{self.address_string()} {fmt % args}", flush=True)


def startup():
    if DATABASE_URL:
        for _ in range(30):
            try:
                init_db()
                break
            except Exception as e:
                print(f"db not ready: {type(e).__name__}: {e}", flush=True)
                time.sleep(2)
        else:
            print("db unavailable, exit", flush=True)
            os._exit(1)
    state["ready"] = True
    print("ready", flush=True)


def main():
    port = int(os.environ.get("PORT", "8000"))
    time.sleep(STARTUP_DELAY)                     # пока «стартуем», порт закрыт
    server = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    server.daemon_threads = True

    def on_sigterm(signum, frame):
        print(f"SIGTERM: not ready, serving {SHUTDOWN_DELAY:g}s more", flush=True)
        state["terminating"] = True
        threading.Thread(target=lambda: (time.sleep(SHUTDOWN_DELAY), server.shutdown()), daemon=True).start()

    signal.signal(signal.SIGTERM, on_sigterm)
    print(f"orders-api {VERSION} listening on :{port} db={'yes' if DATABASE_URL else 'no'}", flush=True)
    threading.Thread(target=startup, daemon=True).start()
    server.serve_forever()
    server.server_close()
    print("bye", flush=True)


if __name__ == "__main__":
    main()
E

echo 'psycopg[binary]==3.2.10' > requirements.txt

cat > Dockerfile <<'E'
FROM python:3.12-slim
WORKDIR /srv
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app/ app/
USER 10001
ARG APP_VERSION=dev
ENV APP_VERSION=$APP_VERSION PORT=8000 PYTHONUNBUFFERED=1
EXPOSE 8000
CMD ["python", "-m", "app.main"]
E

docker build -t localhost:5001/orders-api:2.0 --build-arg APP_VERSION=2.0 .
docker push localhost:5001/orders-api:2.0
curl -s http://127.0.0.1:5001/v2/orders-api/tags/list
```

Проверено (push):

```
2.0: digest: sha256:ad4f8fd2cabaef73e735d9a623a3499270fd5f3a5d7f640719bfd0982e772465 size: 1991
```

Ответ реестра — `{"name":"orders-api","tags":["2.0"]}` (проверено тем же запросом из сети kind к `kind-registry:5000`: песочница агента не видит `127.0.0.1` хоста, §5). Узлы тянут образ из реестра — проверено `docker exec lab-worker crictl pull localhost:5001/orders-api:2.0`.

Дайджест у вас будет другим: он зависит от времени сборки и слоёв базового образа.

### 4.2. PostgreSQL

```bash
cd ~/lab/k8s/orders-api/k8s
cat > postgres.yaml <<'E'
apiVersion: v1
kind: Secret
metadata: {name: postgres, namespace: orders}
type: Opaque
stringData:
  POSTGRES_USER: orders
  POSTGRES_PASSWORD: orders-lab-pass        # учебный пароль стенда; в проде — не в Git (04-1, 08-2)
  POSTGRES_DB: orders
  DATABASE_URL: postgresql://orders:orders-lab-pass@postgres:5432/orders
---
apiVersion: v1
kind: Service
metadata: {name: postgres, namespace: orders}
spec:
  clusterIP: None                            # headless: DNS-имена postgres-0.postgres (02-3)
  selector: {app: postgres}
  ports: [{name: pg, port: 5432}]
---
apiVersion: apps/v1
kind: StatefulSet
metadata: {name: postgres, namespace: orders}
spec:
  serviceName: postgres
  replicas: 1
  selector: {matchLabels: {app: postgres}}
  template:
    metadata: {labels: {app: postgres}}
    spec:
      containers:
      - name: postgres
        image: postgres:17.6-alpine
        envFrom: [{secretRef: {name: postgres}}]
        env: [{name: PGDATA, value: /var/lib/postgresql/data/pgdata}]
        ports: [{name: pg, containerPort: 5432}]
        readinessProbe:
          exec: {command: ["pg_isready", "-U", "orders", "-d", "orders"]}
          periodSeconds: 5
        resources:
          requests: {cpu: 100m, memory: 256Mi}
          limits:   {memory: 512Mi}
        volumeMounts: [{name: data, mountPath: /var/lib/postgresql/data}]
  volumeClaimTemplates:
  - metadata: {name: data}
    spec:
      accessModes: [ReadWriteOnce]
      resources: {requests: {storage: 1Gi}}
E

kubectl create namespace orders
kubectl apply -f postgres.yaml
kubectl -n orders rollout status sts/postgres --timeout=180s
```

Пароль лежит в манифесте открытым текстом — это учебный стенд. Как с секретами поступают по-настоящему — 04-1 и 08-2.

### 4.3. orders-api, Service и маршрут

```bash
cat > orders-api.yaml <<'E'
apiVersion: v1
kind: ConfigMap
metadata: {name: orders-config, namespace: orders}
data:
  config.json: |
    {"discount_percent": 0, "banner": "welcome"}
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: orders-api, namespace: orders}
spec:
  replicas: 2
  selector: {matchLabels: {app: orders-api}}
  template:
    metadata: {labels: {app: orders-api}}
    spec:
      containers:
      - name: api
        image: localhost:5001/orders-api:2.0
        ports: [{name: http, containerPort: 8000}]
        env:
        - name: DATABASE_URL
          valueFrom: {secretKeyRef: {name: postgres, key: DATABASE_URL}}
        - {name: SHUTDOWN_DELAY, value: "5"}
        readinessProbe: {httpGet: {path: /ready, port: http}, periodSeconds: 2}
        livenessProbe:  {httpGet: {path: /health, port: http}, periodSeconds: 10}
        resources:
          requests: {cpu: 100m, memory: 64Mi}
          limits:   {memory: 256Mi}
        volumeMounts: [{name: config, mountPath: /etc/orders}]
      volumes:
      - name: config
        configMap: {name: orders-config}
---
apiVersion: v1
kind: Service
metadata: {name: orders-api, namespace: orders}
spec:
  selector: {app: orders-api}
  ports: [{name: http, port: 80, targetPort: http}]
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: orders-api, namespace: orders}
spec:
  parentRefs: [{name: lab, namespace: envoy-gateway-system}]
  hostnames: ["orders.localhost"]
  rules:
  - backendRefs: [{name: orders-api, port: 80}]
E

kubectl apply -f orders-api.yaml
kubectl -n orders rollout status deploy/orders-api --timeout=120s
kubectl -n orders get pods,svc,pvc,httproute
```

Проверено:

```
NAME                              READY   STATUS    RESTARTS   AGE
pod/orders-api-6d54d4c46b-fvq75   1/1     Running   0          5m18s
pod/orders-api-6d54d4c46b-ksf5v   1/1     Running   0          5m18s
pod/postgres-0                    1/1     Running   0          8m8s

NAME                 TYPE        CLUSTER-IP     EXTERNAL-IP   PORT(S)    AGE
service/orders-api   ClusterIP   10.96.100.97   <none>        80/TCP     7m36s
service/postgres     ClusterIP   None           <none>        5432/TCP   8m8s

NAME                                    STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   ...
persistentvolumeclaim/data-postgres-0   Bound    pvc-4c926342-30ed-4448-80b3-abbde6d0c56f   1Gi        RWO            standard       ...

NAME                                             HOSTNAMES              AGE
httproute.gateway.networking.k8s.io/orders-api   ["orders.localhost"]   7m36s
```

### 4.4. Сквозной запрос

```bash
curl -s http://orders.localhost:8088/api/orders
```

curl сам резолвит любые имена `*.localhost` в `127.0.0.1`, правка `/etc/hosts` не нужна. Браузеры делают так же.

Ожидаемый результат:

```
{"orders": [{"id": 1, "item": "book", "qty": 2}, {"id": 2, "item": "pen", "qty": 5}], "total_items": 7, "pod": "orders-api-6d54d4c46b-fvq75"}
```

⚠️ С хоста в среде агента не проверено: песочница агента работает в своём сетевом namespace и не видит `127.0.0.1` хоста. Тот же путь (NodePort 30080 узла control-plane → Envoy → orders-api → PostgreSQL) проверен из сети kind:

```bash
docker exec lab-worker curl -s -H 'Host: orders.localhost' http://lab-control-plane:30080/api/orders
```

Проверено — ответ выше, слово в слово, с данными из PostgreSQL. Повторите запрос несколько раз: поле `pod` меняется — Service распределяет запросы между двумя репликами.

## 5. Как в курсе выполняются команды 🟢

- Все команды — с хоста: `kubectl` с контекстом `kind-lab`, `docker exec lab-<узел> …` — когда нужно посмотреть на узел изнутри.
- Каждая лаба работает в своём namespace `lab-NN-M` и удаляет его в уборке. Namespace `orders` (сквозной сценарий) лабы не удаляют; если часть его меняет — в конце возвращает исходное состояние (`kubectl apply -f ~/lab/k8s/orders-api/k8s/`).
- В выводах «проверено» имена подов, IP, UID и миллисекунды — с прогона автора. У вас будут другие, сверяйте структуру и порядок величин.
- Агент выполнял `kubectl` из служебного контейнера в docker-сети kind (песочница не видит `127.0.0.1` хоста); у читателя те же команды работают с хоста. Отличаются только адреса в ошибках подключения: у агента `lab-control-plane:6443`, у вас `127.0.0.1:<порт>`.

## 6. Если не поднялось 🟡

| Симптом | Причина | Что делать |
|---|---|---|
| `Bind for 0.0.0.0:8080 failed: port is already allocated` при `kind create cluster` | порт занят другим контейнером (у автора — `searxng` на 8080; поэтому стенд на 8088) | `docker ps --format '{{.Names}} {{.Ports}}'`; поменять `hostPort` в `lab-up.sh` и в командах курса |
| `error getting credentials - err: exec: "docker-credential-desktop"` | в `~/.docker/config.json` прописан `credsStore` от Docker Desktop | убрать `credsStore` или запускать с `DOCKER_CONFIG=$(mktemp -d)` |
| `too many open files` в логах kubelet/kube-proxy, узлы NotReady | мало `fs.inotify.max_user_instances` | §2, затем `bash kubernetes/lab/lab-down.sh --purge && bash kubernetes/lab/lab-up.sh` |
| под в `ImagePullBackOff`, в событиях `dial tcp [::1]:5001: connect: connection refused` | в узле нет (или пустой) `/etc/containerd/certs.d/localhost:5001/hosts.toml`: `localhost` внутри узла — сам узел (проверено — так было, пока в скрипте не хватало `docker exec -i`) | перезапустить `lab-up.sh`; проверить `docker exec lab-worker cat /etc/containerd/certs.d/localhost:5001/hosts.toml` |
| запрос к `:8088` висит до таймаута, а из пода через Service Envoy работает | `externalTrafficPolicy: Local` у Service Envoy: трафик NodePort на узел без пода Envoy kube-proxy отбрасывает (проверено: правило `has no local endpoints … DROP`) | в скрипте стоит `Cluster` через `EnvoyProxy`; если меняли — вернуть (разбор в 03-2) |
| `curl … :8088` → `Connection refused` | Gateway не создан или не Programmed | `kubectl -n envoy-gateway-system get gateway lab`; повторить `lab-up.sh` |
| orders-api `0/1 Running`, в логах `db not ready: …` | PostgreSQL не готов или неверный `DATABASE_URL` | `kubectl -n orders get pods`, `kubectl -n orders logs deploy/orders-api`; приложение пробует 60 с и выходит |
| после перезагрузки машины `kubectl` → `connection refused` | узлы kind остановлены | `bash kubernetes/lab/lab-up.sh` — запустит узлы и дождётся apiserver |
| `kubectl` ходит не в тот кластер | текущий контекст не `kind-lab` | `kubectl config use-context kind-lab` |

## 7. Включить и выключить 🟢

Стенд не нужно держать запущенным постоянно:

```bash
bash kubernetes/lab/lab-down.sh     # docker stop узлов и реестра; etcd, PVC, образы — сохраняются
bash kubernetes/lab/lab-up.sh       # docker start, ожидание apiserver, проверка дополнений
```

Проверено: в таблицу `orders` добавлена строка `lamp`, `lab-down.sh` → `lab-up.sh` за 51 с, поды перезапустились (`RESTARTS 1`), ответ:

```
{"orders": [{"id": 1, "item": "book", "qty": 2}, {"id": 2, "item": "pen", "qty": 5}, {"id": 3, "item": "lamp", "qty": 1}], "total_items": 8, "pod": "orders-api-6d54d4c46b-ksf5v"}
```

## 8. Уборка

```bash
bash kubernetes/lab/lab-down.sh --purge        # кластер, реестр, том с образами, ~/lab/k8s (включая исходники orders-api)
docker image rm kindest/node:v1.36.1 registry:2.8.3   # по желанию, ~1 ГБ
```

`--purge` удаляет и `~/lab/k8s/orders-api` — если вы правили код, сохраните его заранее.

---

## Чеклист

- [ ] `bash kubernetes/lab/lab-up.sh` закончился строкой `== готово`, все 4 узла `Ready`.
- [ ] `kubectl top nodes` показывает цифры (metrics-server работает).
- [ ] Образ `localhost:5001/orders-api:2.0` в реестре, поды orders-api и postgres `Running`, `1/1`.
- [ ] `curl http://orders.localhost:8088/api/orders` возвращает заказы, поле `pod` меняется между запросами.
- [ ] Знаю, как зайти на узел (`docker exec -it lab-worker bash`) и где на нём kubelet и containerd.
- [ ] Умею выключить и включить стенд без потери данных.

→ Следующая часть: **00-2. Инструменты** — kubectl по-взрослому (контексты, `-o jsonpath`/`custom-columns`, `explain`, `-v=8`, `--dry-run=server`, `diff`), `kubectl debug`, k9s, stern, kubectx/kubens, krew; что чем смотреть на узле — `crictl`, `journalctl`, `etcdctl`.
