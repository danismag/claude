# Ревью 00-2 «Инструменты»

Файл: /home/user/claude/kubernetes/00-lab/00-2-tools.md. Отчёта писателя не было, поэтому сомнительными считались все строки вывода, которых нет в старой версии (e755ced). Коммита нет.

## Найденные ошибки (было → стало)

- Ephemeral-контейнер «делит с подом сеть и тома» (§5, схема, ответ 2 работы 3) → делит сеть, с `--target` и PID; тома `kubectl debug` не подключает (код kubectl, profiles.go).
- «Профиль general — безопасный набор прав по умолчанию» → general добавляет SYS_PTRACE; в kubectl 1.36 это профиль по умолчанию (debug.go release-1.36: default ProfileGeneral; страница kubernetes.io всё ещё пишет legacy, она устарела).
- «Профиль sysadmin включает hostPID, hostNetwork и /host» → host namespaces и /host даёт любой профиль отладки узла, sysadmin добавляет privileged (profiles.go). Поправлено в §5, таблице шага 6 и в «Рисках» работы 3.
- `--copy-to`: добавлено, что general убирает у копии метки, пробы и init-контейнеры (profiles.go).
- port-forward «слушает только 127.0.0.1» → `localhost` (127.0.0.1 и ::1).
- `kind create cluster --wait 120s` «ждёт готовности узлов» → ждёт control plane.
- crictl «хватает первых 12 знаков» → в таблице 13 знаков, принимается любое уникальное начало.
- kubectl -v: добавлен уровень 7 (заголовки запроса), тела — с уровня 8.
- В ожидаемом выводе `config view --minify` было `client-key-data: REDACTED` → `DATA+OMITTED` (ShortenConfig перезаписывает результат RedactSecrets, client-go helpers.go).
- Manjaro crictl: пакет `cri-tools` → `crictl` (по памяти, не подтверждено).
- kubeadm: ссылка 10-3 → 10-1 (по плану §4). Ссылки на 00-1: §6/§2/§7/§4.1 → §5, работа 1 шаг 3, работа 4, работа 3 шаг 1.
- Уборка работы 3: «Вторая строка» → третья; «менялись только поды» → rollout restart добавляет аннотацию, повторный apply не нужен.
- Схема 17: «шаги 4, 6, 7 меняют объекты» → шаги 2, 4, 5, 6 (port-forward объекты не меняет).
- Разбор шага 2 работы 1: Burstable «requests и limits заданы, но разные» → requests не совпадают с limits.
- Упоминания, похожие на метки проверки («на стенде автора», «в прогоне автора», «не снимался») убраны.
- Строки вывода длиннее 100 знаков (`-v=8`, ошибка `--dry-run=server`, пример строки лога CRI) сокращены через `…`, а над блоком указано, что опущено. Цикл установки kubectx переписан через переменную `U`.
- Risks работ 1 и 3: контрольные суммы названы точно (`checksums.txt` у kubectx и stern, `.sha256` у krew, `checksums.sha256` у k9s).
- Шаг 3 работы 3: результат оформлен блоком `exit=1` с оговоркой о сообщении `command terminated with exit code 1`.

## Добавлено по исследованию

- §2: новый подраздел «Свои настройки: kuberc и вывод KYAML» (схема 4, пример kuberc с `defaults` и `aliases`, `KUBERC`, `--kuberc`, `KUBERC=off`, `KUBECTL_KUBERC=false`, credentialPluginPolicy в 1.35, `kubectl kuberc set` в 1.36; KYAML alpha 1.34, beta и включён 1.35, stable 1.37). Строка `-o kyaml` — в карточку kubectl и в список форматов §3.
- Работа 1, шаг 11 «kuberc» через `KUBERC=~/lab/k8s/00-2/kuberc`: хост не меняется. Добавлены строки итога, вопрос 5, уборка файла и `unset KUBERC`.
- §5: `kubectl debug --custom` (stable 1.32); переход exec, attach и port-forward на WebSocket (stable 1.35); node log query (stable 1.36), с оговоркой про поля kubelet.
- §5: `kubectl logs -l` по умолчанию даёт 10 строк на под; §6 дополнен.
- В «придут позже»: на стенде Helm 4, разбор в 07-1 (абзац переделан в список).
- Схемы перенумерованы, их теперь 17.

