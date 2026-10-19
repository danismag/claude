# 12-1. Банк вопросов с собеседований: ~150 вопросов по уровням

> Модуль 12 «Подготовка к собеседованию» · часть 1 из 4 · 🟢🟡🔴
>
> **Как пользоваться.** Закройте правую часть, ответьте вслух за 30–90 секунд, сравните с эталоном. Не получилось — идите по ссылке на часть курса. Эталон — **скелет**: механика, цифра, инструмент. Расширяйте его примером из своих лаб.
>
> Уровни: 🟢 Junior (знать каждому), 🟡 Middle (уметь руками), 🔴 Senior/SRE (объяснить, спроектировать, починить под нагрузкой).

---

## Как отвечать на вопросы по Kubernetes

1. **Через контроллеры и состояние.** Почти любой ответ — «объект в etcd через apiserver → контроллер видит расхождение → приводит фактическое состояние к желаемому». Это показывает понимание, а не заучивание.
2. **Структура**: что это (1 фраза) → как работает (2–3 фразы) → где ломается и как видно (`describe`, события, метрики) → пример со стенда или из работы.
3. **Цифры и дефолты** убеждают:
   - 300 с до эвикции с недоступного узла, 50 с до NotReady;
   - `maxSurge`/`maxUnavailable` 25 %;
   - `terminationGracePeriodSeconds` 30 с;
   - `ndots:5`;
   - квота etcd 2 ГиБ;
   - OOM — код выхода 137;
   - лимит объекта ~1,5 МиБ, ConfigMap/Secret до 1 МиБ;
   - сертификаты kubeadm на 1 год, CA на 10 лет;
   - skew kubelet ≤ 3 минорных версии ниже apiserver.
4. **Уточняйте контекст**: «managed или self-hosted?», «stateless или с данными?», «какой CNI?». Это признак опыта.
5. **Признавайте границы**: «в проде не делал, но на стенде проверял так-то» лучше выдумки.

---

## A. Архитектура (01)

| # | Вопрос | Эталон | Часть |
|---|---|---|---|
| 1 🟢 | Из чего состоит кластер Kubernetes? | Control plane: kube-apiserver (единственный, кто ходит в etcd), etcd (состояние), kube-scheduler (выбор узла), kube-controller-manager (контроллеры). Узлы: kubelet, container runtime (containerd) через CRI, kube-proxy, CNI-плагин. Аддоны: CoreDNS, metrics-server, ingress/gateway. | 01-1 |
| 2 🟢 | Что происходит после `kubectl apply -f deploy.yaml`? | apiserver: аутентификация → авторизация → mutating admission → валидация схемы → validating admission → запись в etcd. Deployment-контроллер создаёт ReplicaSet, тот — поды. Scheduler назначает `nodeName`. Kubelet узла через CRI тянет образ, CNI даёт IP, запускаются контейнеры, пробы. EndpointSlice-контроллер добавляет ready-под в Service. | 01-1 |
| 3 🟢 | Что такое декларативная модель и reconcile loop? | Описываем желаемое состояние (`spec`), контроллеры в цикле сравнивают с фактическим (`status`) и устраняют расхождение. Ручные изменения откатываются, если противоречат `spec` владельца. | 01-1 |
| 4 🟡 | Зачем `resourceVersion` и watch? | Оптимистичная блокировка: обновление с устаревшей версией получает `409 Conflict`. Watch с `resourceVersion` — поток изменений без опроса. Контроллеры строят на этом informer'ы с локальным кэшем. | 01-2 |
| 5 🟡 | Что такое ownerReferences и garbage collection? | Ссылки зависимого объекта на владельца (ReplicaSet → Deployment, Pod → ReplicaSet). При удалении владельца GC удаляет зависимых: `--cascade=background` (по умолчанию), `foreground` (сначала зависимые), `orphan` (оставить). | 01-2 |
| 6 🟡 | Как kubelet запускает контейнер? | Watch подов своего узла → CRI `RunPodSandbox` (pause-контейнер, network namespace, вызов CNI) → `PullImage` → `CreateContainer`/`StartContainer` → пробы → статус в apiserver. Runtime — containerd + runc через shim. | 01-2 |
| 7 🟡 | Чем static pod отличается от обычного? | Kubelet запускает его из файла в `/etc/kubernetes/manifests` без scheduler'а. В API виден только mirror pod (изменить через API нельзя). Так kubeadm запускает control plane. | 01-2, 11-3 |
| 8 🟡 | Что такое CRI, CNI, CSI? | Стандартные интерфейсы: CRI — kubelet ↔ runtime (containerd, CRI-O), CNI — сеть пода (Calico, Cilium, kindnet), CSI — тома (облачные диски, Ceph, local-path). Позволяют менять реализацию без изменения Kubernetes. | 01-2 |
| 9 🔴 | Что будет, если etcd потеряет кворум? | Записи в API невозможны (нужно большинство: из 3 узлов — 2). apiserver отдаёт ошибки или таймауты на запись, чтение зависит от настроек. Работающие поды продолжают работать (data plane независим), но ничего нельзя изменить. Кластер etcd — нечётное число членов: 3 переживают потерю 1, 5 — 2. | 01-3, 11-3 |
| 10 🔴 | Как apiserver масштабируется и что его перегружает? | Stateless — несколько реплик за балансировщиком. Нагрузка: LIST без пагинации и кэша (`resourceVersion=0`), много watch'ей, тяжёлые вебхуки. Защита: API Priority and Fairness (FlowSchema, PriorityLevel), метрики `apiserver_request_duration_seconds`, `apiserver_flowcontrol_rejected_requests_total`. | 01-3 |
| 11 🟡 | Server-side apply vs client-side apply? | SSA: apiserver считает слияние и ведёт `managedFields` — кто какое поле контролирует. Конфликт полей → ошибка или `--force-conflicts`. Client-side — через аннотацию `last-applied-configuration`. SSA лучше для нескольких владельцев (HPA меняет replicas, GitOps — остальное). | 01-3 |
| 12 🟢 | Что такое namespace и что он не изолирует? | Область имён и единица политик (квоты, RBAC, NetworkPolicy, PSA). Не изолирует сеть (без NetworkPolicy), узлы и ядро. Кластерные объекты (Node, PV, StorageClass, CRD) вне namespace. | 01-1 |
| 13 🔴 | Version skew: что с чем совместимо? | kubelet может быть до 3 минорных версий **младше** apiserver (1.33–1.36 при apiserver 1.36), но не новее. kubectl ±1 минор. Control plane обновляется на один минор за раз. | 10-2 |
| 14 🟡 | Почему `kubectl get` может врать о состоянии? | Видим последний записанный `status`. Если kubelet не обновляет статус (узел NotReady), поды показываются `Running`, хотя узла нет. Смотрите условия узла и `lastTransitionTime`. | 11-3 |

