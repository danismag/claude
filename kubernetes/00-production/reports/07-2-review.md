# 07-2 Чужие чарты — отчёт ревьюера

Файл: /home/user/claude/kubernetes/07-packaging/07-2-helm-third-party.md. Режим «только текст»: ничего не запускалось. Исходники лежат в scratchpad rv072/: архивы чарта 1.6.8 и 1.5.0 с GitHub Releases, sha256 1.6.8 совпал с digest в index.yaml; entrypoint и Dockerfile образа postgres 18; miscinit.c PostgreSQL 18; README, report.go и parse.go helm-diff; файл .prov v3.15.15; plugin_install.go, plugin_list.go и upgrade.go Helm v4.2.2; statefulset.md из kubernetes/website.

## Решение по чарту
Чарт groundhog2k/postgres 1.6.8 подтверждён, замена не нужна. Он есть в index.yaml (gh-pages): appVersion 18.6, опубликован 2026-08-14. Версия 1.5.0 тоже есть: appVersion 17.0, 2024-11-02. Образ — Docker Official `docker.io/postgres`. Теги `postgres:18.6` и `postgres:17.6` есть на Docker Hub (API hub.docker.com, код 200). Имена объектов подтверждены по `_helpers.tpl`: fullname `<релиз>-postgres`, то есть `db-postgres`, `db-postgres-0`, `db18-postgres`; PVC `postgres-data-db-postgres-0`. Пароль задаётся через `settings.superuserPassword.value`: чарт создаёт Secret `<fullname>` (secureconfig.yaml). Другой путь — `settings.existingSecret`: ключ `POSTGRES_PASSWORD` по умолчанию, `superuserPassword.secretKey` меняет его. С PostgreSQL 18 чарт работает: он задаёт `PGDATA=/var/lib/postgresql/data/pg` явно. Проверка старого монтирования в entrypoint 18 срабатывает только при PGDATA по умолчанию (`/var/lib/postgresql/18/docker`), поэтому чарта она не касается.

## Найденные ошибки (было → стало)
1. ЛР4 шаг 3: `helm rollback --wait` при CrashLoopBackOff StatefulSet. Было: ожидаемый успех. Стало: rollback без `--wait`, затем `k delete pod db-postgres-0` и `k wait --for=condition=Ready`. Причина — forced rollback, kubernetes#67250, docs statefulset.md, 02-3 §5. Исправлены также §5, схема ЛР4, Риски, Итог и вопрос 3.
2. ЛР4 шаг 2: history после неудачного upgrade. Было: «2 superseded». Стало: «2 deployed», плюс объяснение. По upgrade.go Helm v4.2.2 прежняя ревизия получает superseded только после успеха.
3. Карточка helm-diff, §6. Было: «без `-q` печатает Secret открытым текстом». Стало: по умолчанию значения маскируются, `--show-secrets` их раскрывает, а `-q` убирает изменения Secret целиком (README v3.15.15).
4. Карточка helm-diff. Было: «перечень версий Helm — в описании выпуска»; на странице выпуска такого перечня нет. Стало: «README требует Helm 3.18+, на стенде 4.2.2».
5. Ключ подписи. EA17A2A206AFF8CD подтверждён: я разобрал подпись в `helm-diff-linux-amd64.tgz.prov` v3.15.15. Issuer fingerprint C5645EF47482257A1F806D2BEA17A2A206AFF8CD, RSA, подпись от 2026-09-26. B5690EEEBB952194 страница выпуска показывает у коммита: это проверенная GitHub подпись коммита, а не ключ плагина. В частые ошибки карточки добавлены оба пункта и пункт о `pubring.gpg`/`pubring.kbx`.
6. ЛР3 шаг 3, вывод установки. Было: `pub rsa4096 … [SC]` (размер не подтверждён), «NAME VERSION …». Стало: строки из plugin_install.go — `Verifying plugin signature...`, `Signed by`, `Using Key With Fingerprint`, `Plugin Hash Verified`, `Installed plugin: diff`. Колонки plugin list: NAME VERSION TYPE APIVERSION PROVENANCE SOURCE. Отпечаток в формате README.
7. ЛР3 шаг 1. Было: список Source без scripts.yaml, одна строка image, порядок cpu/memory/limit. Стало: scripts.yaml, service.yaml, statefulset.yaml; две строки image (init-контейнер и основной); limits раньше requests, потому что toYaml сортирует ключи. В разборе добавлено, что Secret чарт не создаёт, а NetworkPolicy — только при `networkPolicy`.
8. ЛР3 шаг 2. Было: `512Mi 512Mi` для grep манифеста. Стало: строки `memory: 512Mi` и `memory: 256Mi`, потому что grep ловит и лимит, и запрос, плюс 512Mi из пода.
9. ЛР2 шаг 3, вывод diff. Стало: порядок limits → requests → storage, разделители `---`, добавлен лимит памяти 512Mi → 1Gi.
10. ЛР4 шаг 1, diff 1.6.8 и 1.5.0. Было: одна метка. Стало: helm.sh/chart, app.kubernetes.io/version (18.6/17.0), checksum/scripts, команда pg_isready (изменена в 1.6.6), apiVersion/kind в volumeClaimTemplates (1.6.5). Образ в helm diff — две пары строк. В разборе сказано: меток чарта в шаблоне диска нет (подтверждено по шаблону); checksum/scripts перезапускает под при любом обновлении чарта.
11. ЛР3 шаг 4: отступ строк helm-diff исправлен на «- » + отступ манифеста. Заголовок `ns, name, Kind (group) has changed:` подтверждён по parse.go и report.go.
12. Проба. Было: «проверяет порт». Стало: «`pg_isready` проверяет, что сервер принимает подключения, пароль не проверяет» (statefulset.yaml) — в §5, ЛР1 шаг 5 и вопросе 1.
13. ЛР1. Добавлено, что при `superuserPassword.value` чарт создаёт Secret `db-postgres`: §2, разбор шага 4, ответ 2, §5. В шаг 5 добавлена строка `command terminated with exit code 2`.
14. ЛР2 шаг 5, ЛР3 шаг 5: добавлен `INSERT 0 1` — psql без `-q` печатает тег последней команды.
15. Сообщения образа и сервера. Текст ошибки без пароля подтверждён и расширен по entrypoint 18. FATAL/DETAIL о несовместимых файлах подтверждены по miscinit.c; добавлен префикс лога «…» и хвост «compatible with this version 18.6».
16. Придуманные RESTARTS и AGE (2/60s, 2/80s, 0/20s) заменены на «…».
17. §6 дополнен: каталог данных (PGDATA, dataDir/pgDir, изменение образа 18) и пробы (startup 30×10 с, liveness/readiness 3×10 с). Чтобы список не превышал 7 пунктов, раздел разделён на два подраздела.
18. Уборка ЛР4: оговорка не удалять ключ GPG, если он был у читателя до работы. В подготовке устранён разрыв строки с висящим пробелом.

