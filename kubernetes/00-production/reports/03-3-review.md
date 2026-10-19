# 03-3 DNS в кластере — ревью

Файл: /home/user/claude/kubernetes/03-networking/03-3-dns.md (правки в рабочем дереве, без коммита). Документация скачана в /tmp/claude-0/-home-user-claude/740afa2c-c313-5763-bb73-bdca3fdc2abb/scratchpad/docs033.

## Найденные ошибки (было → стало)

1. §6, forward: «до 1000 одновременных запросов на один сервер» → лимит на весь плагин forward, сверх него ответ REFUSED (coredns plugin/forward README).
2. §6 NodeLocal DNSCache: «промахи кэша он отправляет в CoreDNS по TCP» → в CoreDNS по TCP (force_tcp, kube-dns-upstream) идут только промахи cluster.local/in-addr.arpa/ip6.arpa; внешние имена агент шлёт на серверы из resolv.conf узла (nodelocaldns.yaml). Схема 4 дополнена третьей веткой.
3. §6 NodeLocal: адрес 169.254.20.10 подан как обязательный → «обычно 169.254.20.10 из link-local; документация требует только отсутствия пересечений с адресами кластера»; агент — CoreDNS в режиме кэша; ipvs: агент слушает только локальный адрес, в kubelet меняют clusterDNS (nodelocaldns.md). «Точка отказа на каждом узле» → «его сбой бьёт по DNS всех подов узла».
4. Работа 3, разбор шага 3 и вопрос 3: без `fallthrough` hosts отвечает не NXDOMAIN, а SERVFAIL (hosts.go: «we make it SERVFAIL»); hosts стоит в plugin.cfg раньше kubernetes, поэтому ломаются и имена кластера — добавлено.
5. Работа 3, Риски: «документационный адрес 10.0.50.10» → частный адрес (10/8 — RFC 1918, не документационный), которого нет в сети стенда.
6. §5: «повторяет попытку до двух раз» → «отправляет запрос не больше двух раз (attempts:2)» (resolv.conf(5): attempts — число отправок, по умолчанию 2). §6 attempts переформулирован так же.
7. §5 loop: «На Ubuntu kubeadm делает это сам» → на любом узле, где активна systemd-resolved (cmd/kubeadm/app/componentconfigs/kubelet_unix.go mutateResolverConfig); Ubuntu — как пример.
8. §3: «с 1.34 разрешена одиночная точка — нужно клиентам, которые иначе подставляют лишний домен» (назначение не подтверждено) → «проверка searches мягче: разрешены `.` и подчёркивание» (validation.go: search != "." → ValidateDNS1123SubdomainWithUnderScore).
9. §2 таблица и §6: «кэш на 30 с» → «до 30 с» (cache README: TTL только ограничивает срок сверху); в §6 добавлено, что без строки `ttl` плагин kubernetes ставит 5 с.
10. §1 TTL: «клиент и CoreDNS хранят» — неверно для CoreDNS (cache отключён для cluster.local) → «кэш хранит… клиент, который кэширует ответы, видит изменение с задержкой до 30 с».
11. Работа 2 шаг 3, разбор 0,0/5,0 с и вопрос 1: гипотеза «успел ли отказ дойти до сокета» → честная трактовка: 5,0 с — ровно один таймаут; две попытки по таймауту заняли бы ≥10 с, значит повторная отправка, похоже, сразу получила отказ; почему одна отправка теряется — по выводу не видно.
12. Работа 1 шаг 3, разбор: NXDOMAIN в захвате не виден (фильтр `udp dst port 53` берёт только запросы) — оговорено; «ответ дал DNS узла» → «CoreDNS получил через forward от DNS узла».
13. §3 autopath: «особого внимания к версиям» → «в документации плагина перечислены известные ошибки» (autopath README, раздел Bugs).
14. §6: добавлены пределы glibc (ndots ≤15, timeout ≤30, attempts ≤5; до glibc 2.26 search — 6 доменов/256 знаков) и «2048 знаков с пробелами» (validation.go).
15. Уборка работы 1: `unset i py` → `unset i py sel ms n` (функция оставляла глобальные переменные).
16. Схема 3: рамка была перекошена (строка на символ длиннее) — выровнена.
17. Работа 2 шаг 3: «полная с точкой — один запрос» → «одна попытка (пара A и AAAA)».

## Проверка функций (работа 1 шаг 3, работа 2 шаг 1)

- count: Python в одинарных кавычках bash, f-строка с двойными кавычками — корректно; `python -c "$py" "$2"` даёт имя в sys.argv[1]; `.0f` печатает целые мс. `grep -c ' A\| AAAA'` считает строку запроса один раз; `grep -oE '(A|AAAA)\? [^ ]+'` для «AAAA?» даёт «AAAA? имя» (левое совпадение, альтернатива A не проходит на «?»). jsonpath с `$i` в двойных кавычках раскрывается; state.running содержит startedAt — `grep -q started` срабатывает. Тайминг 1+резолв+6 с укладывается в `timeout 7` (как в старой версии). Ошибок нет; форма вывода (целые мс) не прогонялась.
- res: str(gaierror) = «[Errno -3] Temporary failure in name resolution», тип gaierror — совпадает с реальными строками старой версии.
- sed/awk работы 3: GNU sed понимает `\n` в замене; двухстрочная программа awk валидна, блок hosts печатается перед строкой prometheus.

