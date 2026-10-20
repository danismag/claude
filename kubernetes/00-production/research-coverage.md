# Исследование охвата курса Kubernetes (2026-10-19)

План: /home/user/claude/kubernetes/00-plan.md (§4). Режим — только чтение и веб.

## 1. Программы сертификаций (CKA, CKAD, CKS)

Источник: https://github.com/cncf/curriculum — сейчас там `CKA_Curriculum_v1.37.pdf`, `CKAD_Curriculum_v1.37.pdf`, `CKS_Curriculum v1.34.pdf`. PDF через WebFetch не распарсились (бинарный поток); сайты cncf.io и training.linuxfoundation.org из среды не резолвятся (ENOTFOUND). Поэтому формулировки ниже — по вторичным источникам (зеркала программы на GitHub, учебные сайты), сверены между собой; дословность не гарантирована.

### CKA (редакция с 18.02.2025; программа v1.35–1.37)

Источник: https://github.com/techiescamp/cka-certification-guide (ссылается на CNCF v1.35); подтверждение реформы 2025: https://kodekloud.com/community/t/change-of-curriculam-for-cka-exam-around-jan-2025/470466

| Домен | Вес | Компетенции | В плане |
|---|---|---|---|
| Cluster Architecture, Installation & Configuration | 25% | RBAC (06-1); подготовка инфраструктуры; **создание кластера kubeadm**; жизненный цикл кластера (10-2); Helm и Kustomize для компонентов (07-1..3); **extension interfaces CNI/CSI/CRI** (01-2, 03-1, 04-2 частично); CRD и операторы (09-1); HA control plane (нет) | kubeadm-установка и HA — нет |
| Workloads & Scheduling | 15% | Deployment, rolling update, rollback (02-2); ConfigMap/Secret (04-1); автомасштабирование (05-3); self-healing (02-x); admission и scheduling: limits, affinity (05-1, 05-2) | полно |
| Storage | 10% | StorageClass, динамическое выделение; типы томов, access modes, reclaim (04-2); PV/PVC | полно |
| Services & Networking | 20% | связность подов (03-1); NetworkPolicy (03-5); ClusterIP/NodePort/**LoadBalancer** (03-2; LB в kind не проверен); Gateway API (03-4); Ingress-контроллеры (03-4); CoreDNS (03-3) | LoadBalancer — только упоминание |
| Troubleshooting | 30% | кластер и узлы; компоненты кластера (11-3); **мониторинг ресурсов** (metrics-server, `kubectl top`); логи контейнеров (11-1); сервисы и сеть (11-2) | `top`/metrics-server нигде не выделены как тема |

### CKAD (программа v1.37; веса с официальной страницы по сниппету поиска)

| Домен | Вес | Компетенции | В плане |
|---|---|---|---|
| Application Design and Build | 20% | **сборка образов** (курс Docker); выбор workload-ресурса (02-x); multi-container: sidecar, init (02-1); persistent и ephemeral volumes (04-2; emptyDir/ephemeral — частично) | образы — вне курса |
| Application Deployment | 20% | **blue/green и canary примитивами Kubernetes** (нет); rolling update (02-2); Helm (07-1/2); Kustomize (07-3) | canary/blue-green — нет |
| Application Observability and Maintenance | 15% | **API deprecations** (pluto/kubent упомянуты, не проверены); probes (02-5); CLI-мониторинг (`top`); логи; отладка (11-1, `kubectl debug` в 00-2) | deprecations — раздел нужен |
| Application Environment, Configuration and Security | 25% | CRD/операторы (09-1); authn/authz/admission (06-1, 06-2, 09-2); requests/limits/quota (05-1); ConfigMap/Secret (04-1); ServiceAccount (06-1); **securityContext, capabilities** (06-2 частично) | securityContext — нужна явная глава |
| Services and Networking | 20% | NetworkPolicy (03-5); Service (03-2); Ingress (03-4) | полно |

### CKS (программа v1.34; обновление 2024: SBOM, Cilium/Istio)

Старые формулировки — https://github.com/walidshaari/Certified-Kubernetes-Security-Specialist ; изменения 2024 — https://kodekloud.com/blog/cks-exam-updates-2024-your-complete-guide-to-certification-with-kodekloud/ , https://www.oreilly.com/library/view/certified-kubernetes-security/9781098132965/ch01.html . Веса Cluster Setup/System Hardening в источниках расходятся (10/15 или 15/10).

| Домен | Вес | Компетенции | В плане |
|---|---|---|---|
| Cluster Setup | 10–15% | NetworkPolicy (03-5); **CIS benchmark, kube-bench** (нет); Ingress с TLS (03-4); защита metadata узлов и эндпоинтов (нет); проверка бинарей (нет) | kube-bench — нет |
| Cluster Hardening | 15% | ограничение доступа к API (06-1 частично); RBAC (06-1); осторожность с ServiceAccount, automount (06-1); обновления (10-2) | хорошо |
| System Hardening | 10–15% | минимизация ОС узла (курс linux); least-privilege IAM (облако); внешний доступ; **AppArmor, seccomp** (нет явно) | seccomp/AppArmor — нет |
| Minimize Microservice Vulnerabilities | 20% | Pod Security Standards (06-2); Secrets (04-1); **изоляция: мультитенантность, sandbox gVisor/Kata, RuntimeClass** (нет); **шифрование pod-to-pod mTLS: Cilium, Istio** (нет) | service mesh / mTLS — нет |
| Supply Chain Security | 20% | минимальный базовый образ (Docker); **SBOM**, CI/CD, реестры; **подпись и проверка (cosign), разрешённые реестры** (06-2 VAP «без latest» — частично); **статанализ kubesec/KubeLinter, Trivy** (нет) | почти нет |
| Monitoring, Logging and Runtime Security | 20% | **поведенческий анализ — Falco** (нет); иммутабельность контейнера (readOnlyRootFilesystem — 06-2?); **audit log apiserver** (нет; 06-1 работа 4 — аудит прав, не audit log) | audit policy — нет |

Вывод по разделу: CKA покрыт почти полностью, кроме **установки кластера kubeadm и HA control plane**, **LoadBalancer** и **мониторинга ресурсов**. CKAD — нет **стратегий canary/blue-green** и **API deprecations** как темы. CKS покрыт слабо: нет **audit logging**, **seccomp/AppArmor**, **RuntimeClass/sandbox**, **supply chain (подпись, SBOM, admission по подписи)**, **runtime-детекта (Falco)**, **mTLS**.

## 2. Книги, документация, Hard Way

Доступность: manning.com, oreilly.com, leanpub.com, tenlong и подобные из среды не резолвятся. Открылись только GitHub-репозитории.

### Kubernetes in Action, 2-е изд. (Лукша; Manning) — открылось частично

Источник: README репозитория примеров https://github.com/luksa/kubernetes-in-action-2nd-edition (главы 1–18; главы дальше 18 в репозитории не перечислены — оглавление MEAP не открылось).
Части: I Getting Started (контейнеры, первое приложение); II Pods (Pods, жизненный цикл и health, namespaces и labels); III Config & Storage (ConfigMap/Secret, тома и метаданные, PV); IV Connecting (Services, Ingress, **Gateway API — отдельная глава 13**); V Controllers (ReplicaSet, Deployment, StatefulSet, DaemonSet, Job/CronJob).
Сравнение: всё есть в плане (02-x, 03-x, 04-x). Отдельной темы **labels/selectors/namespaces как организация** в плане нет — она размазана; в KiA это целая глава.

### Kubernetes Patterns, 2-е изд. (Ibryam, Huß) — открылось

Источник: https://github.com/k8spatterns/examples
Foundational: Predictable Demands (05-1), Declarative Deployment (02-2; **blue-green и canary тут же** — в плане нет), Health Probe (02-5), Managed Lifecycle (02-5), Automated Placement (05-2). Behavioral: Batch/Periodic Job (02-4), Daemon Service (02-4), **Singleton Service — leader election, Lease** (нет), Stateless/Stateful (02-2/02-3), Service Discovery (03-2/03-3), Self Awareness (02-1 Downward API). Structural: Init/Sidecar (02-1), **Adapter, Ambassador** (нет, мелочь). Configuration: EnvVar, Configuration Resource, **Immutable Configuration** (04-1 — проверить, есть ли `immutable: true`), Configuration Template. Security (новое во 2-м изд.): **Process Containment** (securityContext — 06-2 частично), **Network Segmentation** (03-5), Secure Configuration (ESO/SOPS — не проверено), Access Control (06-1). Advanced: Controller, Operator (09-1), **Elastic Scale** (05-3), **Image Builder** (вне курса — cicd/Docker).

### Production Kubernetes (Rosso и др., O'Reilly 2021) — страница не открылась

Оглавление по памяти, не подтверждено источником (пометка: НЕ ПРОВЕРЕНО): Path to Production; Deployment Models; Container Runtime; Container Storage; Pod Networking; Service Routing; Secret Management; Admission Control; Observability; Identity; Building Platform Services; **Multitenancy**; Autoscaling; Application Considerations; **Software Supply Chain**; **Platform Abstractions**. Пробелы плана относительно этой книги: мультитенантность, supply chain, идентичность рабочих нагрузок (workload identity / OIDC), платформенные абстракции (IDP), наблюдаемость.

### Kubernetes: Up and Running, 3-е изд. (2022) — страница не открылась

Оглавление не получено. По памяти (НЕ ПРОВЕРЕНО) в 3-м изд. есть главы про **Policy and Governance (Gatekeeper)**, **Multicluster Application Deployments**, **Service Meshes**, **Securing Applications**, Organizing Your Application. Значит, mesh и multicluster в «канонической» книге — отдельные главы.

### Kubernetes Best Practices, 2-е изд. (2023) — частично

Источник сниппета: https://oreilly.com/library/view/kubernetes-best-practices/9781098142155 — подтверждены главы 20 «Chaos Testing, Load Testing, and Experiments», 21 «Implementing an Operator», 22 Conclusion; в описании — ML-нагрузки. Остальное оглавление не открылось. Пробел плана: **нагрузочное тестирование и chaos**, **ML/GPU-нагрузки (DRA)**.

### The Kubernetes Book (Poulton, ред. 2025, Kubernetes 1.32; анонсирована ред. 2026) — оглавление не открылось

По листингам (https://en.bookmate.com/books/V6H9eqtV , https://community.kebuk.com.ua/book/138262): добавлен **WebAssembly на Kubernetes** (RuntimeClass), API, безопасность, troubleshooting. Глава про threat modeling не подтверждена.

### Kubernetes the Hard Way — открылось

Источник: https://github.com/kelseyhightower/kubernetes-the-hard-way (Kubernetes 1.32, containerd 2.1, etcd 3.6). Лабы: jumpbox, CA и TLS-сертификаты, kubeconfig для аутентификации, encryption config, bootstrapping etcd, control plane, worker nodes, маршруты подов, smoke test.
Сравнение: в плане нет части «собрать кластер руками» (kubeadm init/join, PKI). 01-1/01-2/10-3 объясняют компоненты на готовом kind. Рекомендация: раздел «как kind и kubeadm собирают кластер» (PKI, static pods, bootstrap token, TLS bootstrap kubelet) — новая часть 10-0/10-4 или в 01-1.

### Документация kubernetes.io: Concepts — открылось

Источник: https://github.com/kubernetes/website/tree/main/content/en/docs/concepts (разделы architecture, cluster-administration, configuration, containers, extend-kubernetes, overview, policy, resource-management, scheduling-eviction, security, services-networking, storage, windows, workloads).
Страницы, которых нет в плане (по файлам каталогов):
- cluster-administration: **flow-control** (API Priority and Fairness), **kube-state-metrics**, **system-metrics / system-logs / system-traces**, **logging**, **dra** (Dynamic Resource Allocation, GA в 1.34), node-autoscaling (Cluster Autoscaler/Karpenter — упомянуто, не проверено), **swap-memory-management**, **node-shutdown** (упомянуто), coordinated-leader-election, compatibility-version, admission-webhooks-good-practices (09-2).
- security: **multi-tenancy**, **linux-kernel-security-constraints** (seccomp, AppArmor, SELinux), **api-server-bypass-risks**, hardening-guide, rbac-good-practices, secrets-good-practices, security-checklist, application-security-checklist.
- scheduling-eviction: gang-scheduling, podgroup-scheduling, workload-aware-preemption (новое, 1.35–1.36, альфа), scheduling-framework, **pod-scheduling-readiness** (schedulingGates), pod-overhead, resource-bin-packing, running-multiple-schedulers, api-eviction (05-4), node-pressure-eviction (05-4).
Вывод: план хорошо закрывает workloads/services/storage/scheduling, но не закрывает **наблюдаемость кластера (метрики компонентов, kube-state-metrics, логи, трейсы)**, **APF**, **DRA/GPU**, **мультитенантность**, **ядро-безопасность (seccomp/AppArmor)**, **audit**.

## 3. Собеседования 2025–2026

Доступность: habr.com и roadmap.sh из среды не резолвятся; репозиторий roadmap.sh на GitHub по прежним путям даёт 404. Данные — по сниппетам поиска и спискам на GitHub.

Источники:
- https://github.com/bregman-arie/devops-exercises/blob/master/topics/kubernetes/README.md — открылось (разделы: 101, Cluster/Architecture, Pods, Labels, Deployments, Services, Ingress, ReplicaSets, DaemonSet, StatefulSet, Storage, Networking, NetworkPolicy, etcd, Namespaces/Quota, Operators, Secrets, Access Control, Patterns, CronJob, **Gatekeeper**, **Policy Testing**, Helm, Security, Troubleshooting Scenarios, **Istio**, Controllers, Scheduler, Taints, Limits, **Monitoring**, Kustomize, **Deployment Strategies**, Scenarios).
- Сниппеты: https://cloudsoftsol.com/kubernetes/top-advanced-kubernetes-interview-questions-2026-edition-scenario-based/ , https://www.weekday.works/post/kubernetes-interview-questions , https://komodor.com/blog/the-definitive-guide-to-kubernetes-cluster-upgrades — акцент 2026: platform design, security/compliance, reliability, production outages, GitOps, **cost and scale**; формат — 2–3 сценария траблшутинга, оценивается методичность; апгрейды — pluto/kubeconform в CI, release notes, критерии отката; мультитенантность — три модели изоляции (namespace / узлы / кластер).
- Хабр (только сниппеты): https://habr.com/en/articles/909260 (шпаргалка интервьюера, базовые → сложные), https://career.habr.com/vacancies/1000141456 (Senior DevOps: несколько кластеров, Helm, Argo CD, Terraform, VictoriaMetrics, Loki). Русский рынок ожидает стек K8s + Helm + Argo CD + Prometheus/VictoriaMetrics + Loki + Terraform; Yandex Managed Kubernetes как облако по умолчанию.
- roadmap.sh/kubernetes — не открылось. По памяти (НЕ ПРОВЕРЕНО) разделы: контейнеры; установка (managed-провайдеры, локальный кластер); workloads; сеть и внешний доступ; конфигурация; ресурсы и квоты; безопасность (RBAC, network security, CIS, image scanning, pod security); **мониторинг и логирование (logs, metrics, traces, resource health)**; **автомасштабирование (HPA, VPA, cluster autoscaling)**; планирование; storage/CSI; **deployment patterns (CI/CD, GitOps, Helm, canary, blue-green, rolling)**; продвинутое (свои контроллеры, свои планировщики, CRD, установка control plane, **multi-cluster management**).

Сводка тем по уровням (синтез источников):
- **Junior**: объекты (Pod/Deployment/Service/ConfigMap/Secret), `kubectl` и логи, probes, labels/selectors, namespaces, CrashLoopBackOff/ImagePullBackOff/Pending, Service-типы, «что происходит при `kubectl apply`/создании пода».
- **Middle**: rolling update и откат, requests/limits и QoS, OOMKilled/троттлинг, HPA, affinity/taints, PV/PVC/StorageClass, StatefulSet, Ingress vs Gateway API, NetworkPolicy, DNS ndots, RBAC и ServiceAccount, Helm/Kustomize, Argo CD, Secrets (ESO/SOPS/Vault), **canary/blue-green**, траблшутинг сети.
- **Senior**: устройство control plane и etcd (кворум, размер, defrag), обновления флота и deprecated API, PDB/drain, приоритеты и вытеснение, **мультитенантность**, **supply chain и admission-политики (Kyverno/Gatekeeper/VAP)**, **наблюдаемость кластера и SLO**, **стоимость (FinOps)**, **многокластерность и DR**, операторы, **service mesh/mTLS**, **APF и масштабные пределы**, managed vs self-hosted, разбор инцидентов (postmortem).

## 4. Практика: наблюдаемость, мультитенантность, FinOps, managed, multi-cluster, supply chain, Velero, DR, обновления, инциденты

Источники: Kubernetes 1.36 (22.04.2026) — https://kubernetes.io/blog/2026/04/22/kubernetes-v1-36-release/ (сниппеты: GA — fine-grained kubelet authz, **user namespaces**, **MutatingAdmissionPolicy**, **VolumeGroupSnapshot**, external SA token signing, DRA admin access/prioritized list; alpha — workload-aware scheduling). Ingress NGINX — https://kubernetes.io/blog/2025/11/11/ingress-nginx-retirement/ (поддержка закончена в марте 2026; Ingress API остаётся; рекомендация — Gateway API). Мультитенантность — https://www.infoq.com/news/2025/10/cncf-vcluster-multitenancy , https://docs.stakater.com/mto/1.9/learn/capsule-alternatives.html . Velero — https://oneuptime.com/blog/post/2026-01-19-kubernetes-velero-backup-restore/markdown (MinIO как S3, file-system backup, restore namespace, namespace mapping; для CSI-снапшотов нужен драйвер со снапшотами — local-path их не умеет).

По темам — что относится к курсу Kubernetes, а что к соседним курсам:

- **Наблюдаемость.** В курс K8s: источники данных кластера — events (TTL по умолчанию 1 ч, `--event-ttl`), metrics-server и `kubectl top`, `/metrics` компонентов (`kubectl get --raw /metrics`), kube-state-metrics, логи контейнеров на узле и ротация kubelet (`containerLogMaxSize` 10Mi, `containerLogMaxFiles` 5), audit log, `/readyz` `/livez`. В курс observability: Prometheus/VictoriaMetrics, Grafana, Loki, OpenTelemetry, алерты, SLO, кардинальность. Сейчас в плане нет ни того, ни другого как темы — только metrics-server в стенде.
- **Мультитенантность.** Модели: namespace (мягкая) → выделенные узлы → виртуальный control plane (vCluster, Kamaji) → отдельный кластер. Инструменты: Capsule, HNC (заморожен), vCluster. В плане есть кирпичи (RBAC, quota, PSA, NetPol), но нет сборки «namespace как услуга» и сравнения моделей. Место — новая часть.
- **FinOps.** В курс K8s: requests vs фактическое потребление, VPA recommender, bin packing, OpenCost (CNCF) для разнесения стоимости по namespace/меткам, spot-узлы и PDB. Облачные скидки и биллинг — курс cloud. В плане — нет.
- **Managed-кластеры** (EKS, GKE, AKS, Yandex Managed Kubernetes): что берёт провайдер (control plane, etcd, сертификаты, часть апгрейда), IAM ↔ RBAC, workload identity (IRSA/EKS Pod Identity, GKE WI, YC — сервисные аккаунты), cloud LB и CSI, Cluster Autoscaler/Karpenter, окна обслуживания. Лабы на kind невозможны; в K8s — раздел-сравнение, практика — курс cloud. В плане — только «managed-кластеры» в непроверенном.
- **Многокластерность.** Argo CD ApplicationSet с cluster generator на двух kind-кластерах (второй — 1 узел, ~600 МиБ), Cluster API (kind как management-кластер — CAPD), multi-cluster Services (MCS API), kubeconfig-контексты. В плане — 08-2 (только ApplicationSet внутри одного кластера).
- **Supply chain и политика образов.** Подпись cosign (ключ или keyless), SBOM (syft), сканирование (Trivy: образы и `trivy k8s`), admission по подписи (Kyverno verifyImages, Sigstore policy-controller), разрешённые реестры (VAP), дайджесты вместо тегов. Сборка и подпись в пайплайне — курс cicd; проверка при admission — курс K8s. В плане — только VAP «без latest» (06-2) и промоушен дайджеста (08-2).
- **Бэкап кластера, Velero, DR.** Уровни: etcd-снапшот (10-1) → объекты API (Velero, GitOps как источник) → данные томов (04-3, Velero FS backup/kopia, CSI snapshots, VolumeGroupSnapshot GA в 1.36). RPO/RTO, восстановление в другой кластер, namespace mapping. В плане нет Velero и нет «восстановить кластер целиком в новый кластер».
- **Обновления.** Есть 10-2. Не хватает: version skew policy (kubelet до 3 минорных назад с 1.28), deprecated API (метрика `apiserver_requested_deprecated_apis`, pluto), стратегия «новый кластер рядом» (blue/green clusters), обновление аддонов (CNI, CoreDNS, Gateway), compatibility-version (откат минорной версии apiserver, 1.32+ — по странице compatibility-version.md).
- **Инциденты.** Модуль 11 и 12-2 закрывают диагностику. Не хватает формата postmortem и типовых инцидентов уровня кластера: etcd `mvcc: database space exceeded` (квота по умолчанию 2 ГиБ), apiserver 429 от APF, истёкшие сертификаты (10-3), DNS-штормы, массовое вытеснение, webhook с `failurePolicy: Fail` блокирует кластер (09-2).

## 5. Матрица «тема эталона → в плане → важность → рекомендация → URL»

Важность: П — практика, С — собеседование; высокая/средняя/низкая. Сокращения URL: CKA = https://github.com/techiescamp/cka-certification-guide ; CKS = https://github.com/walidshaari/Certified-Kubernetes-Security-Specialist + KodeKloud 2024; DOCS = https://github.com/kubernetes/website/tree/main/content/en/docs/concepts ; PAT = https://github.com/k8spatterns/examples ; DEX = devops-exercises.

| Тема эталона | В плане | Важность | Рекомендация | URL |
|---|---|---|---|---|
| Архитектура, путь запроса, watch | 01-1 | П выс / С выс | оставить; добавить Lease и leader election | DOCS/architecture, PAT Singleton |
| kubelet, CRI, CNI, static pod | 01-2 | П выс / С выс | оставить | CKA |
| SSA, finalizers, каскад | 01-3 | П ср / С ср | оставить | DOCS/overview |
| Labels, selectors, namespaces, annotations | частично (размазано) | П выс / С выс (Junior) | раздел в 01-3 | KiA2 гл. 7, DEX |
| Pod, init, sidecar, Downward API | 02-1 | П выс / С выс | готово | KiA2, PAT |
| Deployment, rollout, rollback | 02-2 | П выс / С выс | оставить | CKA, CKAD |
| **Blue-green, canary** | нет | П выс / С выс | новая часть (Gateway API веса) | CKAD, PAT Declarative Deployment, DEX |
| StatefulSet | 02-3 | П выс / С выс | оставить | KiA2 |
| DaemonSet, Job, CronJob | 02-4 | П ср / С ср | оставить | KiA2 |
| Probes, graceful shutdown | 02-5 | П выс / С выс | оставить | CKAD |
| Сеть подов, CNI | 03-1 | П выс / С выс | оставить | CKA |
| Service, kube-proxy, EndpointSlice | 03-2 | П выс / С выс | оставить | CKA |
| **LoadBalancer** (MetalLB / cloud-provider-kind) | частично (не проверено) | П ср / С ср | работа в 03-2 с cloud-provider-kind | CKA |
| CoreDNS | 03-3 | П выс / С выс | оставить | CKA |
| Gateway API, Ingress, TLS | 03-4 | П выс / С выс | учесть уход ingress-nginx (март 2026) | k8s blog 2025-11-11 |
| NetworkPolicy | 03-5 | П выс / С выс | оставить | CKA, CKAD |
| **Service mesh, mTLS** (Istio ambient / Linkerd / Cilium) | нет | П ср / С выс (Senior) | новая часть 03-6 | CKS, DEX Istio, K8s Up&Running (не проверено) |
| ConfigMap, Secret, шифрование etcd | 04-1 | П выс / С выс | добавить `immutable` | CKA, PAT |
| PV, PVC, CSI, StorageClass | 04-2 | П выс / С выс | оставить; VolumeGroupSnapshot (GA 1.36) — упоминание | CKA |
| Бэкап данных | 04-3 | П выс / С ср | + Velero (см. ниже) | — |
| **Velero, бэкап объектов, восстановление в новый кластер** | нет | П выс / С выс | раздел и работа в 04-3 или 10-1 | oneuptime Velero |
| Requests, limits, QoS, квоты | 05-1 | П выс / С выс | оставить | CKA, CKAD |
| Планировщик, affinity, taints, приоритеты | 05-2 | П выс / С выс | + schedulingGates, bin packing — абзацем | DOCS/scheduling-eviction |
| HPA, KEDA | 05-3 | П выс / С выс | + **VPA** и **Cluster Autoscaler/Karpenter** (теория) | roadmap (не проверено), DOCS node-autoscaling |
| PDB, drain, вытеснение kubelet | 05-4 | П выс / С выс | оставить | DOCS |
| **DRA, GPU, gang scheduling / Kueue** | нет | П низ / С ср (тренд 2026) | раздел в 05-2, опц. работа dra-example-driver | DOCS dra.md, k8s 1.36 |
| RBAC, SA, kubeconfig | 06-1 | П выс / С выс | оставить | CKA, CKS |
| PSA, VAP | 06-2 | П выс / С выс | + **MutatingAdmissionPolicy (GA 1.36)** вместо «непроверено» | k8s 1.36 |
| **securityContext, capabilities, seccomp, AppArmor, user namespaces (GA 1.36), RuntimeClass** | частично (06-2) | П выс / С выс | новая часть 06-3 | CKS, CKAD, DOCS linux-kernel-security-constraints |
| **Audit log apiserver** | нет | П выс / С выс | работа в новой 06-4 | CKS |
| **Supply chain: cosign, SBOM, Trivy, Kyverno verifyImages, разрешённые реестры** | частично (VAP latest) | П выс / С выс | новая часть 06-4 | CKS |
| **CIS benchmark (kube-bench), защита metadata узлов** | нет | П ср / С ср | работа в 06-4 | CKS |
| **Мультитенантность** (модели, Capsule, vCluster) | нет | П ср / С выс (Senior) | новая часть | DOCS multi-tenancy, InfoQ 2025 |
| Helm | 07-1, 07-2 | П выс / С выс | проверить Bitnami (каталог изменён в 2025) | CKA |
| Kustomize | 07-3 | П выс / С ср | оставить | CKA |
| Argo CD, ApplicationSet | 08-1, 08-2 | П выс / С выс | + Argo Rollouts как связь с canary — опц. | DEX |
| **Многокластерность** | частично (08-2) | П ср / С выс | работа: 2 kind-кластера, cluster generator | roadmap (не проверено) |
| CRD, операторы | 09-1 | П ср / С выс | оставить | CKA |
| Admission webhooks, finalizers | 09-2 | П ср / С ср | оставить | DOCS |
| etcd | 10-1 | П выс / С выс | + квота 2 ГиБ, space exceeded | KTHW |
| **Сборка кластера kubeadm, PKI, TLS bootstrap, HA control plane** | нет (только kind) | П выс / С выс | новая часть 10-0 | CKA, KTHW |
| Обновление кластера | 10-2 | П выс / С выс | + skew policy, deprecated API (метрика), blue/green clusters | Komodor |
| Сертификаты, обслуживание узлов | 10-3 | П выс / С ср | убрать дубль drain с 05-4 | CKA |
| **API Priority and Fairness, пределы масштаба** | нет | П ср / С выс (Senior) | раздел в 01-1 или 10-1 | DOCS flow-control |
| **Наблюдаемость кластера** (events, top, /metrics, kube-state-metrics, логи узла) | нет | П выс / С выс | новая часть 11-0 | CKA Troubleshooting, DOCS observability |
| Диагностика подов, сети, узлов | 11-1..3 | П выс / С выс | оставить | CKA 30% |
| **FinOps** (OpenCost, VPA, rightsizing) | нет | П ср / С ср | раздел в части про мультитенантность | — |
| **Managed (EKS/GKE/AKS/YC)** | нет | П ср / С выс | раздел-сравнение без лаб в 10-2; практика — курс cloud | — |
| Сборка образов, multi-stage | нет | П выс / С выс | вне курса — курс Docker / cicd | CKAD, CKS |
| Prometheus, Grafana, Loki, OTel, SLO | нет | П выс / С выс | вне курса — observability | — |
| Falco, runtime-детект | нет | П низ / С ср | вне курса — security (в 06-4 абзац) | CKS |
| Минимизация ОС узла, IAM | нет | П низ / С низ | вне курса — linux, cloud, security | CKS |
| Windows-узлы, Wasm | нет | П низ / С низ | не включать; Wasm — абзац при RuntimeClass | DOCS windows, Poulton 2025 |
| Chaos/нагрузочное тестирование | нет | П ср / С ср | абзац в 12-3; chaos — курс observability/SRE | K8s Best Practices 2e гл. 20 |

## 6. Пробелы по приоритету

### Приоритет 1 — новые части (критично и для практики, и для собеседования)

1. **06-3 Изоляция контейнера: securityContext, seccomp, AppArmor, user namespaces** (модуль 06, после PSA). Работы на kind:
   1. capabilities: `drop: [ALL]`, `NET_BIND_SERVICE`, `readOnlyRootFilesystem` и `emptyDir` для записи; `runAsNonRoot` и отказ запуска;
   2. seccomp: `RuntimeDefault` против `Unconfined`, свой профиль из `/var/lib/kubelet/seccomp` узла kind (файл копируется `docker cp` в узел-контейнер), отказ syscall в `strace`/выводе;
   3. user namespaces: `hostUsers: false` (GA 1.36), UID в поде и на узле (`/proc/<pid>/uid_map` через `crictl inspect`); требования: ядро ≥ 6.3, idmap-монтирования, containerd 2 — проверить ядро читателя (Manjaro новее, Ubuntu 24.04 — 6.8);
   4. RuntimeClass: объект и выбор обработчика (gVisor — теория; на kind можно runsc, но это меняет узел — пометить «выполняете сами»).
   AppArmor — раздел с различием Ubuntu (включён) и Manjaro (по умолчанию нет).
2. **06-4 Аудит и цепочка поставки** (модуль 06). Работы:
   1. audit policy apiserver: отдельный kind-кластер `lab-06-4` (1 узел, `extraMounts` + `kubeadmConfigPatches`), уровни Metadata/RequestResponse, поиск «кто прочитал Secret» в `audit.log`;
   2. Trivy: скан образа из реестра стенда и `trivy config`/`trivy k8s` по манифестам; kube-bench как Job — отчёт CIS;
   3. cosign: подпись образа в `localhost:5001` своим ключом, SBOM syft как attestation;
   4. Kyverno verifyImages (или Sigstore policy-controller): неподписанный образ отклонён, подписанный — пропущен; разрешённые реестры через VAP.
3. **11-0 Наблюдаемость кластера: события, метрики, логи** (начало модуля 11; или 05-0). Работы:
   1. events: TTL 1 ч, `kubectl events --for`, `--watch`, агрегация `count`;
   2. metrics-server и `kubectl top` против cgroup-цифр; Metrics API `kubectl get --raw /apis/metrics.k8s.io/...`;
   3. `/metrics` apiserver, kubelet (`/metrics/cadvisor`, `/metrics/resource`) через `kubectl get --raw`; kube-state-metrics: `kube_pod_container_status_restarts_total`;
   4. логи на узле: `/var/log/pods`, ротация kubelet `containerLogMaxSize`/`containerLogMaxFiles`, `kubectl logs --previous`, логи компонентов control plane.
   Prometheus/Grafana/Loki — ссылкой на курс observability.
4. **10-0 Сборка кластера: kubeadm, PKI, bootstrap** (первая часть модуля 10). Работы:
   1. как kind вызывает kubeadm: `/kind/kubeadm.conf`, фазы `kubeadm init`, `/etc/kubernetes/pki`, `/etc/kubernetes/manifests`;
   2. TLS bootstrap kubelet: bootstrap token, CSR `kubernetes.io/kube-apiserver-client-kubelet`, автоматическое одобрение; `kubeadm token create --print-join-command`;
   3. HA control plane: отдельный kind-кластер с 3 control-plane (kind ставит haproxy-балансировщик), остановка одного apiserver и одного члена etcd — кворум;
   4. (опц.) ручной `kubeadm join` дополнительного узла — «выполняете сами».
   Kubernetes the Hard Way — ссылкой в приложении E.

### Приоритет 2 — новые части или крупные разделы

5. **02-6 Стратегии поставки: blue-green и canary** (после 02-5; или 08-3). Работы: blue-green переключением selector Service; canary долей реплик; canary весами HTTPRoute (Envoy Gateway уже в стенде) с замером доли ответов; (опц.) Argo Rollouts с анализом — в модуле 08.
6. **Мультитенантность и стоимость** — новая часть 06-5 или 10-4 «Кластер для нескольких команд». Работы: namespace как услуга (quota + LimitRange + RBAC + NetPol + PSA одним набором, проверка «шумного соседа»); Capsule Tenant или vCluster (vCluster легче показать: виртуальный apiserver в namespace); OpenCost: стоимость по namespace и разрыв requests/usage; VPA в режиме Off — рекомендации.
7. **03-6 Service mesh и mTLS** (модуль 03, после NetworkPolicy). Работы: Linkerd или Istio ambient на kind; mTLS STRICT и отказ plaintext; разделение трафика и retries; сравнение с NetworkPolicy (L4 против L7-идентичности). Средний приоритет: тяжело для стенда (~0,5–1 ГиБ), но частый Senior-вопрос и домен CKS.
8. **Velero** — работа в 04-3 (или 10-1): MinIO в кластере как S3, `velero backup create --include-namespaces`, удаление и восстановление, namespace mapping, file-system backup (kopia) для local-path; сравнение с etcd-снапшотом (10-1) — «что восстанавливает каждый уровень».

### Приоритет 3 — разделы в существующих частях

- 01-1: Lease и leader election (`kubectl get lease -n kube-system`), APF (`flowschemas`, `prioritylevelconfigurations`, ответ 429), пределы масштаба (5000 узлов, 110 подов на узел, 150 000 подов — из документации «Considerations for large clusters»).
- 01-3: labels, selectors, annotations, recommended labels `app.kubernetes.io/*`.
- 03-2: LoadBalancer через cloud-provider-kind (работа), иначе тип остаётся `<pending>`.
- 03-4: уход ingress-nginx (март 2026), ingress2gateway как путь миграции.
- 04-1: `immutable: true`, External Secrets Operator / SOPS — раздел (сейчас непроверено).
- 05-2: schedulingGates, DRA и GPU (DeviceClass, ResourceClaim), gang scheduling — теория; опц. работа dra-example-driver на kind.
- 05-3: VPA и автомасштабирование узлов (Cluster Autoscaler, Karpenter) — теория и схема, без лабы.
- 06-2: MutatingAdmissionPolicy (GA в 1.36) — работа вместо пометки «не проверено».
- 08-2: два kind-кластера и ApplicationSet cluster generator — многокластерность.
- 10-1: квота etcd 2 ГиБ (`--quota-backend-bytes`), авария `database space exceeded` и выход из неё.
- 10-2: version skew policy, deprecated API (метрика `apiserver_requested_deprecated_apis`, pluto), стратегия «новый кластер рядом», обновление аддонов; раздел «managed-кластеры»: что делает провайдер в EKS/GKE/AKS/Yandex MK.

### Вне курса — в другие курсы репозитория

- **observability**: Prometheus/VictoriaMetrics + kube-prometheus-stack, Grafana, Loki, OpenTelemetry, алерты на компоненты кластера, SLO, кардинальность метрик.
- **security**: Falco и runtime-детект, threat modeling кластера, проверка периметра, CIS для ОС узла.
- **cicd**: сборка образов (BuildKit, Kaniko), подпись в пайплайне, SBOM в CI, промоушен артефактов.
- **cloud**: managed-кластеры практикой (EKS/GKE/AKS/Yandex MK), IAM и workload identity, облачные LB/CSI, Karpenter, биллинг.
- **iac**: Terraform для кластеров, Cluster API — как инструмент IaC (в K8s — абзац).
- **linux**: минимизация ОС узла, AppArmor/SELinux на хосте, ядро для user namespaces.
- **networks**: eBPF/Cilium как dataplane (в K8s — абзац в 03-1).
- Курс Docker (зависимость): образы, multi-stage, минимальные базовые образы.

## 7. Лишнее или переразвитое

- **Модуль 11 против 12-2.** «Десять сломанных подов» (11-1), «восемь сетевых поломок» (11-2) и 21 тренажёр 12-2 сильно пересекаются. Предложение: 11-x оставить как методику (порядок проверки, инструменты, слои) с 3–4 опорными поломками, а массовые сценарии собрать только в 12-2.
- **Drain дважды**: 05-4 (Drain и PDB) и 10-3 (cordon, drain, uncordon). В 10-3 оставить только ссылку и сертификаты; освободившееся место — под kubeadm/PKI или Velero.
- **08-2 GitOps в масштабе** (три работы, Gitea + Argo CD) — тяжело для стенда. Работу «удаление окружения» можно сделать разделом; добавить вместо неё многокластерность.
- **09-1 CloudNativePG и failover** — дорогая работа (до 5 ГиБ) ради одной идеи оператора. Можно оставить, но свой маленький контроллер или CRD с CEL-валидацией дешевле и ближе к CKA; CNPG — опционально.
- **05-3 KEDA** — уместна, но если места нет, cron и scale-to-zero можно оставить, а VPA и Cluster Autoscaler (по программам и вопросам весомее) добавить теорией.
- **07-2 «Чужие чарты»**: если пример построен на Bitnami — проверить актуальность (в 2025 Bitnami перевёл бесплатные версионные образы в `bitnamilegacy`; утверждение по памяти, НЕ ПРОВЕРЕНО в этом исследовании). Иначе лаба сломается у читателя.
- **03-4 «Ingress без контроллера»** — полезно, но Ingress теперь вторичен; не расширять раздел Ingress, акцент — Gateway API.
- В целом переразвитых частей мало: перекос не «лишнее», а **недоразвитый модуль 06 (2 части против 20% CKA-домена + весь CKS)** и **отсутствие наблюдаемости**.

## 8. Рекомендации для модуля 12

### 12-1: вопросы, которых сейчас нет (с привязкой к будущим частям)

Junior:
- Чем labels отличаются от annotations; как Service находит поды.
- Что покажет `kubectl top` и откуда берутся цифры; почему без metrics-server HPA не работает.
- Где лежат логи контейнера на узле и почему `kubectl logs` пуст после рестарта (`--previous`).
- Что такое events и почему старого события уже нет (TTL 1 ч).

Middle:
- Как сделать canary без сервис-меша (доля реплик, веса HTTPRoute) и чем это хуже Argo Rollouts.
- Чем `RuntimeDefault` seccomp отличается от `Unconfined`; что даёт `readOnlyRootFilesystem`; какие capabilities есть по умолчанию.
- Ingress NGINX больше не поддерживается — что делать с Ingress-ресурсами (Ingress API жив; контроллер сменить или перейти на Gateway API).
- VPA против HPA: почему их нельзя включать на одну метрику CPU.
- Как узнать, что кластер использует deprecated API перед обновлением.
- Velero против etcd-снапшота: что восстанавливает каждый.
- Чем MutatingAdmissionPolicy отличается от mutating webhook.

Senior:
- Модели мультитенантности: namespace / узлы / vCluster / кластер — критерии выбора, «шумный сосед», CRD как общий ресурс.
- Audit policy: какие уровни, почему `RequestResponse` для Secret опасен, объём логов.
- Как запретить в кластере неподписанные образы и образы из чужих реестров; где хранить ключ; keyless.
- user namespaces: что меняется для root в контейнере, требования к ядру и ФС.
- API Priority and Fairness: откуда 429, как один контроллер может «положить» apiserver.
- etcd `database space exceeded`: причина, выход (compact + defrag + disarm alarm), профилактика.
- Пределы масштаба кластера и что ломается первым (etcd, apiserver watch-кэш, kube-proxy iptables, CoreDNS).
- Managed vs self-hosted: что вы теряете и получаете; кто отвечает за etcd, сертификаты, апгрейд; workload identity.
- Как считать стоимость namespace/команды; почему requests, а не usage, — база для FinOps.
- service mesh: когда нужен, цена (sidecar против ambient), mTLS против NetworkPolicy.
- DRA и GPU: почему device plugin недостаточно; gang scheduling для обучения.

Ловушки (дополнить):
- «Ingress устарел» — нет, устарел только контроллер ingress-nginx.
- «Secret зашифрован» — base64 ≠ шифрование; шифрование в etcd — отдельная настройка (04-1).
- «Velero бэкапит etcd» — нет, Velero работает через API.
- «CPU limit всегда нужен» — зависит, троттлинг (05-1).
- «PSA заменяет seccomp» — PSA только проверяет поля, профиль применяет runtime.

«Зависит, уточню»: мультитенантность (доверие между арендаторами, комплаенс), canary (есть ли метрики для анализа), DR (RPO/RTO, stateful или нет), managed или свой (команда, регион, требования к данным — для РФ Yandex MK/VK Cloud).

### 12-2: новые тренажёры

- Под отклонён PSA/seccomp-профилем, которого нет на узле.
- Неподписанный образ отклонён политикой Kyverno — найти причину по событию.
- Audit log не пишется: путь не смонтирован в static pod apiserver.
- etcd упёрся в квоту: кластер read-only.
- HTTPRoute canary: весь трафик уходит в одну версию (ошибка в `weight` или `backendRefs`).
- Velero restore «успешен», но PVC без данных (не включён FS backup).
- `kubectl top` — `Metrics API not available`.
- Арендатор исчерпал квоту — `exceeded quota` при rollout.

### 12-3: system design, которых нет (сейчас: платформа для 30 команд; поставка без простоя с GitOps; две зоны с DR)

1. **Безопасная цепочка поставки «от коммита до пода»**: сборка, SBOM, подпись, реестр, admission, аудит, отзыв уязвимого образа.
2. **Обновление флота из 20 кластеров** (1.34 → 1.36): skew policy, deprecated API, аддоны, канареечный кластер, in-place против «нового кластера рядом», критерии отката.
3. **Платформа наблюдаемости для кластеров** (граница с курсом observability): что собирать с компонентов, kube-state-metrics, логи, хранение, кардинальность, SLO control plane.
4. **Снижение стоимости кластера на 30%**: rightsizing по VPA, bin packing, spot + PDB, автомасштабирование узлов, OpenCost-отчёты по командам.
5. **ML/GPU-платформа**: DRA, очереди (Kueue), gang scheduling, квоты на GPU, изоляция команд.
6. **Миграция с ingress-nginx на Gateway API без простоя**: инвентаризация аннотаций, ingress2gateway, параллельный запуск, переключение DNS.
Мини-задачи: разбор инцидента «apiserver отвечает 429» (postmortem-шаблон); «выбрать модель мультитенантности для внешних клиентов»; «бэкап и DR для кластера с 5 stateful-сервисами» (etcd + Velero + бэкапы БД).

### 12-4: матрица самопроверки

Добавить строки: наблюдаемость кластера, изоляция контейнера, audit и supply chain, стратегии поставки, мультитенантность и FinOps, сборка кластера kubeadm, managed-кластеры (только «объясню»).

## 9. Что не открылось (для честности)

- PDF программ CNCF (cncf/curriculum) — бинарный поток не распарсился; cncf.io и training.linuxfoundation.org — DNS не резолвится. Программы — по зеркалам на GitHub и сниппетам.
- Оглавления: Production Kubernetes, Kubernetes: Up and Running 3e, Kubernetes Best Practices 2e (кроме гл. 20–22), The Kubernetes Book 2025 — не открылись; что указано «по памяти», помечено.
- roadmap.sh, habr.com — не резолвятся; данные по сниппетам и памяти (помечено).