## Читаемость
До правок: 300 предложений, средняя длина 11,6 слова, коротких 38 %, нарушений 0. После: 308 предложений, 11,8 слова, коротких 36 %, нарушений 0. Одно промежуточное нарушение (список из 9 пунктов в §6) устранено делением на два подраздела.

## Подтверждено (источник)
- Chart.yaml 1.6.8/18.6, values (image.*, settings.*, storage.*, securityContext, probes), RELEASENOTES (1.5.0 = 17.0, 1.6.0 = 18.1, 1.6.8 = 18.6) — архив чарта.
- Имена объектов, Secret чарта, env POSTGRES_PASSWORD/secretKeyRef, PGDATA, пробы pg_isready — templates 1.6.8.
- Теги postgres 18.6 и 17.6 — Docker Hub API; ENV PGDATA и VOLUME образа 18 — Dockerfile docker-library.
- helm-diff v3.15.15: plugin.yaml, ассеты `helm-diff-linux-amd64.tgz(.prov)` (HTTP 200), подпись .prov ключом EA17A2A206AFF8CD, дата 26 сентября 2026; флаги `--detailed-exitcode`, `-q`, `--show-secrets`, `--three-way-merge`, `-C`, команды revision и rollback — README.
- Helm 4.2.2: `helm plugin install --verify` (по умолчанию true), `--keyring`, проверка .prov для tgz — plugin_install.go v4.2.2.
- Forced rollback — statefulset.md и 02-3.
- Bitnami: строки Rolling tag и Pulled/Digest — из старой части (реальный прогон).

## НЕ ПРОВЕРЕНО (для 00-plan)
- все четыре работы не запускались, вывод ожидаемый;
- `helm plugin install --keyring <файл gpg --export>` с URL архива на Helm 4.2.2: формат связки и путь по умолчанию `~/.gnupg/pubring.gpg` выведены из кода и документации GnuPG;
- точный вывод `gpg --list-keys --with-fingerprint` и `helm plugin list` (TYPE/APIVERSION/PROVENANCE);
- работа helm-diff 3.15.15 с Helm 4.2.2 (README требует только 3.18+);
- B5690EEEBB952194 — подпись коммита GitHub, по странице выпуска; принадлежность ключу web-flow не сверена;
- `ERROR: role "postgres" already exists` при восстановлении pg_dumpall;
- `Error: INSTALLATION/UPGRADE FAILED` — текст сообщения kstatus;
- вывод `helm template --debug` в Helm 4;
- тег вида `18.6@sha256:…` в `image.tag`;
- Bitnami: ImagePullBackOff старых версий чарта и даты 28.08–29.09.2025 — по исследованию, на стенде не воспроизводилось;
- полный diff рендеров 1.6.8 и 1.5.0 (выведен из шаблонов, не отрендерен);
- план §4: в части четыре работы (3 разделена на 3 и 4) — обновить 00-plan.
