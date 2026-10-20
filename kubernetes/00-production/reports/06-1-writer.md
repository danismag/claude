# Отчёт писателя: 06-1 Аутентификация и RBAC

Файл: `/home/user/claude/kubernetes/06-access-security/06-1-authn-rbac.md` (1672 строки). Часть новая, старой версии и реального вывода нет: все четыре работы начинаются фразой «Эту работу вы выполняете сами, результаты в ней — ожидаемые.» Ничего на машине не запускалось, git commit не делался.

## 1. Заголовки

`##` / `###`:

- Где мы на карте
- 1. Какую задачу решают аутентификация и RBAC: Кто пришёл и что ему можно; Пользователи и ServiceAccount; Наименьшие права; Namespace как граница
- 2. Как устроены аутентификация и авторизация: Способы аутентификации; Токен ServiceAccount; Цепочка авторизаторов; Объекты RBAC; Встроенные и агрегированные роли
- 3. Как выдавать доступ: Пользователь по сертификату; Роль и привязка; OIDC и structured authentication config; Цепочка авторизации из файла; ServiceAccount в поде
- 4. Как увидеть, кто есть кто и что кому можно: Кто я: whoami; Что можно: can-i; Кто что получил; Опасные права; Права на kubelet: nodes/proxy и подресурсы
- 5. Что ломается и как найти причину: 401; 403; Права выданы, а эффекта нет; Токен ServiceAccount не работает
- 6. Пределы и значения по умолчанию: Мягкая и жёсткая мультитенантность; Что namespace не изолирует; Сроки, кеши и значения по умолчанию
- Лабораторные работы: 1 Пользователь по клиентскому сертификату (5 шагов); 2 Role, RoleBinding и проверка прав (6 шагов); 3 ServiceAccount, TokenRequest и токен в поде (5 шагов); 4 Кто может читать Secret в вашем кластере (5 шагов)
- → Дальше

## 2. Объём и читаемость

Проза теории (без кода, таблиц, метаданных) около 3,5 тыс. слов; вся проза вместе с лабораторными около 5,9 тыс. Проверка читаемости: 323 предложения, среднее 11,7 слова, длиннее 25 слов — 0, нарушений 0, жирный 1,5 %. Девять схем в теории, четыре в лабораторных.

## 3. Сомнительные места (для ревьюера)

Конфигурации и версии:

1. `apiVersion: apiserver.config.k8s.io/v1` для AuthenticationConfiguration (GA 1.34) и AuthorizationConfiguration (GA 1.32), ключи `jwt[].issuer.url/audiences`, `claimValidationRules`, `claimMappings.username/groups.expression`, `userValidationRules`, `anonymous.conditions[].path`, ключи webhook-авторизатора (`authorizedTTL`, `unauthorizedTTL`, `failurePolicy`, `matchConditionSubjectAccessReviewVersion`, `connectionInfo.type: KubeConfigFile`). Написаны по памяти документации; сверить с kubernetes.io (Authenticating, Authorization).
2. Взаимоисключение флагов: `--authentication-config` с `--oidc-*`, секция `anonymous` с `--anonymous-auth`, `--authorization-config` с `--authorization-mode`.
3. «Constrained impersonation beta в 1.36, глаголы вида `impersonate-on`» (§4 «Опасные права») — только по исследованию (R36); точные имена глаголов не проверены.
4. «Авторизация с селекторами полей и меток GA в 1.34» (§3) — по исследованию; в памяти стадия не подтверждена.
5. «External SA token signer GA 1.36» и «jti / node binding GA 1.32–1.33» — по исследованию.
6. Fine-grained kubelet authz (§4 «Права на kubelet»): список подресурсов (`nodes/metrics`, `stats`, `pods`, `configz`, `healthz`, `log`), порядок «сначала узкое, при отказе `nodes/proxy`», GA 1.36 — по KEP-2862 и исследованию. Утверждение «узкие права действуют при прямом обращении к порту 10250, а через прокси API-сервера по-прежнему нужен `nodes/proxy`» — мой вывод из устройства прокси; ревьюеру проверить. Это расходится с 01-2 (строка ~211): там сказано, что запрос `kubectl get --raw /api/v1/nodes/<узел>/proxy/configz` с 1.36 выдают подресурсом `nodes/configz`. Одно из двух неверно; требуется сверка по документации и правка 01-2 или 06-1.
7. Фраза «kubelet умеет запускать команды в подах» как причина опасности `nodes/proxy` — общеизвестная часть kubelet API; про websocket/GET-обход я осознанно не писал.
8. «Группа `system:masters` обходит всю цепочку через встроенный авторизатор до RBAC» — по памяти кода (privileged groups authorizer); проверить.
9. «RoleBinding на `cluster-admin` даёт полный контроль в namespace»; «`edit` читает Secret и запускает поды от любого SA» — по документации user-facing roles; «`admin` без квот и самого namespace» — тоже.
10. CSR: минимум `expirationSeconds` 600; потолок `--cluster-signing-duration` (по умолчанию 8760 ч); сертификаты kubeadm 1 год, CA 10 лет.
11. TokenRequest: по умолчанию 1 ч, минимум 600 с, `--service-account-max-token-expiration`; в поде 3607 с, замена на 80 % срока или после суток; адресат по умолчанию — issuer `https://kubernetes.default.svc.cluster.local` (kubeadm/kind).
12. Кеши: webhook-авторизация 5 мин / 30 с, webhook токенов 2 мин.
13. «Клиентские библиотеки перечитывают токен примерно раз в минуту» — по памяти client-go.
14. Токен-Secret перестали создавать автоматически в 1.24; в лабораторной колонка `SECRETS 0` в `kubectl get sa` — формат колонок.

