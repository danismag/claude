# Ревью 09-1 CRD и операторы

Файл: /home/user/claude/kubernetes/09-extending/09-1-crd-operators.md. Режим «только текст», команды лабораторных не запускались.

## Найденные ошибки (было → стало)

1. Образ PostgreSQL: `ghcr.io/cloudnative-pg/postgresql:17.6` → `17.11-standard-trixie` (6 мест: теория, ЛР2 шаги 1, 3, 4, уборка). Голый тег `MM.mm` — устаревший формат system-образов на bullseye, такие теги больше не выпускаются (README postgres-containers). Актуальная 17.x в каталоге CNPG на 2026-10-19 — 17.11. В §6 и ЛР2 шаг 1 оговорено: вывод снят на `17.6`, а надёжнее всего закреплять по digest.
2. CNPG 1.30.1 оставлен: это последний релиз (23.09.2026, исправляет CVE-2026-84304 в gRPC-Go и обход вебхука через `..`). Линия 1.30.x поддерживает Kubernetes 1.34–1.36, EOL около декабря 2026 (supported_releases.md). Это добавлено в §6.
3. StorageVersionMigration: «встроенный контроллер в beta с 1.35» → в 1.35–1.36 beta и **выключен по умолчанию** (feature gate `StorageVersionMigrator` + runtime-config `storagemigration.k8s.io/v1beta1`), в 1.37 GA и включён. Контроллер сам обновляет `storedVersions` после миграции (документация в ветке release-1.36 и main, файл feature gate).
4. Схема 3 (путь CR в API-сервере): admission шёл одним блоком до схемы → mutating admission → схема → CEL → validating admission.
5. `metadata.generation` «растёт только при изменении spec» → растёт при любом изменении, кроме `metadata` и `status` (документация CRD).
6. Подресурс scale: «тип понимают kubectl scale и HPA» → для HPA нужен ещё `labelSelectorPath`.
7. selectableFields: «скаляр» → тип string, integer или boolean (ValidateCustomResourceSelectableFields; number не допускается). Лимит 8 подтверждён (MaxSelectableFields = 8).
8. Стоимость CEL: чисел не было → добавлены лимиты из кода: правило ≤ 10 млн (StaticEstimatedCostLimit), CRD ≤ 100 млн (StaticEstimatedCRDCostLimit), при выполнении правило ≤ 1 млн (PerCallLimit), запрос ≤ 10 млн (RuntimeCELCostBudget).
9. Barman Cloud: добавлено, что встроенный `barmanObjectStore` устарел с CNPG 1.26, а плагину нужны CNPG 1.26+ и cert-manager (backup.md, plugin-barman-cloud installation.mdx).
10. Secret'ы CNPG: «replication и server для TLS между экземплярами» → `server` — сертификат сервера, `replication` — клиентский сертификат для репликации.
11. ЛР1 шаг 1, вывод `kubectl explain`: `Enum:` под полем и неполный список → формат по шаблону plaintext.tmpl: строка `FIELD: spec <Object>`, поля по алфавиту (archive, keepDays, …), строка `  enum: orders-db, logs, backups`.
12. ЛР1 шаг 4, ошибка фильтра: `Unable to list …: field label not supported` → при заданном field selector kubectl пишет `Unable to find "…" that match label selector "", field selector "spec.keepDays=30": field label not supported: spec.keepDays` (cli-runtime helper.go EnhanceListError; текст ошибки — conversion/converter.go; BadRequest — apiserver handlers/get.go).
13. ЛР2 шаг 4, расхождение 11+77 записей и 2 адреса против `101|3`: объяснено. В шаге 3 primary — `orders-db-1`, а в шаге 4 удаляют `orders-db-2`: между ними был первый (зависший) прогон автора. Тогда primary `orders-db-1` переключился, а таблица `ticks` (`create table if not exists`) сохранила около 13 строк со старым адресом `orders-db-1`. Третий адрес — это он. Разбор п. 3 переписан: в чистом прогоне будет два адреса и примерно столько строк, сколько `ok`.
14. «Образ скачивался 181 с» → уточнено, что это для прежнего тега `17.6` (новый standard-образ другого размера).

## Подтверждено (источник)

- Формат ошибки CEL без `"object"`: для узлов object/array значение опускается (`field.OmitValueType`, apiextensions schema/cel/validation.go). Строка старой части верна.
- Строка `kind load`: `Image: %q with ID %q not yet present on node %q, loading...` (kind pkg/cmd/kind/load/docker-image).
- Ratcheting: beta с включением по умолчанию в 1.30, GA 1.33 (feature gate CRDValidationRatcheting). В тексте GA 1.33 верно; «GA 1.30» в задании неточно. Transition rules не ratchet-ятся.
- selectableFields GA 1.32, фильтр по `metadata.name` и `metadata.namespace` есть всегда (документация CRD, converter.go).
- Колонки: Age не добавляется сама при своих колонках (пример Shirt в документации), `priority > 0` — только `-o wide`.
- default подставляется в запросе, при чтении из etcd и после мутации (документация CRD).
- CNPG: Services `-rw/-ro/-r` создаются по умолчанию (service_management.md); метка `cnpg.io/instanceRole` (primary/replica/unhealthy), `role` устарела (labels_annotations.md); `instances` по умолчанию 1, минимум 1 (cluster_types.go v1.30.1); репликация асинхронная по умолчанию (replication.md); anti-affinity `preferred`, `kubernetes.io/hostname` по умолчанию (scheduling.md); образ по умолчанию в 1.30.1 — `18.6-system-trixie` (versions.go).
- StorageVersionMigration и staleness mitigation соответствуют research-k8s-changes.md (R35, R36, R37); всё из исследования для 09-1 учтено.
- Ссылки на части: 01-1 §1/§2/§6, 01-3 §2/§3/§6, 03-5 (cert-manager), 04-2 (Retain), 04-3, 05-3, 05-4, 06-1 (агрегированные роли), 06-3 (VAP/MAP), 07-1 (crds/) существуют.
- Уборка: `crictl rmi` конкретных образов в узлах из `kind get nodes --name lab`, `docker rmi` с оговоркой, нет `pkill -f`, нет `apt autoremove`. «Риски» первыми в обеих работах.

## Читаемость

До: 240 предложений, средняя 11,5 слов, коротких 35 %, нарушений 0. После: 243 предложения, средняя 11,7, коротких 34 %, нарушений 0. Правки читаемости не потребовались; новые фразы написаны в той же норме.

## Не подтверждено (для 00-plan §7)

- ЛР1 шаг 1: вывод apply/wait/explain — ожидаемый (формат explain сверен с шаблоном kubectl).
- ЛР1 шаг 3: строки `patched` и `patched (no change)` — ожидаемые.
- ЛР1 шаг 4 целиком (selectableFields в старом прогоне не было): вывод ожидаемый, текст ошибки сверен по коду.
- ЛР1 шаг 5: строка `deleted` — ожидаемая.
- ЛР2 с образом `17.11-standard-trixie` не прогонялась, вывод снят на `17.6`; время скачивания нового образа неизвестно.
- ЛР2 шаг 2: список CRD `cnpg.io` и вывод rollout — ожидаемые.
- ЛР2 шаг 4: команды переписаны (Pod-манифест, `cut | uniq -c`), вывод получен старыми командами.
- Утверждение «вебхуки CNPG обслуживают только его CR» — по памяти писателя.
- Staleness mitigation (beta 1.36): формулировка механизма не сверена с KEP.
- Обновление оператора CNPG перезапускает экземпляры — по памяти, документация upgrading не сверялась.
