# 07-3. Kustomize

> Модуль 07 «Пакетирование» · часть 3 из 3 · ~1,5 ч чтения + ~1 ч лабы · Нужно: стенд 00-1 (контекст `kind-lab`), kubectl 1.36 со встроенным Kustomize v5.8.1, Helm и чарт orders-api из 07-1, образы `orders-api:2.0` и `2.1` в реестре стенда · Опирается на: 07-1 (чарт и values), 04-1 (ConfigMap и переменные окружения), 02-2 (Deployment, rollout, селектор)

## Где мы на карте

Эта часть закрывает модуль 07 и показывает второй способ собирать манифесты. Helm (07-1, 07-2) строит их из шаблонов и values, а Kustomize берёт обычный YAML и правит его патчами. Часть опирается на 07-1: чарт orders-api понадобится в лабораторной работе 3, где Kustomize вызывает Helm. ConfigMap и переменные окружения из 04-1 объясняют, почему хэш в имени перезапускает поды. Селектор Deployment из 02-2 объясняет, почему метки нельзя добавлять в селектор.

Следующий модуль строит на этой части GitOps: в 08-1 Argo CD берёт каталог Kustomize из Git и применяет его в кластер.

```
Git: base + overlays      Kustomize (kubectl)        кластер
┌──────────────────┐      ┌──────────────────┐      ┌──────────────┐
│ обычный YAML     │ ───► │ сборка и патчи   │ ───► │ kubectl apply│
│ + kustomization  │      │ (07-3, эта часть)│      │ или Argo CD  │
└──────────────────┘      └──────────────────┘      │ (08-1)       │
        ▲                          ▲                └──────────────┘
        │                          └── helmCharts: чарт из 07-1 как источник
        └── 07-1, 07-2: чарт и values — альтернативный путь
```

Схема 1. Место Kustomize между Git и кластером: на входе обычные манифесты, на выходе тоже обычные манифесты.

---

## 1. Какую задачу решает Kustomize

Kustomize отвечает на вопрос, как держать одно приложение в нескольких окружениях и не копировать манифесты. Разберём, чем плохи простые решения, как Kustomize обходится без шаблонов и когда выбрать Helm.

### Отличия окружений без копипасты

Staging и prod почти одинаковы: те же Deployment и Service, но разные тег образа, число реплик, ресурсы и namespace. Самый простой путь — отдельный каталог манифестов на окружение. Он расходится за месяц, потому что правку внесли в один каталог и забыли в другом.

Второй путь — `sed` или `envsubst` в CI, который подставляет значения в текст файла. Он ничего не проверяет: спецсимвол в значении ломает YAML, а ошибку находит только `kubectl apply`. Оба пути относятся к анти-рецептам.

**Kustomize** — инструмент, который собирает манифесты из общей части и небольших отличий, а на выходе даёт обычный YAML. Общая часть лежит в **base** (основа) — каталоге с манифестами и файлом `kustomization.yaml`. Отличия окружения лежат в **overlay** (наложение) — каталоге, который ссылается на base и меняет его.

```
orders-api/
  base/                  общие Deployment и Service
    deployment.yaml  service.yaml  kustomization.yaml
  overlays/
    staging/             namespace, тег 2.1, флаг функции, HTTPRoute
    prod/                namespace, 3 реплики, дайджест, ресурсы
```

Схема 2. Дерево каталогов: base один, overlay по одному на окружение; каждый overlay ссылается на `../../base`.

### Патчи вместо шаблонов

Kustomize не знает условий и циклов, и это сделано намеренно. Файлы base остаются настоящими манифестами, которые можно применить и без Kustomize. Отличия окружения описывают **патчи** (patches) — фрагменты, которые меняют отдельные поля объектов. Поэтому на вопрос «что получится в prod» отвечает одна команда сборки, а не рендер шаблона с десятком values.

Цена такого подхода — ограничение. Патч меняет то, что уже есть в base, а вставить блок по условию нельзя. Если окружения различаются структурно, base превращается в набор уступок, и тогда лучше шаблон.

### Helm, Kustomize или оба

Выбор между инструментами зависит от того, чей это код и чем окружения отличаются.

| Вопрос | Helm | Kustomize |
|---|---|---|
| Модель | шаблоны и values | обычный YAML и патчи |
| Условия и циклы | да | нет, намеренно |
| Пакеты, версии, репозитории | да, чарты и OCI | нет, только Git и URL |
| Релиз, история, откат | да, записи в Secret | нет, состояние в Git |
| Hooks | да | нет |
| Что получится | нужно рендерить | видно почти сразу |

Практичное правило такое: сторонние компоненты ставят чартами вендора, а свои сервисы с отличиями по окружениям собирают Kustomize. Чужой чарт без форка дорабатывают Kustomize поверх Helm (§3). Форк чарта ради одной правки — ещё один анти-рецепт, потому что каждое обновление вендора придётся переносить вручную. В GitOps (08-1) работают оба инструмента, и состояние релиза хранит Git, а не Helm.

---

## 2. Как устроен Kustomize

Сборка в Kustomize — это чтение файла `kustomization.yaml`, загрузка ресурсов и применение преобразований в фиксированном порядке. Рассмотрим сам файл, порядок сборки и генераторы, которые меняют имена объектов.

### Kustomization и его поля

**Kustomization** — каталог с файлом `kustomization.yaml`, который описывает одну сборку. Файл начинается со строк `apiVersion: kustomize.config.k8s.io/v1beta1` и `kind: Kustomization`, а дальше идут поля. Главные поля такие:

- `resources` — файлы, каталоги и другие kustomization, которые войдут в сборку; overlay так подключает base.
- `namespace`, `labels`, `commonAnnotations` — одно значение для всех объектов.
- `images`, `replicas` — тег, дайджест и имя образа, число реплик, без патчей.
- `patches` — правки отдельных полей (§3).
- `configMapGenerator`, `secretGenerator` — создают ConfigMap и Secret из литералов и файлов.
- `components` — общие куски для нескольких overlay (§3).

Поля `replacements` и `helmCharts` разобраны ниже, в §3. Все пути в файле считаются от его каталога.

### Порядок сборки

Kustomize сначала загружает ресурсы и запускает генераторы, а затем применяет **трансформеры** (transformers) — встроенные операции над объектами: патчи, namespace, метки, образы, реплики, замены. Порядок трансформеров зашит в программу, и порядок полей в файле на него не влияет. Патчи идут первыми, `replicas` — раньше `images`, а `replacements` стоят в конце.

```
resources ──► объекты ─┐
generators ─► объекты ─┼─► patches → namespace → labels → replicas → images → replacements ─► YAML
helmCharts ─► объекты ─┘
```

Схема 3. Конвейер сборки: слева источники объектов, справа вывод; в середине трансформеры в порядке применения.

Результат сборки печатается в stdout, а кластер при этом не нужен. Команды `kubectl apply -k` и `kubectl diff -k` собирают то же самое и затем обращаются к API-серверу.

### Генератор и хэш в имени

**Генератор** (generator) — поле, которое создаёт объект по описанию. `configMapGenerator` строит ConfigMap из литералов, файлов или env-файлов и добавляет к имени **хэш** — суффикс из 10 знаков, который считается от содержимого. Затем Kustomize находит ссылки на этот ConfigMap в Deployment (`envFrom`, `env`, `volumes`) и подставляет новое имя.

