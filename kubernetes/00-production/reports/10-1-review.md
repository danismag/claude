# Ревью 10-1 «Сборка кластера: kubeadm, PKI, TLS bootstrap, HA control plane»

Файл: /home/user/claude/kubernetes/10-cluster-ops/10-1-cluster-build.md (новая часть). Режим «только текст»: исходники kind v0.32.0 и kubernetes release-1.36 скачаны в scratchpad (r101/), команды лабораторных не запускались.

## Найденные ошибки (было → стало)

1. Работа 1, шаг 2: вывод показывал кавычки (`podSubnet: "10.244.0.0/16"`, `criSocket: "unix://…"`), порядок полей из шаблона и одну строку criSocket → kind всегда прогоняет шаблон через patch.KubeYAML (YAML→JSON→YAML), поэтому ключи по алфавиту, без кавычек и комментариев; criSocket дважды (Init и Join); после certSANs идёт extraArgs. Добавлен пункт разбора об этом.
2. Работа 1, шаг 1, разбор: «kind пишет один и тот же файл на каждый узел» → файл из одного шаблона, у каждого узла свой (адрес, имя узла).
3. §4 «Как kind вызывает kubeadm»: preflight пропущен «потому что проверки в контейнере не имеют смысла» → по коду kind: kind заранее кладёт образы, и preflight может с этим конфликтовать.
4. Работа 1, шаг 5: в списке привязок не было `kubeadm:apiserver-kubelet-client` (в 1.36 её создаёт фаза bootstrap-token, AllowAPIServerToAccessKubeletAPI) → добавлена; в kube-public не было `local-registry-hosting` (создаёт lab-up.sh) → добавлена; `kubeadm:node-proxier` создаёт фаза addon, а не bootstrap-token/kubeconfig → исправлены таблица и разбор, `kube-root-ca.crt` отнесён к controller-manager.
5. Работа 1, шаг 6 (`config migrate`): вывод показывал один ClusterConfiguration с `timeouts` → migrate добавляет InitConfiguration (первым документом), `timeouts.controlPlaneComponentHealthCheck` уходит в неё; ключи по алфавиту (`apiServer` перед `apiVersion`). Разбор исправлен.
6. Работа 3, шаг 4: в cds.yaml backend показаны как `<IP узла>` → kind пишет имена контейнеров (`lab-10-1-control-plane` и т. д., тип STRICT_DNS); фильтр `grep -E 'address:|…|path:'` ловил `socket_address:` и `event_log_path:` → `grep -E ' (address|port_value|path): '`; порядок вывода (path до endpoints) исправлен.
7. Работа 3, шаг 3: одна строка «Marking the node» на узел → kubeadm печатает две (labels и taints); строки обрезки >100 знаков → `cut -c1-96`, вывод пересчитан.
8. Работа 3, шаг 8, разбор: «балансировщик исключает последний backend, поэтому connection refused/EOF» → у Envoy по умолчанию panic mode (здоровых <50 %), соединения всё равно идут на последний API-сервер, ошибку обычно возвращает он.
9. Работа 2, шаг 4, разбор: «kubeadm переписал kubelet.conf (фаза kubelet-finalize)» для lab-worker → на рабочем узле kubelet.conf пишет сам kubelet в конце TLS bootstrap; kubelet-finalize — только на первом узле control plane (init).
10. §2: v1beta3 «срок удаления в документации не назван» → doc.go release-1.36: «will be removed in a future release, 1.34 or later»; kubeadm 1.36 её ещё читает.
11. §2 TLS bootstrap: «группа имеет право только создавать CSR» → ещё чтение узлов (`kubeadm:get-nodes`) и того, что нужно join.
12. §2 aggregation: «API-сервер подписывает передачу сертификатом front-proxy-client» → подключается с клиентским сертификатом, расширение проверяет его по front-proxy-ca.
13. §2: patches kubeadm и `kubeadmConfigPatches` kind названы «тем же приёмом» → kind правит файл конфигурации, а не манифесты.
14. §1: «три CA и одиннадцать пар ключей» (читалось как 3+11) → одиннадцать пар всего, включая CA и sa.
15. §3 HA: «три или пять узлов … переживает потерю одного» → три — одного, пять — двух.
16. Карточка kubeadm, частые ошибки: `timed out waiting for the condition` → `[control-plane-check] kube-apiserver is not healthy after 4m0s` (apiclient/wait.go 1.36).
17. §4: check-expiration «примерно десять строк» → одиннадцать; §6: «срок CSR, 1 год» → 1 год (флаг controller-manager), без кода в ячейке.

## Дублирование с 10-2…10-4

- Работа 2 шаг 1 повторял 10-4 работу 1 шаг 1 (тот же `check-expiration` и вывод), шаг 4 — 10-4 шаг 2 (тот же grep rotateCertificates). Шаг 1 заменён на «файлы pki и их CA» (ls + цикл `openssl x509 -issuer`, CN CA из certlist.go: kubernetes, etcd-ca, front-proxy-ca); `ls` перенесён из шага 2, шаг 2 — только сертификат API-сервера. Из шага 4 убран grep rotateCertificates, фокус — результат TLS bootstrap, backdate 5 минут и kubelet.conf. Итог и вопрос 2 переписаны (вопрос о «минус 5 минут» вместо rotateCertificates). Реальный вывод check-expiration остаётся в 10-4.
- §3 «Ротация сертификатов kubelet» сокращён до того, что включает kubeadm (rotateCertificates, привязка), механика и serverTLSBootstrap — ссылкой на 10-4.
- Обновление (10-3) и etcd (10-2) не дублируются; в 10-3 есть два абзаца о v1beta4 и migrate — пересечение небольшое, лаба migrate только в 10-1.
- Ссылки на 10-1 из 10-3 («карточка kubeadm (10-1)») и 10-4 («PKI и TLS bootstrap kubelet», «токен 24 часа (10-1)», «CA, 10-1») находят нужные разделы.

