# 06-3. Pod Security и admission-политики

> Модуль 06 «Доступ и безопасность» · часть 3 из 4 · ~1,5 ч чтения + ~1 ч лабы · Нужно: стенд 00-1 (контекст `kind-lab`), образы `localhost:5001/orders-api:2.0` и `busybox:1.37` · Опирается на: 01-1 (путь запроса), 01-3 (API-объекты), 06-1 (RBAC), 06-2 (securityContext)

## Где мы на карте

Эта часть разбирает, как кластер проверяет и правит объект после того, как RBAC его пропустил. Часть опирается на путь запроса (01-1): admission стоит между авторизацией и записью в etcd. Поля `securityContext`, capabilities, seccomp и user namespaces объяснены в 06-2, а здесь мы проверяем, что поды их действительно задают. Вебхуки как отдельный сервис разобраны в 09-2, а проверка подписей и реестров образов — в 06-4.

```
запрос ─► аутентификация ─► авторизация (RBAC, 06-1)
                                  │
                                  ▼
             ┌─── admission ──────────────────────────────────┐
             │ 1. mutating: правят объект                     │  ← 06-3 §2 (MAP)
             │ 2. проверка схемы                              │
             │ 3. validating: принимают или отклоняют         │  ← 06-3 §2 (PSA, VAP)
             └────────────────────────────────────────────────┘
                                  │
                                  ▼
                                etcd
```

Схема 1. Место admission в пути запроса: сначала объект можно изменить, потом проверить; после проверки он попадает в etcd.

---

## 1. Какую задачу решают admission-политики

RBAC отвечает на вопрос «кто может создать объект», а admission отвечает на вопрос «какой объект можно создать». Без admission любой пользователь с правом создавать поды запустит под от root, с сетью узла и с образом `latest`.

### Что RBAC не проверяет

RBAC смотрит на глагол, ресурс и namespace, но не заглядывает в содержимое объекта. Право `create pods` одинаково для пода с `securityContext` и для привилегированного пода. Поэтому ограничения на поля объекта живут отдельно — в admission.

Admission (допуск, 01-1) — этап обработки запроса, на котором API-сервер проверяет объект и при необходимости меняет его. Этап идёт после аутентификации и авторизации и касается только запросов на запись: создание, обновление, удаление и подключение (connect, например `kubectl exec`). Чтение (get, list, watch) admission не проверяет.

### Цепочка admission

Admission состоит из двух фаз, и порядок фаз важен. Сначала работают mutating-плагины (mutating admission, 01-1) — они меняют объект: подставляют значения по умолчанию, добавляют контейнер, метку или поле. Затем API-сервер проверяет схему изменённого объекта. После этого работают validating-плагины (validating admission) — они только принимают или отклоняют объект.

Такой порядок защищает проверки: validating видит объект уже в окончательном виде, после всех мутаций. Обратная сторона в том, что мутация может сделать валидный манифест невалидным (§5).

Внутри фазы плагины делятся на встроенные и расширяемые:

- **Встроенные** — часть API-сервера: `PodSecurity`, `ResourceQuota` (05-2), `LimitRanger` (05-2), `ServiceAccount`.
- **Политики на CEL** — ValidatingAdmissionPolicy и MutatingAdmissionPolicy; выражения выполняются внутри API-сервера.
- **Вебхуки** — внешний сервис, который API-сервер вызывает по HTTPS (09-2).

CEL (Common Expression Language, 05-3) — небольшой язык выражений без побочных эффектов: выражение читает объект и возвращает значение, например `true` или `false`.

### Три способа задать правило

Для каждой задачи есть свой инструмент, и они дополняют друг друга.

- Pod Security Admission — готовый набор правил для полей пода, включается меткой namespace. Правило выбрать можно, написать своё нельзя.
- **Политики на CEL** — своё правило для любого объекта: теги образов, обязательные метки, лимиты. Работают без отдельного сервиса.
- **Вебхуки и их оболочки (Kyverno, OPA Gatekeeper)** — всё остальное: генерация объектов, обращение к внешним данным, проверка подписей образов.

Дальше мы идём в этом же порядке — от готового к самописному.

---

## 2. Как устроены PSS, PSA, VAP и MAP

В этом разделе четыре механизма: стандарты безопасности подов, их контроллер, политики проверки и политики мутации. Затем мы сравним их с Kyverno и Gatekeeper.

### Pod Security Standards: три уровня

**Pod Security Standards** (PSS, стандарты безопасности подов) — три фиксированных набора требований к полям пода, от свободного до строгого. Набор называют **уровнем** (level).

- **privileged** — без ограничений. Нужен системным компонентам: CNI, CSI, агентам узлов.
- **baseline** — запрещает очевидно опасное. Минимально ограничивающий уровень, который не ломает большинство приложений.
- **restricted** — следует практикам усиления защиты (hardening). Он включает всё из baseline и требует безопасный под.

Таблица показывает, что запрещает каждый уровень и что требует restricted сверх baseline.

| Уровень | Что запрещено или требуется | Для кого |
|---|---|---|
| privileged | ничего | системные компоненты |
| baseline | privileged-контейнеры, host-пространства имён, hostPath, лишние capabilities | обычные приложения |
| restricted | non-root, seccomp, drop ALL, запрет повышения привилегий | чувствительные нагрузки |

Список в baseline включает ещё порты хоста, профили AppArmor и SELinux вне разрешённых, тип монтирования `/proc` и seccomp `Unconfined`. Sysctl разрешены только из безопасного набора, и он растёт с версиями: в 1.32 добавлены `tcp_rmem` и `tcp_wmem`. С Kubernetes 1.34 baseline запрещает и поле `host` в `httpGet` и `tcpSocket` проб и хуков. Через это поле проба или хук бьёт в произвольный адрес, а не в под.

Restricted требует `runAsNonRoot: true` без `runAsUser: 0`, `allowPrivilegeEscalation: false` и `seccompProfile` типа `RuntimeDefault` или `Localhost`. Capabilities сбрасывают целиком (`drop: [ALL]`), а добавить можно только `NET_BIND_SERVICE`. Типы томов ограничены списком: `configMap`, `secret`, `emptyDir`, `projected`, `persistentVolumeClaim` и ещё несколько, но не `hostPath`. Смысл этих полей объяснён в 06-2.

