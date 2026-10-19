# 03-5. TLS и миграция с Ingress

> Модуль 03 «Сеть» · часть 5 из 6 · ~1,5 ч чтения + ~1,5 ч лабы · Нужно: стенд 00-1 (Envoy Gateway 1.9.2, Gateway `lab`), helm и docker из 00-1, доступ к `quay.io` и образам `python:3.12-slim`, `curlimages/curl:8.11.1`, openssl на хосте · Опирается на: 03-2 (Service), 03-4 (Gateway, HTTPRoute, ReferenceGrant)

## Где мы на карте

Часть закрывает вход в кластер: шифрование на Gateway, выпуск сертификатов и переезд с Ingress. Она опирается на 03-4, где Gateway и HTTPRoute уже принимают трафик по HTTP, и на 03-2, потому что бэкендом маршрута остаётся Service. Объекты Gateway API (listener, HTTPRoute, ReferenceGrant) здесь не объясняются заново.

Следующая часть, 03-6, ограничивает трафик внутри кластера политиками NetworkPolicy. Шифрование и ограничение дополняют друг друга: TLS защищает содержимое, политика решает, кто вообще может подключиться.

```
клиент ──TLS 1──► Gateway lab (listener HTTPS) ──TLS 2──► Service secure ──► под
                     │  Secret kubernetes.io/tls              ▲
                     │  выпускает cert-manager        BackendTLSPolicy
                     ▼                                 проверяет сертификат бэкенда
          Issuer / ClusterIssuer (ACME, свой CA)

Ingress (старый вход) ──ingress2gateway──► Gateway + HTTPRoute   ← переезд
```

Схема 1. Два участка TLS на пути запроса: клиент → Gateway (TLS 1) и Gateway → бэкенд (TLS 2). Смотрите, какой объект отвечает за каждый участок.

---

## 1. Какую задачу решает TLS на входе

Вход в кластер должен шифровать трафик, доказывать свою подлинность и не требовать ручной работы с сертификатами. Ещё одна задача года: уйти с Ingress-контроллера ingress-nginx, который перестал получать исправления.

### Два участка шифрования

**TLS** (Transport Layer Security, протокол шифрования соединения) на входе работает на двух участках. На первом клиент проверяет Gateway, на втором Gateway проверяет бэкенд. **TLS termination** (завершение TLS) значит, что Gateway расшифровывает запрос и читает заголовки и пути. Затем он выбирает маршрут и отправляет запрос в бэкенд открытым текстом или новым шифрованным соединением.

Первый участок есть почти везде. Второй нужен, когда сеть внутри кластера нельзя считать доверенной: требования регулятора, общие узлы, чужие сетевые плагины. Вариант без расшифровки на Gateway называется **passthrough**: Gateway пересылает зашифрованные байты, выбирая бэкенд только по имени сервера (SNI), а маршрутизировать по путям не может.

### Сертификаты нельзя продлевать руками

**Сертификат** (certificate) — подписанный удостоверяющим центром документ, который связывает имя хоста с открытым ключом. Срок публичных сертификатов сокращает CA/Browser Forum: до 200 дней с 15 марта 2026, до 100 дней в 2027 и до 47 дней в 2029. При 47 днях ручная замена на десятках хостов превращается в постоянные аварии. Поэтому сертификатами управляет оператор **cert-manager** — набор контроллеров Kubernetes, который выпускает сертификаты и продлевает их до истечения.

### Ingress уходит

**Ingress** — старый объект Kubernetes для входящего HTTP-трафика. Контроллер ingress-nginx, самый популярный из них, снят с поддержки 24 марта 2026: новых релизов и исправлений безопасности нет, а уже установленные копии продолжают работать. Остальные контроллеры живут, но сам объект Ingress заморожен в API и новых возможностей не получит. Миграция на Gateway API из желательной стала обязательной, и дальше разобрано, как её провести без простоя.

## 2. Как это устроено

TLS на входе складывается из пяти частей: listener Gateway, цепочки объектов cert-manager, протокола ACME, политики TLS до бэкенда и объекта Ingress, который предстоит заменить.

### TLS на listener Gateway

**Listener** (слушатель, порт и протокол Gateway, 03-4) с протоколом HTTPS ссылается на сертификат через поле `certificateRefs`. Режим `Terminate` расшифровывает трафик на Gateway, режим `Passthrough` пересылает его как есть. Сертификат лежит в **Secret** (объект для секретных данных) типа `kubernetes.io/tls` с двумя ключами: `tls.crt` с цепочкой сертификатов и `tls.key` с закрытым ключом.

```yaml
listeners:
- name: https-shop
  protocol: HTTPS
  port: 443
  hostname: shop.localhost
  tls:
    mode: Terminate
    certificateRefs: [{name: shop-localhost-tls}]
```

Блок задаёт listener для хоста `shop.localhost`. Секрет `shop-localhost-tls` берётся из namespace Gateway. Чтобы взять его из другого namespace, владелец секрета создаёт ReferenceGrant, как для бэкендов в 03-4. В начале соединения клиент сообщает имя хоста в поле **SNI** (Server Name Indication, имя сервера в открытом виде). По нему Envoy выбирает listener и сертификат.

Режим `Passthrough` требует другого маршрута: HTTPRoute не видит расшифрованных заголовков, поэтому вместо него берут **TLSRoute** (маршрут по SNI, стабильный в Gateway API 1.5). Listener с `Passthrough` не имеет `certificateRefs`, потому что сертификат хранит сам бэкенд. Общий сертификат на несколько хостов подходит под wildcard-имя вроде `*.example.com`, а отдельные listener на каждый хост дают отдельные сертификаты и отдельные секреты.

Клиентский сертификат на входе (взаимный TLS, mTLS) проверяет сам Gateway: в Gateway API 1.5 для этого появилась стабильная настройка проверки клиентских сертификатов на listener. Для типичного веб-входа она не нужна, а для внутренних API за Gateway помогает не пускать чужих клиентов ещё до маршрутизации.

### Цепочка объектов cert-manager

cert-manager добавляет в кластер собственные типы объектов. Они образуют цепочку от запроса к готовому секрету.

- **Issuer** и **ClusterIssuer** — «кто подписывает»: ACME-сервер, собственный CA, Vault. Issuer действует в одном namespace, ClusterIssuer во всём кластере.
- **Certificate** — «что выпустить»: имена, срок, алгоритм ключа и имя секрета для результата.
- **CertificateRequest** — запрос на подпись, который контроллер создаёт сам; его можно только читать.
- **Secret** типа `kubernetes.io/tls` — готовый результат, который обновляется при каждом продлении.

```
Certificate shop-localhost-tls ──► CertificateRequest ──► Issuer / ClusterIssuer
        ▲                                                       │ подписывает
        │ следит за сроком, продлевает                          ▼
   cert-manager ◄────────────────────────── Secret shop-localhost-tls (tls.crt, tls.key)
                                                              ▲
                                            читает listener Gateway (certificateRefs)
```

Схема 2. Путь запроса на сертификат: Certificate порождает CertificateRequest, issuer подписывает, результат попадает в Secret, а Gateway подхватывает его.

Контроллер Certificate сравнивает желаемое и фактическое состояние. Он считает сертификат неготовым, если секрета нет, ключ не подходит к сертификату, имена в `dnsNames` расходятся с секретом или подошёл срок продления. В каждом из этих случаев запускается новый выпуск, поэтому удалённый секрет восстанавливается сам.

На стенде подписывает свой CA: самоподписанный ClusterIssuer создаёт корневой сертификат, а второй ClusterIssuer типа `ca` подписывает им сертификаты для листенеров. В продакшене вместо этого стоит ACME.

### ACME: подтверждение владения именем

**ACME** (Automatic Certificate Management Environment, протокол автоматического выпуска) позволяет серверу вроде Let's Encrypt проверить, что запрашивающий управляет доменом. Для проверки cert-manager создаёт объекты **Order** (заказ у CA) и **Challenge** (проверка), а подтвердить владение можно двумя способами.

- **HTTP-01** — CA запрашивает файл по адресу `http://имя/.well-known/acme-challenge/…`. cert-manager временно создаёт для этого HTTPRoute на вашем Gateway. Метод простой, но не выдаёт wildcard-сертификаты (`*.example.com`) и требует порт 80, открытый из интернета.
- **DNS-01** — CA ищет TXT-запись `_acme-challenge.имя` в DNS. cert-manager создаёт её через API DNS-провайдера. Метод выдаёт wildcard и работает в закрытых кластерах, но требует ключ доступа к DNS.