```
FEATURE_DISCOUNT=on   ──хэш──►  ConfigMap orders-env-hcdt7bmb5c ◄── ссылка в шаблоне пода
FEATURE_DISCOUNT=half ──хэш──►  ConfigMap orders-env-65k4tf7cd9 ◄── шаблон изменился → rollout
```

Схема 4. Изменили литерал, поменялось имя ConfigMap, поменялся шаблон пода, и Deployment перезапустил поды.

Это единственный способ Kustomize сделать конфигурацию частью шаблона пода. Переменные окружения из ConfigMap читаются при старте контейнера (04-1), и без смены шаблона поды остаются со старыми значениями. В Helm ту же задачу решает аннотация `checksum/config` (07-1). Хэш можно отключить через `generatorOptions: {disableNameSuffixHash: true}`, но тогда перезапуск придётся организовывать самому.

**generatorOptions** — общие настройки всех генераторов одного kustomization. Кроме `disableNameSuffixHash` в нём есть ещё три поля:

- `labels` — метки, которые получат все созданные генераторами объекты.
- `annotations` — аннотации для тех же объектов.
- `immutable` — флаг, который делает созданные ConfigMap и Secret неизменяемыми (04-1).

Хэш считается от имени и поля `data`, а у Secret ещё от `type`. Суффикс — первые 10 знаков SHA-256, в которых часть цифр и букв заменена.

---

## 3. Как управлять сборкой

Сборкой управляют через поля kustomization и команды kubectl. Ниже идут карточка инструмента, патчи, простые трансформеры, компоненты с заменами и Helm-чарт внутри Kustomize.

### Карточка инструмента: Kustomize

**Назначение.** Kustomize собирает манифесты окружения из base и overlay и печатает обычный YAML. Он нужен, чтобы хранить различия окружений в Git как небольшие патчи.

**Как работает.** Команда читает каталог, собирает объекты и печатает результат, а `apply -k` отправляет его в кластер.

```
kubectl kustomize DIR ─► сборка ─► YAML в stdout
kubectl apply -k DIR  ─► сборка ─► kubectl apply  ─► API-сервер
kubectl diff -k DIR   ─► сборка ─► сравнение с кластером
```

Схема 5. Одна и та же сборка стоит за тремя командами; только `diff` и `apply` обращаются к кластеру.

**Откуда берёт данные.** Из локальных каталогов, из Git по URL (`github.com/org/repo//path?ref=v1.0`) и из Helm-чартов через `helmCharts`. Удалённый источник закрепляют тегом или коммитом, иначе сборка меняется без вашего изменения.

**Основные команды.** Блок ниже показывает основные команды; каждую поясняет комментарий.

```bash
kubectl kustomize overlays/prod         # собрать и вывести YAML, кластер не нужен
kubectl apply -k overlays/prod          # собрать и применить в кластер
kubectl diff -k overlays/prod           # показать разницу с кластером; код 1 — есть правки
kubectl delete -k overlays/prod         # удалить все объекты сборки
kubectl get -k overlays/prod            # показать состояние объектов сборки
kubectl kustomize --enable-helm DIR     # разрешить helmCharts (нужен helm в PATH)
```

**Команды для скриптов.** В скриптах и CI нужны проверяемые коды выхода и стабильный вывод. Правка самого файла `kustomization.yaml` из CI — подкоманда `kustomize edit`, которая есть только в отдельном бинарнике, а в kubectl её нет.

```bash
kubectl kustomize overlays/prod > /tmp/prod.yaml        # сохранить сборку как артефакт
kubectl apply -k overlays/prod --dry-run=server         # проверить на сервере, не применяя
kubectl diff -k overlays/prod; echo "exit=$?"           # 0 — без правок, 1 — есть, >1 — ошибка
kubectl kustomize --enable-helm --load-restrictor=LoadRestrictionsNone DIR | \
  kubectl apply -f -                                    # единственный путь для helmCharts
kustomize edit set image \
  localhost:5001/orders-api:2.1                         # сменить тег в images текущего каталога
kustomize edit fix                                      # перевести устаревшие поля на новые
```

**Частые ошибки.**

- `kubectl apply -k` не принимает `--enable-helm`: сборку с Helm пускают через конвейер.
- Файл вне каталога kustomization не читается: сработал ограничитель загрузки (§5).
- Метки попали в селектор Deployment, и обновление отклонено (§5).
- Старые ConfigMap от генератора копятся, пока их не уберёт prune (§5).
- Helm 4 в PATH, а Kustomize старше 5.8.1: сборка с `helmCharts` падает, поддержку Helm 4 добавили в 5.8.1.

**Установка.** Отдельно ставить Kustomize не нужно: он встроен в kubectl. Версию встроенного показывает `kubectl version --client` строкой `Kustomize Version`, и у kubectl 1.36 это v5.8.1. Версия 5.8.0 ломала распространение `namespace`, а 5.8.1 исправила это и добавила поддержку Helm 4. Отдельный бинарник нужен для `kustomize edit` и когда встроенный отстаёт: на октябрь 2026 последняя версия — 5.8.3.

```bash
V=v5.8.1
curl -fsSL -o /tmp/kustomize.tgz \
  "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2F${V}/\
kustomize_${V}_linux_amd64.tar.gz"
sudo tar -xz -C /usr/local/bin -f /tmp/kustomize.tgz kustomize
```

Команды выше относятся к Ubuntu: переменная `V` задаёт версию, `curl` скачивает архив релиза, а `tar` кладёт бинарник в `/usr/local/bin`. Обратная косая черта внутри кавычек склеивает адрес в одну строку. На Manjaro достаточно `sudo pacman -S kustomize`. Отдельный бинарник запускают как `kustomize build DIR`.

### Патчи: strategic merge и JSON 6902

Поле `patches` меняет отдельные поля объекта и принимает патч двух видов. **Strategic merge patch** — кусок YAML, который сливается с объектом. Kustomize ищет в списках элементы по ключу слияния (контейнеры по `name`, порты по `containerPort`) и правит только указанное. **JSON 6902** — список операций `add`, `remove`, `replace`, `move`, `copy` и `test`, у каждой есть путь к полю.

```yaml
patches:
- path: resources.yaml            # strategic merge: контейнер api найден по имени
- target: {kind: Deployment, name: orders-api}
  patch: |-                       # JSON 6902: операции по пути
    - op: add
      path: /spec/template/spec/containers/0/env/-
      value: {name: SHUTDOWN_DELAY, value: "10"}
    - op: add
      path: /spec/template/spec/terminationGracePeriodSeconds
      value: 40
```

Фрагмент kustomization: первый патч лежит в файле, второй записан прямо в поле. Файл `resources.yaml` содержит часть Deployment с контейнером `api` и его блоком `resources`.

Strategic merge короче и читается как обычный манифест, но для списков без ключа слияния (например, `command`) он заменяет весь список. JSON 6902 точнее, зато ходит по индексам: путь `containers/0` сломается, когда в base поменяют порядок контейнеров. Удалять поля проще операцией `remove` или строкой `$patch: delete` в strategic merge. Поле `target` выбирает объекты по `kind`, `name`, `namespace` и селекторам меток; у strategic merge без `target` объект определяют по имени внутри патча.

