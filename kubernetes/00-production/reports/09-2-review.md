# Ревью 09-2 «Admission webhooks и finalizers»

Файл: /home/user/claude/kubernetes/09-extending/09-2-webhooks-finalizers.md. Режим «только текст»: команды лабораторных не запускались. Источники скачаны в scratchpad (src092/): код kubernetes release-1.36 (namespace controller, kube-controller-manager core.go, client-go discovery, kube-aggregator handler_discovery/handler_proxy/apiserver.go, admission webhook generic/dispatcher/predicates, metrics.go, admissionregistration defaults/validation, kube_features), kubernetes/website main (extensible-admission-controllers.md, admission-webhooks-good-practices.md), cert-manager website (ca-injector.md).

## 1. Ошибки: было → стало

- Лаба 2, шаг 4 «Почему Ignore не ждал 5 с, не выяснили» → объяснено по механике: сервер `sleep 3600 | nc -l -p 443` в цикле молчит только на ПЕРВОМ соединении; после него `nc` не слушает порт, а `while` не перезапускает его, пока не кончится `sleep 3600` (оболочка ждёт весь конвейер). Шаг 3 (Fail) забрал первое соединение → таймаут 5232 мс; шаг 4 (Ignore) получил сброс соединения → 235 мс. Добавлено: при молчащем сервере Ignore тоже ждал бы весь таймаут.
- Лаба 2, шаг 6 (timeoutSeconds=2): по той же механике ожидаемый `context deadline exceeded` за ~2 с не получился бы (порт не слушается → быстрый отказ). Стало: шаг сначала пересоздаёт под `hang` (Service находит его по `app=hang`), добавлена таблица разбора команды (её не было), вывод — ожидаемый без придуманного числа (`2… ms`).
- §3 timeoutSeconds «при Fail каждый запрос ждёт всё это время» → «и при Fail, и при Ignore»: политика применяется после сбоя вызова (docs, раздел Timeouts: «If the timeout expires… ignored or rejected based on the failure policy»).
- §5 «Вебхук недоступен»: добавлен разбор скорости отказа — Service не найден (кэш API-сервера, без соединения), порт не слушается / нет эндпоинтов (`connection refused` / `no endpoints available`, быстро), сервер молчит (полный таймаут); вывод: Ignore не ускоряет вызов. Подпись схемы 5 дополнена.
- §5 APIService «код и стенд расходятся, причина не найдена» → изложена подтверждённая цепочка по коду 1.36: агрегатор помечает версию группы `Stale` при ошибке запроса discovery (handler_discovery.go syncAPIService; 503 из proxy при недоступном/неразрешимом сервисе) → client-go `convertAPIGroup` кладёт Stale в failedGVs → `ServerPreferredResources` возвращает `ErrGroupDiscoveryFailed` → `deleteAllContent` удаляет найденное, пишет `NamespaceDeletionDiscoveryFailure`/`DiscoveryFailed`, возвращает ошибку → `Delete` не снимает finalizer → `AddRateLimited` (5 мс…60 с). Объяснение стенда помечено гипотезой: кэш discovery в агрегаторе обновляется при изменении APIService и раз в 60 с после успешного обновления (`discoveryRefreshInterval = 1m`); если последний запрос к metrics-server прошёл, пока под завершался, группа оставалась `Current`, и namespace удалился внутри окна (~20 с после scale 0). Старое «ресурсы только для чтения» — верно лишь при Current: типы без `delete` отфильтровываются (`SupportsAllVerbs{delete}`).
- Лаба 4: шаг 2 не имел таблицы «часть команды → значение» → добавлена; разбор переписан под код и гипотезу; добавлен необязательный вариант проверки гипотезы (пауза 90 с) с пометкой «не проверяли»; уборка — что делать, если namespace ещё в Terminating; «литература» заменена на «код контроллера».
- §3 sideEffects «dryRun-запрос не отправляют вебхуку без такой заявки, запрос падает» → в v1 допустимы только None/NoneOnDryRun, оба обещают отсутствие следов при dryRun; вебхук с NoneOnDryRun сам проверяет `dryRun`.
- §3 matchPolicy «вызывает и для старой версии API, если правило для новой» → «для того же ресурса через другую группу или версию, с переводом объекта в версию правила» (docs).
- §3 matchConditions: уточнено — любое false → пропуск; ошибка без false → решает failurePolicy (docs).
- §2 исключение конфигураций: добавлено, что исключены шесть типов admissionregistration.k8s.io — обе конфигурации вебхуков, VAP, MAP и их привязки (predicates/rules.IsExemptAdmissionConfigurationResource, generic/webhook.go Dispatch).
- §2 удаление namespace: «контроллер ставит фазу Terminating» → фазу и deletionTimestamp ставит API-сервер; контроллер ждёт 5 с (namespaceDeletionGracePeriod); finalizer `kubernetes` — в `spec.finalizers`; удаляются только типы с операцией delete. Повторные определения Discovery и APIService заменены ссылками (00-2, 09-1); введено понятие freshness (Current/Stale) агрегированного discovery.
- §4 условия: добавлено пятое — NamespaceDeletionGVParsingFailure; причина DiscoveryFailed; уточнено, почему фильтруют `True`. Метрики: добавлены `apiserver_admission_webhook_request_total` и верхняя корзина гистограммы 25 с.
- §6: умолчания selectors `{}`; `.static.k8s.io` — резерв для manifest-based admission (alpha 1.36, действует при включённой функции); warnings — «может обрезать / сверх 4096 отбрасывает»; новый подраздел «Сроки контроллера namespace» (5 с, оценка 15 с → повтор ~8 с, ошибки 5 мс…60 с, поды — половина оставшегося grace).
- §1: добавлена короткая граница «VAP / MAP / вебхук» (research 09-2: MAP GA 1.36 как замена вебхукам).
- Ссылки: cert-manager 03-4 → 03-5 (метаданные и §2); Argo CD finalizer 08-2 → 08-1.
- Лаба 2 «Риски»: «ждёт по 5 секунд» → «до 5 секунд»; строка «Итог» шага 4 уточнена.