## B. Workloads (02)

| # | Вопрос | Эталон | Часть |
|---|---|---|---|
| 15 🟢 | Pod vs контейнер? | Pod — группа контейнеров с общим network namespace (один IP, localhost), томами и жизненным циклом; единица планирования. Обычно один контейнер + sidecar/init. | 02-1 |
| 16 🟢 | Фазы пода и состояния контейнера? | Phase: Pending, Running, Succeeded, Failed, Unknown. Контейнер: Waiting (reason: ContainerCreating, ImagePullBackOff, CrashLoopBackOff, CreateContainerConfigError), Running, Terminated (reason, exitCode). | 02-1, 11-1 |
| 17 🟢 | Что значит CrashLoopBackOff? | Контейнер многократно завершается; kubelet перезапускает с экспоненциальной задержкой 10 с → 20 с → … до 5 минут (сброс после 10 минут успешной работы). Причина — в `lastState` и логах. | 02-1, 11-1 |
| 18 🟢 | Deployment, ReplicaSet, Pod — как связаны? | Deployment управляет ReplicaSet'ами (по одному на ревизию шаблона), ReplicaSet поддерживает число подов по selector. Rollout — создание нового RS и масштабирование старого вниз. | 02-2 |
| 19 🟡 | `maxSurge` и `maxUnavailable` — что значат и дефолты? | По умолчанию 25 %/25 %. Surge — сколько подов сверх `replicas` можно создать, unavailable — сколько может быть неготовыми. `maxUnavailable: 0` + `maxSurge: 1` — без снижения ёмкости, но медленнее и нужна свободная ёмкость. | 02-2 |
| 20 🟡 | Как откатить Deployment и где история? | `kubectl rollout undo deploy/x [--to-revision=N]`. История — старые ReplicaSet'ы (`revisionHistoryLimit`, по умолчанию 10), `kubectl rollout history`. В GitOps откатывают коммитом, иначе контроллер вернёт состояние из Git. | 02-2, 08-1 |
| 21 🟡 | Rollout завис — почему и как узнать? | Новые поды не становятся Ready (проба, образ, ресурсы, квота). `progressDeadlineSeconds` (600 с) → условие `Progressing=False ProgressDeadlineExceeded`. `rollout status` возвращает ошибку — так CI понимает, что деплой не удался. | 02-2 |
| 22 🟢 | StatefulSet vs Deployment? | Стабильные имена (`db-0`, `db-1`), стабильные PVC на под (`volumeClaimTemplates`), упорядоченный запуск и обновление, headless Service для DNS-имён подов. Для БД, кворумных систем, брокеров. | 02-3 |
| 23 🟡 | Что происходит с PVC при удалении StatefulSet? | По умолчанию PVC остаются (данные защищены). `persistentVolumeClaimRetentionPolicy` (`whenDeleted`/`whenScaled`: Retain/Delete) меняет это. | 02-3 |
| 24 🟡 | DaemonSet: зачем и как обновляется? | Под на каждом подходящем узле: агенты логов/метрик, CNI, CSI-ноды. Обновление RollingUpdate с `maxUnavailable` (по умолчанию 1) или OnDelete. Толерирует taints `not-ready`/`unreachable` без срока. | 02-4 |
| 25 🟡 | Job и CronJob: ключевые параметры? | Job: `completions`, `parallelism`, `backoffLimit` (6), `activeDeadlineSeconds`, `ttlSecondsAfterFinished`. CronJob: `schedule`, `concurrencyPolicy` (Allow/Forbid/Replace), `startingDeadlineSeconds`, `timeZone`, история успешных/неудачных. | 02-4 |
| 26 🟢 | Liveness vs readiness vs startup? | Readiness — принимать ли трафик (не прошла → вне Service, без рестарта). Liveness — жив ли процесс (не прошла → рестарт). Startup — задерживает остальные пробы для медленного старта. | 02-5 |
| 27 🟡 | Почему liveness не должна проверять БД? | При падении БД все поды одновременно перезапустятся по кругу — каскад без пользы, долгий старт усугубит инцидент. Liveness — только «процесс завис». Зависимости — в readiness, и то осторожно. | 02-5 |
| 28 🟡 | Как сделать graceful shutdown без 502? | Удаление пода: эндпоинт убирается из Service и одновременно контейнер получает SIGTERM. Чтобы балансировщики успели обновиться — `preStop` sleep 5–10 с (или задержка в приложении), затем обработка SIGTERM: дописать запросы. `terminationGracePeriodSeconds` (30 с) больше всего этого, после него — SIGKILL. | 02-5 |
| 29 🟡 | Init-контейнеры и sidecar-контейнеры в 1.29+? | Init — выполняются последовательно до основных. Нативные sidecar — init-контейнер с `restartPolicy: Always`: стартует до основных, работает всё время пода, останавливается после них. Решает проблему Job, не завершающихся из-за sidecar. | 02-1 |
| 30 🔴 | PodDisruptionBudget: что защищает и что нет? | Ограничивает **добровольные** нарушения (eviction API: drain, autoscaler) — `minAvailable`/`maxUnavailable`. Не защищает от падения узла, OOM, `kubectl delete pod`. PDB с `maxUnavailable: 0` блокирует drain навсегда. | 02-5, 10-3 |
| 31 🔴 | Deployment с 1 репликой и PVC RWO — что будет при rollout? | При RollingUpdate новый под на другом узле не сможет подключить RWO-том (Multi-Attach error) — rollout зависнет. Решение: `strategy: Recreate`, StatefulSet или ReadWriteOncePod с осознанным простоем. | 02-3, 04-2 |
| 32 🟡 | Чем `kubectl rollout restart` отличается от удаления подов? | Restart меняет аннотацию шаблона → обычный rolling update с соблюдением surge/unavailable и проб. Удаление подов — одновременная потеря ёмкости. | 02-2 |

## C. Сеть (03)

