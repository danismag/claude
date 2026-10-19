# Kubernetes для DevOps: план учебника

> Ветка `kubernetes` · Статус: **написан полностью** (37 частей из 39 + 00-1/00-2 + приложения A–E; 06-1 и 10-1 не опубликованы — §0) · Зависимости: курс Linux (процессы, cgroups, systemd), `networks/` (iptables/nftables, DNS, TLS, балансировка), `git-docker/` (namespaces и cgroups — 02-2, образы и реестры — 02-3/02-8), `cicd/` (orders-api, промоушен по дайджесту — 03-1, GitOps как pull-деплой — 05-3).

---

## 0. Итог производства и навигация

**Отличия от плана:**
- **06-1 «Аутентификация и RBAC» и 10-1 «etcd» не опубликованы.** Генерация текста этих частей дважды блокировалась фильтром безопасности среды агента. По решению заказчика части пропущены. Ссылки на них в других частях заменены пометкой «не опубликована». Темы частично затронуты в 04-1 (Secret, automount токена SA), 06-2, 11-3 §4 (состояние etcd), 12-1, 12-3. Что читать по ним — приложение E.1.
- Вход стенда — `127.0.0.1:8088`: порт 8080 на машине автора занят.
- cert-manager ставится в лабе 03-4, а не `lab-up.sh`. Argo CD и Gitea (08), KEDA (05-3), Bitnami PostgreSQL (07-2), CloudNativePG (09-1) ставятся и удаляются в своих лабах (приложение C.3).
- Стенд обновлён в 10-2 с v1.36.1 до v1.36.5 (`kubeadm upgrade` в kind удался). `lab-up.sh` по-прежнему создаёт 1.36.1 — подходят обе версии.
- 05-4: опыты с давлением на узел ограничены тем, что kind отключает дисковые пороги (11-3 §5). 12-2 — 21 тренажёр вместо ≥ 18; RBAC-тренажёр заменён (06-1 нет).

**Навигация:**

| Модуль | Части |
|---|---|
| 00 Стенд | [00-1 стенд](00-lab/00-1-stand.md) · [00-2 инструменты](00-lab/00-2-tools.md) |
| 01 Архитектура | [01-1](01-architecture/01-1-control-plane.md) · [01-2](01-architecture/01-2-node.md) · [01-3](01-architecture/01-3-api-objects.md) |
| 02 Workloads | [02-1](02-workloads/02-1-pod.md) · [02-2](02-workloads/02-2-deployment.md) · [02-3](02-workloads/02-3-statefulset.md) · [02-4](02-workloads/02-4-daemonset-job-cronjob.md) · [02-5](02-workloads/02-5-probes-shutdown.md) |
| 03 Сеть | [03-1](03-networking/03-1-pod-network-cni.md) · [03-2](03-networking/03-2-service-kube-proxy.md) · [03-3](03-networking/03-3-dns.md) · [03-4](03-networking/03-4-gateway-api-ingress-tls.md) · [03-5](03-networking/03-5-networkpolicy.md) |
| 04 Конфигурация и данные | [04-1](04-config-storage/04-1-configmap-secret.md) · [04-2](04-config-storage/04-2-storage.md) · [04-3](04-config-storage/04-3-postgres-backup.md) |
| 05 Ресурсы и планирование | [05-1](05-resources-scheduling/05-1-requests-limits-qos.md) · [05-2](05-resources-scheduling/05-2-scheduler.md) · [05-3](05-resources-scheduling/05-3-autoscaling.md) · [05-4](05-resources-scheduling/05-4-disruptions-eviction.md) |
| 06 Безопасность | 06-1 — не опубликована · [06-2](06-access-security/06-2-pod-security-admission.md) |
| 07 Пакетирование | [07-1](07-packaging/07-1-helm.md) · [07-2](07-packaging/07-2-helm-third-party.md) · [07-3](07-packaging/07-3-kustomize.md) |
| 08 GitOps | [08-1](08-gitops/08-1-argocd.md) · [08-2](08-gitops/08-2-gitops-at-scale.md) |
| 09 Расширение API | [09-1](09-extending/09-1-crd-operators.md) · [09-2](09-extending/09-2-webhooks-finalizers.md) |
| 10 Эксплуатация | 10-1 — не опубликована · [10-2](10-cluster-ops/10-2-cluster-upgrade.md) · [10-3](10-cluster-ops/10-3-certs-node-maintenance.md) |
| 11 Диагностика | [11-1](11-troubleshooting/11-1-pod-not-working.md) · [11-2](11-troubleshooting/11-2-network-dns.md) · [11-3](11-troubleshooting/11-3-node-control-plane.md) |
| 12 Собеседование | [12-1 банк вопросов](12-interview/12-1-question-bank.md) · [12-2 тренажёры](12-interview/12-2-break-fix-trainers.md) · [12-3 system design](12-interview/12-3-system-design.md) · [12-4 матрица](12-interview/12-4-self-check-matrix.md) |
| Приложения | [A шпаргалки](appendix/A-cheatsheets.md) · [B Manjaro vs Ubuntu](appendix/B-manjaro-vs-ubuntu.md) · [C стенд](appendix/C-lab-stand.md) · [D глоссарий](appendix/D-glossary.md) · [E что читать](appendix/E-reading-list.md) |