Ход выпуска через ACME такой: cert-manager регистрирует аккаунт на сервере CA и создаёт Order с перечнем имён. Для каждого имени появляется Challenge, а cert-manager готовит ответ на проверку: файл через временный маршрут для HTTP-01 или TXT-запись для DNS-01. Когда CA подтвердил владение всеми именами, cert-manager отправляет запрос на подпись и получает сертификат. Любой сбой останавливает цепочку на Challenge, поэтому разбор ошибок ACME начинают с него.

Для отладки у Let's Encrypt есть отдельный staging-сервер с более мягкими лимитами, а выпущенные им сертификаты браузеры не принимают. На стенде ACME не запускается: стенд не виден из интернета, поэтому здесь это теория.

### TLS до бэкенда: BackendTLSPolicy

**BackendTLSPolicy** — объект Gateway API, который велит Gateway подключаться к Service по TLS и проверять сертификат бэкенда. Он стал стабильным (канал Standard, `gateway.networking.k8s.io/v1`) в Gateway API 1.4 от 6 октября 2025. Политика лежит в том же namespace, что и Service, на который указывает.

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: BackendTLSPolicy
metadata: {name: secure}
spec:
  targetRefs: [{group: "", kind: Service, name: secure}]
  validation:
    hostname: secure.lab-03-5.svc.cluster.local
    caCertificateRefs: [{group: "", kind: ConfigMap, name: backend-ca}]
```

Политика работает на уровне Service и относится ко всем маршрутам, которые ведут в него. Если нужно зашифровать только один порт, в `targetRefs` добавляют `sectionName` с именем порта Service. Клиентский сертификат Gateway для бэкенда (mTLS в сторону бэкенда) в Gateway API 1.5 задаётся полем `clientCertificateRef` на самом Gateway, а не в политике.

Поля читаются так: `targetRefs` называет Service, `caCertificateRefs` — до 8 ConfigMap с корневыми сертификатами в PEM, `hostname` — имя для SNI и для проверки. Вместо ConfigMap можно задать `wellKnownCACertificates: System`, тогда Gateway доверяет общим корням системы. Поле `subjectAltNames` заменяет проверку по `hostname`: тогда `hostname` служит только для SNI, а имя в сертификате сверяется со списком SAN.

### Ingress и его аннотации

**Ingress** (`networking.k8s.io/v1`) описывает правила в одном объекте: хост, путь, Service и секрет TLS. Контроллер выбирается через **IngressClass** — объект, который связывает Ingress с контроллером. Без контроллера Ingress ничего не делает: он просто лежит в etcd.

Правило Ingress состоит из хоста, списка путей и бэкенда. Тип пути `Exact` требует точного совпадения, `Prefix` сравнивает по сегментам (`/api` совпадает с `/api/orders`, но не с `/apiary`), а `ImplementationSpecific` отдаёт решение контроллеру. Блок `tls` связывает список хостов с секретом, а при пустом `ingressClassName` Ingress достаётся контроллеру, помеченному как класс по умолчанию.

Стандарт Ingress знает только хосты, пути и TLS. Переписывание путей, canary, CORS, лимиты и таймауты контроллеры реализуют через **аннотации** (annotations) — произвольные пары «ключ=значение» в метаданных. У ingress-nginx их сотни, они несовместимы с другими контроллерами и не проверяются API. Опечатка в аннотации не вызывает ошибки, а просто не работает. Из-за аннотаций конвертация не бывает автоматической: каждую нужно перевести или заменить.

## 3. Как этим управлять

Управление сводится к трём действиям: выпустить сертификат для Gateway, настроить продление и перевести маршруты Ingress на Gateway API.

### Выпуск через аннотацию Gateway

**gateway-shim** — часть cert-manager, которая следит за Gateway и сама создаёт Certificate для каждого HTTPS-listener с hostname. Достаточно повесить на Gateway аннотацию `cert-manager.io/cluster-issuer`. Режим включается значением `enableGatewayAPI: true` в конфигурации контроллера; без него аннотация молча игнорируется.

```bash
kubectl -n envoy-gateway-system annotate gateway lab cert-manager.io/cluster-issuer=lab-ca
```

Команда ставит аннотацию с именем ClusterIssuer. Имя Certificate и секрета берётся из `certificateRefs` листенера. Если Certificate нужен вне Gateway (для Ingress, для подов), его пишут вручную с теми же полями.

### Срок и продление

cert-manager продлевает сертификат заранее, чтобы запас успел выпуститься, если CA недоступен. По умолчанию срок сертификата — 90 дней (`duration: 2160h`), а продление начинается за треть срока до окончания, то есть примерно за 30 дней (`renewBefore`). Минимальные значения: срок не меньше 1 часа, `renewBefore` не меньше 5 минут. В статусе Certificate поле `renewalTime` показывает, когда начнётся продление.

При продлении cert-manager создаёт новый CertificateRequest и обновляет тот же Secret. Envoy Gateway подхватывает новый секрет сам, перезапускать поды не нужно. Приложения за Gateway сертификата не видят, а бэкенды с собственным TLS перечитывают его по своим правилам.

### Миграция: порядок без простоя

Миграция строится вокруг одного правила: старый и новый вход работают одновременно, пока трафик переносится по одному хосту. Разберём шаги по порядку.

1. Инвентаризация: список Ingress и аннотаций, которые они используют (команда в §4).
2. Выбор реализации Gateway API: Envoy Gateway, NGINX Gateway Fabric, Istio, Cilium, Traefik или облачный контроллер.
3. Конвертация: `ingress2gateway` создаёт Gateway и HTTPRoute, а остальное дописывается вручную.
4. Параллельный запуск: новый Gateway получает свой внешний адрес, и старый Ingress продолжает работать.
5. Проверка по содержимому ответов, а не только по кодам: маршрут, версия, заголовки, редиректы.
6. Перенос трафика: DNS переключают хост за хостом, начиная с малых весов или тестового имени.
7. Вывод старого входа: удалить Ingress и контроллер, когда по старому адресу перестали приходить запросы.

Параллельный запуск безопасен, потому что оба входа читают одни и те же Service и поды. Общими остаются только сертификаты и квоты. Если оба входа выпускают сертификат для одного имени через ACME, вы быстрее упрётесь в лимиты CA, поэтому для нового входа берите staging-сервер или копируйте существующий секрет.

Новый вход с отдельным адресом даёт мгновенный откат: достаточно вернуть DNS-запись. TTL записи заранее уменьшают, например до 60 секунд, иначе откат растянется на часы.

### ingress2gateway: что переводит и что нет

**ingress2gateway** — инструмент SIG Network, который читает Ingress (из файлов или кластера) и печатает манифесты Gateway API. Версия 1.0 вышла 20 марта 2026 и понимает больше 30 аннотаций ingress-nginx: CORS, regex-пути, перезапись пути, таймауты. Флаг `--emitter` (`envoy-gateway`, `kgateway`, `agentgateway`) добавляет расширения конкретной реализации.

Часть возможностей инструмент не переводит, а только предупреждает.

- **`configuration-snippet`** — произвольный кусок конфигурации nginx. Переводу не подлежит, его переписывают на нативные возможности: именно через сниппеты работала цепочка уязвимостей CVE-2025-1974.
- **`proxy-body-size`** — стандартного эквивалента нет, у реализаций свои объекты политик и свои лимиты по умолчанию.
- **Нормализация URL** — Gateway API её не стандартизует, поведение зависит от реализации.

## 4. Как увидеть состояние

Состояние читается в статусах объектов: у каждого звена цепочки есть свои условия и события.

### Certificate и цепочка выпуска

Certificate описывает готовность одним условием `Ready`. Если оно ложно, смотрят вниз по цепочке: сначала события Certificate, затем CertificateRequest и, для ACME, Order и Challenge.

```bash
kubectl describe certificate shop-localhost-tls -n envoy-gateway-system
kubectl get certificaterequest,order,challenge -A
```

Первая команда показывает условия и события выпуска, вторая сводит объекты цепочки в один список. В событиях видны причины: «issuer не готов», «секрет CA не найден», «ошибка проверки ACME». Для ACME причина чаще всего лежит в Challenge, поэтому читают `status.reason` у него.

Для мониторинга cert-manager отдаёт метрики Prometheus: `certmanager_certificate_expiration_timestamp_seconds` (когда истекает) и `certmanager_certificate_ready_status` (готов ли). Алерт на срок меньше 14 дней ловит сломанное продление раньше, чем сертификат истечёт.

### Gateway, маршрут и политика

Listener показывает в `status.listeners` условия `Programmed`, `Accepted` и `ResolvedRefs`, а также число `attachedRoutes`. Если секрет не найден или доступ к нему запрещён, `ResolvedRefs` становится `False` с причиной `InvalidCertificateRef` или `RefNotPermitted`. BackendTLSPolicy отражает состояние в `status.ancestors[]`: для каждого Gateway-предка свои условия `Accepted` и `ResolvedRefs`.

### Инвентаризация Ingress

Перед миграцией нужен список аннотаций и сколько раз каждая встречается. Команда собирает ключи аннотаций со всех Ingress кластера и считает.

```bash
kubectl get ingress -A -o json | jq '[.items[].metadata.annotations // {} | keys[]]
  | group_by(.) | map({(.[0]): length}) | add'
