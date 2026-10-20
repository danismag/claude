# Ревью 05-2 «Ресурсы пода и квоты»

Файл: /home/user/claude/kubernetes/05-resources-scheduling/05-2-pod-resources-quotas.md
Источники (скачаны в scratchpad rv052/): kube_features.go (release-1.36), CHANGELOG-1.36/1.37, KEP-2837 README, website main: resize-container-resources, resize-pod-resources, assign-pod-level-resources, resource-quotas, limit-range, node-pressure-eviction, pod-overhead, manage-resources-containers, swap-memory-management; kubernetes/api core/v1 types.go.

## Найденные ошибки (было → стало)

- §3 resize, тип контейнера: «обычные init-контейнеры не меняются; в 1.37 GA» → в 1.36 работающий обычный init-контейнер меняется (гейт InPlacePodVerticalScalingInitContainers, beta, вкл. с 1.36; только NotRequired, CHANGELOG-1.36 #137352, #137458), в 1.37 GA. То же добавлено в §6.
- Дублирование 05-1 (§6 AGENTS.md): подразделы «Планирование идёт по requests» и «Overcommit» повторно вводили allocatable и overcommit (уже определены жирным в 05-1 §2); §4 «Занятость узла и overcommit» повторял 05-1 §4; §5 «Под Pending, хотя узел почти пуст» повторял 05-1 §5; лаба 3 шаг 1 (big/greedy) — та же работа с тем же выводом, что в 05-1 лаб. 1. → заменено ссылками на 05-1 и новой механикой: «Из чего складывается запрос пода» (pod-level requests вместо суммы, overhead RuntimeClass, схема 2); §4 «Ресурсы пода, overhead и QoS-класс»; §5 «Ресурсы пода: отказ API или OOM соседа»; шаг 1 лабы 3 удалён, шаги перенумерованы, лаба переименована по плану («Квота, LimitRange и ephemeral storage»), цель/схема/итог/вопрос 1 обновлены.
- Лаба 3, вывод `get resourcequota`: писатель разбил реальную строку на две выдуманные таблицы «NAME REQUEST / NAME LIMIT» → реальный заголовок и строка (REQUEST и LIMIT), колонка AGE опущена с пометкой.
- QoS при spec.resources: уточнено по KEP-2837 — Guaranteed только если для CPU и памяти запрос пода равен лимиту; если в spec.resources для ресурса нет запроса или лимита — Burstable, даже при равенстве у контейнеров.
- Добавлены правила валидации уровней (KEP-2837, resize-pod-resources): сумма запросов контейнеров ≤ запроса пода; лимит контейнера ≤ лимита пода, сумма лимитов может превышать; умолчание запроса пода; неявный лимит контейнера = лимит пода в cgroup (не в spec).
- Добавлен подраздел «Общий лимит памяти и OOM» (схема 4): cgroup OOM по сумме — при превышении лимита пода (KEP-2837 «cgroup OOM Kill»); жертва — контейнер (memory.oom.group на cgroup контейнера), под остаётся.
- Pod-level resize: добавлено — у пода нет своей resizePolicy, cgroup пода меняется без перезапуска; контейнер без своего лимита перезапустится, если его resizePolicy RestartContainer; те же проверки уровней; зависимость от NodeDeclaredFeatures (beta, вкл. 1.36).
- Порядок отложенных resize уточнён: PriorityClass → Guaranteed раньше Burstable → давность; отложенный высокоприоритетный не блокирует остальные. Infeasible сохраняется для прочих невыполнимых случаев (в 1.36 сверх allocatable — отказ на admission, CHANGELOG-1.36 #136043).
- Квота: «обязаны указать эти ресурсы» → «запрос или лимит»; терминальные поды — «нетерминальная фаза» по документации; overhead учитывается квотой; задержка — только при освобождении (контроллер квот), а не при создании; операторы scopeSelector: In/NotIn ≥1 значение, Exists/DoesNotExist без values, Exists — единственный для Terminating/NotTerminating/BestEffort/NotBestEffort (раньше было только про BestEffort и «In для PriorityClass»).
- LimitRange: «ниже запроса пода» → «ниже запроса, указанного в контейнере» (по документации).
- Пороги hard eviction: добавлен `imagefs.inodesFree<5%`; добавлен housekeeping-interval 10 с.
- «Максимум подов на узел в kind — 110» → умолчание kubelet maxPods=110, квота pods — по namespace.
- Добавлено в §6: PodLevelResourceManagers alpha 1.36 (менеджеры CPU/Memory/Topology не учитывают ресурсы пода без гейта); для расширенных ресурсов в квоте — только `requests.`.
- Лаба 3: добавлена таблица разбора для команды `run huge`; вопрос 1 заменён (LimitRanger стоит в admission раньше ResourceQuota).

## Читаемость

До: средняя 11,8 слова, коротких 36 %, нарушений 2 (абзац из 6 предложений, стр. 7; предложение 29 слов, «Дальше»).
После: средняя 12,1 слова, коротких 32 %, предложений >25 слов — 0, нарушений 0. Строк кода >100 знаков нет. В §2 после слияния подраздела — 5 подразделов `###`. Теория без кода и таблиц ~3,6 тыс. слов (было ~3,1).

## Подтверждено (источник)

- PodLevelResources: alpha 1.32, beta on 1.34 (kube_features.go release-1.36).
- InPlacePodLevelResourcesVerticalScaling: alpha 1.35, beta on 1.36; зависит от InPlacePodVerticalScaling, PodLevelResources, NodeDeclaredFeatures (beta on 1.36) (kube_features.go; CHANGELOG-1.36 #137684). Документация main всё ещё пишет alpha — оговорка в тексте оставлена.
- InPlacePodVerticalScaling: alpha 1.27, beta 1.33, GA 1.35 locked (kube_features.go).
- NodeSwap GA 1.34 locked; PodObservedGenerationTracking GA 1.35 (kube_features.go).
- Условия PodResizePending (Deferred/Infeasible), PodResizeInProgress (reason Error), max из трёх запросов для scheduler, kubectl ≥1.32, restartPolicy Never → только NotRequired, ограничения (QoS, sidecar, static CPU/Memory Manager, удаление, swap) — resize-container-resources.md.
- Сверх allocatable — отказ на admission с 1.36 (CHANGELOG-1.36 #136043).
- Ресурсы пода: CPU/память/hugepages, без Windows; QoS по уровню пода; scheduler берёт только pod-level requests; overhead добавляется к pod-level requests и в cgroup — assign-pod-level-resources.md, KEP-2837.
- LimitRange: типы Container/Pod/PersistentVolumeClaim, поля default/defaultRequest/min/max/maxLimitRequestRatio (core/v1 types.go); 403, недетерминизм при нескольких LimitRange, без проверки согласованности (limit-range.md).
- ResourceQuota: области Terminating/NotTerminating/BestEffort/NotBestEffort/PriorityClass/CrossNamespacePodAffinity/VolumeAttributesClass (types.go, resource-quotas.md); extended resources только `requests.`; нетерминальные поды; ephemeral-storage без полей не учитывается.
- Overhead RuntimeClass: admission копирует в spec.overhead, учитывается scheduler, квотой и cgroup (pod-overhead.md).
- Hard eviction по умолчанию: memory.available<100Mi, nodefs.available<10%, imagefs.available<15%, nodefs.inodesFree<5%, imagefs.inodesFree<5%; housekeeping 10s (node-pressure-eviction.md).
- Swap: NoSwap по умолчанию, failSwapOn, LimitedSwap только Burstable, высокий приоритет без swap, opt-out request=limit, noswap с 6.3, метрики и `--show-swap`, nodeInfo.swap.capacity (swap-memory-management.md).
- Учёт ephemeral: слой записи, /var/log/pods, emptyDir, /etc/hosts (manage-resources-containers.md).
- Реальный вывод лаб 1 и 3 сверен со старой 05-1 (e755ced).

## Не подтверждено (для 00-plan §7)

- Лаба 1 шаг 1: вывод `20000 100000` команды `kubectl exec … cat cpu.max` взят из чтения cgroup контейнера с узла в старой части; эта команда не запускалась.
- Лаба 2 целиком ожидаемая: qosClass Burstable, формат `.spec.resources`, memory.max 104857600 у a, OOMKilled у b, число перезапусков, приём resize пода до 400Mi.
- Выбор жертвы при OOM по лимиту пода (весь контейнер через memory.oom.group, под остаётся) — вывод из KEP-2837 и поведения cgroup v2, на стенде не проверялся.
- Правило «если в spec.resources нет запроса или лимита ресурса — не Guaranteed» — по KEP-2837 (раздел QoS Changes); в документации задач нет.
- Задержка освобождения квоты контроллером после удаления — по устройству контроллера, без числа.
- Порядок admission (LimitRanger раньше ResourceQuota) в ответе на вопрос 1 лабы 3 — по рекомендуемому порядку плагинов, на стенде не проверялся отдельно.
- Строка `Total limits may be over 100 percent, i.e., overcommitted` теперь только в 05-1; в 05-2 не используется.
- Таймаут выселения по ephemeral-storage 20–25 с — замер старой части, зависит от housekeeping.