**Не проверено в среде агента (⚠️ в тексте):**

| Часть | Что |
|---|---|
| 00-1, B | установка на Ubuntu (стенд проверен на Manjaro); путь с `127.0.0.1` хоста — проверен изнутри docker-сети |
| 00-2 | kubectx/kubens, stern, k9s, krew — не устанавливались |
| 02-3, 02-4 | отдельные сценарии StatefulSet; CronJob «too many missed start times» (нужно ~2 ч) |
| 03-1 | облачные CNI с адресами из VPC (теория) |
| 03-2 | `type: LoadBalancer` (cloud-provider-kind/MetalLB) — задание ★ |
| 03-3 | NodeLocal DNSCache — задание ★ |
| 03-4 | `ingress2gateway` не запускался |
| 03-5 | AdminNetworkPolicy (kindnet не реализует) |
| 04-1 | KMS v2 для шифрования etcd |
| 04-2 | CSI hostpath со снапшотами — задание ★ |
| 04-3 | часть процедуры восстановления |
| 05-3 | custom metrics (Prometheus Adapter), Cluster Autoscaler/Karpenter (в kind нельзя добавлять узлы), KEDA prometheus-скейлер |
| 05-4 | graceful node shutdown (systemd-inhibit в kind) |
| 06-2 | MutatingAdmissionPolicy |
| 07-1, 07-2 | `helm push` в OCI без TLS — задание ★; плагин `helm diff` |
| 08-1, 08-2 | UI Argo CD, генератор `pullRequest`, отдельные поля sync, инструменты секретов (ESO/SOPS/Sealed Secrets) |
| 09-1 | возможности CNPG сверх failover (бэкапы в объектное хранилище и т. п.) |
| 09-2 | недоступный APIService в 1.36 не держит удаление ns — поведение отличается от описанного в литературе |
| 10-2 | pluto/kubent; обновление managed-кластеров |
| 11-2 | panic mode Envoy как причина 504 при NotReady-эндпоинтах; разбор busybox `nslookup` |
| 11-3 | отдельная остановка controller-manager; DiskPressure узла (kind отключает пороги) |
| 12-2 | T21 Argo CD OutOfSync — Argo CD со стенда удалён после 08-2 |
| C | RAM/диск при Argo CD и CNPG — оценка |

---

## 1. Цель и рамки

В работе Kubernetes чаще всего выглядит так: «под не стартует», «после деплоя 502», «сервис не видит базу», «Argo CD показывает OutOfSync», «узел NotReady». Курс учит **быстро находить, на каком звене сломалось** (scheduler, kubelet, сеть, DNS, probes, ресурсы, RBAC), **править чужие манифесты и Helm-чарты** и **проектировать** кластер и поставку в него. На собеседовании Kubernetes — самый большой блок (бэклог): архитектура, workloads, Service/Ingress, probes, requests/limits, ConfigMap/Secret, RBAC, разбор CrashLoopBackOff. Отвечать нужно механикой и цифрами, а не определениями.

Уровни: 🟢 Junior — задеплоить приложение манифестами, прочитать `describe`/`logs`/`events`, понять базовые объекты; 🟡 Middle — probes и graceful shutdown, ресурсы и QoS, Service/DNS/Gateway, Helm и Kustomize, RBAC, Argo CD, диагностика типовых поломок; 🔴 Senior — как устроены control plane и kubelet, планирование и вытеснение, сетевая модель и kube-proxy, etcd и обновления кластера, операторы и admission, мультитенантность, проектирование надёжной поставки.

**Сквозной сценарий курса**: `orders-api` из курса `cicd` (образ из реестра стенда) + PostgreSQL в StatefulSet. Запрос

```
curl http://orders.localhost:8088/api/orders
```

проходит путь: kind-узел (порт 8088 хоста) → Gateway (Envoy) → HTTPRoute → Service → EndpointSlice → под orders-api (probes, ресурсы, ConfigMap/Secret) → Service postgres → под StatefulSet → PVC. Каждая часть ломает или улучшает одно звено этого пути.

**Стенд** (00-1), всё в Docker на одной машине (ориентир: 16 ГБ RAM, около 5 ГБ под стенд, 20 ГБ диска):

