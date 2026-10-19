# Ревью 06-3 «Pod Security и admission-политики»

Файл: /home/user/claude/kubernetes/06-access-security/06-3-pod-security-admission.md. Старая версия: e755ced:kubernetes/06-access-security/06-2-pod-security-admission.md.

## Найденные ошибки (было → стало)

1. Лаба 4, MutatingAdmissionPolicy без `reinvocationPolicy` → добавлено `reinvocationPolicy: Never` и строка в таблицу разбора. В v1 поле Required, умолчания нет (validation.go: `field.Required(fldPath.Child("reinvocationPolicy"))`; defaults.go задаёт только failurePolicy). Без поля `kubectl apply` политики падал бы с ошибкой валидации — лаба была нерабочей.
2. §2 MAP: о `reinvocationPolicy` и `failurePolicy` (умолчание Fail) не говорилось → добавлен список из двух полей; «Объекты те же две» → «Объектов тоже два»; добавлено, что у привязки MAP нет `validationActions`.
3. §2 JSONPatch: не сказано, что `add` в `/metadata/labels/<ключ>` требует существующего словаря labels → добавлена фраза (RFC 6902: родитель пути должен существовать); в таблицу лабы 4 — «метка `run` уже есть».
4. §2 PSS, состав уровней неполный → baseline: добавлены seccomp `Unconfined` и безопасный набор sysctl (tcp_rmem/tcp_wmem с 1.32); restricted: добавлены запрет `runAsUser: 0`, `add` только `NET_BIND_SERVICE`, ограничение типов томов.
5. Лаба 4 шаг 3: ожидаемый вывод только `Unconfined` → добавлены строка предупреждения PSA (формат из check_seccompProfile_restricted.go) и `pod/m2 created`; разбор объясняет, почему под создан (нет enforce).
6. §1: admission «только создание, обновление, удаление» → добавлено подключение (connect, `kubectl exec`) и что чтение не проверяется.
7. §3 исключения PSA в kind: «правят на уровне kubeadm-конфигурации» → флаг `--admission-control-config-file`, файл через `extraMounts`, флаг через `kubeadmConfigPatches`; секция `defaults` задаёт уровни для namespace без меток.
8. §3 VAP: «даём API-серверу около 3 секунд» (как факт) → пауза 3 секунды как практика лабы, причина — кэш политик в API-сервере.
9. §6: добавлено, что MAP в beta (1.34) была выключена по умолчанию (kube_features.go release-1.36: Beta Default false; GA 1.36 Default true); добавлена фраза о manifest-based admission control (alpha 1.36, beta и включено в 1.37 — отличие 1.37); ограничение ApplyConfiguration (не меняет атомарные структуры, словари, списки); умолчания `failurePolicy` у VAP и MAP.
10. Лаба 2: вывод отказа `hostnet` дан полностью (`pods "hostnet" is forbidden: violates …`) — суффикс реальный из старой части, префикс стандартный; уборка лабы 2 противоречила команде («удаляется вместе с namespace» и тут же `delete pod plain`) → переписана.
11. Запасной образ busybox назван явно: `localhost:5001/busybox:1.37` (как в 04-2).
12. Лаба 1 разбор: «по одному на каждое требование restricted» → «…которое этот под не выполняет» (требований больше четырёх).

## Читаемость

До: 216 предложений, средняя 11,3 слова, коротких 38 %, нарушений 0. После правок фактов: 2 нарушения (абзац из 6 предложений в «Исключения PSA», предложение 29 слов в §6) — исправлены делением абзаца и предложения. После: 232 предложения, средняя 11,4, коротких 38 %, >25 слов: 0, нарушений 0.

## Подтверждено (источник)

- MAP: apiVersion `admissionregistration.k8s.io/v1`, `patchType` ApplyConfiguration/JSONPatch, `applyConfiguration.expression`, `jsonPatch.expression`, синтаксис `Object{spec: Object.spec{...}}`, `matchConditions` с `name`, `jsonpatch.escapeKey` — website examples/mutatingadmissionpolicy/*.yaml, docs mutating-admission-policy.md, k8s.io/api admissionregistration/v1 types.go.
- MAP alpha 1.32 / beta 1.34 (выкл.) / GA 1.36 (вкл.) — kube_features.go ветки release-1.36. ManifestBasedAdmissionControlConfig alpha 1.36 — там же.
- Привязка MAP: policyName, paramRef, matchResources (namespaceSelector) — types.go.
- VAP: failurePolicy по умолчанию Fail (defaults.go); reason по умолчанию StatusReasonInvalid (types.go); parameterNotFoundAction Required, Allow/Deny.
- PSS baseline/restricted, host в пробах с 1.34, sysctl 1.32/1.37 — pod-security-standards.md.
- PSA: enforce только для Pod, warn/audit и для шаблонов; exemptions по usernames/runtimeClasses/namespaces; исключение пользователя — только прямое создание пода; не исключать SA контроллеров; stable 1.25 — pod-security-admission.md. Умолчания privileged/latest — enforce-standards-admission-controller.md (секция defaults).
- Аннотации аудита `pod-security.kubernetes.io/audit-violations`, `validation.policy.admission.k8s.io/validation_failure` — audit-annotations.md.
- Реальный вывод лаб 1–3 совпадает со старой частью.
- Соответствие плану §4: четыре работы как в плане; 06-4 = аудит и политика образов — ссылки верны; 00-2, 01-1, 01-3, 02-1, 02-2, 05-1, 06-1, 06-2, 09-2 существуют.

## Не подтверждено (для 00-plan)

- Лаба 4 целиком не прогонялась (MAP на 1.36): строки вывода, порядок ключей меток, точный текст предупреждений PSA.
- Лаба 1 шаг 2 (`pod/hardened created`, `condition met`), лаба 2 шаг 1 (`labeled`), лаба 3 шаг 1 (`created`) — ожидаемые строки.
- Пауза `sleep 3` достаточна для загрузки MAP (для VAP — из старого прогона).
- Применение exemptions PSA в kind через extraMounts + kubeadmConfigPatches — не проверялось.
- Таблица Kyverno/Gatekeeper (языки, мутация, генерация, внешние данные) — по общим знаниям.
- Утверждение, что Unconfined в m2 приходит в предупреждении одной строкой с остальными нарушениями — формат по коду, не прогонялось.