| # | Вопрос | Эталон | Часть |
|---|---|---|---|
| 33 🟢 | Сетевая модель Kubernetes — три правила? | Каждый под имеет свой IP; поды общаются между собой без NAT на любых узлах; агенты узла видят поды по их IP. Реализует CNI. | 03-1 |
| 34 🟡 | Как пакет идёт с пода на под другого узла? | veth пары → маршрут узла → оверлей (VXLAN/Geneve) или прямая маршрутизация (BGP, облачные маршруты) → узел назначения → veth пода. В kind (kindnet) — прямые маршруты между узлами в одной docker-сети. | 03-1 |
| 35 🟢 | Типы Service? | ClusterIP (виртуальный IP внутри кластера), NodePort (порт 30000–32767 на каждом узле), LoadBalancer (внешний балансировщик облака/MetalLB), ExternalName (CNAME), headless (`clusterIP: None` — DNS отдаёт IP подов). | 03-2 |
| 36 🟡 | Как работает ClusterIP на уровне kube-proxy? | kube-proxy смотрит Service и EndpointSlice и программирует iptables/nftables (или IPVS) на каждом узле: DNAT с ClusterIP:port на случайный ready-эндпоинт. ClusterIP не принадлежит интерфейсу, не пингуется. В Cilium вместо kube-proxy — eBPF. | 03-2 |
| 37 🟡 | port, targetPort, nodePort, containerPort — разница? | `port` — порт Service, `targetPort` — порт контейнера (число или имя `containerPort`), `nodePort` — порт на узлах, `containerPort` — декларация в поде (на трафик не влияет, но нужна для именованного targetPort). | 03-2, 11-2 |
| 38 🟡 | `externalTrafficPolicy: Local` vs `Cluster`? | Cluster — любой узел принимает и пересылает (лишний хоп, SNAT, теряется IP клиента). Local — только узлы с локальными подами, IP клиента сохраняется, но узлы без подов дропают трафик (на стенде это ломало NodePort, 03-4). | 03-4 |
| 39 🟢 | Как под находит Service по имени? | CoreDNS (Service `kube-dns` 10.96.0.10). В `/etc/resolv.conf` пода — search `<ns>.svc.cluster.local svc.cluster.local cluster.local`. Имя `svc` резолвится в своём ns, `svc.ns` — в чужом. | 03-3, 11-2 |
| 40 🟡 | Что такое `ndots:5` и чем вредит? | Имена с < 5 точками сначала пробуются со всеми search-доменами: внешний `api.example.com` — 3 лишних запроса × A/AAAA. Решение: FQDN с точкой, `dnsConfig` `ndots: 2`, NodeLocal DNSCache. | 03-3, 11-2 |
| 41 🔴 | Задержки DNS кратные 5 с — причина? | Таймаут glibc-резолвера при потере UDP-ответа: гонка conntrack для параллельных A/AAAA с одного сокета, перегрузка CoreDNS, потери. Лечится NodeLocal DNSCache, `single-request-reopen`, масштабированием CoreDNS. | 03-3, 11-2 |
| 42 🟢 | Ingress vs Gateway API? | Ingress — один ресурс, возможности через аннотации контроллера, ingress-nginx снят с поддержки. Gateway API — роли (GatewayClass — провайдер, Gateway — платформа, HTTPRoute — команда), типизированные возможности (веса, заголовки, TLS, межнеймспейсные ссылки через ReferenceGrant). | 03-4 |
| 43 🟡 | Как сделать canary 10 % на Gateway API? | HTTPRoute с двумя `backendRefs` и `weight: 90`/`10`, или по заголовку через `matches.headers`. Проверка — доля ответов новой версии в N запросах. | 03-4 |
| 44 🟡 | Как выдаётся TLS-сертификат для Gateway? | Listener HTTPS с `certificateRefs` на Secret `kubernetes.io/tls`. cert-manager создаёт и продлевает Secret по Certificate (ACME HTTP-01/DNS-01 или свой CA). Продление — за 1/3 срока до истечения (по умолчанию). | 03-4 |
| 45 🟢 | Что такое NetworkPolicy и что по умолчанию? | По умолчанию всё разрешено. Политика, выбравшая под по `podSelector`, переводит его в режим «разрешено только указанное» для своих `policyTypes`. Политики аддитивны — запрещающих правил нет. Работает, только если CNI поддерживает. | 03-5 |
| 46 🟡 | Default deny: что обязательно разрешить? | DNS (UDP+TCP 53 к kube-dns в kube-system) для egress, ingress от Gateway/ingress-контроллера и мониторинга (scrape), egress к БД и внешним API. Без DNS ломается всё по таймауту. | 03-5, 11-2 |
| 47 🟡 | Почему `namespaceSelector` и `podSelector` в одном элементе `from` — не то же, что в двух? | В одном элементе — И (поды с меткой в namespace с меткой), в двух элементах списка — ИЛИ (любые поды из ns или поды с меткой в своём ns). Частая дыра в политиках. | 03-5 |
| 48 🔴 | Как отлаживать сетевую проблему между подами? | Двигаться от пода наружу: `curl podIP:port` из соседнего пода → через ClusterIP → через Service DNS → через Gateway. Проверить EndpointSlice, NetworkPolicy, `kubectl debug` с netshoot (tcpdump в network namespace пода), conntrack/iptables узла. | 11-2 |
| 49 🔴 | Gateway отдаёт 503/504 — как по ответу понять слой? | Мгновенный 503 — нет эндпоинтов (`direct_response` в логе Envoy) или порт закрыт (`UF`, refused). 503 через connect timeout — пакеты режутся (NetworkPolicy). 504 через таймаут маршрута — приложение не ответило (`UT`). 404 `NR` — маршрут не совпал. | 11-2 |
| 50 🟡 | Что такое EndpointSlice и чем лучше Endpoints? | Разбиение эндпоинтов Service на куски по 100. Обновление одного пода не пересылает весь список на все узлы. Условия `ready`/`serving`/`terminating` для graceful-переключений. | 03-2 |
| 51 🔴 | Session affinity и долгие соединения — подводные камни? | `sessionAffinity: ClientIP` — привязка по IP на уровне kube-proxy (за NAT — все клиенты на одном поде). HTTP/2 и gRPC держат одно соединение — L4-балансировка kube-proxy не распределяет запросы, нужен L7 (Gateway, mesh) или клиентская балансировка с headless Service. | 03-2 |
| 52 🟡 | Как получить реальный IP клиента в поде? | `externalTrafficPolicy: Local` (без SNAT) или L7-прокси с `X-Forwarded-For`/PROXY protocol и доверием только к своему прокси. | 03-4 |

## D. Конфигурация и данные (04)

