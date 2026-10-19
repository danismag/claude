# Отчёт писателя 05-2

Файл: /home/user/claude/kubernetes/05-resources-scheduling/05-2-pod-resources-quotas.md

## Заголовки
## Где мы на карте; ## 1 Какую задачу решают (Три уровня; Кто проверяет; Что нельзя менять на ходу); ## 2 Как устроены (Планирование по requests; Overcommit; Ресурсы на весь под; Resize: желаемое/принятое/фактическое; Swap); ## 3 Как управлять (Resize: подресурс и resizePolicy [+ограничения, + pod-level resize]; LimitRange; ResourceQuota [+ области]; Диск пода: ephemeral-storage); ## 4 Как увидеть (Resize; Занятость узла и overcommit; Квоты и LimitRange; Диск и swap в метриках); ## 5 Что ломается (Resize не применился; Pending при пустом узле; Квота режет создание; LimitRange; Выселен по диску); ## 6 Пределы (Resize; Ресурсы пода и swap; Квота и LimitRange; Диск); ## Лабораторные работы (1 Resize на месте; 2 Ресурсы на весь под; 3 Requests, квота, LimitRange и ephemeral storage); ## → Дальше.

## Объём и читаемость
Теория (без кода и таблиц) около 3,1 тыс. слов — ниже ориентира, механизмы покрыты. Читаемость: средняя 11,8 слова, >25 слов: 1, нарушений 2 (абзац 6 предложений во вводе «Где мы на карте»; одно предложение в «Дальше», 29 слов).

## Отличия от плана
- Лаба 3 объединяет планирование по requests (старый шаг 6), квоту/LimitRange (шаг 7) и ephemeral (шаг 8) — четыре шага, 3 работы как в плане. Второй namespace lab-05-2q (как в старой части).
- Лаба 2 (pod-level) целиком «Эту работу вы выполняете сами»: в 1.36 гейты по умолчанию включены (PodLevelResources beta on с 1.34; InPlacePodLevelResourcesVerticalScaling beta on с 1.36 — по файлам feature-gates), kind-конфиг не нужен.
- Файл 03-2-sample-lab.md из задания в репозитории не найден; формат лабы взят из 02-1.

## Реальный вывод (из старой части 05-1)
Лаба 1 шаги 2–4 (cpu.max 50000, QOS-ошибка, memory.max 104857600, hold-под), лаба 3 шаги 1–4 целиком. Лаба 2 — ожидаемый.

## Сомнительные места
- Лаба 1 шаг 1: `20000 100000` взят из старого вывода cgroup для cpu 200m (вывод пода-слайса/контейнера из шага троттлинга); команда `cat cpu.max` внутри контейнера в старой части для исходного значения не запускалась. Стартовые limits 200m/128Mi — из старого манифеста.
- Лаба 1 шаг 2: старый вывод получен после patch requests+limits 500m; тот же patch. Порядок шагов 2→3 даёт Guaranteed-отказ только при cpu req=lim=500m — как в старой части.
- Лаба 2 целиком ожидаемая: qosClass Burstable, memory.max 104857600 у a, OOMKilled у b при лимите пода 200Mi, число перезапусков (restarts=1, 2), поведение после resize пода до 400Mi (в т.ч. что OOM убьёт именно контейнер b, а не вызовет иное; oom.group на уровне пода не проверялся). Валидация API для pod-level (сумма requests контейнеров <= запрос пода, лимит контейнера vs лимит пода) не описана в тексте.
- Документация kubernetes.io (main) называет InPlacePodLevelResourcesVerticalScaling alpha, файл feature-gate — beta с 1.36; в тексте стоит beta + оговорка.
- QoS пода при заданном spec.resources («Guaranteed, если запросы и лимиты CPU и памяти пода совпадают») — по KEP-2837 по памяти, документация говорит только «pod-level take precedence».
- Overhead RuntimeClass прибавляется к запросу пода; scheduler берёт pod-level requests вместо суммы контейнеров — по памяти/KEP.
- Порядок отложенных resize (PriorityClass → QoS → давность) и «1.36 — сверх allocatable отклоняется на admission» — по research-k8s-changes.md.
- «В 1.37 resize init-контейнеров GA» — по research.
- Пороги hard eviction по умолчанию (nodefs.available<10%, imagefs.available<15%, nodefs.inodesFree<5%, memory.available<100Mi) — по памяти (документация kubelet).
- Формула LimitedSwap, noswap tmpfs (ядро 6.3), метрики swap, `kubectl top --show-swap` — документация swap-memory-management; «поды с высоким приоритетом не получают swap» — оттуда же; «нужен RestartContainer для памяти при swap» — документация resize.
- Квота: поведение для cpu/memory (обязательно) и ephemeral-storage (поды без полей не учитываются) — пересказ документации; терминальные поды квоту не занимают, задержка обновления квоты — по памяти; для расширенных ресурсов только префикс requests. — по памяти.
- LimitRange: типы Container/Pod/PVC и поля default/defaultRequest/min/max/maxLimitRequestRatio — по памяти (страница документации полей не называет).
- `kubectl get pod -o jsonpath '{.status.qosClass}'` в лабе 2 — ожидаемый вывод.
- observedGeneration упомянут по документации resize (гейт PodObservedGenerationTracking).
- Таймаут «20–25 с» до выселения — из старой части.

## Выброшено/перенесено в модуль 12 (из старой 05-1, не относящееся к 05-2)
Не разбирал QoS/OOM/троттлинг (это 05-1). Кейс «лимиты — p99 в 5 раз» и вопросы собеседования про requests vs limits, подводные камни и чеклист старой части — в модуль 12 (принадлежат 05-1). Из тем 05-2 для модуля 12: вопросы про «Deployment 7/12 из-за квоты», «Pending при пустом узле — requests», «resize и смена QoS», «LimitRange подставил OOM-лимит».