| Компонент | Что | Роль |
|---|---|---|
| Кластер | **kind 0.32**, Kubernetes **1.36.1**, containerd 2.3.1: `lab-control-plane` + `lab-worker`, `lab-worker2`, `lab-worker3` | несколько узлов — для scheduling, drain, PDB, DaemonSet, отказа узла; кластер пересоздаётся за ~45 с (проверено) |
| Реестр | `registry:2` на `localhost:5001`, подключён к узлам kind | imagePullPolicy, ImagePullBackOff, обновление по дайджесту |
| Вход | **Gateway API** + Envoy Gateway, порт узла → `127.0.0.1:8088` | ingress-nginx в марте 2026 закончил сопровождение — разбирается как наследие и миграция (03-4) |
| Дополнения | metrics-server (с `--kubelet-insecure-tls`), local-path-provisioner (встроен в kind); cert-manager — ставится в лабе 03-4 | `kubectl top`, HPA, PVC, TLS |
| GitOps | Argo CD + Gitea внутри кластера (только модуль 8) | GitLab из `cicd` весит ~4 ГБ, для GitOps нужен только Git |

Запуск — `lab/lab-up.sh` (кластер + реестр + дополнения не поднимаются одной командой), уборка — `lab/lab-down.sh`. Каждая лаба работает в своём namespace `lab-NN-M` и удаляет его в конце. Стенд курса `cicd` на время этого курса выключен (`cicd/appendix/C`).

Особенность kind, которая влияет на лабы: узлы — контейнеры на одном хосте, поэтому **каждый узел сообщает полную память и все CPU хоста** (проверено: `memory: 16315248Ki`, `cpu: 12` у каждого из четырёх узлов), а пороги eviction в kubelet kind отключены. Опыты с нехваткой памяти на узле (05-4) делаются через `system-reserved`/`evictionHard` в конфиге узла — это оговаривается в части.

---

## 2. Структура

```
kubernetes/
  00-plan.md
  00-lab/00-1-stand.md              стенд: kind 1+3, реестр, Gateway, metrics-server; orders-api; проверка; уборка
  00-lab/00-2-tools.md              kubectl (контексты, -o jsonpath/custom-columns, explain, -v=8), k9s, stern, kubectx/kubens, krew, kubectl debug
  01-architecture/01-1 … 01-3
  02-workloads/02-1 … 02-5
  03-networking/03-1 … 03-5
  04-config-storage/04-1 … 04-3
  05-resources-scheduling/05-1 … 05-4
  06-access-security/06-1 … 06-2
  07-packaging/07-1 … 07-3
  08-gitops/08-1 … 08-2
  09-extending/09-1 … 09-2
  10-cluster-ops/10-1 … 10-3
  11-troubleshooting/11-1 … 11-3
  12-interview/12-1 … 12-4
  appendix/A-E
  lab/lab-up.sh, lab/lab-down.sh
```
Итого 39 частей + 00-1/00-2 + приложения.

---

## 3. Модуль 1. Архитектура (3 части)

| Часть | Содержание по уровням | 🔧 Лаба | 🔥 Кейс | 💼 Ключевые вопросы |
|---|---|---|---|---|
| **01-1 Control plane и путь запроса** | 🟢 компоненты: kube-apiserver, etcd, scheduler, controller-manager, kubelet, kube-proxy; декларативная модель «желаемое vs фактическое». 🟡 путь `kubectl apply` → authn/authz/admission → etcd → watch → контроллеры → scheduler → kubelet; reconcile loop, resourceVersion, optimistic concurrency (409 Conflict). 🔴 watch и informers, list/watch нагрузка на apiserver, APF (priority & fairness), leader election, что происходит при недоступности etcd или apiserver (работающие поды живут) | Ключ объекта в etcd (`etcdctl get /registry/...`); остановить kube-scheduler (static pod) — новые поды Pending, старые работают; `kubectl -v=8` — реальные HTTP-запросы | «Упал control plane — прод работает, но деплой и автоскейлинг встали» | Что произойдёт при `kubectl apply`? Что будет с подами, если упал apiserver? Зачем etcd? |
| **01-2 Узел: kubelet, CRI, CNI, kube-proxy** | 🟢 что делает kubelet, container runtime (containerd), pause-контейнер. 🟡 CRI и `crictl`, CNI-плагин и IP пода, static pods (`/etc/kubernetes/manifests`), cgroup-иерархия kubepods (QoS-слайсы), статусы узла (Ready, pressure), lease и `node-monitor-grace-period`. 🔴 PLEG, image GC, логирование контейнеров (`/var/log/pods`, ротация), как kubelet считает ресурсы узла (capacity/allocatable/reserved) | `crictl ps/inspect` на узле kind; найти cgroup пода; удалить static pod через файл; остановить kubelet → узел NotReady (замер: `node-monitor-grace-period`, 50 с в новых версиях) и вытеснение подов через 300 с (tolerations по умолчанию) | «Узел NotReady, а контейнеры на нём работают» | Что такое pause-контейнер? Как kubelet узнаёт о подах? Через сколько поды уедут с упавшего узла? |
| **01-3 API-объекты и kubectl под капотом** | 🟢 apiVersion/kind/metadata/spec/status, labels/selectors, annotations, namespaces. 🟡 `kubectl explain`, client-side vs server-side apply, field managers, `last-applied-configuration`, ownerReferences и каскадное удаление, finalizers. 🔴 API groups/versions и удаление API (deprecation policy), subresources (`status`, `scale`, `resize`), conflicts в SSA, garbage collector (foreground/background/orphan) | SSA конфликт двух менеджеров; удаление Deployment с `--cascade=orphan`; объект, висящий на finalizer | «`kubectl apply` затирает изменения HPA в `replicas`» | Чем apply отличается от create/replace? Что такое finalizer? Как работает каскадное удаление? |