## 2. Читаемость

До: 268 предложений, средняя 11,5 слова, коротких 38 %, нарушений 0. После правок фактов: 2 нарушения (предложение 27 слов; список из 8 пунктов) — исправлены. Итог: 287 предложений, средняя 11,7, коротких 36 %, >25 слов 0, нарушений 0, жирный 4,2 %. Строки кода ≤100 символов. Проза теории ~3,2 тыс. слов (было ~2,7).

## 3. Подтверждено (источник)

- Умолчания v1: timeoutSeconds 10 (1–30), failurePolicy Fail, matchPolicy Equivalent, selectors `{}`, reinvocationPolicy Never, service port 443 — defaults.go; path «/» — docs; sideEffects и admissionReviewVersions обязательны — validation.go; matchConditions ≤64 — validation.go, docs.
- Исключение конфигураций вебхуков/VAP/MAP из вызова вебхуков — predicates/rules/rules.go, generic/webhook.go.
- Validating — параллельно (validating/dispatcher.go, wg); порядок mutating не гарантирован, идемпотентность — good-practices.
- failurePolicy: виды сбоев, явный отказ не сбой — docs Failure policy; таймаут → политика — docs Timeouts.
- Метрики: webhook_rejection_count (error_type calling_webhook_error/no_error/apiserver_internal_error), webhook_fail_open_count, webhook_admission_duration_seconds (корзины до 25), webhook_request_total — metrics.go, docs.
- Условия namespace и причины (DiscoveryFailed, SomeResourcesRemain, SomeFinalizersRemain, ContentDeletionFailed, GroupVersionParsingFailed); формат сообщений совпадает с реальным выводом лабы 3 — status_condition_utils.go.
- Ordered namespace deletion: beta 1.30 (off), 1.33 (on), GA 1.34 locked; поды первыми, остальное ждёт — kube_features.go, namespaced_resources_deleter.go.
- MAP: alpha 1.32, beta 1.34 (off), GA 1.36 (on); ManifestBasedAdmissionControlConfig alpha 1.36 — kube_features.go.
- Цепочка APIService → Stale → ErrGroupDiscoveryFailed → finalizer не снимается — handler_discovery.go, handler_proxy.go, apiserver.go (agg), aggregated_discovery.go, discovery_client.go, kcm core.go, namespace_controller.go, namespaced_resources_deleter.go.
- cainjector заполняет caBundle Validating/MutatingWebhookConfiguration, CRD, APIService по `cert-manager.io/inject-ca-from: <ns>/<Certificate>` — cert-manager ca-injector.md.
- Warnings 256/4096, `.static.k8s.io` — docs; виртуальные ресурсы 1.37 (ExcludeAdmissionWebhookVirtualResources) — docs.

## 4. Не подтверждено (для 00-plan §7)

- 09-2 §5/лаба 4: причина удаления namespace при недоступном APIService на 1.36.1 — гипотеза (кэш discovery Current до 60 с), не проверена.
- 09-2 лаба 4: вариант с паузой 90 с (ожидаемое зависание с NamespaceDeletionDiscoveryFailure) не проверялся.
- 09-2 лаба 2: механика «nc молчит только на первом соединении» выведена из поведения sh/busybox nc, на стенде не проверена (согласуется с 5232/235 мс).
- 09-2 лаба 2 шаг 6: пересоздание `hang` и таймаут 2 с — ожидаемый вывод.
- 09-2 лаба 2 шаг 5: числа счётчиков 15/2 — из старого сквозного прогона, в новой разбивке другие.
- 09-2 лаба 1 шаг 3: таблица `get deploy d1` восстановлена по строке «ready: 0/1»; строка события — по формату describe.
- 09-2 лабы 1–2: новые имена lab-09-2-policy и метка lab-09-2/policy=on — нужен перепрогон.
- 09-2 лаба 3: вывод create/patch и NotFound после снятия finalizer — стандартный, не из прогона.
- 09-2 §6: GA 1.30 для matchConditions вебхуков, VAP и агрегированного discovery — по памяти (feature gates уже удалены из кода 1.36).
- 09-2 §6: 1.37 «балансировка вызовов между бэкендами» — по research CL37, детали не сверены.
- 09-2 §5: «объекты вернутся при повторном создании namespace после /finalize» — из старой части, не проверено.
- 09-2 §5: «нет эндпоинтов → connection refused / no endpoints available» — по механике (REJECT kube-proxy / резолвер эндпоинтов), на стенде не воспроизводилось.
