# Изменения Kubernetes 1.31 → 1.36 и экосистемы для курса (исследование 2026-10-19)

Статус: готово (2026-10-19). Структура: §1 сырые заметки по релизам и темам; §2 таблица по частям; §3 экосистема; §4 кандидаты в новые части; §5 что в плане устарело; §6 не подтверждено. Источники — GitHub kubernetes/website (блог релизов), CHANGELOG, KEP, блоги проектов.

## 1. Сырые заметки по релизам

### 1.37 (Garhwal, вышел 2026-08-26; последний патч 1.37.1) — вышел после 1.36, стенд на 1.36
Источник: https://raw.githubusercontent.com/kubernetes/kubernetes/master/CHANGELOG/CHANGELOG-1.37.md ; https://kubernetes.io/releases/1.37/ (через поиск)
- Urgent: SELinuxMount GA и включён по умолчанию — может сломать нагрузки на SELinux-кластерах.
- kubelet eventRecordQPS: 0 теперь = без лимита. Стартовые логи kubelet содержат конфиг → ограничить роль nodes/logs.
- kubeadm явно ставит KubeProxyConfiguration.mode=iptables, если не задан; kube-proxy предупреждает, если режим не задан явно, — готовится переход на nftables по умолчанию. Предупреждение об устаревании ipvs (устарел с 1.35); новый alpha-гейт KubeProxyIPVS (подготовка к удалению ipvs).
- Удалены ~18 устаревших флагов cAdvisor у kubelet (запуск падает), кроме --housekeeping-interval.
- SchedulerPreQueueingHints понижен beta → alpha.
- GA: SELinuxMount, PodCertificateRequest, HostnameOverride, ClusterTrustBundle(+Projection), NodeDeclaredFeatures, StorageVersionMigration, HPAConfigurableTolerance, DRA device taints/tolerations, DRA extended resource, DRAResourceClaimDeviceStatus, InPlacePodVerticalScalingInitContainers, PLEGOnDemandRelist, RelaxedServiceNameValidation, PodReadyToStartContainers condition, metrics.k8s.io v1, `kubectl get -o kyaml` stable.
- Beta: WatchListCompression, EtcdRangeStream, ManifestBasedAdmissionControlConfig (on), MemoryQoS, MaxUnavailableStatefulSet (on), PersistentVolumeClaimUnusedSinceTime (on), KubeletInUserNamespace, PodGroup/Workload → scheduling.k8s.io/v1beta1.
- По поиску (beta.0 notes, не сверено с CHANGELOG): новая стратегия StatefulSet Recreate; etcd 3.7.0 по умолчанию — не подтверждено.
- Вторичный источник (поиск): «сроки удаления kube-dns, kube-proxy (ipvs?), cgroup v1» — не подтверждено в деталях.