## Читаемость

До: средняя 11,4 слова, коротких 38 %, нарушений 1 (26 слов в «Дальше», стр. 1589). После правок фактов: 2 строки кода по 108 знаков (исправлено). Итог: средняя 11,3, коротких 37 %, нарушений 0. «Дальше» разделено на два предложения.

## Подтверждено (источник)

- Envoy вместо HAProxy, образ `docker.io/envoyproxy/envoy:v1.36.2`; `/home/envoy/cds.yaml` (и lds.yaml, envoy.yaml); health check `/healthz`, interval 2s, timeout 3s, unhealthy_threshold 2, журнал проверок в stdout; listener 6443 — kind v0.32.0 pkg/cluster/internal/loadbalancer/{config,const}.go.
- Имя `<кластер>-external-load-balancer` — constants.ExternalLoadBalancerNodeRoleValue + MakeNodeNamer (providers/docker/provision.go v0.32.0); порт LB публикуется на APIServerAddress.
- /kind/kubeadm.conf: шаблон v1beta4 для 1.36+, пять документов в порядке Cluster/Init/Join/Kubelet/KubeProxy, controlPlaneEndpoint = узел или LB:6443, certSANs [localhost, APIServerAddress], criSocket containerd, unsafeSkipCAVerification: true, skipPhases preflight; подсети по умолчанию 10.244.0.0/16 и 10.96.0.0/16 — kubeadm/config.go, apis/config/default.go v0.32.0; пересериализация — internal/patch/kubeyaml.go, resource.go.
- kind: `kubeadm init --config=/kind/kubeadm.conf --skip-token-print --v=6`; копирование admin.conf, ca, front-proxy-ca, sa, etcd/ca на остальные CP; CP-узлы по очереди, рабочие одновременно — kubeadminit/init.go, kubeadmjoin/join.go v0.32.0.
- 14 фаз init в порядке таблицы — cmd/kubeadm/app/cmd/init.go release-1.36.
- Привязки kubeadm:get-nodes, kubeadm:kubelet-bootstrap, kubeadm:node-autoapprove-bootstrap, kubeadm:node-autoapprove-certificate-rotation, kubeadm:node-proxier, kubeadm:cluster-admins, kubeadm:apiserver-kubelet-client — constants.go, phases/bootstraptoken/node/tlsbootstrap.go, cmd/phases/init/bootstraptoken.go release-1.36.
- Learner при join CP: AddMemberAsLearner без feature gate (EtcdLearnerMode в features.go 1.36 уже нет, т. е. поведение постоянное); строка «[etcd] Announced new etcd member joining to the existing etcd cluster» — phases/etcd/local.go.
- Preflight 2 CPU и 1700 МБ — constants.go ControlPlaneNumCPU/ControlPlaneMem, preflight/checks.go InitNodeChecks.
- kubelet-finalize: подфаза enable-client-cert-rotation, опирается на kubelet-client-current.pem — cmd/phases/init/kubeletfinalize.go.
- «Минус 5 минут»: signer.go Backdate 5m, Short 8h; policies.go NotAfter = now + TTL − Backdate для долгих сертификатов.
- Тайм-ауты v1beta4 (4m/4m/1m/2m/5m/5m/5m), сроки 8760h/87600h, etcd 3.6.8-0, CoreDNS v1.14.2, pause 3.10.2, kubelet −3 — constants.go release-1.36.
- Сообщения «[mark-control-plane] Marking the node … labels/taints», «[addons] Applied essential addon: CoreDNS», «[control-plane-check] … is not healthy after» — markcontrolplane.go, dns.go, apiclient/wait.go.
- CN CA: kubernetes, etcd-ca, front-proxy-ca; apiserver-kubelet-client без O — phases/certs/certlist.go.
- v1beta3 устарела, «1.34 or later» — apis/kubeadm/v1beta3/doc.go release-1.36.
- Реальный вывод из старой 10-3 (e755ced): check-expiration (теперь только в 10-4), ls /var/lib/kubelet/pki, subject/notAfter kubelet-client, совпадает.

## Не подтверждено (для 00-plan §7)

- Работа 1 целиком (ожидаемый вывод): версия v1.36.1 в kubeadm version -o short; вывод grep по пересериализованному kubeadm.conf (отступы go-yaml); вывод init-defaults; блок фаз в `kubeadm init --help`; вывод `config migrate` через /dev/stdin; присутствие kubeadm:apiserver-kubelet-client в 1.36.1.
- Работа 2: вывод цикла `openssl -issuer` и SAN apiserver.crt; subject admin/super-admin/controller-manager/scheduler; kubelet.conf на lab-worker; kubelet.crt CN=<узел>@ts; пустые get csr и token list.
- Работа 3 целиком: вывод kind create -v 3 (статусные строки без эмодзи); имя образа в docker ps (с префиксом docker.io или без); метки фаз в журнале; panic mode Envoy при одном backend и тексты ошибок при потере кворума; единичные fail в первые секунды; NotReady ~50 с; возврат членов etcd после docker stop/start.
- Теория: jitter ротации 70–90 % (по 10-4); cgroup v1 — ошибка preflight с 1.35 (по исследованию); пакет kubeadm в Manjaro; ветка pkgs.k8s.io v1.36 (не сверено с документацией установки).