## 4. Модуль 2. Workloads (5 частей)

| Часть | Содержание по уровням | 🔧 Лаба | 🔥 Кейс | 💼 Ключевые вопросы |
|---|---|---|---|---|
| **02-1 Pod** | 🟢 под как единица планирования, несколько контейнеров, фазы и состояния контейнеров. 🟡 init-контейнеры, нативные sidecar (`restartPolicy: Always` в initContainers), restartPolicy, CrashLoopBackOff и back-off (10 с → удвоение → 5 мин, сброс после 10 мин работы), `terminationMessagePath`, коды выхода. 🔴 жизненный цикл в kubelet, ephemeral containers, downward API, порядок старта/остановки sidecar | CrashLoopBackOff с замером интервалов; sidecar переживает main; init с ожиданием БД | «Под в CrashLoopBackOff без логов — упал до записи в stdout» | Что такое CrashLoopBackOff? Зачем init-контейнер? Чем sidecar отличается от init? |
| **02-2 Deployment и ReplicaSet** | 🟢 replicas, selector, template, `rollout status/undo/history`. 🟡 стратегии RollingUpdate/Recreate, maxSurge/maxUnavailable, `minReadySeconds`, `progressDeadlineSeconds`, `revisionHistoryLimit`, pod-template-hash. 🔴 почему selector неизменяем, rollout с неготовыми подами, pause/resume, откат образа по дайджесту, связь с HPA | Rolling update orders-api с замером ошибок под нагрузкой; зависший rollout (плохой образ) и `progressDeadlineSeconds`; откат | «Деплой “успешен” по CI, в кластере старые поды» — `rollout status` не ждали | Как работает rolling update? Как откатиться? Что даёт maxSurge=0? |
| **02-3 StatefulSet** | 🟡 стабильные имена и DNS (headless Service), `volumeClaimTemplates`, порядок создания/удаления, `podManagementPolicy`. 🔴 partition rollout, PVC не удаляются (`persistentVolumeClaimRetentionPolicy`), StatefulSet vs оператор для БД | PostgreSQL в StatefulSet, удаление пода — тот же PVC; scale down — PVC остался | «Удалили StatefulSet, пересоздали — данные на месте, а место кончилось» | Чем StatefulSet отличается от Deployment? Зачем headless Service? |
| **02-4 DaemonSet, Job, CronJob** | 🟢 DaemonSet — по поду на узел, Job/CronJob. 🟡 `backoffLimit`, `activeDeadlineSeconds`, `ttlSecondsAfterFinished`, `completions/parallelism`, `concurrencyPolicy`, `startingDeadlineSeconds`, часовой пояс CronJob. 🔴 indexed jobs, podFailurePolicy, DaemonSet и taints (tolerations для control-plane), maxSurge у DaemonSet | CronJob с Forbid и долгим запуском; Job с podFailurePolicy; DaemonSet на всех узлах, включая control-plane | «CronJob бэкапа молча не запускался неделю» | Как ограничить время Job? Что значит concurrencyPolicy? |
| **02-5 Probes и graceful shutdown** | 🟢 liveness/readiness/startup — что каждая делает. 🟡 параметры и дефолты (period 10 с, timeout 1 с, failureThreshold 3), readiness и endpoints, startupProbe для медленного старта, SIGTERM → `terminationGracePeriodSeconds` 30 с → SIGKILL, preStop. 🔴 гонка «под уже удалён из endpoints или ещё нет» и 502 при деплое, liveness, зависящая от БД (каскадный рестарт), PID 1 и сигналы (ссылка git-docker 02-4) | 502 при rolling update без preStop → 0 ошибок с preStop sleep; liveness на БД роняет все поды | «Каждый деплой даёт всплеск 502» | Разница liveness и readiness? Почему нельзя проверять БД в liveness? Как сделать graceful shutdown? |

## 5. Модуль 3. Сеть (5 частей)

