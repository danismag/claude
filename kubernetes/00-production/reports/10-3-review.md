# Ревью 10-3 «Обновление кластера»

Файл: /home/user/claude/kubernetes/10-cluster-ops/10-3-cluster-upgrade.md. Старая версия: e755ced:kubernetes/10-cluster-ops/10-2-cluster-upgrade.md.

## Найденные ошибки (было → стало)

- §2 etcd 3.6: «обновляться на 3.6 с 3.5.20 и новее» → «все члены до последнего патча 3.5: текущее руководство etcd требует 3.5.32 или новее» (etcd upgrade_3_6.md).
- §2 mixed version proxy: «требует отдельной настройки» → гейт `UnknownVersionInteroperabilityProxy` beta и включён по умолчанию в 1.36, но нужны флаги доверия (`--peer-ca-file` и др.).
- §2 таблица skew: kube-proxy → добавлено «±3 от kubelet» (version-skew-policy).
- §3 команды узла: установка `kubelet=…`/`kubectl=…` без `apt-mark unhold` падает на закреплённых пакетах → добавлены `unhold`/`hold`; комментарий `kubeadm upgrade node` уточнён: только рабочий узел, после пакета kubeadm.
- §3 v1beta4: «обновление с её помощью (migrate) задают через --config» → «параметры обновления в v1beta4 задают файлом с UpgradeConfiguration».
- §3 AKS: каналы `patch/stable/rapid/node-image` → `none` (по умолчанию), `patch`, `stable`, `rapid` (`node-image` — устаревший); max surge «10 %» → «по умолчанию 1 узел при maxUnavailable 0» (azure-aks-docs upgrade-aks-node-pools-rolling.md, auto-upgrade-cluster.md).
- §3 GKE: «по умолчанию maxSurge=1, maxUnavailable=0» → без чисел (документация GKE недоступна).
- §3 Yandex: добавлено «канал выбирают при создании и не меняют» (yandex-cloud/docs release-channels-and-updates.md).
- §3/§6 EKS: «около 14 + около 12 мес, затем принудительно» → «14 + 12 мес, затем облако само обновляет control plane» (awsdocs kubernetes-versions.adoc).
- §4: добавлены удаления функций из исследования: `nodeInfo.kubeProxyVersion` (1.33), том `gitRepo` (1.36), ipvs устарел (1.35).
- §5 containerd: «2.2 или новее (рекомендован 2.3)» → «для 1.36 — 2.2 или 2.3, для 1.37 — 2.3 или 2.4; 1.7 последний раз в 1.35» (containerd RELEASES.md).
- §5 `--emulated-version`: «нужен, чтобы дать откатиться бинарнику» → «эмулирует API и функции прошлой версии; обновление дробится на шаги» (compatibility-version.md не говорит об откате).
- Работа 1 шаг 5 (ожидаемый вывод): kubelet `v1.36.5` → `v1.36.1` (шаг идёт до работы 2), добавлена строка etcd `3.6.8-0 → 3.7.0-0`; разбор: «строк метрики может не быть».
- Подготовка к работам: пересоздание `--purge` → добавлено предупреждение, что удаляются реестр и `~/lab/k8s` с исходниками (00-1 §3).
- Работа 3: строка таблицы `get pods -o wide -n orders` → как в команде; уборка: `kill` по pid-файлу только если файл есть; лишний пробел в начале абзаца.

## Читаемость

До: 256 предложений, средняя 11,7 слов, короче 10 слов — 35 %, >25 слов — 0, нарушений 0. После: 259 предложений, средняя 11,9, короче 10 — 35 %, нарушений 0 (одно новое длинное предложение разделено). Строки кода ≤100 символов (проверено по символам).

## Подтверждено (источник)

