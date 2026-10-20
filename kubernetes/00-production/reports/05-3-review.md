# Ревью 05-3 «Планировщик»

Файл: /home/user/claude/kubernetes/05-resources-scheduling/05-3-scheduler.md. Источники: kubernetes/kubernetes release-1.36 (pkg/features/kube_features.go, pkg/scheduler/framework/plugins/podtopologyspread/{common,filtering}.go, pkg/scheduler/schedule_one.go, pkg/scheduler/apis/config/v1/defaults.go, pkg/scheduler/backend/queue/scheduling_queue.go, pkg/scheduler/metrics/metrics.go, pkg/apis/scheduling/types.go, плагины nodeaffinity/volumebinding/noderesources/interpodaffinity, cli-runtime printers/tableprinter.go); kubernetes/website main (feature-gates DRAExtendedResource, DRADeviceTaints, GangScheduling; pod-scheduling-readiness.md). Режим «только текст»: ничего не запускалось.

## Найденные ошибки (было → стало)

1. Подготовка меняла контекст: `kubectl config set-context --current --namespace=lab-05-3` (запрещено brief-writer) → функция `k() { kubectl -n lab-05-3 "$@"; }`; все команды namespace в работах переведены на `k`, `where`/`mkd` вызывают `k`; уборка работы 5 — `unset -f k where mkd` вместо возврата namespace в `default`; из вывода подготовки убрано `Context "kind-lab" modified.`.
2. Вводный абзац лаб: «Работы 1, 3 и 5 меняют узлы… кроме текущего namespace в ~/.kube/config» → «Работы 1 и 3 меняют узлы, работа 4 создаёт объекты уровня кластера»; хост и контекст не меняются.
3. Работа 1 шаг 1: заголовок колонки `LAB-05-3/ZONE` → `ZONE` (kubectl `formatLabelHeaders` берёт часть ключа после последнего `/` и переводит в верхний регистр); разбор исправлен.
4. Таблица §5: «had volume node affinity conflict» → «didn't match PersistentVolume's node affinity» (ErrReasonNodeConflict в volumebinding/binder.go, 1.36).
5. §6: «Групповое планирование… пока в beta» → в 1.36 alpha и выключено (GangScheduling alpha 1.35–1.36), в 1.37 beta.
6. Работа 4 шаг 2: блок «результата» был конспектом старого скрипта («critical Ready after 1s…», «Pending — 3 Insufficient cpu…») → шаг разделён на две команды с реальными строками старого прогона: узел `critical` (lab-worker3), событие Preempted; затем `get pods` и событие FailedScheduling Pending-замены (фрагмент `3 Insufficient cpu … 1 No preemption victims found for incoming pod` из старой части). Замер «за 1 секунду» убран из разбора и «Итога» (команда его не показывает).
7. Работа 2 шаг 2: `custom-columns` печатал бы заголовок, которого нет в выводе → добавлен `--no-headers`, добавлена таблица разбора команды, указано, что сообщение `rollout status` о таймауте опущено.
8. Механизм зависшего rollout (§5): добавлена формула плагина PodTopologySpread (перекос = подов в домене + сам под − глобальный минимум; домены — все узлы с меткой `topologyKey`, прошедшие nodeAffinityPolicy/nodeTaintsPolicy, включая пустые) и следствие «без пустого домена минимум 1, surge-под встал бы»; «зависает» → «может зависнуть». В «Узел с taint'ом остаётся доменом» добавлено, что поды в состоянии удаления не считаются (`DeletionTimestamp != nil` в common.go). Ответ на вопрос 1 работы 2 дополнен пустым доменом control-plane.
9. §6: уточнено, что DeviceTaintRule в 1.36 beta выключен (DRADeviceTaintRules default false); в §2 у extended resource и device taints добавлено «в 1.36 beta».
10. `percentageOfNodesToScore`: уточнена формула (50 % − узлы/125, не ниже 5 %, не меньше 100 узлов; меньше 100 узлов — все).
11. По исследованиям добавлено: стратегия оценки NodeResourcesFit `LeastAllocated` по умолчанию и `MostAllocated` (bin packing) — фраза в §2; операторы `Gt`/`Lt` для toleration (TaintTolerationComparisonOperators, alpha 1.35, выключены в 1.36) — фраза в §3.
12. Работа 4 «Что понадобится»: добавлено требование 12 CPU хоста и замена запроса при другом числе CPU.
13. Мелочи: «ждать запуска под» → «пода»; Работа 3 шаг 2 — «сокращён до имени и статуса»; фраза «в работе 2 проверены» → «работа 2 воспроизводит».