## Читаемость

До: 282 предложения, средняя 12,1 слова, коротких 32–33 %, >25 слов: 0, нарушений 0. После: 284 предложения, средняя 12,2, коротких 32 %, нарушений 0. Строки кода ≤100 символов (проверено посимвольно). Блоки §3 по порядку; эмодзи, «Проверено», вопросов собеседования, чеклистов нет; после каждого `##` есть фраза; ссылки на части (01-1, 01-2, 02-3, 03-1, 03-2, 03-4, 03-6, 04-1, 05-1, 05-5, 11-3) существуют по плану.

## Подтверждено (источник)

- dnsPolicy (ClusterFirstWithHostNet → иначе поведение Default), nameservers ≤3, searches ≤32 и ≤2048, слияние dnsConfig, имена подов `a-b-c-d.ns.pod.cluster.local` — website dns-pod-service.md.
- Relaxed search validation (`.` и `_`) — kubernetes validation.go; GA 1.34 — research-k8s-changes.
- timeout 5 (≤30), attempts 2 (≤5), ndots 1 (≤15), search без лимита с glibc 2.26, MAXNS 3, параллельные A/AAAA с одного сокета — resolv.conf(5) (man-pages, зеркало GitHub).
- kubeadm CoreDNS: requests 100m/70Mi, limit 170Mi, lameduck 5s, ttl 30, max_concurrent 1000, cache 30 с disable success/denial — kubeadm phases/addons/dns/manifests.go.
- reload: 30 с ± 15 с, при ошибке остаётся прежняя конфигурация («Corefile changed but reload failed»), строка «Reloading complete» — reload README, reload.go, website dns-debugging-resolution.md.
- loop: останов при петле, CrashLoopBackOff, 127.0.0.53/systemd-resolved, `resolvConf: /run/systemd/resolve/resolv.conf`, сообщение «Loop … detected» — loop README.
- autopath требует pods verified — kubernetes plugin README.
- kubernetes plugin ttl по умолчанию 5 с — kubernetes plugin README.
- Метрики coredns_dns_requests_total / responses_total{rcode} / request_duration_seconds — metrics README; порт 9153 — Corefile kubeadm.
- Формат журнала log: `[INFO] ip:port - id "A IN name. udp size do bufsize" RCODE flags rsize dur` — log README; строки работы 3 соответствуют формату.
- EndpointSlice без эндпоинтов: контроллер создаёт placeholder со пустыми ports, принтер печатает `<unset>` в PORTS и ENDPOINTS — endpointslice reconciler.go, printers.go (listWithMoreString).
- NodeLocal DNSCache: обход DNAT/conntrack, TCP к CoreDNS для cluster.local, link-local адрес, ipvs и clusterDNS, kube-dns-upstream — nodelocaldns.md, nodelocaldns.yaml.
- hosts без fallthrough → SERVFAIL; порядок плагинов (hosts раньше kubernetes) — hosts.go, plugin.cfg.
- kubeadm и systemd-resolved — kubeadm componentconfigs/kubelet_unix.go.
- cluster-proportional-autoscaler coresPerReplica 256 / nodesPerReplica 16 — пример в website dns-horizontal-autoscaling (по памяти писателя, совпадает с известным примером; файл не скачивался).
- Реальные числа (8/2/4/8/2, 2/6, 925/3670/190 мс, 1,5 с, 0,0/5,0 с, 10 с, 3,3 мс, 33 с, 63 с, 10.96.100.97, флаги qr,aa,rd/qr,rd,ra) — старая версия e755ced.

## Не подтверждено (для 00-plan §7)

- Работа 1 шаг 3: новая форма функции count (целые мс, имя через sys.argv) не прогонялась; порядок A/AAAA в паре.
- Работа 1 шаги 4–5: таблицы сведены из таблиц старой части, не из сырых строк функции.
- Работа 1 шаг 2: resolv.conf пода dns1 (`options ndots:1`) — ожидаемый.
- Работы 1–3, шаги 1: сообщения kubectl run/wait — типовые.
- Работа 2 шаг 1 (`ok after 0.0 s`), шаг 2 (`<unset>` и имя `kube-dns-…` сверены с кодом, но не прогонялись), шаг 4 (строки scale/rollout status).
- Работа 2 шаг 3: причина 0,0 с против 5,0 с — трактовка, не измерена.
- Работа 3: коды NXDOMAIN/NOERROR в строках журнала выведены логически (в старой части только флаги); вывод `head -n 3`; вывод уборки.
- NodeLocal DNSCache целиком (теория, не ставился); адрес 169.254.20.10 — общепринятое значение, не из документации.
- Гонки conntrack: «часть исправлена в ядрах 5.x» — без источника.
- Права профиля `kubectl debug --profile=netadmin` (NET_ADMIN, NET_RAW) — по памяти, документацию kubectl не сверял.
- kube-dns: пакеты не собираются после 1.40; kubeadm 1.36 → CoreDNS v1.14.2, 1.37 → v1.14.6 — из research-k8s-changes, не перепроверено в constants.go.
