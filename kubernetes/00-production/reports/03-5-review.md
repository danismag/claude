# Ревью 03-5 «TLS и миграция с Ingress»

Файл: /home/user/claude/kubernetes/03-networking/03-5-tls-ingress-migration.md
Копия до правок: /tmp/claude-0/-home-user-claude/740afa2c-c313-5763-bb73-bdca3fdc2abb/scratchpad/rv035/part-before.md
Источники (скачаны в scratchpad/rv035): gateway-api main apis/v1 (backendtlspolicy_types.go, gateway_types.go, httproute_types.go); ingress2gateway README и блог 1.0 (kubernetes/website 2026/ingress2gateway-v1-0-release.md); cert-manager website usage/certificate.md, usage/gateway.md, acme/http01; cert-manager v1.21.2 pkg/apis/config/controller/v1alpha1/types.go и pkg/metrics/metrics.go; letsencrypt docs/rate-limits.md; ingress-nginx configmap.md и annotations.md; Envoy Gateway v1.9 tasks/security/backend-tls.md; старая часть e755ced:03-4.

## Найденные ошибки (было → стало)

1. Listener HTTPS «режим Passthrough пересылает как есть» → Passthrough допустим только у listener с протоколом TLS; для HTTPS API требует Terminate (XValidation в gateway_types.go).
2. Frontend mTLS «на listener» → в `spec.tls.frontend` Gateway (default + perPort), режим по умолчанию AllowValidOnly.
3. `enableGatewayAPI: true` → в 1.21.2 поле помечено Deprecated, новое — `gatewayAPI.enabled`; в лабе values переведены на `gatewayAPI: {enabled: true}`, в теории упомянуто старое как устаревшее, но рабочее (на нём был реальный прогон).
4. «через сниппеты работала цепочка CVE-2025-1974» → убрано (IngressNightmare — внедрение конфигурации через аннотации и admission webhook, не configuration-snippet).
5. `backend-protocol` «включал HTTP/2 к бэкенду» → задаёт протокол к бэкенду (HTTPS, GRPC…), по умолчанию HTTP.
6. ЛР1 шаг 6: гонка `wait Ready` сразу после удаления секрета → цикл `until get secret`, затем wait; DATA 2 → 3 (issuer типа ca добавляет `ca.crt`); добавлено, что для ротации — `cmctl renew` (документация cert-manager не рекомендует удалять Secret).
7. ЛР1 шаг 2: в выводе `helm list` не было колонки UPDATED → добавлена с «…», вывод назван ожидаемым.
8. ЛР1 уборка: противоречивый совет «не удаляйте ns при переходе к работе 2» (работа 2 делает `create ns`) → удалён; «сквозной сценарий» → «вход стенда работает».
9. ЛР2 шаг 5: добавлено — ConfigMap без ключа `ca.crt` тоже InvalidCACertificateRef; при всех неверных ссылках Accepted=False NoValidCACertificate (спецификация).
10. ЛР3: Go 1.22 → 1.25.5 (README ingress2gateway); Ubuntu 24.04 golang старый — бинарник из релизов.
11. ЛР3 шаг 4: выдуманный формат предупреждений → формат из блога 1.0 (WARN/INFO-рамки, сокращено).
12. ЛР3 шаг 5: «dry-run=server покажет ошибку на Gateway с неизвестным классом» — неверно (API-сервер класс не проверяет) → исправлено; grep сужен, ожидаемый вывод приведён к структуре из блога (имена Gateway=класс, HTTPRoute <ingress>-<host>, -ssl-redirect, 308) + строки dry-run.
13. Метки проверки: «Первая половина работы выполнена на стенде, её вывод реальный» и «на стенде не снимался» → убраны, оставлены фразы «вы выполняете сами, результаты — ожидаемые».
14. «Около 100 МБ образов» (не подтверждено) → «четыре образа cert-manager»; время лаб в метаданных 1,5 → 2,5 ч; «около 30 аннотаций» → «больше 30»; «47 дня» → «47 дней»; ссылки на 03-4 дополнены разделами (§2, §3).

## Дополнение теории (было ~1,5 тыс. слов → ~3,6 тыс. с заголовками)

Новые подразделы: «Выбор сертификата по SNI» (filter chains, порядок exact > wildcard > без hostname, сброс без кода, клиент по IP, 404/421, ловушка wildcard Gateway API vs TLS); «Цепочка доверия и промежуточные CA» (порядок в tls.crt, ca.crt, ошибка curl/Go/Java); «Выпуск через ACME: HTTP-01 и DNS-01» (ClusterIssuer с gatewayHTTPRoute, решатель на 8089, проверка распространения); «Срок, продление и ротация» (2/3 срока, rotationPolicy Always с 1.18, что видит клиент, pinning); «Редирект на HTTPS и HSTS» (RequestRedirect с sectionName, порт 443, код 302 по умолчанию, 307/308 Extended, приоритет HTTP-01; HSTS через ResponseHeaderModifier); «Что видит клиент» (openssl s_client -servername -showcerts); «Выпуск через ACME застрял» (backoff 1 ч → 32 ч, cmctl renew, лимит 5 неудачных проверок/ч); «Лимиты Let's Encrypt» (50/7 д, 5 дубликатов/7 д, 5 ошибок/ч, 300 заказов/3 ч, ARI освобождён). В «переезде» добавлены HSTS и 308 по умолчанию у ingress-nginx; список непереводимого ingress2gateway перенесён в §5. Структура Ingress перенесена в §1, чтобы в разделах было 3–5 подразделов.