### Простые трансформеры вместо патчей

Для частых правок есть отдельные поля, и они надёжнее патчей, потому что не зависят от пути в манифесте.

```yaml
namespace: lab-07-3-prod
replicas:
- name: orders-api
  count: 3
images:
- name: localhost:5001/orders-api
  digest: sha256:ad4f8fd2…        # newTag или newName — другие варианты
labels:
- pairs: {app.kubernetes.io/part-of: orders}
  includeSelectors: false
```

Фрагмент kustomization: `images` ищет образ по имени во всех контейнерах и меняет тег, имя или дайджест. `namespace` ставит namespace всем объектам, но не трогает ссылки на чужие namespace, например `parentRefs` в HTTPRoute. Поле `labels` по умолчанию добавляет метки только в `metadata` объектов. Флаги `includeSelectors` и `includeTemplates` добавляют их в селекторы и шаблоны подов, и на эти флаги нужно смотреть внимательно (§5).

### Компоненты и замены

**Component** — переиспользуемый кусок конфигурации, который подключают в нескольких overlay. У него другой `kind` и версия API `v1alpha1`, а подключает его поле `components` в overlay.

```yaml
# components/graceful/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1alpha1
kind: Component
patches:
- target: {kind: Deployment}
  patch: |-
    - op: add
      path: /spec/template/spec/terminationGracePeriodSeconds
      value: 30
# overlays/prod/kustomization.yaml
components: [../../components/graceful]
```

Фрагменты двух файлов: компонент добавляет время остановки всем Deployment, а prod подключает его строкой `components`, и staging может обойтись без него. Так общие правки (securityContext, пробы, время остановки) пишут один раз, а не копируют по overlay.

**Replacement** (замена) — правило, которое копирует значение одного поля в другое прямо во время сборки. Оно заменило устаревшие `vars` и нужно, когда одно и то же значение встречается в разных объектах.

```yaml
replacements:
- source: {kind: Service, name: orders-api, fieldPath: metadata.name}
  targets:
  - select: {kind: Deployment, name: orders-api}
    fieldPaths: [spec.template.spec.containers.[name=api].env.[name=SELF_HOST].value]
```

Фрагмент kustomization: правило берёт имя Service и записывает его в переменную `SELF_HOST` контейнера `api`. Переменная в Deployment должна уже существовать с любым значением-заглушкой, иначе сборка падает с ошибкой `unable to find field … in replacement target`. Создать отсутствующее поле разрешает `options: {create: true}` у цели. Если Kustomize добавит к имени префикс или хэш, замена получит итоговое имя.

### Helm-чарт внутри Kustomize

Поле `helmCharts` рендерит Helm-чарт во время сборки, и поверх результата работают обычные патчи. Это путь для чужого чарта, который нужно подправить без форка: values задают штатные параметры, а патчи закрывают всё, чего в values нет.

```
helmCharts: чарт + values ─► helm template ─► объекты ─► патчи Kustomize ─► YAML
```

Схема 6. Kustomize вызывает `helm template` из PATH, поэтому Helm должен быть установлен (07-1).

Kustomize принимает Helm 3 и Helm 4: перед сборкой он запускает `helm version --short` и отказывает другим мажорным версиям. Helm 4 поддерживается с Kustomize 5.8.1, то есть встроенный в kubectl 1.36 работает с Helm 4.2 стенда. Другой бинарник задаёт флаг `--helm-command`.

```yaml
helmGlobals: {chartHome: ../../../../charts}
helmCharts:
- name: orders-api
  releaseName: shop
  valuesInline: {route: {hostname: helm.lab073.localhost}, image: {tag: "2.1"}}
```

Фрагмент kustomization: `chartHome` — каталог с чартами, `releaseName` — имя релиза для шаблонов, `valuesInline` — values прямо в файле. Релиз Helm при этом не создаётся: `helm list` останется пустым, а hooks чарта не выполняются как hooks. Подробности и три ловушки — в §5 и в лабораторной работе 3.

---

## 4. Как увидеть состояние

Kustomize не хранит состояния, поэтому смотреть приходится на три вещи: результат сборки, разницу с кластером и сами объекты. Разберём каждую по очереди.

### Сборка как проверка

Команда `kubectl kustomize DIR` показывает, что именно уйдёт в кластер, и её запускают до любого применения. В сборке проверяют четыре места: имена с хэшем у ConfigMap и ссылки на них, `metadata.namespace` у каждого объекта, `image` в контейнерах и число `replicas`. Длинный вывод сужают через `grep -E`, как в лабораторной работе 1.

### Разница с кластером

Команда `kubectl diff -k DIR` сравнивает сборку с живыми объектами и печатает разницу, а кластер не меняет. Код выхода однозначен: 0 значит «разницы нет», 1 значит «есть изменения», больше 1 значит ошибку. Поэтому diff годится как проверка в CI: код 1 не авария, а сигнал, что применение что-то изменит.

### Объекты после применения

После `kubectl apply -k` объекты ничем не отличаются от созданных вручную, кроме меток и аннотаций, которые вы сами задали. Команда `kubectl get -k DIR` показывает состояние объектов сборки, а `rollout status` (02-2) ждёт готовности Deployment. Истории релизов в Kustomize нет: откат делают через Git, то есть возвращают коммит и применяют каталог заново, а быстрый откат ReplicaSet даёт `rollout undo` (02-2).

---

## 5. Что ломается и как найти причину

Поломки Kustomize тихие: сборка проходит, а поведение отличается от ожидаемого. Основные случаи ниже, и начинать поиск всегда стоит с вывода `kubectl kustomize`.

### Конфигурация не доходит до подов

Если ConfigMap изменили, а поды не перезапустились, причина в имени. Генератор меняет имя вместе с содержимым и тем перезапускает поды (§2). Обычный ConfigMap в `resources` меняет только содержимое, а переменные окружения подов фиксируются при старте (04-1).

Частая ловушка — разные механизмы в разных overlay: в staging генератор, в prod статический файл. Тогда staging заметит изменение, а prod нет. Правило простое: механизм одинаков во всех overlay, различаются только значения.

### Селекторы и метки

Селектор Deployment неизменяем (02-2), поэтому метки в нём ломают обновление. Если включить `includeSelectors: true` у `labels` (так вёл себя устаревший `commonLabels`), Kustomize добавит метки и в селектор. Применение на существующий Deployment тогда завершится ошибкой неизменяемого поля. Оставляйте `includeSelectors: false` и проверяйте сборку.

### Патч не сработал

JSON 6902 ходит по индексам и ломается, когда порядок элементов в base меняется. Strategic merge ошибается тише: если имя контейнера в патче не совпало с base, он добавит второй контейнер вместо правки первого. Проверка одна: смотрите в сборке именно то поле, которое должен был изменить патч.

### Старые ConfigMap и prune

Генератор не удаляет прежние ConfigMap: старый остаётся, и откат ReplicaSet находит свою конфигурацию, но такие ConfigMap копятся. Чистит их `kubectl apply -k DIR --prune -l <метка>`. Prune удаляет всё, что имеет метку и отсутствует в сборке, поэтому метка должна быть уникальной для набора, иначе команда удалит чужое.