## Читаемость

До: 266 предложений, средняя 11,8 слова, 36 % короче 10 слов, нарушений 0. После правок фактов появились 2 предложения >25 слов (percentageOfNodesToScore, gang scheduling) — разделены. После: 283 предложения, средняя 11,9 слова, 35 % короче 10 слов, >25 слов — 0, нарушений 0, жирный 2,4 %. Строки кода ≤100 символов.

## Подтверждено (источник)

- Зависание rollout: `calPreFilterState` добавляет в TpValueToMatchNum все допущенные узлы (в т.ч. с 0 подов); `nodeTaintsPolicy: Honor` исключает узлы с непереносимым NoSchedule/NoExecute; skew = matchNum + selfMatchNum − minMatchNum (filtering.go). На стенде: 1/1/1 + control-plane 0 → перекос 2 → Pending; с Honor минимум 1 → встаёт. Расклады работы 5 (sp-ignore 1/1/1 + Pending, sp-honor 2/1/1) логически следуют из этого алгоритма; zspread без метки зоны у control-plane — узел не домен (nodeLabelsMatchSpreadConstraints).
- Стадии 1.36: MatchLabelKeysInPodTopologySpread beta с 1.27 (on); SchedulerAsyncPreemption alpha 1.32, beta on 1.33; SchedulerQueueingHints GA locked 1.34; NodeInclusionPolicyInPodTopologySpread и MatchLabelKeysInPodAffinity GA 1.33; PodSchedulingReadiness GA 1.30; DynamicResourceAllocation GA 1.34, locked 1.35; DRAPrioritizedList, DRAAdminAccess GA 1.36; DRAExtendedResource, DRADeviceTaints beta on 1.36 (GA 1.37 по website); DRADeviceTaintRules beta off 1.36; GangScheduling alpha off.
- Очередь: podInitialBackoffSeconds 1, podMaxBackoffSeconds 10, DefaultPodMaxInUnschedulablePodsDuration 5 мин.
- percentageOfNodesToScore: minFeasibleNodesToFind 100, minFeasibleNodesPercentageToFind 5, адаптивно 50 − n/125.
- HighestUserDefinablePriority 1000000000; SystemCriticalPriority 2000000000.
- Метрики: `scheduler_pending_pods{queue=active|backoff|unschedulable|gated}` (STABLE), `scheduler_schedule_attempts_total{result,profile}` (STABLE).
- Тексты: «didn't match Pod's node affinity/selector», «didn't match pod anti-affinity rules», «Too many pods» — исходники 1.36; Insufficient cpu, untolerated taint, topology spread, No preemption victims — старая часть.
- SchedulingGated в STATUS и снятие шлюзов (только удаление) — pod-scheduling-readiness.md.
- Разделы «Риски» в работах 1, 3, 4 стоят первыми после схемы опыта, уборка снимает метки, taint'ы, классы, namespace, каталог и функции; `pkill`, `apt autoremove` нет.

## Осталось неподтверждённым (для 00-plan)

- Работа 5 целиком: SchedulingGated и пустые события, снятие шлюза `kubectl patch … remove /spec/schedulingGates`, расклады sp-ignore/sp-honor, `No resources found` для deviceclasses/resourceslices.
- Работа 2: объяснение зависания пустым доменом control-plane выведено из алгоритма PodTopologySpread, прогоном с Honor не подтверждено.
- Работа 3 шаг 4: строки `node/lab-worker3 untainted` и формат колонки TAINTS `[map[…]]` — типовой формат kubectl, не из прогона.
- Работа 4 шаг 1: значение PRIO 100 в выводе выведено из класса; шаг 2 — заголовки/колонки `get pod -o wide` и `get pods` сокращены, строки собраны из старого прогона.
- Работа 1 шаг 1: заголовок `ZONE` — по исходнику kubectl, не из прогона.
- Порт метрик 10259 — значение по умолчанию kube-scheduler (по памяти ревьюера, не сверено с исходником в этом ревью).
- Отличие от плана 00-plan §4: пять работ вместо трёх (1 anti-affinity и spread, 2 зависший rollout, 3 taints, 4 вытеснение, 5 шлюз/Honor/DRA) — записать в 00-plan §6.