Ожидаемый вывод (не подтверждён ни прогоном, ни документацией построчно):

15. Работа 1: `subject=CN = lab-anna, O = lab-06-1-devs` (формат OpenSSL 3); `issuer=CN = kubernetes`; таблица `get csr` (колонки сокращены `…`); сообщения `set-cluster/set-credentials/set-context/use-context`; вывод `auth whoami` (по образцу 00-2); текст `Forbidden`.
16. Работа 2: таблица `can-i --list` (порядок и состав строк, встроенные URL); сообщение защиты от эскалации (`user "lab-anna" (groups=["lab-06-1-devs" "system:authenticated"]) is attempting to grant RBAC permissions not currently held`); `No resources found in lab-06-1 namespace.`
17. Работа 3: декодирование JWT через `tr '_-' '/+' | base64 -d 2>/dev/null` без дополнения `=` (должно напечатать JSON целиком, но проверить); состав claims (`jti`, `kubernetes.io.serviceaccount`, отсутствие `pod`); `.exp - .iat` равно 600; индекс `volumes[0].projected.sources[0]` и значение `3607`; код 403 для Secret; `ls` без тома и `command terminated with exit code 1`; 401 после удаления привязанного пода (проверяется ли удаляемый, но ещё завершающийся под — зависит от `terminationGracePeriodSeconds: 1`); образ `curlimages/curl:8.11.1` (существование тега и пользователь, под которым читается токен, проверить).
18. Работа 4: `/version` анониму отвечает 200 (роль `system:public-info-viewer`); привязки по умолчанию (`cluster-admin` → `system:masters`, `kubeadm:cluster-admins`); состав списка ролей с чтением Secret (число 11 — условное) и список ролей с `escalate/bind/impersonate/nodes/proxy` (`system:controller:clusterrole-aggregation-controller`, `system:kubelet-api-admin`); формат `column -t` и вывод jq; `kubectl create clusterrole --resource=nodes/metrics,nodes/stats` (запись resource/subresource).
19. `kubectl auth can-i` с `--as` отправляет SelfSubjectAccessReview/RulesReview от имени подменённого субъекта: из этого выведено, что для анонима команда не годится, а проверка анонима в работе 4 сделана `curl` без учётных данных.
20. Команда `kubectl auth reconcile` описана по памяти (создаёт недостающее, обновляет правила).

## 4. Отличия от плана

- Мультитенантность разнесена: модели soft/hard и ограничения namespace — в §6; в §1 только короткая «граница namespace». Квоты — ссылка 05-2, NetworkPolicy — 03-6, Pod Security — 06-3, taints — 05-3; vCluster/gVisor/Kata названы одним словом, без практики.
- OIDC без лабораторной (в исследовании предлагалась): структурированная конфигурация показана манифестом в теории (§3), развернуть IdP на стенде курс не берёт.
- Подсказана ссылка из 01-2 на `nodes/configz` (см. п. 6) — нужна правка за пределами этой части.

## 5. Что выброшено или перенесено

Старой версии части нет, поэтому ничего не выброшено. В модуль 12 стоит передать:

- Вопрос «401 или 403: в чём разница и что смотреть» (§1, §5).
- Вопрос «может ли RoleBinding выдать ClusterRole и что будет» (§2, работа 2).
- Ловушка «`edit` называется редактором, но читает Secret» (§2, работа 4).
- Ловушка «сертификат нельзя отозвать» (§2, §3).
- Вопрос «защита от эскалации: `escalate` и `bind`» (§2, работа 2 шаг 5).
- Вопрос «bound-токен SA: чем лучше старого Secret» (§2, §3, работа 3).
- Тренажёр: «под не может читать API» (automount false) и «токен перестал работать после удаления пода».
- Тренажёр: «ошибочная привязка `edit` открыла Secret» (работа 4 шаг 4).
- Тема system design: платформа для 30 команд (модели мультитенантности, §6).
- Вопрос «`nodes/proxy` для мониторинга: чем опасен и чем заменить» (§4).