| # | Вопрос | Эталон | Часть |
|---|---|---|---|
| 53 🟢 | ConfigMap vs Secret? | Оба — пары ключ-значение до 1 МиБ. Secret — base64 (не шифрование!), отдельные права, может шифроваться в etcd (EncryptionConfiguration), монтируется в tmpfs. | 04-1 |
| 54 🟡 | Обновится ли конфиг в поде при изменении ConfigMap? | env — нет, только при пересоздании пода. Том — да, через ~1 мин (период синхронизации kubelet + кэш), атомарно через симлинк. `subPath` — никогда. Приложение должно перечитать файл. Практика — хэш конфига в аннотации шаблона (Helm checksum) → rollout. | 04-1 |
| 55 🟡 | Как безопасно хранить секреты в GitOps? | Не класть открытым текстом в Git. Варианты: External Secrets Operator (синхронизация из Vault/облачного хранилища), Sealed Secrets (шифрование ключом контроллера), SOPS (age/KMS) с плагином. Плюс шифрование etcd и минимальные права на Secret. | 04-1, 08-1 |
| 56 🟢 | PV, PVC, StorageClass — как связаны? | PVC — запрос (размер, accessMode, класс). StorageClass — как создавать (provisioner, параметры, reclaimPolicy, bindingMode). PV — фактический том, создаётся динамически под PVC или вручную. | 04-2 |
| 57 🟡 | `WaitForFirstConsumer` — зачем? | PV создаётся после выбора узла подом. Иначе облачный диск появится в случайной зоне, и под не сможет запланироваться (volume node affinity conflict). Для local-path обязательно. | 04-2, 11-1 |
| 58 🟡 | Access modes RWO, RWX, ROX, RWOP? | RWO — монтирование на одном **узле** (несколько подов того же узла могут), RWOP — одним подом, RWX — на многих узлах (NFS, CephFS, EFS), ROX — только чтение многими. Блочные облачные диски — RWO. | 04-2 |
| 59 🟡 | reclaimPolicy Delete vs Retain? | Delete — при удалении PVC том удаляется вместе с данными (дефолт динамических классов). Retain — PV переходит в Released, данные остаются, нужно вручную очистить и привязать. Для важных данных — Retain или снапшоты. | 04-2 |
| 60 🟡 | Как увеличить PVC? | `allowVolumeExpansion: true` в StorageClass → увеличить `spec.resources.requests.storage`. Уменьшать нельзя. Файловая система расширяется онлайн (большинство CSI) или при перезапуске пода. | 04-2 |
| 61 🔴 | Стоит ли запускать БД в Kubernetes? | Зависит (см. «зависит»): да — с оператором (CNPG, Zalando, Percona), локальными или быстрыми сетевыми томами, бэкапами и проверенным восстановлением, PDB, anti-affinity, командой, которая это умеет. Нет — если есть managed-БД и нет компетенции. Deployment для БД — анти-рецепт. | 04-3, 09-1 |
| 62 🟡 | VolumeSnapshot — что даёт и чего не даёт? | Снимок тома средствами CSI (crash-consistent), быстрый откат/клон. Не заменяет бэкап (тот же storage, не консистентен для приложения без заморозки). Для БД — логический/физический бэкап средствами БД. | 04-3 |
| 63 🟢 | emptyDir — где хранится и сколько живёт? | На диске узла (или в памяти `medium: Memory`) на время жизни пода, переживает рестарт контейнера, но не пересоздание пода. Без `sizeLimit` может заполнить диск узла → eviction. | 04-2, 11-3 |
| 64 🔴 | Downward API и projected volumes — зачем? | Передать в под его метаданные (имя, ns, метки, limits) через env или файлы. Projected — объединить в одном томе ConfigMap, Secret, downwardAPI и serviceAccountToken (короткоживущий токен с audience). | 04-1 |

## E. Ресурсы и планирование (05)

| # | Вопрос | Эталон | Часть |
|---|---|---|---|
| 65 🟢 | Requests vs limits? | Requests — гарантия и основа планирования (scheduler суммирует requests на узле против allocatable). Limits — потолок: CPU троттлится (CFS quota), память — OOM kill (137). | 05-1 |
| 66 🟢 | QoS-классы? | Guaranteed (requests = limits для CPU и памяти у всех контейнеров), Burstable (что-то задано), BestEffort (ничего). При нехватке памяти узла первыми выселяются BestEffort, затем Burstable сверх requests. | 05-1 |
| 67 🟡 | CPU limits — ставить или нет? | Зависит: limits дают предсказуемость и защиту соседей, но троттлинг повышает латентность даже при свободных CPU узла (квота за период 100 мс). Частая практика — requests по p95 + без CPU limits для латентных сервисов, limits для batch и мультитенантности. Мониторить `container_cpu_cfs_throttled_periods_total`. | 05-1 |
| 68 🟡 | OOMKilled — где видно и что делать? | `lastState.terminated.reason=OOMKilled`, exitCode 137, событий нет. Причины: лимит меньше рабочего набора, утечка, рост heap (JVM без `-XX:MaxRAMPercentage`). Смотреть `container_memory_working_set_bytes`, поднять лимит или исправить приложение. | 05-1, 11-1 |
| 69 🟡 | LimitRange и ResourceQuota? | LimitRange — дефолты и мин/макс на контейнер/под в namespace. ResourceQuota — суммарный бюджет namespace (requests, limits, число объектов). С квотой на CPU/память под без requests будет отклонён — нужен LimitRange с дефолтами. | 05-1 |
| 70 🟢 | nodeSelector, affinity, taints/tolerations — разница? | nodeSelector/nodeAffinity — под **хочет** на определённые узлы. Taints — узел **отталкивает** поды; tolerations — под разрешает себе такие узлы (но не притягивается к ним). Для выделенных узлов нужно и то, и другое. | 05-2 |
| 71 🟡 | podAntiAffinity vs topologySpreadConstraints? | Anti-affinity — «не рядом с такими же» (required жёстко блокирует при нехватке узлов). Spread — равномерность с допустимым перекосом `maxSkew` по `topologyKey` (узел, зона), `whenUnsatisfiable: DoNotSchedule/ScheduleAnyway`. Для реплик сервиса spread гибче. | 05-2 |
| 72 🟡 | Что такое PriorityClass и preemption? | Приоритет пода: при нехватке ресурсов scheduler вытесняет поды с меньшим приоритетом. Системные компоненты — `system-cluster-critical`/`system-node-critical`. Риск — каскадное вытеснение. | 05-2 |
| 73 🟡 | Как работает HPA? | Каждые 15 с: desired = ceil(current × текущая метрика / целевая). Метрика CPU — от **requests**. Окно стабилизации на уменьшение 300 с. Нужен metrics-server (или адаптер custom/external metrics). | 05-3 |
| 74 🔴 | HPA не масштабирует — причины? | Нет requests (CPU utilization не считается) — `<unknown>`. metrics-server недоступен. Достигнут `maxReplicas`. Поды нового масштаба Pending. Метрика не растёт, потому что узкое место в БД. Конфликт с `replicas` в GitOps (Argo CD откатывает — нужно игнорировать поле или убрать его из манифеста). | 05-3, 08-1 |
| 75 🟡 | VPA — когда и с какими ограничениями? | Рекомендации и автоматическая подстройка requests. Режимы Off/Initial/Recreate/InPlaceOrRecreate (in-place resize в новых версиях). Не совмещать с HPA по той же метрике CPU/памяти. Хорош как источник рекомендаций (`updateMode: Off`). | 05-3 |
| 76 🟡 | KEDA — что добавляет к HPA? | Масштабирование по внешним событиям (очереди, Kafka lag, Prometheus, cron) и до нуля. Создаёт HPA под капотом и активирует с 0 → 1 сам. | 05-3 |
| 77 🟡 | Cluster Autoscaler vs Karpenter? | CA масштабирует группы узлов, когда есть Pending-поды из-за ресурсов, и удаляет недогруженные (с учётом PDB). Karpenter (AWS и др.) подбирает тип узла под конкретные поды, быстрее, консолидирует. Оба не помогут при неверных affinity/зоне PVC. | 05-4 |
| 78 🔴 | Почему узел недогружен, а поды Pending? | Scheduler смотрит requests, а не фактическое потребление: requests завышены → «занято» на бумаге. Плюс фрагментация (свободно 0,5 CPU на каждом из 10 узлов, а нужно 2), taints, affinity, зона тома, лимит подов (110 на узел по умолчанию), лимит томов узла. | 05-1, 05-2 |
| 79 🔴 | Как выбрать requests для сервиса? | По данным: p95–p99 использования CPU и пик рабочего набора памяти за неделю под реальной нагрузкой + запас; рекомендации VPA; нагрузочный тест. Память: request = limit (предсказуемость). Пересматривать после релизов. | 05-1, 05-3 |
| 80 🟡 | Что такое allocatable узла? | Capacity минус `kube-reserved`, `system-reserved` и порог eviction. Именно его scheduler делит между requests. | 05-1 |

