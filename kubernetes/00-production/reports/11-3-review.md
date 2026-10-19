# 11-3 Сеть и DNS по слоям: отчёт ревьюера

Файл: /home/user/claude/kubernetes/11-troubleshooting/11-3-network-dns.md. Дополнительно правлен /home/user/claude/kubernetes/03-networking/03-4-gateway-api.md (§2 и таблица кодов; правка уже попала в промежуточный коммит ведущего d64d858).

## Найденные ошибки (было → стало)

1. §4 panic mode: «гипотеза, исходник сверен по main, 1.9.2 не сверялся» → подтверждённая цепочка по исходникам Envoy Gateway release/v1.9 и Envoy: неготовый эндпоинт передаётся со статусом DRAINING (условие: `serving: false` или `terminating: true`, без этих полей — `ready: false`); Envoy исключает DRAINING-хост из балансировки и из расчёта доли здоровых; при 0 готовых доля 0 % < 50 % → паника → запросы на все хосты → 504 через 15 с. Добавлены схема 3 (1 из 2 готов / 0 из 2 / пустой срез) и определение DRAINING. Лабораторная схема перенумерована в «Схема 4».
2. §4 admin-интерфейс: «порт 19000 — по памяти» → `127.0.0.1:19000` внутри пода (bootstrap.go), доступ через `kubectl port-forward`; вывода нет — так и сказано.
3. §4 флаги: UH, UF, UO указаны с кодом 503, UT — 504, NR — 404, UPE — ошибка протокола в ответе бэкенда (substitution_formatter.rst).
4. §4 502: «документация связывает с UPE (по памяти)» → факт: router.cc отдаёт 502 (BadGateway) при сбросе с причиной ProtocolError, остальные сбросы — 503.
5. §4 504: «Envoy ждёт ответ маршрута 15 с» → уточнено: Envoy Gateway не задаёт таймаут маршрута без настройки в HTTPRoute/политике, действует умолчание Envoy RouteAction.timeout 15 с.
6. §4 таблица: слой «1, 5» у 504 → «5, приложение» (504 на стенде давали DNS и зависимость приложения, не сеть пода).
7. §3 таблица разбора `kubectl debug`: `--target=api` «делить пространства имён» → «видеть процессы контейнера api» (по docs: --target задаёт process namespace; сеть пода общая и так). Добавлена фраза: профиль netadmin даёт NET_ADMIN и NET_RAW (profiles.go).
8. §6 «Проба готовности — период 10 с … действуют на стенде» → умолчания Kubernetes, а у orders-api на стенде `periodSeconds: 2` (00-1, манифест orders-api).
9. §5 DNS: разложение 20 с «5 с × 2 попытки × несколько search-доменов» (арифметика не сходится и не подтверждена) → «20 секунд, кратно таймауту glibc 5 с на попытку (03-3 §5)».
10. §2 и §3: повторные определения MTU и conntrack (определены в 03-1) → без жирного, со ссылкой.
11. §2: «срез строится по selector'у и условиям ready и serving» → условия отмечают готовность адресов, а не отбирают их (неготовые адреса в срезе есть).
12. ЛР1 шаг 3: разбор ссылался на вывод `get pods`, которого нет в блоке → помечено, что вывод сокращён.
13. 03-4 §2 (противоречие): «в кластер попадают только готовые поды» → «Неготовые поды контроллер тоже передаёт, но с пометкой «draining», и Envoy не шлёт им запросы, пока готов хотя бы один под; когда готовых не остаётся, включается режим паники (11-3 §4)». В таблице кодов 03-4: 503 «у бэкенда нет готовых подов» → «у бэкенда нет адресов».

## Читаемость

- До: 207 предложений, средняя 11,6 слов, коротких 37 %, нарушений 0.
- После: 217 предложений, средняя 11,7 слов, коротких 35 %, нарушений 0 (по ходу правок исправлены одно предложение 30 слов и абзац из 6 предложений).

## Формат и план

- Блоки §3 по порядку; эмодзи, «Проверено», вопросов, чеклистов нет; после каждого `##` есть фраза; лаба по §3.2 (Риски, Цель, Что понадобится, Схема, шаги, Итог, Уборка, Вопросы); строки кода ≤100.
- Соответствие 00-plan §4: одна работа «Методика на четырёх опорных поломках» — совпадает; research-coverage п. «модуль 11 против 12-2» учтён (4 опорные поломки, остальные — в 12-2).
- Ссылки 03-1 §2/§5, 03-2 §2–§5, 03-3 §2/§4/§5/§6, 03-4 §2/§3/§5, 03-6 §1/§2/§3/§5, 02-1 §4, 02-5 — разделы существуют.
- Безопасность: уборка трогает только `lab-11-3`, `t-deny-ingress` и возвращает манифесты orders; `pkill`, `apt autoremove` нет.

## Подтверждено (источник)

- Envoy Gateway release/v1.9 `internal/gatewayapi/route.go` getIREndpointsFromEndpointSlice: draining = Terminating || !Serving, иначе Ready=false; эндпоинты не пропускаются.
- Envoy Gateway release/v1.9 `internal/xds/translator/cluster.go`: Draining → `HealthStatus_DRAINING`; HealthyPanicThreshold не задаётся по умолчанию (комментарий «50% is the Envoy default»); `tcpClusterPerConnectTimeout = 10 * time.Second`.
- Envoy Gateway release/v1.9 `internal/xds/translator/route.go`: таймаут маршрута ставится только при настройке.
- Envoy Gateway release/v1.9 `internal/xds/bootstrap/bootstrap.go`: EnvoyAdminAddress 127.0.0.1, EnvoyAdminPort 19000.
- Envoy main `source/common/upstream/upstream_impl.cc`: DRAINING → флаг EDS_STATUS_DRAINING; excludeBasedOnHealthFlag включает EDS_STATUS_DRAINING. `load_balancer_impl.cc`: host_count = hosts − excluded, при 0 доля 0 %; паника → AllHosts.
- Envoy docs panic_threshold.rst: порог 50 %, 0 % отключает, тогда 503. route_components.proto: timeout по умолчанию 15 s. substitution_formatter.rst: флаги UH/UF/UO/UC/UR — 503, UT — 504, NR — 404, UPE — protocol error. router.cc: ProtocolError → 502.
- kubectl `pkg/cmd/debug/profiles.go`: netadmin добавляет NET_ADMIN и NET_RAW; docs debug-running-pod: --target — process namespace.
- 00-1 манифест orders-api: контейнер `api`, readinessProbe periodSeconds 2; каталог `~/lab/k8s/orders-api/k8s/` содержит Service и HTTPRoute.

## Не подтверждено (для 00-plan)

- Panic mode на стенде: admin `/clusters` и `/config_dump` не открывались; версия Envoy в поставке EG 1.9.2 сверена по ветке main Envoy, не по её релизной ветке.
- Строки `nameserver 10.96.0.10` и `options ndots:5` в выводе resolv.conf (ЛР1 шаг 5) — не из прогона, стандартные для kind.
- Вывод функции `R` получен старой командой (getent в цикле), новая форма функции не запускалась.
- Ожидаемые служебные строки kubectl (`condition met`, `created/deleted/patched`, `No resources found`, `unchanged` в уборке) не из прогона.
- Шаги 1–4: запрос идёт с хоста на 127.0.0.1:8088, в старом прогоне — из сети Docker; времена ответа могут немного отличаться.
- Команда `kubectl debug … --profile=netadmin --target=api -- tcpdump` — без вывода.
- 20 с до `Temporary failure in name resolution` — из старого прогона, разложение по попыткам не выведено.
