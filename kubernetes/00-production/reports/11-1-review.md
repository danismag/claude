# Ревью 11-1 «Наблюдаемость кластера»

Файл: /home/user/claude/kubernetes/11-troubleshooting/11-1-cluster-observability.md (новая часть, старой версии нет). Режим «только текст»: исходники release-1.36 и документация скачаны в scratchpad (`src111/`), команды лабораторных не запускались.

## Найденные ошибки (было → стало)

1. Node log query, лаба 4 шаг 4: «либо строки журнала, либо ошибка, если запрос отключён» → при `enableSystemLogQuery: false` kubelet не разбирает `query` и отдаёт HTML-список файлов `/var/log` (kubelet.go release-1.36: режим запроса только при `NodeLogQuery && EnableSystemLogQuery`, иначе `http.FileServer`). В §3 и §6 добавлено: код 1.36 требует оба поля, страница system-logs называет достаточным первое.
2. `eventRecordQPS`: «значение 0 снимает ограничение» → в 1.36 ноль даёт лимит клиента по умолчанию 5/с (client-go rest/config.go DefaultQPS 5), «без лимита» — с 1.37 (CHANGELOG-1.37, #117119).
3. Соответствие полей событий: «в events.k8s.io/v1 им соответствуют series.count и series.lastObservedTime» → поля старого механизма видны как `deprecatedCount`, `deprecatedFirstTimestamp`… (pkg/apis/events/v1/conversion.go). В §2 уточнено: kubelet пишет старым механизмом (`count`, `lastTimestamp`), scheduler — новым (`series.count`).
4. Ключ склейки: «тип, причина, объект, источник» → добавлен текст сообщения (getEventKey в events_cache.go включает Message). Фильтр шума и агрегатор отнесены к старому механизму записи (client-go/tools/record).
5. Ротация, лаба 4 шаг 2: в выводе два несжатых 10M-файла и .gz по 2,4M, порядок не как у `ls` → несжатым остаётся только последний ротированный, остальные (до 3) сжаты; порядок по имени; размеры заменены на `…`. Обоснование: container_log_manager.go (removeExcessLogs оставляет MaxFiles−2, затем compressLog всех несжатых, затем rename с форматом `20060102-150405`). Размер несжатого файла при 1 МиБ/с и проверке раз в 10 с — до 20 МиБ (было «чуть больше 10»); .gz одинаковых строк — килобайты.
6. Объём лога на контейнер: «до 5 файлов по 10 МиБ, около 50 МиБ» → верхняя граница, со сжатием меньше (§6, «Риски», ответ 1 в лабе 4).
7. metrics-server: противоречие «одна последняя точка» (§1) / «последний замер» (§6) / «последняя пара» (§2) → везде «два последних замера».
8. `apiserver_storage_objects`: добавлено, что метрика stable, устарела в 1.34, замена `apiserver_resource_objects` (staging/.../etcd3/metrics/metrics.go); использована как пример устаревания в §2.
9. Ссылка «10-2 §4» про долю событий в etcd → «10-2 §2» (там стоит текст про lease и 402 из 838).
10. Лаба 2 шаг 6: «403, а иногда 401» → 403 (анонимный запрос проходит аутентификацию, отказ даёт авторизация; /healthz, /readyz, /livez в AlwaysAllowPaths — authorization.go).
11. Опечатка «его раз в 15 секунд» → «он раз в 15 секунд».
12. `No events found` → точный текст `No events found in lab-11-1 namespace.` (kubectl events.go).
13. Добавлена фраза 1.37 про `nodes/log` (CHANGELOG-1.37, #139837: kubelet пишет эффективную конфигурацию при старте; в заметке написано «nodes/logs», подресурс в коде — `log`).
14. Лаба 3 шаг 1: добавлено, что kustomize вместе с префиксом меняет `roleRef` и `subjects` (имя и namespace SA) — namereference.go и nameref.go kustomize.
15. Иллюстративные числа заменены на `…` или помечены: лаба 2 шаги 1–5 (199m/0Mi и JSON помечены «иллюстративные», 2315.4, 128.7, 1043, 812, 402, 77, 4.096e+05, 214, 9 → `…`), лаба 3 шаги 2–3 помечены, лаба 4 шаги 1–3 (1432, 1466912, 2200000, 27M → `…`).
16. §6: к 16 КиБ добавлен источник — параметр containerd `max_container_log_line_size = 16384`.

## Читаемость

До: 276 предложений, средняя 11,7 слова, 37 % короче 10 слов, нарушений 0. После: 287 предложений, средняя 11,8, 36 % короче 10 слов, нарушений 0 (один абзац из 6 предложений, появившийся после правок, разделён). Строк кода длиннее 100 символов нет. Эмодзи, «Проверено», вопросов собеседования нет; блоки §3 по порядку; «Риски» есть в лабе 4; уборка полная (кластерные объекты с префиксом lab-11-1-, проверка `grep lab-11-1`), `pkill`/`apt autoremove` нет.

## Подтверждено (источник)

- types.go release-1.36: `enableSystemLogHandler` default true, `enableSystemLogQuery` default false, «EnableSystemLogHandler has to be enabled in addition»; defaults.go: handler true, eventRecordQPS 50, eventBurst 100, containerLogMaxSize 10Mi, containerLogMaxFiles 5, containerLogMaxWorkers 1, containerLogMonitorInterval 10s.
- kube_features.go release-1.36: NodeLogQuery GA 1.36, LockToDefault true (alpha 1.27, beta 1.30).
- kubelet/server/auth.go: путь /logs → подресурс `nodes/log`; /metrics → `nodes/metrics`; /stats → `nodes/stats`; прочее → `nodes/proxy`.
- kubelet_server_journal.go: параметры query, sinceTime, untilTime, boot, tailLines, pattern.
- client-go events_cache.go release-1.36: спам-фильтр 25 / 1 за 300 с, агрегация 10 за 600 с, LRU 4096; events/event_broadcaster.go: finishTime 6 мин, refreshTime 30 мин.
- apiserver options.go: `--event-ttl` 1h.
- kubectl event_printer.go: колонки LAST SEEN TYPE REASON OBJECT MESSAGE, формат «%s (x%d over %s)»; `--for`, `--types`, `--watch`.
- kubectl top: «Metrics API not available», «metrics not available yet», колонки NAME CPU(cores) CPU(%) MEMORY(bytes) MEMORY(%).
- metrics-server README: 15 с, 100m/200MiB до 100 узлов, +1m/2MiB на узел, 0.8.x — 1.31+, только для автомасштабирования, чтение /metrics/resource, `--kubelet-insecure-tls`.
- CHANGELOG-1.37: metrics.k8s.io v1 без изменений, kubectl top с v1; eventRecordQPS 0 = без лимита; nodes/logs.
- system-metrics.md: адреса kubelet /metrics/cadvisor, /metrics/resource, /metrics/probes; stable скрывается через ≥3 релиза или 9 месяцев, beta — 1 релиз или 4 месяца; `--show-hidden-metrics-for-version`; PSI `container_pressure_*`.
- logging.md: kubectl logs отдаёт не больше одного файла (пример 40 МиБ → 10 МиБ).
- kubeadm manifests.go: bind-address 127.0.0.1 для scheduler и controller-manager; constants.go: 10259, 10257.
- kube-state-metrics README: v2.20.0 ↔ client-go v1.36; examples/standard@v2.20.0: namespace kube-system, Service headless с портами http-metrics 8080 и telemetry 8081, образ registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.20.0, runAsNonRoot, runAsUser 65534, readOnlyRootFilesystem, правило с secrets — list, watch; cli-arguments.md: `--resources`, `--metric-labels-allowlist`.
- containerd docs/cri/config.md: max_container_log_line_size = 16384.

## Не подтверждено (для 00-plan §7)

- Все четыре работы — ожидаемый вывод, команды не запускались.
- Лаба 1: точные тексты Failed/BackOff для busybox:1.37-nope и тайминги «(x2 over 18s)»; отсутствие `--event-ttl` в манифесте API-сервера kind.
- Лаба 2: значения top/PodMetrics (window, n, Ki) — форма по памяти; метки времени в /metrics/resource; наличие curl в узле kind; код 403 без токена (по устройству делегированной авторизации).
- Лаба 3: удалённая база kustomize `//examples/standard?ref=v2.20.0` (нужен git) не прогонялась; порядок меток KSM; фаза Running у пода crash в момент замера.
- Лаба 4: скорость генератора ~1 МиБ/с; имена и размеры ротированных файлов на стенде; HTML-список /var/log при выключенном enableSystemLogQuery (по коду, не по прогону); значения enableSystemLogHandler/Query в kind; время удаления каталога логов после удаления пода.
- metrics-server до 0.6 читал Summary API — по памяти.
- Имена метрик kubelet_running_pods, kubelet_pleg_relist_duration_seconds, workqueue_depth, apiserver_flowcontrol_rejected_requests_total, apiserver_client_certificate_expiration_seconds, prober_probe_total — по памяти, в коде не сверялись.