## Читаемость

- До: средняя длина 8,4 слова, 64 % коротких предложений, 7 нарушений (5 строк кода, 1 стоп-слово «является», 1 предложение на 26 слов).
- После: средняя длина 12,5 слова, 31 % коротких, 0 нарушений.
- Что сделано: рубленые предложения об одной мысли сшиты. Метки блоков карточек переведены в форму «**Назначение:** …». Перечни ошибок в карточках kubectx, krew, k9s и stern сделаны списками. Строки «Ubuntu: …» и «Manjaro: …» переписаны полными предложениями.

## Подтверждено (источник)

- Имена файлов в релизах: kubectx v0.11.0 (`kubectx_v0.11.0_linux_x86_64.tar.gz`, `kubens_…`), krew v0.5.0 (`krew-linux_amd64.tar.gz`, 2026-02-26), stern v1.34.0 (`stern_1.34.0_linux_amd64.tar.gz`), k9s v0.51.0 (`k9s_linux_amd64.deb`). Источник: страницы expanded_assets на github.com.
- kuberc: путь, `KUBERC`, `--kuberc`, `KUBERC=off`, `KUBECTL_KUBERC=false`, формат defaults и aliases. Источник: kubernetes/website docs/reference/kubectl/kuberc.md.
- KYAML: стадии, `-o kyaml`, начало вывода, `kubectl kuberc set` в 1.36. Источник: блог 2026 how-to-pretty-print-kubernetes-yaml-as-kyaml.md.
- Профили `kubectl debug`, значение по умолчанию general, монтирование /host, `--copy-to` и метки или пробы. Источник: kubernetes release-1.36 debug.go и profiles.go.
- `config view` и DATA+OMITTED. Источник: kubectl config/view.go и client-go clientcmd/api/helpers.go.
- Стенд: путь `~/lab/k8s/orders-api/k8s/orders-api.yaml`, `replicas: 2`, HTTPRoute `orders-api`, readiness `periodSeconds: 2`, формат лога приложения, `--wait 120s` в lab-up.sh. Источник: 00-1 и lab-up.sh.
- Числа без изменений: `--request-timeout` 0, `--event-ttl` 1 ч, containerLogMaxSize 10 МиБ и containerLogMaxFiles 5, коды возврата diff, расхождение версий kubectl ±1.

## Не подтверждено (для 00-plan §7)

- Имена и версии пакетов Manjaro и Arch: `krew` (0.5.0), `kubectx` (0.11.0), `stern` (1.34.0), `k9s` (0.51.0), `crictl`. Сайты archlinux.org и repology недоступны.
- Вывод `kubectl tree` (колонки NAMESPACE, NAME, READY, REASON, AGE).
- Сообщения `kubens`: `Context "kind-lab" modified.` и `Active namespace is "…"`.
- Работа 1, шаг 11 (kuberc): весь вывод, вид вопроса `delete --interactive`; работает ли `KUBERC` с путём к файлу в каталоге работы так же, как `~/.kube/kuberc`.
- Начало вывода `-o kyaml` для пода (взято из блога, на стенде не снималось).
- Node log query на kind: включены ли `enableSystemLogHandler` и `enableSystemLogQuery` на узлах стенда.
- Дата перехода `kubectl debug` на профиль general по умолчанию (в 1.36 подтверждено кодом, версия перехода неизвестна).
- Строка HTTPRoute в `apply --dry-run=server` (работа 1, шаг 8).
- `config view --minify` (работа 1, шаг 1).
- Работа 2, шаги 2–6: ожидаемые результаты.
- Работа 3, шаги 1, 2, 5, 6, 8, 9: ожидаемые результаты.
- Установка kubectx, krew, stern и k9s в Ubuntu.
- Строка `command terminated with exit code 1` (работа 3, шаг 3).
- WebSocket для exec, attach и port-forward stable в 1.35: взято из исследования, release notes не открывались.
