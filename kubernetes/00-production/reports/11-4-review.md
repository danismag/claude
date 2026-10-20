# Ревью 11-4 «Узел и control plane» (старая 11-3)

Файл: /home/user/claude/kubernetes/11-troubleshooting/11-4-node-control-plane.md. Режим «только текст»: команды не запускались, сверка по документации kubernetes/website, коду kubernetes/kubernetes и client-go, sig-scalability (WebFetch raw).

## Найденные ошибки (было → стало)

1. §6, цели SIG Scalability: «5 с на list в namespace, 30 с по кластеру» → «30 с на list в namespace и по кластеру (раньше для namespace было 5 с)». Источник: community/sig-scalability/slos/api_call_latency.md, сноска о повышении порога с 5 до 30 с.
2. §3, node log query: «включён `enableSystemLogQuery`, право `nodes/log`» → закрыт настройками kubelet (`enableSystemLogHandler`, `enableSystemLogQuery`, ссылка на 11-1 §3), через API нужно широкое право `nodes/proxy`; добавлено «включают заранее». Согласовано с 11-1 и system-logs.md (страница предупреждает именно о `nodes/proxy`; права `nodes/log` она не называет).
3. Работа 1, «Риски»: «kubelet начнёт выселение подов» → выселяет контроллер в controller-manager (taint-based eviction), kubelet в это время стоит.
4. Работа 1, «Риски», откат: добавлено, что будет, если 300 с истекли (замены на других узлах, старые копии в `Terminating` уйдут после возврата kubelet).
5. Версия стенда: в выводе `kubectl get nodes` (работа 1, шаг 6) `v1.36.1` → `v1.36.5` с пояснением; 10-3 прямо пишет «Кластер целиком на 1.36.5; дальше курс работает на этой версии», и старая 11-3 мерила на 1.36.5. В §6 в условия прогона добавлено «Kubernetes 1.36.5 после 10-3». Пункт 17 отчёта писателя решён в пользу 1.36.5.
6. §5, `leaderelection lost`: уточнено, что процесс завершается с кодом 1; у scheduler строка пишется как `Leaderelection lost` (cmd/kube-scheduler/app/server.go, `klog.FlushAndExit(..., 1)`).
7. Работа 2, шаг 4: добавлена оговорка, что сборщик мёртвых контейнеров kubelet удаляет контейнер и каталог логов удалённого static pod примерно через минуту, поэтому строки `Exited` и каталога может не оказаться.
8. Работа 1, шаг 5: добавлено, что при нескольких отказах kubelet перечисляет их в одном сообщении Ready (errors.NewAggregate в setters.go).
9. Работа 3, шаг 2: формулировка про отсутствие строки `rejected_requests_total` смягчена до свойства счётчика с метками.
10. Теория §4: добавлен абзац про PSI узла (`/proc/pressure/*`) и метрики `container_pressure_*`. Без него 05-1 ссылалась на 11-4 впустую («Использование PSI в мониторинге разобрано в 11-4»), а исследование для старой 11-3 требует PSI.

## Читаемость

- До: 231 предложение, средняя длина 10,6 слова, 45 % короче 10 слов, нарушений 0.
- После: 223 предложения, средняя длина 11,5 слова, 39 % короче 10 слов, нарушений 0. Это после склейки около 15 пар рубленых предложений об одной мысли (§2, §3, §4, §5, вводные лабораторных, разборы) и деления трёх предложений, выросших после правок, длиннее 25 слов. Ещё один абзац был в 6 предложений, его сократили слиянием.
- Строки кода ≤ 100 символов (проверено скриптом), эмодзи, меток «Проверено», вопросов собеседования и чеклистов нет; после каждого `##` есть фраза.

## Подтверждено (источник)

- Причины и сообщения условий: `KubeletReady` («kubelet is posting ready status»), `KubeletNotReady` с агрегированным сообщением, `KubeletHasSufficientMemory`, `KubeletHasNoDiskPressure`, `KubeletHasSufficientPID`; Ready идёт последним в списке — pkg/kubelet/nodestatus/setters.go.
- `NodeStatusUnknown` / «Kubelet stopped posting node status.» ставится Ready, MemoryPressure, DiskPressure и PIDPressure (NetworkUnavailable не трогается) — node_lifecycle_controller.go.
- `container runtime is down`, «%s is not healthy» (PLEG) — pkg/kubelet/runtime.go; `container runtime network not ready: %v` — kubelet.go updateRuntimeUp; «GenericPLEG: Unable to retrieve pods», «pleg was last seen active … threshold is …» — pleg/generic.go.
- `--node-monitor-grace-period` 50s, `--node-monitor-period` 5s, аренда лидера 15/10/2 с — справка kube-controller-manager; совпадает с 01-2 §2 и §6 (50 с, раньше 40 с).
- 429 от APF с заголовком `Retry-After` (значение берётся по уровню приоритета) — apiserver/pkg/server/filters/priority-and-fairness.go; метки `flow_schema`, `priority_level`, `reason` у `apiserver_flowcontrol_rejected_requests_total` — flow-control.md.
- `apiserver_current_inflight_requests{request_kind="mutating"|"readOnly"}` — apiserver/pkg/endpoints/metrics/metrics.go.
- Node log query: GA в 1.36, параметры `query`, `tailLines`, `pattern` — system-logs.md.
- Реальные значения из старой 11-3: 47 с, 32 с, 10 с, ~1 с, 30/30, 4 с, 3 с, etcd 3.6.8 / 9.0 MB / 2.1 GB / 5.022125ms, 9.02e+06, evictionHard 0 %, сообщение выселения 20Mi.
- Работа 1 укладывается в окно до выселения: kubelet стоит ~2 мин (Unknown на 47 с, затем шаги 3–4), containerd ~1 мин (taint на 32 с), в обоих случаях меньше 300 с после taint.

## Осталось неподтверждённым (для 00-plan §7)

- Работы 1–3 целиком по форме вывода (собраны писателем, числа из прогона 2026-10-14).
- `docker top <узел kind>` показывает процессы подов (рекурсивный обход cgroup узла); номера PID иллюстративны.
- Структура JSON `crictl info` (`.status.conditions[]` с `RuntimeReady`/`NetworkReady`) в crictl для containerd 2.3.
- Имена метрик `kubelet_pleg_relist_duration_seconds`, `leader_election_master_status`, `etcd_request_duration_seconds`, `apiserver_admission_webhook_admission_duration_seconds` подтверждены по памяти кода, а не прочитанным файлом.
- Отсутствие строки `apiserver_flowcontrol_rejected_requests_total` до первого отказа (возможна предынициализация серий).
- Работа 2, шаг 4: `Exited` у kube-apiserver и каталог в `/var/log/pods` к моменту проверки (их может удалить GC kubelet).
- Работа 3, шаг 3: `grep imageGC` в config.yaml kind печатает только `imageGCHighThresholdPercent: 100`.
- Работа 3, шаг 4: STATUS `Error` у выселенного пода и время выселения 10–25 с.
- Строка `leaderelection lost` у controller-manager (у scheduler подтверждена как `Leaderelection lost`).
- Утверждение «без controller-manager мёртвый узел не получит Unknown» — вывод из архитектуры, не опыт.
- `crictl rmi --prune` и образы `kind load` — осторожная формулировка, не проверялась.
- `eventRecordQPS: 0` = без лимита в 1.37 и PLEG on-demand relist GA в 1.37 — по исследованию (CL37), CHANGELOG не открывался.
