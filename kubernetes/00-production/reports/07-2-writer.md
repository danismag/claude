# 07-2 Чужие чарты — отчёт писателя

Файл: /home/user/claude/kubernetes/07-packaging/07-2-helm-third-party.md. Проза около 6400 слов с лабами (теория до лабораторных около 3000, остальное — пояснения внутри лаб); читаемость: средняя длина предложения 11,6, нарушений 0.

## Заголовки
Теория: 1 Какую задачу решает чужой чарт (готовое решение; цена зависимости; случай Bitnami; как выбирать чарт). 2 Как устроен (репозиторий и OCI; values как интерфейс; версии чарта/приложения/образа; субчарты). 3 Как управлять (карточка helm-diff; values по окружениям; секреты через существующий Secret; закрепление образа). 4 Как увидеть состояние (разведка; источник поля; сравнение до обновления). 5 Что ломается (образ; пароль и данные; мажор приложения; мажор чарта). 6 Пределы (значения чарта; ограничения; права и секреты).
Лабы: 1 Установка как есть и проблема пароля; 2 Правильная установка: values по окружениям; 3 Источник поля и diff перед upgrade; 4 Мажорная версия приложения и данные. Работа 3 плана разделена на 3 и 4 (план §4 надо обновить: четыре работы).

## Решения
- Чарт: groundhog2k/postgres 1.6.8 (appVersion 18.6, репозиторий https://groundhog2k.github.io/helm-charts/), образ docker.io/postgres (Docker Official Image), не генерирует пароль. Из-за этого проблема пароля в работе 1 другая, чем у Bitnami: без пароля под падает; пароль из --set виден в helm get values; смена пароля при сохранившемся PVC не действует. Генерация пароля Bitnami описана текстом (§5).
- helm-diff закреплён на v3.15.15, устанавливается из архива с проверкой подписи (требование Helm 4).
- Все четыре работы начинаются фразой «Эту работу вы выполняете сами…»: старый реальный вывод относился к чарту Bitnami, поэтому в лабораторные не перенесён. Из старой части использованы только поведение Helm 4 (строки Pulled/Digest в stdout при template из oci://, §4) и текст предупреждения Rolling tag (§1).
- Карточка helm — ссылка на 07-1; в части новая карточка helm-diff (### в §3).

## Сомнительные места (проверить ревьюеру по документации/исходникам чарта)
1. Chart.yaml 1.6.8/18.6, ключи values (image.*, settings.existingSecret, settings.superuserPassword.{value,secretKey}, storage.requestedSize, persistentVolumeClaimRetentionPolicy), RELEASENOTES (1.5.0 = PG17, 1.6.0 = PG18.1) — подтверждены чтением raw.githubusercontent, но не весь шаблон: имена Secret/Service/StatefulSet (`db-postgres`, `db-postgres-0`, `db18-postgres`), имя PVC `postgres-data-db-postgres-0` (volumeName по умолчанию postgres-data), список `# Source:` (я указал service.yaml и statefulset.yaml, прочие не знаю), работа проб (читают порт, не пароль — предположение), «pgDir»/PGDATA и поведение чарта с PG18 (смена каталога данных в образе 18).
2. Что чарт создаёт при settings.superuserPassword.value: Secret или env-значение — не проверено; в тексте это не утверждается, лишь что helm get values показывает пароль.
3. Образ postgres: сообщения «Database is uninitialized and superuser password is not specified» и «database files are incompatible with server / The data directory was initialized by PostgreSQL version 17, which is not compatible…» — по памяти образа и PostgreSQL; по loopback в официальном образе trust (pg_hba) — по памяти.
4. Образы postgres:17.6 и postgres:18.6 существуют на docker.io (18.6 взят из appVersion чарта).
5. helm-diff: версия v3.15.15 и дата 26 сентября (страница релизов); URL архива helm-diff-linux-amd64.tgz (из README); отпечаток EA17A2A206AFF8CD из README, а на странице релизов упомянут ключ подписи тегов B5690EEEBB952194 — расхождение, ревьюеру сверить; флаг `helm plugin install --keyring` и формат файла (gpg --export) для Helm 4; вывод `helm plugin list` (колонки); формат вывода `helm diff upgrade` (заголовок «has changed:»); `helm diff revision/rollback` в карточке; совместимость v3.15.15 с Helm 4.2.2 (в релизах указаны 4.2.1–4.3.0 для 3.15.9–3.15.13).
6. Строки вывода в «Результат (ожидаемый)»: Error: INSTALLATION FAILED…, UPGRADE FAILED…, таблица helm search repo, helm history (колонка APP VERSION = appVersion чарта, DESCRIPTION), число строк дампа (в тексте плейсхолдер), «role postgres already exists» при restore pg_dumpall, значения RESTARTS/AGE.
7. Diff чарта 1.6.8 и 1.5.0 в работе 4 шаг 1: ожидается различие метки helm.sh/chart; существует ли 1.5.0 в индексе — по RELEASENOTES; попадает ли метка в volumeClaimTemplates — не проверено (в тексте условно).
8. Bitnami: даты 28 авг – 29 сен 2025, bitnamilegacy без обновлений, бесплатный только latest (research-k8s-changes.md); поведение чарта 18.12.4 (latest + предупреждение Rolling tag) — из старой части; «старые версии чарта дают ImagePullBackOff» — по исследованию, не замерено.
9. Ограничение Secret ~1 МиБ — из 07-1; `--history-max` 10, timeout 5m — из 07-1.
10. Отсылки: 06-4 (разрешённые реестры), 09-1 (CloudNativePG), 04-1 (шифрование etcd), 06-1 (RBAC), 05-1 (BestEffort), 03-6, 05-5, 02-2, 02-3, 04-2, 04-3 — номера по плану, не перечитывал содержимое.
11. Предложение «Kubernetes принимает тег вида 18.6@sha256:…» выведено из строки шаблона image: "{{registry}}/{{repository}}:{{tag}}" (получается валидная ссылка repo:tag@digest); не проверено на стенде.

## Что выкинуто/перенесено (в модуль 12)
- Кейс «переустановили Keycloak — никто не может войти»: генерируемый пароль + PVC после uninstall; починка trust в pg_hba и смена пароля; пароли через внешний менеджер, БД отдельным релизом.
- Вопросы собеседования: как узнать параметры чарта; как зафиксировать версию; найти шаблон поля; values по окружениям; почему БД не принимает пароль после переустановки; безопасное мажорное обновление чарта; чем плох зонтичный чарт; что делать с latest по умолчанию.
- Подводные камни: latest по умолчанию (Bitnami); генерируемые пароли + PVC; Running без работающей аутентификации; неточные NOTES (WARNING about authentication после existingSecret); Pulled/Digest в stdout; полная копия values; --reuse-values; чарт создаёт NetworkPolicy/PDB/ServiceAccount; мажор чарта ≠ мажор приложения.
- Задание со звёздочкой (orders-chart с Bitnami и перенос данных orders) — убрано; можно вернуть как задачу для модуля 12 с новым чартом.
- Добавить в модуль 12 как вопрос-ловушку: «helm install bitnami/... как есть» (Bitnami 2025).
