# Ревью 01-1 «Control plane и путь запроса»

## Найденные ошибки (было → стало)
- §2 схема 4 и список: 422 стоял у validating admission → 422 у проверки схемы, 403 у validating admission (api-concepts; ответ admission — Forbidden).
- §2 «Хранение в etcd»: «значение — protobuf с префиксом k8s\0» → уточнено: так у встроенных объектов, CRD хранятся в JSON.
- §2: «resourceVersion сравнивать можно только на равенство» → с 1.35 у встроенных ресурсов сравнимы как числа внутри вида ресурса; у агрегированных API — только равенство (блог 1.35 KEP-5504; api-concepts.md).
- §5: «при долгой недоступности API приложения получат 401 (токен 1 ч)» → по умолчанию apiserver выписывает токены kubelet с запасом до 1 года (--service-account-extend-token-expiration=true, min(1 год, max)), 401 — только при выключенном запасе (kube-apiserver reference; service-accounts-admin.md).
- §6: «consistent reads из кэша (с 1.31) не обращаются к etcd» → GA в 1.34 (beta on с 1.31); apiserver узнаёт у etcd текущую ревизию (FG ConsistentListFromCache; api-concepts).
- Таблица §5: код в ячейках убран; строки вывода >100 знаков (лаба 1 шаг 1, лаба 3 шаги 5–6) сокращены/перенесены с пометкой.

## Добавлено по плану и исследованию
- §2 Watch: streaming list (WatchList: sendInitialEvents=true, resourceVersionMatch=NotOlderThan, ADDED + BOOKMARK), beta, on с 1.34 (FG WatchList, api-concepts).
- §2 Leader election: coordinated leader election / LeaseCandidate — beta, выключен в 1.36 (FG CoordinatedLeaderElection).
- §3 APF: 429 Too Many Requests при полной очереди; API только flowcontrol.apiserver.k8s.io/v1, v1beta3 удалён в 1.32 (research R32; flow-control.md).
- §4: /statusz и /flagz — beta, on с 1.36 (FG ComponentStatusz, ComponentFlagz).
- §6 Нагрузка: общий предел 400 + 200 = 600 (--max-requests-inflight, --max-mutating-requests-inflight); 1.37 — устойчивый запуск watch cache с ответом 429 (research R37).
- §6 Etcd: запрос ≤ 1,5 МиБ, квота 2 ГиБ, рекомендуемый максимум 8 ГиБ (etcd v3.6 limit.md).
- §6 новый подраздел «Пределы масштаба»: 5000 узлов, 110 подов на узел (= maxPods), 150 000 подов, 300 000 контейнеров; события — в отдельный etcd (cluster-large.md). «Время реакции на отказ узла» влито в «Высокая доступность» (чтобы в §6 было 5 подразделов).

## Читаемость
- До: 258 предложений, средняя 9,8 слова, 50 % короче 10 слов, 14 нарушений (3 предложения >25, 2 абзаца по 6, 4 строки кода >100, 5 «код в ячейке»).
- После: 243 предложения, средняя 11,3 слова, 35 % короче 10 слов, 3 нарушения — все «код в ячейке» в таблицах разбора команд (строки 497, 530, 563): ложное срабатывание проверки на экранированный `\|` в первом столбце.
- Сшиты ~70 пар рубленых предложений об одной мысли; абзацы >5 предложений разделены; длинные предложения разбиты.

## Подтверждено (источник)
- --event-ttl 1h, --etcd-compaction-interval 5m, --max-requests-inflight 400, --max-mutating-requests-inflight 200, --enable-priority-and-fairness true — kube-apiserver.md.
- 429 при отказе APF — flow-control.md; таблица FlowSchema — реальный вывод старой части.
- Leader election 15/10/2 с; NotReady ~50 с (node-monitor-grace-period 50 с с 1.32), 300 с tolerationSeconds — общеизвестные значения по умолчанию, совпадают со старой частью.
- Реальный вывод (4306/4307, 5263→5265, 838/402, 4336/4338, 410 «10 (2942)», условия пода, 2 с, 21 с, 3 с, 13 с, crictl, lease) — совпадает со старой версией e755ced.

## Осталось неподтверждённым (для 00-plan)
- Лаба 1 шаг 1: формат строк `"Response" verb=… url=… status=…` сокращён; grep '"Response"' зависит от формата логов kubectl 1.36 (по старому прогону совпадает).
- Лаба 2 шаг 1: вывод jq (JSON вместо формата Python старого прогона) — ожидаемый, числа реальные.
- Лаба 3 шаг 4: строка «прошло 21 с» — форма вывода новая, число из старого прогона.
- Лаба 3 «Риски»: «короткий всплеск CPU» — оценка.
- §3: «kubelet замечает удаление манифеста за секунды» — по inotify; периодическая проверка 20 с (fileCheckFrequency), не сверено с кодом.
- §4: `/readyz?verbose` перечисляет проверки, включая etcd — по знаниям, не прогонялось.
- §6: «resilient watch cache init stable в 1.37» — только по исследованию (R37), не сверено отдельно.
- Отклонение от правила карточек: etcdctl впервые появляется в 01-1, а карточка отложена в 10-2 — решить ведущему и записать в 00-plan §6.