```

Результат — словарь «аннотация: число Ingress». Каждый ключ нужно сопоставить либо с полем Gateway API, либо с политикой реализации, либо с решением «отказаться». Наличие самого контроллера проверяют так: `kubectl get pods -A --selector app.kubernetes.io/name=ingress-nginx`.

## 5. Что ломается и как найти причину

Поломки делятся на три группы: выпуск сертификата, соединение TLS и перенос маршрутов.

### Выпуск и соединение TLS

Таблица сводит симптом, причину и первую проверку.

| Симптом | Вероятная причина | Что проверить |
|---|---|---|
| Certificate не Ready | ClusterIssuer не готов или нет секрета CA | описание Certificate и события |
| Секрет не создаётся | режим Gateway API выключен, аннотации игнорируются | конфигурация контроллера cert-manager |
| ResolvedRefs=False у listener | секрет в другом namespace без ReferenceGrant | статус Gateway |
| Recv failure, сброс соединения | SNI не совпал с hostname listener | запрос curl с нужным именем через resolve |
| unable to get local issuer | клиент не знает CA | запрос с корнем CA в cacert |
| 503 при BackendTLSPolicy | бэкенд не говорит TLS или CA не тот | статус политики, логи Envoy |
| Challenge в состоянии pending | порт 80 закрыт или нет записи DNS | описание Challenge |

Таблица 1. Поломки TLS на входе и первая проверка для каждой.

Один сброс соединения может значить разное. Envoy обрывает соединение на уровне TLS, если SNI не подошёл ни к одному listener, и в этом случае HTTP-кода нет вообще. Если же TLS прошёл, а ответ пришёл с кодом 5xx, дело в маршруте или бэкенде.

### Что ломается при переезде с Ingress

Ошибки миграции редко видны по кодам 200. Типичные расхождения между ingress-nginx и Gateway API перечислены ниже.

- **Редирект HTTP на HTTPS.** ingress-nginx включал его для Ingress с TLS сам, а в Gateway это явный маршрут `RequestRedirect`.
- **Таймауты.** У ingress-nginx `proxy-read-timeout` равен 60 секундам; у реализации Gateway API дефолт свой, и его задают явно в `timeouts` маршрута.
- **Размер тела.** ingress-nginx по умолчанию пропускает тело запроса до 1 МБ (`proxy-body-size: 1m`), у других прокси лимит иной.
- **Приоритет правил.** canary с заголовком и весами ведёт себя по правилам Gateway API, а не nginx (03-4, ловушка приоритета).
- **Регулярные выражения.** В ingress-nginx пути-regex были регистронезависимыми префиксами, и конвертер сохраняет это конструкцией `(?i)…*`.

Ещё одно расхождение касается имён портов и протоколов бэкенда. Ingress-nginx включал HTTP/2 к бэкенду по аннотации `backend-protocol`, а в Gateway API это поле `appProtocol` у порта Service или политика реализации. Если приложение говорило с бэкендом по gRPC или HTTPS, а аннотацию не заметили, после переноса оно получит открытый HTTP.

После каждого переноса проверяйте распределение запросов по версиям и заголовки ответа, как в 03-4: код 200 не доказывает, что запрос попал в нужный бэкенд.

### Анти-рецепт: ingress-nginx как «временное» решение

Рецепт «поставить ingress-nginx на kind и забыть» устарел с марта 2026. Контроллер больше не получает исправлений. Его уязвимости показательны: CVE-2025-1974 (март 2025, «IngressNightmare») давала выполнение кода через admission webhook контроллера, который имеет доступ ко всем секретам кластера. Если ingress-nginx ещё стоит у вас, закройте доступ к его webhook из сети подов, не публикуйте его в интернет и запланируйте миграцию. Для новых кластеров он не подходит вовсе.

## 6. Пределы и значения по умолчанию

Значения этой части собраны в одном месте, чтобы не искать их по тексту.

### Сертификаты и cert-manager

- Срок Certificate по умолчанию 90 дней, `renewBefore` — треть срока; минимум 1 час и 5 минут.
- Публичные сертификаты ограничены сроком 200 дней с 15 марта 2026 (100 дней с 2027, 47 дня с 2029).
- Secret в Kubernetes не больше 1 МиБ.

### Версия cert-manager и права

В лабораторных стоит cert-manager 1.21.2. Начиная с ветки 1.21 чарт не создаёт Role для токенов собственного ServiceAccount, а агрегированная роль `cert-manager-edit` не разрешает создавать Order и Challenge. Если пользователям нужны эти права, выдайте их отдельной ролью.

### Gateway API и Ingress

- Gateway содержит до 64 listener, а у listener до 64 `certificateRefs`.
- BackendTLSPolicy принимает до 8 ссылок `caCertificateRefs`.
- У Ingress поле `pathType` обязательно: `Exact`, `Prefix` или `ImplementationSpecific`.
- Kubernetes 1.37 (стенд на ней не работает) переводит в GA сертификаты подов (PodCertificateRequest) и ClusterTrustBundle: так можно выдавать подам сертификаты для mTLS без cert-manager.

---

## Лабораторные работы

Все работы идут через Gateway `lab` стенда и используют namespace `lab-03-5`, каталог `~/lab/k8s/03-5` и имя хоста `*.localhost`. Подготовьте namespace и каталог один раз перед первой работой, а в конце каждой работы убирайте за собой.

```bash
kubectl config use-context kind-lab
mkdir -p ~/lab/k8s/03-5
```

### Лабораторная работа 1. TLS на Gateway через cert-manager

**Цель.** Выпустить сертификат для HTTPS-listener Gateway автоматически и проверить его клиентом. Вы установите cert-manager, создадите собственный CA, включите HTTPS на Gateway одной аннотацией и убедитесь, что клиент видит нужного издателя.

**Что понадобится.**

- Стенд 00-1: кластер `kind-lab`, Gateway `lab` в namespace `envoy-gateway-system`, helm 4.
- Образ `localhost:5001/orders-api:2.0` из реестра стенда, образ `curlimages/curl:8.11.1`.
- Доступ к `quay.io` для чарта cert-manager (около 100 МБ образов).
- Около 10 минут на установку и 50 минут на разбор.

**Схема опыта.**

```
хост ──8088──► NodePort 30080 ──► Envoy (listener http:80) ──► Service api ──► поды
клиент в сети kind ──► NodePort 443 ──► Envoy (listener https-shop) ──► Service api

cert-manager (ns cert-manager):
  ClusterIssuer selfsigned ──► Certificate lab-ca ──► ClusterIssuer lab-ca
  Gateway lab (аннотация) ──gateway-shim──► Certificate shop-localhost-tls ──► Secret
```

Схема показывает два входа: открытый на хосте и HTTPS из сети kind. Смотрите на нижнюю цепочку: Certificate появляется из аннотации, без единой строки YAML.

**Риски.** Работа ставит в кластер cert-manager и меняет общий Gateway стенда.

- **Что меняется:** в кластере — namespace `cert-manager`, CRD cert-manager (кластерные объекты) и ClusterIssuer; в Gateway `lab` — одна аннотация и второй listener; в `~/.kube/config` — namespace по умолчанию.
- **Надолго ли:** до уборки; уборка убирает listener, аннотацию, CRD и все объекты.
- **Безопасность:** привилегий на хосте не нужно; закрытый ключ CA живёт в Secret кластера стенда.
- **Влияние на систему:** другие части курса работают, пока Gateway `lab` содержит свой первый listener; rolling-обновление Envoy при смене listener занимает секунды.
- **Откат:** блок «Уборка».

#### Шаг 1. Развернуть приложение за Gateway

Создаём namespace, Deployment `api` из образа orders-api, Service и HTTPRoute для хоста `shop.localhost`. Это обычный маршрут по HTTP; он нужен, чтобы позже повесить на него HTTPS.

```bash
kubectl create ns lab-03-5
kubectl config set-context --current --namespace=lab-03-5
kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata: {name: api}
spec:
  replicas: 2
  selector: {matchLabels: {app: api}}
  template:
    metadata: {labels: {app: api}}
    spec:
      containers:
      - name: api
        image: localhost:5001/orders-api:2.0
        ports: [{name: http, containerPort: 8000}]
        readinessProbe: {httpGet: {path: /ready, port: http}, periodSeconds: 2}
