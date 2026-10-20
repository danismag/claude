# Ревью 02-3 StatefulSet

Файл: /home/user/claude/kubernetes/02-workloads/02-3-statefulset.md. Коммит не делался.

## Найденные ошибки (было → стало)
- §3 maxUnavailable: «beta с 1.35 и по документации включена по умолчанию; на 1.36 может оказаться выключенной из-за #137409, исправленной в 1.37» → гейт MaxUnavailableStatefulSet beta с 1.35 с Default: false в release-1.36 (kube_features.go); в 1.36.0-rc.0 выключен PR #137904 из-за регрессии 1.35 (#137409, исправлена PR #137666); в 1.37 снова включён (CHANGELOG-1.37, PR #139466). При выключенном гейте API-сервер молча отбрасывает поле (strategy.go, dropStatefulSetDisabledFields). Добавлено определение «функциональный гейт (feature gate)».
- «нуль недопустим» → «нуль API-сервер отклоняет» (validation.go: "cannot be 0").
- §6 значения по умолчанию: maxUnavailable 1 → «1, если гейт включён (в 1.36 выключен)».
- §6 изменяемые поля: в список не входил revisionHistoryLimit → добавлен (validation.go release-1.36: replicas, ordinals, template, updateStrategy, revisionHistoryLimit, persistentVolumeClaimRetentionPolicy, minReadySeconds).
- Лаба 2 шаг 2: «время совпадает со временем первого создания (шаг 2 работы 1)» → «со временем первого старта в шаге 1»: в новой раскладке уборка работы 1 удаляет PVC, и работа 2 создаёт поды заново.
- Лаба 2 шаг 4: «ссылки владельца на них не удалены» (неверно по механике) → «при whenDeleted: Retain у заявок нет ссылки владельца на StatefulSet, поэтому сборщик мусора их не тронул».
- Лаба 3, схема 9: шаги не совпадали с заголовками (maxUnavailable был «шагом 4») → пять шагов по порядку; подпись исправлена.
- Лаба 3, хеши ревизий: вывод снят в старом прогоне другим манифестом (версия в команде, правка патчем, «echo v3 broken; exit 1»), с новым манифестом (env VERSION, set env, exit 1) хеши будут другими → конкретные хеши заменены обозначениями web-<h1>/<h2>/<h3> с пояснением перед первым выводом. Структура вывода (v1/v2, current/update, ready=2, CrashLoopBackOff 3, partitioned roll out complete) — из реального прогона.
- Лаба 3 шаг 5: ожидаемый результат описывал пары как основной исход → основной ожидаемый исход на стенде 1.36: поля maxUnavailable нет в spec (`{"rollingUpdate":{"partition":0},"type":"RollingUpdate"}`), поды пересоздаются по одному; пары — только при включённом гейте (1.37). Пункт разбора «один под в минуту при maxUnavailable: 1 (работа 2)» (бессмыслица, в работе 2 обновления нет) → объяснение шага ≥8 с через sleep 8. Итог и ответ 4 — «гейт» вместо «функция».

## Читаемость
До: 262 предложения, средняя 11,6 слов, коротких <10 слов 36 %, >25 слов 0, нарушений 0. После: 263, средняя 11,8, коротких 35 %, >25 слов 0, нарушений 0. Одно 26-словное предложение, возникшее при правке, разделено.

## Подтверждено (источник)
- Recreate для StatefulSet — alpha 1.37, гейт StatefulSetRecreateStrategy (нужен в kube-apiserver и kube-controller-manager): CHANGELOG-1.37 API Change PR #137187; docs statefulset.md (main). KEP-3541 в CHANGELOG не упомянут — в тексте номера KEP нет, всё верно.
- CoreDNS кэширует 30 с, negative caching: docs statefulset.md.
- revisionHistoryLimit 10, рекомендация 5–10, не 0: docs statefulset.md. partition 0 по умолчанию, partition > replicas — обновлений нет: docs. minReadySeconds 0: docs. terminationGracePeriodSeconds 0 unsafe: docs. Forced rollback, #67250: docs.
- maxUnavailable: проценты вверх, 0 нельзя, считаются ординалы 0…replicas−1, пачки при Parallel: docs + validation.go.
- persistentVolumeClaimRetentionPolicy GA 1.32, ordinals.start GA 1.31, pod-index GA 1.32: research-k8s-changes (R31/R32), docs (PodIndexLabel locked, отключение через emulated version 1.31).
- PVC retention: при отказе узла PVC сохраняется, owner references, unmount до удаления: docs.
- Реальный вывод работ 1–3 сверен со старой версией (e755ced): времена создания, born, IP/UID, df, 127.0.53.53, 8 с/14 с, 3 с/6 с scale down, 6 с снятия partition, sleep 12.

## НЕ ПРОВЕРЕНО (для 00-plan §7)
- `kubectl rollout undo sts/web` в лабе 3 шаг 3 (в прогоне шаблон возвращали JSON-патчем);
- лаба 3 шаг 1 через `kubectl set env` (в прогоне — JSON-патч команды); хеши ревизий заменены обозначениями;
- лаба 3 шаг 5 (maxUnavailable) целиком — ожидаемый результат по коду 1.36 (поле отбрасывается) и документации;
- формат вывода `get pvc -o custom-columns` (л1 ш3, л2 ш1, ш3) — в прогоне был `get pvc` по умолчанию, состояние Bound и состав заявок реальные;
- вывод `getent ahostsv4` в форме трёх строк IP (в прогоне показан иначе, адреса реальные);
- строки `kubectl get pods` после отката в сокращённом виде «web-0 1/1 Running 0» — как в старой части;
- времена born в лабе 2 (09:22:54/09:22:58) взяты из сквозного прогона, где работа 2 не пересоздавала StatefulSet;
- вывод `kubectl get controllerrevisions` (описан словами).
