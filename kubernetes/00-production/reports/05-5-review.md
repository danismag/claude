# Ревью 05-5 «Прерывания и вытеснение»

Файл: /home/user/claude/kubernetes/05-resources-scheduling/05-5-disruptions-eviction.md. Старая версия: e755ced:kubernetes/05-resources-scheduling/05-4-disruptions-eviction.md.

## Найденные ошибки (было → стало)

1. §2 сигналы: «Сигналов шесть» → шесть основных + `containerfs.available`/`containerfs.inodesFree` только при разделённой ФС образов (KubeletSeparateDiskGC, пока только CRI-O); «каждые 10 секунд» уточнено как `housekeeping-interval`, по умолчанию 10 с.
2. §2 жёсткие пороги по умолчанию: не хватало `imagefs.inodesFree` 5% → добавлено (в тексте и таблице §6); добавлено `evictionMinimumReclaim` = 0 по умолчанию.
3. §2 мягкий порог: «время не больше evictionMaxPodGracePeriod» → меньшее из grace пода и максимума; без максимума kubelet убивает под сразу (документация node-pressure-eviction).
4. §2 Eviction API: к Pending/Succeeded/Failed добавлены уже удаляемые поды (canIgnorePDB в pkg/registry/core/pod/storage/eviction.go проверяет и DeletionTimestamp).
5. §2 toleration на memory-pressure: «Admission-плагин добавляет» → «Control plane добавляет» (так в taint-and-toleration.md; плагин документация не называет); добавлено, что подам DaemonSet контроллер добавляет tolerations на все три давления.
6. §3 graceful shutdown: «при 0s поды умирают без SIGTERM» → kubelet не участвует в остановке, preStop и grace period не соблюдаются (SIGTERM процессам шлёт сама система при выключении). Добавлена фраза про `InhibitDelayMaxSec` logind и ограничение 30 с от unattended-upgrades в Ubuntu (node-shutdown.md). То же исправлено в §6 «Особенности kind».
7. §6 kind: добавлена фраза про поле `mergeDefaultEvictionSettings: true` (сохраняет умолчания незаданных порогов; kind его не задаёт).
8. §6 таблица значений по умолчанию: была таблица из двух столбцов «понятие → значение» (запрещено §3.1) → три столбца с «Где задаётся»; добавлены `imagefs.inodesFree`, `evictionMinimumReclaim`, `evictionMaxPodGracePeriod`, порог GC 12 500.
9. Лаба 1, шаг 2: выдуманная строка `error: unable to drain node "lab-worker", aborting command...` — такого формата в kubectl нет (реальный: `error: unable to drain node %q due to error: %s, continuing command...` + `There are pending nodes to be drained:`) → строка заменена на `…`, подпись «служебные строки между первой и третьей опущены»; в строке DaemonSet оставлен реальный префикс `kube-system/kindnet-…`. Строка `node/lab-worker cordoned` верна (RunCordonOrUncordon до отбора подов).
10. Лаба 1, шаги 3 и 4: подписи вывода уточнены («оставлены две значимые строки», «строки сокращены»), так как реальный вывод drain содержит ещё `already cordoned`, предупреждения и итоговую ошибку.
11. Лаба 3, функция `mkp`: в YAML не было `restartPolicy` (у Pod по умолчанию Always), а старый проверенный вариант через `kubectl run --restart=Never` давал Never → добавлено `restartPolicy: Never` и строка в таблицу разбора. Остальное bash/YAML корректно: heredoc без кавычек подставляет `$1 $2 $3 $W`, закрывающий `YAML` с нулевой колонки, flow-mapping `resources: {…}` и `{}` валидны, `b'x'` внутри YAML-строки в двойных кавычках допустимо.
12. Лаба 3, «Риски»: «привилегированных контейнеров нет» вводило в заблуждение (контейнер-узел kind привилегированный, `docker exec` даёт root узла) → переписано; откат дан точными командами `docker exec lab-worker3 cp … && systemctl restart kubelet` и сказано, где лежит копия.
13. Лаба 3, шаг 2: подпись ожидаемого вывода configz уточнена (ключи по алфавиту; нулевые пороги kind видны в выводе уборки). Команда `sed` проверена разбором кавычек: `\$` в двойных кавычках → `$` (якорь конца строки), `\n` доходит до GNU sed как перевод строки, `$TH` подставляется на хосте — эквивалентно старому проверенному `sh -c`.

