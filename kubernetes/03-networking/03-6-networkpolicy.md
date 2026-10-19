# 03-6. NetworkPolicy

> Модуль 03 «Сеть» · часть 6 из 6 · ~1,5 ч чтения + ~1 ч лабы · Нужно: стенд 00-1 (контекст `kind-lab`, kindnet, Envoy Gateway, namespace `orders`), образы `localhost:5001/orders-api:2.0` и `python:3.12-slim`, доступ к узлам через `docker exec` · Опирается на: 03-1 (сеть подов и CNI), 03-2 (Service), 03-3 (DNS), 03-4 (Gateway API)

## Где мы на карте

Эта часть закрывает модуль 03: до неё вы узнали, как поды находят друг друга (03-1…03-3) и как трафик входит в кластер (03-4). Здесь трафик ограничивают. Она опирается на сеть подов из 03-1, потому что политики исполняет тот же **CNI** (Container Network Interface, подключаемый модуль сети), что выдаёт подам адреса. Из 03-2 нужно помнить, что Service — только виртуальный адрес, а из 03-3 — что имя сначала превращается в адрес через CoreDNS. Оба факта объясняют самые частые поломки политик.

Следующий модуль, 04, переходит от сети к данным: конфигурации, Secret и хранилищу. Права доступа к API (06-1) и безопасность подов (06-2) закрывают другие стороны той же защиты, а политики из этой части ограничивают только сетевые соединения.

```
Gateway API (03-4)     снаружи → Envoy → поды       вход в кластер
        │
Service / DNS          03-2, 03-3: имя → адрес      поиск пода
        │
NetworkPolicy          03-6 (эта часть)             кому разрешено соединиться
        │
CNI: kindnet           03-1: правила на узле        исполняет политики
```

Схема 1. Политика стоит над CNI: объекты хранит API, а пакеты пропускает или отбрасывает CNI на узле.

---

## 1. Какую задачу решает NetworkPolicy

NetworkPolicy ограничивает, какие поды могут соединяться с какими. Без неё кластер открыт целиком, и этим объясняется почти всё остальное в части.

### Открытая сеть по умолчанию

В Kubernetes любой под может открыть соединение к любому поду в любом namespace, включая базу данных. Так задумана плоская сеть из 03-1: каждый под получает адрес, и маршрут к нему есть у всех. Если взломан один под, из него видна вся сеть кластера.

**NetworkPolicy** (сетевая политика) — объект API в группе `networking.k8s.io/v1`, который перечисляет разрешённые соединения для выбранных подов. Политика описывает намерение, а пакеты фильтрует CNI на узле.

### Кто исполняет политику

API принимает NetworkPolicy всегда, но действует она только тогда, когда CNI её поддерживает. Если CNI политик не знает, объекты создаются и молча игнорируются: все соединения остаются разрешёнными.

Стенд ставит kindnet, и он поддерживает NetworkPolicy: на узлах видна таблица `inet kindnet-network-policies` в nftables (§2). Простой Flannel без дополнений политик не исполняет; Calico, Cilium и Antrea исполняют. Поэтому проверка политики всегда состоит в попытке запрещённого соединения, а не в команде `kubectl get netpol`.

### Чего политика не умеет

Стандартная политика работает только на уровнях 3 и 4: адреса, метки, порты и протоколы TCP, UDP, SCTP. Она не различает HTTP-пути и методы, не знает DNS-имён, не пишет лог отброшенных пакетов и не содержит явного запрета. Политика живёт в одном namespace, а кластерных политик в стандарте нет (§3).

Расширения CNI закрывают часть пробелов: Calico и Cilium дают правила по DNS-именам, L7-правила и лог. Эти возможности зависят от CNI, поэтому манифесты с ними не переносятся между кластерами. Модель, ограничения стандарта и расширения подробно разобраны в курсе `networks` (08-6).

---

## 2. Как устроена политика

Политика состоит из трёх частей: выбор подов, направления и правила. Разберём их по порядку, а затем посмотрим, как правила превращаются в пакетные фильтры на узле.

### Выбор подов и изоляция

Поле `spec.podSelector` выбирает поды политики по меткам, а `policyTypes` называет направления: `Ingress` (входящие соединения) и `Egress` (исходящие). Под, который выбрала хотя бы одна политика данного направления, становится **изолированным** (isolated) по этому направлению: разрешено только то, что перечислено в правилах. Поды без политики остаются открытыми.

Если `policyTypes` не указан, Kubernetes добавляет `Ingress` всегда, а `Egress` только при наличии секции `egress`. Пустой `podSelector: {}` выбирает все поды namespace.

```
          политика с podSelector: app=api, policyTypes: [Ingress]
                               │ выбирает
   client ──► нет ──┐          ▼
                    ├────►  под app=api   изолирован по Ingress: пускает только по правилам
   gateway ─► да ───┘                     Egress не изолирован: наружу открыто всё
```

Схема 2. Изоляция действует на выбранные поды и только по названному направлению; смотрите, что выбрано и какое направление названо.

### Политики складываются

Политики **аддитивны** (additive): они только разрешают, запретов в них нет. Если на под действует несколько политик, итоговое множество разрешённого равно объединению их правил, а порядка и приоритета нет. Поэтому ошибку «слишком открыто» чинят удалением правила, а «слишком закрыто» — добавлением новой политики.

### Источники и получатели

Каждое правило называет собеседников в поле `from` (для Ingress) или `to` (для Egress). Собеседника описывают три селектора:

- **podSelector** — поды по меткам; без `namespaceSelector` это поды того же namespace, что и политика.
- **namespaceSelector** — все поды namespace с подходящими метками; namespace по имени выбирают через метку `kubernetes.io/metadata.name`, которую Kubernetes ставит сам.
- **ipBlock** — диапазон адресов CIDR с исключениями `except`; нужен для внешних адресов, потому что адреса подов недолговечны.

Правило ограничивают портами: `port` (число или имя порта контейнера), `protocol` (по умолчанию TCP) и `endPort` для диапазона. Если `ports` не указан, разрешены все порты. Порт всегда относится к поду, а не к Service. Политика видит пакет после замены адреса в kube-proxy (03-2), поэтому «разрешить Service» нельзя, а разрешают поды за ним.

### AND и OR в одном правиле

Один дефис решает, будут ли два селектора условием «и» или «или». Если `namespaceSelector` и `podSelector` стоят в одном элементе списка, правило требует оба условия: под с меткой в выбранном namespace. Если они стоят в разных элементах, каждый работает сам по себе, и доступ открывается шире задуманного.