### Pod Security Admission: метки namespace

**Pod Security Admission** (PSA) — встроенный validating-плагин `PodSecurity`, который применяет уровни PSS к подам по меткам namespace. Плагин включён в API-сервер по умолчанию, ставить ничего не нужно. У каждого режима своя метка вида `pod-security.kubernetes.io/<режим>`.

- **enforce** — отклонять под, который нарушает уровень.
- **warn** — пропускать под, но показывать клиенту предупреждение.
- **audit** — пропускать под и записывать нарушение в аннотацию события аудита.

Три режима задают независимо, и у каждого может быть свой уровень. К метке уровня добавляют метку версии: `pod-security.kubernetes.io/enforce-version` принимает значение `latest` или версию вида `v1.36`. Версия фиксирует набор правил на тот момент, поэтому после обновления кластера новые требования не появятся неожиданно.

```
namespace lab-06-3b
  labels:  enforce=baseline    warn=restricted    audit=restricted
                │                    │                   │
под нарушает restricted:             │                   │
  отклонить? ───┘ нет, это baseline  │                   │
  предупредить клиента ──────────────┘                   │
  записать в аудит ──────────────────────────────────────┘
```

Схема 2. Один под проверяется по трём меткам: отказывает только enforce, остальные режимы лишь сообщают.

Режимы по-разному относятся к контроллерам. Enforce проверяет только объект Pod, а Deployment или Job он пропускает. Warn и audit проверяют и шаблоны подов в Deployment, Job и других контроллерах, поэтому предупреждение приходит уже при `kubectl apply` манифеста Deployment.

### ValidatingAdmissionPolicy: политика и привязка

**ValidatingAdmissionPolicy** (VAP) — объект API, который описывает правило проверки на CEL; он выполняется внутри API-сервера, и отдельный сервис не нужен. Функция стала GA в 1.30, группа API — `admissionregistration.k8s.io/v1`. Правило состоит из двух объектов.

- **Политика** (ValidatingAdmissionPolicy) — что проверять: на какие ресурсы и операции она смотрит и какие выражения вычисляет.
- **Привязка** (ValidatingAdmissionPolicyBinding) — где и как применять: в каких namespace, с какими параметрами и что делать при нарушении.

Разделение позволяет написать правило один раз и привязать его к разным областям с разными действиями.

```
ValidatingAdmissionPolicy        ValidatingAdmissionPolicyBinding
  matchConstraints  (что) ◄───────  policyName
  validations: CEL                  matchResources (где: namespaceSelector)
  paramKind (тип параметров)        paramRef       (какие параметры)
  failurePolicy                     validationActions: Deny | Warn | Audit
```

Схема 3. Политика хранит логику, привязка выбирает область и действие; без привязки политика ничего не проверяет.

В выражении доступны переменные: `object` — новый объект, `oldObject` — прежний (при создании пуст), `request` — атрибуты запроса, `params` — объект параметров. Если выражение возвращает `false`, правило нарушено.

Три поля определяют поведение при нарушении и при сбое:

- **validationActions** в привязке — список действий: `Deny` отклоняет запрос, `Warn` возвращает предупреждение клиенту, `Audit` записывает нарушение в аннотацию аудита. Deny и Warn вместе не используют.
- **failurePolicy** в политике — что делать, если выражение само не вычислилось (ошибка CEL): `Fail` (по умолчанию) отклоняет запрос, `Ignore` пропускает.
- **messageExpression** — выражение, которое собирает текст отказа, и в нём видны данные объекта.

Параметры нужны, когда одно правило должно работать с разными значениями. В политике задают `paramKind`, например ConfigMap, а привязка через `paramRef` называет конкретный объект или выбирает их по меткам. В выражении параметры читают из `params`, и первой строкой проверяют `params != null`. Обязательное поле `parameterNotFoundAction` решает, что делать, если параметра нет: `Allow` пропускает запрос, `Deny` применяет `failurePolicy`.

### MutatingAdmissionPolicy: мутация без вебхука

**MutatingAdmissionPolicy** (MAP) — аналог VAP для изменений: CEL-выражение возвращает патч, и API-сервер применяет его к объекту. Функция прошла путь alpha 1.32, beta 1.34 и стала GA в 1.36, так что на стенде она включена по умолчанию. Объектов тоже два: политика и привязка (`MutatingAdmissionPolicyBinding`), с теми же `matchConstraints`, `paramKind` и `matchConditions`. У привязки нет `validationActions`: мутация либо применяется, либо нет.

Два поля политики MAP отвечают за сбои и повторы:

- **failurePolicy** — что делать при ошибке выражения или патча: `Fail` (по умолчанию) отклоняет запрос, `Ignore` пропускает его без мутации.
- **reinvocationPolicy** — обязательное поле: `Never` применяет мутацию один раз, `IfNeeded` повторяет её, если объект изменили более поздние мутации. Значения по умолчанию у поля нет, и политика без него не создаётся.

Патч задаёт список `mutations`, и у каждой мутации один из двух типов (`patchType`).

- **ApplyConfiguration** — выражение возвращает объект, построенный через `Object{...}`; он сливается с исходным по правилам server-side apply (01-3). Подходит для «добавить поле» и «задать значение по умолчанию».
- **JSONPatch** — выражение возвращает список операций `JSONPatch{op, path, value}` по RFC 6902. Подходит для точечных правок и операции `test`.

Ключи с символами `/` и `~` в пути экранирует функция `jsonpatch.escapeKey()`; без неё метка `example.com/team` сломает путь. Операция `add` по RFC 6902 требует, чтобы родитель пути уже существовал. Поэтому `add` в `/metadata/labels/<ключ>` падает у объекта без единой метки, и тогда сначала добавляют сам словарь `/metadata/labels`.

Условия `matchConditions` отбирают запросы, которым патч нужен: например, мутация применяется, только если поле ещё не задано. Это защищает от перезаписи значений, которые указал автор манифеста.

### Kyverno и OPA Gatekeeper

**Kyverno** и **OPA Gatekeeper** — внешние контроллеры, которые работают как admission-вебхуки и дают политики в виде объектов Kubernetes. Курс `security` разбирает их полнее, а здесь мы сравниваем механизмы по ключевым свойствам.

