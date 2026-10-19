# Ревью 11-2. Под не работает

Файл: /home/user/claude/kubernetes/11-troubleshooting/11-2-pod-not-working.md. Копия до правок: /tmp/claude-0/-home-user-claude/740afa2c-c313-5763-bb73-bdca3fdc2abb/scratchpad/11-2-before.md.

## Найденные ошибки (было → стало)

1. Порядок шагов жизни не совпадал с порядком kubelet. Было: шаг 2 «образ», шаг 3 «конфигурация, тома, сеть»; `PodReadyToStartContainers=False` — «шаги 2–3, включая образ». По документации (Pod Lifecycle) и коду kubelet (тома → песочница и CNI → загрузка образа → конфигурация контейнера → create → start → postStart) условие становится True до загрузки образа. Стало: 8 шагов (1 планирование, 2 тома и песочница, 3 образ, 4 конфигурация, 5 запуск, 6 работа, 7 готовность, 8 остановка). Перенумерованы схема 1, условия, §5, дерево решений, разборы ЛР («Шаг жизни N», чтобы не путать с шагами работы).
2. Добавлен раздел §2 «Путь kubelet: где остаётся след» (схема 2): шаг kubelet → reason (FailedMount, FailedCreatePodSandBox, ImagePullBackOff, CreateContainerConfigError, CreateContainerError, RunContainerError, FailedPostStartHook) → где смотреть; ссылка на 01-2 §2 (схема 4). Схемы ниже перенумерованы (3 — дерево, 4 — ЛР).
3. Шаги 3–6 для init-контейнеров (`Init:ErrImagePull`, `Init:CrashLoopBackOff`) — фраза добавлена.
4. `--share-processes` «включается флагом» → по коду он по умолчанию `true`, и профиль `general` в режиме копии тоже включает общий PID. Профиль `general` в копии убирает метки, аннотации, пробы и init-контейнеры (дописаны init-контейнеры).
5. `429 — лимит запросов к реестру (08-1)` → (02-1 §5): в 08-1 о 429 ничего нет, в 02-1 §5 есть. `401/403 (04-1)` → (02-1 §5, 04-1).
6. `runAsNonRoot` → дан точный текст kubelet: `container has runAsNonRoot and image will run as root`, `image has non-numeric user (…), cannot verify user is non-root`; ссылка (06-2 §5).
7. Ссылки: `kubectl events` (00-2 §3) → (00-2 §2, карточка kubectl); отладка узла (11-4, 06-3) → (00-2 §5, 11-4); StatefulSet (02-3) → (02-3 §5); finalizer определён в 01-3 — повторное определение жирным убрано, термин единообразно «finalizer» (было «финализатор»).
8. «Остальное (ресурсы, nodeSelector…) требует пересоздания» — неверно с 1.35: ресурсы меняют подресурсом `resize` (05-2 §3). В решении pod-a убрано «поле неизменяемо», под пересоздаётся на шаге 6 работы.
9. RESTARTS: добавлен формат `3 (20s ago)` (printers.go: `"%d (%s ago)"` при restarts≠0). В сводке ЛР подпись: «AGE и время последнего перезапуска опущены» (реальный вывод старой части был без них).
10. Добавлена фраза research «ImagePullBackOff с деталями (1.32)»: сообщение `Back-off pulling image "…": <последняя ошибка>` — объясняет начальное «…» в выводе pod-b.
11. `kubectl events --for`: добавлено, что команда сортирует по времени, и флаг `--types=Warning`.
12. Образ busybox в ЛР: писатель заменил на `localhost:5001/busybox:1.37`, что требует ручного push на хосте. Возвращено `busybox:1.37` (как в реальном прогоне старой части и в 02-1) с указанием на запасной путь из подготовки 02-1. Метаданные и «Что понадобится» поправлены.
13. Добавлена ссылка 01-2 в «Опирается на».

## Читаемость

До: 174 предложения, средняя 11,8, коротких 34 %, нарушений 0. После правок (до шлифовки): 2 предложения >25 слов (новые) — разделены. Итог: 188 предложений, средняя 12,2, коротких 34 %, нарушений 0. Строки кода ≤100 символов.

## Подтверждено (источник)

- Профиль `kubectl debug` по умолчанию `general` в release-1.36; `--set-image` (только с `--copy-to`), `--share-processes` (default true), `--copy-to`, `--keep-labels`; legacy устарел, удаление планируется в 1.39 — staging/src/k8s.io/kubectl/pkg/cmd/debug/debug.go, profiles.go (release-1.36). Совпадает с 00-2 §6.
- Back-off загрузки образа: 10 с → потолок 300 с — pkg/kubelet/kubelet.go (`imageBackOffPeriod`, `MaxImageBackOff = 300s`); docs concepts/containers/images.md.
- Back-off перезапуска 10→300 с, сброс через 10 мин — pod-lifecycle.md.
- PodReadyToStartContainers: True после песочницы, сети, томов; образы — после; stable в 1.37 (feature-state v1.37) — pod-lifecycle.md; readinessGates: при готовых контейнерах и невыполненном gate — `ContainersReady=True`, `Ready=False`.
- Порядок startContainer: pull → generateContainerConfig (ErrCreateContainerConfig) → CreateContainer (ErrCreateContainer) → StartContainer (ErrRunContainer) → postStart — kuberuntime_container.go.
- Тексты runAsNonRoot — kuberuntime/security_context_others.go; реальный вывод в 06-2.
- Формат RESTARTS «N (X ago)» — pkg/printers/internalversion/printers.go.
- `kubectl events --for`, `--types`, сортировка по времени — kubectl/pkg/cmd/events/events.go.
- Сообщение ImagePullBackOff с предыдущей ошибкой — pkg/kubelet/images/image_manager.go.
- orders-api: `/ready` → 200 без `DATABASE_URL` после старта, `/healthz` → 404 (ветка else) — код в 00-1.
- Ссылки 02-1 §2/§3/§4/§5/§6, 02-5 §5, 03-1 §5, 04-2 §5, 05-1 §2/§5, 05-2 §5, 05-3 §2/§3/§5, 06-3 §5, 09-2 §5, 01-2 §5, 02-2 §4, 00-2 §3/§5/§6 — сверены по заголовкам.

## Неподтверждённое (для 00-plan §7)

- 11-2 ЛР1 шаг 6: итоговый `get pods` после исправления — ожидаемый, не снимался.
- 11-2: pod-d на `/ready` с 200 — по коду orders-api, на стенде не проверено.
- 11-2: `which server` в busybox без вывода — по поведению busybox (в старом прогоне виден только вывод `ls`).
- 11-2: тексты FailedScheduling (taint, `3 Insufficient cpu`) зависят от стенда 1+3.
- 11-2: `--previous` ответил `unable to retrieve container logs` — единичное наблюдение старого прогона.
- 11-2: событие `FailedPostStartHook` и reason `CreateContainerError` в схеме 2 — по коду kubelet, на стенде не воспроизводились.
- 11-2: ссылки на 11-1 (срок жизни событий) — часть пишется параллельно, без номера раздела.
