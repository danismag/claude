# Отчёт писателя: 02-4

Файл: /home/user/claude/kubernetes/02-workloads/02-4-daemonset-job-cronjob.md
Читаемость: readability.py — нарушений 0, средняя длина предложения 10,5, >25 слов: 0.
Объём прозы (без кода/вывода, с таблицами): около 2550 слов; ниже ориентира 3,5–4,5 тыс. — механизм уложился, лабы не резались.

## Сомнительные места
- Потолок back-off Job: 10 мин по текущей документации Job; старая часть говорила 6 мин. Проверить по коду job controller.
- Событие при более чем 100 пропусках: текст говорит «пишет ошибку в лог, Job не создаёт»; название события и то, остаётся ли CronJob заблокированным навсегда, не подтверждено (не воспроизводилось).
- Лаба 1 шаг 4: вывод custom-columns не приведён блоком, только времена из старого прогона (09:29:17/27/47; 17/23/29) — имена подов не выдуманы.
- Лаба 1 шаг 2: пояснение «18 с = три волны по ~6 с» — моя интерпретация (старая часть писала «18 с вместо 6×3», что арифметически неверно).
- Лаба 2 целиком ожидаемая (фраза в начале): значения completed/failed индексов, failed=6, ~25s, пустой список Running после successPolicy, Terminating/имена подов в podReplacementPolicy, время 3 с двух подов. Особенно проверить: поведение лишних подов после SuccessPolicy; failed=1 при FailIndex; что pr-default создаёт замену сразу при ручном delete pod.
- Лаба 3: форма вывода списка Job сокращена до 4 колонок (AGE опущена) по строкам старого прогона; в jsonpath для T использован синтаксис с T+= (не прогонялся).
- Лаба 4: вывод taint control-plane (`[{"effect":"NoSchedule","key":"node-role.kubernetes.io/control-plane"}]`), updateStrategy в JSON и строки cordon/uncordon — ожидаемые, не из старого прогона. `jq` предполагается установленным (00-2 упоминает).
- Статус возможностей: mutable resources у suspended Job (beta 1.36), gang scheduling (alpha 1.35, beta 1.37) — по исследованию; managedBy/podReplacementPolicy/backoffLimitPerIndex/successPolicy GA — по исследованию (страница Job версий GA не даёт).
- Ссылки: 05-3 (priorityClassName), 05-5 (drain), 11-1 (kube-state-metrics), 11-4 (лог контроллера) — по плану, номера не сверялись с написанными частями.
- Лаба 2 шаг 4 `kubectl delete pod -l batch.kubernetes.io/job-name` (селектор без значения) — допустим в kubectl, не прогонялся.

## Отличие от плана
Вместо трёх работ четыре: Job (старый вывод), Indexed Job (backoffLimitPerIndex, FailIndex, successPolicy, podReplacementPolicy), CronJob, DaemonSet. managedBy, elastic Indexed Jobs, mutable resources, gang — только теория. Записать в 00-plan §6.

## Выброшено/перенесено в модуль 12
- Кейс «CronJob бэкапа молча не запускался неделю»: Forbid + зависший pg_dump без таймаута; фикс activeDeadlineSeconds, startingDeadlineSeconds, PGCONNECT_TIMEOUT, алерт по lastSuccessfulTime >26 ч (04-3 ссылается на «кейс 02-4»).
- Вопросы: зачем DaemonSet; Job против Deployment; почему DS не на control-plane; backoffLimit/activeDeadlineSeconds; Allow/Forbid/Replace; как не ретраить ошибку конфигурации; почему CronJob перестаёт запускаться; Job дважды и идемпотентность; обновление DS в большом кластере.
- Подводные камни: Forbid+зависший Job, 100 пропусков, timeZone не меняет часы, deadline на весь Job, OnFailure против Never, sidecar в containers, DS без toleration, неизменяемый template Job.
- Звёздочка: правильный бэкап-CronJob для PostgreSQL (перекрыта 04-3).