| | VAP / MAP | Kyverno | Gatekeeper |
|---|---|---|---|
| Где работает | в API-сервере | вебхук | вебхук |
| Язык правил | CEL | YAML, CEL | Rego, CEL |
| Мутация | MAP | да | да |
| Генерация объектов | нет | да | нет |
| Внешние данные | нет | да | ограниченно |

Таблица строится по документации проектов; версии и режимы зависят от установки, поэтому детали проверяйте в курсе `security`. Практический вывод простой. Правила по полям объекта пишут на CEL внутри API-сервера, а за генерацией объектов, проверкой подписей и внешними данными идут в Kyverno или Gatekeeper.

---

## 3. Как управлять политиками

Управление сводится к меткам namespace для PSA и к объектам политик и привязок для VAP и MAP. Главное правило — вводить ограничения постепенно, от сообщения к отказу.

### Включить PSA на namespace

Уровень задают меткой, и достаточно одной команды `kubectl label`. Namespace без меток живёт на уровне privileged, поэтому защита появляется только после явной метки.

```bash
kubectl label ns lab-06-3 \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/enforce-version=latest
```

Команда ставит две метки: уровень `restricted` для режима enforce и версию правил `latest`. Для долгоживущих namespace версию фиксируют конкретной (`v1.36`), чтобы обновление кластера не изменило требования.

### Мягкое внедрение

Уровень повышают по шагам, и каждый шаг проверяют, прежде чем включать отказ. Так внедрение не ломает работающие сервисы.

1. Поставить `warn` и `audit` на целевой уровень, а `enforce` оставить на текущем. Тогда команды видят предупреждения при `kubectl apply`.
2. Исправить манифесты по списку нарушений и дождаться нуля предупреждений.
3. Проверить существующий namespace пробной меткой: `kubectl label --dry-run=server --overwrite`.
4. Включить `enforce`.

Сухой прогон на сервере (`--dry-run=server`) выполняет запрос на сервере, но не сохраняет результат; для метки он перечисляет работающие поды, которые нарушат новый уровень.

### Исключения PSA

**Исключение** (exemption) — запрос, который PSA не проверяет вообще: ни enforce, ни warn, ни audit. Исключения задают статически в конфигурации admission-контроллера API-сервера (`AdmissionConfiguration`, плагин `PodSecurity`) по трём признакам: имя пользователя, класс рантайма (RuntimeClass) или namespace.

Файл конфигурации API-сервер получает флагом `--admission-control-config-file` и читает при старте. В kind его задают при создании кластера: файл монтируют на узел через `extraMounts`, а флаг передают через `kubeadmConfigPatches`. Эту работу мы не делаем. В том же файле секция `defaults` задаёт уровни для namespace без меток.

Исключение пользователя действует только на прямое создание пода, но не на создание Deployment. Сервисные учётные записи контроллеров (например, ReplicaSet) исключать нельзя: тогда любой, кто может создать Deployment, обойдёт проверку.

### Включить VAP: от Warn к Deny

Привязка с действием `Warn` показывает нарушения без отказов, и её меняют на `Deny`, когда нарушений нет. Область ограничивают через `namespaceSelector` привязки: правило включается по namespace, а не на весь кластер.

Порядок тот же, что у PSA: `Warn` (а при необходимости `Audit`), потом `Deny`. Переключение делают патчем привязки, политику не трогают:

```bash
kubectl patch validatingadmissionpolicybinding no-latest-tag --type=merge \
  -p '{"spec":{"validationActions":["Deny"]}}'
```

Команда заменяет список действий в привязке `no-latest-tag`. Политика остаётся прежней, меняется только реакция на нарушение. Изменение вступает в силу не мгновенно, потому что API-сервер подхватывает объекты политик через свой кэш, поэтому в лабораторной после патча стоит пауза в 3 секунды.

### Включить MAP

Привязка MAP не имеет действий `Deny` и `Warn`: мутация всегда применяется. Поэтому безопасно вводить её через узкий `namespaceSelector` и условие `matchConditions`. Как и у VAP, область задаёт привязка, а политика без привязки не работает.

---

## 4. Как увидеть состояние

Результат admission видно в трёх местах: в ответе на запрос, в событиях контроллера и в аудите. Какое место смотреть, зависит от того, кто создал под — человек или контроллер.

### Ответ на запрос

Отказ и предупреждение приходят в ответе на запрос, и `kubectl` печатает их сразу. Отказ PSA выглядит как `Forbidden: violates PodSecurity "restricted:latest": …` и перечисляет все нарушенные требования с подсказкой, какое поле добавить. Предупреждение начинается словами `Warning: would violate PodSecurity`. У VAP в тексте названы политика и привязка: `ValidatingAdmissionPolicy 'имя' with binding 'имя' denied request`.

### События контроллера

Поды создаёт контроллер, а не человек, и его отказы видны в событиях. Под из Deployment создаёт ReplicaSet, поэтому событие `FailedCreate` с текстом отказа лежит у ReplicaSet, а не у Deployment. Сам Deployment при этом выглядит нормально, а `READY` показывает, например, `2/6`. Команда `kubectl describe rs` и `kubectl get events` показывают причину.

### Сухой прогон и проверка политики

`kubectl label --dry-run=server` покажет, какие поды нарушат новый уровень PSA. Для манифеста подходит `kubectl apply --dry-run=server`: он проходит admission, и CI ловит отказ до выкатки (00-2). Для VAP на сервере проверяется и сама политика: при создании API-сервер проверяет типы выражений и пишет предупреждения в `status.typeChecking.expressionWarnings`. Пустой статус значит, что ошибок не найдено.

### Аудит

Режимы `audit` пишут нарушения в аннотации событий аудита API-сервера. У PSA это аннотация `pod-security.kubernetes.io/audit-violations`, у VAP с действием `Audit` — `validation.policy.admission.k8s.io/validation_failure`. Включить аудит и читать его — тема 06-4. На стенде аудит выключен, поэтому записи режима `audit` здесь не видны.

---

## 5. Что ломается и как найти причину

Поломки admission делятся на три группы: отказ после включения enforce, отказ из-за мутации и сбой самой политики. Для каждой группы свой первый шаг диагностики.