Kubectl при этом предупреждает об устаревшем `v1 Endpoints`, потому что перебирает типы из встроенного списка, а Endpoints в нём есть. Сам режим prune по списку типов до сих пор в альфе. В GitOps чистку делает инструмент (08-1).

### Ошибки helmCharts

Сборка с Helm падает в трёх известных местах. Во-первых, нужен флаг `--enable-helm`, а `kubectl apply -k` его не принимает: сообщение `must specify --enable-helm`. Во-вторых, ограничитель загрузки не разрешает читать чарт вне каталога kustomization: сообщение `security; file '…' is not in or below '…'`.

В-третьих, `namespace` может не примениться к объектам из `helmCharts`. На Kustomize v5.8.1 ни ConfigMap, ни Deployment, ни Service не получили `metadata.namespace`. Без явного `-n` объекты уйдут в namespace текущего контекста, поэтому проверяйте вывод сборки и задавайте namespace при применении.

---

## 6. Пределы и значения по умолчанию

Ниже собраны версии и значения по умолчанию, от которых зависит поведение сборки.

### Версии

- kubectl 1.36 встраивает Kustomize v5.8.1; версия 5.8.0 нарушала распространение `namespace`.
- Последний отдельный релиз на октябрь 2026 — Kustomize 5.8.3; `helmCharts` работает с Helm 3 и Helm 4.
- Версия API kustomization — `kustomize.config.k8s.io/v1beta1`, компонентов — `v1alpha1`.
- Argo CD (08-1) использует свой Kustomize, и его версия может отличаться от встроенной в kubectl.
- В Argo CD 3.5.4 и новее Kustomize-сборки с Helm не учитывают `helmGlobals.configHome` (релизные заметки, октябрь 2026).
- В октябре 2026 Argo CD исправил уязвимость: удалённая ссылка Kustomize запускала команды в repo-server (версии 3.3.15, 3.4.10, 3.5.4). Удалённые источники закрепляйте коммитом и держите Argo CD не ниже исправленной версии.

### Значения по умолчанию

- Суффикс хэша у генератора — 10 знаков, считается от содержимого.
- `behavior` генератора — `create`; значения `merge` и `replace` меняют уже существующий ConfigMap.
- Ограничитель загрузки — `LoadRestrictionsRootOnly`: файлы читаются только из каталога kustomization и ниже.
- `generatorOptions`: хэш включён, `immutable` выключен.
- `labels`: `includeSelectors` и `includeTemplates` по умолчанию выключены.
- `kubectl diff`: коды выхода 0, 1 и больше 1 (§4).

### Что устарело

Kustomize 5 ещё читает устаревшие поля, но печатает предупреждение и подсказку запустить `kustomize edit fix`. Эта команда переписывает файл на новые поля:

- `bases` — заменено на `resources`.
- `patchesStrategicMerge` и `patchesJson6902` — заменены на `patches`.
- `commonLabels` — заменено на `labels`; старое поле всегда меняет и селекторы.
- `vars` — заменено на `replacements` и будет удалено.
- `imageTags` — заменено на `images`.

В новых kustomization старые поля не используйте. Для отслеживания собранных объектов готовится механизм ApplySet (в kubectl он пока в альфе и включается переменной `KUBECTL_APPLYSET=true`), а до его готовности остаётся prune по метке.

---

## Лабораторные работы

Работы идут на стенде 00-1 и используют три namespace с общим префиксом: `lab-07-3-staging`, `lab-07-3-prod` и `lab-07-3-helm`. Каждая работа создаёт и удаляет свой namespace. Файлы лежат в `~/lab/k8s/07-3/orders-api`, и работы 2 и 3 используют base из работы 1, поэтому выполняйте их по порядку.

Контекст kubectl не меняем. Перед началом проверьте, что активен кластер стенда.

```bash
kubectl config current-context
```

Команда печатает имя активного контекста. Ожидаемый ответ — `kind-lab`; если он другой, переключите контекст сами до начала работ.

### Лабораторная работа 1. Base, overlay и генератор с хэшем

**Риски.** Работа меняет только кластер стенда и каталог `~/lab/k8s/07-3`; хост не затрагивается.

- **Что меняется:** создаётся namespace `lab-07-3-staging` с Secret, Deployment, Service, HTTPRoute и ConfigMap; на хосте появляются файлы base и overlay.
- **Надолго ли:** namespace живёт до уборки работы, каталог остаётся для работ 2 и 3 и для 08-1.
- **Безопасность:** привилегий не нужно; пароль базы учебный, из 00-1.
- **Влияние на систему:** один под orders-api с запросом 100m CPU и 64 МиБ; `--prune` ограничен меткой и namespace работы.
- **Откат:** `kubectl delete ns lab-07-3-staging`.

**Цель.** Собрать base и overlay staging, применить их и увидеть, как смена литерала генератора меняет имя ConfigMap и перезапускает поды.

**Что понадобится.**

- Стенд 00-1, образы `localhost:5001/orders-api:2.0` и `2.1`.
- Gateway `lab` и порт `127.0.0.1:8088` для проверки через HTTPRoute.
- Около 30 минут.

**Схема опыта.** Генератор в base задаёт значение флага, overlay переопределяет его; сравнивать нужно имена ConfigMap и ReplicaSet до и после правки.

```
base ──► overlay staging ──► namespace lab-07-3-staging
          │ configMapGenerator: FEATURE_DISCOUNT on ──► half
          └─ ConfigMap orders-env-<хэш> ──► ссылка в Deployment ──► rollout
```

Схема 7. Генератор в base задаёт `off`, overlay переопределяет значение; смотрите на имя ConfigMap и число ReplicaSet.

#### Шаг 1. Создать namespace и base

Команды создают каталог, namespace с Secret для базы и три файла base. Secret `postgres` нужен Deployment в каждом namespace, потому что он читает `DATABASE_URL` из него.

```bash
mkdir -p ~/lab/k8s/07-3/orders-api/{base,overlays/{staging,prod,helm,helm-chart}}
cd ~/lab/k8s/07-3/orders-api
kubectl create ns lab-07-3-staging
kubectl -n lab-07-3-staging create secret generic postgres \
  --from-literal=DATABASE_URL=postgresql://orders:orders-lab-pass@postgres.orders:5432/orders
cat > base/deployment.yaml <<'E'
apiVersion: apps/v1
kind: Deployment
metadata: {name: orders-api}
spec:
  replicas: 1
  selector: {matchLabels: {app: orders-api}}
  template:
    metadata: {labels: {app: orders-api}}
    spec:
      containers:
      - name: api
        image: localhost:5001/orders-api
        ports: [{name: http, containerPort: 8000}]
        envFrom: [{configMapRef: {name: orders-env}}]
        env:
        - name: DATABASE_URL
          valueFrom: {secretKeyRef: {name: postgres, key: DATABASE_URL}}
        readinessProbe: {httpGet: {path: /ready, port: http}, periodSeconds: 2}
        resources: {requests: {cpu: 100m, memory: 64Mi}, limits: {memory: 256Mi}}
E
cat > base/service.yaml <<'E'
apiVersion: v1
kind: Service
metadata: {name: orders-api}
spec:
  selector: {app: orders-api}
  ports: [{name: http, port: 80, targetPort: http}]
E
cat > base/kustomization.yaml <<'E'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources: [deployment.yaml, service.yaml]
labels:
- pairs: {app.kubernetes.io/part-of: orders}
  includeSelectors: false
configMapGenerator:
- name: orders-env
  literals: [FEATURE_DISCOUNT=off]
images:
- name: localhost:5001/orders-api
  newTag: "2.0"
E
```