| Часть | Содержание по уровням | 🔧 Лаба | 🔥 Кейс | 💼 Ключевые вопросы |
|---|---|---|---|---|
| **03-1 Сеть подов и CNI** | 🟢 у каждого пода свой IP, поды видят друг друга без NAT. 🟡 CNI (kindnet, Calico, Cilium), podCIDR узла, маршруты между узлами, MTU и оверлеи (ссылки на `networks`). 🔴 eBPF-датаплейн, IPAM и исчерпание адресов, hostNetwork/hostPort | Трассировка пакета под → под на разных узлах (`ip route`, `tcpdump` на veth) | «Новые поды не получают IP: кончился podCIDR» | Как под на одном узле достучится до пода на другом? Что делает CNI? |
| **03-2 Service и kube-proxy** | 🟢 ClusterIP, NodePort, LoadBalancer, selector → endpoints. 🟡 EndpointSlice, `targetPort` по имени, headless, sessionAffinity, externalTrafficPolicy и сохранение IP клиента, kube-proxy в режимах iptables/nftables/ipvs. 🔴 conntrack и UDP, топологическая маршрутизация (trafficDistribution), масштаб iptables-правил | Service без endpoints (опечатка в selector, порт); правила kube-proxy в nftables на узле; externalTrafficPolicy Local | «Service есть, curl висит — selector не совпал» | Как Service находит поды? Что делает kube-proxy? Чем NodePort отличается от LoadBalancer? |
| **03-3 DNS в кластере** | 🟢 имена `svc.namespace.svc.cluster.local`. 🟡 CoreDNS, `resolv.conf` пода, `ndots:5` и лишние запросы, dnsPolicy. 🔴 задержки 5 с (conntrack race, A/AAAA), NodeLocal DNSCache, кэш и TTL | Посчитать запросы к CoreDNS для внешнего имени с ndots:5 и с FQDN; сломать CoreDNS | «Каждый запрос во внешний API на 5 с дольше» | Как резолвится имя сервиса? Что такое ndots и чем он вреден? |
| **03-4 Gateway API, Ingress и TLS** | 🟢 зачем L7-вход в кластер. 🟡 Gateway API: GatewayClass/Gateway/HTTPRoute, роли (платформа vs приложение), маршрутизация по хосту/пути, веса для canary; Ingress и аннотации контроллеров; cert-manager (Issuer, Certificate, ACME). 🔴 завершение сопровождения ingress-nginx (март 2026) и миграция на Gateway API, TLS passthrough, ReferenceGrant между namespaces | Envoy Gateway: HTTPRoute для orders-api, canary 90/10 весами с замером; сертификат от cert-manager | «Ingress-контроллер сняли с поддержки — что делать с 200 Ingress-объектами» | Ingress vs Gateway API? Как выкатить canary средствами Gateway? |
| **03-5 NetworkPolicy** | 🟡 default deny, ingress/egress, селекторы по namespace/pod, DNS в egress. 🔴 политики не работают без поддерживающего CNI, порядок применения (аддитивность), AdminNetworkPolicy, отладка «почему не проходит» | Default deny в namespace orders → разрешить только из Gateway; забытый egress на DNS | «Включили default deny — всё сломалось через минуту, когда истёк DNS-кэш» | Как изолировать namespace? Почему после default deny не работает DNS? |

## 6. Модуль 4. Конфигурация и данные (3 части)

| Часть | Содержание по уровням | 🔧 Лаба | 🔥 Кейс | 💼 Ключевые вопросы |
|---|---|---|---|---|
| **04-1 ConfigMap и Secret** | 🟢 env vs volume, `envFrom`. 🟡 обновление: env не меняется, volume обновляется (~1 мин, кроме subPath), перезапуск по хэшу конфига, immutable. 🔴 Secret — base64, не шифрование; шифрование в etcd (EncryptionConfiguration), кто может читать Secret (RBAC `get`/`list`), внешние секреты (ESO, CSI) — мост в `security` | Поменять ConfigMap — env не изменился, файл изменился через N секунд, subPath не изменился; прочитать Secret из etcd до и после шифрования | «Поменяли конфиг, ничего не произошло — поды не перезапускались» | Secret безопасен? Как подхватить новый конфиг? Почему subPath не обновляется? |
| **04-2 Хранилище: PV, PVC, StorageClass, CSI** | 🟢 том как каталог пода, emptyDir, PVC. 🟡 PV/PVC/StorageClass, access modes (RWO/RWX/RWOP), reclaimPolicy, `WaitForFirstConsumer`, расширение тома. 🔴 CSI (controller/node), привязка к зоне, снапшоты, ephemeral volumes | PVC в local-path; под переехал — данные остались на старом узле (Pending); reclaimPolicy Delete vs Retain | «Под с PVC не стартует после drain: том привязан к узлу» | PV vs PVC? Что значит WaitForFirstConsumer? |
| **04-3 Данные в кластере: PostgreSQL, бэкап, восстановление** | 🟡 StatefulSet PostgreSQL для orders-api, бэкап `pg_dump` CronJob'ом в объектное хранилище/том, проверенное восстановление. 🔴 когда БД в Kubernetes оправдана, операторы (CloudNativePG — 09-1), снапшоты томов vs логический бэкап, RPO/RTO | Бэкап CronJob → удалить данные → восстановить и проверить `curl .../api/orders` | «Бэкапы были, восстановиться не смогли — никто не проверял» | Как бэкапить БД в Kubernetes? Стоит ли держать БД в кластере? |

## 7. Модуль 5. Ресурсы и планирование (4 части)