```
from:                                          from:
- namespaceSelector: {…other}                  - namespaceSelector: {…other}
  podSelector: {role: client}                  - podSelector: {role: client}
        │                                              │
   ОДИН элемент: AND                              ДВА элемента: OR
   клиент role=client из other                    все поды из other
                                                  ИЛИ role=client в своём namespace
```

Схема 3. Слева один элемент (AND), справа два (OR); различие в дефисе перед `podSelector`.

Лабораторная работа 2 измеряет оба варианта.

### Как kindnet исполняет правила

kindnet превращает политики в правила nftables на каждом узле, но решение принимает в пространстве пользователя. С kind 0.24 для этого в kindnet встроена библиотека kube-network-policies — эталонная реализация от SIG Network. **nftables** — фильтр пакетов ядра Linux. **conntrack** (connection tracking) — таблица ядра, где хранятся состояния соединений. **NFQUEUE** — очередь, через которую ядро отдаёт пакет программе в пространстве пользователя для решения.

Первый пакет нового соединения уходит в NFQUEUE (на стенде очередь номер 101), и агент kindnet решает по политикам: пропустить или отбросить. Пропущенное соединение получает **conntrack label** (метку соединения в таблице conntrack), и следующие пакеты проходят по ней без повторной проверки. Выводы два: запрет действует на новые соединения (§5), а правила узла можно прочитать командой `nft list table inet kindnet-network-policies`.

```
новое соединение ─► nftables: нет conntrack label ─► NFQUEUE ─► агент kindnet
                                                                  │ сверяет с политиками
                    пакет проходит ◄── conntrack label ◄── разрешено ┤
                    пакет отброшен молча ◄───────────────── запрещено ┘
```

Схема 4. Путь первого пакета: решение принимает агент, а остальные пакеты соединения идут по conntrack label.

---

## 3. Как управлять политиками

Политику пишут по шаблону: закрыть всё, потом открыть нужное. Здесь собраны типовые заготовки и порядок работы с ними.

### Default deny

Политика **default deny** (запрет по умолчанию) выбирает все поды namespace и не содержит правил, поэтому закрывает выбранное направление целиком. Она создаёт изоляцию, а остальные политики открывают в ней нужные потоки.

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: default-deny-ingress}
spec:
  podSelector: {}
  policyTypes: [Ingress]
```

Манифест выбирает все поды (`podSelector: {}`) и называет направление `Ingress` без единого правила `ingress`, значит, входящее не разрешено никому. Запретить исходящее можно тем же способом с `Egress`. Правило с пустым элементом, например `ingress: [{}]`, наоборот, разрешает всё.

### Egress требует DNS

Закрытый Egress ломает разрешение имён, потому что запрос к CoreDNS (03-3) тоже исходящее соединение. Приложение пытается получить адрес, не получает ответа и ждёт: на стенде это 20 секунд на каждое имя. Правило для DNS нужно добавлять в тот же момент, когда закрывают Egress.

```yaml
- to:
  - namespaceSelector:
      matchLabels: {kubernetes.io/metadata.name: kube-system}
    podSelector:
      matchLabels: {k8s-app: kube-dns}
  ports:
  - {port: 53, protocol: UDP}
  - {port: 53, protocol: TCP}
```

Это правило разрешает поды CoreDNS в `kube-system` на порту 53 по UDP и TCP. TCP нужен для больших ответов и повторов. Если кластер использует NodeLocal DNSCache (03-3), под обращается к адресу `169.254.20.10` на узле, и его разрешают через `ipBlock`.

### Набор политик для namespace

На практике namespace закрывают небольшим набором из четырёх политик. Лабораторная работа 5 применяет его к namespace `orders`.

| Политика | Кого выбирает | Что разрешает |
|---|---|---|
| default-deny | все поды | ничего: закрывает Ingress и Egress |
| allow-dns | все поды | Egress к CoreDNS, порт 53 |
| orders-api | поды orders-api | вход от Gateway; выход к PostgreSQL |
| postgres | поды PostgreSQL | вход только от orders-api |

Дополнения зависят от среды: Egress к внешним API через `ipBlock`, вход от Prometheus из namespace мониторинга, выход к Vault или брокеру. Облачный адрес служебного сервиса `169.254.169.254` закрывают через `except` в `ipBlock` (networks 08-6 §2).

### Кластерные политики

Стандартная NetworkPolicy не может задать правило для всех namespace сразу, поэтому SIG Network развивает кластерные политики. Первый вариант, AdminNetworkPolicy и BaselineAdminNetworkPolicy (v1alpha1), заменён объектом **ClusterNetworkPolicy** (v1alpha2, релиз network-policy-api v0.2.0 от 21 апреля 2026). Оба прежних объекта слиты в один, а уровень задаёт поле `tier` со значением `Admin` или `Baseline`. Действие `Allow` переименовано в `Accept`, поле `ports` заменено полем `protocols`, а лимит правил и пиров снижен со 100 до 25.

Уровень Admin вычисляется до обычных NetworkPolicy и может запретить или разрешить окончательно. Baseline вычисляется после них, как запасное правило для трафика, о котором NetworkPolicy не решила. Внутри уровня политики идут по полю `priority` от 0 до 1000, меньшее значение проверяется раньше. Действие `Pass` пропускает остальные правила уровня и передаёт решение дальше.

```
пакет ─► ClusterNetworkPolicy tier Admin ─► NetworkPolicy namespace ─► tier Baseline
              Accept / Deny: решение окончательное        Pass → дальше