| Часть команды | Значение |
|---|---|
| `mkdir -p …/{base,overlays/{…}}` | создать каталоги base и четыре overlay за один вызов |
| `create secret generic postgres` | Secret с адресом базы из стенда |
| `envFrom … name: orders-env` | ссылка на ConfigMap, которого в base нет: его создаст генератор |
| `labels … includeSelectors: false` | метка попадёт на объекты, но не в селектор |
| `configMapGenerator … literals` | ConfigMap `orders-env` с ключом `FEATURE_DISCOUNT=off` |
| `images … newTag: "2.0"` | подставить тег 2.0 в образ без тега |

Разбор: команды ничего не печатают, кроме строк `namespace/… created` и `secret/postgres created`. В base образ указан без тега намеренно: тег ставит поле `images`, и каждый overlay может заменить его.

#### Шаг 2. Собрать overlay staging

Команды создают overlay staging с HTTPRoute и собирают его, не обращаясь к кластеру. Overlay переопределяет литерал (`behavior: merge`), ставит тег 2.1 и namespace.

```bash
cd ~/lab/k8s/07-3/orders-api
cat > overlays/staging/kustomization.yaml <<'E'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: lab-07-3-staging
resources: [../../base, route.yaml]
configMapGenerator:
- name: orders-env
  behavior: merge
  literals: [FEATURE_DISCOUNT=on]
images:
- name: localhost:5001/orders-api
  newTag: "2.1"
E
cat > overlays/staging/route.yaml <<'E'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: orders-api}
spec:
  parentRefs: [{name: lab, namespace: envoy-gateway-system}]
  hostnames: ["staging.lab073.localhost"]
  rules: [{backendRefs: [{name: orders-api, port: 80}]}]
E
kubectl kustomize overlays/staging | \
  grep -E 'FEATURE|name: orders-env|image:|namespace:'
```

| Часть команды | Значение |
|---|---|
| `resources: [../../base, route.yaml]` | взять base и добавить свой HTTPRoute |
| `behavior: merge` | слить литералы с ConfigMap из base, а не создавать второй |
| `newTag: "2.1"` | заменить тег из base |
| `parentRefs … namespace: envoy-gateway-system` | ссылка на Gateway в чужом namespace |
| `kubectl kustomize overlays/staging` | собрать overlay и вывести YAML |
| `grep -E …` | оставить строки с флагом, именем ConfigMap, образом и namespace |

Результат (сокращено до значимых строк):

```
  FEATURE_DISCOUNT: "on"
  name: orders-env-hcdt7bmb5c
  namespace: lab-07-3-staging
…
            name: orders-env-hcdt7bmb5c
        image: localhost:5001/orders-api:2.1
  namespace: lab-07-3-staging
    namespace: envoy-gateway-system
```

Разбор:

1. `FEATURE_DISCOUNT: "on"` — значение overlay перекрыло `off` из base.
2. `orders-env-hcdt7bmb5c` — ConfigMap получил хэш в имени, и та же строка стоит в ссылке Deployment: Kustomize обновил ссылку сам.
3. `image: …:2.1` — тег подставило поле `images`.
4. `namespace: lab-07-3-staging` встречается у каждого из четырёх объектов сборки.
5. `namespace: envoy-gateway-system` в `parentRefs` не тронут: `namespace` не меняет ссылки на чужие namespace.

#### Шаг 3. Применить staging

Команда применяет сборку и ждёт, пока Deployment станет готов. Затем запрос через Gateway показывает конфигурацию, которую видит приложение.

```bash
cd ~/lab/k8s/07-3/orders-api
kubectl apply -k overlays/staging
kubectl -n lab-07-3-staging rollout status deploy/orders-api
curl -s -H 'Host: staging.lab073.localhost' http://127.0.0.1:8088/config; echo
```

| Часть команды | Значение |
|---|---|
| `apply -k overlays/staging` | собрать overlay и применить результат |
| `rollout status deploy/orders-api` | ждать готовности новой версии Deployment |
| `-H 'Host: staging.lab073.localhost'` | выбрать HTTPRoute по имени хоста |
| `:8088/config` | путь приложения, который показывает конфигурацию |

Результат (сокращено):

```
configmap/orders-env-hcdt7bmb5c created
…
deployment "orders-api" successfully rolled out
```

Разбор: ConfigMap создан под именем с хэшем, а Deployment стал готов. Ответ `/config` содержит `"env_FEATURE_DISCOUNT": "on"`: переменная пришла из ConfigMap через `envFrom`.

#### Шаг 4. Изменить литерал и увидеть перезапуск

Команды переписывают overlay с новым значением `half`, применяют его и сравнивают ReplicaSet и ConfigMap до и после.

```bash
cd ~/lab/k8s/07-3/orders-api
cat > overlays/staging/kustomization.yaml <<'E'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: lab-07-3-staging
resources: [../../base, route.yaml]
configMapGenerator:
- name: orders-env
  behavior: merge
  literals: [FEATURE_DISCOUNT=half]
images:
- name: localhost:5001/orders-api
  newTag: "2.1"
E
kubectl apply -k overlays/staging
kubectl -n lab-07-3-staging rollout status deploy/orders-api
kubectl -n lab-07-3-staging get rs,cm
curl -s -H 'Host: staging.lab073.localhost' http://127.0.0.1:8088/config; echo
```

| Часть команды | Значение |
|---|---|
| `literals: [FEATURE_DISCOUNT=half]` | новое значение флага, остальной файл прежний |
| `get rs,cm` | список ReplicaSet и ConfigMap namespace |

Результат (сокращено до значимых строк):

```
configmap/orders-env-65k4tf7cd9 created
…
deployment "orders-api" successfully rolled out
{"env_FEATURE_DISCOUNT": "half", …}
```

Разбор:

1. `orders-env-65k4tf7cd9` — другое содержимое дало другой хэш и новый ConfigMap.
2. Deployment перезапустил поды без вашей команды: шаблон пода изменился.
3. `get rs,cm` показывает два ReplicaSet (было 1, стало 2) и два ConfigMap: `orders-env-65k4tf7cd9` и `orders-env-hcdt7bmb5c`.
4. `half` в ответе подтверждает, что приложение увидело новое значение, хотя env из ConfigMap сам по себе не обновляется (04-1).

#### Шаг 5. Убрать старый ConfigMap

Команда применяет сборку ещё раз с флагом `--prune` и меткой набора. Метка `part-of=orders` есть у всех объектов сборки, потому что её задаёт base.

```bash
cd ~/lab/k8s/07-3/orders-api
kubectl apply -k overlays/staging --prune -l app.kubernetes.io/part-of=orders
kubectl -n lab-07-3-staging get cm
```

