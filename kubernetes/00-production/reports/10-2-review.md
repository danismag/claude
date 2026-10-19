# Ревью 10-2 etcd

Файл: /home/user/claude/kubernetes/10-cluster-ops/10-2-etcd.md (новая часть, реального вывода нет, все три работы — «Эту работу вы выполняете сами…»).
Режим «только текст»: команды лаб не запускались; источники — raw-файлы GitHub (kubernetes release-1.36/1.37, etcd release-3.6, etcd-io/website v3.6, kubernetes/website, kind v0.32.0), загрузки в scratchpad/r102.

## Главный риск: etcdutl в образе

- Старый образ registry.k8s.io/etcd собирал проект Kubernetes (cluster/images/etcd, до 3.6.4): Dockerfile копирует только `etcd*`, `etcdctl*`, Makefile ставит только etcd и etcdctl — etcdutl там нет.
- В декабре 2025 эта сборка удалена из kubernetes/kubernetes (PR #135824, «Official etcd images are used instead», issue #135801, etcd-io/etcd#19798): в registry.k8s.io/etcd публикуются официальные образы релизов etcd без изменений (теги с суффиксом -0 сохранены).
- Официальный Dockerfile etcd release-3.6: distroless/static, `etcd`, `etcdctl`, `etcdutl` в `/usr/local/bin`, оболочки нет.
- kubeadm 1.36 constants.go: `DefaultEtcdVersion = "3.6.8-0"` (собран после перехода, CHANGELOG 1.36 «Updated etcd images to v3.6.8»). Вывод: etcdutl в образе есть и в PATH; работа 2 оставлена на etcdutl из образа. Прямой проверки содержимого именно 3.6.8-0 нет — в шаг 2 добавлена подсказка на случай `executable file not found`.

## Найденные ошибки (было → стало)

1. Перед переходом с 3.5 на 3.6: «3.5.20 или новее» → «3.5.32 или новее» (upgrade_3_6.md etcd v3.6; так же в 10-3).
2. Тюнинг heartbeat: «таймаут выборов минимум в пять раз больше интервала» → «heartbeat ≈ RTT, таймаут выборов не меньше 10 RTT» (tuning.md).
3. `apiserver_storage_objects` устарела с 1.34 (metrics.go release-1.36) → основная метрика `apiserver_resource_objects` (метки group, resource), упомянуты устаревшая и `apiserver_resource_size_estimate_bytes`; то же в ответе работы 3.
4. EtcdRangeStream «через флаг в 1.37» → «в бете и включён по умолчанию в 1.37, работает только с etcd 3.7+» (исследование, R37).
5. Работа 2, восстановление без `--bump-revision`/`--mark-compacted`, хотя recovery.md советует их «when using Kubernetes in general» и теория части о них говорит → в под restore добавлены `--bump-revision=1000000000 --mark-compacted`, строки таблицы и разбор; в список процедуры §3 — оба флага.
6. Работа 2, шаг 4: `grep 'path: /var/lib/etcd'` находит и `mountPath: /var/lib/etcd` → ожидаемый вывод из двух строк, разбор переписан.
7. Работа 2, шаг 2: у `snapshot save` есть строка `Server version …` (snapshot_command.go), у `etcdutl snapshot status -w table` есть столбец VERSION (etcdutl printer.go) → добавлены.
8. Работа 2, шаг 3: в ожидаемом выводе не было строк `namespace/lab-10-2-after created` и `namespace "lab-10-2" deleted` → добавлены.
9. Работа 3, шаг 2: `until ec endpoint health` мог сработать на старом поде etcd до перезапуска → функция `st` дополнена полем `quota` (`.dbSizeQuota`), цикл ждёт `quota = 33554432`.
10. Работа 3, шаг 5: `etcdctl compact` без `--physical` возвращается до физического удаления, и `st` сразу после мог не показать падение `inuse` → `compact $REV --physical`.
11. Работа 3: «60–70 итераций», «около 70 обновлений» — расчёт без замера, компакция API-сервера раз в 5 мин может его сдвинуть → «несколько десятков», с оговоркой о компакции; схема 8 исправлена.
12. Работа 3, ожидаемые JSON вида `"db":≈33554432,"inuse":≈0,4 МиБ + база` (невалидные, выдуманные значения) → `…` и словесное описание в разборе.
13. Текст ошибки kubectl: `Error from server: … etcdserver: …` → `Error from server …: etcdserver: mvcc: database space exceeded` и фраза, что kubectl может вставить тип ошибки (точный префикс не подтверждён).
14. Работа 1, шаг 1: в таблице `endpoint status` 3.6 есть столбец QUOTA (printer.go) → добавлен `2.1 GB` (humanize.Bytes), разбор и связь с шагом 3; единицы «МБ» → «MB», как печатает etcdctl.
15. §3: «etcdutl ставится вместе с ним и на стенде есть в образе» → уточнено: в архиве релиза и в официальном образе etcd рядом с etcdctl; в работе 2 добавлено, что образ без оболочки.

## Читаемость

Автопроверка до: 268 предложений, средняя 11,9 слов, коротких 32 %, нарушений 0. После: 276 предложений, средняя 11,9, коротких 33 %, нарушений 0. Строки кода ≤100 знаков. Новые фразы держались той же длины; отдельных правок читаемости не потребовалось.

## Подтверждено (источник)

- kubeadm 1.36 → etcd 3.6.8-0, 1.37 → 3.7.0-0 (constants.go release-1.36/1.37; master уже 3.7.1-0).
- Манифест kubeadm 1.36 (local.go): `command` начинается с `etcd`, флаги `--snapshot-count=10000`, `--listen-metrics-urls=http://127.0.0.1:2381` (EtcdMetricsPort 2381), `--data-dir` из конфига, том `etcd-data` hostPath DirectoryOrCreate, `--auto-compaction-*` нет, `--quota-backend-bytes` нет; есть `--feature-gates=InitialCorruptCheck=true`, `--watch-progress-notify-interval=5s`; пробы `/livez`, `/readyz`. Аргументы сортируются, порядок в выводе шага 3 работы 1 верный. kind 0.32.0 config.go не меняет dataDir — `/var/lib/etcd`.
- curl в образе узла kind — реальный вывод старой версии (00-1, `docker exec lab-worker curl -s`).
- heartbeat 100 мс, election timeout 1000 мс, верхний предел 50 с (tuning.md v3.6); backend batch interval 100 мс, limit 10000 (backend.go); snapshot-count 10 000 (tuning.md).
- Компакция API-сервера: `--etcd-compaction-interval` по умолчанию 5m, сжатие до ревизии, запомненной на прошлом шаге, т. е. хранится ~5 мин истории (compact.go, storagebackend/config.go).
- Квота 2 ГиБ, рекомендуемый максимум 8 ГиБ с предупреждением, запрос 1,5 МиБ (limit.md); NOSPACE, режим «чтение и удаление», порядок compact → defrag → disarm, тексты `compacted revision N`, `Finished defragmenting etcd member[…]`, `memberID:… alarm:NOSPACE`, ошибка `etcdserver: mvcc: database space exceeded` (maintenance.md, compaction_command.go, defrag_command.go: «. took %s»).
- JSON `endpoint status -w json`: `[{"Endpoint":…,"Status":{"header":{"revision":…},"dbSize","dbSizeInUse","dbSizeQuota"}}]` (ep_command.go, rpc.pb.go).
- `endpoint health`: «is healthy: successfully committed proposal: took = …» (printer_simple.go); столбцы member list (printer.go).
- etcdutl restore: `--bump-revision`, `--mark-compacted`, `--skip-hash-check`, `--initial-cluster-token`; snapshot status/restore только в etcdutl с 3.6 (recovery.md, etcdutl snapshot_command.go).
- 50/500 sequential IOPS, память 8 / 16–64 ГБ (hardware.md); fsync p99 < 10 мс, backend commit p99 < 25 мс, нечётное число, не больше 7 (faq.md); `--force-new-cluster` паникует при живых старых членах (recovery.md); 5 членов для production, дефрагментация как можно реже, etcd-defrag в CronJob (kubernetes/website configure-upgrade-etcd.md).
- Линеаризуемость чтений по умолчанию (api_guarantees.md: strict serializability).
- Перекрёстные ссылки 01-1 §2/§3/§4/§5/§6, 04-1 §3, 04-3 §1/§6, 01-2, 09-1, 10-3 существуют; переменные сертификатов `ecs`/`ec` совпадают с карточкой 01-1 §4 (`server.crt`/`server.key`, `ca.crt`, `https://127.0.0.1:2379`).

## Не подтверждено (для 00-plan §7)

- Содержимое именно registry.k8s.io/etcd:3.6.8-0 (etcdutl в /usr/local/bin, без оболочки) — выведено из перехода на официальные образы, не проверено на образе.
- Версия etcd внутри kindest/node:v1.36.1 (ожидается 3.6.8).
- Работы 1–3 целиком — без реального вывода.
- Точный префикс ошибки kubectl при NOSPACE (тип/код ошибки перед текстом etcd).
- Число итераций до NOSPACE в работе 3 и размер свежей базы kind («единицы мегабайт»).
- Перезапуски kube-scheduler/kube-controller-manager при NOSPACE (написано «могли»).
- Поведение кластера kind после восстановления с `--bump-revision`/`--mark-compacted` (переподключение kubelet, scheduler, controller-manager без их перезапуска).
- Время остановки static pod после переноса манифеста (sleep 20) и время подъёма API в работе 2.
- Оценка ресурсов отдельного кластера (~1 ГиБ памяти, ~1 ГБ диска).