| Часть | Содержание по уровням | 🔧 Лаба | 🔥 Кейс | 💼 Ключевые вопросы |
|---|---|---|---|---|
| **05-1 Requests, limits и QoS** | 🟢 что такое requests и limits, единицы (m, Mi). 🟡 requests → планирование и `cpu.weight`, limits → `cpu.max` и `memory.max`; QoS Guaranteed/Burstable/BestEffort и `oom_score_adj`; OOMKilled 137; троттлинг CPU; LimitRange и ResourceQuota. 🔴 почему CPU limit вредит задержкам, где считается троттлинг, `memory.oom.group`, in-place resize, ephemeral-storage, overcommit, CPU в контейнере (`nproc`) | **пробная часть — написана**: cgroup трёх QoS-классов, OOMKilled, троттлинг 93 → 500 мс, квота и LimitRange, resize без рестарта, вытеснение по диску | «После добавления CPU limit p99 вырос в 5 раз, а загрузка CPU 20%» | Чем requests отличаются от limits? Что такое QoS? Что будет при превышении лимита памяти и CPU? |
| **05-2 Scheduler** | 🟢 nodeSelector. 🟡 node/pod affinity и anti-affinity, taints и tolerations, topologySpreadConstraints, PriorityClass и preemption. 🔴 фильтрация и оценка (framework), почему под Pending: читать сообщение scheduler'а, descheduler, планирование по зонам | Разнести реплики по узлам (spread vs anti-affinity), taint узла, приоритетный под вытесняет обычный | «Все 3 реплики на одном узле — узел упал, сервис лежит» | Taint vs affinity? Как разнести реплики по зонам? Что такое preemption? |
| **05-3 Автоскейлинг** | 🟡 HPA (CPU/memory/custom), формула, стабилизация (scale down 5 мин), metrics-server. 🔴 VPA и in-place, KEDA (очереди, cron), Cluster Autoscaler/Karpenter (⚠️ в kind — только теория), связка requests ↔ HPA ↔ CA | HPA по CPU под нагрузкой: от 1 до N реплик, время реакции, обратное масштабирование | «HPA не масштабирует — у подов нет requests» | Как работает HPA? Почему HPA не видит метрики? HPA vs VPA? |
| **05-4 Disruptions: PDB, drain, eviction** | 🟡 drain/cordon, PodDisruptionBudget, добровольные и недобровольные прерывания. 🔴 eviction по давлению на узле (memory.available, nodefs), soft/hard пороги, порядок вытеснения по QoS и usage, graceful node shutdown | Drain узла с PDB minAvailable=2; drain, который не проходит; eviction по памяти с настроенным порогом в kind | «Обновление узлов зависло — PDB не даёт выселить единственную реплику» | Что такое PDB? Почему drain завис? Кого kubelet вытесняет первым? |

## 8. Модуль 6. Доступ и безопасность (2 части)

| Часть | Содержание по уровням | 🔧 Лаба | 🔥 Кейс | 💼 Ключевые вопросы |
|---|---|---|---|---|
| **06-1 Аутентификация и RBAC** — ⚠️ не опубликована (§0) | 🟢 kubeconfig, контексты, пользователи vs ServiceAccount. 🟡 Role/ClusterRole/Binding, `kubectl auth can-i --as`, токены SA (bound, TTL), automount. 🔴 эскалация через RBAC (`escalate`, `bind`, `create pods` = доступ к секретам namespace), OIDC для людей, аудит-лог | SA с правом только на чтение подов; `can-i` матрица; под с SA читает API; создать pod = прочитать Secret | «Дали CI право `create pods` в namespace — он прочитал все секреты» | Role vs ClusterRole? Как проверить права? Что опасного в праве create pods? |
| **06-2 Pod Security и admission** | 🟡 securityContext (runAsNonRoot, readOnlyRootFilesystem, capabilities, seccomp), Pod Security Standards и Admission (enforce/warn/audit). 🔴 ValidatingAdmissionPolicy (CEL), MutatingAdmissionPolicy, Kyverno/OPA для политик образов (мост в `security`) | Namespace с `restricted` — какие поля нужны поду; VAP «запрет :latest» | «Под с privileged и hostPath / — root на узле» | Что такое Pod Security Standards? Как запретить latest? |

## 9. Модуль 7. Пакетирование (3 части)

