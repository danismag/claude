# 03-2. Пробная лабораторная работа: Service без эндпоинтов

Образец формата лабораторной работы; при производстве войдёт в часть 03-2 как Лабораторная работа 1.

Модуль 3 «Сеть», часть 2 · ~1 ч · Нужно: стенд 00-1, образ `python:3.12-slim` · Опирается на: 00-1 (стенд), 02-5 (readiness).

---

## Лабораторные работы

В образце одна работа: она воспроизводит две поломки Service с одинаковым симптомом и учит их различать.

### Лабораторная работа 1. Service без эндпоинтов: селектор и порт

**Цель.** Научиться за пять минут находить, почему **Service** (служба, постоянный адрес для группы подов) не отвечает. Вы воспроизведёте две поломки с одинаковым симптомом `Connection refused` и отличите их по **EndpointSlice**.

**Что понадобится.**

- Стенд из 00-1: кластер kind с контекстом `kind-lab`, `kube-proxy` в режиме iptables.
- Образ `python:3.12-slim` (узлы скачают его при первом запуске пода).
- Права на создание namespace `lab-03-2`.
- Около 10 минут на запуск подов и 40 минут на разбор результатов.

**Схема опыта.** Клиентский под ходит к Service по имени `orders`, а смотреть нужно на звено между Service и подами: именно там пропадают адреса.

```
client (под) ──► DNS: orders ──► ClusterIP:80 ──► правила kube-proxy на узле
                                                        │
                                  EndpointSlice orders ◄┘  ← сюда смотрим: пуст или нет
                                        │ адреса: IP подов + порт
                                        ▼
                          поды app=orders (2 шт., слушают :8000)

Поломка 1: selector app=order не совпадает с метками подов → список адресов пуст.
Поломка 2: targetPort 8080 → адреса есть, но на порту 8080 никто не слушает.
```

Схема показывает путь пакета: первая поломка рвёт его на EndpointSlice, а вторая — уже в самом поде.

**Риски.** Работа меняет только кластер стенда и одну настройку на хосте.

- **Что меняется:** в кластере kind — namespace `lab-03-2` с подами и Service; на хосте — namespace по умолчанию у контекста `kind-lab` в `~/.kube/config`.
- **Надолго ли:** до уборки; уборка удаляет namespace и возвращает `default`.
- **Безопасность:** привилегий не нужно; `docker exec … iptables-save` только читает правила узла.
- **Влияние на систему:** другие контексты kubectl и рабочие кластеры не затрагиваются.
- **Откат:** блок «Уборка» в конце работы.

#### Шаг 1. Создать namespace

Создаём отдельный **namespace** (пространство имён, логическая папка объектов кластера) и делаем его текущим, чтобы все объекты работы лежали в одном месте и удалялись одной командой.

```bash
kubectl config use-context kind-lab
kubectl create ns lab-03-2
kubectl config set-context --current --namespace=lab-03-2
```

Разбор команд:

| Часть команды | Значение |
|---|---|
| `use-context kind-lab` | работать с кластером стенда, а не с рабочим |
| `create ns lab-03-2` | создать namespace с именем части |
| `set-context --current` | изменить текущий контекст kubectl |
| `--namespace=lab-03-2` | подставлять этот namespace, если флаг `-n` не указан |

Результат:

```
Switched to context "kind-lab".
namespace/lab-03-2 created
Context "kind-lab" modified.
```

Разбор вывода:

1. Контекст переключён на стенд, поэтому команды не попадут в рабочий кластер.
2. Namespace `lab-03-2` создан и пока пуст.
3. Контекст изменён: дальше команды без `-n` попадают в `lab-03-2`.

#### Шаг 2. Запустить поды и Service с опечаткой в селекторе