---
apiVersion: v1
kind: Service
metadata: {name: api}
spec:
  selector: {app: api}
  ports: [{name: http, port: 80, targetPort: http}]
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: shop}
spec:
  parentRefs: [{name: lab, namespace: envoy-gateway-system}]
  hostnames: ["shop.localhost"]
  rules: [{backendRefs: [{name: api, port: 80}]}]
EOF
kubectl rollout status deploy/api
```

Разбор команд:

| Часть команды | Значение |
|---|---|
| `create ns lab-03-5` | namespace с именем части |
| `set-context --current --namespace=` | сделать его namespace по умолчанию |
| `readinessProbe … /ready` | Service получит только готовые поды (02-5) |
| `parentRefs: [{name: lab, …}]` | прицепить маршрут к Gateway стенда |
| `hostnames: ["shop.localhost"]` | маршрут отвечает только на это имя |
| `rollout status deploy/api` | ждать готовности обеих реплик |

Результат:

```
namespace/lab-03-5 created
Context "kind-lab" modified.
deployment.apps/api created
service/api created
httproute.gateway.networking.k8s.io/shop created
deployment "api" successfully rolled out
```

Разбор вывода:

1. Namespace создан, а контекст теперь по умолчанию указывает на него.
2. Три объекта созданы одной командой `apply`.
3. Последняя строка значит, что обе реплики прошли проверку готовности.

#### Шаг 2. Установить cert-manager

Ставим cert-manager Helm-чартом версии v1.21.2. Значения лежат в файле: CRD ставятся вместе с чартом, а `enableGatewayAPI: true` включает gateway-shim.

```bash
cat > ~/lab/k8s/03-5/cm-values.yaml <<'EOF'
crds: {enabled: true}
config:
  apiVersion: controller.config.cert-manager.io/v1alpha1
  kind: ControllerConfiguration
  enableGatewayAPI: true
EOF
helm upgrade --install cert-manager oci://quay.io/jetstack/charts/cert-manager \
  --version v1.21.2 -n cert-manager --create-namespace \
  -f ~/lab/k8s/03-5/cm-values.yaml --wait --timeout 5m
helm -n cert-manager list
```

Разбор команд:

| Часть команды | Значение |
|---|---|
| `crds: {enabled: true}` | чарт сам ставит CRD cert-manager |
| `enableGatewayAPI: true` | включить gateway-shim |
| `oci://quay.io/jetstack/charts/cert-manager` | чарт из OCI-реестра |
| `--version v1.21.2` | версия закреплена, без `latest` |
| `--wait --timeout 5m` | ждать готовности подов до 5 минут |

Результат (установка занимала 31 секунду):

```
NAME          NAMESPACE     REVISION  STATUS    CHART                   APP VERSION
cert-manager  cert-manager  1         deployed  cert-manager-v1.21.2    v1.21.2
```

Разбор вывода:

1. Релиз в статусе `deployed`: три Deployment cert-manager готовы, иначе `--wait` завершился бы ошибкой.
2. Версия чарта закреплена, поэтому при повторе работы вы получите ту же установку.

#### Шаг 3. Создать собственный CA

Цепочка из трёх объектов: самоподписанный ClusterIssuer выпускает корневой сертификат `lab-ca`, а второй ClusterIssuer подписывает им остальные. **isCA** (признак корневого сертификата) разрешает подписывать другие.

```bash
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
```

Разбор ключей манифеста:

| Часть манифеста | Значение |
|---|---|
| `selfSigned: {}` | issuer подписывает ключом самого сертификата |
| `isCA: true` | выпускаемый сертификат может подписывать другие |
| `secretName: lab-ca` | куда положить ключ и сертификат |
| `ca: {secretName: lab-ca}` | второй issuer подписывает ключом из этого секрета |
| `wait --for=condition=Ready` | ждать, пока CA будет выпущен |

Результат:

```
clusterissuer.cert-manager.io/selfsigned created
certificate.cert-manager.io/lab-ca created
clusterissuer.cert-manager.io/lab-ca created
certificate.cert-manager.io/lab-ca condition met
```

Разбор вывода:

1. Три объекта созданы, последняя строка подтверждает условие `Ready`.
2. Корень выпущен самоподписанным issuer; он нужен один раз, а дальше все сертификаты подписывает `lab-ca`.

#### Шаг 4. Включить HTTPS на Gateway

Вешаем на Gateway аннотацию с issuer и добавляем второй listener `https-shop` для хоста `shop.localhost`. gateway-shim видит listener и сам создаёт Certificate с именем из `certificateRefs`. Ждём, пока он появится и станет Ready, затем читаем срок.

```bash
kubectl -n envoy-gateway-system annotate gateway lab cert-manager.io/cluster-issuer=lab-ca
kubectl -n envoy-gateway-system patch gateway lab --type=json -p '[{"op":"add",
  "path":"/spec/listeners/-","value":{"name":"https-shop","protocol":"HTTPS","port":443,
  "hostname":"shop.localhost","allowedRoutes":{"namespaces":{"from":"All"}},
  "tls":{"mode":"Terminate","certificateRefs":[{"name":"shop-localhost-tls"}]}}}]'
GW='kubectl -n envoy-gateway-system'
until $GW get certificate shop-localhost-tls 2>/dev/null; do sleep 2; done
$GW wait --for=condition=Ready certificate/shop-localhost-tls
```

Разбор команд:

| Часть команды | Значение |
|---|---|
| `annotate … cluster-issuer=lab-ca` | какой issuer подписывает сертификаты Gateway |
| `"op":"add","path":"/spec/listeners/-"` | добавить listener в конец списка |
| `"protocol":"HTTPS","port":443` | второй вход на порту 443 |
| `allowedRoutes … from: All` | принимать маршруты из любых namespace |
| `"mode":"Terminate"` | расшифровывать TLS на Gateway |
| `until … get certificate` | ждать, пока gateway-shim создаст объект |

Результат:

```
gateway.gateway.networking.k8s.io/lab annotated
gateway.gateway.networking.k8s.io/lab patched
certificate.cert-manager.io/shop-localhost-tls condition met
```

Разбор вывода:

1. Аннотация и патч применились без ошибок.
2. Certificate `shop-localhost-tls` появился без вашего манифеста: его создал gateway-shim.
3. Условие `Ready` значит, что issuer подписал запрос и секрет создан.

Теперь читаем параметры сертификата и состояние нового listener.

```bash
$GW get certificate shop-localhost-tls -o jsonpath=\
'dnsNames={.spec.dnsNames} issuer={.spec.issuerRef.name} notAfter={.status.notAfter} '\
'renewal={.status.renewalTime}{"\n"}'
$GW get gateway lab -o jsonpath='{range .status.listeners[?(@.name=="https-shop")]}'\
'{.name}: attachedRoutes={.attachedRoutes} {range .conditions[*]}{.type}={.status} {end}{"\n"}{end}'
```

Результат:

```
dnsNames=["shop.localhost"] issuer=lab-ca notAfter=2027-01-12T10:10:21Z renewal=2026-12-13T10:10:21Z
https-shop: attachedRoutes=1 Programmed=True …
```

Разбор вывода:

1. В `dnsNames` одно имя из `hostname` listener.
2. Срок 90 дней: от `notAfter` до выпуска ровно столько, а продление `renewal` наступает за 30 дней до конца (13 декабря против 12 января).
3. `attachedRoutes=1`: маршрут `shop` прицепился к новому listener, потому что hostname совпал.
4. `Programmed=True` значит, что Envoy получил конфигурацию с сертификатом.

#### Шаг 5. Проверить TLS клиентом

HTTPS-порт 443 получил случайный NodePort: kind пробрасывает на хост только 30080, поэтому запросы идут из сети kind. Берём корень CA из секрета и проверяем соединение curl'ом в контейнере. В вывод попадают только строки про TLS.