### Релиз прошёл, а подов нет

Enforce не трогает уже работающие поды, поэтому проблема всплывает на следующем rollout или при масштабировании. Deployment остаётся «зелёным», новые реплики не создаются, а ReplicaSet пишет `FailedCreate`. Так же ведёт себя исчерпанная квота (05-2).

Диагностика идёт по цепочке: `kubectl get deploy` показывает нехватку реплик, `kubectl describe rs` показывает отказ с текстом, и в тексте уже написано, какие поля добавить. Чтобы не попасть в эту ловушку, перед enforce делают сухой прогон метки, а в CI проверяют `rollout status`, а не только `kubectl apply` (02-2).

### Мутация сломала валидный манифест

Если манифест корректен, а PodSecurity отказывает, виновата мутация. Она идёт раньше проверки: вебхук-инжектор (sidecar сервисной сетки, агент) добавляет контейнер без нужного `securityContext`, и под перестаёт проходить restricted. Автор манифеста тут ни при чём.

Признак: в тексте отказа названо имя контейнера, которого нет в манифесте. Чинят инжектор, чтобы он добавлял безопасный контейнер, или исключают его по признаку (§3), но не ослабляют уровень namespace.

### Политика не срабатывает или срабатывает не там

Тихая политика чаще всего ошибается в области. Типичные причины такие:

- Привязка не совпала с namespace: `namespaceSelector` не находит метку, и правило ничего не проверяет.
- Политика создана, а привязки нет.
- Выражение неверно разбирает значение: двоеточие порта реестра принято за тег.
- Действие в привязке `Warn`, а не `Deny`, поэтому поды создаются.

Диагностика: проверить метки namespace, прочитать `status.typeChecking` у политики и создать тестовый объект с ожидаемым отказом. Ошибки в самом выражении при `failurePolicy: Fail` превращаются в отказы всех запросов, которые попали под правило, поэтому политику сначала запускают в режиме `Warn`.

### Недоступный вебхук

Вебхук падает как отдельный сервис, и при `failurePolicy: Fail` кластер перестаёт принимать изменения, которые под него попадают. Для CEL-политик такой сценарий невозможен, потому что они работают внутри API-сервера. Диагностика вебхука и выход из зависших namespace — 09-2.

---

## 6. Пределы и значения по умолчанию

Ниже собраны стадии функций, значения по умолчанию и то, чего эти механизмы не умеют. Значения приведены для Kubernetes 1.36.

### Стадии функций

Таблица показывает, с какой версии что доступно без включения флагов.

| Функция | Стадия | Версия |
|---|---|---|
| Pod Security Admission | stable | 1.25 |
| ValidatingAdmissionPolicy | GA | 1.30 |
| MutatingAdmissionPolicy | GA | 1.36 |
| Контроль `host` в пробах и хуках (baseline) | в PSS | 1.34 |

MAP в 1.32 была alpha, в 1.34 — beta, но и в beta оставалась выключенной по умолчанию. Если кластер старше 1.36, проверьте, включена ли функция и какая версия API у политики. Политики из файлов, которые API-сервер загружает с диска при старте, называют manifest-based admission control. Эта функция появилась в 1.36 как alpha, а в 1.37 стала beta и включена по умолчанию.

### Значения по умолчанию

- Namespace без меток PSA — уровень privileged, проверок нет.
- Версия правил без метки версии — `latest`.
- `failurePolicy` у VAP и MAP — `Fail`; `reinvocationPolicy` у MAP умолчания не имеет.
- Режимы PSA независимы: каждый настраивается отдельной меткой.
- Исключений PSA по умолчанию нет.
- Ответ на нарушение VAP без `reason` — код `Invalid` (422); значение `reason` можно задать: `Unauthorized`, `Forbidden`, `Invalid`, `RequestEntityTooLarge`.

### Что механизмы не умеют

PSA проверяет поля пода и больше ничего: не теги образов, не реестры, не метки и не ресурсы. Исключения у PSA грубые: на пользователя, RuntimeClass или namespace целиком, а не на образ. Исключить под по отдельному полю нельзя.

VAP и MAP видят один объект и параметры. Они не обращаются к внешним сервисам, не создают другие объекты и не проверяют подпись образа. ApplyConfiguration в MAP не меняет атомарные структуры, словари и списки, иначе слияние стёрло бы чужие значения; для них остаётся JSONPatch. PSA не заменяет seccomp-профиль: она проверяет, что поле задано, а применяет его рантайм. Подробности про профили — в 06-2.

---

## Лабораторные работы

Работы идут на стенде 00-1 в namespace `lab-06-3` и `lab-06-3b`; последний нужен для мягкого внедрения, а MAP использует отдельный `lab-06-3c`. Команды везде с явным `-n`: контекст kubectl и текущий namespace не меняются. Хост работы не меняют; политики и привязки — объекты кластера, их удаляет уборка. Образ `busybox:1.37` узлы тянут из Docker Hub, а при недоступности используйте копию `localhost:5001/busybox:1.37` в реестре стенда (02-1).

Подготовку делают один раз: выбирают контекст стенда и создают два namespace.

```bash
kubectl config use-context kind-lab
kubectl create ns lab-06-3
kubectl label ns lab-06-3 \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/enforce-version=latest
kubectl create ns lab-06-3b
```

| Часть команды | Значение |
|---|---|
| `use-context kind-lab` | выбрать кластер стенда |
| `create ns` | создать namespace |
| `label ns … enforce=restricted` | отклонять поды, нарушающие уровень restricted |
| `enforce-version=latest` | брать правила текущей версии кластера |

Первая команда переключает контекст на стенд, поэтому дальнейшие команды не попадут в рабочий кластер.

### Лабораторная работа 1. Уровень restricted: отказ и исправление

**Цель.** Увидеть отказ PSA для пода без `securityContext`, прочитать в сообщении список недостающих полей и собрать под, который проходит restricted.

**Что понадобится.**

- Стенд из 00-1 и namespace `lab-06-3` с меткой enforce.
- Образ `localhost:5001/orders-api:2.0`.
- Около 20 минут.

**Схема опыта.**