Создаём Deployment из двух подов с меткой `app=orders` и Service, который ищет поды по метке `app=order`, — одна буква расходится намеренно. **Метка** (label) — это пара «ключ=значение», которую вешают на объект кластера. **Селектор** (selector) — условие, по которому Service выбирает поды по их меткам.

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
```

Разбор ключей манифеста:

| Часть манифеста | Значение |
|---|---|
| `replicas: 2` | два пода |
| `command: [python, -m, http.server, 8000]` | веб-сервер на порту 8000 |
| `ports: [{name: http, ...}]` | порту 8000 дано имя `http` |
| `readinessProbe` | проверка готовности: GET `/` каждые 2 с |
| `selector: {app: order}` | Service ищет метку `app=order`, а её нет |
| `port: 80` | порт Service |
| `targetPort: http` | порт пода — по имени `http` |

Результат:

```
deployment.apps/orders created
service/orders created
Waiting for deployment "orders" rollout to finish: 0 of 2 updated replicas are available...
…
deployment "orders" successfully rolled out
```

Разбор вывода:

1. Deployment создан. Строки `Waiting for…` идут, пока узлы скачивают образ и поды проходят проверку, поэтому при повторном запуске их может не быть. Последняя строка значит, что оба пода запущены и прошли проверку готовности (**Ready** — под готов принимать трафик).
2. Service создан без ошибок: Kubernetes не проверяет, что селектор что-то выбирает.
3. Приложение здорово, поэтому проблема только в связи Service с подами.

#### Шаг 3. Найти пустой EndpointSlice

Первым делом при жалобе «Service не отвечает» проверяют **эндпоинты** (endpoints) — адреса подов, на которые Service отправляет трафик. Контроллер хранит их в объектах **EndpointSlice** (срез эндпоинтов): по умолчанию один объект вмещает до 100 адресов. Старый объект v1 Endpoints с теми же адресами устарел с версии 1.33, поэтому смотрим только EndpointSlice. Выводим Service, его EndpointSlice и две строки из описания Service.

```bash
kubectl get svc,endpointslice
kubectl describe svc orders | grep -E 'Selector|Endpoints'
```

Разбор команд:

| Часть команды | Значение |
|---|---|
| `get svc,endpointslice` | показать объекты двух видов за один вызов |
| `describe svc orders` | подробное описание Service |
| `grep -E '…'` | оставить строки `Selector` и `Endpoints` |

Результат:

```
NAME             TYPE        CLUSTER-IP     EXTERNAL-IP   PORT(S)   AGE
service/orders   ClusterIP   10.96.88.241   <none>        80/TCP    1s

NAME                                          ADDRESSTYPE   PORTS     ENDPOINTS   AGE
endpointslice.discovery.k8s.io/orders-9vf5b   IPv4          <unset>   <unset>     1s
Selector:                 app=order
Endpoints:
```

Разбор вывода:

1. У Service есть **ClusterIP** (виртуальный адрес внутри кластера) `10.96.88.241`: его выдают всегда, даже если подов нет.
2. В EndpointSlice `orders-9vf5b` колонки `PORTS` и `ENDPOINTS` равны `<unset>`: адресов нет.
3. Строка `Selector` показывает `app=order`, а строка `Endpoints` пуста.
4. Вывод: селектор ничего не выбрал, и это видно, если сравнить его с метками подов командой `kubectl get pods --show-labels`.

#### Шаг 4. Увидеть симптом глазами клиента

Запускаем клиентский под и подключаемся из него к Service по имени. Функция `probe` пытается открыть TCP-соединение и печатает результат вместе со временем попытки. Не закрывайте текущее окно терминала, потому что функция понадобится в следующих шагах.

```bash
kubectl run client --image=python:3.12-slim --restart=Never --command -- sleep infinity
kubectl wait --for=condition=Ready pod/client
probe() {
  kubectl exec client -- python -c '
import socket, sys, time
t = time.time()
try:
    socket.create_connection((sys.argv[1], int(sys.argv[2])), timeout=5)
    print("connected")
except Exception as e:
    print(type(e).__name__, e)
print(f"{time.time()-t:.3f}s")' "$@"
}
probe orders 80
```

Разбор команд:

| Часть команды | Значение |
|---|---|
| `run client --restart=Never` | одиночный под, без Deployment |
| `--command -- sleep infinity` | держать под живым, ничего не делая |
| `wait --for=condition=Ready` | ждать готовности пода |
| `probe orders 80` | подключиться к имени `orders`, порт 80 |
| `python -c '…' "$@"` | аргументы функции попадают в `sys.argv[1]` и `sys.argv[2]` |
| `timeout=5` | ждать соединения не дольше 5 с |

Результат:

```
ConnectionRefusedError [Errno 111] Connection refused
0.020s
```

Разбор вывода:

1. Имя `orders` разрешилось в ClusterIP, поэтому ошибки DNS нет.
2. `Connection refused` — это активный отказ: на пакет ответили, а не промолчали.
3. Отказ пришёл за 0,02 с, а таймаут в 5 с означал бы потерянные пакеты (NetworkPolicy, маршрутизация, 03-6).
4. Мгновенный отказ при пустом EndpointSlice говорит, что это не проблема сети.

#### Шаг 5. Найти правило REJECT на узле

Отказ создаёт **kube-proxy** (компонент на каждом узле, который программирует правила пересылки для Service). Для Service без эндпоинтов он ставит правило **REJECT**: пакет отбрасывается, а отправителю возвращается ответ «порт недоступен». Узлы kind — это контейнеры Docker, поэтому правила узла смотрим командой `iptables-save` через `docker exec`; команда их только читает.

```bash
docker exec lab-worker iptables-save | grep 'lab-03-2/orders'
```

Разбор команды:

| Часть команды | Значение |
|---|---|
| `docker exec lab-worker` | выполнить команду внутри узла `lab-worker` |
| `iptables-save` | вывести все правила iptables |
| `grep 'lab-03-2/orders'` | оставить правила нашего Service |

Результат:

```
-A KUBE-SERVICES -d 10.96.88.241/32 -p tcp -m comment --comment "lab-03-2/orders has no endpoints" -m tcp --dport 80 -j REJECT --reject-with icmp-port-unreachable
```

Строка вывода длинная, но приведена целиком: так её печатает `iptables-save`.

Разбор вывода:

1. `-A KUBE-SERVICES` — правило в цепочке `KUBE-SERVICES` таблицы `filter`. Цепочка с тем же именем есть и в таблице `nat`, но правила отказа kube-proxy пишет в `filter`; `grep` скрывает заголовок таблицы.
2. `-d 10.96.88.241/32 … --dport 80` — условие: адрес и порт нашего Service.
3. Комментарий `has no endpoints` — причина отказа, которую kube-proxy пишет сам.
4. `-j REJECT --reject-with icmp-port-unreachable` — действие: отказ с ICMP-ответом «порт недоступен», поэтому клиент сразу видит `Connection refused`.

#### Шаг 6. Исправить селектор

Приводим селектор в соответствие меткам подов, а затем проверяем, что EndpointSlice заполнился и клиент получает ответ.

```bash
kubectl patch svc orders -p '{"spec":{"selector":{"app":"orders"}}}'
kubectl get endpointslice -l kubernetes.io/service-name=orders
kubectl exec client -- python -c \
  'import urllib.request as u; print(u.urlopen("http://orders", timeout=5).status)'