```

Схема 5. Порядок проверки: сначала уровень Admin, потом политики namespace, потом уровень Baseline.

CRD этих объектов на стенде не установлены, а kindnet подключает только проверку стандартной NetworkPolicy, поэтому в лабораторных работах их нет. ClusterNetworkPolicy реализуют kube-network-policies (отдельно от kindnet), Calico и Kube-OVN; Cilium добавляет поддержку в версиях 1.19–1.20.

---

## 4. Как увидеть состояние политик

Состояние политики состоит из трёх вещей: что она выбирает, кого пускает и что делают правила узла. Первые две видны через API, третья — на узле.

### Что выбирает политика

Команда `kubectl get netpol` показывает имя и `podSelector` каждой политики. Команда `kubectl describe netpol <имя>` разворачивает её в читаемый текст: какие поды выбраны, какие направления закрыты, откуда и куда разрешено.

Чтобы понять, затрагивает ли политика конкретный под, сравните её селекторы с метками командой `kubectl get pod --show-labels` и для чужих namespace — `kubectl get ns --show-labels`. Большая часть ошибок находится на этом шаге: метка отличается на одну букву, а селектор тихо ничего не выбирает.

### Правила на узле

Узлы kind — контейнеры Docker, поэтому правила kindnet читает команда `docker exec`. Она только показывает таблицу и ничего не меняет. Таблица появляется, когда в кластере создана первая NetworkPolicy: до этого kindnet правил не ставит.

```bash
docker exec lab-worker nft list table inet kindnet-network-policies
```

В таблице видны цепочки с вызовом NFQUEUE и проверка conntrack label, по которой проходят установленные соединения (§2). У Calico аналог — правила iptables и `calicoctl`, у Cilium — `cilium monitor --type drop` и `hubble observe`.

### Проверка новым соединением

Политику проверяют запрещённым и разрешённым соединением, а не наличием объекта. Хорошая проверка — матрица «источник → цель → ожидание»: каждая строка запускается новым соединением и сравнивается с ожидаемым результатом. Лабораторная работа 1 строит такую матрицу функцией `check`.

---

## 5. Что ломается и как найти причину

Поломки политик подчиняются нескольким признакам. Знание признака сокращает поиск до одного-двух шагов.

### Таймаут вместо отказа

Запрещённое соединение заканчивается **таймаутом**, а не отказом: пакет отбрасывается молча. Это отличает политику от Service без эндпоинтов (03-2), где ответ приходит мгновенно как `Connection refused`. Таймаут ведёт к политике, отказ — к Service или порту.

Порядок поиска:

1. Проверить симптом: таймаут или отказ.
2. Найти политики, которые выбирают под-получатель (Ingress) и под-источник (Egress).
3. Сравнить метки: хватает ли селектора, не перепутаны ли AND и OR.
4. Сверить порт: порт пода, а не Service.
5. Убедиться, что DNS разрешён в Egress.
6. Прочитать правила узла.
7. Повторить проверку новым соединением.

### DNS в Egress

Закрытый Egress без DNS проявляется именем, а не адресом. Запрос по IP пода и по ClusterIP проходит, а запрос по имени ждёт 20 секунд и падает. Причина в том, что приложения кэшируют DNS и держат пулы соединений: сразу после включения политики всё работает и ломается при следующем разрешении имени или переподключении.

### Установленные соединения

Политика проверяется на новых соединениях, поэтому уже открытые продолжают работать. Стандарт оставляет это на выбор реализации, а kindnet и большинство CNI пропускают установленные соединения. Долгий пул соединений к базе, WebSocket или gRPC-поток живёт до разрыва, и закручивание политики его не обрывает. Проверку делают новыми соединениями, а после изменения политики перезапускают клиентов, иначе «вчера включили, ночью после рестарта всё легло». HTTP-сервер orders-api закрывает соединение после каждого ответа, поэтому каждый запрос к нему создаёт новое соединение, и политика срабатывает сразу.

### Трафик узла и probes

kubelet проверяет поды (**probes**, 02-5) с адреса узла. Документация Kubernetes требует пропускать трафик от узла пода независимо от политик. kindnet, Calico и Cilium так и делают, поэтому после default deny поды orders-api остаются Ready. В kindnet это правило `meta skuid 0 accept`: пакеты процессов root на узле, включая kubelet, идут мимо очереди.

Некоторые CNI позволяют подчинить трафик узла политикам отдельной настройкой, и тогда probes нужно разрешать явно. Поведение для подов с `hostNetwork: true` стандарт не определяет, и обычно политики их не охватывают (03-1).

---

## 6. Пределы и значения по умолчанию

Ниже собраны значения, на которые полагаются при проектировании политик.

- **Без политики** все соединения разрешены; изоляция появляется только у выбранных подов.
- **Направления:** `Ingress` всегда в `policyTypes` по умолчанию, `Egress` — при наличии секции `egress`.
- **Протокол и порты:** по умолчанию TCP; TCP, UDP и SCTP поддерживаются; без `ports` разрешены все порты, `endPort` задаёт диапазон.
- **Порядок:** политики складываются, приоритетов нет; запретить явно можно только расширениями CNI или ClusterNetworkPolicy.
- **Область:** политика действует в своём namespace; чужой namespace выбирают через `namespaceSelector`.
- **Удаление namespace:** с версии 1.34 поды удаляются раньше NetworkPolicy, поэтому изоляция действует, пока поды останавливаются.
- **ClusterNetworkPolicy:** v1alpha2, максимум 25 правил и пиров, `priority` от 0 до 1000; на стенде не установлена.

Очередь kindnet работает в режиме **fail open** (пропуск при отказе): если агент kindnet не работает, пакеты проходят, и политики не действуют.

---

## Лабораторные работы

Работы идут на стенде 00-1 в двух namespace: `lab-03-6` для экспериментов и `lab-03-6-other` для клиентов из другого namespace. Работа 5 временно меняет namespace `orders`. Хост не меняется, текущий namespace контекста не переключается: функция `k` добавляет `-n lab-03-6` к каждой команде. Выполняйте работы в одном окне терминала, потому что функции `k`, `probe` и `check` живут в оболочке. Политики действуют только внутри этих namespace и `orders`, поэтому остальной стенд работает как обычно.

Подготовка создаёт namespace, Deployment `api` из одного пода, Service `api`, четырёх клиентов и маршрут Gateway `np.localhost`. Клиенты нужны, чтобы отличать источники по метке и namespace: `client` и `stranger` в `lab-03-6`, `client` и `other-any` в `lab-03-6-other`.

```bash
kubectl config use-context kind-lab
kubectl create ns lab-03-6
kubectl create ns lab-03-6-other
k() { kubectl -n lab-03-6 "$@"; }
k create deploy api --image=localhost:5001/orders-api:2.0 --port=8000
k expose deploy api --port=80 --target-port=8000
k run client --image=python:3.12-slim --labels=role=client --command -- sleep infinity
k run stranger --image=python:3.12-slim --labels=role=stranger --command -- sleep infinity
kubectl -n lab-03-6-other run client --image=python:3.12-slim \
  --labels=role=client --command -- sleep infinity
kubectl -n lab-03-6-other run other-any --image=python:3.12-slim \
  --labels=role=other --command -- sleep infinity
```

Разбор команд:

| Часть команды | Значение |
|---|---|
| `k() { … }` | короткая команда `kubectl` для namespace `lab-03-6` |
| `create deploy api --port=8000` | один под orders-api, порт 8000 |
| `expose … --port=80 --target-port=8000` | Service `api`: порт 80 ведёт на порт пода 8000 |
| `run client --labels=role=client` | клиентский под с меткой `role=client` |
| `--command -- sleep infinity` | держать под живым |

Теперь маршрут Gateway, ожидание готовности и функции проверки. `probe` открывает HTTP-соединение из заданного пода и печатает код ответа со временем, а `check` собирает четыре строки матрицы доступа к Service `api`.

```bash
k apply -f - <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: api}
spec:
  parentRefs: [{name: lab, namespace: envoy-gateway-system}]
  hostnames: ["np.localhost"]
  rules: [{backendRefs: [{name: api, port: 80}]}]
