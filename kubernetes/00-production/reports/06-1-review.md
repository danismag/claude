# Ревью 06-1 «Аутентификация и RBAC»

Файл: `/home/user/claude/kubernetes/06-access-security/06-1-authn-rbac.md`. Часть новая, реального вывода нет; все четыре работы правильно начинаются фразой «Эту работу вы выполняете сами…». Сверка: website main (authentication.md, authorization.md, kubelet-authn-authz.md, rbac.md, service-accounts-admin.md, certificate-signing-requests.md, user-impersonation.md, configure-service-account.md, блог 2026 fine-grained-kubelet-authz), код kubernetes release-1.36 (pkg/features/kube_features.go, apiserver features, pkg/kubelet/server/auth.go, bootstrappolicy/policy.go и controller_policy.go, pkg/serviceaccount/claims.go, filters/impersonation/impersonation.go, kubectl create_role.go, rbac/validation/rule.go, client-go transport/token_source.go, kubeapiserver/authorizer/config.go). Загрузки — scratchpad `r061/`. Ничего не запускалось, git commit не делался.

## 1. Найденные ошибки (было → стало)

1. **Расхождение 06-1 и 01-2 по kubelet authz.** Верна 06-1: запрос `/api/v1/nodes/<узел>/proxy/...` API-сервер авторизует как `nodes/proxy`, а к kubelet идёт со своим сертификатом (kubelet делает SubjectAccessReview для API-сервера, не для клиента). Узкие подресурсы работают только при прямом обращении к 10250. **Исправлена строка 211 в 01-2**: было «право на такой запрос с 1.36 выдают узким подресурсом `nodes/configz`, а не `nodes/proxy`» → «запрос через прокси API-сервера требует `nodes/proxy`; узкий `nodes/configz` (с 1.36) действует только при прямом обращении к kubelet на порт 10250 (06-1)».
2. §4 «Права на kubelet»: было «с 1.36 kubelet проверяет узкие подресурсы metrics, stats, pods, configz, healthz, log; раньше монитор вынужден был получать nodes/proxy ради метрик» → `/metrics`, `/stats`, `/logs` (а также `/spec`, `/checkpoint`) проверялись отдельными подресурсами и до 1.32; KubeletFineGrainedAuthz (alpha 1.32, beta 1.33, GA locked 1.36) добавил `nodes/pods`, `nodes/healthz`, `nodes/configz` с откатом на `nodes/proxy`. Добавлено предупреждение из документации kubelet: `get` на `nodes/proxy` разрешает запуск команд (WebSocket через GET) — без техники. Объяснено, почему через прокси API-сервера нужен `nodes/proxy`.
3. Лаба 4 шаг 5, разбор п. 3: «что kubelet проверяет именно эти подресурсы, документировано с 1.36» → metrics/stats проверяются при прямом обращении к 10250, через прокси этой роли не хватит.
4. Лаба 4 шаг 5, ожидаемый вывод: в списке не было `admin`, `edit`, `system:aggregate-to-edit` — у них `impersonate` на `serviceaccounts` (policy.go editRules) → добавлены и разобраны.
5. §2 «Встроенные роли»: `edit` дополнена «выпускает токены и подменяет любой SA namespace»; `admin` «без квот и самого namespace» → «без записи в квоты и в сам namespace» (rbac.md).
6. §2 «Способы аутентификации»: «если не узнал никто, а аноним включён — `system:anonymous`» → аноним только для запроса без учётных данных; неверные учётные данные дают 401 всегда (authentication.md). Схема 3 и подпись: «способы работают параллельно» → «пробуются по очереди, порядок не гарантирован».
7. §2 токен SA: «поля GA в 1.32–1.33» → `jti` и имена в claims — GA 1.32, привязка к узлу — GA 1.33 (ServiceAccountTokenJTI/PodNodeInfo 1.32, NodeBinding 1.33). Добавлено: 3607 — метка, `--service-account-extend-token-expiration` (по умолчанию вкл.) продлевает такой токен до года; то же — в §6.
8. §3 reconcile: «обновляет правила» → добавляет недостающие правила и пересоздаёт привязку при смене `roleRef`; лишнее убирает только с `--remove-extra-permissions/--remove-extra-subjects`.
9. §3 OIDC: «берёт ключи по адресу `<issuer>/.well-known/openid-configuration`» → находит ключи через этот документ.
10. §3 external signer: добавлен флаг `--service-account-signing-endpoint`; добавлена фраза из исследования про `podCertificate` (beta выкл. в 1.36, GA в 1.37).
11. §4 whoami: «для SA — имя и UID самого SA, пода и узла» → `credential-id` = `JTI=…`, у токена пода — имя и UID пода и узла (service-accounts-admin.md).
12. §4 can-i для анонима: уточнено почему не работает — impersonation.go не добавляет `system:authenticated` при подмене на `system:anonymous`, а `system:basic-user` (право на SelfSubjectAccessReview) привязан только к `system:authenticated`; `can-i --as system:anonymous` получит отказ. Вывод писателя верен.
13. §4 constrained impersonation: «глаголы вида `impersonate-on`» → `impersonate:user-info` и `impersonate-on:user-info:list` (user-impersonation.md; beta, вкл. в 1.36).
14. §4 опасные права: «approve на CSR» → `update` на `certificatesigningrequests/approval` + `approve` на `signers`.
15. Лаба 3 шаг 2, декодирование JWT: `base64 -d 2>/dev/null` без дополнения `=` ненадёжно (может отказать или оборвать JSON в зависимости от реализации base64) → функция дописывает `=` до длины, кратной 4; строка таблицы разбора заменена.
16. Лаба 2 шаг 5: `error: failed to create role: …` → `Error from server (Forbidden): …` (kubectl create_role.go возвращает ошибку сервера без обёртки); подпись «вторая ошибка — одна строка» исправлена (в сообщении настоящий перевод строки перед `{APIGroups…}`, rule.go).
17. Лаба 3 шаг 5: в выводе не было сообщений `set-cluster/set-credentials/set-context` → добавлены. Шаг 4: неверная подпись «ошибка перенесена» убрана.
18. Лаба 4 шаг 2: подпись «убраны AGE и NAMESPACE» → «оставлены NAME, ROLE, GROUPS». Шаг 3: выдуманное число `11` → `…`, в разборе — «число зависит от кластера».

