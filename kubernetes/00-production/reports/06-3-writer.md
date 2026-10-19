# Отчёт писателя: 06-3 Pod Security и admission-политики

Файл: /home/user/claude/kubernetes/06-access-security/06-3-pod-security-admission.md (переписан поверх старой 06-2).

## Заголовки
## Где мы на карте
## 1. Какую задачу решают admission-политики: Что RBAC не проверяет; Цепочка admission; Три способа задать правило
## 2. Как устроены PSS, PSA, VAP и MAP: Pod Security Standards; Pod Security Admission: метки namespace; ValidatingAdmissionPolicy; MutatingAdmissionPolicy; Kyverno и OPA Gatekeeper
## 3. Как управлять политиками: Включить PSA; Мягкое внедрение; Исключения PSA; Включить VAP; Включить MAP
## 4. Как увидеть состояние: Ответ на запрос; События контроллера; Сухой прогон и проверка политики; Аудит
## 5. Что ломается: Релиз прошёл, а подов нет; Мутация сломала валидный манифест; Политика не срабатывает; Недоступный вебхук
## 6. Пределы и значения по умолчанию: Стадии функций; Значения по умолчанию; Что механизмы не умеют
## Лабораторные работы: 1 restricted (шаги 1-3); 2 мягкое внедрение (1-3); 3 VAP без latest (1-3); 4 MAP (1-3, без реального вывода)
## → Дальше (06-4)

## Объём и читаемость
Проза теории ~3,2 тыс. слов (с лабами ~5 тыс., без кода и таблиц). 216 предложений, средняя 11,3 слова, >25 слов: 0, нарушений: 0.

## Отступления от плана (внести в 00-plan §6)
- Лаба 3: переименованы метка на `lab-06-3/images` (было `policy.lab/images`), а имена политики и привязки оставлены `no-latest-tag` ради реального вывода (объекты кластерные, префикс правила имён не применён). Namespace второй группы лаб — `lab-06-3b`, лабы 4 — `lab-06-3c`; все удаляются в уборке лабы 4.
- Старый шаг 4 (перевод orders-api под restricted) и задание со звёздочкой убраны; на orders остался только dry-run (лаба 2, шаг 3).
- Лаба 1: manifest hardened сохранён; wait/вывод `created` ожидаемые.
- Контекст kubectl не меняется; `-n` везде явный. Раздел 1 старой части (securityContext) заменён ссылкой на 06-2.
- Часть 06-1 теперь есть в плане: ссылка вместо «в курсе security».

## СОМНИТЕЛЬНЫЕ места
Не из старой части (ожидаемый вывод):
- Лаба 1: `pod/hardened created`, `condition met`; лаба 2 шаг 1 `labeled`; лаба 3 шаг 1 `created`; лаба 4 целиком.
- Лаба 2 шаг 2: префикс `Error from server (Forbidden): …` и обрезка warning-строки — старая часть давала только суффикс.
- Лаба 4: `apiVersion: admissionregistration.k8s.io/v1` для MAP (GA 1.36 по research; в 1.34 было v1beta1); поля `failurePolicy`, `matchConditions` (с `name`), `patchType`/`applyConfiguration.expression`/`jsonPatch.expression`, `namespaceSelector` в привязке MAP; синтаксис `Object.spec.securityContext{...}` (в WebFetch-документации примеры yaml не раскрылись, взято из KEP-3962 по памяти); JSONPatch `add` на `/metadata/labels/…` предполагает, что метки уже есть (у `kubectl run` есть `run=`); порядок ключей в выводе меток.
- Предупреждение PSA в лабе 4 шаг 2: «не упоминает seccompProfile» — логический вывод из порядка mutating→validating, не прогонялось.
Из памяти или документации, не сверено:
- Состав baseline (порты хоста, AppArmor, SELinux, /proc, sysctl) — перечислено кратко.
- Namespace без меток PSA = privileged; исключений по умолчанию нет; аннотации аудита `pod-security.kubernetes.io/audit-violations` и `validation.policy.admission.k8s.io/validation_failure`.
- `failurePolicy` у VAP по умолчанию `Fail`; `reason` по умолчанию `Invalid` (422); `parameterNotFoundAction`.
- PSA stable в 1.25; MAP alpha 1.32 / beta 1.34 / GA 1.36 (по research, вторичный источник).
- Таблица сравнения Kyverno/Gatekeeper (языки, мутация, генерация) — общие знания, ссылка на курс security.
- Встроенный набор admission-плагинов (PodSecurity, ResourceQuota, LimitRanger, ServiceAccount); ссылки на 05-1 для квоты и LimitRanger.
- Правка конфигурации exemptions в kind «на уровне kubeadm-конфигурации» — не проверялась.
- Отличие 1.37 не упомянуто (документация MAP: вебхуки исключают виртуальные authn/authz-ресурсы с 1.37 — в часть не включено).

## Что выкинуто / перенесено (в модуль 12)
Кейс из прода: «включили restricted в пятницу — релиз в понедельник зелёный, а подов нет» (enforce на всех namespace без warn/dry-run, rolling update не создаёт новые поды, HPA нечем масштабироваться; фикс: откат на baseline+warn/audit, `apply --dry-run=server` и `rollout status` в CI, enforce по namespace после недели без предупреждений). Суть сохранена в §5.
Вопросы с собеседования (7): что делает securityContext; что такое PSS; как безопасно включить restricted; как запретить latest; VAP или вебхук; почему под нарушает PodSecurity при корректном манифесте (mutating раньше validating); как работать с readOnlyRootFilesystem.
Подводные камни (7): enforce не проверяет работающие поды; ошибки у контроллеров в событиях ReplicaSet; `enforce-version: latest` меняется с кластером; readOnlyRootFilesystem без emptyDir; БД-образы требуют root; порт реестра не тег; мутирующие вебхуки ломают уровень.
Задание со звёздочкой: перевод orders (orders-api + PostgreSQL runAsUser/fsGroup 70, PGDATA в подкаталоге) на restricted и тот же dry-run в CI — в тренажёры модуля 12.
Старый раздел 1 (таблица полей securityContext и вывод CapEff/NoNewPrivs/Seccomp) — вывод оставлен в лабе 1, теория отдана 06-2.
Чеклист удалён.
