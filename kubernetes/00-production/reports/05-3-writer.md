# Отчёт писателя 05-3 «Планировщик»

Файл: /home/user/claude/kubernetes/05-resources-scheduling/05-3-scheduler.md (старая 05-2, переписана поверх).
Читаемость: 266 предложений, средняя 11,8 слова, >25 слов: 0, нарушений 0; 36 % короче 10 слов; жирный 2,5 %.
Объём прозы (без кода, вывода и таблиц): теория ~2900 слов, проза лабораторных ~2500. Теория ниже ориентира 3,5–4,5 тыс.: механизмы помещаются, DRA дан компактно (схема, два манифеста, статусы функций в таблице §6).
Режим «только текст» соблюдён: на машине ничего не запускалось; читались файлы репозитория и документация kubernetes (raw.githubusercontent.com, feature-gates/*.md, concepts/resource-management/dynamic-resource-allocation/*, device-taints.md, pod-scheduling-readiness.md, topology-spread-constraints.md, scheduling-framework.md).

## Заголовки
## Где мы на карте
## 1 Какую задачу решает планировщик: Выбор узла для пода; Что планировщик знает и чего не знает; Решение принимается один раз
## 2 Как устроен планировщик: Два цикла и три очереди; Фильтры и оценка; Повторные попытки и подсказки QueueingHints; Scheduling gates; Устройства: Dynamic Resource Allocation
## 3 Как управлять размещением: Куда можно (nodeSelector, node affinity); Рядом и врозь (pod affinity); Равномерно (topologySpreadConstraints, minDomains, nodeAffinityPolicy, nodeTaintsPolicy); Запреты (taints); Важнее других (PriorityClass, вытеснение)
## 4 Как увидеть решение планировщика: События и условия пода; Узлы и приоритеты; Метрики и журнал
## 5 Что ломается и как найти причину: Читаем событие FailedScheduling; Spread вешает rollout; Узел с taint'ом остаётся доменом; Вытеснение и каскады
## 6 Пределы и значения по умолчанию: Числа; Статус функций; Чего планировщик не делает
## Лабораторные работы (подготовка с функциями where и mkd)
### Работа 1 Anti-affinity и spread по зонам (Риски: метки узлов) — шаги 1–4
### Работа 2 Spread и зависший rollout — шаги 1–3
### Работа 3 Taints и tolerations (Риски: taint и NoExecute на lab-worker3) — шаги 1–4
### Работа 4 Приоритеты и вытеснение (Риски: PriorityClass, 10 CPU) — шаги 1–2
### Работа 5 Scheduling gate, nodeTaintsPolicy и DRA без устройств — шаги 1–4, целиком ожидаемая, начинается фразой «Эту работу вы выполняете сами…»
## → Дальше

Отличие от плана 00-plan §4: работ пять вместо трёх (старая лаба разделена: «Anti-affinity и spread» → 1 и 2; добавлена 5 — шлюз, Honor, проверка DRA). Это надо записать в 00-plan §6.

## Правило имён
Метки и taint'ы: `lab-05-3/zone`, `lab-05-3/dedicated`; PriorityClass: `lab-05-3-low`, `lab-05-3-high` (cluster-scoped, поэтому дефис, а не слэш); gate: `lab-05-3/hold`; манифесты в `~/lab/k8s/05-3/`; namespace `lab-05-3`. Стандартные метки топологии не трогаются (старая лаба ставила `topology.kubernetes.io/zone`).

## Реальный вывод из старой части (прогон 2026-10-14)
Взят без изменений по смыслу: расклады `where` (plain 3/2/1, anti 1/1/1+Pending, zspread 3/2/1 по узлам), событие FailedScheduling с anti-affinity, hs-plain (surge Pending, имена подов) и hs-mlk, поведение NoSchedule/NoExecute/tolerationSeconds, Preempted и Pending у batch. Ключи в манифестах заменены на `lab-05-3/...` (на вывод не влияет). Выводы вставлены в сокращённом виде («(сокращён)» и «…»), как в старой части.

## СОМНИТЕЛЬНЫЕ места
1. Работа 5 целиком без реального вывода: `SchedulingGated`, `No resources found` для deviceclasses/resourceslices, расклады sp-ignore (1/1/1 + Pending) и sp-honor (2/1/1).
2. Объяснение зависания rollout (§5 «Spread вешает rollout», схема 4, работа 2 шаг 2): в старой части причина дана как «surge-под считается со старыми»; я добавил, что control-plane остаётся доменом с 0 подов при `nodeTaintsPolicy: Ignore` (минимум 0, перекос 2). Это вывод из правил расчёта, не из прогона. Следствие, что `Honor` тоже лечит ловушку (минимум 1), не проверялось (проверяется только в работе 5, ожидаемо). Если ревьюер знает иной механизм, править §5, схему 4 и разбор работы 2.
3. Текст события при зависшем rollout: в работе 2 дан как `0/4 nodes are available: … 3 node(s) didn't match pod topology spread constraints. …` — только фрагмент из старой 03-2, начало и конец заменены на «…».
4. Работа 4 шаг 1: строка вывода `batch-55c5fc9bfc-drfgg lab-worker3 100` — имя и узел из старого прогона, значение 100 следует из класса, колонки PRIO в старом прогоне не печатали.
5. Работа 4 шаг 2: три строки результата — это конспект старой части (не дословный вывод команд); строка «critical Ready after 1s on lab-worker3» измерена старым скриптом, а не выводом `kubectl wait`.
6. Работа 3 шаг 4: вывод `kubectl taint ... untainted` и формат колонки TAINTS (`[map[effect:NoSchedule key:...]]`) — типичный формат, в старой части не показан.
7. Работа 1 шаг 1: заголовок колонки `LAB-05-3/ZONE` для `kubectl get nodes -L` (kubectl делает заголовок из ключа верхним регистром — по памяти).
8. Образ `registry.k8s.io/pause:3.10` «уже на узлах» (в kind это образ песочницы) — в метке-строке не утверждается напрямую, но подразумевается; в старой части лаба шла без проблем.
9. Числа без прогона: пауза очереди отсрочки 1–10 с и возврат неподходящего пода не позже 5 минут (podInitialBackoffSeconds=1, podMaxBackoffSeconds=10, podMaxInUnschedulablePodsDuration=5m — по памяти, не проверено по документации); `percentageOfNodesToScore` (меньше 100 узлов — все, потолок снижения 5 %) — по памяти; maxPods 110; верхняя граница пользовательских приоритетов 1000000000 — по памяти.
10. Метрики `scheduler_pending_pods{queue=active|backoff|unschedulable|gated}` (gated подтверждён документацией scheduling readiness, остальные значения label — по памяти), `scheduler_schedule_attempts_total` (по памяти), порт метрик 10259.
11. Тексты событий в таблице §5 для volume node affinity conflict, Too many pods, node affinity/selector — по исходникам по памяти. Подтверждены старой частью: Insufficient cpu, untolerated taint, anti-affinity, topology spread, No preemption victims.
12. Асинхронное вытеснение: по файлу feature gate SchedulerAsyncPreemption — beta, включено с 1.33; в research-k8s-changes.md строка 76 говорит «alpha» (в списке 1.32), строка 329 — «beta 1.33 / alpha 1.34»; я взял файл гейта.
13. `matchLabelKeys` в topologySpread — по файлу гейта MatchLabelKeysInPodTopologySpread всё ещё beta (включена с 1.27), а не GA; research-k8s-changes.md (строка 328) объединяет его с GA-функциями 1.33 — это расхождение, в тексте указано beta. В affinity — GA 1.33 (подтверждено гейтом).
14. Статусы DRA в таблице §6: core GA 1.34 и locked 1.35, prioritized list и admin access GA 1.36, extended resource GA 1.37 (beta 1.36), device taints GA 1.37 (DRADeviceTaints beta 1.36, DeviceTaintRule v1 — GA 1.37, beta 1.36 выключен по умолчанию) — по файлам feature-gates из kubernetes/website main (1.37). Формулировка «на стенде 1.36 в beta и включены» верна для extended resource и DRADeviceTaints, но DRADeviceTaintRules в 1.36 beta и выключен — в тексте не детализировано.
15. Манифест DRA: ResourceClaimTemplate с `exactly` и `deviceClassName: example-device-class` — взят из примера документации (`examples/dra/resourceclaimtemplate.yaml`) и сокращён до одного CEL-условия. Фраза «по умолчанию число устройств равно 1» про `exactly` — по памяти (в документации примера нет `count`).
16. Лимит «ограничение: scheduler не вытесняет поды ради DRA-устройств» — документация DRA (раздел Limitations, версия main).
17. «Групповое планирование в beta» — по research-k8s-changes.md (gang scheduling KEP-4671 beta в 1.37); для стенда 1.36 — alpha/недоступно, в тексте сказано обобщённо.
18. `kubectl patch ... remove /spec/schedulingGates` (работа 5) — снимает поле целиком; в документации снятие описано повторным apply без поля.

## Что выкинуто или перенесено в модуль 12
Кейс из прода:
- «Три реплики на одном узле — узел упал, сервис лёг»: нет правил размещения, массовый drain сложил поды на один узел, PDB не было; фикс — spread зона DoNotSchedule + узел ScheduleAnyway с matchLabelKeys, PDB minAvailable 2, descheduler RemovePodsViolatingTopologySpreadConstraint, алерт «все реплики на одном узле/в одной зоне» (kube_pod_info + kube_deployment_spec_replicas); отказ узла = ~6 минут недоступности (01-2).
Вопросы с собеседования (8):
- nodeSelector и node affinity; taint и toleration; как разнести реплики по узлам и зонам; taint или affinity для выделенных узлов; Pod Pending — как понять причину; почему после topology spread завис rollout; как работает preemption и чем опасен; почему распределение ухудшается со временем и как исправить.
Подводные камни (9):
- встроенный spread мягкий (3/2/1 норма); required anti-affinity — реплик больше узлов Pending; spread DoNotSchedule без matchLabelKeys вешает rollout; узлы с taint'ом по умолчанию домены (Ignore); toleration не притягивает; NoExecute выселяет сразу; без PriorityClass вытеснение не работает, каскады; schedulerName с опечаткой — Pending без событий; scheduler не видит реальной загрузки.
Чеклист и «Задание со звёздочкой» (устойчивость orders-api к отказу узла и зоны: 4 реплики со spread, PostgreSQL на выделенном узле с taint и affinity, вопрос про PVC local-path при переносе, остановка kubelet на узле zone-b) убраны; идею задания можно взять в 12-2/12-3 (system design: кластер в двух зонах).
Из старого §7 перенесено: несколько scheduler'ов (`schedulerName`, Pending без событий) — одна фраза в §5; scheduling gates — подраздел §2; descheduler — §1 и §6; ресурсы, невидимые scheduler'у, — §1.
Не включено сознательно (вне части): gang scheduling/Kueue — одна фраза в §6; pod overhead, resource bin packing, профили scheduler'а (KubeSchedulerConfiguration) — не разворачивались; workload-aware preemption (alpha); nominatedNodeName и async preemption — по фразе в §3.