```bash
kubectl -n cert-manager get secret lab-ca -o jsonpath='{.data.ca\.crt}' | \
  base64 -d > ~/lab/k8s/03-5/lab-ca.crt
NP=$(kubectl -n envoy-gateway-system get svc -l gateway.envoyproxy.io/owning-gateway-name=lab \
  -o jsonpath='{.items[0].spec.ports[?(@.port==443)].nodePort}')
IP=$(docker inspect -f '{{.NetworkSettings.Networks.kind.IPAddress}}' lab-control-plane)
docker run --rm --network kind -v ~/lab/k8s/03-5:/w curlimages/curl:8.11.1 -sv \
  --cacert /w/lab-ca.crt --resolve shop.localhost:$NP:$IP \
  https://shop.localhost:$NP/api/orders -o /dev/null 2>&1 | \
  grep -E 'SSL connection|issuer|expire|ALPN'
```

Разбор команд:

| Часть команды | Значение |
|---|---|
| `jsonpath='{.data.ca\.crt}' \| base64 -d` | достать корневой сертификат из секрета |
| `NP=$(…nodePort)` | случайный NodePort порта 443 |
| `IP=$(docker inspect …)` | адрес узла control-plane в сети kind |
| `--cacert` | доверять только нашему CA |
| `--resolve host:порт:адрес` | подставить адрес без DNS |
| `grep -E '…'` | оставить строки про TLS |

Результат:

```
* SSL connection using TLSv1.3 / TLS_AES_256_GCM_SHA384 / x25519 / RSASSA-PSS
* ALPN: server accepted h2
*  subject:
*  expire date: Jan 12 10:10:21 2027 GMT
*  issuer: CN=lab-ca
```

Разбор вывода:

1. Соединение TLS 1.3, шифр AES-256-GCM.
2. ALPN выбрал `h2`: Envoy включил HTTP/2 без настроек.
3. Поле `subject` пустое: cert-manager кладёт имя только в SAN, а CN для серверных сертификатов устарел.
4. Издатель `CN=lab-ca` и срок совпадают со статусом Certificate.

Те же запросы с ошибками показывают границы доверия.

```bash
docker run --rm --network kind curlimages/curl:8.11.1 -s --resolve shop.localhost:$NP:$IP \
  https://shop.localhost:$NP/ -o /dev/null -w '%{http_code} %{errormsg}\n'
docker run --rm --network kind -v ~/lab/k8s/03-5:/w curlimages/curl:8.11.1 -s \
  --cacert /w/lab-ca.crt --resolve other.localhost:$NP:$IP \
  https://other.localhost:$NP/ -o /dev/null -w '%{http_code} %{errormsg}\n'
```

Первая команда идёт без `--cacert`, вторая использует имя `other.localhost`, которого нет ни в одном listener.

Результат:

```
000 SSL certificate problem: unable to get local issuer certificate
000 Recv failure: Connection reset by peer
```

Разбор вывода:

1. Без корня CA клиент отвергает сертификат: код 000 значит, что HTTP-ответа не было.
2. Запрос с чужим SNI Envoy сбрасывает на уровне TLS, потому что ни один listener не подошёл.
3. Оба случая отличаются от 5xx: до HTTP дело не дошло.

#### Шаг 6. Пересоздать секрет (проверка автовосстановления)

Удаляем секрет с сертификатом: cert-manager должен заметить пропажу и выпустить его заново. Результат этого шага ожидаемый, он выведен по документации cert-manager и на стенде не снимался.

```bash
kubectl -n envoy-gateway-system delete secret shop-localhost-tls
kubectl -n envoy-gateway-system wait --for=condition=Ready \
  certificate/shop-localhost-tls --timeout=60s
kubectl -n envoy-gateway-system get secret shop-localhost-tls
```

Ожидаемый результат:

```
secret "shop-localhost-tls" deleted
certificate.cert-manager.io/shop-localhost-tls condition met
NAME                 TYPE                DATA   AGE
shop-localhost-tls   kubernetes.io/tls   2      …
```

Разбор вывода:

1. cert-manager сравнивает Certificate с секретом и при расхождении запускает новый выпуск.
2. В секрете два ключа, `tls.crt` и `tls.key`, и новый возраст.
3. Вывод: продление и восстановление идут одним механизмом, поэтому сертификат переживает потерю секрета.

#### Итог

Что вы узнали:

| Что узнали | Как проверить |
|---|---|
| Сертификат Gateway выпускается по аннотации | `get certificate -n envoy-gateway-system` |
| Срок 90 дней, продление за 30 дней до конца | поля `notAfter` и `renewalTime` |
| Имя сертификата живёт в SAN, а не в CN | пустой `subject` в выводе curl |
| Клиент без CA и с чужим SNI получает разные ошибки | коды 000 и тексты `errormsg` |
| Листенер без секрета или без разрешения не работает | `status.listeners[].conditions` |

#### Уборка

Убираем listener и аннотацию из Gateway, сертификат и секрет, issuer'ы и cert-manager с его CRD, затем namespace и файлы. CRD удаляются отдельно: `helm uninstall` их не трогает. Последняя команда проверяет сквозной сценарий стенда.

```bash
kubectl -n envoy-gateway-system patch gateway lab --type=json -p '[
  {"op":"remove","path":"/spec/listeners/1"},
  {"op":"remove","path":"/metadata/annotations/cert-manager.io~1cluster-issuer"}]'
kubectl -n envoy-gateway-system delete certificate shop-localhost-tls --ignore-not-found
kubectl -n envoy-gateway-system delete secret shop-localhost-tls --ignore-not-found
kubectl delete clusterissuer selfsigned lab-ca
helm -n cert-manager uninstall cert-manager
kubectl delete ns cert-manager
kubectl get crd -o name | grep cert-manager.io | xargs kubectl delete
kubectl config set-context --current --namespace=default
kubectl delete ns lab-03-5
rm -rf ~/lab/k8s/03-5
curl -s -o /dev/null -w '%{http_code}\n' http://orders.localhost:8088/api/orders
```

Разбор: последняя команда должна вернуть `200`, значит, сквозной сценарий стенда цел. Если вы продолжаете с работой 2, не выполняйте `rm -rf` и `delete ns lab-03-5` сейчас, а пересоздайте их в начале работы 2. Удаление CRD удаляет и все Certificate кластера, поэтому делайте это только на стенде.

#### Вопросы для самопроверки

1. Какие объекты создаёт gateway-shim и откуда он знает имя секрета?

<details><summary>Ответ</summary>

Он создаёт Certificate для каждого HTTPS-listener с hostname. Имя секрета берётся из `certificateRefs` листенера, а issuer из аннотации `cert-manager.io/cluster-issuer` на Gateway. Без `enableGatewayAPI: true` в конфигурации контроллера аннотация не действует.

</details>

2. Почему у сертификата в выводе curl пустой `subject`?

<details><summary>Ответ</summary>

cert-manager записывает имена только в расширение SAN. Поле CN для серверных сертификатов устарело, клиенты проверяют SAN, поэтому subject может быть пустым.

</details>

3. Клиент получил `Connection reset by peer` без HTTP-кода. Что это значит?

<details><summary>Ответ</summary>

Envoy оборвал соединение на уровне TLS: SNI клиента не подошёл ни к одному listener. Проверьте имя в запросе и поле `hostname` листенеров.

</details>

4. Когда cert-manager начнёт продление сертификата со сроком 90 дней?

<details><summary>Ответ</summary>

По умолчанию за треть срока до окончания, то есть примерно за 30 дней (через 60 дней после выпуска). Точное время лежит в `status.renewalTime`.

</details>

### Лабораторная работа 2. TLS до бэкенда: BackendTLSPolicy

Эту работу вы выполняете сами, результаты в ней — ожидаемые. Они выведены по документации Gateway API 1.4 и Envoy Gateway, а точные тексты ошибок могут отличаться в вашей версии.

**Цель.** Включить шифрование на участке Gateway → бэкенд и увидеть, что делает политика. Вы запустите бэкенд, который отвечает только по TLS, подключите его без политики (ошибка), добавите BackendTLSPolicy (успех) и сломаете проверку имени.

**Что понадобится.**

- Стенд 00-1 с Gateway `lab`; openssl на хосте.
- Образ `python:3.12-slim` (узлы скачают его при запуске).
- Около 15 минут на подготовку и 45 минут на разбор.
- Cert-manager не нужен: сертификаты выпускает openssl.

**Схема опыта.**

```
curl ──► Gateway lab :80 ──► Envoy ──TLS 2──► Service secure:443 ──► под :8443 (HTTPS)
                              ▲
                  BackendTLSPolicy secure: проверить сертификат по CA из ConfigMap backend-ca,
                  имя для SNI и проверки: secure.lab-03-5.svc.cluster.local
```

Схема показывает только участок до бэкенда: клиентский участок остаётся обычным HTTP, чтобы не смешивать две настройки. Смотрите на связку Service ↔ политика ↔ ConfigMap.