```
kubectl run plain ──► PodSecurity (restricted) ──► отказ + список полей
kubectl apply hardened ──► PodSecurity (restricted) ──► принят, под Ready
```

Схема 4. Один namespace, два пода: первый нарушает уровень, второй проходит.

#### Шаг 1. Создать под без securityContext

Команда пытается запустить orders-api без единого поля безопасности.

```bash
kubectl -n lab-06-3 run plain --image=localhost:5001/orders-api:2.0
```

| Часть команды | Значение |
|---|---|
| `-n lab-06-3` | namespace с меткой `enforce=restricted` |
| `run plain` | создать под с именем `plain` |
| `--image=…` | образ orders-api стенда |

Результат (одна строка, здесь перенесена):

```
Error from server (Forbidden): pods "plain" is forbidden: violates PodSecurity
"restricted:latest": allowPrivilegeEscalation != false (container "plain" must set
securityContext.allowPrivilegeEscalation=false), unrestricted capabilities
(container "plain" must set securityContext.capabilities.drop=["ALL"]),
runAsNonRoot != true (pod or container "plain" must set
securityContext.runAsNonRoot=true), seccompProfile (pod or container "plain" must
set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
```

Разбор:

1. `Forbidden` — запрос отклонён на admission, под не создан.
2. `restricted:latest` — применён уровень restricted с версией правил `latest`.
3. Четыре нарушения — по одному на каждое требование restricted (§2), которое этот под не выполняет.
4. В скобках названо поле, которое нужно добавить: сообщение — готовый список правок.

#### Шаг 2. Создать под, который проходит restricted

Команда создаёт под с полным набором полей и ждёт готовности.

```bash
kubectl -n lab-06-3 apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata: {name: hardened}
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 10001
    seccompProfile: {type: RuntimeDefault}
  containers:
  - name: api
    image: localhost:5001/orders-api:2.0
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities: {drop: [ALL]}
    volumeMounts: [{name: tmp, mountPath: /tmp}]
  volumes: [{name: tmp, emptyDir: {}}]
EOF
kubectl -n lab-06-3 wait --for=condition=Ready pod/hardened
```

| Часть команды | Значение |
|---|---|
| `runAsNonRoot`, `runAsUser: 10001` | процесс не root, как в образе orders-api |
| `seccompProfile: RuntimeDefault` | фильтр системных вызовов рантайма |
| `allowPrivilegeEscalation: false` | процесс не получит больше прав |
| `capabilities.drop: [ALL]` | без Linux capabilities |
| `readOnlyRootFilesystem: true` | корневая ФС только для чтения |
| `emptyDir` на `/tmp` | каталог для временных файлов |

Результат: под создаётся, затем `condition met`; точных строк вывода прогона у этого шага нет, поэтому форма ожидаемая.

```
pod/hardened created
pod/hardened condition met
```

Разбор: PSA пропустил под, потому что все четыре требования из шага 1 выполнены. Поля `readOnlyRootFilesystem` и `emptyDir` restricted не требует, они здесь для защиты и показывают, что приложению нужен только каталог для `/tmp`. Манифест тот же, что в 06-2 §3. Что эти поля делают в процессе (`Uid`, `CapEff`, `NoNewPrivs`, `Seccomp`), показано в 06-2, лабораторная работа 1, шаг 2.

**Итог.**

| Что узнали | Где видно |
|---|---|
| Сообщение PSA перечисляет все недостающие поля | шаг 1 |
| Под с полным набором полей проходит restricted | шаг 2 |

**Уборка.**

```bash
kubectl -n lab-06-3 delete pod hardened
```

Namespace остаётся для следующих работ.

**Вопросы для самопроверки.**

1. Почему `kubectl run plain` отклонён, хотя у пользователя есть право создавать поды?
2. Какое поле не требует restricted, но понадобилось приложению?

<details>
<summary>Ответы</summary>

1. RBAC проверяет право на действие, а PSA — содержимое пода. Они работают на разных шагах цепочки admission, и отказ PSA не связан с правами.
2. `emptyDir` для `/tmp`. Restricted требует non-root, seccomp, drop ALL и запрет повышения привилегий. Каталог для записи нужен приложению, потому что корневая ФС только для чтения.

</details>

### Лабораторная работа 2. Мягкое внедрение: baseline и предупреждения restricted

**Цель.** Увидеть, как режимы enforce, warn и audit работают вместе, и проверить существующий namespace пробной меткой до включения enforce.

**Что понадобится.**

- Namespace `lab-06-3b` из подготовки.
- Образы `localhost:5001/orders-api:2.0` и `busybox:1.37`.
- Namespace `orders` со стенда, который работа только читает.

**Схема опыта.**

```
lab-06-3b: enforce=baseline  warn=restricted  audit=restricted
  plain   ──► создан + Warning (нарушает restricted)
  hostnet ──► отклонён (нарушает baseline)
orders:  label --dry-run=server enforce=restricted ──► список нарушений, метка не ставится
```

Схема 5. Baseline защищает, restricted только сообщает, а пробная метка показывает цену ужесточения.

#### Шаг 1. Поставить режимы

Команда ставит одну метку enforce и две метки для предупреждений и аудита.

```bash
kubectl label ns lab-06-3b \
  pod-security.kubernetes.io/enforce=baseline \
  pod-security.kubernetes.io/warn=restricted \
  pod-security.kubernetes.io/audit=restricted
```

| Часть команды | Значение |
|---|---|
| `enforce=baseline` | отклонять только очевидно опасное |
| `warn=restricted` | предупреждать о нарушениях restricted |
| `audit=restricted` | писать нарушения restricted в аудит |

Результат: `namespace/lab-06-3b labeled`; строка ожидаемая.

#### Шаг 2. Создать обычный под и под с сетью узла

Первая команда создаёт обычный под без полей безопасности, вторая просит сеть узла.

```bash
kubectl -n lab-06-3b run plain --image=localhost:5001/orders-api:2.0
kubectl -n lab-06-3b run hostnet --image=busybox:1.37 \
  --overrides='{"spec":{"hostNetwork":true}}' -- sleep 60
```

| Часть команды | Значение |
|---|---|
| `run plain` | под без `securityContext` |
| `--overrides='{"spec":{"hostNetwork":true}}'` | добавить в спецификацию сеть узла |
| `-- sleep 60` | команда контейнера: спать 60 секунд |