## F. Доступ и безопасность (06)

> Часть 06-1 (аутентификация и права) не опубликована — см. 00-plan. Здесь — вопросы по опубликованной 06-2 и смежным частям.

| # | Вопрос | Эталон | Часть |
|---|---|---|---|
| 81 🟢 | Pod Security Admission — уровни и режимы? | Уровни: privileged, baseline, restricted. Режимы на namespace через метки: `enforce` (отклонить), `audit` (запись в audit-лог), `warn` (предупреждение клиенту). Привязка к версии `…-version`. | 06-2 |
| 82 🟡 | Что требует уровень restricted? | `runAsNonRoot: true`, `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]` (разрешено добавить только NET_BIND_SERVICE), `seccompProfile: RuntimeDefault`, без hostPath/hostNetwork/privileged. | 06-2 |
| 83 🟡 | Почему PSA enforce не остановил Deployment, а поды не появились? | PSA проверяет **поды** при создании. Deployment и ReplicaSet создаются, а ReplicaSet получает отказ — ошибка видна в событиях RS (`FailedCreate`), не у Deployment. | 06-2, 11-1 |
| 84 🟡 | Как внедрить restricted без поломки? | Сначала `warn` и `audit` на нужный уровень, `kubectl label --dry-run=server` показывает нарушения существующих подов, исправить манифесты, затем `enforce`. | 06-2 |
| 85 🟡 | securityContext — что настроить в первую очередь? | Не root (`runAsNonRoot`, `runAsUser`), `readOnlyRootFilesystem: true` + emptyDir для временных файлов, drop ALL capabilities, без privilege escalation, seccomp RuntimeDefault. | 06-2 |
| 86 🔴 | Чем PSA отличается от Kyverno/Gatekeeper/ValidatingAdmissionPolicy? | PSA — встроенные фиксированные профили на namespace. Kyverno/Gatekeeper — произвольные политики (реестры, метки, обязательные limits), мутации, генерация, отчёты. ValidatingAdmissionPolicy — встроенные CEL-правила без вебхука. | 06-2, 09-2 |
| 87 🟡 | Почему Secret — не секрет? | base64 — кодирование. Без шифрования в etcd лежит открытым текстом, его видят все с правом `get secrets` в namespace и все, кто может создать под в этом namespace (смонтирует любой Secret). Защита: шифрование etcd (KMS), минимальные права, внешние хранилища. | 04-1 |
| 88 🔴 | Как ограничить, какие образы попадают в кластер? | Политики admission: только свой реестр, запрет `:latest`, проверка подписи (cosign + Kyverno verifyImages / policy-controller), сканирование в CI и в реестре. | 06-2, 09-2 |
| 89 🟡 | Зачем `automountServiceAccountToken: false`? | Не давать приложению токен к API, если он не нужен. Меньше последствий при компрометации контейнера. | 04-1 |
| 90 🔴 | Как проверить безопасность собственного кластера? | Сканеры конфигурации своего кластера: kube-bench (CIS), Kubescape/Trivy k8s (манифесты, образы), отчёты Kyverno, audit-логи apiserver. Регулярно и с ограниченными правами. | 06-2 |

## G. Пакетирование (07)