**Риски.** Работа меняет только кластер стенда и общий каталог в `~/lab/k8s`.

- **Что меняется:** namespace `lab-03-5` с подом и Service; в `~/.kube/config` — namespace по умолчанию; в каталоге `~/lab/k8s/03-5` лежат ключи и сертификаты.
- **Надолго ли:** до уборки; уборка удаляет namespace и каталог.
- **Безопасность:** ключи тестовые и живут 30 дней; Gateway `lab` не меняется, маршрут прицепляется к существующему listener.
- **Влияние на систему:** другие хосты Gateway не затрагиваются.
- **Откат:** блок «Уборка».

#### Шаг 1. Выпустить сертификаты бэкенда

Создаём тестовый CA и подписанный им сертификат сервера. Имена в SAN должны совпасть с тем, что потом укажет политика.

```bash
mkdir -p ~/lab/k8s/03-5 && cd ~/lab/k8s/03-5
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 30 \
  -keyout ca.key -out ca.crt -subj "/CN=lab-backend-ca"
openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
  -keyout tls.key -out tls.csr -subj "/CN=secure"
printf 'subjectAltName=DNS:secure.lab-03-5.svc.cluster.local\n' > san.ext
openssl x509 -req -in tls.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 30 \
  -extfile san.ext -out tls.crt
```

Разбор команд:

| Часть команды | Значение |
|---|---|
| `req -x509 … -nodes` | самоподписанный корень без пароля на ключе |
| `-days 30` | срок 30 дней |
| `req -newkey … -out tls.csr` | ключ и запрос на сертификат сервера |
| `san.ext` | расширение SAN с именем Service |
| `x509 -req -CA ca.crt -CAkey ca.key` | подписать запрос ключом корня |

Результат:

```
Certificate request self-signature ok
subject=CN=secure
```

Разбор вывода:

1. Корень `ca.crt` и сервер `tls.crt` с ключом `tls.key` лежат в каталоге.
2. Строки результата зависят от версии openssl, но ошибок быть не должно.

#### Шаг 2. Запустить бэкенд с TLS

Создаём namespace, ConfigMap с корнем для политики, Secret с ключом сервера и под на Python, который слушает HTTPS на порту 8443. Service публикует его как порт 443.

```bash
kubectl create ns lab-03-5
kubectl config set-context --current --namespace=lab-03-5
kubectl create configmap backend-ca --from-file=ca.crt=ca.crt
kubectl create secret tls backend-tls --cert=tls.crt --key=tls.key
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata: {name: server-py}
data:
  server.py: |
    import http.server, ssl
    class H(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            body = b"hello from tls backend\n"
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain("/tls/tls.crt", "/tls/tls.key")
    srv = http.server.HTTPServer(("", 8443), H)
    srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
    srv.serve_forever()
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: secure}
spec:
  replicas: 1
  selector: {matchLabels: {app: secure}}
  template:
    metadata: {labels: {app: secure}}
    spec:
      containers:
      - name: srv
        image: python:3.12-slim
        command: ["python", "/app/server.py"]
        ports: [{name: https, containerPort: 8443}]
        readinessProbe: {tcpSocket: {port: https}, periodSeconds: 2}
        volumeMounts:
        - {name: app, mountPath: /app}
        - {name: tls, mountPath: /tls, readOnly: true}
      volumes:
      - {name: app, configMap: {name: server-py}}
      - {name: tls, secret: {secretName: backend-tls}}
---
apiVersion: v1
kind: Service
metadata: {name: secure}
spec:
  selector: {app: secure}
  ports: [{name: https, port: 443, targetPort: https}]
EOF
kubectl rollout status deploy/secure
```

Разбор ключей манифеста:

| Часть манифеста | Значение |
|---|---|
| `configmap backend-ca` | корень CA, на который сошлётся политика |
| `secret tls backend-tls` | сертификат и ключ сервера |
| `ctx.load_cert_chain(…)` | сервер читает сертификат из смонтированного секрета |
| `HTTPServer(("", 8443), H)` | слушать порт 8443 по HTTPS |
| `readinessProbe tcpSocket` | готовность по открытому порту |
| `port: 443, targetPort: https` | Service принимает 443 и ведёт на порт пода по имени |

Ожидаемый результат:

```
namespace/lab-03-5 created
Context "kind-lab" modified.
configmap/backend-ca created
secret/backend-tls created
configmap/server-py created
deployment.apps/secure created
service/secure created
deployment "secure" successfully rolled out
```

Разбор вывода:

1. Все объекты созданы, а под прошёл проверку готовности.
2. Под отвечает только по TLS, поэтому любой обычный HTTP-запрос к нему закончится ошибкой.

#### Шаг 3. Подключить бэкенд без политики

Создаём маршрут `secure.localhost` на этот Service и обращаемся к нему с хоста. Gateway пока не знает, что бэкенд говорит по TLS, и шлёт открытый HTTP на порт TLS.

```bash
kubectl apply -f - <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: secure}
spec:
  parentRefs: [{name: lab, namespace: envoy-gateway-system}]
  hostnames: ["secure.localhost"]
  rules: [{backendRefs: [{name: secure, port: 443}]}]
EOF
sleep 3
curl -s -o /dev/null -w '%{http_code}\n' http://secure.localhost:8088/
```

Разбор команд:

| Часть команды | Значение |
|---|---|
| `hostnames: ["secure.localhost"]` | отдельное имя для этого опыта |
| `backendRefs … port: 443` | бэкенд — Service secure, порт 443 |
| `curl … :8088/` | запрос через NodePort стенда |
| `-w '%{http_code}'` | вывести только код ответа |

Ожидаемый результат:

```
503
```

Разбор вывода:

1. Маршрут принят, и запрос дошёл до Envoy.
2. Envoy отправил в бэкенд обычный HTTP, а сервер ждал рукопожатия TLS и закрыл соединение, поэтому прокси ответил 503.
3. Тот же код 503 выдаёт любой недоступный бэкенд, поэтому причину ищут в логах Envoy и статусе политики.

#### Шаг 4. Добавить BackendTLSPolicy

Политика велит Envoy подключаться к Service `secure` по TLS и проверять сертификат по корню из ConfigMap `backend-ca`. Имя `hostname` совпадает с SAN сертификата из шага 1.

```bash
kubectl apply -f - <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: BackendTLSPolicy
metadata: {name: secure}
spec:
  targetRefs: [{group: "", kind: Service, name: secure}]
  validation:
    hostname: secure.lab-03-5.svc.cluster.local
    caCertificateRefs: [{group: "", kind: ConfigMap, name: backend-ca}]
EOF
sleep 3
curl -s http://secure.localhost:8088/
```

Разбор ключей:

| Часть манифеста | Значение |
|---|---|
| `targetRefs … kind: Service` | политика действует на этот Service |
| `validation.hostname` | SNI и ожидаемое имя в сертификате |
| `caCertificateRefs … ConfigMap` | корень, которому доверяет Envoy |

Ожидаемый результат:

```
hello from tls backend
```

Разбор вывода:

1. Запрос прошёл по пути клиент → Gateway (HTTP) → бэкенд (TLS).
2. Envoy проверил сертификат сервера по `ca.crt` и убедился, что в SAN есть `hostname`.
3. Маршрут не менялся: TLS включили отдельным объектом политики.

#### Шаг 5. Прочитать статус политики

Политика сообщает о принятии в `status.ancestors`: по одной записи на каждый Gateway, к которому относится Service. Читаем условия.

```bash
kubectl get backendtlspolicy secure \
  -o jsonpath='{range .status.ancestors[*].conditions[*]}{.type}={.status} {.reason}{"\n"}{end}'
```

Ожидаемый результат:

```
Accepted=True Accepted
ResolvedRefs=True ResolvedRefs
```

Разбор вывода:

1. `Accepted=True` значит, что политика допустима и применена.
2. `ResolvedRefs=True` значит, что ConfigMap с корнем найден и прочитан.
3. Если ConfigMap назван неверно, второе условие станет `False` с причиной `InvalidCACertificateRef`.

#### Шаг 6. Сломать проверку имени

Меняем `hostname` на имя, которого нет в SAN. Соединение TLS теперь не пройдёт проверку, хотя корень верный.

```bash
kubectl patch backendtlspolicy secure --type=json \
  -p '[{"op":"replace","path":"/spec/validation/hostname","value":"wrong.example.com"}]'
sleep 3
curl -s -o /dev/null -w '%{http_code}\n' http://secure.localhost:8088/
```

Разбор команд:

| Часть команды | Значение |
|---|---|
| `"path":"/spec/validation/hostname"` | поле с ожидаемым именем |
| `"value":"wrong.example.com"` | имя, которого нет в сертификате |

Ожидаемый результат:

```
503
```

Разбор вывода:

1. Envoy открыл TLS-соединение, но имя `wrong.example.com` не найдено в SAN, и он оборвал рукопожатие.
2. Снаружи это тот же 503, что и в шаге 3, а различие видно в логах Envoy: ищите ошибку проверки сертификата.
3. Верните имя обратной правкой и убедитесь, что снова приходит `hello from tls backend`.

#### Итог

Что вы узнали:

| Что узнали | Как проверить |
|---|---|
| Без политики Gateway шлёт бэкенду открытый HTTP | код 503 в шаге 3 |
| BackendTLSPolicy включает TLS и проверку по CA | ответ `hello…` в шаге 4 |
| Статус политики лежит в `status.ancestors` | условия `Accepted`, `ResolvedRefs` |
| Неверное имя ломает проверку | код 503 в шаге 6 |
| Снаружи ошибки TLS и сети выглядят одинаково | логи Envoy |

#### Уборка

Удаляем namespace, возвращаем namespace по умолчанию и стираем ключи. Gateway `lab` в этой работе не менялся.

```bash
kubectl config set-context --current --namespace=default
kubectl delete ns lab-03-5
rm -rf ~/lab/k8s/03-5
```

Разбор: namespace удаляет под, Service, маршрут, политику, ConfigMap и Secret. Каталог с тестовыми ключами удаляется явно, потому что ключи лежат вне кластера.

#### Вопросы для самопроверки

1. Что делает Gateway с бэкендом, если BackendTLSPolicy нет?

<details><summary>Ответ</summary>

Подключается по открытому HTTP, даже если порт Service ожидает TLS. Для HTTPS-бэкенда это закончится ошибкой соединения и 503.

</details>

2. Чем `hostname` в политике отличается от `subjectAltNames`?

<details><summary>Ответ</summary>

`hostname` задаёт SNI и, если SAN не указаны, имя для проверки сертификата. Если `subjectAltNames` заданы, проверка идёт по ним, а `hostname` используется только как SNI.

</details>

3. Где лежит политика и на что она указывает?

<details><summary>Ответ</summary>

В namespace Service, на который указывает `targetRefs`. Состояние читается в `status.ancestors` по каждому Gateway.

</details>

4. Почему снаружи ошибка проверки сертификата бэкенда выглядит как 503?

<details><summary>Ответ</summary>

Envoy не получил ответ от апстрима и сообщает об этом общим кодом 503. Причину видно в логах Envoy и в статусе политики.

</details>

### Лабораторная работа 3. Из Ingress в Gateway API

Первая половина работы (шаги 1–2) выполнена на стенде, её вывод реальный. Шаги 3–5 с ingress2gateway вы выполняете сами, результаты в них — ожидаемые.

**Цель.** Увидеть, что Ingress без контроллера мёртв, и перевести его на Gateway API. Вы создадите Ingress с аннотацией ingress-nginx, убедитесь, что он не работает, и конвертируете его инструментом ingress2gateway в HTTPRoute.

**Что понадобится.**

- Стенд 00-1 с Gateway `lab`.
- Для шагов 3–5: Go 1.22 или новее (команда `go install`) либо готовый бинарник из релизов проекта.
- Образ `localhost:5001/orders-api:2.0`.
- Около 40 минут.

**Схема опыта.**

```
Ingress shop-legacy (ingressClassName: nginx) ── нет контроллера ──► ADDRESS пуст, трафика нет
        │
        │ ingress2gateway print --providers=ingress-nginx
        ▼
HTTPRoute (parentRefs → Gateway lab) ──► Service api ──► поды   ← работает через Envoy
```

Схема показывает путь миграции: объект Ingress остаётся источником, а рабочий маршрут создаётся рядом.

**Риски.** Работа меняет только namespace `lab-03-5` и каталог `~/lab/k8s/03-5`.

- **Что меняется:** в кластере — namespace с подами и объектами Ingress и HTTPRoute; в `~/.kube/config` — namespace по умолчанию; на хосте — бинарник `ingress2gateway` в `~/go/bin` или в каталоге из PATH.
- **Надолго ли:** до уборки; бинарник остаётся, если вы не удалите его сами.
- **Безопасность:** конвертер только читает входной файл и печатает манифесты; в кластер он ничего не пишет.
- **Влияние на систему:** общий Gateway стенда не меняется.
- **Откат:** блок «Уборка».

#### Шаг 1. Подготовить приложение и Ingress

Создаём namespace, Deployment `api` с Service и Ingress с классом `nginx` и аннотацией ingress-nginx. IngressClass `nginx` в кластере нет, поэтому Ingress ждёт контроллера, которого не будет.

```bash
kubectl create ns lab-03-5
kubectl config set-context --current --namespace=lab-03-5
mkdir -p ~/lab/k8s/03-5
kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata: {name: api}
spec:
  replicas: 2
  selector: {matchLabels: {app: api}}
  template:
    metadata: {labels: {app: api}}
    spec:
      containers:
      - name: api
        image: localhost:5001/orders-api:2.0
        ports: [{name: http, containerPort: 8000}]
        readinessProbe: {httpGet: {path: /ready, port: http}, periodSeconds: 2}
---
apiVersion: v1
kind: Service
metadata: {name: api}
spec:
  selector: {app: api}
  ports: [{name: http, port: 80, targetPort: http}]
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: shop-legacy
  annotations: {nginx.ingress.kubernetes.io/rewrite-target: /}
spec:
  ingressClassName: nginx
  rules:
  - host: legacy.localhost
    http:
      paths:
      - path: /
        pathType: Prefix
        backend: {service: {name: api, port: {number: 80}}}
EOF
kubectl rollout status deploy/api
```

Разбор ключей:

| Часть манифеста | Значение |
|---|---|
| `annotations … rewrite-target: /` | аннотация ingress-nginx: перезапись пути на `/` |
| `ingressClassName: nginx` | выбрать контроллер класса nginx |
| `host: legacy.localhost` | имя хоста правила |
| `pathType: Prefix` | все пути, начинающиеся с `/` |
| `backend.service … number: 80` | Service `api`, порт 80 |

Результат:

```
namespace/lab-03-5 created
Context "kind-lab" modified.
deployment.apps/api created
service/api created
ingress.networking.k8s.io/shop-legacy created
deployment "api" successfully rolled out
```

Разбор вывода:

1. API принял Ingress без проверки, есть ли контроллер и класс.
2. Приложение работает, поэтому дальше можно проверять именно вход.

#### Шаг 2. Убедиться, что Ingress без контроллера мёртв

Смотрим классы Ingress, сам объект и его статус, а затем запрашиваем хост через Gateway стенда.

```bash
kubectl get ingressclass
kubectl get ingress shop-legacy
kubectl get ingress shop-legacy -o jsonpath='{.status}{"\n"}'
curl -s -o /dev/null -w '%{http_code}\n' http://legacy.localhost:8088/
```

Разбор команд:

| Часть команды | Значение |
|---|---|
| `get ingressclass` | какие классы объявили контроллеры |
| `get ingress shop-legacy` | колонка ADDRESS заполняется контроллером |
| `-o jsonpath='{.status}'` | статус объекта целиком |
| `curl … legacy.localhost:8088` | запрос в Envoy стенда по этому имени |

Результат:

```
No resources found
NAME          CLASS   HOSTS              ADDRESS   PORTS   AGE
shop-legacy   nginx   legacy.localhost             80      …
{"loadBalancer":{}}
404
```

Разбор вывода:

1. В кластере нет ни одного IngressClass, поэтому ни один контроллер не взял Ingress.
2. Колонка `ADDRESS` пуста, а статус `{"loadBalancer":{}}` не содержит адресов.
3. Envoy ответил 404: хоста `legacy.localhost` нет ни в одном HTTPRoute.
4. Аннотация `rewrite-target` никого не интересует, потому что читать её некому.

#### Шаг 3. Установить ingress2gateway и сохранить Ingress

Шаги 3–5 вы выполняете сами. Ставим инструмент и сохраняем Ingress в файл, расширенный типичными аннотациями ingress-nginx и секцией TLS: так конвертер покажет и перевод, и предупреждения.

**Карточка инструмента ingress2gateway.**

