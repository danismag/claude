# Ревью 03-2 «Service и kube-proxy»

Файл: /home/user/claude/kubernetes/03-networking/03-2-service-kube-proxy.md. Источники (в scratchpad rv032/): kubernetes release-1.36 pkg/proxy/iptables/proxier.go, pkg/proxy/nftables/proxier.go, pkg/proxy/topology.go, pkg/proxy/metrics/metrics.go, pkg/proxy/apis/config/v1alpha1/defaults.go, cmd/kube-proxy/app/server_linux.go; kubernetes/website: service.md, endpoint-slices.md, virtual-ips.md, service-traffic-policy.md, extend-service-ip-ranges.md, feature-gates/*.md, blog 2026 externalIPs и ipvs; cloud-provider-kind README.

## Ошибки (было → стало)
- ipvs: «источники расходятся, 1.40–1.43» → по документации virtual-ips: выключение по умолчанию в 1.40 (возврат гейтом KubeProxyIPVS), удаление в 1.43; ранний пост называл 1.40.
- Ссылка «чек-лист обновления — 10-2» (10-2 теперь etcd) → 10-3.
- «(00-1 §6)» про EnvoyProxy/Local → 00-1 §5 (раздел «Что ломается», там этот симптом).
- Имя Service с цифры «с 1.37» → с 1.36 (RelaxedServiceNameValidation beta, включено по умолчанию), GA 1.37.
- externalIPs: «kube-proxy выдаёт предупреждения с 1.36» → предупреждает API-сервер; kube-proxy выключит по умолчанию не раньше 1.40 (с opt-in), полностью — не раньше 1.43 (блог deprecation-of-service-externalips).
- localhost:NodePort в nftables: «отдельный прокси (альфа, KEP-6032)» → альфа-гейт KubeProxyNFTablesLocalhostNodePorts (1.37) + `--nodeport-addresses primary,localhost`; абзац с висячим пробелом и обрывом склеен.
- ServiceCIDR: «удалить нельзя» → finalizer держит объект в удалении, пока есть выданные адреса.
- conntrack: «пакет conntrack (Ubuntu и Manjaro)» → в узлах kind уже есть; на реальном узле `conntrack` (Ubuntu) / `conntrack-tools` (Manjaro).
- PreferClose: «устарело в 1.36» → устаревший псевдоним PreferSameZone, сервер 1.36 предупреждает (версия устаревания в документации не указана).
- Переменные *_SERVICE_HOST: уточнено «только для Service своего namespace, созданных раньше пода».
- Лаба 2 шаг 2: первая строка цикла `service/echo-np patched` → `service/echo-np patched (no change)` (политика уже Cluster) + пояснение в разборе.
- Лаба 2 шаг 3: выдуманная форма DROP-строки с «…» → форма по коду iptables proxier.go (filter, KUBE-EXTERNAL-SERVICES, `-m addrtype --dst-type LOCAL`, `--dport 30081`, `-j DROP`) в порядке iptables-save, помечена ожидаемой и перенесённой; разбор п.1 уточнён (таблица filter, любой локальный адрес узла).
- Лаба 2 шаг 4: в выводе нет строк patch — добавлена пометка «строки service/echo-np patched опущены».
- Лаба 3: «три пода на разных узлах» → «планировщик обычно разносит их по узлам» (не гарантировано; лаба 5 шаг 1 это учитывает).
- Лаба 4 шаг 3 разбор: «Сервисы — элементы одного словаря… последняя строка словаря» → первые две строки — словарь ClusterIP, третья — отдельный словарь NodePort (`tcp . 30081`), `}` закрывает его; убрано неточное «не сотни цепочек» (цепочки service-* в nftables тоже есть, разница — поиск по словарю).
- Лаба 4 «Риски»: добавлены — ядро хоста <5.13 ломает Service во всём кластере до отката; аннотация last-applied-configuration остаётся в ConfigMap; откат = команды шага 5, проверка `Using iptables Proxier`.
- Вводная к лабам: «только работа 4 имеет Риски» → работы 4 (kube-proxy) и 5 (метки узлов).
- Лаба 1 «Что понадобится»: «права на создание namespace» → namespace из подготовки (стыковка с вынесенной подготовкой).
- Теория дополнена по исследованию (строки «фраза»): ipMode VIP/Proxy (GA 1.32); /healthz 503 при удалении узла — connection draining (GA 1.31); права cloud-provider-kind (сокет Docker + добавление адресов интерфейсам).

## Читаемость
До: 360 предложений, средняя 11,2, короче 10 слов 39 %, >25 слов 0, нарушений 1 (строка iptables-save 162 знака).
После: 366 предложений, средняя 11,2, короче 10 слов 38 %, >25 слов 0, нарушений 1 (та же строка — исключение, записано в 00-plan §6). Новые длинные предложения разделены, абзац из 6 предложений перестроен (MetalLB перенесён в абзац «В облаке…»).

## Подтверждено (источник)
- REJECT «has no endpoints» / DROP «has no local endpoints» для eTP/iTP Local — iptables/proxier.go.
- route_localnet только в iptables-режиме; nftables не принимает localhost в nodeport-addresses — proxier.go, virtual-ips.md.
- Порты 10249 (метрики, 127.0.0.1) и 10256 (healthz, 0.0.0.0) — defaults.go; метрика kubeproxy_sync_proxy_rules_duration_seconds — metrics.go.
- Строки журнала «Using iptables/nftables Proxier» — server_linux.go; очистка правил другого режима при старте — platformCleanup.
- Fallback на serving+terminating при отсутствии ready — topology.go.
- 100 эндпоинтов в срезе, --max-endpoints-per-slice до 1000; Endpoints ≤1000 (truncated) — endpoint-slices.md, service.md.
- healthCheckNodePort 200/503 — virtual-ips.md; sessionAffinity 10800 с — virtual-ips.md.
- nftables beta 1.31 / GA 1.33, ядро 5.13 — feature-gate NFTablesProxyMode, virtual-ips.md.
- ServiceCIDR/IPAddress GA 1.33 (MultiCIDRServiceAllocator), объект `kubernetes`, finalizer — virtual-ips.md, extend-service-ip-ranges.md.
- trafficDistribution GA 1.33; PreferSameZone/PreferSameNode GA 1.35; PreferClose — устаревший псевдоним — feature gates, virtual-ips.md; предупреждение — реальный вывод старой части.
- ipvs устарел 1.35, 1.40/1.43 — virtual-ips.md; externalIPs deprecated 1.36 — service.md, блог.
- cloud-provider-kind: docker.sock, права на адреса и порты, контейнер Envoy — README.
- Лаба 1 — перенос утверждённого эталона; отличия только в стыковке (шаг namespace вынесен, уборка без удаления ns) — корректны.

## Не подтверждено (для 00-plan)
- Лаба 2: вывод шага 1 и строка DROP шага 3 — ожидаемые (форма по коду, не прогон).
- Лаба 3: вывод шагов 1 и 3 — ожидаемые.
- Лаба 4: число 19 до переключения (взято из прогона «после возврата»); порядок строк grep -m3 при echo-np, созданном в шаге 1; строки warning/configured/restarted.
- Лаба 5: вывод шага 1 и уборки — ожидаемые; имена подов в шагах 2–3 из разных прогонов.
- Уборка лабы 1 (строки deleted) — ожидаемая.
- «kube-proxy 1.37 предупреждает без явного mode» — только по заметкам 1.37 (CL37), в коде 1.36 не сверялось.
- Очистка kube-proxy устаревших UDP-записей conntrack — по памяти, не сверено с кодом.