| # | Вопрос | Эталон | Часть |
|---|---|---|---|
| 91 🟢 | Что такое Helm chart и release? | Chart — пакет шаблонов + `values.yaml` + `Chart.yaml`. Release — установленный экземпляр chart'а с именем в namespace. История ревизий хранится в Secret'ах `sh.helm.release.v1.*`. | 07-1 |
| 92 🟡 | `helm upgrade --install` с `--atomic`/`--wait` — что дают? | `--wait` — ждать готовности ресурсов. `--atomic` (в Helm 4 `--rollback-on-failure`) — при неудаче откатить. Без них CI считает деплой успешным сразу после применения манифестов. | 07-1 |
| 93 🟡 | Релиз в `pending-upgrade` — что делать? | Предыдущая операция прервана (убит CI). `helm history` → `helm rollback <rel> <последняя deployed>`. В крайнем случае — удалить Secret ревизии в состоянии pending. Предотвращение — таймауты, один деплой за раз. | 07-1 |
| 94 🟡 | Как проверить chart до деплоя? | `helm lint`, `helm template` + kubeconform/валидация схемы, `helm diff upgrade` (плагин), `--dry-run=server`, unit-тесты helm-unittest, `values.schema.json`. | 07-1 |
| 95 🟡 | Kustomize: base, overlays, patches? | Base — общие манифесты, overlays — окружения с патчами (strategic merge, JSON 6902), `images`, `replicas`, генераторы ConfigMap/Secret с хэшем в имени (автоматический rollout при изменении). Встроен в `kubectl apply -k`. | 07-3 |
| 96 🔴 | Helm или Kustomize? | Зависит: Helm — дистрибуция стороннего ПО, параметризация, жизненный цикл релиза. Kustomize — свои сервисы и окружения без шаблонов, прозрачный YAML. Часто вместе: сторонние chart'ы через Helm, свои — Kustomize, или Helm + Kustomize post-render. | 07-3 |
| 97 🟡 | Как обновлять сторонний chart (например, БД)? | Зафиксировать версию chart'а и образа, читать changelog/upgrade notes, `helm diff`, тест на стенде, бэкап до обновления. Мажорные версии chart'а часто ломают values или требуют миграции PVC. | 07-2 |
| 98 🟡 | Почему `helm uninstall` не удалил PVC? | PVC из `volumeClaimTemplates` StatefulSet не принадлежат релизу — защищают данные. Удалять вручную осознанно. | 07-2 |
| 99 🟡 | Что такое hooks в Helm и чем они опасны? | Ресурсы с аннотацией `helm.sh/hook` (pre-install, pre-upgrade, …) — миграции, проверки. Не входят в релиз (не удаляются без `hook-delete-policy`). Упавший hook ломает upgrade. В Argo CD маппятся на sync hooks. | 07-1 |
| 100 🔴 | OCI-реестр для chart'ов — зачем? | Хранение chart'ов рядом с образами (`helm push oci://…`), единая аутентификация и подпись, без `index.yaml`. В Helm 4 — основной способ. | 07-1 |

## H. GitOps (08)

| # | Вопрос | Эталон | Часть |
|---|---|---|---|
| 101 🟢 | Что такое GitOps? | Желаемое состояние в Git, агент в кластере (Argo CD, Flux) **тянет** его и непрерывно согласовывает. Изменения — через merge request, откат — revert, аудит — история Git. CI не ходит в кластер. | 08-1 |
| 102 🟡 | Sync status vs health status в Argo CD? | Sync — совпадает ли кластер с Git (Synced/OutOfSync). Health — работает ли (Healthy, Progressing, Degraded, Missing) по правилам для типа ресурса. Synced + Degraded — применилось, но не работает. | 08-1 |
| 103 🟡 | Почему приложение постоянно OutOfSync? | Поле меняется в кластере контроллером или вебхуком (HPA → replicas, мутации, дефолты), или его нормализует apiserver. Решение — `ignoreDifferences`, убрать поле из манифеста, `ServerSideApply`, `RespectIgnoreDifferences`. | 08-1 |
| 104 🟡 | Self-heal и prune — что делают и риски? | Self-heal — возвращает ручные изменения к Git. Prune — удаляет ресурсы, исчезнувшие из Git. Риск prune — случайно удалённый файл удалит ресурс (и PVC!). Защита: `Prune=false` на важных ресурсах, ревью. | 08-1 |
| 105 🟡 | Как продвигать версию между окружениями? | Отдельные каталоги/overlays на окружение; CI или Image Updater обновляет тег в Git для dev; продвижение в stage/prod — merge request. Не ветка на окружение (дрейф веток). | 08-2 |
| 106 🟡 | ApplicationSet — зачем? | Генерировать Application'ы из шаблона по генераторам: список кластеров, каталоги в Git, matrix. Для «одно приложение × N окружений/кластеров» и онбординга команд. | 08-2 |
| 107 🟡 | App-of-apps vs ApplicationSet? | App-of-apps — Application, указывающий на каталог с другими Application (явный список, bootstrap платформы). ApplicationSet — генерация по правилам. Часто: app-of-apps для платформы, ApplicationSet для команд. | 08-2 |
| 108 🔴 | Как откатить в GitOps, если релиз сломал прод? | `git revert` коммита → sync. Ручной `rollout undo` или откат в UI Argo CD без отключения auto-sync перезапишется из Git. Миграции БД должны быть обратно совместимы (expand/contract), иначе откат кода не поможет. | 08-1, 12-3 |
| 109 🔴 | Sync waves и hooks — как упорядочить развёртывание? | Аннотация `argocd.argoproj.io/sync-wave`: ресурсы применяются по волнам с ожиданием health. Hooks PreSync/Sync/PostSync — миграции, smoke-тесты. CRD раньше CR — отдельной волной или `SkipDryRunOnMissingResource`. | 08-2 |
| 110 🟡 | Push-деплой из CI vs pull GitOps — плюсы и минусы? | Push: проще, CI нужен доступ к кластеру (секреты в CI), дрейф не исправляется. Pull: кластер не открыт наружу, непрерывная сверка, аудит в Git; минусы — ещё один компонент, сложнее «императивные» шаги. | 08-1 |

## I. Расширение API (09)

| # | Вопрос | Эталон | Часть |
|---|---|---|---|
| 111 🟢 | CRD и оператор — что это? | CRD — новый тип ресурса в API (схема OpenAPI, версии). Оператор — контроллер, который реализует логику этого ресурса (создаёт поды, сервисы, бэкапы, failover) — знания эксплуатации в коде. | 09-1 |
| 112 🟡 | Валидация в CRD — какие средства? | OpenAPI-схема: типы, `required`, `enum`, `minimum`/`maximum`, `pattern`, `default`. CEL-правила `x-kubernetes-validations` для межполевых проверок. Без вебхуков. | 09-1 |
| 113 🟡 | Что такое подресурс status? | Отдельный эндпоинт `/status`: пользователь меняет `spec`, контроллер — `status`. Изменения `status` через основной объект игнорируются. `observedGeneration` показывает, обработал ли контроллер последний `spec`. | 09-1 |
| 114 🟡 | Чем опасно удаление CRD? | Удаляются **все** объекты этого типа во всех namespace (и, через операторов, связанные ресурсы). Защита — не удалять CRD через prune GitOps, права на CRD только у платформы. | 09-1 |
| 115 🟡 | Mutating vs validating admission webhook? | Mutating — изменяет объект (инъекция sidecar, дефолты), вызываются первыми. Validating — разрешает или отклоняет после мутаций. Настраиваются `failurePolicy`, `timeoutSeconds` (по умолчанию 10, макс 30), селекторы. | 09-2 |
| 116 🔴 | Вебхук упал — что случится с кластером? | При `failurePolicy: Fail` все попадающие под правило запросы отклоняются (на стенде — отказ за 226 мс при отсутствии сервиса, `context deadline exceeded` за ~5 с при молчащем сервере). Если правило охватывает kube-system — можно сломать сам кластер. Защита: исключить системные ns, ≥ 2 реплики, PDB, короткий таймаут, мониторинг `apiserver_admission_webhook_rejection_count`. | 09-2 |
| 117 🟡 | Namespace застрял в Terminating — почему? | Объекты внутри с finalizer'ами, которые некому снять (оператор удалён), или недоступный APIService. `kubectl get ns x -o yaml` → `status.conditions` называет тип и finalizer. Чинить причину; снимать finalizer вручную — осознанно (утечка внешних ресурсов). | 09-2 |
| 118 🔴 | Как оператор CNPG делает failover? | Следит за primary. При потере выбирает реплику с наименьшим лагом, повышает её, переключает Service `-rw` на новый primary, старый после возврата становится репликой. На стенде — новый primary через 5 с, окно ошибок записи ~2,5 с. | 09-1 |

