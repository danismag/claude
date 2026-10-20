# 04-3 Бэкап и восстановление данных: отчёт ревьюера

Файл: /home/user/claude/kubernetes/04-config-storage/04-3-postgres-backup.md. Скрипты правки и копия «до»: scratchpad/fix043/ (fix1.py, fix2.py, lab3.md, 04-3-before.md). Загрузки (CHECKSUM Velero, теги Docker Hub): scratchpad/dl043/.

## Найденные ошибки (было → стало)
- MinIO: репозиторий minio/minio архивирован 25.04.2026, README: «no longer maintained», community-версия только исходным кодом, бинарные сборки не выпускаются; quay.io недоступен из среды, теги `RELEASE.2025-09-07…`/`mc RELEASE.2025-08-13…` не подтверждены → хранилище заменено на VersityGW `versity/versitygw:v1.8.0` (Apache-2.0, Versity Software, релиз 2026-09-04; v1.9.0 от 13.10 не взят как слишком свежий) в режиме `posix /data`, ключи — переменные `ROOT_ACCESS_KEY_ID`/`ROOT_SECRET_ACCESS_KEY`, порт 7070; бакет создаёт Job `amazon/aws-cli:2.37.0` (`aws s3 mb --endpoint-url`). В тексте работы одним абзацем объяснено, почему не MinIO; термин VersityGW введён с определением.
- `region=minio` → `region=us-east-1` (VersityGW проверяет подпись с регионом, по умолчанию `us-east-1`; плагин AWS требует region при s3ForcePathStyle=true).
- Плагин `velero-plugin-for-aws:v1.14.0` → `v1.14.4` (релиз 28.09, вместе с Velero v1.18.4; оба образа есть на Docker Hub).
- Шаг 1: файл сумм `velero-v1.18.4-checksums.txt` (404) → `CHECKSUM` (существует, содержит `velero-v1.18.4-linux-amd64.tar.gz`).
- Шаг 5: `grep -E 'Phase|Kopia|data'` не находил раздел — Velero печатает `Pod Volume Backups - kopia:` (backup_describer.go v1.18.4) → `grep -E '^Phase|Pod Volume|lab-04-3-demo/'`, ожидаемый вывод переписан по форматным строкам кода; разбор упоминает `<none included>`.
- Шаг 6: `kubectl get pvc,pod,cm app-config` (имя с несколькими типами даёт NotFound для pvc/pod) → `get pvc,pod,cm`; в ожидаемый вывод добавлен `kube-root-ca.crt`. Разбор про init-контейнер и «новый PV» уточнён по file-system-backup.md.
- Шаг 7: `grep -E 'Namespaces|Total items'` не показывал `Included:` → `grep -A1 -E '^(Namespaces|Total items)'`, вывод по форматным строкам кода.
- Теория §5: «без s3ForcePathStyle запись проходит, а чтение падает» — неверно → без path-style клиент обращается к хосту `velero.s3…`, которого нет в DNS, падает любой запрос; добавлен `checksumAlgorithm=""` (по умолчанию CRC32, backupstoragelocation.md плагина).
- §4: список фаз Velero был подан как полный → «среди значений есть…» (есть ещё WaitingForPluginOperations, Finalizing и др.).
- §2: добавлено, что FSB в документации v1.18 — beta.
- Риски работы 3: «около 15 CRD» и «100–200 МиБ на агента» (оценки по памяти) → «набор CRD velero.io»; у node-agent по умолчанию нет requests/limits, сервер 500m/128Mi, лимит 1 CPU/512Mi (customize-installation.md); агент монтирует `/var/lib/kubelet/pods` и `/plugins`.
- Уборка работы 3: `velero uninstall` сам удаляет namespace установки, CRD и ClusterRoleBinding (uninstall.go) — текст поправлен; файлы ключей переименованы под s3-user/s3-pass.
- Работы 1–2: «Риски» теперь первым блоком (в работе 1 добавлен, в работе 2 перенесён до «Цели»). Уборка работы 2 не возвращала данные: строки `mug`, `desk` оставались → добавлены `rollout status` и `DELETE … IN ('mug','desk','after-backup')`; в уборке работы 1 — указание выполнить уборку работы 2, если она пропускается.
- Таблица шага 3 работы 2: «создать StatefulSet, Service и PVC» → «Secret, Service и StatefulSet; PVC создаст StatefulSet» (postgres.yaml из 00-1).
- Мелкое: «а чтение другой ключ» → «а для чтения выдают другой ключ»; MinIO в метаданных, вводе к лабам, итоге и вопросах заменён на шлюз S3.

## Читаемость
До: 241 предложение, средняя 10,9 слова, короче 10 слов 39 %, нарушений 0. После: 254, средняя 11,4, 37 %, нарушений 0 (одно новое предложение в 30 слов поделено). Строки кода ≤100 знаков.

