# 02-5 Probes и завершение пода — ревью

Файл: /home/user/claude/kubernetes/02-workloads/02-5-probes-shutdown.md (правки в рабочем дереве, без коммита).

## Найденные ошибки (было → стало)

1. `seconds: 0` в preStop sleep: «разрешили там же, в 1.34» → beta и включено по умолчанию с 1.33, stable с 1.34 (kube_features.go release-1.36: PodLifecycleSleepActionAllowZero alpha 1.32 / beta 1.33 / GA 1.34). Исправлено в §3 и §6.
2. `lifecycle.stopSignal`: «статус в 1.36 проверяйте по документации» → в 1.36 alpha, gate `ContainerStopSignals` выключен по умолчанию (в master/1.37 тоже alpha), обязательно `spec.os.name` (pod-lifecycle.md).
3. «Контейнеры пода kubelet останавливает параллельно» → основные контейнеры получают сигнал в произвольном порядке, без гарантий; sidecar — после них (pod-lifecycle.md).
4. «У readiness такого поля нет» (probe-level terminationGracePeriodSeconds) → поле есть в типе Probe, но для readiness API-сервер его отклоняет (probes.md). Добавлено в §6.
5. Метрика: «по всему узлу в prober_probe_total» → эндпоинт kubelet `/metrics/probes`, метрика `prober_probe_total` с метками probe_type, result (prober_manager.go, server.go release-1.36).
6. «SHUTDOWN_DELAY 503 → EndpointSlice пометит адрес неготовым» — неточно: завершающийся адрес и так `ready=false`; 503 даёт `serving=false`. Переписано (§3, шаг 1 списка) + в §2: при удалении liveness/startup останавливаются, readiness работает до конца (worker.go).
7. grpc: «порт указывают числом» как критерий успеха → успех — статус `SERVING`; число порта перенесено в §6.
8. Схема работы 1: «rollout restart на 30-й секунде нагрузки» → 30 с нагрузки, restart на 3-й секунде (по функции `run`).
9. §5 «5100–5600 запросов» → 5100–5700 (в записи до 5656).
10. load.py: добавлен явный `import urllib.error` (используется `urllib.error.HTTPError`; работало только за счёт побочного импорта). Остальное корректно: `getattr(e,"reason",e)` даёт ровно `TimeoutError:timed out` и `URLError:[Errno 111] Connection refused`, как в записи; detail только при ошибках — как в старых строках B/C. Добавлена фраза о связи с клиентом из подготовки к лабораторным 02-2 (там ~/lab/k8s/02-2/load.py без Host и без причины ошибки). Свой файл ~/lab/k8s/02-5/load.py и /tmp/load.py в поде client — по правилу имён, ссылки «шаг 0 02-2» больше нет.
11. Схема 4 дублировалась номером после вставки — схемы перенумерованы 1–10.

## Вывод — приведён к честной форме

- Шаг 3 работы 1: вместо достроенного заголовка `A: …` с отступами — реальные строки записи с меткой `A2 via gateway/service`, перенос `detail` оговорён.
- Шаг 1 работы 2: метка `B2: preStop sleep 5 (repeat)` как в записи (было «B: … (repeat)»). Вариант C совпадает с записью дословно.
- Базовая строка 544: оговорено, что в записи строка сокращена, хвост `error_window=0s` печатает клиент всегда.
- Шаг 3 работы 2: «ожидаемый вид результата, числа 2,1/30,8 с из прогона, где печатались мс».
- Шаг 4 работы 2: «Этот шаг вы выполняете сами…»; придуманные «1.x s / 5.x s» заменены на `…`, разбор — «заметно быстрее 5 с» / «не быстрее 5 с». Формат события FailedPreStopHook сверен с примером в container-lifecycle-hooks.md («Exec lifecycle hook ([cmd]) for Container … failed - error: …»).
- Работа 4: фраза «Эту работу вы выполняете сами…» перенесена в начало работы (сырого вывода нет ни в одном шаге; числа шагов 3–4 — из сводной таблицы автора), из шага 3 убрана.