## J. Эксплуатация кластера (10)

| # | Вопрос | Эталон | Часть |
|---|---|---|---|
| 119 🟡 | Как обновить кластер kubeadm? | По одному минору: `kubeadm upgrade plan` → `kubeadm upgrade apply` на первом control-plane → `kubeadm upgrade node` на остальных → kubelet/kubectl по узлам через `drain` → обновление пакетов → `uncordon`. Перед этим — проверка устаревших API, бэкап, аддоны (CNI, CoreDNS). | 10-2 |
| 120 🟡 | Как узнать, что манифесты используют удалённые API? | `kubectl get --raw /metrics \| grep apiserver_requested_deprecated_apis`, pluto/kubent по манифестам и релизам Helm, release notes. Удалённый API — ошибка при apply после обновления. | 10-2 |
| 121 🟡 | `kubectl drain` — что делает и почему может зависнуть? | cordon + выселение подов через eviction API (уважая PDB). Зависает на PDB с нулевым запасом, подах без контроллера (нужен `--force`), emptyDir (`--delete-emptydir-data`). DaemonSet пропускаются с `--ignore-daemonsets`. | 10-3 |
| 122 🟡 | Сертификаты kubeadm — сроки и продление? | Сертификаты компонентов — 1 год, CA — 10 лет. `kubeadm certs check-expiration`, продление при каждом `kubeadm upgrade` или `kubeadm certs renew all` + перезапуск static pods. Клиентский сертификат kubelet ротируется автоматически. | 10-3 |
| 123 🔴 | Что будет, если сертификаты apiserver истекут? | Клиенты (kubectl, kubelet, контроллеры) перестанут доверять, кластер «встанет» для изменений; data plane продолжит работать какое-то время. Продление на узлах control plane, перезапуск компонентов, обновление kubeconfig (admin.conf). Мониторинг сроков — обязательно. | 10-3 |
| 124 🟡 | Managed vs self-hosted Kubernetes? | Managed (EKS, GKE, AKS): control plane, etcd, обновления и SLA у провайдера. Меньше контроля и флагов, платные опции. Self-hosted: полный контроль и ответственность (etcd, сертификаты, обновления). Выбор — по компетенции команды и требованиям. | 10-2 |
| 125 🔴 | Как обновлять узлы без простоя сервисов? | PDB у всех критичных сервисов, ≥ 2 реплики с spread, readiness и graceful shutdown, `drain` по одному узлу (или surge-пул в облаке: новые узлы → перенос → удаление старых), мониторинг ошибок во время процесса. На стенде drain → reboot → uncordon под нагрузкой — 678 запросов без ошибок. | 10-3 |
| 126 🔴 | Что нужно для восстановления кластера после катастрофы? | Регулярные бэкапы состояния кластера и данных приложений, проверенная процедура восстановления, GitOps-репозиторий как источник манифестов, бэкапы томов отдельно, документированный RTO/RPO, учения. Детали процедуры для etcd — в документации kubeadm/etcd (часть 10-1 курса не опубликована). | 12-3 |

## K. Диагностика (11)

| # | Вопрос | Эталон | Часть |
|---|---|---|---|
| 127 🟢 | Методика диагностики «под не работает»? | `get pod -o wide` (STATUS, рестарты, узел) → `describe` (события, Last State) → `logs` (в т.ч. `--previous`) → `get events` → `kubectl debug`. По STATUS понятно, на каком шаге застряли. | 11-1 |
| 128 🟢 | ImagePullBackOff — причины? | Нет тега (`not found`), нет доступа (`401/403`, нет `imagePullSecrets`), лимиты (`429`), реестр недоступен (DNS/TLS/сеть). Текст в `state.waiting.message`. | 11-1 |
| 129 🟡 | Pending — где смотреть? | Событие `FailedScheduling` с причинами по узлам: `Insufficient cpu/memory`, taints, affinity/selector, `unbound PVC`, `volume node affinity conflict`. Нет событий — scheduler не работает. | 11-1, 11-3 |
| 130 🟡 | CreateContainerConfigError? | Нет ConfigMap/Secret или ключа, на который ссылается env/том. Создать объект — под оживёт без пересоздания (после очередной попытки kubelet). | 11-1 |
| 131 🟡 | Под Running 0/1 — что это? | Readiness не проходит — под исключён из Service, рестартов нет. Событие `Unhealthy` с кодом/таймаутом. Проверить путь и порт пробы и зависимости. | 11-1 |
| 132 🟡 | Отладка контейнера без shell? | `kubectl debug -it pod --image=busybox --target=<c>` (эфемерный контейнер в тех же namespace), `kubectl debug pod --copy-to=… -- sleep` (копия с другой командой), `kubectl debug node/…` для узла. | 11-1 |
| 133 🟡 | Код выхода 137, 143, 1, 127, 128? | 137 — SIGKILL (OOM или kill после grace), 143 — SIGTERM (штатная остановка), 1 — ошибка приложения, 127 — команда не найдена (в shell), 128 — StartError (бинарника нет, ошибка runtime). | 11-1 |
| 134 🔴 | Узел NotReady — что происходит дальше и через сколько? | ~50 с (`node-monitor-grace-period`) — Unknown, taints unreachable/not-ready, поды выпадают из Service. 300 с — эвикция и пересоздание. Контейнеры на узле могут продолжать работать. StatefulSet ждёт. | 11-3 |
| 135 🔴 | apiserver недоступен — сайт работает? | Да, data plane независим (на стенде 30/30 запросов). Не работают деплой, масштабирование, замена упавших подов, обновление эндпоинтов. | 11-3 |
| 136 🔴 | Где логи компонентов, когда `kubectl` не работает? | На узле: `journalctl -u kubelet -u containerd`, `crictl ps -a`, `crictl logs`, `/var/log/pods`. Managed — облачные логи control plane (включить заранее). | 11-3 |
| 137 🟡 | Под Evicted — что значит? | Kubelet выселил из-за давления узла (память, диск, PID) или превышения лимита ephemeral-storage. Сообщение в `status.message`. Разобраться с узлом или лимитом, удалить Failed-поды (GC удалит по порогу). | 11-3 |
| 138 🔴 | p99 вырос, p50 в норме — гипотезы? | Проблема в доле запросов: DNS-таймауты 5 с, троттлинг CPU (limits), один плохой под/узел, GC-паузы, медленные запросы к БД, перегруз узла соседями. Метрики по подам/узлам, троттлинг, трассировки. | 11-2, 05-1 |