EOF
k rollout status deploy/api
k wait --for=condition=Ready pod --all
kubectl -n lab-03-6-other wait --for=condition=Ready pod --all
```

```bash
probe() { kubectl -n "$1" exec "$2" -- python -c "
import urllib.request,time
t=time.perf_counter()
try: r=str(urllib.request.urlopen('$3',timeout=3).status)
except Exception as e: r=type(e).__name__+':'+str(getattr(e,'reason',e))[:28]
print(f'{r} ({time.perf_counter()-t:.1f}s)')"; }
check() {
  echo "  same-ns client   -> api: $(probe lab-03-6 client http://api.lab-03-6/version)"
  echo "  same-ns stranger -> api: $(probe lab-03-6 stranger http://api.lab-03-6/version)"
  echo "  other-ns client  -> api: $(probe lab-03-6-other client http://api.lab-03-6/version)"
  echo "  via gateway      -> api: $(curl -s -m 3 -o /dev/null -w '%{http_code}' \
    -H 'Host: np.localhost' http://127.0.0.1:8088/version)"
}
```

Разбор:

| Часть команды | Значение |
|---|---|
| `probe NS ПОД URL` | запрос из пода с таймаутом 3 с; печатает код или тип ошибки и время |
| `check` | четыре запроса к Service `api` из разных источников |
| `-H 'Host: np.localhost'` | заголовок для маршрута Gateway |
| `127.0.0.1:8088` | вход стенда на хосте (00-1) |

### Лабораторная работа 1. Default deny и выборочное разрешение

**Цель.** Закрыть входящий трафик к Service целиком, затем открыть его для Gateway и клиентов с меткой, и увидеть каждое состояние матрицей доступа.

**Что понадобится.**

- Подготовка из начала раздела: namespace, поды и функции `k`, `probe`, `check`.
- Права на создание NetworkPolicy в `lab-03-6`.
- Около 15 минут.

**Схема опыта.** Четыре источника ходят к Service `api`; политики меняют, кого из них пропускают.

```
same-ns client   ─┐
same-ns stranger ─┤
other-ns client  ─┼──► Service api ──► поды app=api (политики выбирают их)
via gateway      ─┘    (Envoy, namespace envoy-gateway-system)
```

Схема показывает, что политики стоят на входе в поды `api`; смотрите, какие из четырёх источников доходят.

#### Шаг 1. Снять исходную матрицу

Запускаем `check` до любых политик, чтобы зафиксировать, что открыто всё.

```bash
echo "== baseline"; check
```

Разбор команды:

| Часть команды | Значение |
|---|---|
| `check` | четыре запроса к `api` |

Результат:

```
== baseline
  same-ns client   -> api: 200 (0.0s)
  same-ns stranger -> api: 200 (0.0s)
  other-ns client  -> api: 200 (0.0s)
  via gateway      -> api: 200
```

Разбор вывода:

1. Все четыре источника получают `200`: политик нет, сеть открыта.
2. Время `0.0s` показывает, что запросы идут внутри кластера мгновенно.

#### Шаг 2. Включить default deny

Создаём политику, которая выбирает все поды и закрывает входящий трафик.

```bash
k apply -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: default-deny-ingress}
spec:
  podSelector: {}
  policyTypes: [Ingress]
EOF
sleep 3; echo "== default deny ingress"; check
```

Разбор команд:

| Часть команды | Значение |
|---|---|
| `podSelector: {}` | выбрать все поды namespace |
| `policyTypes: [Ingress]` | закрыть входящие, правил нет |
| `sleep 3` | дать kindnet применить правила |

Результат:

```
== default deny ingress
  same-ns client   -> api: URLError:timed out (3.0s)
  same-ns stranger -> api: URLError:timed out (3.0s)
  other-ns client  -> api: URLError:timed out (3.0s)
  via gateway      -> api: 000
```

Разбор вывода:

1. Все источники получили таймаут (3,0 с — предел `probe`), а не отказ: пакеты отброшены молча.
2. Для Gateway `curl` вернул `000`: ответа за 3 секунды нет. Envoy стоит в namespace `envoy-gateway-system`, и без явного разрешения маршрут превращается в таймаут.
3. Сервис и поды здоровы; закрыт только вход.

#### Шаг 3. Открыть вход для Gateway и клиентов

Добавляем политику, которая пускает поды `api` от Envoy и от подов с меткой `role=client` в том же namespace. Два элемента `from` дают условие «или».

```bash
k apply -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: api-allow}
spec:
  podSelector: {matchLabels: {app: api}}
  policyTypes: [Ingress]
  ingress:
  - from:
    - namespaceSelector:
        matchLabels: {kubernetes.io/metadata.name: envoy-gateway-system}
    - podSelector: {matchLabels: {role: client}}
    ports: [{port: 8000}]
EOF
sleep 3; echo "== allow gateway OR same-ns role=client"; check
```

Разбор ключей манифеста:

| Часть манифеста | Значение |
|---|---|
| `podSelector: {app: api}` | политика действует на поды `api` |
| первый элемент `from` | все поды namespace Envoy Gateway |
| второй элемент `from` | поды `role=client` в этом же namespace |
| `ports: [{port: 8000}]` | порт пода, а не Service |

Результат:

```
== allow gateway OR same-ns role=client
  same-ns client   -> api: 200 (0.0s)
  same-ns stranger -> api: URLError:timed out (3.0s)
  other-ns client  -> api: URLError:timed out (3.0s)
  via gateway      -> api: 200