- **Назначение.** Читает Ingress из файлов или кластера и печатает эквивалентные Gateway и HTTPRoute.
- **Как работает.** Провайдер (`ingress-nginx`) разбирает Ingress и аннотации, общая часть строит объекты Gateway API, эмиттер добавляет расширения реализации.
- **Откуда берёт данные.** Из файлов (`--input-file`) или из кластера (`--namespace`, `--all-namespaces`) через текущий контекст kubectl.
- **Команды для скриптов.** `ingress2gateway print` пишет манифесты в stdout, а предупреждения в stderr, поэтому вывод можно перенаправлять в файл.
- **Частые ошибки.** Принять вывод за готовый: предупреждения нужно читать, а `gatewayClassName` и имена листенеров править. Забыть, что regex и таймауты переводятся приблизительно.
- **Установка.** Ubuntu и Manjaro: `go install github.com/kubernetes-sigs/ingress2gateway@v1.0.0` (бинарник попадёт в `~/go/bin`) или готовый файл со страницы релизов проекта; в Manjaro Go ставится пакетом `go`.

```bash
go install github.com/kubernetes-sigs/ingress2gateway@v1.0.0
export PATH=$PATH:$HOME/go/bin
cd ~/lab/k8s/03-5
cat > ingress.yaml <<'EOF'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: shop-legacy
  namespace: lab-03-5
  annotations:
    nginx.ingress.kubernetes.io/enable-cors: "true"
    nginx.ingress.kubernetes.io/use-regex: "true"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "3"
    nginx.ingress.kubernetes.io/configuration-snippet: |
      more_set_headers "X-Frame-Options: DENY";
spec:
  ingressClassName: nginx
  tls: [{hosts: [legacy.localhost], secretName: legacy-tls}]
  rules:
  - host: legacy.localhost
    http:
      paths:
      - {path: "/users/(\\d+)", pathType: ImplementationSpecific,
         backend: {service: {name: api, port: {number: 80}}}}
EOF
```

Разбор команд:

| Часть команды | Значение |
|---|---|
| `go install …@v1.0.0` | собрать и установить закреплённую версию |
| `export PATH=…/go/bin` | найти бинарник в PATH |
| `enable-cors`, `use-regex` | аннотации, которые конвертер умеет переводить |
| `proxy-read-timeout: "3"` | таймаут чтения 3 секунды |
| `configuration-snippet` | аннотация, которую конвертер не переведёт |
| `tls: [{… secretName}]` | секция TLS, из которой родится HTTPS-listener |

Ожидаемый результат: команды не выводят ничего, кроме возможных сообщений `go: downloading …`, а файл `ingress.yaml` появляется в каталоге.

Разбор: `ingress.yaml` служит входом для конвертера, и кластер при его чтении не затрагивается.

#### Шаг 4. Выполнить конвертацию

Запускаем конвертер на файле: провайдер ingress-nginx, эмиттер Envoy Gateway. Манифесты уходят в файл, предупреждения остаются на экране.

```bash
ingress2gateway print --input-file ingress.yaml \
  --providers=ingress-nginx --emitter envoy-gateway > gateway.yaml
```

Разбор команды:

| Часть команды | Значение |
|---|---|
| `print` | напечатать манифесты Gateway API |
| `--input-file ingress.yaml` | читать Ingress из файла, не из кластера |
| `--providers=ingress-nginx` | понимать аннотации ingress-nginx |
| `--emitter envoy-gateway` | добавить расширения Envoy Gateway |
| `> gateway.yaml` | манифесты — в файл, предупреждения — на экран |

Ожидаемый результат (по описанию выпуска 1.0; точные тексты зависят от версии):

```
… warning: configuration-snippet is not supported; check your implementation
… info: regex paths are case-insensitive prefix matches in ingress-nginx; output uses (?i) and .*
… info: proxy-read-timeout approximated as timeouts.request
```

Разбор вывода:

1. Предупреждение про `configuration-snippet`: заголовок `X-Frame-Options` придётся задавать средствами реализации (в Envoy Gateway — через политики), конвертер его не перенёс.
2. Regex-путь переведён с сохранением регистронезависимости, поэтому в пути появился префикс `(?i)` и окончание `.*`.
3. Таймаут чтения стал `timeouts.request` приблизительно: у nginx он относился к TCP, у Gateway API — к запросу.

#### Шаг 5. Прочитать результат и проверить его на кластере

Смотрим, что получилось в `gateway.yaml`, и проверяем HTTPRoute на сервере без применения. Результат ожидаемый: имена объектов и поля зависят от версии конвертера, поэтому сверяйте их с вашим файлом.

```bash
grep -E '^kind:|name:|gatewayClassName|type: RequestRedirect|timeouts|request:' gateway.yaml
kubectl apply --dry-run=server -f gateway.yaml
```

Разбор команд:

| Часть команды | Значение |
|---|---|
| `grep -E '…'` | оставить виды объектов, имена, редирект и таймаут |
| `--dry-run=server` | проверить объекты на API-сервере, ничего не создавая |

Ожидаемый результат:

```
kind: Gateway
  gatewayClassName: nginx
kind: HTTPRoute
    timeouts: …
kind: HTTPRoute
      - type: RequestRedirect
```

Разбор вывода:

1. Gateway содержит HTTPS-listener на 443 с `certificateRefs: legacy-tls` из секции `tls` Ingress.
2. Один HTTPRoute несёт путь-regex, CORS-фильтр и таймаут, второй выполняет редирект HTTP на HTTPS (код 308): так вёл себя ingress-nginx для Ingress с TLS.
3. `gatewayClassName` взят из `ingressClassName`, то есть `nginx`; такого класса у стенда нет, поэтому Gateway из файла применять нельзя.
4. Правильный путь на стенде: оставить в файле только HTTPRoute и заменить `parentRefs` на Gateway `lab` в `envoy-gateway-system`, а listener `legacy.localhost` добавить в `lab` вручную, как в работе 1.
5. Пробный `--dry-run=server` покажет ошибку на объектах Gateway с неизвестным классом и подтвердит схему HTTPRoute; сам кластер не изменится.

#### Итог

Что вы узнали:

| Что узнали | Как проверить |
|---|---|
| Ingress без контроллера не создаёт трафика | пустой `ADDRESS`, ответ 404 |
| API принимает Ingress без IngressClass | команда `get ingressclass` |
| Конвертер переводит около 30 аннотаций | `print` с провайдером ingress-nginx |
| Сниппеты и размер тела переписываются вручную | предупреждения в stderr |
| Результат требует правки и проверки | `--dry-run=server`, сравнение ответов |

#### Уборка

Удаляем namespace и каталог. Бинарник ingress2gateway остаётся в `~/go/bin`: удалите его, если инструмент больше не нужен.

```bash
kubectl config set-context --current --namespace=default
kubectl delete ns lab-03-5
rm -rf ~/lab/k8s/03-5
rm -f ~/go/bin/ingress2gateway
```

Разбор: namespace удаляет Deployment, Service, Ingress и HTTPRoute. Последняя команда нужна только если вы ставили инструмент через `go install` ради этой работы.

#### Вопросы для самопроверки

1. Что случится, если создать Ingress в кластере без контроллера?

<details><summary>Ответ</summary>

API его примет, но ничего не произойдёт: `ADDRESS` останется пустым, трафик не пойдёт, а аннотации никто не прочитает. Ingress лишь запись в etcd, пока контроллер его не обработает.

</details>

2. Какие возможности ingress-nginx ingress2gateway не переводит?

<details><summary>Ответ</summary>

`configuration-snippet`, `proxy-body-size` и нормализацию URL. Первый нужно переписать на возможности реализации, остальные проверить по её документации и задать лимиты явно.

</details>

3. Как провести миграцию без простоя?

<details><summary>Ответ</summary>

Запустить новый Gateway с отдельным адресом рядом со старым Ingress и проверить ответы по содержимому. Затем переносить DNS по одному хосту с малым TTL для быстрого отката и удалить старый вход, когда запросы на него прекратятся.

</details>

4. Почему `gatewayClassName` из вывода конвертера нельзя применять как есть?

<details><summary>Ответ</summary>

Он берётся из `ingressClassName` и не совпадает с классами вашего кластера. Нужный класс или ссылку на существующий Gateway выбирают вручную.

</details>

---

## → Дальше

Вход в кластер теперь зашифрован, и вы умеете заменять Ingress. Но внутри кластера любой под по умолчанию достаёт до любого другого, а шифрование само не запрещает подключения. Следующая часть, 03-6, вводит NetworkPolicy: правила, которые ограничивают, какие поды могут обращаться друг к другу и что может выходить из namespace. Она идёт после TLS и миграции, потому что политики проверяют на работающем Gateway. Нужно разрешить в приложение только трафик от Envoy и не забыть про DNS в egress.