---

## Вопросы-ловушки

| # | Вопрос | Ловушка → правильный ответ | Часть |
|---|---|---|---|
| 139 🟡 | «Limit памяти — это гарантия памяти?» | Нет. Гарантия — **request** (по нему планируют). Limit — потолок, после него OOM kill. При limit > request узел может переподписаться, и под будет выселен при давлении. | 05-1 |
| 140 🟢 | «Secret шифрует данные?» | Нет, base64. Шифрование — только при настроенном шифровании etcd, плюс права доступа. | 04-1 |
| 141 🟡 | «Liveness проверяет БД — так надёжнее?» | Нет. При падении БД все поды уйдут в рестарты, каскад. Liveness — только «процесс жив». | 02-5 |
| 142 🟡 | «Для БД подойдёт Deployment с PVC?» | Нет: нет стабильной идентичности, rolling update с RWO зависнет (Multi-Attach), риск двух экземпляров. StatefulSet или оператор. | 02-3, 04-3 |
| 143 🟢 | «Под упал — kubelet перенесёт его на другой узел?» | Нет. Kubelet только перезапускает контейнеры на своём узле. Новый под на другом узле создаёт **контроллер** (ReplicaSet и т. п.); «голый» под без контроллера пропадёт навсегда. | 02-1 |
| 144 🟡 | «`kubectl delete pod` в Deployment — под удалён?» | Удалён, но ReplicaSet сразу создаст новый с другим именем. Уменьшить — `scale`. | 02-2 |
| 145 🟡 | «NetworkPolicy deny — запретит трафик?» | Только если CNI поддерживает политики (в Flannel без доп. компонента — нет), и политики аддитивны: запрета нет, есть «разрешено только перечисленное». | 03-5 |
| 146 🟡 | «ClusterIP можно пингануть, чтобы проверить Service?» | Нет: ClusterIP — правило DNAT для TCP/UDP-портов, ICMP на него не отвечает (в iptables-режиме). Проверять `curl`/`nc` по порту. | 03-2 |
| 147 🟡 | «`replicas: 3` — значит, переживём отказ узла?» | Не обязательно: без spread/anti-affinity все три могут быть на одном узле. На стенде единственный Envoy на одном узле дал 6 минут простоя. | 05-2, 11-3 |
| 148 🟡 | «ConfigMap изменили — приложение подхватит?» | env — никогда без пересоздания, том — через ~минуту, если приложение перечитывает, subPath — никогда. | 04-1 |
| 149 🔴 | «PDB защитит от падения узла?» | Нет, только от добровольных выселений через eviction API. | 02-5 |
| 150 🔴 | «HPA по CPU масштабирует по реальной загрузке узла?» | По проценту от **requests** пода, усреднённому по подам. Без requests HPA по CPU не работает. | 05-3 |
| 151 🟡 | «Readiness упала — под перезапустится?» | Нет, только исключится из Service. Перезапуск — от liveness. | 02-5 |
| 152 🔴 | «Ресурсы namespace изолированы — значит, команды не мешают друг другу?» | Без ResourceQuota/LimitRange, NetworkPolicy, PSA и ограничений прав — нет: шумные соседи, сетевой доступ ко всему, общий узел и ядро. | 05-1, 03-5, 06-2 |

## «Зависит, уточню»

Вопросы без единственного ответа. Сильный кандидат называет, **от чего** зависит, и задаёт уточнения.

| # | Вопрос | Что уточнить | Варианты ответа |
|---|---|---|---|
| 153 | Helm или Kustomize? | Своё ПО или стороннее? Сколько окружений? Нужна ли дистрибуция другим? Что умеет команда? | Сторонние — Helm; свои с overlays — Kustomize; оба в связке через Argo CD. (07-3) |
| 154 | БД в Kubernetes или managed? | Есть ли managed у провайдера, RTO/RPO, компетенция, бюджет, требования к данным, latency, число БД. | Managed по умолчанию; в кластере — с оператором, бэкапами и учениями. (04-3, 09-1) |
| 155 | Ставить CPU limits? | Латентный сервис или batch? Мультитенантность? Как настроены requests? Есть ли мониторинг троттлинга? | Requests всегда; limits — для мультитенантных и batch, для латентных — часто без них. (05-1) |
| 156 | Managed или self-hosted кластер? | Облако или on-prem, требования к версиям/флагам, команда, SLA, стоимость. | Managed, если нет особых требований; self-hosted — on-prem и специфика. (10-2) |
| 157 | Один большой кластер или много? | Изоляция (команды, окружения, регуляторика), blast radius, лимиты масштаба, стоимость control plane, инструменты управления флотом. | Минимум prod отдельно от non-prod; дальше по требованиям изоляции. (12-3) |
| 158 | Service mesh нужен? | Требования mTLS, L7-политики, наблюдаемость, ретраи, сколько сервисов, готовность к сложности. | Не по умолчанию; начать с Gateway API, NetworkPolicy, библиотек. Mesh — при реальной потребности. (03-4) |
| 159 | Argo CD или Flux? | UI нужен? Мультикластер, модель доступа, привычки команды, Helm/Kustomize. | Оба зрелые; Argo CD — UI и ApplicationSet, Flux — легче и ближе к Kubernetes-примитивам. (08-1) |
| 160 | Сколько реплик ставить? | Нагрузка, SLO, время старта, зоны/узлы, стоимость, HPA. | ≥ 2 для всего, что обслуживает пользователей, распределить по узлам/зонам; дальше — HPA. (05-2, 05-3) |

---

→ Следующая часть: **12-2. Тренажёры «сломай и почини»** — 18 сценариев на стенде с поломкой, симптомом и решением под спойлерами.