Результат (строки сокращены `…` и перенесены):

```
Warning: would violate PodSecurity "restricted:latest": allowPrivilegeEscalation != false …
pod/plain created
Error from server (Forbidden): pods "hostnet" is forbidden: violates PodSecurity
"baseline:latest": host namespaces (hostNetwork=true)
```

Разбор:

1. `Warning: would violate … restricted` — режим warn сообщает о нарушении, но под создан.
2. `pod/plain created` — enforce на уровне baseline его пропустил.
3. `Forbidden … baseline` — сеть узла запрещена уже на baseline, поэтому `hostnet` отклонён.

Команды видят, что нужно исправить, и ничего не ломается: так выглядит внедрение без аварий.

#### Шаг 3. Проверить namespace orders пробной меткой

Команда выполняет метку на сервере, но не сохраняет её: так видно цену ужесточения для работающего namespace.

```bash
kubectl label --dry-run=server --overwrite ns orders \
  pod-security.kubernetes.io/enforce=restricted
```

| Часть команды | Значение |
|---|---|
| `--dry-run=server` | выполнить на сервере без сохранения |
| `--overwrite` | разрешить замену метки, если она есть |
| `ns orders` | namespace демо-приложения |

Результат:

```
Warning: existing pods in namespace "orders" violate the new PodSecurity
enforce level "restricted:latest"
Warning: orders-api-7f45b67f95-c47t8 (and 2 other pods):
allowPrivilegeEscalation != false, unrestricted capabilities, runAsNonRoot != true, seccompProfile
namespace/orders labeled (server dry run)
```

Разбор:

1. Первая строка — работающие поды нарушат новый уровень.
2. Вторая строка — один под и ещё два, а после двоеточия список нарушений.
3. `(server dry run)` — метка не поставлена: namespace `orders` не изменился.

Работающие поды enforce не убивает, но следующий rollout не создаст новых подов. Поэтому ужесточение начинают с warn и пробной метки.

**Итог.**

| Что узнали | Где видно |
|---|---|
| Три режима работают независимо | шаг 2 |
| Enforce отклоняет, warn только предупреждает | шаг 2 |
| Пробная метка показывает нарушения без изменений | шаг 3 |

**Уборка.** Пробная метка ничего не сохранила, поэтому удаляем только под `plain`. Namespace `lab-06-3b` с метками PSA остаётся для работы 3.

```bash
kubectl -n lab-06-3b delete pod plain
```

**Вопросы для самопроверки.**

1. Почему `plain` создан, хотя нарушает restricted?
2. Что случится с работающими подами `orders`, если поставить enforce=restricted?
3. Почему пробную метку нужно ставить до enforce?

<details>
<summary>Ответы</summary>

1. Enforce стоит на baseline, а restricted задан только для warn и audit. Эти режимы лишь сообщают о нарушениях.
2. Ничего: enforce проверяет создаваемые поды и не трогает работающие. Но следующий rollout или масштабирование упрётся в отказ, и ReplicaSet напишет `FailedCreate`.
3. Она перечисляет нарушения заранее и ничего не сохраняет, так что команды успевают исправить манифесты.

</details>

### Лабораторная работа 3. ValidatingAdmissionPolicy: запретить образы без тега и с latest

**Риски.** Работа создаёт объекты уровня кластера, поэтому прочтите их влияние до запуска.

- **Что меняется:** политика и привязка `no-latest-tag` (объекты кластера), метка на namespace `lab-06-3b`.
- **Надолго ли:** до уборки; привязка действует только на namespace с меткой `lab-06-3/images=pinned`.
- **Безопасность:** привилегий не нужно; политика только запрещает поды.
- **Влияние на систему:** другие namespace не затронуты, пока у них нет метки.
- **Откат:** блок «Уборка».

**Цель.** Написать политику на CEL, проверить её в режимах Warn и Deny и убедиться, что порт реестра не принят за тег.

**Что понадобится.**

- Namespace `lab-06-3b` и образы `busybox` и `localhost:5001/orders-api:2.0`.
- Дайджест образа `orders-api:2.0` из вывода `docker push` в 00-1: вместо него в примере стоит сокращение.

**Схема опыта.**

```
под ──► VAP no-latest-tag (CEL по spec.containers[].image)
          │ привязка: namespaceSelector lab-06-3/images=pinned
          ├─ validationActions [Warn] ──► создан + предупреждение
          └─ validationActions [Deny] ──► отклонён
```

Схема 6. Правило одно, а реакция на нарушение меняется в привязке.

#### Шаг 1. Создать политику и привязку в режиме Warn

Команда помечает namespace и создаёт политику с привязкой.

```bash
kubectl label ns lab-06-3b lab-06-3/images=pinned
kubectl apply -f - <<'EOF'
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata: {name: no-latest-tag}
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
    - {apiGroups: [""], apiVersions: [v1], operations: [CREATE, UPDATE], resources: [pods]}
  validations:
  - expression: >-
      object.spec.containers.all(c, c.image.contains('@sha256:') ||
        (c.image.split('/')[size(c.image.split('/'))-1].contains(':') &&
         !c.image.endsWith(':latest')))
    messageExpression: "'образ без тега или с :latest запрещён: ' +
      object.spec.containers.map(c, c.image).join(', ')"
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata: {name: no-latest-tag}
spec:
  policyName: no-latest-tag
  validationActions: [Warn]
  matchResources:
    namespaceSelector: {matchLabels: {lab-06-3/images: pinned}}
EOF
```

| Часть команды | Значение |
|---|---|
| `label ns … lab-06-3/images=pinned` | метка, по которой привязка выбирает namespace |
| `failurePolicy: Fail` | при ошибке выражения отклонять запрос |
| `operations: [CREATE, UPDATE]` | проверять создание и обновление подов |
| `c.image.contains('@sha256:')` | образ с дайджестом всегда принят |
| `split('/')[size(…)-1]` | взять последний сегмент пути образа |
| `.contains(':')` | в последнем сегменте должен быть тег |
| `!c.image.endsWith(':latest')` | тег не `latest` |
| `validationActions: [Warn]` | сначала только предупреждать |

