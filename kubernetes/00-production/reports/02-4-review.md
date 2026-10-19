# Ревью 02-4 «DaemonSet, Job, CronJob»

Файл: /home/user/claude/kubernetes/02-workloads/02-4-daemonset-job-cronjob.md
Источники (скачаны в scratchpad/rv024): kubernetes/kubernetes master — pkg/controller/job/job_controller.go, backoff_utils.go; pkg/controller/cronjob/cronjob_controllerv2.go, utils.go; pkg/controller/daemon/util/daemonset_util.go; website — concepts/workloads/controllers/job.md, cron-jobs.md, daemonset.md, tasks/manage-daemon/update-daemon-set.md.

## Найденные ошибки (было → стало)
1. §2 back-off: «потолок 10 мин взят из документации» → подтверждено кодом: `DefaultJobPodFailureBackOff = 10s`, `MaxJobPodFailureBackOff = 10min` (job_controller.go); 6 мин — значение старых версий; добавлено: при backoffLimitPerIndex пауза считается по индексу (getRemainingTimePerIndex).
2. §5 и §6 «>100 пропусков: Job не создаётся, ошибка в лог» → по коду controller v2 (utils.go nextScheduleTime) пишется Warning-событие `TooManyMissedTimes`, но Job за последнее пропущенное время всё же создаётся; документация описывает старое поведение — расхождение названо в тексте. Добавлено событие `MissSchedule` при опоздании сверх startingDeadlineSeconds.
3. Лаба 2 шаг 4: при `TerminatingOrFailed` удалённый под засчитывается как неудачный (isPodFailed: DeletionTimestamp != nil), и замена ждёт back-off 10 с (manageJob → getRemainingTime). Ожидание «замена через 3 с» было неверным → `sleep 3` заменён на `sleep 15`; вывод переписан без выдуманных AGE/READY (колонки опущены), добавлен столбец FAILED (1 у pr-default, `<none>` у pr-failed); замена pr-failed — примерно через 30 с после удаления (20 с grace + 10 с back-off).
4. Лаба 2 шаг 4: `kubectl delete pod -l batch.kubernetes.io/job-name` (селектор «ключ существует» — синтаксически допустим) задевал поды всех Job'ов namespace → `-l 'batch.kubernetes.io/job-name in (pr-default,pr-failed)'`, тот же селектор у `get pods`.
5. Лаба 2 шаг 1: выдуманный `DURATION ~25s` → `…` с пояснением.
6. Лаба 3 шаг 2: в выводе Job'ов был добавлен заголовок, которого не может быть (`grep backup` его отфильтровывает; в старом прогоне его нет) → убран, пометка в подписи.
7. §6: фраза «где указано в лабораторных, проверены на стенде» (метка проверки) → «по документации и коду контроллеров».
8. §3 podReplacementPolicy: добавлено, что `TerminatingOrFailed` — по умолчанию без podFailurePolicy, `Failed` — по умолчанию и единственное при podFailurePolicy; замена ждёт back-off.

## Дополнена теория (без воды)
- DaemonSet: пересчёт узлов при смене меток, новый узел — по текущему шаблону; приоритет/PriorityClass и вытеснение (совет документации), `system-node-critical` (ссылка 05-3).
- Обновление DaemonSet: maxUnavailable и maxSurge не оба 0; `minReadySeconds`; OnDelete отдельным абзацем.
- CronJob: формат расписания (поля и диапазоны, списки, шаги, `?`, имена, макросы @yearly…@hourly) со схемой 6; timeZone (IANA, пояс kcm по умолчанию, встроенная tzdata); аннотация `batch.kubernetes.io/cronjob-scheduled-timestamp` (1.32); «примерно один раз» — нужна идемпотентность; Forbid запускает пропущенное после завершения прошлого Job (в пределах startingDeadlineSeconds); concurrencyPolicy только внутри одного CronJob.
- Схемы перенумерованы 7–10.

## Читаемость
До: 262 предложения, средняя 10,5 слова, коротких 48 %, >25 слов 0, нарушений 0.
После: 288 предложений, средняя 10,9, коротких 44 %, >25 слов 0, нарушений 0 (по ходу исправлены 1 длинное предложение и 2 абзаца по 6 предложений). Объём прозы части вырос примерно на 500 слов (теория §2–§3).

## Подтверждено
- Автоматические tolerations DaemonSet (6 + network-unavailable при hostNetwork) — daemonset_util.go.
- backoffLimit 6, MaxInt32 при backoffLimitPerIndex, FailedIndexes, FailureTarget→Failed, SuccessCriteriaMet/SuccessPolicy → Complete с той же причиной (job_controller.go: Complete копирует reason), порядок условий с 1.31 — job.md, код.
- FailIndex засчитывается в status.failed (nonIgnoredFailedPodsCount исключает только Ignore).
- 52 знака имени CronJob, 3/1 history, startingDeadlineSeconds <10 с, 10-секундная проверка (по документации), запрет TZ/CRON_TZ, timeZone GA 1.27 — cron-jobs.md.
- JobAlreadyActive типа Normal — cronjob_controllerv2.go.
- updateStrategy по умолчанию, minReadySeconds 0 — update-daemon-set.md.
- Версии GA (podFailurePolicy 1.31, backoffLimitPerIndex/successPolicy 1.33, podReplacementPolicy 1.34, managedBy 1.35, elastic 1.31, mutable resources suspended beta 1.36, gang alpha 1.35/beta 1.37) — по research-k8s-changes.md, согласованы.
- Ссылки 01-2, 02-1 §4/§5, 05-3, 05-5, 11-1, 11-4 существуют по плану.

## НЕ ПРОВЕРЕНО (для 00-plan)
- Лаба 2 целиком ожидаемая: значения completed/failed индексов, failed=6, FailIndex failed=1, пустой список Running после successPolicy.
- Лаба 2 шаг 4: тайминг замены (~10 с для TerminatingOrFailed, ~30 с для Failed) выведен из кода, не прогонялся.
- Лаба 4: вывод taint control-plane, JSON updateStrategy, строки cordon/uncordon — ожидаемые.
- Лаба 1 шаг 4: вывод custom-columns не приведён блоком (только времена старого прогона).
- Поведение при >100 пропусках (событие TooManyMissedTimes + запуск последнего) — по коду master, не воспроизводилось.
- Лаба 3 шаг 3: jsonpath с `T+=` не прогонялся в новой форме.