| Часть команды | Значение |
|---|---|
| `--prune` | удалить объекты с меткой, которых нет в сборке |
| `-l app.kubernetes.io/part-of=orders` | ограничить удаление объектами с этой меткой |

Результат (сокращено):

```
configmap/orders-env-hcdt7bmb5c pruned
```

Разбор:

1. `pruned` — старый ConfigMap с хэшем `hcdt7bmb5c` удалён: его нет в сборке, а метка совпала.
2. Kubectl может предупредить об устаревшем `v1 Endpoints`: prune перебирает типы из встроенного списка, и предупреждение не мешает.
3. `get cm` теперь показывает только `orders-env-65k4tf7cd9` и служебный `kube-root-ca.crt`.

**Итог.**

| Что узнали | Где видно |
|---|---|
| Overlay меняет namespace, образ и значения base без копирования | шаг 2, сборка |
| Ссылки на другие namespace Kustomize не меняет | шаг 2, `envoy-gateway-system` |
| Генератор меняет имя ConfigMap и тем перезапускает поды | шаг 4, `65k4tf7cd9` |
| Старые ConfigMap остаются и убираются prune | шаг 5, `pruned` |

**Уборка.**

```bash
kubectl delete ns lab-07-3-staging
```

Команда удаляет namespace вместе с объектами работы. Каталог `~/lab/k8s/07-3/orders-api` остаётся: он нужен в работах 2 и 3 и в 08-1.

**Вопросы для самопроверки.**

1. Почему после смены литерала поды перезапустились, хотя Deployment не менялся вручную?

<details><summary>Ответ</summary>
Генератор поменял имя ConfigMap, Kustomize подставил его в шаблон пода, а любое изменение шаблона вызывает rollout (02-2).
</details>

2. Чем `behavior: merge` отличается от `create`?

<details><summary>Ответ</summary>
`create` (по умолчанию) создаёт новый ConfigMap и ошибается, если такой уже есть; `merge` сливает литералы с ConfigMap из base.
</details>

3. Почему `--prune` без уникальной метки опасен?

<details><summary>Ответ</summary>
Prune удаляет всё, что имеет метку и отсутствует в сборке. С неточной меткой под удаление попадают чужие объекты.
</details>

### Лабораторная работа 2. Prod: патчи, образ по дайджесту, diff

**Риски.** Работа меняет только кластер стенда и каталог `~/lab/k8s/07-3`; хост не затрагивается.

- **Что меняется:** создаётся namespace `lab-07-3-prod` с тремя подами orders-api; в каталоге работы появляется overlay prod.
- **Надолго ли:** до уборки работы; overlay остаётся для 08-2.
- **Безопасность:** привилегий не нужно; к реестру стенда идёт один запрос на чтение заголовков.
- **Влияние на систему:** три пода по 250m CPU и 128 МиБ запроса, то есть 750m CPU и 384 МиБ на кластер.
- **Откат:** `kubectl delete ns lab-07-3-prod`.

**Цель.** Собрать overlay prod с двумя видами патчей, образом по дайджесту и тремя репликами, а затем проверить его через `diff` и `apply`.

**Что понадобится.**

- Base из работы 1 в `~/lab/k8s/07-3/orders-api`.
- Образ `localhost:5001/orders-api:2.0` в реестре стенда `127.0.0.1:5001`.
- Около 20 минут.

**Схема опыта.** Один overlay вносит четыре отличия prod от base; проверять нужно сборку и поля готового Deployment.

```
base ──► overlay prod ─┬─ replicas: 3
                       ├─ images: digest sha256:…
                       ├─ patch 1 (strategic merge): resources контейнера api
                       └─ patch 2 (JSON 6902): env SHUTDOWN_DELAY, grace period 40 с
```

Схема 8. Четыре отличия prod от base: реплики, образ по дайджесту и два вида патчей.

#### Шаг 1. Создать namespace и узнать дайджест

Команды создают namespace с Secret и читают дайджест образа `2.0` из реестра стенда. Дайджест — хэш содержимого образа, поэтому тег `2.0` можно перезаписать, а дайджест нет.

```bash
cd ~/lab/k8s/07-3/orders-api
kubectl create ns lab-07-3-prod
kubectl -n lab-07-3-prod create secret generic postgres \
  --from-literal=DATABASE_URL=postgresql://orders:orders-lab-pass@postgres.orders:5432/orders
DIGEST=$(curl -sI \
  -H 'Accept: application/vnd.oci.image.index.v1+json' \
  -H 'Accept: application/vnd.oci.image.manifest.v1+json' \
  -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' \
  http://127.0.0.1:5001/v2/orders-api/manifests/2.0 | tr -d '\r' | \
  awk -F': ' 'tolower($1)=="docker-content-digest" {print $2}')
echo "$DIGEST"
```

| Часть команды | Значение |
|---|---|
| `curl -sI` | запросить только заголовки ответа реестра |
| `-H 'Accept: …'` | перечислить форматы манифеста, которые понимает клиент |
| `/v2/orders-api/manifests/2.0` | манифест образа с тегом 2.0 |
| `tr -d '\r'` | убрать возврат каретки из заголовков HTTP |
| `awk … docker-content-digest` | вынуть значение заголовка с дайджестом |

Результат (дайджест у вас будет другим):

```
sha256:ad4f8fd2…
```

Разбор: строка `sha256:…` — дайджест образа. Если переменная пуста, реестр недоступен или образ `2.0` не загружен (00-1).

#### Шаг 2. Написать overlay prod

Команда создаёт overlay с заменой реплик и образа и двумя патчами. Heredoc без кавычек подставляет `$DIGEST` в файл, а `sed` для этого не нужен.

```bash
cd ~/lab/k8s/07-3/orders-api
cat > overlays/prod/kustomization.yaml <<E
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: lab-07-3-prod
resources: [../../base]
replicas:
- name: orders-api
  count: 3
images:
- name: localhost:5001/orders-api
  digest: $DIGEST
patches:
- path: resources.yaml
- target: {kind: Deployment, name: orders-api}
  patch: |-
    - op: add
      path: /spec/template/spec/containers/0/env/-
      value: {name: SHUTDOWN_DELAY, value: "10"}
    - op: add
      path: /spec/template/spec/terminationGracePeriodSeconds
      value: 40
E
cat > overlays/prod/resources.yaml <<'E'
apiVersion: apps/v1
kind: Deployment
metadata: {name: orders-api}
spec:
  template:
    spec:
      containers:
      - name: api
        resources: {requests: {cpu: 250m, memory: 128Mi}, limits: {memory: 512Mi}}
E
kubectl kustomize overlays/prod | \
  grep -E 'replicas:|image:|SHUTDOWN|terminationGrace|cpu: 250m'
```

| Часть команды | Значение |
|---|---|
| `<<E` без кавычек | shell подставляет `$DIGEST` внутрь файла |
| `replicas … count: 3` | три реплики вместо одной |
| `digest: $DIGEST` | образ по дайджесту вместо тега |
| `path: resources.yaml` | strategic merge: файл с частью Deployment |
| `op: add … env/-` | JSON 6902: добавить переменную в конец списка `env` |
| `op: add … terminationGracePeriodSeconds` | JSON 6902: добавить поле, которого нет в base |

Результат (сокращено до значимых строк):