Тег ищется в последнем сегменте пути: иначе двоеточие порта реестра (`localhost:5001/…`) сошло бы за тег. Результат: `validatingadmissionpolicy … created`, `validatingadmissionpolicybinding … created`; строки ожидаемые.

#### Шаг 2. Проверить режим Warn

Команда запускает под с образом без тега в помеченном namespace.

```bash
sleep 3
kubectl -n lab-06-3b run w1 --image=busybox -- sleep 60
```

Результат:

```
Warning: Validation failed for ValidatingAdmissionPolicy 'no-latest-tag' with binding
'no-latest-tag': образ без тега или с :latest запрещён: busybox
```

Разбор:

1. `sleep 3` — пауза на загрузку политики в API-сервер.
2. Предупреждение называет политику и привязку, а текст собран `messageExpression`.
3. Под при этом создан, потому что действие — `Warn`.

#### Шаг 3. Переключить на Deny и проверить шесть образов

Команда меняет действие в привязке и по очереди создаёт поды с шестью образами. Для последнего вместо дайджеста стоит сокращение: подставьте свой.

```bash
kubectl patch validatingadmissionpolicybinding no-latest-tag --type=merge \
  -p '{"spec":{"validationActions":["Deny"]}}'
sleep 3
DIGEST=sha256:ad4f8fd…   # свой дайджест из docker push
for img in busybox busybox:latest busybox:1.37 localhost:5001/orders-api:2.0 \
           localhost:5001/orders-api localhost:5001/orders-api@$DIGEST; do
  printf "%-40s -> " "${img:0:40}"
  kubectl -n lab-06-3b run t-$RANDOM --image=$img -- sleep 60 2>&1 | tail -1 | cut -c1-110
done
```

| Часть команды | Значение |
|---|---|
| `patch … validationActions:["Deny"]` | теперь нарушения отклоняются |
| `t-$RANDOM` | случайное имя пода |
| `printf "%-40s -> "` | вывести образ в колонку шириной 40 |
| `2>&1 \| tail -1 \| cut -c1-110` | взять последнюю строку и обрезать до 110 знаков |

Результат:

```
busybox                       -> … ValidatingAdmissionPolicy 'no-latest-tag' with binding
                                 'no-latest-tag' denied request
busybox:latest                -> … denied request
busybox:1.37                  -> pod/… created
localhost:5001/orders-api:2.0 -> pod/… created
localhost:5001/orders-api     -> … denied
localhost:5001/orders-api@sha256:ad4f8fd… -> pod/… created
```

Разбор:

1. `busybox` и `busybox:latest` отклонены: образа нет тега, либо тег `latest`.
2. `busybox:1.37` создан: закреплённый тег принят.
3. `orders-api:2.0` создан: порт `5001` лежит в предпоследнем сегменте, а тег `2.0` в последнем.
4. `localhost:5001/orders-api` отклонён: двоеточие порта не принято за тег.
5. Образ с дайджестом создан: он закреплён навсегда.

**Итог.**

| Что узнали | Где видно |
|---|---|
| Привязка выбирает область через `namespaceSelector` | шаг 1 |
| Warn показывает нарушения без отказов | шаг 2 |
| Тег ищется в последнем сегменте пути | шаг 3, `localhost:5001/orders-api` |

**Уборка.** Удаляем привязку, политику, метку и поды, созданные работой.

```bash
kubectl delete validatingadmissionpolicybinding no-latest-tag
kubectl delete validatingadmissionpolicy no-latest-tag
kubectl label ns lab-06-3b lab-06-3/images-
kubectl -n lab-06-3b delete pod --all
```

**Вопросы для самопроверки.**

1. Почему политика без привязки ничего не проверяет?
2. Зачем выражение ищет тег в последнем сегменте пути?
3. Почему сначала включают `Warn`, а не `Deny`?

<details>
<summary>Ответы</summary>

1. Политика хранит только логику. Область, параметры и действие задаёт привязка, и без неё API-сервер не знает, к чему применять правило.
2. Порт реестра (`localhost:5001`) тоже содержит двоеточие. Без выбора последнего сегмента образ без тега прошёл бы проверку.
3. Warn показывает, кого заденет правило, и ничего не ломает. Когда предупреждений нет, действие меняют на Deny.

</details>

### Лабораторная работа 4. MutatingAdmissionPolicy: значение по умолчанию на CEL

Эту работу вы выполняете сами, результаты в ней — ожидаемые.

**Риски.** Работа создаёт объекты уровня кластера: политику мутации и привязку.

- **Что меняется:** `MutatingAdmissionPolicy` и привязка `lab-06-3-default-seccomp`, namespace `lab-06-3c` с метками.
- **Надолго ли:** до уборки; мутация действует только на namespace с меткой `lab-06-3/mutate=on`.
- **Безопасность:** мутация добавляет `seccompProfile` и метку, привилегий не нужно.
- **Влияние на систему:** другие namespace не затронуты.
- **Откат:** блок «Уборка». Нужен кластер версии 1.36 или новее: в старых версиях функция выключена, а версия API другая.

**Цель.** Написать политику мутации, которая задаёт seccomp по умолчанию и добавляет метку, и увидеть, что PSA проверяет под уже после мутации.

**Что понадобится.**

- Kubernetes 1.36 (стенд).
- Образ `busybox:1.37`.
- Около 20 минут.

**Схема опыта.**

```
kubectl run ──► MAP (mutating): добавить seccompProfile и метку
            ──► PSA warn=restricted (validating): видит уже изменённый под
```

Схема 7. Мутация идёт раньше проверки, поэтому предупреждение PSA не упоминает seccomp.

#### Шаг 1. Создать namespace, политику и привязку

Команда создаёт namespace с PSA в режиме warn и политику с двумя мутациями.