```

Разбор команд:

| Часть команды | Значение |
|---|---|
| `patch svc orders -p '{…}'` | точечно изменить поле селектора |
| `-l kubernetes.io/service-name=orders` | найти EndpointSlice этого Service по метке |
| `urlopen("http://orders")` | HTTP-запрос по имени Service, порт 80 |
| `.status` | вывести код ответа |

Результат:

```
service/orders patched
NAME           ADDRESSTYPE   PORTS   ENDPOINTS                AGE
orders-9vf5b   IPv4          8000    10.244.3.8,10.244.2.10   12s
200
```

Разбор вывода:

1. Service изменён, и контроллер EndpointSlice сразу пересчитал адреса.
2. Тот же объект `orders-9vf5b` теперь содержит два адреса — IP двух подов.
3. В колонке `PORTS` стоит `8000`: имя `http` из `targetPort` превратилось в номер порта контейнера.
4. Код `200` значит, что запрос прошёл через ClusterIP до пода.

#### Шаг 7. Сломать targetPort

Теперь подставляем неверный **targetPort** — порт пода, на который Service пересылает трафик. Селектор верный и поды готовы, но на порту 8080 никто не слушает.

```bash
kubectl patch svc orders --type=json \
  -p '[{"op":"replace","path":"/spec/ports/0/targetPort","value":8080}]'
kubectl get endpointslice -l kubernetes.io/service-name=orders
probe orders 80
```

Разбор команд:

| Часть команды | Значение |
|---|---|
| `--type=json` | патч в формате JSON Patch: операции над путями |
| `"op":"replace"` | заменить существующее значение |
| `"path":"/spec/ports/0/targetPort"` | поле `targetPort` у первого порта |
| `"value":8080` | новое значение, число вместо имени |

Результат:

```
service/orders patched
NAME           ADDRESSTYPE   PORTS   ENDPOINTS                AGE
orders-9vf5b   IPv4          8080    10.244.2.10,10.244.3.8   15s
ConnectionRefusedError [Errno 111] Connection refused
…
```

Разбор вывода:

1. Адреса в EndpointSlice на месте, а порт изменился на `8080`.
2. Симптом прежний — `Connection refused` со временем ответа порядка миллисекунд (последняя строка), но причина другая.
3. Пакет дошёл до пода, и отказ послало ядро пода: на порту 8080 нет процесса, поэтому ядро ответило TCP RST, а не ICMP.
4. Различие читается по EndpointSlice: пусто — ищите селектор; адреса есть, но не готовы — ищите readiness; адреса готовы, порт чужой — ищите `targetPort`.

#### Шаг 8. Задать targetPort по имени

Возвращаем `targetPort: http`, потому что имя порта переживает смену номера в образе, а число — нет.

```bash
kubectl patch svc orders --type=json \
  -p '[{"op":"replace","path":"/spec/ports/0/targetPort","value":"http"}]'