## Подтверждено (источник)
- Velero v1.18.4 — последний релиз (28 сентября), v1.18.3 — 21 сентября: github.com/vmware-tanzu/velero/releases; образ velero/velero:v1.18.4 — Docker Hub API.
- Совместимость Velero 1.18: ожидаемая «1.18-latest», проверено на 1.33.7/1.34.1/1.35.0 — README velero; в части сказано, что 1.36 входит в ожидаемую, но отдельно не проверялась.
- Плагин AWS v1.14.x ↔ Velero v1.18.x — README плагина; v1.14.4 — releases плагина, Docker Hub.
- Флаги `--use-node-agent`, `--default-volumes-to-fs-backup`, `--use-volume-snapshots`, `--backup-location-config`, `--wait` (ждёт Deployment и node-agent), `--namespace` через общий флаг, uploader по умолчанию Kopia, сообщение «Velero is installed! … Use 'kubectl logs deployment/velero -n %s'…» — install.go v1.18.4.
- s3ForcePathStyle, s3Url, region, checksumAlgorithm (CRC32 по умолчанию) — backupstoragelocation.md плагина; команда для S3-хранилища — docs/main/contributions/minio.md.
- FSB beta; hostPath не поддерживается, local — да; общий статический ключ шифрования; opt-in по `backup.velero.io/backup-volumes`, opt-out — `--default-volumes-to-fs-backup`; init-контейнер ждёт файл в `.velero` — docs v1.18 file-system-backup.md.
- TTL по умолчанию 30 дней (720 ч) — docs v1.18 how-velero-works.md.
- `velero uninstall --force`: удаляет namespace, CRD, ClusterRoleBinding — uninstall.go v1.18.4.
- Формат describe (`Phase:`, `Pod Volume Backups - %s:`, `Namespaces:/Included:`, `Total items to be backed up:`, `Items backed up:`), «Backup completed with status: %s.», «Backup request %q submitted successfully.» — backup_describer.go, create.go v1.18.4.
- MinIO: архив 25.04.2026, только исходный код — github.com/minio/minio.
- VersityGW: posix backend, «subdirectories are treated as buckets», требование xattr («xattr check failed»), флаг `--port` по умолчанию `:7070`, `ROOT_ACCESS_KEY_ID`/`ROOT_SECRET_ACCESS_KEY`, регион по умолчанию us-east-1, entrypoint передаёт аргументы бинарю — README, main.go, gwcli/posix.go, docker-entrypoint.sh; теги v1.8.0/v1.9.0 — Docker Hub; amazon/aws-cli:2.37.0 (22.09.2026) — Docker Hub.
- `etcdctl snapshot status` удалён в 3.6, нужен `etcdutl` — etcdctl/README.md; колонки HASH/REVISION/TOTAL KEYS/TOTAL SIZE — etcdutl/README.md. Сертификаты `/etc/kubernetes/pki/etcd/{ca,server}.{crt,key}` и exec в `etcd-lab-control-plane` совпадают с карточкой etcdctl в 01-1.
- Значения CronJob/Job по умолчанию (successfulJobsHistoryLimit 3, failedJobsHistoryLimit 1, backoffLimit 6, concurrencyPolicy Allow, без TTL) — стандартные значения API batch/v1, согласованы с 02-4.
- Ссылки на части (02-3, 02-4 DaemonSet/Job/CronJob, 04-1, 04-2, 05-1, 08-1, 09-1 CloudNativePG, 10-2 etcd) есть в плане §4.

## Не подтверждено (для 00-plan)
- Работа 3 целиком не прогонялась: весь вывод ожидаемый.
- Velero 1.18 на Kubernetes 1.36 — только «ожидаемая совместимость» README, не тестировалась разработчиками.
- Velero + VersityGW v1.8.0 (Kopia, контрольные суммы CRC32 плагина) — совместная работа не проверена; запасной вариант `checksumAlgorithm=""` указан в §5.
- Поддержка xattr файловой системой под emptyDir узла kind (нужна VersityGW) — не проверена.
- Структура архива `velero-v1.18.4-linux-amd64/velero` — по прежним релизам, архив не скачивался.
- Наличие `etcdutl` в образе etcd 3.6 стенда и текст «Snapshot saved at …» — не подтверждены.
- Строки вывода `backup-location get`, `make_bucket: velero`, вывод `restore create --wait` и `get pvc,pod,cm` — ожидаемые.
- Работа 2: «statefulset.apps "postgres" deleted», «persistentvolumeclaim … deleted» — стандартные сообщения kubectl, не из прогона; уборка с `DELETE` не прогонялась.
- Работа 1 шаг 4: jsonpath узла PV записан заново (в прогоне был только вывод).
- Работы 1–2 идут в namespace `orders`, файлы в `~/lab/k8s/04-3/` — отклонение от правила имён, записать в 00-plan §6; имя файла части (postgres-backup) не соответствует новой теме — на ведущем агенте.
- Ссылки 09-1 на «задание 04-3 с MinIO/Barman Cloud» устарели — поправить в 09-1.