```bash
kubectl create ns lab-06-3c
kubectl label ns lab-06-3c lab-06-3/mutate=on \
  pod-security.kubernetes.io/warn=restricted
kubectl apply -f - <<'EOF'
apiVersion: admissionregistration.k8s.io/v1
kind: MutatingAdmissionPolicy
metadata: {name: lab-06-3-default-seccomp}
spec:
  failurePolicy: Fail
  reinvocationPolicy: Never
  matchConstraints:
    resourceRules:
    - {apiGroups: [""], apiVersions: [v1], operations: [CREATE], resources: [pods]}
  matchConditions:
  - name: no-seccomp
    expression: "!has(object.spec.securityContext) ||
      !has(object.spec.securityContext.seccompProfile)"
  mutations:
  - patchType: ApplyConfiguration
    applyConfiguration:
      expression: >-
        Object{
          spec: Object.spec{
            securityContext: Object.spec.securityContext{
              seccompProfile: Object.spec.securityContext.seccompProfile{
                type: "RuntimeDefault"
              }
            }
          }
        }
  - patchType: JSONPatch
    jsonPatch:
      expression: >-
        [JSONPatch{op: "add",
          path: "/metadata/labels/" + jsonpatch.escapeKey("lab-06-3/mutated"),
          value: "true"}]
---
apiVersion: admissionregistration.k8s.io/v1
kind: MutatingAdmissionPolicyBinding
metadata: {name: lab-06-3-default-seccomp}
spec:
  policyName: lab-06-3-default-seccomp
  matchResources:
    namespaceSelector: {matchLabels: {lab-06-3/mutate: "on"}}
EOF
```

| Часть команды | Значение |
|---|---|
| `warn=restricted` | PSA предупреждает о нарушениях restricted |
| `reinvocationPolicy: Never` | обязательное поле: мутировать один раз |
| `matchConditions … no-seccomp` | мутировать, только если seccomp не задан |
| `patchType: ApplyConfiguration` | слить указанные поля с объектом |
| `Object.spec.securityContext{…}` | построить вложенный объект по схеме пода |
| `patchType: JSONPatch` | выполнить операцию `add`; метка `run` уже есть |
| `jsonpatch.escapeKey(…)` | экранировать `/` в имени метки |
| `namespaceSelector` | область: только namespace с меткой |

Результат: `namespace/lab-06-3c created`, `namespace/lab-06-3c labeled`, затем две строки `created` для политики и привязки; вывод ожидаемый.

#### Шаг 2. Создать под и прочитать результат мутации

Команда запускает под в помеченном namespace и читает поле seccomp и метки.

```bash
sleep 3
kubectl -n lab-06-3c run m1 --image=busybox:1.37 -- sleep 60
kubectl -n lab-06-3c get pod m1 \
  -o jsonpath='{.spec.securityContext.seccompProfile.type}{"\n"}{.metadata.labels}{"\n"}'
```

| Часть команды | Значение |
|---|---|
| `sleep 3` | пауза, пока API-сервер загрузит политику |
| `run m1` | под без `securityContext` |
| `jsonpath … seccompProfile.type` | значение, которое добавила мутация |
| `.metadata.labels` | все метки пода |

Ожидаемый результат (порядок ключей меток может быть другим):

```
Warning: would violate PodSecurity "restricted:latest": allowPrivilegeEscalation != false …
pod/m1 created
RuntimeDefault
{"lab-06-3/mutated":"true","run":"m1"}
```

Разбор:

1. Предупреждение PSA не упоминает `seccompProfile` — мутация выполнилась раньше проверки и закрыла это нарушение.
2. В предупреждении остались остальные нарушения: их мутация не трогает.
3. `RuntimeDefault` — значение из `ApplyConfiguration`.
4. Метка `lab-06-3/mutated` — результат JSONPatch; ключ с `/` экранирован.

#### Шаг 3. Проверить, что заданный seccomp не перезаписывается

Команда создаёт под, в котором автор уже указал другой профиль.

```bash
kubectl -n lab-06-3c apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata: {name: m2, labels: {run: m2}}
spec:
  securityContext:
    seccompProfile: {type: Unconfined}
  containers:
  - {name: c, image: "busybox:1.37", command: ["sleep", "60"]}
EOF
kubectl -n lab-06-3c get pod m2 -o jsonpath='{.spec.securityContext.seccompProfile.type}{"\n"}'
```

Ожидаемый результат (строка предупреждения сокращена):

```
Warning: would violate PodSecurity "restricted:latest": … seccompProfile (pod must not set
securityContext.seccompProfile.type to "Unconfined") …
pod/m2 created
Unconfined
```

Разбор: условие `matchConditions` не пропустило этот под, потому что `seccompProfile` уже задан. Значение автора осталось, и нарушение попало в предупреждение PSA. Под создан, потому что у namespace нет метки enforce, а `Unconfined` запрещён уже на baseline. Без такого условия `ApplyConfiguration` перезаписал бы выбор автора.

**Итог.**

| Что узнали | Где видно |
|---|---|
| MAP меняет объект до проверки PSA | шаг 2, предупреждение без seccomp |
| ApplyConfiguration добавляет поля, JSONPatch — точечные операции | шаг 2, значение и метка |
| `matchConditions` защищают значения автора | шаг 3 |

**Уборка.**

```bash
kubectl delete mutatingadmissionpolicybinding lab-06-3-default-seccomp
kubectl delete mutatingadmissionpolicy lab-06-3-default-seccomp
kubectl delete ns lab-06-3c lab-06-3 lab-06-3b
```

Удаление namespace удаляет все поды работ вместе с ним.

**Вопросы для самопроверки.**

1. Почему предупреждение PSA не называет seccomp?
2. Зачем в политике условие `matchConditions`?
3. Когда JSONPatch удобнее ApplyConfiguration?

<details>
<summary>Ответы</summary>

1. Mutating admission идёт раньше validating. Когда PSA проверяет под, поле `seccompProfile` уже добавлено мутацией.
2. Оно ограничивает мутацию подами без заданного поля. Без условия `ApplyConfiguration` перезаписал бы профиль, который указал автор манифеста.
3. Когда нужна одна точная операция: заменить значение, удалить поле или проверить его через `test`. ApplyConfiguration удобнее для «добавить поле целиком».

</details>

---

## → Дальше

Мы научились решать, какой объект кластер примет и как его изменит, но пока не знаем, кто и когда эти решения принимал. Следующая часть, 06-4, добавляет журнал: аудит API-сервера записывает запросы и аннотации нарушений, которые мы здесь упоминали. Там же та же механика VAP из §2 ограничит образы: разрешённые реестры и дайджесты, а проверка подписи покажет, где VAP не справляется.