```

Разбор вывода:

1. `client` из своего namespace и Gateway проходят: они попали под разрешающие элементы.
2. `stranger` без метки `role=client` по-прежнему получает таймаут.
3. `client` из другого namespace тоже отброшен: `podSelector` без `namespaceSelector` выбирает поды только своего namespace, а метка у чужого не помогает.

#### Шаг 4. Прочитать правила на узле

Смотрим таблицу nftables, в которую kindnet превратил политики. Команда только читает.

```bash
docker exec lab-worker sh -c 'nft list table inet kindnet-network-policies | head -30'
```

Разбор команды:

| Часть команды | Значение |
|---|---|
| `docker exec lab-worker` | выполнить внутри узла |
| `nft list table inet …` | показать таблицу kindnet |
| `head -30` | ограничить вывод |

Результат: ожидаемый — таблица с цепочками, правилами `queue` на NFQUEUE и проверкой conntrack label. Текст вывода зависит от версии kindnet, и прогон его не сохранил.

Разбор вывода:

1. Правила `queue` отправляют первый пакет нового соединения агенту (§2).
2. Правило с `ct label` и `ct state established,related` пропускает следующие пакеты без повторной проверки.

#### Итог

| Что узнали | Как проверить |
|---|---|
| Без политик всё открыто | базовая матрица, все `200` |
| Default deny закрывает вход молча | таймауты, `000` у Gateway |
| Gateway надо разрешать отдельно | `envoy-gateway-system` в `from` |
| Запрет проявляется таймаутом | 3,0 с против мгновенного отказа |

#### Уборка

Удаляем политики работы. Namespace и поды оставляем для следующих работ.

```bash
k delete netpol --all
```

Результат:

```
networkpolicy.networking.k8s.io "api-allow" deleted
networkpolicy.networking.k8s.io "default-deny-ingress" deleted
```

Разбор вывода: оба объекта удалены, матрица снова вернётся к четырём `200`.

#### Вопросы для самопроверки

1. Почему default deny даёт таймаут, а не `Connection refused`?

<details><summary>Ответ</summary>

Пакеты отбрасываются молча, а отказ создаёт получатель или правило REJECT. Таймаут указывает на политику или потерю пакетов, мгновенный отказ — на Service или порт (03-2).

</details>

2. Что нужно добавить, чтобы после default deny снова заработал маршрут Gateway?

<details><summary>Ответ</summary>

Ingress-правило с `namespaceSelector` на namespace Envoy (`envoy-gateway-system`) и портом пода. Gateway — это поды Envoy, а не внешний трафик.

</details>

3. Почему клиент с меткой `role=client` из другого namespace не прошёл в шаге 3?

<details><summary>Ответ</summary>

`podSelector` без `namespaceSelector` относится к подам namespace самой политики. Чужие поды нужно выбирать через `namespaceSelector`.

</details>

### Лабораторная работа 2. AND против OR

**Цель.** Измерить разницу между одним и двумя элементами в `from` и запомнить, что её определяет один дефис.

**Что понадобится.**

- Подготовка из начала раздела.
- Около 10 минут.

**Схема опыта.** Один и тот же набор источников проверяется на двух вариантах политики.

```
источники:  other-ns role=client   other-ns role=other   same-ns role=client
вариант AND: один элемент from  (namespace И метка)
вариант OR:  два элемента from  (namespace ИЛИ метка в своём namespace)
```

Схема показывает три источника и два варианта политики; смотрите, у каких пар результат меняется.

#### Шаг 1. Вариант AND

Закрываем вход default deny и разрешаем один элемент: поды `role=client` из namespace `lab-03-6-other`.

```bash
k apply -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: default-deny-ingress}
spec: {podSelector: {}, policyTypes: [Ingress]}
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: api-allow}
spec:
  podSelector: {matchLabels: {app: api}}
  policyTypes: [Ingress]
  ingress:
  - from:
    - namespaceSelector:
        matchLabels: {kubernetes.io/metadata.name: lab-03-6-other}
      podSelector: {matchLabels: {role: client}}
    ports: [{port: 8000}]
EOF
sleep 3
echo "other-ns role=client -> $(probe lab-03-6-other client http://api.lab-03-6/version)"
echo "other-ns role=other  -> $(probe lab-03-6-other other-any http://api.lab-03-6/version)"
echo "same-ns  role=client -> $(probe lab-03-6 client http://api.lab-03-6/version)"
```

Разбор команд:

| Часть команды | Значение |
|---|---|
| `namespaceSelector` и `podSelector` в одном элементе | оба условия обязательны (AND) |
| три `probe` | источники из таблицы схемы |

Ожидаемый результат: прогон записал только итог каждой строки, поэтому время в скобках у вас будет своим.

```
other-ns role=client -> 200 (…)
other-ns role=other  -> URLError:timed out (…)
same-ns  role=client -> URLError:timed out (…)
```

Разбор вывода:

1. Проходит только `role=client` из `lab-03-6-other`: совпали оба условия.
2. Под `other-any` из нужного namespace, но без метки `role=client`, отброшен.
3. `client` из `lab-03-6` с нужной меткой, но из другого namespace, тоже отброшен.

#### Шаг 2. Вариант OR

Меняем один элемент на два: теперь работает каждый селектор отдельно.

```bash
k apply -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: api-allow}
spec:
  podSelector: {matchLabels: {app: api}}
  policyTypes: [Ingress]
  ingress:
  - from:
    - namespaceSelector:
        matchLabels: {kubernetes.io/metadata.name: lab-03-6-other}
    - podSelector: {matchLabels: {role: client}}
    ports: [{port: 8000}]
EOF
sleep 3
echo "other-ns role=client -> $(probe lab-03-6-other client http://api.lab-03-6/version)"
echo "other-ns role=other  -> $(probe lab-03-6-other other-any http://api.lab-03-6/version)"
echo "same-ns  role=client -> $(probe lab-03-6 client http://api.lab-03-6/version)"
```

Разбор команд:

| Часть команды | Значение |
|---|---|
| дефис перед `podSelector` | отдельный элемент: условие «или» |

Ожидаемый результат: прогон записал только коды, время у вас будет своим.

```
other-ns role=client -> 200 (…)
other-ns role=other  -> 200 (…)
same-ns  role=client -> 200 (…)
```

Разбор вывода:

1. Все источники проходят: `lab-03-6-other` пускается целиком, а `role=client` пускается в своём namespace.
2. Под `other-any` без метки `role=client` прошёл по первому элементу, то есть доступ шире, чем в варианте AND.
3. Одна лишняя строка с дефисом открыла весь namespace.

#### Итог

| Что узнали | Как проверить |
|---|---|
| Один элемент — AND | пройдён только `other / role=client` |
| Два элемента — OR | прошли все три источника |
| Ошибка в дефисе открывает шире | `other-any` прошёл во втором варианте |

#### Уборка

```bash
k delete netpol --all
```

Результат: две строки `deleted`, как в работе 1.

#### Вопросы для самопроверки

1. Как записать «клиент с меткой из namespace prod»?

<details><summary>Ответ</summary>

Один элемент `from` с `namespaceSelector` на `prod` и `podSelector` с меткой клиента. Два селектора без дефиса между ними дают AND.

</details>

2. Что откроет политика, если два селектора стоят в разных элементах?

<details><summary>Ответ</summary>

Все поды выбранного namespace и все поды с меткой в namespace самой политики. Условие превращается в «или».

</details>

3. Как выбрать namespace по имени?

<details><summary>Ответ</summary>

Через метку `kubernetes.io/metadata.name`, которую Kubernetes ставит на каждый namespace сам.

</details>

### Лабораторная работа 3. Egress и DNS

**Цель.** Закрыть исходящий трафик клиента и увидеть, как пропадает DNS, затем вернуть его одним правилом.

**Что понадобится.**

- Подготовка из начала раздела.
- Около 15 минут.

**Схема опыта.** Клиент ходит к `api` тремя способами: по имени, по IP пода и по ClusterIP.

```
client ──► CoreDNS (kube-system:53)     имя → адрес     нужен свой Egress-пропуск
   │
   ├──► IP пода :8000        работает, пока разрешён под app=api
   └──► ClusterIP :80        работает: политика видит под, а не Service
