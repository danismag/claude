# 03-6 NetworkPolicy: отчёт ревьюера

Файл: /home/user/claude/kubernetes/03-networking/03-6-networkpolicy.md. Скрипты правки: scratchpad/fix036r.py, fix036r2.py.

## Найденные ошибки (было → стало)
- ClusterNetworkPolicy: «v0.2.0 от 2 июня 2026» → «21 апреля 2026» (GitHub API: published_at 2026-04-21; 2 июня — дата kind v0.32.0, ошибка исследования).
- CNP: добавлено `ports` → `protocols` (release notes v0.2.0), `priority` 0–1000, меньшее раньше; уточнена семантика Pass (пропускает остальные правила уровня) и Baseline («для трафика, о котором NetworkPolicy не решила»). Удалена непроверенная фраза о beta к KubeCon NA 2026.
- «поддержка CNP в kindnet не подтверждена» → «kindnet подключает только проверку стандартной NetworkPolicy» (kind images/kindnetd main.go: только NewStandardNetworkPolicy).
- kindnet: «метка conntrack» → **conntrack label** (kube-network-policies dataplane: ct label + established,related; не ct mark); добавлено: библиотека kube-network-policies с kind 0.24, очередь 101, таблица появляется после первой NetworkPolicy, fail open (FailOpen: true).
- §5 «Трафик узла»: противоречие «стандарт разрешает… но это поведение реализации» и непроверенное «Cilium с policy-enforcement: always роняет probes» → документация требует пропускать трафик узла; kindnet/Calico/Cilium пропускают; в kindnet — `meta skuid 0 accept`; часть CNI позволяет подчинить трафик узла политикам настройкой. hostNetwork — «стандарт не определяет».
- §5 «Установленные соединения»: добавлено, что стандарт оставляет это реализации (network-policies.md).
- Подготовка: «Deployment api из двух подов» → «из одного пода» (`kubectl create deploy` без `--replicas` создаёт 1 реплику; старая часть так же).
- Работа 2: псевдовывод с выдуманным временем `(0.0s)/(3.0s)` → «Ожидаемый результат», время `(…)`; исправлен разбор шага 1 (пункты 2–3 не соответствовали строкам вывода).
- Работа 3 шаг 3: время, не сохранённое прогоном, → `(…)` и пояснение, что из прогона, что ожидается.
- Работа 5: «Риски» перенесены первым блоком (§3.2); пояснение к `-> internet`: итоги из прогона, команда записана заново, python в образе есть (python:3.12-slim, 00-1); в уборке добавлен вывод `kubectl apply`.
- Работа 1 шаг 4: разбор правил переписан под `ct label`/`ct state established,related`.

## Читаемость
До: 237 предложений, средняя 11,0, короче 10 слов 40 %, нарушений 0. После: 245, средняя 11,4, 36 %, нарушений 0 (поделены два предложения по 26 слов, абзац из 6 предложений, список §6 из 8 пунктов сокращён до 7 — fail open вынесен в абзац с определением). Строки кода ≤100 знаков.

## Подтверждено (источник)
- policyTypes по умолчанию, трафик узла всегда разрешён, endPort (stable 1.25, требует port), hostNetwork не определён, установленные соединения — на усмотрение реализации: kubernetes/website network-policies.md.
- kindnet = kube-network-policies, таблица `kindnet-network-policies`, QueueID 101, FailOpen, только стандартный evaluator: kubernetes-sigs/kind images/kindnetd/cmd/kindnetd/main.go; поддержка политик с kind v0.24.0 (release notes).
- NFQUEUE, ct label, `meta skuid 0 accept`, fail open с bypass: kube-network-policies pkg/dataplane/controller.go.
- CNP v1alpha2: tier Admin/Baseline, Accept/Deny/Pass, priority 0–1000, лимиты 25 правил/пиров/protocols, порядок Admin → NetworkPolicy → Baseline: network-policy-api apis/v1alpha2/clusternetworkpolicy_types.go; Allow→Accept, ports→protocols, 100→25, дата 2026-04-21: release v0.2.0.
- python в orders-api:2.0: 00-1 (FROM python:3.12-slim); метки app=orders-api/app=postgres, порты 8000/5432: 00-1.
- Cilium по умолчанию пропускает трафик с узла к подам: docs.cilium.io (kubernetes/concepts).

## Не подтверждено (для 00-plan)
- Работа 1 шаг 4: вывод `nft list table` (ожидаемый).
- Работа 2: время в строках вывода (прогон дал только коды).
- Работа 3 шаг 3: время во второй строке и после `200`.
- Работа 4 шаг 1 и уборки: стандартные сообщения kubectl (не из прогона); метка echo role=echo вместо app=api — не прогонялась.
- Работа 5: команда проверки `-> internet` записана заново; работа 5 сверх плана §4 — занести в 00-plan.
- «via gateway» через 127.0.0.1:8088 с хоста вместо lab-control-plane:30080 — не прогонялось.
- Cilium: поддержка ClusterNetworkPolicy в 1.19–1.20 — только из исследования.
- Ordered namespace deletion GA 1.34 — из исследования, по KEP не сверено.
- Ссылка networks 08-6 — курс не в этом репозитории, существование раздела не проверено.
- Файл политик перенесён в ~/lab/k8s/03-6/orders-netpol.yaml — поправить ссылку в 12-2.