| Часть | Содержание по уровням | 🔧 Лаба | 🔥 Кейс | 💼 Ключевые вопросы |
|---|---|---|---|---|
| **07-1 Helm: чарты и релизы** | 🟢 chart, values, release, `install/upgrade/rollback/uninstall`. 🟡 шаблоны (Go templates, `include`, `tpl`, `required`), `helm template/lint/diff`, хранение релизов в Secret, `--atomic/--wait`, hooks. 🔴 Helm 4 (на стенде 4.2.2): отличия от Helm 3, server-side apply, OCI-реестры чартов, ловушка «упавший upgrade, release в pending-upgrade» | Чарт для orders-api, upgrade с ошибкой и откат; release, застрявший в pending | «`helm upgrade` прервали — следующий upgrade: another operation is in progress» | Как устроен Helm-релиз? Как откатиться? Что делать с pending-upgrade? |
| **07-2 Helm в работе: чужие чарты** | 🟡 values чужого чарта (bitnami-подобный), `helm show values`, override-файлы по окружениям, subcharts и dependencies, `global`. 🔴 отладка шаблонов (`--debug`, `helm template | kubectl apply --dry-run=server`), library charts, post-renderer, upgrade мажорной версии чарта | Поставить чарт PostgreSQL, переопределить values, найти, какой шаблон рождает поле | «Обновили чарт — пропал PVC» | Как разобраться в чужом чарте? Как вести values по окружениям? |
| **07-3 Kustomize и выбор инструмента** | 🟡 base/overlays, patches (strategic merge, JSON 6902), generators с хэшем, images. 🔴 Helm + Kustomize вместе, когда что, анти-рецепты (копипаста манифестов, sed в CI) | Overlays staging/prod для orders-api; ConfigMap-генератор перезапускает поды | «Поменяли ConfigMap — prod не заметил, staging заметил» | Helm vs Kustomize? Что делает configMapGenerator? |

## 10. Модуль 8. GitOps (2 части)

| Часть | Содержание по уровням | 🔧 Лаба | 🔥 Кейс | 💼 Ключевые вопросы |
|---|---|---|---|---|
| **08-1 Argo CD** | 🟢 pull-модель, Application, sync. 🟡 статусы Synced/OutOfSync и Healthy/Degraded, auto-sync, self-heal, prune, sync waves и hooks, ignoreDifferences, откат через Git. 🔴 почему «вечный OutOfSync» (мутирующие контроллеры, дефолты, HPA), RBAC и проекты Argo CD, масштаб (шардинг контроллера) | Argo CD + Gitea: orders-api из Git; ручная правка в кластере → self-heal; вечный OutOfSync и ignoreDifferences | «Argo CD показывает OutOfSync каждые 3 минуты, хотя никто ничего не менял» | Push vs pull деплой? Что такое drift? Как откатиться в GitOps? |
| **08-2 GitOps в масштабе** | 🟡 app-of-apps, ApplicationSet (генераторы), структура репозиториев (app vs config), промоушен по окружениям. 🔴 секреты в GitOps (SOPS, ESO, Sealed Secrets), связь с CI (обновление тега/дайджеста — Image Updater или коммит из CI), сравнение с Flux | ApplicationSet на два окружения; промоушен коммитом дайджеста из CI | «В Git — секреты в base64» | Как хранить секреты в GitOps? App-of-apps vs ApplicationSet? Argo CD vs Flux? |

## 11. Модуль 9. Расширение API (2 части)

| Часть | Содержание по уровням | 🔧 Лаба | 🔥 Кейс | 💼 Ключевые вопросы |
|---|---|---|---|---|
| **09-1 CRD и операторы** | 🟡 CRD, custom resource, контроллер и reconcile, status/conditions. 🔴 паттерн оператора, уровни зрелости, CloudNativePG как пример (failover, бэкапы), когда оператор оправдан | CRD своими руками (без кода — объект и схема); CloudNativePG: кластер из 3 реплик, failover при удалении primary | «Удалили CRD — исчезли все объекты» | Что такое оператор? Чем CRD отличается от ConfigMap? |
| **09-2 Admission webhooks и finalizers** | 🟡 validating/mutating webhooks, failurePolicy, finalizers. 🔴 «namespace висит в Terminating», webhook недоступен → кластер не принимает изменения, timeoutSeconds, namespaceSelector | Намеренно сломанный webhook с failurePolicy Fail; namespace в Terminating из-за finalizer и как найти причину | «Упал сервис webhook — никто не может задеплоить» | Почему namespace не удаляется? Чем опасен failurePolicy Fail? |

## 12. Модуль 10. Эксплуатация кластера (3 части)

| Часть | Содержание по уровням | 🔧 Лаба | 🔥 Кейс | 💼 Ключевые вопросы |
|---|---|---|---|---|
| **10-1 etcd** — ⚠️ не опубликована (§0) | 🟡 роль etcd, кворум (3/5 узлов), бэкап `etcdctl snapshot save`, восстановление. 🔴 размер БД и квота (2 ГиБ по умолчанию), defrag и compaction, задержка диска (fsync), шифрование данных | Снапшот etcd → удалить namespace → восстановить из снапшота в kind | «etcd превысил квоту — кластер только на чтение» | Сколько узлов etcd и почему нечётное? Как восстановить кластер из бэкапа? |
| **10-2 Обновление кластера** | 🟡 version skew (kubelet до 3 минорных версий ниже apiserver), порядок: control plane → узлы, drain. 🔴 kubeadm upgrade plan/apply, удалённые API (поиск устаревших манифестов), обновление managed-кластеров, план отката | ⚠️ решается на пробе: `kubeadm upgrade` внутри узлов kind; если не выйдет — частичная лаба (plan, проверка API) | «После обновления упал деплой: удалили API-версию» | В каком порядке обновлять кластер? Что такое version skew? |
| **10-3 Сертификаты и обслуживание узлов** | 🟡 PKI kubeadm, срок 1 год, `kubeadm certs check-expiration/renew`, ротация сертификатов kubelet. 🔴 kubeconfig администратора как секрет, замена узла, обслуживание (cordon/drain/uncordon), runbook | `check-expiration` на стенде, обновить сертификаты, перезапустить компоненты | «Через год после установки кластер перестал отвечать — истекли сертификаты» | Какие сертификаты в кластере и сколько живут? Как вывести узел на обслуживание? |