```

Схема показывает три пути; смотрите, какие из них зависят от DNS.

#### Шаг 1. Разрешить Egress только к api

Создаём политику, которая выбирает поды `role=client` и разрешает им исходящее только к подам `app=api` на порту 8000.

```bash
k apply -f - <<'EOF'
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
```

Разбор ключей манифеста:

| Часть манифеста | Значение |
|---|---|
| `podSelector: {role: client}` | политика действует на клиента |
| `policyTypes: [Egress]` | закрыть исходящее |
| `to: podSelector app=api` | разрешить только поды `api` |
| `port: 8000` | порт пода |

Результат: `networkpolicy.networking.k8s.io/client-egress created`.

Разбор вывода: объект создан. Клиент изолирован по Egress, и DNS в разрешённых получателях нет.

#### Шаг 2. Проверить три способа обращения

Функция `tryc` резолвит имя, затем открывает адрес и печатает оба результата со временем.

```bash
tryc() { k exec client -- python -c "
import urllib.request,time,socket
t=time.perf_counter()
try: socket.getaddrinfo('api.lab-03-6',80); d='dns ok'
except Exception as e: d='dns '+type(e).__name__
d+=f' ({time.perf_counter()-t:.1f}s)'
t=time.perf_counter()
try: r=str(urllib.request.urlopen('$1',timeout=3).status)
except Exception as e: r=type(e).__name__+':'+str(getattr(e,'reason',e))[:30]
print(f'{d}; $1 -> {r} ({time.perf_counter()-t:.1f}s)')"; }
tryc http://api.lab-03-6/version
tryc http://$(k get pod -l app=api -o jsonpath='{.items[0].status.podIP}'):8000/version
tryc http://$(k get svc api -o jsonpath='{.spec.clusterIP}')/version
```

Разбор команд:

| Часть команды | Значение |
|---|---|
| `getaddrinfo` | резолв имени через CoreDNS |
| `jsonpath … podIP` | IP первого пода `api` |
| `jsonpath … clusterIP` | ClusterIP Service |

Результат:

```
dns gaierror (20.0s); http://api.lab-03-6/version -> URLError:[Errno -3] Temporary failure i (20.0s)
dns gaierror (20.0s); http://10.244.2.136:8000/version -> 200 (0.0s)
dns gaierror (20.0s); http://10.96.187.232/version -> 200 (0.0s)
```

Разбор вывода:

1. Резолв имени занимает 20,0 секунд и заканчивается `gaierror`: запрос к CoreDNS отброшен.
2. По IP пода запрос проходит с кодом `200`.
3. По ClusterIP запрос тоже проходит: после замены адреса в kube-proxy политика видит пакет к поду `app=api`, а не к Service.
4. Функция `tryc` резолвит имя в каждой строке, поэтому 20 секунд добавляются и к запросам по IP; само соединение по IP занимает 0,0 секунды.

#### Шаг 3. Добавить правило для DNS

Дописываем в Egress поды CoreDNS на порту 53 по UDP и TCP.

```bash
k patch networkpolicy client-egress --type=json -p '[{"op":"add","path":"/spec/egress/-","value":{
  "to":[{"namespaceSelector":{"matchLabels":{"kubernetes.io/metadata.name":"kube-system"}},
         "podSelector":{"matchLabels":{"k8s-app":"kube-dns"}}}],
  "ports":[{"port":53,"protocol":"UDP"},{"port":53,"protocol":"TCP"}]}}]'
sleep 3
tryc http://api.lab-03-6/version
tryc http://1.1.1.1
```

Разбор команд:

| Часть команды | Значение |
|---|---|
| `--type=json` | патч операциями над путями |
| `"op":"add"`, путь `/spec/egress/-` | добавить правило в конец списка |
| `k8s-app: kube-dns` | метка подов CoreDNS |
| `1.1.1.1` | внешний адрес для проверки запрета |

Результат:

```
dns ok (0.0s); http://api.lab-03-6/version -> 200 (…)
dns ok (…); http://1.1.1.1 -> URLError:timed out (…)
```

Прогон сохранил начало первой строки и итог второй; пропуски отмечены `…`, а таймаут во второй строке ожидается около 3 секунд по `timeout=3`.

Разбор вывода:

1. Резолв занимает 0,0 секунды: DNS разрешён, имя `api` работает.
2. Внешний адрес `1.1.1.1` даёт таймаут: Egress наружу не разрешён.
3. Одно правило с портом 53 заменило 20 секунд ожидания на мгновенный ответ.

#### Итог

| Что узнали | Как проверить |
|---|---|
| Закрытый Egress ломает DNS | резолв 20,0 с, `gaierror` |
| По IP пода и ClusterIP работает | `200` в шагах без DNS |
| Политика видит под, а не Service | запрос по ClusterIP прошёл |
| DNS открывают отдельным правилом | порт 53 UDP и TCP к `kube-dns` |

#### Уборка

```bash
k delete netpol client-egress
unset -f tryc
```

Результат: `networkpolicy.networking.k8s.io "client-egress" deleted`.

#### Вопросы для самопроверки

1. Почему запрос по IP работает, а по имени нет?

<details><summary>Ответ</summary>

IP не требует DNS, а имя требует запроса к CoreDNS, который политика Egress отбросила.

</details>

2. Зачем в правиле DNS указан TCP?

<details><summary>Ответ</summary>

Большие ответы и повторы идут по TCP. Без него часть запросов остаётся без ответа.

</details>

3. Почему политика на `app=api` разрешила запрос к ClusterIP?

<details><summary>Ответ</summary>

kube-proxy заменяет ClusterIP на IP пода раньше, чем пакет проверяют по политике, поэтому разрешают поды за Service.

</details>

### Лабораторная работа 4. Установленное соединение

**Цель.** Увидеть, что политика не обрывает уже открытое TCP-соединение, но блокирует новое.

**Что понадобится.**

- Подготовка из начала раздела.
- Около 10 минут.

**Схема опыта.** Клиент держит открытое соединение к echo-серверу, а на четвёртой секунде политика, разрешающая клиента, удаляется.

```
t=0  client ══ соединение ══► echo-tcp   политика разрешает client
t=4  политика удалена
t=5… старое соединение живёт (conntrack label); новое — таймаут
```

Схема показывает момент удаления политики; смотрите, что происходит с открытым и новым соединениями.

#### Шаг 1. Запустить echo-сервер

Запускаем под, который возвращает каждую полученную строку, закрываем вход default deny и пускаем в echo-под только клиентов.

```bash
k run echo-tcp --image=python:3.12-slim --labels=role=echo --command -- python -c "
import socketserver
class H(socketserver.StreamRequestHandler):
    def handle(self):
        for line in self.rfile: self.wfile.write(line)