```
  replicas: 3
        - name: SHUTDOWN_DELAY
        image: localhost:5001/orders-api@sha256:ad4f8fd2…
            cpu: 250m
      terminationGracePeriodSeconds: 40
```

Разбор:

1. `replicas: 3` — поле `replicas` перекрыло одну реплику из base.
2. `image: …@sha256:…` — поле `images` с `digest` превратило тег в дайджест.
3. `cpu: 250m` — strategic merge нашёл контейнер `api` по имени и поменял только `resources`; остальные поля контейнера остались.
4. `SHUTDOWN_DELAY` и `terminationGracePeriodSeconds: 40` — результат двух операций JSON 6902.

#### Шаг 3. Сравнить с кластером и применить

Команды сравнивают сборку с пустым namespace, применяют её и читают поля готового Deployment.

```bash
cd ~/lab/k8s/07-3/orders-api
kubectl diff -k overlays/prod > /dev/null; echo "diff exit: $?"
kubectl apply -k overlays/prod
kubectl -n lab-07-3-prod rollout status deploy/orders-api
kubectl -n lab-07-3-prod get deploy orders-api -o jsonpath=\
'replicas={.status.readyReplicas} '\
'grace={.spec.template.spec.terminationGracePeriodSeconds} '\
'cpu={.spec.template.spec.containers[0].resources.requests.cpu}{"\n"}'
kubectl -n lab-07-3-prod get pods \
  -o jsonpath='{.items[0].status.containerStatuses[0].imageID}{"\n"}'
```

| Часть команды | Значение |
|---|---|
| `diff -k … > /dev/null` | сравнить и скрыть саму разницу |
| `echo "diff exit: $?"` | показать код выхода diff |
| `-o jsonpath='replicas=…'` | вывести три поля готового Deployment |
| `imageID` | образ, который реально запущен в контейнере |

Результат (сокращено):

```
diff exit: 1
…
replicas=3 grace=40 cpu=250m
localhost:5001/orders-api@sha256:ad4f8fd2…
```

Разбор:

1. `diff exit: 1` — в кластере ещё ничего нет, поэтому изменения есть.
2. `replicas=3` — все три реплики готовы.
3. `grace=40` и `cpu=250m` — оба патча дошли до живого Deployment.
4. `imageID` в последней команде содержит дайджест из шага 1.

**Итог.**

| Что узнали | Где видно |
|---|---|
| Образ по дайджесту задаёт поле `images` | шаг 2, `@sha256:` |
| Strategic merge правит контейнер по имени, не трогая остальное | шаг 2, `cpu: 250m` |
| JSON 6902 добавляет поля по пути | шаг 2, `SHUTDOWN_DELAY`, `40` |
| Код 1 у `diff` значит «есть изменения», а не ошибку | шаг 3, `diff exit: 1` |

**Уборка.**

```bash
kubectl delete ns lab-07-3-prod
unset DIGEST
```

Команды удаляют namespace и переменную оболочки.

**Вопросы для самопроверки.**

1. Что случится с патчем JSON 6902 `containers/0/env/-`, если в base поменять порядок контейнеров?

<details><summary>Ответ</summary>
Индекс `0` укажет на другой контейнер, и переменная окажется не там. Strategic merge в такой ситуации ищет контейнер по имени и продолжит работать.
</details>

2. Почему дайджест надёжнее тега?

<details><summary>Ответ</summary>
Тег можно перенести на другой образ, а дайджест — хэш содержимого, он указывает на один и тот же образ всегда (02-2).
</details>

3. Чем код 1 у `kubectl diff` отличается от кода 2?

<details><summary>Ответ</summary>
Код 1 значит, что разница найдена, а код больше 1 — что сам diff завершился ошибкой.
</details>

### Лабораторная работа 3. Helm-чарт внутри Kustomize

**Риски.** Работа меняет только кластер стенда и каталог `~/lab/k8s/07-3`; хост не затрагивается.

- **Что меняется:** создаётся namespace `lab-07-3-helm` с объектами чарта из 07-1; Helm-релиз не создаётся.
- **Надолго ли:** до уборки работы.
- **Безопасность:** флаг `--load-restrictor=LoadRestrictionsNone` разрешает сборке читать любые файлы вашего пользователя; здесь он нужен только для чарта из `~/lab/k8s/charts`, чужие каталоги не подключайте.
- **Влияние на систему:** два пода orders-api с запросом 100m CPU и 64 МиБ.
- **Откат:** `kubectl delete ns lab-07-3-helm`.

**Цель.** Подключить чарт orders-api из 07-1 через `helmCharts`, поправить результат патчем и увидеть три ловушки: флаг `--enable-helm`, ограничитель загрузки и namespace.

**Что понадобится.**

- Чарт `~/lab/k8s/charts/orders-api` из 07-1 и Helm 4.2.x в PATH (встроенный в kubectl 1.36 Kustomize 5.8.1 его поддерживает).
- Каталог `~/lab/k8s/07-3/orders-api` из работы 1.
- Около 20 минут.

**Схема опыта.** Нижний каталог рендерит чарт, верхний патчит результат; ловушки ждут на пути от каталога к кластеру.

```
overlays/helm        namespace + патч env ──┐
  └─ resources: ../helm-chart               ├─► kubectl kustomize --enable-helm ─► kubectl apply -n
       └─ helmCharts: orders-api, values ───┘
```

Схема 9. Два каталога: нижний подключает чарт, верхний правит его объекты; смотрите на флаги сборки.

#### Шаг 1. Подготовить namespace и два kustomization

Команды проверяют наличие чарта, создают namespace с Secret и пишут два kustomization. Нижний вызывает чарт, верхний подключает его и патчит Deployment `shop`.

```bash
ls ~/lab/k8s/charts/orders-api/Chart.yaml
cd ~/lab/k8s/07-3/orders-api
kubectl create ns lab-07-3-helm
kubectl -n lab-07-3-helm create secret generic postgres \
  --from-literal=DATABASE_URL=postgresql://orders:orders-lab-pass@postgres.orders:5432/orders
cat > overlays/helm-chart/kustomization.yaml <<'E'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
helmGlobals:
  chartHome: ../../../../charts
helmCharts:
- name: orders-api
  releaseName: shop
  valuesInline:
    route: {hostname: helm.lab073.localhost}
    image: {tag: "2.1"}
E
cat > overlays/helm/kustomization.yaml <<'E'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: lab-07-3-helm
resources: [../helm-chart]
patches:
- target: {kind: Deployment, name: shop}
  patch: |-
    - op: add
      path: /spec/template/spec/containers/0/env/-
      value: {name: SHUTDOWN_DELAY_OVERRIDE, value: "via-kustomize"}
E
```

| Часть команды | Значение |
|---|---|
| `ls …/Chart.yaml` | убедиться, что чарт из 07-1 на месте |
| `chartHome: ../../../../charts` | каталог чартов, путь от `overlays/helm-chart` |
| `releaseName: shop` | имя релиза для шаблонов; оно же имя Deployment |
| `valuesInline` | values прямо в файле: хост маршрута и тег образа |
| `resources: [../helm-chart]` | верхний каталог подключает нижний как источник |
| `target … name: shop` | патч применяется к Deployment, который создал чарт |