## 13. Модуль 11. Диагностика (3 части)

| Часть | Содержание по уровням | 🔧 Лаба | 🔥 Кейс | 💼 Ключевые вопросы |
|---|---|---|---|---|
| **11-1 Под не работает** | 🟢 методика: `get` → `describe` (Events) → `logs` (`--previous`) → `exec`/`debug`. 🟡 разбор статусов: Pending (ресурсы, taints, PVC), ImagePullBackOff, CrashLoopBackOff, CreateContainerConfigError, OOMKilled, Running но не Ready. 🔴 `kubectl debug` (ephemeral, copy пода, узел), под без shell, отличие проблемы приложения от проблемы платформы | 10 сломанных подов-тренажёров | «Pending 2 часа: PVC в другой зоне» | Под в CrashLoopBackOff — ваши действия? Что смотреть в describe? |
| **11-2 Сеть и DNS: пошагово** | 🟡 методика по слоям: под → Service → EndpointSlice → kube-proxy → DNS → NetworkPolicy → Gateway. 🔴 `tcpdump` в netns пода, conntrack, MTU | 8 сетевых поломок на пути запроса сквозного сценария | «Таймауты 1 % запросов» | Сервис не отвечает — по шагам, что проверяете? |
| **11-3 Узел и control plane** | 🟡 NotReady: kubelet, runtime, диск, сеть; логи kubelet (`journalctl`), `crictl`. 🔴 медленный apiserver (метрики, APF), etcd, scheduler/controller-manager не работают (leader) | Сломать kubelet, containerd, диск узла (заполнение); апи медленный | «Узлы флапают NotReady под нагрузкой» | Узел NotReady — что проверяете? Как понять, что тормозит apiserver? |

## 14. Модуль 12. Подготовка к собеседованию (4 части)

- **12-1 Банк вопросов (~150)** по разделам и уровням с эталонами и ссылками на части; ловушки («limit памяти = гарантия?», «Secret шифрует данные?», «liveness проверяет БД — хорошо?», «Deployment для БД», «под упал → kubelet перенесёт его на другой узел?»); «зависит, уточню» (Helm vs Kustomize, БД в кластере, CPU limits, managed vs self-hosted, один кластер или много).
- **12-2 Тренажёры «сломай и почини»** (≥ 18): опечатка в selector Service, ndots, readiness без preStop, OOM, Pending по ресурсам и taint, PVC на другом узле, CrashLoop без логов, RBAC forbidden, webhook Fail, namespace в Terminating, helm pending-upgrade, Argo CD OutOfSync…
- **12-3 System design**: платформа для 30 команд (мультитенантность, квоты, RBAC, политики); zero-downtime поставка orders-api с БД и откатом через GitOps; кластер в двух зонах с DR и восстановлением etcd — «как ответил бы сильный кандидат», шаблон рассуждения, мини-задачи.
- **12-4 Матрица самопроверки**, план повторения на 2 недели, контрольная без подсказок.

## 15. Приложения

A — шпаргалки: kubectl (jsonpath, custom-columns, debug), Helm, Kustomize, Argo CD CLI, crictl/etcdctl/kubeadm; B — Manjaro vs Ubuntu (kind/kubectl/helm пакеты и версии, inotify-лимиты, cgroup); C — стенд (запуск, ресурсы, расширения, сброс); D — глоссарий RU/EN; E — что читать (документация Kubernetes, «Kubernetes in Action» 2-е изд., «Production Kubernetes», KEP'ы, разборы инцидентов).

---

## 16. Ограничения среды агента (для пометок «проверено»)

В среде агента есть Docker 29.7 и доступ в интернет: kind-кластер 1+3, Gateway, Argo CD, Gitea, cert-manager, CloudNativePG поднимаются реально — лабы проверяются с реальным выводом. Песочница агента не видит `127.0.0.1` хоста, поэтому агент выполняет kubectl из служебного контейнера в docker-сети `kind`; у читателя те же команды выполняются с хоста. Не проверяется (⚠️): облачные LoadBalancer, Cluster Autoscaler/Karpenter, managed-кластеры (EKS/YC/VK), реальная многозонность; обновление кластера в kind — решается на пробе (10-2).

---

## 17. Статус согласования

- [x] План утверждён (2026-10-14)
- [x] Формат пробной части `05-1` утверждён (2026-10-14)
- [x] Производство без остановок — учебник написан полностью (2026-10-14); 06-1 и 10-1 не опубликованы (§0)
- [ ] Согласование готового учебника заказчиком → слияние в `main`
