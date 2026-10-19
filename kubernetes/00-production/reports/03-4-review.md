# Ревью 03-4 Gateway API
Файл: /home/user/claude/kubernetes/03-networking/03-4-gateway-api.md. Скрипт правок: scratchpad/rv034/fix034.py.

## Найденные ошибки (было → стало)
- RequestRedirect: «код 301 или 302» → «301, 302, 303, 307 или 308, по умолчанию 302» (enum в apis/v1/httproute_types.go v1.6.1).
- Версии §6: «Envoy Gateway 1.9.x нужны CRD 1.6, 1.9.0 пропустить в пользу 1.9.1» → «по матрице совместимости EG 1.9 — Gateway API 1.6.1, Kubernetes 1.33–1.36; без CRD 1.6 EG 1.9 молча пропускает TCPRoute/UDPRoute; на стенде 1.9.2». Совет пропустить 1.9.0 в официальных release notes не найден — убран.
- 1.4: «появилось поле supportedFeatures» → «стабильными стали BackendTLSPolicy, имена правил, supportedFeatures».
- 1.5: CORS был «добавлен», стал «стабильным (Standard, поддержка Extended)»; добавлено «требует Kubernetes 1.30+».
- 1.6: добавлено «v1alpha2 TCPRoute/UDPRoute устарела».
- Лимиты: добавлены 32 parentRefs, 128 условий на все правила, 16 фильтров, >64 listener'ов через ListenerSet.
- Таймауты: «дефолты сверяйте» → Envoy 15 с на маршрут, 504 при превышении; request ≥ backendRequest.
- «503 на стенде не воспроизводился» (метка проверки в тексте) → «коды 500 и 503 задаёт спецификация» (500 — недопустимый бэкенд, 503 SHOULD — нет готовых эндпоинтов).
- Разброс: «около 9» → √(1000·0,1·0,9) ≈ 9,5 (в теории, ЛР2, итоге, вопросе); 50 %: √250 ≈ 15,8 ≈ 16, коридор 468–532 верен.
- Метка `split over 1000:`: добавлена оговорка в ЛР1 шаг 2 (в прогоне автора — `weights 90/10 over 1000:`, числа те же).
- Убраны метки «в прогоне автора этого шага не было», «первая точка измерена на стенде автора», «по вычисленному».
- ЛР3 шаг 1: строка вывода 158 знаков сокращена с «…», полный текст сообщения — в прозе.
- «весы 100/0» → «веса»; «Значения allowedRoutes по умолчанию» → «Значение»; «обход через .. невозможен» смягчено.
- Уборка: добавлено `unset T G`.
- Таблица кодов: добавлена строка 504.

## Добавлено в теорию (механика, ~300 слов)
- §2 «Контроллер и прокси»: mergeGateways в EnvoyProxy; слияние Gateway по спецификации (MAY merge onto single set of Addresses).
- §2 новый подраздел «Перевод маршрута в конфигурацию Envoy» со схемой 5: listener → listener, hostnames → virtual host, rule → route, backendRefs → cluster, адреса из EndpointSlice (routingType по умолчанию Endpoint — мимо kube-proxy), обновление по xDS без перезапуска. Схемы перенумерованы 5→11.
- §3 «Хост и путь»: заголовки Exact по умолчанию, имя без учёта регистра, до 16 заголовков, RegularExpression — реализация.
- §3 «Фильтры» → «Фильтры и таймауты»: mirror (100 % по умолчанию, percent/fraction), timeouts request/backendRequest с примером и разбором.
- Вес 0…1 000 000.
Теория теперь ~3000 слов прозы.

## Читаемость
До: средняя 12,2 слова, коротких 32 %, >25 слов 0, нарушений 1 (строка кода 158).
После: средняя 12,5, коротких 31 %, >25 слов 0, нарушений 0.

## Подтверждено (источник)
- Лимиты 16 правил/16 хостов/64 matches/16 backendRefs/16 filters/16 headers, 128 matches на маршрут, 64 listener'а, 32 parentRefs; allowedRoutes default Same; redirect default 302; path default PathPrefix "/"; header default Exact; weight default 1, 0…1000000, 0 = нет трафика; порядок приоритета; 500/503; reasons маршрута — kubernetes-sigs/gateway-api v1.6.1 apis/v1/{httproute,gateway,shared}_types.go.
- 1.4 (BackendTLSPolicy, supportedFeatures, named rules), 1.5 (ListenerSet, TLSRoute, CORS, frontend mTLS, ReferenceGrant v1, k8s 1.30+), 1.6 (TCPRoute/UDPRoute v1, 2026-06-30) — блоги kubernetes/website.
- EG 1.9 ↔ Gateway API 1.6.1, k8s 1.33–1.36 — envoyproxy/gateway site/.../matrix.md; 1.9.0 (2026-08-14) требует CRD 1.6; 1.9.1 (2026-08-28); 1.9.2 (2026-09-28) существует — release-notes/*.yaml.
- Deployment контроллера `envoy-gateway` (жёстко в charts/gateway-helm/templates/envoy-gateway-deployment.yaml); чарт ставит CRD Gateway API (crds.enabled=true).
- mergeGateways, routingType default Endpoint — api/v1alpha1/envoyproxy_types.go.
- Таймаут Envoy 15 с, 504 «upstream request timeout» — docs EG http-timeouts.
- Реальный вывод ЛР1 и ЛР2 шаг 1 (901/99, 19/1, 20/20, 302, 404), ЛР3 шаг 1 (RefNotPermitted, 500), Gateway status — старая часть e755ced.

## Не подтверждено (для 00-plan)
- ЛР1 шаг 2: строка «ResolvedRefs=True ResolvedRefs: Resolved all the Object references for the Route» — ожидаемая.
- ЛР2 шаги 2–3 (50/50, 0/100, 100/0) — ожидаемые; поведение веса 0 в EG на стенде не проверялось.
- ЛР3 шаг 2 (текст сообщения) и шаг 3 (отзыв гранта) — ожидаемые.
- Код 503 при отсутствии готовых эндпоинтов и 504 по таймауту — на стенде не воспроизводились.
- Подготовка: сборка 2.1 через build-arg (старая часть брала готовый образ), выводы rollout status/created — стандартные, не из прогона.
- Канал experimental CRD 1.6.1 — из старой части; канал CRD в чарте EG по values не определён.
- Обновление xDS без разрыва соединений — по устройству Envoy, на стенде не проверено.