Разбор: команда `ls` печатает путь, если чарт есть. Остальные команды ничего не печатают, кроме `namespace/lab-07-3-helm created` и `secret/postgres created`.

#### Шаг 2. Применить через apply -k

Первая попытка идёт привычным путём и должна завершиться ошибкой.

```bash
cd ~/lab/k8s/07-3/orders-api
kubectl apply -k overlays/helm
```

| Часть команды | Значение |
|---|---|
| `apply -k overlays/helm` | собрать overlay и применить; `--enable-helm` здесь не передать |

Результат:

```
error: … must specify --enable-helm
```

Разбор: Kustomize не запускает Helm без явного разрешения, а `apply -k` флага `--enable-helm` не принимает. Поэтому сборку делают отдельной командой и передают результат в `apply -f -`.

#### Шаг 3. Собрать с --enable-helm и столкнуться с ограничителем

Команда собирает overlay с разрешённым Helm. Чарт лежит вне каталога kustomization, поэтому сборка упирается в ограничитель загрузки.

```bash
cd ~/lab/k8s/07-3/orders-api
kubectl kustomize --enable-helm overlays/helm
```

| Часть команды | Значение |
|---|---|
| `kustomize --enable-helm` | разрешить запуск `helm template` во время сборки |

Результат (сокращено, пути заменены на `…`):

```
error: … security; file '…/charts/orders-api/values.yaml' is not in or below '…/overlays/helm'
```

Разбор: по умолчанию Kustomize читает файлы только из каталога сборки и ниже (`LoadRestrictionsRootOnly`). Чарт лежит в `~/lab/k8s/charts`, то есть выше. Есть два выхода: положить чарт внутрь каталога kustomization или снять ограничитель флагом `--load-restrictor=LoadRestrictionsNone`. В работе используется второй, потому что чарт принадлежит 07-1.

#### Шаг 4. Собрать с обоими флагами и проверить результат

Команды собирают overlay с двумя флагами и проверяют два места: патч дошёл до Deployment, а namespace нет.

```bash
cd ~/lab/k8s/07-3/orders-api
kubectl kustomize --enable-helm --load-restrictor=LoadRestrictionsNone overlays/helm | \
  grep -A1 SHUTDOWN_DELAY_OVERRIDE
kubectl kustomize --enable-helm --load-restrictor=LoadRestrictionsNone overlays/helm | \
  grep -c 'namespace: lab-07-3-helm'
```

| Часть команды | Значение |
|---|---|
| `--load-restrictor=LoadRestrictionsNone` | разрешить читать файлы вне каталога сборки |
| `grep -A1 SHUTDOWN_DELAY_OVERRIDE` | найти добавленную переменную и строку после неё |
| `grep -c 'namespace: lab-07-3-helm'` | посчитать объекты, которым поставлен namespace |

Результат (отступы могут отличаться):

```
        - name: SHUTDOWN_DELAY_OVERRIDE
          value: via-kustomize
0
```

Разбор:

1. Переменная `SHUTDOWN_DELAY_OVERRIDE` есть в Deployment: патч Kustomize сработал на объекте, который создал Helm.
2. Счётчик `0` — поле `namespace` из kustomization не применилось к объектам из `helmCharts`. На Kustomize v5.8.1 ConfigMap, Deployment и Service остались без `metadata.namespace`.
3. Без явного `-n` при применении объекты ушли бы в namespace текущего контекста, поэтому следующий шаг задаёт `-n`.

#### Шаг 5. Применить и сравнить с Helm-релизом

Команды применяют сборку с явным namespace, проверяют ответ приложения и список релизов Helm.

```bash
cd ~/lab/k8s/07-3/orders-api
kubectl kustomize --enable-helm --load-restrictor=LoadRestrictionsNone overlays/helm | \
  kubectl apply -n lab-07-3-helm -f -
kubectl -n lab-07-3-helm rollout status deploy/shop
curl -s -H 'Host: helm.lab073.localhost' http://127.0.0.1:8088/version; echo
helm list -n lab-07-3-helm
```

| Часть команды | Значение |
|---|---|
| `apply -n lab-07-3-helm -f -` | применить собранный YAML из stdin в нужный namespace |
| `rollout status deploy/shop` | ждать готовности Deployment `shop` |
| `/version` | путь приложения с версией образа |
| `helm list -n …` | показать релизы Helm в namespace |

Результат (сокращено):

```
deployment "shop" successfully rolled out
…
NAME  NAMESPACE  REVISION  UPDATED  STATUS  CHART  APP VERSION
```

Разбор:

1. Ответ `/version` содержит `2.1`: тег пришёл из `valuesInline`.
2. Список `helm list` пуст, только заголовок: Helm-релиза нет, потому что объекты применил `kubectl`, а Helm лишь отрендерил шаблоны. На объектах при этом есть метка `app.kubernetes.io/managed-by: Helm`.
3. Hooks чарта в таком режиме не выполняются как hooks. Argo CD работает с Helm так же, и `helm list` там тоже пуст (08-1).
4. Argo CD с версии 3.5.4 не учитывает `helmGlobals.configHome` в таких сборках: проверьте это, когда будете переносить каталог в GitOps.

**Итог.**

| Что узнали | Где видно |
|---|---|
| `apply -k` не принимает `--enable-helm`, нужен конвейер | шаг 2 |
| Чарт вне каталога требует снять ограничитель загрузки | шаг 3 |
| `namespace` kustomization не применился к объектам Helm | шаг 4, счётчик `0` |
| Объекты из `helmCharts` не образуют Helm-релиз | шаг 5, пустой `helm list` |

**Уборка.**

```bash
kubectl delete ns lab-07-3-helm
```

Команда удаляет namespace и его объекты. Каталог `~/lab/k8s/07-3/orders-api` остаётся: 08-1 берёт его как источник для Argo CD. Если он вам больше не нужен, удалите его командой `rm -r ~/lab/k8s/07-3`.

**Вопросы для самопроверки.**

1. Почему `kubectl apply -k` не подходит для kustomization с `helmCharts`?

<details><summary>Ответ</summary>
Для сборки с Helm нужен флаг `--enable-helm`, а `apply -k` его не принимает; сборку делают `kubectl kustomize --enable-helm` и передают в `apply -f -`.
</details>

2. Чем объекты из `helmCharts` отличаются от релиза, созданного `helm install`?

<details><summary>Ответ</summary>
Релиза нет: Helm только рендерит шаблоны, Secret релиза и истории нет, `helm list` пуст, а hooks не выполняются как hooks.
</details>

3. Что проверить в сборке, прежде чем применять её в кластер?

<details><summary>Ответ</summary>
Наличие `metadata.namespace` у каждого объекта, итоговые имена, образы и результат патчей. Для объектов из Helm namespace задают флагом `-n`.
</details>

---

## → Дальше

Kustomize превращает каталог с обычным YAML в понятный результат сборки, а состояние окружения живёт в Git, как и сами патчи. Модуль 08 использует это: Argo CD (08-1) читает такой каталог из Git, собирает его своим Kustomize и применяет в кластер. Поэтому следующая часть идёт сразу после этой. Чтобы понимать, почему Argo CD показывает `OutOfSync` и что он удаляет, нужно уже знать, что делают `images`, генераторы и prune.