## Читаемость

До: 254 предложения, средняя 12,5 слова, коротких 32 %, нарушений 1 (предложение 26 слов).
После: 317 предложений, средняя 12,5 слова, коротких 30 %, нарушений 0. Разделены 4 длинных предложения, код убран из ячейки таблицы §5, пары «понятие — значение» в §6 оформлены списками с жирным ключом.

## Подтверждено (источник)

- BackendTLSPolicy v1: targetRefs (до 16, group "" Service, sectionName), caCertificateRefs до 8 (ConfigMap с ключом ca.crt — Core), wellKnownCACertificates System (одно из двух обязательно), hostname = SNI + проверка, subjectAltNames до 5, условия Accepted/ResolvedRefs, причины InvalidCACertificateRef/NoValidCACertificate/InvalidKind, 5xx при неверном CA — gateway-api apis/v1/backendtlspolicy_types.go.
- Listener до 64, certificateRefs до 64; ResolvedRefs: InvalidCertificateRef/RefNotPermitted; Passthrough только для TLS; правило «longest matching SNI», порядок exact > wildcard > пусто, 421/404; clientCertificateRef в spec.tls.backend; frontend AllowValidOnly — gateway_types.go.
- RequestRedirect: default 302, enum 301/302/303/307/308, порт по схеме 443 — httproute_types.go.
- Envoy Gateway 1.9: BackendTLSPolicy с ConfigMap, Secret, ClusterTrustBundle — EG v1.9 backend-tls.md.
- ingress2gateway 1.0: 20.03.2026, >30 аннотаций, --input-file/--providers/--emitter envoy-gateway, go install @v1.0.0 → $(go env GOPATH)/bin, Go 1.25.5+, gatewayClassName из ingressClassName, формат предупреждений, ssl-redirect 308, regex (?i)….* — README и блог.
- cert-manager: срок 90 д, продление на 2/3, минимум 1 ч и 5 мин, rotationPolicy Always с 1.18, удаление Secret не рекомендуется (cmctl renew) — usage/certificate.md; gateway-shim: требования к listener, тот же namespace, рестарт после установки CRD — usage/gateway.md; HTTP-01 gatewayHTTPRoute, порт 8089, HTTPRoute Exact path — acme/http01; backoff 1 ч / 32 ч, gatewayAPI.enabled (enableGatewayAPI Deprecated) — v1.21.2 types.go; метрики certificate_expiration_timestamp_seconds, certificate_ready_status — v1.21.2 metrics.go.
- Let's Encrypt: 50 / 5 / 5 в час / 300 за 3 ч, ARI освобождён — rate-limits.md.
- ingress-nginx: hsts true, max-age 31536000, includeSubDomains true, ssl-redirect true (308), proxy-body-size 1m, proxy-read-timeout 60, allow-snippet-annotations false, backend-protocol значения — configmap.md, annotations.md.
- Реальный вывод ЛР1 шаги 3–5 и ЛР3 шаги 1–2 совпадает со старой частью e755ced (notAfter/renewal, TLSv1.3, h2, пустой subject, CN=lab-ca, 000 + errormsg, No resources found, {"loadBalancer":{}}, 404).
- Ретайрмент ingress-nginx 24.03.2026, Gateway API 1.4 (06.10.2025), TLSRoute v1 в 1.5, PodCertificateRequest/ClusterTrustBundle GA 1.37, RBAC cert-manager 1.21 — research-k8s-changes.md.

## Осталось неподтверждённым (для 00-plan)

- ЛР1 шаг 1 (вывод apply/rollout для маршрута shop на Service api) — собран, не из прогона.
- ЛР1 шаг 2: вывод `helm list` и работа значения `gatewayAPI: {enabled: true}` (прогон был с `enableGatewayAPI`).
- ЛР1 шаг 4: порядок условий в строке `https-shop: attachedRoutes=1 Programmed=True …` при новом jsonpath.
- ЛР1 шаг 6 (удаление секрета и восстановление, DATA 3) — ожидаемый.
- ЛР2 целиком — ожидаемая: 503 без политики и при неверном hostname, тексты условий статуса BackendTLSPolicy в Envoy Gateway 1.9.2, работа Python-сервера.
- ЛР3 шаг 2: таблица `get ingress` (колонки и PORTS 80) восстановлена по старому тексту.
- ЛР3 шаги 3–5: ingress2gateway не запускался; имена объектов, тексты предупреждений, наличие доп. объектов эмиттера envoy-gateway и вывод dry-run — ожидаемые.
- Теория: Envoy Gateway собирает listener одного порта в один слушатель Envoy с filter chain на hostname — по устройству EG, документацией не сверено.
- Теория: Envoy Gateway подхватывает обновлённый Secret без перезапуска — по устройству EG (xDS), документацией не сверено.
- Теория: сроки CA/B Forum (SC-081: 200/100/47 дней с 15 марта 2026/2027/2029) — по памяти, первоисточник не скачан.
- Теория: поддержка ARI в cert-manager 1.21 — из исследования, release notes не сверены.