socketserver.ThreadingTCPServer(('0.0.0.0',8000),H).serve_forever()"
k wait --for=condition=Ready pod/echo-tcp
k apply -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: default-deny-ingress}
spec: {podSelector: {}, policyTypes: [Ingress]}
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: echo-allow}
spec:
  podSelector: {matchLabels: {role: echo}}
  policyTypes: [Ingress]
  ingress:
  - from: [{podSelector: {matchLabels: {role: client}}}]
    ports: [{port: 8000}]
EOF
sleep 3
```

Разбор команд:

| Часть команды | Значение |
|---|---|
| `socketserver … serve_forever()` | TCP-сервер, возвращающий строки |
| `--labels=role=echo` | метка для политики |
| `default-deny-ingress` | закрыть вход всем подам; остаётся до конца работы |
| `podSelector role=echo` | политика echo-allow действует на echo-сервер |
| `from: role=client` | пускает клиента |

Результат: `pod/echo-tcp created`, `pod/echo-tcp condition met` и две строки `created` для политик.

Разбор вывода: под готов, и политика создана; метка `role=echo` исключает попадание echo-сервера в Service `api`.

#### Шаг 2. Удалить политику при открытом соединении

Открываем соединение в фоне, на четвёртой секунде удаляем политику, а затем пробуем открыть новое соединение.

```bash
IP=$(k get pod echo-tcp -o jsonpath='{.status.podIP}')
k exec client -- python -c "
import socket,time
s=socket.create_connection(('$IP',8000),timeout=3)
for i in range(14):
    try:
        s.sendall(b'ping\n')
        print(f't={i}s established: {s.recv(16).strip().decode()}', flush=True)
    except Exception as e:
        print(f't={i}s established: {type(e).__name__}', flush=True)
    time.sleep(1)" &
sleep 4; k delete netpol echo-allow; wait
k exec client -- python -c "
import socket
try: socket.create_connection(('$IP',8000),timeout=3); print('new connection: ok')
except Exception as e: print('new connection:', type(e).__name__)"
```

Разбор команд:

| Часть команды | Значение |
|---|---|
| `create_connection(…)` | открыть одно TCP-соединение |
| `s.sendall(b'ping\n')` | отправлять строку раз в секунду |
| `… &` | запустить в фоне |
| `sleep 4; k delete netpol echo-allow` | убрать разрешение на четвёртой секунде |
| `wait` | дождаться конца фонового цикла |
| последний `exec` | открыть новое соединение |

Результат:

```
t=0s established: ping
…
t=13s established: ping
new connection: TimeoutError
```

Разбор вывода:

1. Строки `established: ping` идут до `t=13s`: старое соединение пережило удаление политики.
2. Новое соединение даёт `TimeoutError`: разрешающей политики нет, а default deny продолжает изолировать под.
3. Вывод: политика проверяется на новых соединениях, а установленные идут по conntrack label.

Полный вывод содержит 14 строк с `ping`; пропущенные строки заменены `…`.

#### Итог

| Что узнали | Как проверить |
|---|---|
| Установленное соединение переживает изменение политики | `established: ping` до `t=13s` |
| Новое соединение блокируется | `TimeoutError` |
| Проверять надо новыми соединениями | отдельный `create_connection` |
| После закручивания политик перезапускают клиентов | пулы соединений рвутся только так |

#### Уборка

```bash
k delete netpol default-deny-ingress
k delete pod echo-tcp --grace-period=0 --force
unset IP
```

Результат: `networkpolicy.networking.k8s.io "default-deny-ingress" deleted` и `pod "echo-tcp" force deleted`.

#### Вопросы для самопроверки

1. Вы закрыли доступ к базе, но приложение продолжает работать. Почему?

<details><summary>Ответ</summary>

Пул соединений к базе открыт заранее, а политика проверяет только новые соединения. Помогает перезапуск клиентов.

</details>

2. Почему запросы к orders-api подчиняются политике сразу?

<details><summary>Ответ</summary>

Сервер закрывает соединение после каждого ответа, поэтому каждый запрос создаёт новое соединение.

</details>

3. Где в kindnet видна проверка conntrack label?

<details><summary>Ответ</summary>

В таблице `inet kindnet-network-policies` на узле: её показывает `nft list table inet kindnet-network-policies`.

</details>

### Лабораторная работа 5. Закрыть namespace orders

**Риски.** Работа временно меняет рабочее приложение стенда.

- **Что меняется:** в namespace `orders` создаются 4 NetworkPolicy и перезапускаются поды orders-api командой `rollout restart`.
- **Надолго ли:** до уборки; уборка удаляет политики.
- **Безопасность:** привилегий не нужно; политики сужают доступ, а не расширяют.
- **Влияние на систему:** при ошибке в политике `orders.localhost:8088` перестаёт отвечать, другие namespace не затрагиваются.
- **Откат:** уборка удаляет политики и применяет исходные манифесты `orders`.

**Цель.** Применить набор из четырёх политик к демо-приложению и проверить, что вход идёт только через Gateway, база доступна только orders-api, а наружу трафика нет.

**Что понадобится.**

- Подготовка из начала раздела: нужен под `client` в `lab-03-6`.
- Запущенный namespace `orders` с orders-api и PostgreSQL (00-1).
- Около 15 минут.

**Схема опыта.** Политики выстраивают в `orders` цепочку: Gateway → orders-api → PostgreSQL, всё остальное закрыто.

```
Gateway (Envoy) ──► orders-api :8000 ──► postgres :5432
чужой client    ──X orders-api / postgres
orders-api      ──X internet          DNS (kube-system :53) разрешён всем
```

Схема показывает единственную разрешённую цепочку; смотрите, какие стрелки отмечены крестом.

#### Шаг 1. Записать набор политик

Файл кладём в каталог части: он пригодится позже в сценариях поломок.

```bash
mkdir -p ~/lab/k8s/03-6
cat > ~/lab/k8s/03-6/orders-netpol.yaml <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: default-deny, namespace: orders}
spec: {podSelector: {}, policyTypes: [Ingress, Egress]}
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: allow-dns, namespace: orders}
spec:
  podSelector: {}
  policyTypes: [Egress]
  egress:
  - to:
    - namespaceSelector:
        matchLabels: {kubernetes.io/metadata.name: kube-system}
      podSelector: {matchLabels: {k8s-app: kube-dns}}
    ports: [{port: 53, protocol: UDP}, {port: 53, protocol: TCP}]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: orders-api, namespace: orders}