kubectl get endpointslice -l kubernetes.io/service-name=orders
kubectl exec client -- python -c \
  'import urllib.request as u; print(u.urlopen("http://orders", timeout=5).status)'
```

Разбор команд:

| Часть команды | Значение |
|---|---|
| `"value":"http"` | строка в кавычках: имя порта, а не номер |
| `get endpointslice -l …` | проверить порт в EndpointSlice |
| `urlopen("http://orders")` | проверить ответ через Service |

Результат:

```
service/orders patched
NAME           ADDRESSTYPE   PORTS   ENDPOINTS                AGE
orders-9vf5b   IPv4          8000    10.244.2.10,10.244.3.8   30s
200
```

Разбор вывода:

1. Имя `http` снова разрешено в номер 8000 по описанию порта в поде.
2. Адреса те же: правка Service не трогает поды, поэтому они не перезапускались.
3. Ответ `200` подтверждает, что Service снова работает.

#### Итог

Что вы узнали:

| Что узнали | Как проверить |
|---|---|
| Service без эндпоинтов отвечает мгновенным отказом | `probe orders 80`, время около 0,02 с |
| Причина отказа — правило REJECT в kube-proxy | `iptables-save` на узле |
| Пустой EndpointSlice значит: селектор не совпал | `kubectl get endpointslice -l …` |
| Неготовые поды видны в EndpointSlice с `ready: false` | `kubectl describe endpointslice -l …` |
| Адреса есть, отказ есть: неверный `targetPort` | колонка `PORTS` в EndpointSlice |
| Имя порта надёжнее числа | `targetPort: http` |

#### Уборка

Удаляем namespace вместе со всем содержимым и возвращаем namespace по умолчанию. Хост и узлы не менялись, поэтому больше чистить нечего.

```bash
kubectl config set-context --current --namespace=default
kubectl delete ns lab-03-2
unset -f probe
kubectl get ns lab-03-2
```

Результат:

```
Context "kind-lab" modified.
namespace "lab-03-2" deleted
Error from server (NotFound): namespaces "lab-03-2" not found
```

Разбор вывода: последняя строка подтверждает, что namespace удалён, а с ним Deployment, Service, EndpointSlice и клиентский под. Удаление может занять около 30 с, потому что kubelet ждёт конца периода остановки (по умолчанию 30 с). Процессы `sleep` и `python` работают в контейнерах как PID 1 и не обрабатывают SIGTERM, поэтому сами не завершаются.

#### Вопросы для самопроверки

1. Service создан, клиент получает отказ за 20 мс. Какую команду выполните первой и что она покажет?

<details><summary>Ответ</summary>

`kubectl get endpointslice -l kubernetes.io/service-name=<имя>`. Пустые `PORTS` и `ENDPOINTS` означают, что селектор не выбрал ни одного пода. Если адреса есть, проверьте их готовность (`kubectl describe endpointslice`, поле `Ready`), а затем `targetPort`.

</details>

2. Почему при пустом EndpointSlice клиент получает отказ, а не таймаут?

<details><summary>Ответ</summary>

kube-proxy ставит для такого Service правило REJECT с ICMP port unreachable, поэтому пакет не теряется, а отвергается сразу. Таймаут говорит о другом: пакеты молча отбрасываются (NetworkPolicy, маршруты, правило DROP).

</details>

3. Под Ready, селектор верный, адреса в EndpointSlice есть, а отказ остался. Где искать причину?

<details><summary>Ответ</summary>

В несовпадении порта: `targetPort` Service указывает на порт, где процесс не слушает. Сравните колонку `PORTS` в EndpointSlice с портом, который открывает приложение. Прямой запрос на IP пода и порт приложения подтвердит, что под отвечает.

</details>

4. Почему `targetPort` лучше задавать именем?

<details><summary>Ответ</summary>

Имя ссылается на порт в описании контейнера (`ports: [{name: http, …}]`). Если номер порта в образе изменится, достаточно поправить Deployment, а Service менять не нужно. Число приходится править в двух местах, и одно из них легко забыть.

</details>

5. Что произойдёт, если селектор верный, но все поды не проходят readiness?

<details><summary>Ответ</summary>

Адреса подов останутся в EndpointSlice, но с условием `ready: false`, и колонка `ENDPOINTS` в `kubectl get endpointslice` их всё равно покажет. Готовых адресов нет, поэтому kube-proxy поставит то же правило REJECT, и симптом совпадёт с опечаткой в селекторе. Отличие видно в `kubectl describe endpointslice` (`Ready: false`) и в `kubectl get pods`: в колонке `READY` будет `0/1`.

</details>