## Читаемость

- До: 270 предложений, средняя 11,5 слов, короче 10 слов 36 %, >25 слов 0, нарушений 0.
- После: 278 предложений, средняя 11,6 слов, короче 10 слов 36 %, >25 слов 0, нарушений 0 (по ходу правок возникали: абзац из 6 предложений, предложение 27 слов, код в ячейках новой таблицы, строка 104 знака — исправлены).

## Подтверждено (источник)

- Eviction API: 429 при нарушении бюджета (текст «Cannot evict pod as it would violate the pod's disruption budget.»), 500 при нескольких PDB («This pod has more than one PodDisruptionBudget…»), успех 200 по документации, 201 — реальный вывод старой лабы; Pending/терминальные/удаляемые поды без проверки PDB — api-eviction.md, eviction.go.
- unhealthyPodEvictionPolicy: умолчание IfHealthyBudget (`currentHealthy >= desiredHealthy && desiredHealthy > 0`), AlwaysAllow выселяет неготовые без декремента — configure-pdb.md, eviction.go; GA 1.31 — research-k8s-changes (R31, KEP-3017).
- Проценты PDB округляются вверх (и для minAvailable, и для maxUnavailable); у произвольных контроллеров только целое minAvailable; `{}` выбирает все поды — configure-pdb.md; null — ни одного — API reference policy/v1 (по памяти, согласуется).
- Здоровый под = Ready=True — configure-pdb.md.
- drain: EvictErrorRetryDelay 5 с, `--timeout` 0 = бесконечно, формат «will retry after %v», «global timeout reached», `--disable-eviction` обходит PDB, `--grace-period`, `--pod-selector` — kubectl pkg/cmd/drain/drain.go и pkg/drain/drain.go.
- Пороги и сигналы, housekeeping 10 с, evictionPressureTransitionPeriod 5m, порядок выселения (превышение request → приоритет → размер превышения), освобождение диска до выселения, обнуление незаданных порогов, MergeDefaultEvictionSettings — node-pressure-eviction.md.
- Toleration memory-pressure для не-BestEffort, tolerations DaemonSet — taint-and-toleration.md.
- Graceful shutdown: умолчания 0, разбивка 30 с/20+10, ByPodPriority, unattended-upgrades 30 с, out-of-service taint — node-shutdown.md.
- Проба /nope у orders-api:2.0 → 404: код приложения в 00-1 (ветка else в do_GET → `_send(404, …)`; без DATABASE_URL приложение стартует и /ready даёт 200, порт 8000).
- Числа лаб (15473/14900Mi, allocatable 1057648Ki, 9 повторов, 2 с, 201, besteffort Evicted 209476Ki) — реальный вывод старой части.

## Не подтверждено (для 00-plan)

- Стадия stable 1.36 для PSI-метрик kubelet — только research (KEP-4205), документацию не открывал.
- Влияние swap на memory.available («сигнал падает позже») — рассуждение, в документации нет.
- Метрики `kubelet_evictions` и `kube_poddisruptionbudget_status_pod_disruptions_allowed` — по памяти.
- Аннотации `cluster-autoscaler.kubernetes.io/safe-to-evict: "false"` и `karpenter.sh/do-not-disrupt: "true"` — по памяти.
- Порог terminated-pod-gc-threshold 12 500 — по памяти (флаг kube-controller-manager).
- Out-of-service taint stable 1.28 — версия в node-shutdown.md не указана, по памяти/research.
- Лаба 1: точная последовательность служебных строк drain и строка «200 after 2s» (собрана из «2 с» старой части) — не прогонялись.
- Лаба 2: вывод `kubectl get pdb sick` (шаг 1) — ожидаемый.
- Лаба 3: YAML-вариант `mkp` (с `restartPolicy: Never`), вывод configz и `condition met` шага 2 — не прогонялись.