spec:
  podSelector: {matchLabels: {app: orders-api}}
  policyTypes: [Ingress, Egress]
  ingress:
  - from:
    - namespaceSelector:
        matchLabels: {kubernetes.io/metadata.name: envoy-gateway-system}
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
```

Разбор файла:

| Часть файла | Значение |
|---|---|
| `default-deny` | закрыть Ingress и Egress всем подам |
| `allow-dns` | Egress всех подов к CoreDNS |
| `orders-api` | вход от Envoy; выход к PostgreSQL |
| `postgres` | вход только от orders-api на 5432 |

Результат: файл создан, вывода нет.

#### Шаг 2. Применить и проверить

Применяем набор и проверяем три вещи: Gateway работает, чужой клиент не проходит, orders-api не выходит наружу.

```bash
kubectl apply -f ~/lab/k8s/03-6/orders-netpol.yaml; sleep 4
for i in 1 2 3; do
  curl -s -o /dev/null -w '%{http_code}\n' http://orders.localhost:8088/api/orders
done
k exec client -- python -c "
import urllib.request, socket
u='http://orders-api.orders/api/orders'
try: print('-> orders-api:', urllib.request.urlopen(u, timeout=3).status)
except Exception as e: print('-> orders-api:', type(e).__name__)
try: socket.create_connection(('postgres.orders',5432),timeout=3); print('-> postgres: ok')
except Exception as e: print('-> postgres:', type(e).__name__)"
kubectl -n orders exec deploy/orders-api -- python -c "
import urllib.request
try: print('-> internet:', urllib.request.urlopen('http://1.1.1.1',timeout=3).status)
except Exception as e: print('-> internet:', type(e).__name__)"
```

Разбор команд:

| Часть команды | Значение |
|---|---|
| `kubectl apply -f …` | создать 4 политики |
| `curl … orders.localhost:8088` | запрос через Gateway, три раза |
| `k exec client` | проверка из чужого namespace |
| `postgres.orders:5432` | прямое соединение с базой |
| `exec deploy/orders-api` | проверка выхода наружу из самого приложения |

Результат:

```
200
200
200
-> orders-api: URLError
-> postgres: TimeoutError
-> internet: URLError
```

Разбор вывода:

1. Три `200`: Gateway проходит к orders-api, а orders-api к PostgreSQL.
2. Чужой `client` не доходит до orders-api: нет разрешения для его namespace.
3. К базе чужой клиент получает `TimeoutError`: пускает только orders-api.
4. Выход orders-api наружу закрыт: в Egress нет ничего, кроме PostgreSQL и DNS.

Итоги всех строк взяты из прогона. Команда для строки `-> internet` в прогоне не сохранилась и записана заново; python в образе orders-api есть, потому что он собран на `python:3.12-slim` (00-1).

#### Шаг 3. Проверить перезапуск и probes

Перезапускаем поды и убеждаемся, что проверки kubelet проходят при default deny.

```bash
kubectl -n orders rollout restart deploy/orders-api
kubectl -n orders rollout status deploy/orders-api
curl -s -o /dev/null -w '%{http_code}\n' http://orders.localhost:8088/api/orders
```

Разбор команд:

| Часть команды | Значение |
|---|---|
| `rollout restart` | пересоздать поды orders-api |
| `rollout status` | дождаться Ready |
| `curl …` | запрос через Gateway |

Результат: `deployment "orders-api" successfully rolled out` и код `200`.

Разбор вывода: новые поды стали Ready при default deny, значит трафик kubelet к подам политика не блокирует. В Cilium и ряде облачных CNI это нужно разрешать явно (§5).

#### Итог

| Что узнали | Как проверить |
|---|---|
| Вход в orders только через Gateway | три `200`, чужой клиент — `URLError` |
| База доступна только orders-api | `TimeoutError` у чужого клиента |
| Выход наружу закрыт | `URLError` у orders-api |
| Probes kubelet проходят | поды Ready после перезапуска |

#### Уборка

Удаляем политики, проверяем ответ и возвращаем исходные манифесты `orders`.

```bash
kubectl delete -f ~/lab/k8s/03-6/orders-netpol.yaml
kubectl apply -f ~/lab/k8s/orders-api/k8s/
curl -s -o /dev/null -w '%{http_code}\n' http://orders.localhost:8088/api/orders
```

Результат: четыре строки `deleted`, строки `unchanged` или `configured` от `kubectl apply`, затем `200`.

Разбор вывода: `200` подтверждает, что приложение снова доступно без политик. Файл `orders-netpol.yaml` остаётся в `~/lab/k8s/03-6/` для сценариев поломок.

#### Вопросы для самопроверки

1. Почему в наборе есть отдельная политика allow-dns?

<details><summary>Ответ</summary>

Default deny закрывает Egress, а резолв имён — исходящее соединение к CoreDNS. Без него имена не разрешаются.

</details>

2. Prometheus из namespace `monitoring` должен собирать метрики orders-api. Что добавить в набор?

<details><summary>Ответ</summary>

Нужна ещё одна Ingress-политика на порт метрик с `namespaceSelector` на `monitoring`. Default deny закрывает вход всем, кроме перечисленного.

</details>

3. Как убедиться, что политики действительно работают, а не просто созданы?

<details><summary>Ответ</summary>

Попробовать запрещённое соединение новым подключением и получить таймаут. Наличие объекта `kubectl get netpol` ничего не доказывает.

</details>

### Общая уборка

Удаляем namespace и функции оболочки. Хост и узлы не менялись.

```bash
kubectl delete ns lab-03-6 lab-03-6-other
unset -f k probe check
kubectl get ns lab-03-6
```

Результат:

```
namespace "lab-03-6" deleted
namespace "lab-03-6-other" deleted
Error from server (NotFound): namespaces "lab-03-6" not found
```

Разбор вывода: оба namespace удалены вместе с подами, Service, HTTPRoute и политиками. Удаление может занять около 30 секунд.

---

## → Дальше

Сеть кластера теперь описана полностью: адреса подов, Service, DNS, вход через Gateway и ограничения политиками. Но приложению нужны ещё конфигурация и данные, и политики не защищают то, что лежит внутри подов. Следующая часть, 04-1, открывает модуль «Конфигурация и данные» с ConfigMap и Secret. Она покажет, как приложение получает настройки и пароли и почему base64 не шифрование.