## 2. Читаемость

До: 323 предложения, средняя 11,7 слова, коротких 37 %, нарушений 0. После: 330 предложений, средняя 11,8, коротких 36 %, нарушений 0 (одно длинное предложение, появившееся при правке, разделено). Строки кода ≤100 символов, эмодзи нет, блоки §3 и §3.2 на месте.

## 3. Подтверждено (источник)

- AuthenticationConfiguration `apiserver.config.k8s.io/v1`: `jwt[].issuer.url/audiences`, `claimValidationRules`, `claimMappings.username/groups.expression`, `userValidationRules`, `anonymous.enabled/conditions[].path`; GA 1.34; горячая перезагрузка; `--authentication-config` с `--oidc-*` — ошибка запуска; секция `anonymous` несовместима с `--anonymous-auth` (authentication.md, kube_features.go). Выражение с `claims.email` требует проверки `email_verified` — в примере есть.
- AuthorizationConfiguration v1: `authorizers[].type/name`, webhook `timeout`, `authorizedTTL` (по умолч. 5m), `unauthorizedTTL` (30s), `failurePolicy` Deny/NoOpinion, `subjectAccessReviewVersion`, `matchConditionSubjectAccessReviewVersion`, `connectionInfo.type: KubeConfigFile`, `matchConditions` внутри webhook; несовместимость с `--authorization-mode`; GA 1.32 (authorization.md).
- Авторизация по селекторам GA 1.34 (AuthorizeWithSelectors, AuthorizeNodeWithSelectors); external signer GA 1.36; constrained impersonation alpha 1.35 / beta (вкл.) 1.36; KubeletFineGrainedAuthz GA locked 1.36 (kube_features.go release-1.36).
- `system:masters` — PrivilegedGroups-авторизатор перед цепочкой (kubeapiserver/authorizer/config.go; authorization.md).
- `system:public-info-viewer`: `/livez`, `/readyz`, `/healthz`, `/version` для authenticated и unauthenticated; `system:basic-user` и `system:discovery` — только authenticated (policy.go).
- `system:kubelet-api-admin` включает nodes/proxy, metrics, stats, log и с FG — pods, healthz, configz; контроллеру агрегации — `escalate` на clusterroles (policy.go, controller_policy.go).
- Токены: по умолчанию 1 ч, в поде `expirationSeconds: 3607`, замена при 80 % TTL или старше 24 ч (configure-service-account.md); extend до года (authentication.md, service-accounts-admin.md); токены-Secret перестали создаваться в 1.24; привязанный под — проверка UID и deletionTimestamp (claims.go); client-go перечитывает файл токена раз в минуту (token_source.go).
- CSR: `expirationSeconds` минимум 600, срок = min(expirationSeconds, `--cluster-signing-duration`); `kube-apiserver-client` никогда не одобряется автоматически; право одобрения — `update` на `…/approval` + `approve` на `signers` (certificate-signing-requests.md).
- Кеш webhook токенов 2 мин (`--authentication-token-webhook-cache-ttl`, authentication.md).
- RBAC: неизменяемый `roleRef`, `resourceNames` и `metadata.name` для list/watch, защита от эскалации и текст ошибки, роли admin/edit/view, метки агрегации, reconcile (rbac.md, rule.go).
- Формат `auth whoami` для сертификата (`X509SHA256=…`) — реальный вывод в 00-2.

## 4. Не подтверждено (для 00-plan)

- Значение `--cluster-signing-duration` по умолчанию 8760h — по памяти справки kube-controller-manager, в скачанных страницах не найдено.
- TokenRequest: минимум 600 с и умолчание 3600 с при `kubectl create token` без `--duration` — по API-справке по памяти.
- Вывод `kubectl get csr` (колонки REQUESTOR, REQUESTEDDURATION, `Approved,Issued`) и вывод `openssl` (формат `subject=CN = …` OpenSSL 3) — ожидаемые.
- Таблица `can-i --list` (состав и порядок строк) — ожидаемая.
- Состав claims токена в работе 3 и issuer `https://kubernetes.default.svc.cluster.local` для kind — по документации и умолчаниям kubeadm, не прогоном.
- Лаба 3: 401 после удаления привязанного пода через `sleep 5` (зависит от задержки кеша API-сервера); тег `curlimages/curl:8.11.1` и чтение токена непривилегированным пользователем образа.
- Лаба 4: списки ролей и привязок (шаги 2–5) — ожидаемые, зависят от версии и дистрибутива.
- Не добавлено из исследования: «1.37 — ограничить nodes/log, стартовые логи kubelet содержат конфиг» (CL37) — источник не сверен.