#### 1.37 — официальный блог релиза (сверено)
URL: https://raw.githubusercontent.com/kubernetes/website/main/content/en/blog/_posts/2026/kubernetes-v1-37-release/index.md
- Stable: resilient watchcache init (429 вместо перегрузки etcd); metrics.k8s.io v1 (KEP-5207); SELinuxMount + SELinuxChangePolicy (KEP-1710); KYAML (`kubectl get -o kyaml`); DRA device status/extended resource/device taints/numaNode; NodeDeclaredFeatures; Storage Version Migrator in-tree (KEP-4192); Pod certificates (KEP-4317, projected volume podCertificate); ClusterTrustBundle (KEP-3257); FQDN как hostname пода (KEP-4762, hostnameOverride); HPA configurable tolerance (KEP-4951); relaxed Service name validation; resource health status в Pod status; condition PodReadyToStartContainers (KEP-3085).
- Beta: etcd RangeStream (KEP-5966, нужен etcd 3.7+); stale controller mitigation; gang scheduling (KEP-4671), workload-aware preemption; HPA scale-to-zero (KEP-2021, on, для Object/External метрик); manifest-based admission control (KEP-5793); удаление нерасшифровываемых ресурсов (KEP-3926); native histograms; CRI-stats без cAdvisor (выкл.); Memory QoS (KEP-2570, memory.min/low/high); pod-level resource managers (выкл.); storage capacity scoring (KEP-4049); PVC last-used time (условие Unused, on).
- Alpha: pod checkpoint/restore (KEP-5823); StatefulSet Recreate strategy (KEP-3541, гейт StatefulSetRecreateStrategy); scheduler preemption для in-place resize; dynamic resize memory-backed emptyDir; node lifecycle conditions (drain/maintenance); Job spec.scheduling (gang); localhost NodePort proxy для nftables (KEP-6032).
- Прочее: StatefulSet maxUnavailable снова on после бага 1.36 (kubernetes#137409); nftables-режим kube-proxy работает через netlink, без CLI `nft`.
- Устарело: kube-dns (пакеты не собираются после 1.40, переход на CoreDNS); ipvs (KEP-5495): в 1.40 выключен по умолчанию (через гейт), в 1.43 удалён — план; проверка `kubectl -n kube-system get cm kube-proxy -o jsonpath='{.data.config\.conf}' | grep mode:`; cgroup v1: failCgroupV1=true с 1.35, в 1.37 ещё можно `failCgroupV1: false`; `kubectl run -f` устарел.
- Удалено: static pods не могут ссылаться на Secret/ConfigMap (configMapRef/secretRef), гейт PreventStaticPodAPIReferences удалён.

### 1.36 (Haru, вышел 2026-04-22; последний патч 1.36.5)
Источник: https://raw.githubusercontent.com/kubernetes/kubernetes/master/CHANGELOG/CHANGELOG-1.36.md
- GA: ImageVolume, UserNamespacesSupport, MutatingAdmissionPolicy (по вторичным источникам), KubeletFineGrainedAuthz, SELinux… (вторичный источник: SELinux volume labeling GA — в 1.37 CHANGELOG SELinuxMount GA; уточнить), VolumeGroupSnapshot GA (вторичный).
- Beta: InPlacePodLevelResourcesVerticalScaling (on), DRA binding conditions, DRA device taints.
- Удалено/выключено: gitRepo volume выключен без возможности включить; kubeadm убрал flex-volume.
- Устарело: Service.spec.externalIPs (предупреждения; перестанет работать в 1.43 по KEP).
- Alpha: ManifestBasedAdmissionControlConfig (статические admission-манифесты), PersistentVolumeClaimUnusedSinceTime, MemoryReservationPolicy (memory.min).
- Resize выше allocatable теперь отклоняется на admission, а не Infeasible.

#### 1.36 — официальный блог релиза (сверено)
URL: https://raw.githubusercontent.com/kubernetes/website/main/content/en/blog/_posts/2026/kubernetes-v1-36-release/index.md
- Stable: fine-grained kubelet API authz (KEP-2862, вместо nodes/proxy); VolumeGroupSnapshot (KEP-3476); mutable CSINode allocatable (KEP-4876); external SA token signing (KEP-740); DRA AdminAccess (5018), DRA prioritized alternatives (4816); MutatingAdmissionPolicy (KEP-3962); declarative validation; node log query (KEP-2258, `kubectl get --raw /api/v1/nodes/<n>/proxy/logs/?query=kubelet`); user namespaces (KEP-127); PSI метрики cgroup v2 (KEP-4205); image volume (KEP-4639); SELinux mount -o context для томов (KEP-1710; в 1.36 — SELinuxMountReadWriteOncePod-часть; полный SELinuxMount GA в 1.37 по CHANGELOG — уточнить формулировку); Portworx → CSI; ProcMount (KEP-4265); DRA в PodResources; split L3 cache в CPU Manager; CSI SA tokens через secrets.
- Beta: allocatedResourcesStatus (здоровье устройств); staleness mitigation контроллеров; StrictIPCIDRValidation; kubectl .kuberc (KEP-3104) — beta в 1.36 (была beta уже с 1.34? см. 1.34); mutable resources у suspended Jobs; constrained impersonation (KEP-5284); DRA partitionable/consumable capacity/device taints/device status/binding conditions; /statusz и /flagz; mixed version proxy; Memory QoS cgroup v2 (KEP-2570, memory.high/memory.min).
- Alpha: workload-aware (gang) scheduling, PodGroup; HPA scale-to-zero для Object/External метрик (KEP-2021; в 1.37 beta — блог kubernetes-v1-37-hpa-scale-to-zero-beta); native histograms; manifest-based admission config; CRI list streaming.
- Ingress NGINX retired 2026-03-24 (SIG Network + SRC): релизов, багфиксов и патчей безопасности больше нет; существующие установки работают.
- Устарело: Service .spec.externalIPs (KEP-5707) — предупреждения с 1.36, удаление планируется в 1.43; CVE-2020-8554; альтернативы — LoadBalancer/NodePort/Gateway API.
- Удалено: gitRepo volume окончательно выключен (KEP-5040) — замена init-контейнер / git-sync.

### 1.35 (Timbernetes, 2025-12-17)
URL: https://raw.githubusercontent.com/kubernetes/website/main/content/en/blog/_posts/2025/kubernetes-v1-35-release/index.md
- Stable: in-place resize (KEP-1287, InPlacePodVerticalScaling); trafficDistribution PreferSameNode GA + PreferClose переименован в PreferSameZone (KEP-3015); Job managedBy (KEP-4368); Pod metadata.generation + status.observedGeneration (KEP-5067); topology manager max-allowable-numa-nodes (вместо жёстких 8); CPUManager reservedSystemCPUs strict; fine-grained supplementalGroups (KEP-3619); kubelet drop-in config dir (KEP-3983, `--config-dir`); image GC по максимальному возрасту (KEP-4210, imageMaximumGCAge); лимит параллельных pull (KEP-3673, maxParallelImagePulls); kubectl метаданные в заголовках; SPDY → WebSockets (KEP-4006, exec/attach/port-forward).
- Beta: Pod certificates/PodCertificateRequest (KEP-4317, mTLS без bearer-токенов); node topology labels через downward API (KEP-4742); native storage version migration (KEP-4192); mutable CSINode allocatable; opportunistic batching в планировщике; StatefulSet maxUnavailable (KEP-961, beta, по умолчанию 1); kuberc credentialPluginPolicy/allowlist; KYAML beta (`kubectl get -o kyaml`, KUBECTL_KYAML=false — выключить); HPA configurable tolerance beta (KEP-4951, по умолчанию 10%); user namespaces beta (id-mapped mounts); image volume beta, включён по умолчанию, нужен containerd 2.1+; проверка credentials для кэшированных образов (KEP-2535, KubeletEnsureSecretPulledImages, on); ContainerRestartRules beta (KEP-5307, restartPolicy и restartPolicyRules у контейнера); CSI SA tokens через secrets; Deployment status.terminatingReplicas (KEP-3973).
- Alpha: NodeDeclaredFeatures; gang scheduling (Workload/PodGroup); constrained impersonation; extended toleration operators (Gt/Lt); mutable resources у suspended Job.
- DRA core всегда включён (GA в 1.34).
- Удалено: поддержка cgroup v1 в kubelet (KEP-5573) — kubelet не стартует без cgroup v2 (по умолчанию failCgroupV1=true; уточнить).
- Устарело: kube-proxy ipvs (KEP-5495) — предупреждение при старте; замена nftables.
- containerd 1.x: 1.35 — последний релиз с поддержкой; метрика kubelet_cri_losing_support.
- KEP-4781: kubelet при рестарте восстанавливает состояние контейнеров — поды остаются Ready.

### 1.34 (Of Wind & Will, 2025-08-27)
URL: https://raw.githubusercontent.com/kubernetes/website/main/content/en/blog/_posts/2025/kubernetes-v1-34-release/index.md
- Stable: DRA core resource.k8s.io/v1 (KEP-4381); Job podReplacementPolicy (KEP-3939); recovery from volume expansion failure (KEP-1790); VolumeAttributesClass (KEP-3751, storage.k8s.io/v1); structured authentication configuration (KEP-3331, --authentication-config, несколько JWT-issuer, CEL, hot reload); authorization по field/label selectors (KEP-4601); anonymous auth только на заданных endpoints (KEP-4633); scheduler QueueingHints (KEP-4247); ordered namespace deletion (KEP-5080, сначала поды); streaming encoding LIST (KEP-5116); resilient watch cache init; relaxed DNS search validation (точка первой); lifecycle sleep action (KEP-3960) + zero sleep (KEP-4818); swap на Linux (KEP-2400, NoSwap по умолчанию, LimitedSwap); printable ASCII в именах env; TaintManager отделён; API server tracing; AppArmor (KEP-24, поле securityContext.appArmorProfile; аннотации устарели); consistent reads from cache (KEP-2340); cgroup driver из CRI (KEP-4033); kubelet OTel tracing.
- Beta: pod-level resources (KEP-2837, spec.resources); .kuberc (KEP-3104, on); external SA token signing; DRA admin access/prioritized list; mutating admission policies beta (KEP-3962); snapshottable apiserver cache (KEP-4988); WatchList (KEP-3157, on в apiserver и KCM); in-place resize: уменьшение памяти; PreferSameZone/PreferSameNode beta; projected SA tokens для image pull (KEP-4412).
- Alpha: KYAML (KUBECTL_KYAML=true); Pod certificates; restricted PSS запрещает probe host (KEP-4940); nominatedNodeName; ContainerRestartRules alpha (KEP-5307); EnvFiles (KEP-3721).
- Устарело: ручной cgroupDriver в kubelet (не раньше 1.36 удалят); PreferClose → PreferSameZone; containerd 1.x (последний — 1.35).

### 1.33 (Octarine, 2025-04-23)
URL: https://raw.githubusercontent.com/kubernetes/website/main/content/en/blog/_posts/2025/kubernetes-v1-33-release/index.md
- Stable: нативные sidecar (KEP-753, initContainers restartPolicy: Always); backoffLimitPerIndex (KEP-3850); Job successPolicy (KEP-3998); bound SA token improvements (KEP-4193, jti, node binding); kubectl --subresource (KEP-2590); multiple ServiceCIDR (KEP-1880, networking.k8s.io/v1 ServiceCIDR/IPAddress); nftables kube-proxy GA (KEP-3866; iptables остаётся по умолчанию); topology-aware routing + trafficDistribution PreferClose GA (KEP-2433/4444); CPU Manager full-pcpus-only; matchLabelKeys/mismatchLabelKeys в affinity (KEP-3633); nodeAffinityPolicy/nodeTaintsPolicy в topologySpread (KEP-3094); volume populators (KEP-1495); always honor PV reclaim policy (KEP-2644); CRD validation ratcheting (KEP-4008); recursive read-only mounts (KEP-3857, recursiveReadOnly: Enabled/IfPossible).
- Beta: in-place resize beta (вкл. по умолчанию); ClusterTrustBundle beta; supplementalGroupsPolicy beta; image volume beta (выкл. по умолчанию в 1.33); user namespaces on by default (hostUsers: false); procMount beta; zero PreStop sleep.
- Alpha: .kuberc; HPA configurable tolerance; KubeletCrashLoopBackOffMax (KEP-4603); lifecycle.stopSignal (KEP-4960); DRA device taints/prioritized list/admin access/partitionable; KubeletEnsureSecretPulledImages (KEP-2535); node topology labels downward API; Pod generation/observedGeneration; PSI метрики; secret-less image pulls (KEP-4412).
- Устарело: Endpoints API (KEP-4974) → EndpointSlice (предупреждения при использовании v1 Endpoints).
- Удалено: status.nodeInfo.kubeProxyVersion; код gitRepo-драйвера (гейт GitRepoVolumeDriver до 1.39; в 1.36 окончательно выключен); hostNetwork у Windows-подов.

### 1.32 (Penelope, 2024-12-11)
URL: https://raw.githubusercontent.com/kubernetes/website/main/content/en/blog/_posts/2024/kubernetes-v1-32-release/index.md
- Stable: field selectors для CR (KEP-4358); размер memory-backed emptyDir по лимитам пода (KEP-1967); bound SA token: имя узла в claims (KEP-4193); structured authorization configuration (KEP-3221, --authorization-config, цепочка авторизаторов, CEL matchConditions у webhook); StatefulSet PVC auto-delete (persistentVolumeClaimRetentionPolicy, KEP-1847); LoadBalancer ipMode (KEP-1860); status.hostIPs; kubectl debug --custom профили; Memory Manager; pod index label для StatefulSet/Indexed Job (apps.kubernetes.io/pod-index).
- Beta: Job managedBy; anonymous auth config; QueueingHints; recovery from expansion failure; VolumeGroupSnapshot beta; DRA structured parameters; authz по selectors.
- Alpha: async preemption; MutatingAdmissionPolicy alpha; pod-level resources alpha; zero PreStop sleep; /statusz /flagz.
- Удалено: classic DRA; flowcontrol.apiserver.k8s.io/v1beta3 (FlowSchema/PriorityLevelConfiguration → v1).

### 1.31 (Elli, 2024-08-13)
URL: https://raw.githubusercontent.com/kubernetes/website/main/content/en/blog/_posts/2024/kubernetes-v1-31-release.md
- Stable: AppArmor (KEP-24, securityContext.appArmorProfile); kube-proxy connection draining для терминирующихся узлов за LB (KEP-3836); PV status.lastTransitionTime; PDB unhealthyPodEvictionPolicy (KEP-3017; AlwaysAllow/IfHealthyBudget); Job podFailurePolicy (KEP-3329); elastic Indexed Jobs; StatefulSet .spec.ordinals.start; случайный выбор подов при scale down ReplicaSet; cgroup v1 в maintenance mode (KEP-4569).
- Beta: nftables kube-proxy (ядро 5.13+); ServiceAccountTokenNodeBinding; multiple ServiceCIDR (выкл.); trafficDistribution (вкл.); VolumeAttributesClass beta.
- Alpha: DRA structured; image volumes (ImageVolume); allocatedResourcesStatus; authz по selectors; anonymous auth config.
- Удалено: in-tree cloud providers (KEP-2395) — только внешние CCM; cephfs и rbd in-tree плагины; --keep-terminated-pod-volumes. SHA-1 сертификаты отвергаются. kubeProxyVersion устарел.
- (1.30, 2024-04: ValidatingAdmissionPolicy GA admissionregistration.k8s.io/v1 — по памяти и блогу validating-admission-policy-ga; базовая точка курса.)

### Сеть: отдельные посты
- Ingress NGINX: объявление о выводе — ноябрь 2025 (блог 2025/ingress-nginx-retirement.md); заявление SIG Network + SRC 2026-01-29; retired 2026-03-24: без релизов и патчей безопасности; ~50% облачных сред используют (оценка Datadog). Проверка: `kubectl get pods -A --selector app.kubernetes.io/name=ingress-nginx`. Замена — Gateway API или сторонний Ingress-контроллер; drop-in замены нет. Инструмент ingress2gateway v1.0 (блог 2026/ingress2gateway-v1-0-release.md). CVE-2025-1974 (IngressNightmare, март 2025, блог 2025/ingress-nginx-cve-2025-1974.md).
  URL: https://raw.githubusercontent.com/kubernetes/website/main/content/en/blog/_posts/2026/ingress-nginx-statement.md
- ipvs: устарел в 1.35 (KEP-5495). Пост ipvs-deprecation: удаление планируется в 1.40. Блог релиза 1.37: в 1.40 выключен по умолчанию (через гейт), в 1.43 удалён — расхождение источников, давать «план: 1.40–1.43». Рекомендация — nftables на 1.36+ и ядре 5.13+ (фиксы производительности после 1.33 не бэкпортированы); при переходе с ipvs на iptables — перезагрузка узла. В nftables и iptables выбор эндпоинта случайный. RHEL планирует убрать iptables API.
  URL: https://raw.githubusercontent.com/kubernetes/website/main/content/en/blog/_posts/2026/ipvs-deprecation/index.md
- Gateway API: v1.2 (окт. 2024: HTTPRoute timeouts/retry? — не сверено); v1.3 (2025-04-24): процентное зеркалирование GA; эксперим. CORS, XListenerSet, retry budget (XBackendTrafficPolicy); эксперим. ресурсы с префиксом X в gateway.networking.x-k8s.io. v1.4 (2025-10-06): BackendTLSPolicy GA (Standard), supportedFeatures в GatewayClass, именованные правила маршрутов; эксперим. Mesh, default gateways, externalAuth; GRPCRoute .spec обязателен. v1.5 (2026-02-27, есть 1.5.1): Standard — ListenerSet, TLSRoute v1 (Passthrough/Terminate), CORS filter, frontend mTLS (client cert validation, AllowValidOnly), clientCertificateRef для TLS к бэкенду, ReferenceGrant v1; release train. Внимание: Standard поверх старых experimental ломает TLSRoute v1alpha2/v1alpha3. v1.6 (2026-06-30): TCPRoute и UDPRoute → v1 Standard; эксперим. XBackend, XMesh.
  URL: https://raw.githubusercontent.com/kubernetes/website/main/content/en/blog/_posts/2026/gateway-api-v1-5/index.md , .../2026/gateway-api-v1-6-release/index.md , .../2025/gateway-api-v1-4/index.md , .../2025/gateway-api-v1-3/index.md

### etcd и kubeadm
- etcd 3.6.0 (2025-05-15): v2store удалён (`--enable-v2` нет; проверка `etcdutl check v2store`), память −50%, `--snapshot-count` по умолчанию 100000 → 10000; feature gates вместо `--experimental-*`; первая версия с полноценным downgrade; /livez и /readyz. Обновляться с 3.5.20+.
  URL: https://raw.githubusercontent.com/kubernetes/website/main/content/en/blog/_posts/2025/announcing-etcd-3-6/index.md
- etcd 3.7.0 (2026-07-08): RangeStream (нужен для гейта EtcdRangeStream, beta on в 1.37), keys-only из индекса, приоритет отзыва lease, удалены v2 discovery/client и флаги `--experimental-*`; образы только multiarch. Перед ним — 3.6.11+.
  URL: https://raw.githubusercontent.com/kubernetes/website/main/content/en/blog/_posts/2026/etcd-3-7.md
- kubeadm 1.36: etcd по умолчанию 3.6.8-0, CoreDNS v1.14.2, pause 3.10.2; kubeadm 1.37: etcd 3.7.0-0, CoreDNS v1.14.6. Перекос версий: kubelet до −3 минорных, control plane −1.
  URL: https://raw.githubusercontent.com/kubernetes/kubernetes/release-1.36/cmd/kubeadm/app/constants/constants.go , .../release-1.37/...
- kubeadm v1beta4 введён в 1.31 (блог 2024-08-23 kubernetes-1-31-kubeadm-v1beta4): новая структура timeouts вместо timeoutForControlPlane, extraArgs списком name/value; v1beta3 устарел, удаление «не раньше чем через 3 минорных» — конкретный релиз удаления не подтверждён. Миграция `kubeadm config migrate`.
- kind (https://github.com/kubernetes-sigs/kind/releases): 0.30 (27 авг 2025, k8s 1.34.0, containerd 2.1.4); 0.31 (18 дек 2025, k8s 1.35.0; образы этих версий без cgroup v1; предупреждение о v1beta4); 0.32 (02 июн 2026, k8s 1.36.1; kubeadm v1beta4 для 1.36+ — патчи kubeadmConfigPatches должны быть v1beta4; Envoy вместо HAProxy для multi-control-plane LB; новые образы требуют новую kind для `kind load`; предупреждение при cgroup v1 на хосте; поддержка containerd config v4); 0.33 (26 авг 2026, k8s 1.37.0).
- kind 0.32 образ k8s 1.36.1 — etcd внутри по версии kubeadm (3.6.x) — вывод, не проверено.

### Runtime: containerd
URL: https://raw.githubusercontent.com/containerd/containerd/main/RELEASES.md
- 1.7 EOL 2026-09-30; 2.0 LTS (2024-11-05, расширенная поддержка до 03.2027); 2.1 (2025-05-07); 2.2 (2025-11-05); 2.3 — первая годовая LTS (2026-04-30, до 2028-04-30); 2.4 (2026-09-16, не LTS). Каденция ~4 месяца, согласована с k8s.
- Матрица: k8s 1.35 → 2.2.0+/2.1.5+/1.7.28+; 1.36 → 2.3.0+/2.2.0+ (1.7 не поддерживается — согласуется с KEP-4033); 1.37 → 2.4.0+/2.3.0+.
- Конфиг: version = 3 — containerd 2.0+; version = 4 — containerd 2.3+ (последняя). Старые конфиги мигрируются в памяти при каждом старте; `containerd config migrate` печатает в новом формате; после миграции на v4 откат на <2.3 невозможен.
- Image volume требует containerd 2.1+ (блог 1.35).

### Узел: cgroup, restart rules
- cgroup v1: 1.25 v2 stable; 1.31 v1 maintenance; 1.35 failCgroupV1=true по умолчанию, kubeadm preflight SystemVerification — ошибка; 1.36 — обход `failCgroupV1: false` ещё работает, удаление запланировано на 1.38 (KEP-5573). Проверка: `stat -fc %T /sys/fs/cgroup/` → `cgroup2fs`. Требования: ядро 5.8+ (5.9+ для Memory QoS), containerd 2.0+ для автоопределения cgroup driver. Новая формула cpu.shares → cpu.weight в crun 1.23 и runc 1.3.2 — значения cpu.weight в лабе QoS могут отличаться от старой формулы (блог 2026/new-cgroup-v1-to-v2-conversion-formula). Проблема active_file в вытеснении (k8s#43916) не решена.
  URL: https://raw.githubusercontent.com/kubernetes/website/main/content/en/blog/_posts/2026/kubernetes-cgroups-v2-shift.md
- RestartAllContainers: гейт RestartAllContainersOnContainerExits, alpha 1.35; действие `RestartAllContainers` в restartPolicyRules контейнера — перезапуск пода на месте, включая init и sidecar. Расширяет ContainerRestartRules (beta 1.35, on).
  URL: https://raw.githubusercontent.com/kubernetes/website/main/content/en/blog/_posts/2026/restart-all-containers.md

- Формула cpu.shares → cpu.weight: старая `1 + ((shares-2)*9999)/262142` (1 CPU → 39, 100m → 4); новая квадратичная по log2 (1 CPU → ~100–102, 100m → 17); runc 1.3.2+, crun 1.23+. Отображение многие-к-одному (90–109m → 17). Для лабы 05-1 (QoS и cgroup): цифры cpu.weight в выводе зависят от версии runc в узле kind — сверить с выводом прогона 2026-10-14.
  URL: https://raw.githubusercontent.com/kubernetes/website/main/content/en/blog/_posts/2026/new-cgroup-v1-to-v2-conversion-formula/index.md

### Feature gates (kubernetes/website main, docs/reference/command-line-tools-reference/feature-gates/<Gate>.md)
- KubeletCrashLoopBackOffMax: alpha 1.32–1.34, beta on 1.35+.
- PodLevelResources: alpha 1.32–1.33, beta on 1.34+. InPlacePodLevelResourcesVerticalScaling: beta on в 1.36. PodLevelResourceManagers: beta, выкл. в 1.37.
- ContainerRestartRules: alpha 1.34, beta on 1.35+.
- CoordinatedLeaderElection: alpha 1.31–1.32, beta **выкл.** 1.33+ (LeaseCandidate API) — не включён по умолчанию.
- NodeSwap: stable 1.34 (locked); нужен failSwapOn: false; swapBehavior NoSwap (по умолчанию)/LimitedSwap.
- SchedulerQueueingHints: stable 1.34. (SchedulerPreQueueingHints понижен в alpha в 1.37 — другой гейт.)
- MemoryQoS: alpha 1.22–1.36, beta on 1.37 (memoryThrottlingFactor → memory.high; memoryReservationPolicy: TieredReservation → memory.min/low). Расхождение: блог релиза 1.36 пишет «beta», файл гейта и пост cgroups-v2 — alpha в 1.36. Верно: alpha в 1.36, beta в 1.37.
- SELinuxMount: alpha 1.30–1.32, beta выкл. 1.33–1.36, stable on 1.37. В 1.36 «стабильной» названа часть KEP-1710 (SELinuxChangePolicy/SELinuxMountReadWriteOncePod) — формулировка блога 1.36 неточна, опираться на гейт.

### Ресурсы: resize, VPA
- In-place resize GA 1.35 (alpha 1.27, beta 1.33): подресурс `resize` (`kubectl patch pod … --subresource resize`), spec — желаемое, status.containerStatuses[].resources — фактическое; уменьшение лимита памяти разрешено (best-effort проверка); отложенные resize по PriorityClass → QoS → давности; нельзя со swap, static CPU/Memory Manager; только CPU и память. 1.36: resize сверх allocatable отклоняется на admission. 1.37: resize init-контейнеров GA; alpha — вытеснение ради resize.
  URL: https://raw.githubusercontent.com/kubernetes/website/main/content/en/blog/_posts/2025/ippr-goes-ga.md
- VPA: InPlaceOrRecreate — alpha 1.4, beta 1.5, GA и включён по умолчанию в VPA 1.6.0 (#9082); в 1.5 режим Auto устарел (остались Recreate и InPlaceOrRecreate, Off/Initial). Источник 1.6.0 — зеркало и Gardener; официальную страницу релиза не открыл — частично подтверждено.
  URL: https://gardener.cloud/docs/gardener/autoscaling/in-place-resource-updates/ ; https://github.com/kubernetes/autoscaler/releases/tag/vertical-pod-autoscaler-1.6.0

- VPA 1.6.0 (12 фев 2026, подтверждено на github.com/kubernetes/autoscaler/releases/tag/vertical-pod-autoscaler-1.6.0): InPlaceOrRecreate GA, on (#9082); Auto устарел (с 1.5, #9073).

### NetworkPolicy API
- AdminNetworkPolicy/BaselineAdminNetworkPolicy (v1alpha1) заменены ClusterNetworkPolicy v1alpha2 (дизайн — блог 2025-10-09; релиз network-policy-api v0.2.0 — 2026-06-02): один CRD с полем tier: Admin | Baseline; действие Allow → Accept; ports → protocols; максимум правил/пиров 100 → 25. Реализации: kube-network-policies (эталонная), Calico, Kube-OVN. Beta — ориентир KubeCon NA 2026. В kindnet поддержка — не подтверждено.
  URL: https://network-policy-api.sigs.k8s.io/blog/2025/10/09/api-update-for-v1alpha2-clusternetworkpolicy-replaces-adminnetworkpolicy-and-baselineadminnetworkpolicy/ ; https://groups.google.com/a/kubernetes.io/g/sig-network/c/ZuHtOKsgJNo/m/E7lAk23TDAAJ

### Service: Endpoints и externalIPs
- v1 Endpoints устарел в 1.33 (KEP-4974): предупреждение `Warning: v1 Endpoints is deprecated in v1.33+; use discovery.k8s.io/v1 EndpointSlice`; тип, вероятно, не удалят, но контроллер Endpoints перестанет быть обязательным для conformance. EndpointSlice искать по метке `kubernetes.io/service-name`; слайсов несколько (dual-stack, порты, >100 эндпоинтов); готовность — условия на эндпоинте.
  URL: https://raw.githubusercontent.com/kubernetes/website/main/content/en/blog/_posts/2025/endpoints-deprecation.md
- externalIPs: 1.36 предупреждение; не раньше 1.40 kube-proxy выключает по умолчанию (opt-in); не раньше 1.43 удаление. Альтернативы: LoadBalancer (MetalLB), Gateway .spec.addresses. Рекомендуется admission DenyServiceExternalIPs.
  URL: https://raw.githubusercontent.com/kubernetes/website/main/content/en/blog/_posts/2026/deprecation-of-service-externalips.md

- KMSv1: deprecated, выкл. по умолчанию с 1.29 (KMS v2 GA в 1.29).
- WatchList: alpha 1.27–1.31, beta on 1.32, beta off 1.33, beta on 1.34+.
- DynamicResourceAllocation: stable 1.34, locked 1.35+.
- PodObservedGenerationTracking: alpha 1.33, beta 1.34, stable locked 1.35.
- kubectl 1.36 встраивает kustomize v5.8.1 (staging/src/k8s.io/kubectl/go.mod, release-1.36). Kustomize 5.8.0 — регрессия namespace-пропагации, исправлено в 5.8.1.

### kubectl: KYAML и kuberc
- KYAML (KEP-5295): строгое подмножество YAML (все строки в кавычках, {} и [], не зависит от отступов, `---` заголовок; решает «Norway problem» NO → false). 1.34 alpha (KUBECTL_KYAML=true), 1.35 beta (on, но нужен `-o kyaml`), 1.37 stable. Делать KYAML выводом по умолчанию не планируют.
  URL: https://raw.githubusercontent.com/kubernetes/website/main/content/en/blog/_posts/2026/how-to-pretty-print-kubernetes-yaml-as-kyaml.md
- kuberc (KEP-3104): `apiVersion: kubectl.config.k8s.io/v1beta1`, `kind: Preference`; алиасы и defaults отдельно от kubeconfig (файл ~/.kube/kuberc, переменная KUBERC — по памяти, не сверено). 1.33 alpha, 1.34 beta on. Команда `kubectl kuberc set --section defaults --command get --option output=kyaml` — с 1.36; в 1.33–1.35 — `kubectl alpha kuberc`. credentialPluginPolicy (AllowAll | DenyAll | Allowlist) + credentialPluginAllowlist — beta 1.35; в 1.36 поле записи allowlist `name` переименовано в `command` (CHANGELOG-1.36: AllowlistEntry.Name → Command).
  URL: https://raw.githubusercontent.com/kubernetes/website/main/content/en/blog/_posts/2026/kuberc-plugin-allowlist.md

### Прочие посты
- User namespaces GA 1.36 (Linux): `hostUsers: false`; id-mapped mounts (ядро 5.12+) убирают рекурсивный chown; capabilities вроде CAP_NET_ADMIN становятся «внутренними». Требования к runtime (containerd 2.0+, runc 1.2+, ядро 6.3+) — по памяти, в посте нет, не подтверждено.
  URL: https://raw.githubusercontent.com/kubernetes/website/main/content/en/blog/_posts/2026/user-namespaces-goes-ga.md
- KubeletFineGrainedAuthz: alpha 1.32, beta on 1.33, GA locked 1.36. Подресурсы nodes/metrics, nodes/stats, nodes/log, nodes/pods, nodes/healthz, nodes/configz; fallback на nodes/proxy. nodes/proxy = суперпользователь узла (даже GET через WebSocket даёт exec).
  URL: https://raw.githubusercontent.com/kubernetes/website/main/content/en/blog/_posts/2026/fine-grained-kubelet-authz.md
- ingress2gateway 1.0 (2026-03-20): 30+ аннотаций ingress-nginx; `ingress2gateway print --namespace X --providers=ingress-nginx`; `--emitter envoy-gateway|kgateway|agentgateway`; configuration-snippet и proxy-body-size не переводятся; regex → case-insensitive prefix.
  URL: https://raw.githubusercontent.com/kubernetes/website/main/content/en/blog/_posts/2026/ingress2gateway-v1-0-release.md
- Нативный sidecar и порядок запуска: readinessProbe сайдкара НЕ задерживает основной контейнер; задерживают startupProbe или postStart на сайдкаре; livenessProbe перезапускает только сайдкар.
  URL: https://raw.githubusercontent.com/kubernetes/website/main/content/en/blog/_posts/2025/start-sidecar-first/index.md

- Pod Security: контроль «Host Probes / Lifecycle Hooks» (поле host в httpGet/tcpSocket проб и хуков должно быть пустым) — в профиле **Baseline**, с v1.34 (KEP-4940; блог 1.34 писал «Restricted» — по документу PSS это Baseline). Новые разрешённые sysctl в Baseline: tcp_rmem/tcp_wmem (1.32+), tcp_slow_start_after_idle/tcp_notsent_lowat (1.37+).
  URL: https://raw.githubusercontent.com/kubernetes/website/main/content/en/docs/concepts/security/pod-security-standards.md
- HPA tolerance: `spec.behavior.scaleUp.tolerance` / `scaleDown.tolerance` (доля, например 0.05); по умолчанию 0.1; alpha 1.33, beta 1.35, GA 1.37.
  URL: https://raw.githubusercontent.com/kubernetes/website/main/content/en/blog/_posts/2025/hpa-configurable-tolerance.md

## 2. Таблица по частям

Сокращения URL: `B/` = https://raw.githubusercontent.com/kubernetes/website/main/content/en/blog/_posts/ ; `FG/` = https://raw.githubusercontent.com/kubernetes/website/main/content/en/docs/reference/command-line-tools-reference/feature-gates/ ; `CL36`/`CL37` = https://raw.githubusercontent.com/kubernetes/kubernetes/master/CHANGELOG/CHANGELOG-1.36.md / -1.37.md. Релизные посты: R31 = B/2024/kubernetes-v1-31-release.md, R32 = B/2024/kubernetes-v1-32-release/index.md, R33…R37 = B/2025|2026/kubernetes-v1-3X-release/index.md.

Действия: «раздел» — новый раздел ## или ### в теории; «фраза» — фраза в теории; «лаба» — в лабораторную; «анти-рецепт»; «новая часть»; «12» — в банк вопросов/ловушки модуля 12.

### Общее (00-1, 00-2, 01-x)

| Часть | Изменение | Версия / стадия | Действие | URL |
|---|---|---|---|---|
| 00-1 | Вышел 1.37 (2026-08-26), kind 0.33 (k8s 1.37.0); стенд остаётся 1.36.1 | 1.37 GA | фраза: курс на 1.36, отличия 1.37 отмечены | R37; github.com/kubernetes-sigs/kind/releases |
| 00-1 | kind 0.32: kubeadm v1beta4 для 1.36+; Envoy вместо HAProxy для multi-CP; новая kind нужна для `kind load` | kind 0.32 | фраза + в патчах конфига kind писать v1beta4 | kind releases |
| 00-1 | kind 0.31/0.32: образы без cgroup v1, предупреждение при cgroup v1 хоста | kind 0.31+ | фраза: проверка `stat -fc %T /sys/fs/cgroup/` | kind releases; B/2026/kubernetes-cgroups-v2-shift.md |
| 00-2 | KYAML: `kubectl get -o kyaml` | alpha 1.34, beta 1.35, GA 1.37 | раздел в карточке kubectl | B/2026/how-to-pretty-print-kubernetes-yaml-as-kyaml.md |
| 00-2 | kuberc: алиасы и defaults отдельно от kubeconfig; `kubectl kuberc set` (1.36+) | alpha 1.33, beta 1.34 | раздел в карточке kubectl + лаба | B/2025/kubectl-kuberc-beta.md; B/2026/kuberc-plugin-allowlist.md |
| 00-2 | `kubectl debug --custom` профили | GA 1.32 | фраза | R32 |
| 00-2 | Node log query: `kubectl get --raw "/api/v1/nodes/<n>/proxy/logs/?query=kubelet"` | GA 1.36 | фраза + лаба 11-3 | R36 |
| 00-2 | exec/attach/port-forward по WebSocket вместо SPDY | GA 1.35 | фраза (прокси и LB между kubectl и apiserver) | R35 |
| 01-1 | Consistent reads from cache (KEP-2340) | GA 1.34 | фраза: LIST с RV="" идёт из watch cache | R34 |
| 01-1 | WatchList / streaming list (KEP-3157), streaming encoding LIST (KEP-5116) | WatchList beta on 1.34; streaming encoding GA 1.34 | раздел «Как клиент получает начальное состояние» | R34; FG/WatchList.md |
| 01-1 | Snapshottable apiserver cache (KEP-4988) | beta 1.34 | фраза | R34 |
| 01-1 | Resilient watchcache init: 429 вместо нагрузки на etcd | GA 1.37 | фраза | R37 |
| 01-1 | Comparable resource versions (KEP-5504) | 1.35 (стадия не указана) | фраза: RV сравнимы как числа, но клиент всё равно не должен на это полагаться — уточнить | R35 |
| 01-1 | Coordinated leader election, LeaseCandidate | beta, выкл. 1.33+ | фраза: по умолчанию Lease-выборы как раньше | FG/CoordinatedLeaderElection.md |
| 01-1 | Mixed version proxy (KEP-4020) | beta 1.36 | фраза (HA-кластер при обновлении) | R36 |
| 01-1 | /statusz и /flagz у компонентов | alpha 1.32, beta 1.36 | фраза + лаба (смотреть флаги компонента) | R36 |
| 01-1 | APF: flowcontrol v1beta3 удалён | удалено 1.32 | фраза (только v1) | R32 |
| 01-2 | cgroup v1: kubelet не стартует (failCgroupV1=true) | 1.35; удаление обхода — план 1.38 | раздел «Требования к узлу» + анти-рецепт | R35; B/2026/kubernetes-cgroups-v2-shift.md |
| 01-2 | cgroup driver из CRI, `cgroupDriver` в kubelet устарел | GA 1.34 | фраза | R34 |
| 01-2 | containerd 1.x не поддерживается после 1.35; для 1.36 — 2.2+/2.3+ | 1.36 | фраза + таблица совместимости | R35; containerd RELEASES.md |
| 01-2 | containerd config version 3 (2.0+) и 4 (2.3+); `containerd config migrate` | containerd 2.3 | раздел про config.toml + лаба (смотреть версию конфига в узле kind) | containerd RELEASES.md |
| 01-2 | containerd 2.3 — первая годовая LTS (до 2028-04-30) | 2026-04-30 | фраза | containerd RELEASES.md |
| 01-2 | kubelet drop-in каталог конфигурации `--config-dir` | GA 1.35 | фраза + лаба 2 (cgroups и конфигурация kubelet) | R35 |
| 01-2 | Static pod не может ссылаться на Secret/ConfigMap | удалено/запрещено 1.37 | фраза в лабе 3 (static pod) | R37 |
| 01-2 | kubelet при рестарте восстанавливает состояние, поды остаются Ready (KEP-4781) | 1.35 | фраза в лабе 4 | R35 |
| 01-2 | PLEG on-demand relist; condition PodReadyToStartContainers | GA 1.37 | фраза | CL37; R37 |
| 01-2 | Fine-grained kubelet authz (nodes/metrics, nodes/stats, nodes/log…) | GA 1.36 | фраза + 06-1 | B/2026/fine-grained-kubelet-authz.md |
| 01-2 | CRI list streaming (KEP-5825), CRI-stats без cAdvisor | alpha 1.36; beta выкл. 1.37 | фраза | R36; R37 |
| 01-2 | Удалены ~18 флагов cAdvisor kubelet | 1.37 | фраза/12 | CL37 |
| 01-2 | NodeDeclaredFeatures (.status.declaredFeatures) | alpha 1.35, GA 1.37 | фраза | R37 |
| 01-3 | CRD field selectors | GA 1.32 | фраза | R32 |
| 01-3 | kubectl `--subresource` (status, scale, resize) | GA 1.33 | лаба 3 (подресурсы) | R33 |
| 01-3 | Ordered namespace deletion (поды раньше NetworkPolicy) | GA 1.34 | фраза + 09-2 | R34 |
| 01-3 | Retry generateName при коллизии | GA 1.32 | фраза | R32 |
| 01-3 | Declarative validation | GA 1.36 | фраза (не для пользователя) | R36 |
| 01-3 | Удаление нерасшифровываемых ресурсов (AllowUnsafeMalformedObjectDeletion) | beta on 1.37 | фраза + 04-1 | R37; CL37 |
| 01-3 | Endpoints v1 устарел — предупреждение kubectl | 1.33 | фраза про warnings API | B/2025/endpoints-deprecation.md |

### Модуль 02. Рабочие нагрузки

| Часть | Изменение | Версия / стадия | Действие | URL |
|---|---|---|---|---|
| 02-1 | Нативные sidecar (initContainers + restartPolicy: Always) | GA 1.33 | уже в части; добавить: readinessProbe сайдкара не задерживает app, задерживает startupProbe | R33; B/2025/start-sidecar-first/index.md |
| 02-1 | ContainerRestartRules (restartPolicy/restartPolicyRules у контейнера) | alpha 1.34, beta on 1.35 | уже учтено; проверить формулировку | FG/ContainerRestartRules.md |
| 02-1 | RestartAllContainers (действие в restartPolicyRules) | alpha 1.35 | фраза | B/2026/restart-all-containers.md |
| 02-1 | KubeletCrashLoopBackOffMax (`crashLoopBackOff.maxContainerRestartPeriod`) | alpha 1.32, beta on 1.35 | уже учтено | FG/KubeletCrashLoopBackOffMax.md |
| 02-1 | Pod metadata.generation + status.observedGeneration | GA (locked) 1.35 | фраза + лаба (увидеть generation после resize) | R35; FG/PodObservedGenerationTracking.md |
| 02-1 | Image volume (`volumes[].image`) | alpha 1.31, beta 1.33, GA 1.36; нужен containerd 2.1+ | раздел (том из OCI-образа) + лаба | R36 |
| 02-1 | User namespaces (`hostUsers: false`) | GA 1.36 | раздел или 06-2 | B/2026/user-namespaces-goes-ga.md |
| 02-1 | Custom stop signal `lifecycle.stopSignal` | alpha 1.33 (дальше — не подтверждено) | фраза | R33 |
| 02-1 | EnvFiles (переменные из файла другого контейнера) | alpha 1.34 | фраза | R34 |
| 02-1 | Printable ASCII в именах env | GA 1.34 | фраза | R34 |
| 02-1 | FQDN как hostname пода (hostnameOverride) | GA 1.37 | фраза | R37 |
| 02-1 | gitRepo том окончательно выключен | 1.36 | анти-рецепт (замена: init-контейнер, git-sync) | R36 |
| 02-1 | Downward API: метки топологии узла (zone/region) | alpha 1.33, beta 1.35 | фраза в работе 4 (Downward API) | R35 |
| 02-2 | Deployment status.terminatingReplicas | beta 1.35 | фраза + лаба 1 | R35 |
| 02-2 | Случайный выбор пода при scale down ReplicaSet | GA 1.31 | фраза | R31 |
| 02-3 | StatefulSet maxUnavailable | beta 1.35; on снова в 1.37 (баг 1.36 kubernetes#137409) | раздел + лаба 3 (с оговоркой для 1.36) | R35; R37 |
| 02-3 | StatefulSet PVC auto-delete (persistentVolumeClaimRetentionPolicy) | GA 1.32 | раздел + лаба 2 (Scale и PVC) | R32 |
| 02-3 | StatefulSet `.spec.ordinals.start` | GA 1.31 | фраза | R31 |
| 02-3 | Метка apps.kubernetes.io/pod-index | GA 1.32 | фраза + лаба 1 | R32 |
| 02-3 | StatefulSet Recreate strategy | alpha 1.37 | фраза | R37 |
| 02-4 | Job podFailurePolicy | GA 1.31 | уже в лабе 1; сверить | R31 |
| 02-4 | Job backoffLimitPerIndex, successPolicy | GA 1.33 | раздел + лаба 1 (indexed) | R33; B/2025/jobs-successpolicy-goes-ga.md |
| 02-4 | Job podReplacementPolicy (Failed / TerminatingOrFailed) | GA 1.34 | фраза + лаба | R34; B/2025/jobs-podreplacementpolicy-goes-ga.md |
| 02-4 | Job managedBy (Kueue/MultiKueue) | GA 1.35 | фраза | R35; B/2025/jobs-managedby-goes-ga.md |
| 02-4 | Elastic Indexed Jobs | GA 1.31 | фраза | R31 |
| 02-4 | Mutable resources у suspended Job | alpha 1.35, beta 1.36 | фраза | R36 |
| 02-4 | Gang scheduling (Workload/PodGroup), Job spec.scheduling | alpha 1.35; beta 1.37 | фраза (+ 05-2) | R35; R37 |
| 02-5 | lifecycle sleep action (preStop: sleep) | GA 1.34; sleep 0 — GA 1.34 | раздел + лаба 1 (preStop без sleep-бинарника в образе) | R34 |
| 02-5 | Restricted→Baseline: поле host в пробах и хуках запрещено | PSS v1.34 | фраза + 06-2 | pod-security-standards.md |
| 02-5 | Завершение: Endpoints terminating в EndpointSlice | — | связь с 03-2 (без изменений) | — |

### Модуль 03. Сеть

| Часть | Изменение | Версия / стадия | Действие | URL |
|---|---|---|---|---|
| 03-1 | Cilium netkit вместо veth | Cilium 1.20 | фраза | isovalent.com/blog/post/cilium-1-20/ |
| 03-1 | Pod status.hostIPs | GA 1.32 | фраза | R32 |
| 03-2 | kube-proxy nftables | beta 1.31, GA 1.33; iptables по умолчанию; ядро 5.13+ | уже в лабе 4; раздел «Режимы kube-proxy» | R33; B/2026/ipvs-deprecation/index.md |
| 03-2 | ipvs устарел | 1.35; план: выкл. по умолчанию 1.40, удаление 1.40–1.43 (источники расходятся) | анти-рецепт + 12 | R35; R37; B/2026/ipvs-deprecation/index.md |
| 03-2 | kube-proxy без явного mode предупреждает; kubeadm пишет mode: iptables; готовится nftables по умолчанию | 1.37 | фраза | CL37 |
| 03-2 | nftables-режим через netlink без `nft`; localhost:NodePort не работает в nftables (alpha-прокси KEP-6032) | 1.37 | фраза (ловушка: NodePort на 127.0.0.1) | R37 |
| 03-2 | trafficDistribution: PreferClose → PreferSameZone; PreferSameNode | PreferClose GA 1.33; PreferSameZone/Node beta 1.34, GA 1.35 | раздел + лаба | R33; R34; R35 |
| 03-2 | Multiple ServiceCIDR (ServiceCIDR, IPAddress v1) | GA 1.33 | раздел + лаба (расширить диапазон ClusterIP) | R33 |
| 03-2 | Endpoints v1 устарел → EndpointSlice | 1.33 | фраза + анти-рецепт `kubectl get endpoints` | B/2025/endpoints-deprecation.md |
| 03-2 | externalIPs устарел (CVE-2020-8554), DenyServiceExternalIPs | 1.36 warn; ≥1.40 выкл.; ≥1.43 удаление | анти-рецепт | B/2026/deprecation-of-service-externalips.md |
| 03-2 | LoadBalancer ipMode (VIP/Proxy) | GA 1.32 | фраза | R32 |
| 03-2 | Connection draining для терминирующихся узлов за LB | GA 1.31 | фраза | R31 |
| 03-2 | Relaxed Service name validation | GA 1.37 | фраза | R37 |
| 03-2 | StrictIPCIDRValidation | beta 1.36 | фраза | R36 |
| 03-3 | Relaxed DNS search validation (точка первой в searches) | GA 1.34 | фраза (ndots-лаба) | R34 |
| 03-3 | CoreDNS: kubeadm 1.36 — v1.14.2; 1.37 — v1.14.6 | 1.36/1.37 | фраза (версии) | kubeadm constants.go |
| 03-3 | kube-dns устарел (пакеты не собираются после 1.40) | 1.37 | фраза/12 | R37 |
| 03-4 | Ingress NGINX выведен из эксплуатации 2026-03-24 | retired | раздел + анти-рецепт; лаба 3 (Ingress без контроллера) оставить как историческую | B/2026/ingress-nginx-statement.md; R36 |
| 03-4 | ingress2gateway 1.0 | 2026-03-20 | раздел «Миграция с Ingress» + лаба | B/2026/ingress2gateway-v1-0-release.md |
| 03-4 | Gateway API 1.4: BackendTLSPolicy GA; supportedFeatures; именованные правила | 2025-10-06 | раздел (TLS до бэкенда) | B/2025/gateway-api-v1-4/index.md |
| 03-4 | Gateway API 1.5: ListenerSet, TLSRoute v1, CORS, frontend mTLS, ReferenceGrant v1 — Standard | 2026-02-27 | раздел + лаба 2 (ReferenceGrant v1) | B/2026/gateway-api-v1-5/index.md |
| 03-4 | Gateway API 1.6: TCPRoute/UDPRoute v1 | 2026-06-30 | фраза | B/2026/gateway-api-v1-6-release/index.md |
| 03-4 | Envoy Gateway 1.9.x требует CRD Gateway API v1.6; 1.9.1 — пропустить 1.9.0 | 2026 | фраза в установке стенда | gateway.envoyproxy.io/news/releases/v1.9/ |
| 03-4 | Pod certificates (PodCertificateRequest) и ClusterTrustBundle (projected volumes) | beta 1.35; GA 1.37 (оба) | фраза (mTLS без cert-manager) / 06-1 | R37; B/2026/pod-certificates-and-cluster-trust-bundles |
| 03-4 | cert-manager 1.21: изменение RBAC чарта и cert-manager-edit | 2026 | фраза в лабе 4 | acme.cert-manager.io (upgrading-1.20-1.21) |
| 03-5 | AdminNetworkPolicy/BANP → ClusterNetworkPolicy v1alpha2 (tier Admin/Baseline, Accept) | network-policy-api v0.2.0, 2026-06-02 | раздел (заменить ANP) | network-policy-api.sigs.k8s.io blog 2025-10-09 |
| 03-5 | Ordered namespace deletion: NetworkPolicy удаляются после подов | GA 1.34 | фраза | R34 |

### Модуль 04. Конфигурация и данные

| Часть | Изменение | Версия / стадия | Действие | URL |
|---|---|---|---|---|
| 04-1 | KMS v2 GA, KMS v1 выключен по умолчанию | 1.29 | фраза + анти-рецепт KMS v1 | FG/KMSv1.md |
| 04-1 | Удаление нерасшифровываемых объектов через API (KEP-3926) | beta 1.37 | фраза в лабе 3 (откат шифрования) | R37 |
| 04-1 | Size memory-backed emptyDir по лимитам | GA 1.32 | фраза | R32 |
| 04-1 | Projected SA token для image pull; проверка credentials для кэшированных образов (KubeletEnsureSecretPulledImages) | beta 1.34; beta on 1.35 | фраза (imagePullSecrets и IfNotPresent) | R34; R35 |
| 04-2 | VolumeAttributesClass (storage.k8s.io/v1) | GA 1.34 | раздел (изменить IOPS онлайн) | R34; B/2025/volume-attributes-class-ga |
| 04-2 | Recovery from expansion failure | GA 1.34 | раздел + лаба 3 (расширение тома) | R34; B/2025/recover-failed-expansion.md |
| 04-2 | Always honor PV reclaim policy (finalizers) | GA 1.33 | фраза в лабе 3 (Delete и Retain) | R33 |
| 04-2 | Volume populators (dataSourceRef) | GA 1.33 | фраза | R33 |
| 04-2 | SELinuxMount (mount -o context) | beta выкл. 1.33–1.36, GA on 1.37 — ломает общий том у привилегированного и обычного пода на одном узле; обход `seLinuxChangePolicy: Recursive`; метрика selinux_warning_controller_selinux_volume_conflict | фраза (Ubuntu/Manjaro без SELinux не затронуты) + 12 | FG/SELinuxMount.md; B/2026/breaking-changes-in-selinux-volume-labeling.md |
| 04-2 | Recursive read-only mounts (recursiveReadOnly) | GA 1.33 | фраза | R33 |
| 04-2 | Mutable CSINode allocatable | GA 1.36 | фраза | R36 |
| 04-2 | Storage capacity scoring; PVC last-used (условие Unused) | alpha 1.36 / beta on 1.37 | фраза | R37 |
| 04-2 | In-tree cephfs, rbd удалены; in-tree cloud providers удалены; Portworx → CSI | 1.31; 1.36 | анти-рецепт | R31; R36 |
| 04-2 | flex-volume убран из kubeadm | 1.36 | фраза | CL36 |
| 04-2 | PV status.lastTransitionTime | GA 1.31 | фраза | R31 |
| 04-3 | VolumeGroupSnapshot (группа PVC, crash-consistent) | beta 1.32, GA 1.36 | раздел + лаба (если CSI с поддержкой) | R36; B/2026/volume-group-snapshot-ga.md |
| 04-3 | CSI changed block tracking (SnapshotMetadataService, cbt.storage.k8s.io/v1beta1; только block-тома) | beta (external-snapshot-metadata v1.0.0, март 2026; k8s 1.33+); v1alpha1 удалён без конверсии | фраза (инкрементальные бэкапы) | B/2026/csi-changed-block-tracking-beta.md |

### Модуль 05. Ресурсы и планирование

| Часть | Изменение | Версия / стадия | Действие | URL |
|---|---|---|---|---|
| 05-1 | In-place resize (подресурс resize) | beta 1.33, GA 1.35; 1.36 — отказ на admission сверх allocatable | раздел + лаба 4 | B/2025/ippr-goes-ga.md; CL36 |
| 05-1 | Pod-level resources (spec.resources) | alpha 1.32, beta on 1.34; resize pod-level — beta 1.36 | раздел (вероятно, повод делить 05-1) + лаба | FG/PodLevelResources.md; CL36 |
| 05-1 | Новая формула cpu.shares → cpu.weight (runc 1.3.2+, crun 1.23+) | 2026 | лаба 1: сверить значения cpu.weight; фраза | B/2026/new-cgroup-v1-to-v2-conversion-formula/index.md |
| 05-1 | Memory QoS (memory.high/min/low) | alpha до 1.36, beta on 1.37 | раздел (кратко) | FG/MemoryQoS.md |
| 05-1 | Swap: NoSwap по умолчанию, LimitedSwap | GA 1.34 | раздел | FG/NodeSwap.md; R34 |
| 05-1 | PSI-метрики cgroup v2 | GA 1.36 | раздел «Как увидеть давление» + 11-3 | R36 |
| 05-1 | CPU Manager: full-pcpus-only GA 1.33; reservedSystemCPUs strict GA 1.35; split L3 GA 1.36; max-allowable-numa-nodes GA 1.35 | разные | фраза/таблица | R33; R35; R36 |
| 05-1 | Memory Manager GA | 1.32 | фраза | R32 |
| 05-2 | QueueingHints | GA 1.34 | раздел «Очереди планировщика» | R34; FG/SchedulerQueueingHints.md |
| 05-2 | Scheduling readiness (schedulingGates) | GA 1.30 | фраза | FG/PodSchedulingReadiness.md |
| 05-2 | matchLabelKeys/mismatchLabelKeys в affinity; nodeAffinityPolicy/nodeTaintsPolicy в topologySpread | GA 1.33 | раздел + лаба 1 | R33 |
| 05-2 | Async preemption, nominatedNodeName | beta 1.33 / alpha 1.34 | фраза | R33; R34 |
| 05-2 | DRA (resource.k8s.io/v1, DeviceClass, ResourceClaim, ResourceSlice) | GA 1.34, locked 1.35; extended resource, device taints GA 1.37 | новая часть или раздел | R34; R36; R37 |
| 05-2 | Gang scheduling / Workload API | alpha 1.35, beta 1.37 | раздел (кратко) | R37 |
| 05-2 | Extended toleration operators (Gt/Lt) | alpha 1.35 | фраза | R35 |
| 05-3 | HPA configurable tolerance (behavior.scaleUp/scaleDown.tolerance) | alpha 1.33, beta 1.35, GA 1.37 | раздел + лаба 2 (behavior) | B/2025/hpa-configurable-tolerance.md; R37 |
| 05-3 | HPA scale-to-zero (Object/External) | alpha 1.36, beta on 1.37 | фраза + сравнение с KEDA в лабе 3 | R36; R37 |
| 05-3 | VPA InPlaceOrRecreate | GA в VPA 1.6.0 (фев 2026); режим Auto устарел с VPA 1.5 | раздел VPA | github.com/kubernetes/autoscaler/releases/tag/vertical-pod-autoscaler-1.6.0 |
| 05-3 | metrics.k8s.io v1 | GA 1.37 | фраза (metrics-server) | R37 |
| 05-3 | KEDA 2.20 (events.k8s.io RBAC), 2.21 (CVE-2026-77524) | 2026 | фраза в лабе 3 | newreleases.io KEDA 2.21.0 |
| 05-3 | Karpenter 1.x: NodeOverlay | 2026 | фраза | endoflife.date/karpenter |
| 05-4 | PDB unhealthyPodEvictionPolicy | GA 1.31 | раздел + лаба 2 (PDB и нездоровые поды) | R31 |
| 05-4 | Node lifecycle conditions (drain/maintenance) | alpha 1.37 | фраза | R37 |
| 05-4 | Taint manager отделён от node lifecycle controller | GA 1.34 | фраза | R34 |

### Модуль 06. Доступ и безопасность

| Часть | Изменение | Версия / стадия | Действие | URL |
|---|---|---|---|---|
| 06-1 | Structured authentication configuration (несколько JWT/OIDC, CEL, hot reload) | GA 1.34 | раздел + лаба (OIDC-аутентификатор из файла) | R34 |
| 06-1 | Structured authorization configuration (цепочка авторизаторов) | GA 1.32 | раздел | R32 |
| 06-1 | Anonymous auth только для заданных путей (/livez, /readyz, /healthz) | GA 1.34 | фраза + лаба 4 (аудит) | R34 |
| 06-1 | Authorization по field/label selectors | GA 1.34 | фраза | R34 |
| 06-1 | Bound SA tokens: jti, node binding; node name в claims | GA 1.32/1.33 | раздел + лаба 3 | R32; R33 |
| 06-1 | External SA token signer | GA 1.36 | фраза | R36 |
| 06-1 | Constrained impersonation | alpha 1.35, beta 1.36 | фраза (impersonate-on) | R36 |
| 06-1 | Fine-grained kubelet authz — не давать nodes/proxy мониторингу | GA 1.36 | раздел + лаба 4 «кто может nodes/proxy» | B/2026/fine-grained-kubelet-authz.md |
| 06-1 | Pod certificates + ClusterTrustBundle | GA 1.37 | фраза | R37 |
| 06-1 | Ограничить nodes/logs: стартовые логи kubelet содержат конфиг | 1.37 | фраза | CL37 |
| 06-2 | ValidatingAdmissionPolicy | GA 1.30 | уже в лабе 3 | B/2024/validating-admission-policy-ga |
| 06-2 | MutatingAdmissionPolicy (CEL, без вебхука) | alpha 1.32, beta 1.34, GA 1.36 | раздел + лаба | R36 |
| 06-2 | Manifest-based admission control (политики из файлов, до старта apiserver) | alpha 1.36, beta on 1.37 | фраза | R36; R37 |
| 06-2 | AppArmor через securityContext.appArmorProfile (аннотации — анти-рецепт) | GA 1.31 | фраза + анти-рецепт | R31 |
| 06-2 | User namespaces hostUsers: false | GA 1.36 | раздел | B/2026/user-namespaces-goes-ga.md |
| 06-2 | procMount | GA 1.36 | фраза | R36 |
| 06-2 | supplementalGroupsPolicy (Strict) | GA 1.35 | фраза | R35 |
| 06-2 | PSS Baseline: host в пробах/хуках (1.34+), новые sysctl (1.32+, 1.37+) | — | фраза | pod-security-standards.md |
| 06-2 | In-tree cloud providers удалены | 1.31 | фраза/12 | R31 |
| 06-2 | SHA-1 сертификаты отвергаются | 1.31 | фраза | R31 |

### Модуль 07–08. Пакетирование и GitOps

| Часть | Изменение | Версия / стадия | Действие | URL |
|---|---|---|---|---|
| 07-1 | Helm 4: SSA для новых релизов, kstatus `--wait` (нужен watch), плагины, `--rollback-on-failure`, `--force-replace` | Helm 4.0 2025-11-12 | раздел «Helm 4 и Helm 3» + лаба 3 (SSA-конфликт) | blog.helm.sh/blog/helm-v3-end-of-life; helm.sh/docs/changelog |
| 07-1 | Helm 3: багфиксы до 2026-09-09, безопасность до 2027-02-10 | — | фраза | blog.helm.sh/blog/helm-v3-end-of-life |
| 07-1 | `--atomic` — анти-рецепт названия (устарел в Helm 4) | Helm 4 | анти-рецепт | там же |
| 07-2 | Bitnami: образы в bitnamilegacy, бесплатно только :latest (bitnamisecure) | авг–сен 2025 | анти-рецепт + лаба 1 (ImagePullBackOff «как есть») | docker.com/blog/broadcoms-new-bitnami-restrictions-migrate-easily-with-docker/ |
| 07-3 | kubectl 1.36 встраивает kustomize v5.8.1; 5.8.0 — регрессия namespace | 1.36 | фраза | k8s release-1.36 kubectl go.mod |
| 07-3 | Argo CD 3.5.4+: Kustomize-сборки с Helm не учитывают helmGlobals.configHome | 2026-10 | фраза в лабе 2 | github.com/argoproj/argo-cd/releases |
| 08-1 | Argo CD 3.0: трекинг по аннотации; RBAC логов; fine-grained RBAC; репо только в Secret; resource.exclusions | 3.0 (2025) | раздел + анти-рецепт label-tracking | argo-cd upgrading/2.14-3.0.md |
| 08-1 | Argo CD 3.3: установка/обновление только `kubectl apply --server-side --force-conflicts` | 3.3 | в лабу 1 | argo-cd upgrading/3.2-3.3.md |
| 08-1 | Argo CD 3.5: Helm 4 внутри; plain HTTP OCI — insecureOCIForceHttp; impersonation на все операции | 3.5 | фраза | argo-cd upgrading/3.4-3.5.md |
| 08-1 | Argo CD CVE (окт 2026): обход AppProject через PreDelete/PostDelete хуки; Kustomize remote ref | 3.3.15/3.4.10/3.5.4 | фраза: версия ≥ исправленной | github.com/argoproj/argo-cd/releases |
| 08-2 | Source Hydrator (git note), ApplicationSet CRD + SSA | 3.3 | фраза | argo-cd upgrading/3.2-3.3.md |
| 08-2 | Flux 2.7–2.9 (Helm 4, ArtifactGenerator) | 2025–2026 | фраза-сравнение | fluxcd.io/blog/2026/02/flux-v2.8.0/ |
| 08-2 | ESO: API external-secrets.io/v1 (v1beta1 не обслуживается с 0.17); текущая линия 2.x | 2025–2026 | фраза (если ESO в части) | github.com/external-secrets/external-secrets/releases |

### Модуль 09–11

| Часть | Изменение | Версия / стадия | Действие | URL |
|---|---|---|---|---|
| 09-1 | CRD validation ratcheting | GA 1.33 | фраза | R33 |
| 09-1 | CRD field selectors (selectableFields) | GA 1.32 | фраза + лаба 1 | R32 |
| 09-1 | Storage Version Migration in-tree (StorageVersionMigration) | beta 1.35, GA 1.37 | раздел «Смена версии CRD» | R35; R37 |
| 09-1 | Staleness mitigation контроллеров | beta 1.36/1.37 | фраза | R36; R37 |
| 09-2 | MutatingAdmissionPolicy как замена вебхукам | GA 1.36 | раздел-сравнение | R36 |
| 09-2 | Ordered namespace deletion | GA 1.34 | фраза в лабе 2 (Terminating) | R34 |
| 09-2 | Webhook round-trip load balancing, исключение виртуальных ресурсов | beta on 1.37 | фраза | CL37 |
| 10-1 | etcd 3.6: v2store удалён, snapshot-count 10000, downgrade, /livez /readyz; обновляться с 3.5.20+ | 3.6.0 2025-05-15; kubeadm 1.36 → 3.6.8 | раздел + лаба 1 | B/2025/announcing-etcd-3-6/index.md; constants.go |
| 10-1 | etcd 3.7: RangeStream, удалены `--experimental-*`; kubeadm 1.37 → 3.7.0 | 2026-07-08 | фраза | B/2026/etcd-3-7.md |
| 10-1 | EtcdRangeStream в apiserver | beta on 1.37 | фраза | R37 |
| 10-2 | kubeadm v1beta4 (timeouts, extraArgs списком); v1beta3 устарел | 1.31 | раздел + лаба 1 (`kubeadm config migrate`) | B/2024/kubernetes-1-31-kubeadm-v1beta4 |
| 10-2 | Перекос версий: kubelet до −3 минорных | с 1.28 | фраза | constants.go |
| 10-2 | Удалённые/устаревшие API за 1.31–1.37: flowcontrol v1beta3 (1.32), классический DRA (1.32), Endpoints (устар. 1.33), kubeProxyVersion (1.33), gitRepo (1.36), externalIPs (устар. 1.36), cAdvisor-флаги (1.37) | — | таблица «что проверить перед обновлением» | R32; R33; R36; CL37 |
| 10-2 | Обновление: containerd 2.x до k8s 1.36; cgroup v2 до 1.35; ipvs → nftables до 1.40 | — | раздел «Предусловия обновления» | R35 |
| 10-3 | Kubelet image GC по возрасту (imageMaximumGCAge), maxParallelImagePulls | GA 1.35 | фраза | R35 |
| 10-3 | Graceful node shutdown; node readiness controller (SIG Node) | — | фраза (не сверено) | B/2026/introducing-node-readiness-controller |
| 11-1 | PodReadyToStartContainers condition | GA 1.37 | фраза (условия пода в describe) | R37 |
| 11-1 | Сообщения ImagePullBackOff с деталями | 1.32 | фраза | R32 |
| 11-1 | allocatedResourcesStatus (здоровье устройств) | GA 1.37 | фраза | R37 |
| 11-3 | Node log query (kubelet/kube-proxy логи без SSH) | GA 1.36 | лаба | R36 |
| 11-3 | PSI-метрики (давление CPU/память/IO) | GA 1.36 | лаба | R36 |
| 11-3 | /statusz, /flagz | beta 1.36 | лаба | R36 |
| 11-3 | kubelet eventRecordQPS: 0 = без лимита | 1.37 | фраза | CL37 |
| 12-x | Все пункты «анти-рецепт» и «12» | — | вопросы-ловушки: ipvs, Endpoints, externalIPs, ingress-nginx, cgroup v1, containerd 1.7, gitRepo, AppArmor-аннотации, KMS v1, Bitnami, `--atomic` | — |

## 3. Экосистема

### Helm
- Helm 4 GA 2025-11-12 (KubeCon NA). Новые релизы ставятся server-side apply; релизы Helm 3 остаются на client-side apply (upgrade/rollback сохраняют метод релиза; флаг `--server-side` переопределяет — точное имя флага не сверено). `--wait` на kstatus — нужен verb `watch` (кроме list), иначе ожидание падает сразу. Post-renderer — только как плагин (не путь к файлу). Новая система плагинов, опционально WebAssembly. `--atomic` → `--rollback-on-failure`, `--force` → `--force-replace` (старые работают с предупреждением). Чарты v2 работают без изменений. `helm registry login` — только домен (вторичный источник).
- Helm 3: багфиксы до финального релиза 2026-09-09 (только обновления client-go); патчи безопасности до 2027-02-10 (продлено с ноября 2026).
  URL: https://blog.helm.sh/blog/helm-v3-end-of-life ; https://helm.sh/docs/changelog (через поиск; helm.sh из среды недоступен)

### Argo CD
- Актуальные линии (12 окт 2026): 3.5.5 (latest), 3.4.11, 3.3.16. 06 окт 2026 — критические CVE: обход ограничений AppProject через PreDelete/PostDelete хуки; Kustomize remote ref выполняет команды в repo-server; OCI-манифест > 4 MiB отвергается.
  URL: https://github.com/argoproj/argo-cd/releases
- 3.0 (2025): трекинг ресурсов по аннотации (не метка) по умолчанию; RBAC на логи обязателен (`logs, get`); fine-grained RBAC: update/delete Application не распространяются на подресурсы; репозитории в argocd-cm не поддерживаются (только Secret); default resource.exclusions (Endpoints, EndpointSlice, Lease…); здоровье ресурсов не хранится в status по умолчанию; Dex sub → federated_claims.user_id.
  URL: https://raw.githubusercontent.com/argoproj/argo-cd/master/docs/operator-manual/upgrading/2.14-3.0.md
- 3.3: CRD ApplicationSet слишком велик для client-side apply — ставить `kubectl apply --server-side --force-conflicts` или syncOption ServerSideApply=true; Source Hydrator хранит состояние в git note; Helm 2 не поддерживается (встроен Helm 3.19.2); Kustomize 5.8.0.
  URL: https://raw.githubusercontent.com/argoproj/argo-cd/master/docs/operator-manual/upgrading/3.2-3.3.md
- 3.5: встроен Helm 4 — plain HTTP OCI требует insecureOCIForceHttp; `spec.source.helm.version: v3` игнорируется; impersonation на все операции; GnuPG → Source Integrity; opt-in mTLS repo-server.
  URL: https://raw.githubusercontent.com/argoproj/argo-cd/master/docs/operator-manual/upgrading/3.4-3.5.md

### Flux
- 2.7 (сен 2025): image automation API GA; ExternalArtifact, ArtifactGenerator; watch ConfigMap/Secret; CEL-проверки готовности; OTel. 2.8 (фев 2026): поддержка Helm 4 (SSA, health checking HelmRelease), .status.inventory у HelmRelease, CEL для helm-объектов. 2.9 (2026-06-30): плагины CLI — не открыто, не подтверждено.
  URL: https://fluxcd.io/blog/2026/02/flux-v2.8.0/

### Bitnami (Broadcom), 2025
- С 28 авг – 29 сен 2025: версионированные образы перенесены в `docker.io/bitnamilegacy` (без обновлений и патчей); бесплатно — только `:latest` в `bitnamisecure` «для разработки»; остальное — платная Bitnami Secure Images. Чарты по умолчанию ссылаются на старые репозитории → ImagePullBackOff. Анти-рецепт для 07-2: «поставить bitnami/postgresql как есть».
  URL: https://www.docker.com/blog/broadcoms-new-bitnami-restrictions-migrate-easily-with-docker/ ; https://northflank.com/blog/bitnami-deprecates-free-images-migration-steps-and-alternatives

### cert-manager
- 1.21.0 — последний минор (2026; дата не сверена): ACME ARI, Vault IAM auth, улучшения Gateway API; breaking: чарт не создаёт Role для токенов своего SA; aggregate ClusterRole cert-manager-edit больше не даёт create Challenges/Orders (также в 1.20.3, 1.19.6, GHSA-8rvj-mm4h-c258 HIGH); удалены значения ServiceMonitor port/path. Поддержка ListenerSet — не подтверждено.
  URL: https://acme.cert-manager.io/docs/releases/upgrading/upgrading-1.20-1.21/ (через поиск)

### Envoy Gateway
- 1.9.0 (2026): breaking — clientIPDetection в ClientTrafficPolicy требует ровно одну опцию; TCPRoute/UDPRoute через gateway.networking.k8s.io/v1 → нужны CRD Gateway API v1.6 (по данным Giant Swarm). 1.9.1 (28 авг 2026) — откат изменения SDS/RDS fetch timeout; рекомендуется 1.8.x → 1.9.1, минуя 1.9.0. EOL: 1.7 — 2026-08-05, 1.8 — 2026-11-08. В плане стенда указан 1.9.2 — наличие 1.9.2 не подтверждено (видел 1.9.0, 1.9.1); есть пакет 1.10 у Giant Swarm — релиз EG 1.10 не подтверждён.
  URL: https://gateway.envoyproxy.io/news/releases/v1.9/ ; https://infoq.com/news/2026/10/envoy-gateway-1-9-1 ; https://docs.giantswarm.io/changes/connectivity/gateway-api-app/v1.9.0/

### External Secrets Operator
- Линия v2.x: v2.13.0 (16 окт 2026), v2.12.0 (06 окт), v2.11.0 (18 сен), v2.9.0 (07 авг). API v1beta1 перестал обслуживаться в v0.17.0 (последняя с v1beta1 — 0.16.2) — переименовать apiVersion на external-secrets.io/v1. Когда вышел 1.0 и 2.0 — не подтверждено.
  URL: https://github.com/external-secrets/external-secrets/releases

### KEDA
- Текущая 2.21.0 (2026): CVE-2026-77524 (аудитория bound SA token в TriggerAuthentication/Vault) — breaking; удалены старые параметры Temporal. 2.20: события через events.k8s.io — нужен RBAC на эту группу. 2.18 EOL 2026-06-01 (endoflife-трекер). В плане KEDA версия не указана.
  URL: https://newreleases.io/project/github/kedacore/keda/release/v2.21.0
- Конкурент: HPA scale-to-zero для Object/External метрик (KEP-2021) — alpha 1.36, beta on 1.37.

### Karpenter
- 1.9.0 (2026-02-06), 1.10.0 (2026-03-20), 1.11.1 (2026-04-09), документация уже до v1.14 (2026); NodeOverlay (feature gate, opt-in: цена/доп. ресурсы/priceAdjustment, weight 1–10000). Подробности NodePool по версиям — не подтверждено.
  URL: https://endoflife.date/karpenter ; https://karpenter.sh/docs/upgrade-guide

### Cilium / Calico
- Cilium 1.19 (начало 2026), 1.20 (сен 2026): Gateway API v1.4 → v1.6 (ExternalAuth, CORS, ListenerSet, TCPRoute/UDPRoute), netkit вместо veth (режим auto), ENI IPAM IPv6, stable MCS API, поддержка ClusterNetworkPolicy.
  URL: https://isovalent.com/blog/post/cilium-1-20/ ; https://cncf.io/blog/2026/09/14/cilium-1-20-gateway-api-externalauth-tcproute-udproute-eni-ipam-for-ipv6-and-more
- Calico 3.31/3.32 — не подтверждено (данных не нашёл).

## 4. Кандидаты в новые части или разделы

Новые части (по §2 AGENTS.md — если механизм не помещается в существующую часть):

1. **05-5 (или 05-2 раздел) «Устройства и DRA»** — DeviceClass, ResourceClaim/ResourceClaimTemplate, ResourceSlice, структурированные параметры, extended resource через DRA, device taints, prioritized list, admin access; GA 1.34, ключевые подфичи GA 1.36–1.37. Важно для собеседований (AI/GPU-платформы). Лаба возможна с dra-example-driver в kind — способ проверки не согласован, только текст.
2. **05-1 делится на «CPU и память контейнера» и «Pod-level resources, in-place resize и swap»** — в 05-1 добавляются pod-level resources (beta), resize GA + pod-level resize (beta 1.36), swap GA, Memory QoS, PSI, новая формула cpu.weight; уже был намёк в плане на деление.
3. **06-3 «Идентичность рабочих нагрузок и токены»** (кандидат) — bound SA tokens (jti, node binding), external JWT signer, projected SA tokens для image pull, Pod certificates + ClusterTrustBundle (GA 1.37), structured authn (OIDC без перезапуска). Альтернатива — разделы в 06-1, если объём позволит.
4. **03-4 делится на «Gateway API» и «TLS, сертификаты и миграция с Ingress»** — Gateway API 1.4–1.6 (BackendTLSPolicy, ListenerSet, TLSRoute, frontend mTLS, CORS, TCP/UDPRoute), retirement ingress-nginx, ingress2gateway, cert-manager — явно больше 1–2 часов.
5. **09-x раздел «CEL-политики: Validating и Mutating Admission Policy, manifest-based admission»** — в 06-2/09-2; MAP GA 1.36 меняет рекомендацию «пиши вебхук».

Новые разделы в существующих частях (крупные):

- 01-1: «Как клиент получает состояние: watch cache, consistent reads, WatchList/streaming list».
- 01-2: «Требования к узлу: cgroup v2, containerd 2.x, config v3/v4, drop-in конфиг kubelet».
- 02-1: «Том из OCI-образа» (image volume GA 1.36); «User namespaces» (или в 06-2).
- 02-4: «Политики успеха и отказа Job» (successPolicy, backoffLimitPerIndex, podReplacementPolicy, managedBy).
- 03-2: «Режимы kube-proxy: iptables, nftables, ipvs (устарел)»; «Распределение трафика: trafficDistribution»; «Диапазоны ClusterIP: ServiceCIDR».
- 03-5: «Политики уровня кластера: ClusterNetworkPolicy».
- 04-2: «VolumeAttributesClass и изменение параметров тома»; «Ошибка расширения и откат».
- 05-3: «VPA и in-place resize»; «HPA tolerance».
- 06-1: «Права на kubelet API: подресурсы вместо nodes/proxy».
- 10-1: «etcd 3.6/3.7: что изменилось».
- 10-2: «Предусловия обновления до 1.36/1.37» (таблица удалённого/устаревшего).

## 5. Что в плане устарело

- **§2/§3 версии стенда:** Envoy Gateway 1.9.2 существует (28 сен 2026, latest; github.com/envoyproxy/gateway/releases) — ок; 1.9 требует CRD Gateway API v1.6. Helm: план «4.2», актуальные — 4.3.1 (15 окт 2026), 4.2.4 (13 авг 2026); Helm 3 — 3.22.1 (15 окт 2026), github.com/helm/helm/releases. Оставить 4.2.x или поднять до 4.3 — решение ведущего. containerd 2.3 — актуальная LTS (ок). Kubernetes 1.36 — уже не последний (1.37 вышел 2026-08-26, kind 0.33); курс можно оставить на 1.36, но отметить 1.37.
- **01-2 работа 4 «Узел без kubelet: NotReady и вытеснение»** — с 1.35 kubelet при рестарте сохраняет Ready подов (KEP-4781); формулировки про перезапуск kubelet пересмотреть.
- **01-2 работа 3 «Static pod»** — с 1.37 static pod не может ссылаться на Secret/ConfigMap; на 1.36 работает, но добавить фразу.
- **02-1 работа 3 «Старый и нативный sidecar»** — «старый» sidecar подавать как анти-рецепт (нативные GA с 1.33).
- **02-3 работа 3 «Partition и сломанная ревизия»** — добавить maxUnavailable (beta; в 1.36 выключен из-за бага — уточнить поведение 1.36.1).
- **03-2 работа 4 «kube-proxy в режиме nftables»** — уже актуальна; добавить ipvs как устаревший, NodePort на localhost не работает в nftables.
- **03-4 работа 3 «Ingress без контроллера»** — Ingress API жив, но ingress-nginx выведен (2026-03-24); ingress-nginx в примерах — только как анти-рецепт; добавить ingress2gateway.
- **03-5 и §7 «AdminNetworkPolicy»** — ANP/BANP заменены ClusterNetworkPolicy (v1alpha2); термин в непроверенном заменить.
- **04-1 работа 3 «Шифрование Secret»** — использовать только KMS v2/aescbc/secretbox; KMS v1 выключен по умолчанию с 1.29.
- **05-1 работа 1 «QoS-классы и их cgroup»** — значения cpu.weight зависят от версии runc (новая формула с 1.3.2); сверить с выводом прогона, объяснить.
- **05-1 работа 4 «In-place resize»** — GA; использовать подресурс `--subresource resize`, а не прямой patch spec.
- **05-3 работа 3 «KEDA: cron и ноль подов»** — оставить, но упомянуть HPA scale-to-zero (beta 1.37); указать версию KEDA ≥ 2.21 (CVE).
- **06-2 работа 3 «ValidatingAdmissionPolicy “без latest”»** — добавить MutatingAdmissionPolicy (GA 1.36).
- **07-1** — команды с `--atomic`/`--force` заменить на `--rollback-on-failure`/`--force-replace`; учесть SSA по умолчанию (лаба 3 «Конфликт SSA» — в Helm 4 сценарий меняется) и kstatus-ожидание.
- **07-2 работа 1 «Установка как есть и проблема пароля»** — если чарт Bitnami: теперь главная проблема — образы (bitnamilegacy/ImagePullBackOff), не только пароль.
- **08-1 работа 1 «Gitea и Argo CD»** — Argo CD 3.3+ ставить `kubectl apply --server-side --force-conflicts`; версия ≥ 3.5.4/3.4.10/3.3.15 (CVE окт 2026). Трекинг по аннотации по умолчанию — учесть в лабе 3 «Prune и вечный OutOfSync».
- **10-1** — etcd 3.6 (v2store удалён, snapshot-count 10000); `etcdctl snapshot restore` устарел в пользу `etcdutl snapshot restore` (с 3.5, удалён из etcdctl в 3.6 — по памяти, не подтверждено).
- **10-2** — kubeadm v1beta4 (kind 0.32 уже использует); требования cgroup v2 и containerd 2.x до обновления.
- **§7 непроверенное: «pluto и kubent»** — актуальность kubent (поддержка новых API) не проверена; не подтверждено.
- **§1 «Карточки инструментов»** — добавить карточку `ingress2gateway`; в карточку kubectl — kuberc и KYAML.

## 6. Не подтверждено

- Удаление ipvs: пост ipvs-deprecation — «удаление в 1.40», блог релиза 1.37 — «выкл. по умолчанию в 1.40, удаление в 1.43». Давать как план с оговоркой.
- Memory QoS в 1.36: блог релиза — beta, файл гейта и пост cgroups-v2 — alpha (принято: alpha 1.36, beta 1.37).
- SELinux в 1.36: блог релиза называет KEP-1710 stable; гейт SELinuxMount stable только с 1.37 (в 1.36 GA — SELinuxChangePolicy/RWOP-часть, уточнить).
- PSS «host в пробах»: блог 1.34 — Restricted; документ PSS — Baseline (принято: Baseline).
- Удаление kubeadm v1beta3 — конкретный релиз не найден.
- Требования user namespaces к ядру/runtime (ядро 6.3+, containerd 2.0+, runc 1.2+) — по памяти.
- Расположение kuberc (`~/.kube/kuberc`) и переменная `KUBERC` — по памяти.
- Calico 3.31/3.32 — данных не нашёл; поддержка ClusterNetworkPolicy в kindnet — не известна.
- cert-manager 1.21 — дата выхода; поддержка ListenerSet.
- ESO: даты 1.0/2.0 и история «паузы релизов» 2025 — не подтверждено.
- Flux 2.9 детали; Karpenter NodePool изменения по версиям.
- `etcdctl snapshot restore` удалён в etcd 3.6 — по памяти.
- Helm 4: точное имя флага выбора метода apply (`--server-side`) — не сверено.
- Comparable resource versions (KEP-5504) — стадия.