- Skew: kubelet/kube-proxy до N-3 (<1.25 — N-2), CM/scheduler N-1, kubectl ±1, HA apiserver в пределах одной минорной; kubelet на N-3 обновить до следующего обновления control plane — website releases/version-skew-policy.md.
- Поддержка ~14 мес (12 + 2 maintenance), три ветки — releases/patch-releases.md, version-skew-policy.md.
- kubeadm upgrade: бэкапы в /etc/kubernetes/tmp (чистить вручную), продление сертификатов, `--certificate-renewal=false`, addons после последнего CP (с 1.28), идемпотентность и `--force`, drain для минорного kubelet, CNI вручную, нельзя пропускать минор — kubeadm-upgrade.md.
- Флаги apply: `--etcd-upgrade` (true), `--certificate-renewal` (true), `-y`, `--force`, `--config` — generated/kubeadm_upgrade_apply.md.
- kubeadm 1.36: etcd 3.6.8-0, CoreDNS v1.14.2, pause 3.10.2; 1.37: etcd 3.7.0-0, CoreDNS v1.14.6 — constants.go (release-1.36, release-1.37).
- etcd 3.6: `etcdutl check v2store`, минимум 3.5.32 — etcd website upgrade_3_6.md.
- Удалений API в 1.33–1.37 нет, последнее — flowcontrol v1beta3 в 1.32 — deprecation-guide.md.
- Аннотации аудита `k8s.io/deprecated`, `k8s.io/removed-release` — audit-annotations.md.
- Метрики `apiserver_requested_deprecated_apis` (gauge, STABLE) и `kubelet_cri_losing_support` (метка version) — instrumentation/metrics.md; строка endpoints с пустым removed_release — реальный вывод 01-3.
- cgroup v1: failCgroupV1=true с 1.35, SystemVerification — ошибка, удаление обхода — план 1.38, ядро 5.8+/5.9+ для Memory QoS — blog 2026/kubernetes-cgroups-v2-shift.md, cgroups.md.
- containerd ↔ Kubernetes — containerd RELEASES.md. EKS 14+12 — awsdocs. AKS каналы и surge — MicrosoftDocs/azure-aks-docs. Yandex каналы, окна; deploy_policy max_expansion/max_unavailable — yandex-cloud/docs, terraform-provider-yandex.
- Реальный вывод работ 1–3 (план 1.36.5, exit=0 took 105s, журнал staticpods, ok=1359 fail=0, swap+ready 4s, 139s/8s/2s, health true, SAN 172.20.0.4/0.2, noexec /tmp) — старая версия части.
- Стенд после работ — 1.36.5, образ узла v1.36.1, возврат только `--purge` + `lab-up.sh` — согласовано с 00-1 и lab-up.sh (NODE_IMAGE).

## Не подтверждено (для 00-plan §7)

- GKE: названия каналов Rapid/Regular/Stable/Extended и наличие maintenance window — docs.cloud.google.com недоступен.
- EKS managed node group `maxUnavailable` — не сверено.
- Пути `/root/lab-10-3/...` в узлах kind и бинарник `/root/lab-10-3/kubeadm` — логика старого прогона, сами пути не прогонялись.
- Работа 1 шаг 3: формат вывода `openssl -ext subjectAltName` — ожидаемый.
- Работа 1 шаг 5: вывод `upgrade plan v1.37.1` (кроме `Target version`) и строка метрики — ожидаемые.
- Работа 2 шаг 2: новая форма команды замера (`echo exit=$?` на хосте) — вывод из старого прогона.
- Работа 2 шаг 4: команды `jq`/`jsonpath` восстановлены, строки вывода — из старого прогона.
- Работа 3: строки `uncordoned` и время lab-worker3; вывод шага 1 (`get pods -o wide`) — ожидаемые.
- §3 пакетные команды apt (pkgs.k8s.io, hold/unhold) — по документации, не прогонялись.
- Время перезапуска etcd «около 35 с» в «Рисках» работы 1 — оценка по sleep 15 + 20, не замер.