## Дополнено (механика, без воды; теория ~2,7 → ~3,3 тыс. слов)

- §2 «Порядок проб»: воркер на каждую пробу, свой таймер, первая проверка сразу, случайная задержка только после рестарта kubelet; исходы Success/Failure/Unknown; счётчик серий и пороги; readiness вне расписания до готовности; молчание воркера после провала liveness до нового контейнера; поведение проб при удалении пода. Схема 4.
- §2 «Кто читает Ready»: readiness gates (`spec.readinessGates`, отсутствующее условие = False, ставит внешний контроллер). Схема 5.
- §6 «Способы проверки: цена и ограничения»: exec через CRI ExecSync, нагрузка на CPU узла, ExecProbeTimeout залочен с 1.35; httpGet — 10 КиБ тела, редиректы и ProbeWarning, Host через httpHeaders, нет DNS кластера; grpc — только число порта, поле service, TLS-режим alpha 1.37; tcpSocket — только «порт открыт».

## Читаемость

До: 221 предложение, средняя 11,9 слова, коротких 33 %, нарушений 0. После: 250 предложений, средняя 12,3, коротких 33 %, нарушений 0 (одно 26-словное предложение, внесённое правкой, разделено). Строки кода ≤100 символов (проверено по символам). Блоки §3 по порядку, эмодзи/«Проверено»/вопросов собеседования нет, после каждого `##` есть фраза.

## Подтверждено (источник)

- preStop sleep GA 1.34; zero sleep beta 1.33 / GA 1.34 — kubernetes/kubernetes release-1.36 pkg/features/kube_features.go.
- ContainerStopSignals alpha 1.33, off в 1.36 и master — тот же файл; spec.os.name — website pod-lifecycle.md.
- +2 с к просроченному preStop; preStop входит в grace; FailedPreStopHook; sleep/httpGet хуки выполняет kubelet — pod-lifecycle.md, container-lifecycle-hooks.md.
- httpGet 200–399; grpc SERVING, порт числом; 10 КиБ; редиректы; probe-level terminationGracePeriodSeconds отклоняется для readiness; дефолты 0/10/1/3/1; exec-проба нагружает CPU — website probes.md, configure-liveness-readiness-startup-probes.md.
- prober_probe_total (BETA), /metrics/probes — prober_manager.go, server.go release-1.36.
- Воркер, случайный сдвиг после рестарта, manual trigger, остановка liveness/startup при deletionTimestamp, onHold — pkg/kubelet/prober/worker.go release-1.36.
- Поле host в пробах и хуках запрещено профилем Baseline с v1.34 — website pod-security-standards.md (таблица Baseline, «Host Probes / Lifecycle Hooks (v1.34+)»).
- ExecProbeTimeout GA locked 1.35; GRPCContainerProbeTLS alpha 1.37 — kube_features.go.
- Terminating endpoints всегда ready=false, serving отражает readiness — pod-lifecycle.md.
- Readiness gates — pod-lifecycle.md.
- Реальные числа работ 1–3 и сводка работы 4 — старая версия e755ced.

## Не подтверждено (для 00-plan §7)

- Работа 1, шаги 1–2 и работа 4, шаги 1–2: сообщения kubectl (apply/rollout status) — стандартные, не из прогона.
- Базовая строка клиента: хвост `error_window=0s` достроен по коду клиента.
- Работа 2, шаг 3: формат строки «… deleted in N s» — нового скрипта; числа 2,1/30,8 с из прогона (мс).
- Работа 2, шаг 4 целиком: наличие pause:3.10 на узлах kind 0.32 / k8s 1.36, время удаления, точный текст FailedPreStopHook от containerd 2.3.
- Работа 4 целиком: сырой вывод `kubectl get pods`, манифест PostgreSQL на emptyDir написан заново (не прогонялся).
- Объяснение `TimeoutError` в варианте A — предположение, помечено в тексте.
- Новый load.py (переписан, не прогонялся; логика сверена с форматом старых строк).
