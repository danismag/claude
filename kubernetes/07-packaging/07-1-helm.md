# 07-1. Helm: чарты и релизы

> Модуль 07 «Пакетирование» · часть 1 из 3 · ~2 ч чтения + ~1,5 ч лабораторных · Нужно: стенд 00-1 (контекст `kind-lab`), Helm 4.2.2 (00-1), образы `localhost:5001/orders-api` версий 2.0 и 2.1, доступ узлов к образу `postgres:17.6-alpine` · Опирается на: 01-3 (владение полями), 02-2 (Deployment и выкатка), 03-4 (HTTPRoute)

## Где мы на карте

Эта часть открывает модуль 07 и разбирает Helm: как упаковать манифесты в чарт, поставить его релизом и безопасно обновлять. Часть опирается на выкатку Deployment (02-2), на владение полями при server-side apply (01-3 §3) и на маршруты Gateway API (03-4). Установка helm на стенде описана в 00-1, а здесь инструмент работает впервые, поэтому карточка helm стоит в разделе 3.

Следующие части используют то, что собрано здесь. В 07-2 вы поставите чужой чарт, в 07-3 сравните Helm с Kustomize, а в модуле 08 системы GitOps будут рендерить такие же чарты сами.

```
манифесты + параметры ──► чарт (пакет)  ──► helm ──► релиз в кластере
                           07-1, раздел 2     │       раздел 2 и 4
                                              ├── чужие чарты и обновления: 07-2
                                              ├── Kustomize как другой способ: 07-3
                                              └── Argo CD и Flux запускают Helm: модуль 08
```

Схема 1. Место Helm в курсе: чарт и релиз разбираются здесь, остальные части используют их.

---

## 1. Какую задачу решает Helm

Helm отвечает на вопрос, как поставить один и тот же набор манифестов в разные окружения и потом им управлять. Разберём, чего не хватает голым манифестам и какие понятия вводит Helm.

### Манифесты без параметров

Приложению нужны Deployment, Service, ConfigMap и маршрут, а на стенде, в тестовом окружении и в проде они отличаются парой полей: тегом образа, числом реплик, именем хоста. Копировать каталог манифестов под каждое окружение быстро надоедает, потому что правки приходится повторять руками. К тому же `kubectl apply` не помнит, что и когда ставил: откатиться на «позавчерашний» набор объектов нечем.

Helm закрывает три задачи сразу. Он подставляет параметры в шаблоны манифестов, хранит историю установок с возможностью отката и раздаёт готовые пакеты через репозитории.

### Чарт, значения и релиз

**Чарт** (chart) — пакет Helm: каталог с шаблонами манифестов и значениями по умолчанию. **Значения** (values) — параметры, которые подставляются в шаблоны. **Релиз** (release) — установленный в кластер экземпляр чарта с именем и namespace; один чарт можно поставить много раз под разными именами. Каждое изменение релиза создаёт новую **ревизию** (revision) с номером 1, 2, 3 и так далее.

Чарты берут из **репозитория** (repository) — HTTP-сервера с файлом `index.yaml` — или из **OCI-реестра** (OCI registry), то есть из того же хранилища образов, куда кладут контейнеры. Адрес в этом случае начинается с `oci://`, так устроены чарты Envoy Gateway и cert-manager в курсе.

```
 чарт (файлы) ─┐
 values        ├──► helm: рендер шаблонов ──► манифесты ──► API-сервер ──► объекты
 --set         ┘                                  │
                                                  └──► Secret с записью ревизии (раздел 2)
```

Схема 2. Что делает Helm при установке: рендерит манифесты на вашей машине, отправляет их в API-сервер и записывает ревизию в Secret.

### Helm 4 и Helm 3

Helm 4 вышел 12 ноября 2025 года. Чарты формата v2 (`apiVersion: v2` в `Chart.yaml`) работают в нём без изменений, но поведение команд изменилось, поэтому рецепты для Helm 3 могут вести себя иначе. На стенде стоит Helm 4.2.2 (00-1); существует и линия 4.3, но лабораторные на ней не проверялись.

- **Применение объектов.** Новые релизы ставятся через server-side apply (01-3 §3), а не через client-side three-way merge, как в Helm 3.
- **Ожидание готовности.** `--wait` использует библиотеку **kstatus** — она вычисляет готовность ресурса по его статусу — и требует у пользователя права `watch`, а не только `list`.
- **Откат при ошибке.** Флаг `--atomic` переименован в `--rollback-on-failure`, а `--force` — в `--force-replace`.
- **Плагины.** Система плагинов новая, с необязательным WebAssembly; post-renderer (программа, правящая манифесты после рендера) подключается только плагином, а не путём к файлу.

Helm 3 получал исправления ошибок до 9 сентября 2026 года и получает патчи безопасности до 10 февраля 2027 года. Новые проекты начинают на Helm 4, а старые релизы Helm 3 при обновлении сохраняют прежний метод применения.

---

## 2. Как устроены чарт и релиз

Чарт — это каталог файлов, а релиз — запись в кластере, поэтому разберём сначала файлы, потом то, как Helm превращает их в манифесты и где хранит результат.

### Каталог чарта

Чарт состоит из фиксированного набора файлов, каждый отвечает за свою часть.

```
orders-api/
├── Chart.yaml          имя, версия чарта, версия приложения
├── values.yaml         значения по умолчанию
├── values.schema.json  (необязательно) схема проверки значений
├── templates/          шаблоны манифестов
│   ├── _helpers.tpl    общие фрагменты: метки, имя образа
│   ├── deployment.yaml
│   └── NOTES.txt       текст, который печатается после установки
├── charts/             зависимости (чарты-подчарты)
└── crds/               CRD, ставятся только при первой установке
```

Схема 3. Каталог чарта: по умолчанию читаются `values.yaml` и `templates/`, остальное нужно не всегда.

В `Chart.yaml` две версии. `version` — версия самого чарта, она растёт при любом изменении шаблонов. `appVersion` — версия приложения, в нашем чарте она служит тегом образа по умолчанию. Файлы, имя которых начинается с подчёркивания (`_helpers.tpl`), Helm не превращает в манифест, а использует как библиотеку фрагментов.

### Шаблоны и значения

Шаблон — это манифест с вставками на языке **Go template**, которые стоят в двойных фигурных скобках. Helm подставляет в них объекты: `.Values` — значения, `.Release` — имя, namespace и номер ревизии релиза, `.Chart` — содержимое `Chart.yaml`. Функции после вертикальной черты работают как конвейер, например `default "x"` подставляет запасное значение, а `toYaml` превращает структуру в YAML.

Значения собираются из нескольких источников, и побеждает последний.

```
values.yaml чарта  <  -f файл1  <  -f файл2  <  --set ключ=значение
   самый слабый                                     самый сильный
```

Схема 4. Приоритет значений: каждый следующий источник перекрывает предыдущие, а при нескольких `-f` важнее тот, что правее.

### Приёмы зрелого чарта

В хороших чартах повторяются четыре приёма. Каждый решает конкретную неприятность, которую иначе находят в проде.

- **Условный `replicas`.** Когда работает HPA (05-4), поле `replicas` в Deployment не пишут, иначе каждый upgrade сбрасывает масштаб на значение из чарта.
- **Хэш конфигурации.** Аннотация `checksum/config` с хэшем отрендеренного ConfigMap меняет шаблон пода при изменении конфига, и Deployment перезапускает поды (04-1).
- **Обязательные значения.** Функция `required` останавливает рендер с понятным сообщением, а не создаёт объект с пустым полем.
- **Тег или дайджест.** Образ берётся по дайджесту, если он задан, и по тегу `appVersion` в остальных случаях (02-2).

### Где живёт релиз

Helm не ведёт отдельной базы: каждая ревизия релиза хранится в **Secret** в namespace релиза. Имя Secret строится по шаблону `sh.helm.release.v1.<релиз>.v<ревизия>`, а тип — `helm.sh/release.v1`.

```
namespace lab-07-1
 ├─ Secret sh.helm.release.v1.shop.v1   status=superseded   ← старая ревизия
 ├─ Secret sh.helm.release.v1.shop.v2   status=deployed     ← текущая
 └─ объекты релиза: Deployment shop, Service shop, ConfigMap shop-config …
```

Схема 5. Записи ревизий лежат рядом с объектами релиза; статус и номер ревизии видны в метках Secret.

Внутри Secret лежит сжатый JSON: значения, отрендеренный манифест, статус и hooks. Из этого следует три вещи. Команды `helm list`, `history` и `get` читают эти Secret, поэтому право читать Secret в namespace равно праву видеть все значения релиза, включая пароли, переданные через `--set`. Если Secret удалить, Helm «забудет» релиз, а объекты в кластере останутся. И число хранимых ревизий ограничивает `--history-max`, по умолчанию 10.

### Hooks

**Hook** (хук) — объект чарта с аннотацией `helm.sh/hook`, который Helm создаёт в нужный момент жизни релиза и не включает в сам релиз. Типичный пример — Job с миграциями базы перед обновлением.

```
helm upgrade
   │
   ├─ pre-upgrade hooks (по возрастанию helm.sh/hook-weight)  ← Job миграции
   │      └─ Helm ждёт, пока они завершатся; ошибка останавливает upgrade
   ├─ обновление объектов релиза
   └─ post-upgrade hooks
```

Схема 6. Порядок upgrade с hooks: хуки `pre-*` выполняются до обновления объектов, а хуки `post-*` после него.

Доступны моменты pre-install, post-install, pre-upgrade, post-upgrade, pre-delete, post-delete, pre-rollback, post-rollback и `test` для `helm test`. Аннотация `helm.sh/hook-delete-policy` задаёт, когда удалять объект хука: `before-hook-creation` (значение по умолчанию) удаляет прошлый экземпляр перед новым, `hook-succeeded` — после успеха, `hook-failed` — после ошибки. Хуки не откатываются командой `helm rollback`, поэтому миграцию базы нужно делать совместимой с предыдущей версией приложения. В GitOps хуки Helm превращаются в sync hooks Argo CD (08-1).

---

## 3. Как управлять релизом

Релизом управляют командой `helm`; сначала карточка инструмента, затем установка, обновление, ожидание, откат, конфликты полей и публикация чарта.

### Карточка инструмента: helm

**Назначение.** **helm** — менеджер пакетов для Kubernetes (package manager). Он собирает манифесты из чарта и значений, ставит их в кластер как релиз, обновляет, откатывает и удаляет. Helm не следит за кластером после установки и не исправляет ручные правки сам.

**Как работает.** helm — клиентская программа без собственного сервера: рендер идёт на вашей машине, а в кластер уходят готовые манифесты. Состояние релиза helm пишет в Secret через тот же API-сервер.

```
 helm (ваша машина)
  │  1. читает чарт и значения
  │  2. рендерит шаблоны в манифесты
  │  3. применяет их через API-сервер (server-side apply)
  │  4. ждёт готовности, если задан --wait
  ▼
 kube-apiserver ──► объекты релиза + Secret sh.helm.release.v1.…
```

Схема 7. Путь команды install: сервера Helm нет, все данные идут через API-сервер, к которому подключает kubeconfig.

**Откуда берёт данные.** Чарт — из каталога, архива `.tgz`, репозитория или `oci://`. Кластер и namespace — из kubeconfig (текущий контекст, `~/.kube/config`), если их не задали флаги `--kube-context` и `-n`. Историю релизов — из Secret в namespace релиза (драйвер `secret`, значение `HELM_DRIVER` по умолчанию). Кэш чартов лежит в `~/.cache/helm`, настройки репозиториев — в `~/.config/helm`.

**Основные команды.** Блок ниже идёт от создания чарта до удаления релиза, у каждой строки свой комментарий.

```bash
helm create demo                               # заготовка чарта в каталоге demo/
helm lint ./demo                               # проверить чарт на ошибки
helm template r ./demo -n ns                   # отрендерить манифесты, кластер не нужен
helm install r ./demo -n ns --wait             # поставить релиз r и дождаться готовности
helm upgrade --install r ./demo -n ns \
  -f prod.yaml --set image.tag=2.1             # установить или обновить одной командой
helm list -n ns                                # релизы в namespace
helm status r -n ns                            # статус и NOTES релиза
helm history r -n ns                           # все ревизии с описанием
helm get values r -n ns                        # значения, которые передал пользователь
helm get manifest r -n ns                      # манифест, отправленный в кластер
helm rollback r 1 -n ns                        # вернуться к ревизии 1 (новая ревизия)
helm uninstall r -n ns                         # удалить релиз и его объекты
```

В блоке первые три команды работают без изменений в кластере, `install` и `upgrade` меняют его, а `get` и `history` только читают Secret релиза. Опыты с каждой командой — в лабораторных работах 1–4.

**Команды для скриптов:**

- `upgrade --install` ставит релиз, если его нет, и обновляет, если есть: так пишут шаг деплоя в CI.
- `--wait --timeout 5m` делает команду синхронной; без `--timeout` лимит на каждую операцию равен 5m0s.
- `--rollback-on-failure` откатывает релиз при ошибке и включает ожидание.
- `-o json` выводит результат в JSON, например `helm status r -o json | jq -r .info.status`.
- `--dry-run=server` рендерит и проверяет манифесты на сервере, ничего не сохраняя.
- `helm lint --strict` превращает предупреждения в ошибки; код возврата ненулевой при любой ошибке.

**Частые ошибки:**

- `Kubernetes cluster unreachable`: неверный контекст или kubeconfig; проверьте `kubectl config current-context`.
- `another operation (install/upgrade/rollback) is in progress`: релиз завис в статусе `pending-*` (раздел 5).
- `cannot re-use a name that is still in use`: релиз с таким именем уже есть в этом namespace.
- `rendered manifests contain a resource that already exists`: объект есть в кластере, но его не создавал этот релиз.
- `UPGRADE FAILED: … conflict occurred while applying object`: другой менеджер владеет полем (раздел 3, SSA).
- `--reuse-values` не подхватывает новые значения по умолчанию из обновлённого чарта.

**Установка.** На стенде helm уже установлен шагом 3 работы 1 из 00-1. В Ubuntu бинарник кладут в `/usr/local/bin` из архива с релиза, в Manjaro ставят командой `sudo pacman -S helm`. Версию показывает `helm version --short`; курс написан для Helm 4.2.x.

### Установка и обновление

Релиз ставит `helm install`, а обновляет `helm upgrade`: оба рендерят чарт, применяют манифесты и создают новую ревизию. Для upgrade важно, что происходит с прошлыми значениями. По умолчанию команда сбрасывает их к значениям чарта и берёт только то, что передано сейчас. Флаг `--reuse-values` берёт значения прошлой ревизии целиком и поверх них применяет новые `--set`, но не подхватывает ключи, которые чарт добавил позже. Компромисс — `--reset-then-reuse-values`: сначала значения чарта, затем прошлые пользовательские, затем новые.

В CI надёжнее всего каждый раз передавать полный набор файлов `-f`. Тогда состояние релиза определяет Git, а не память предыдущего запуска.

### Ожидание и откат

Без флагов Helm 4 считает установку успешной, когда API принял объекты: ждёт он только hooks (стратегия `hookOnly`). Флаг `--wait` включает стратегию `watcher` на основе kstatus: Helm следит за ресурсами, пока они не станут готовыми или не истечёт `--timeout`. Рядом работает `--wait-for-jobs`, который ждёт завершения Job.

```
upgrade без --wait      ──► объекты приняты ──► статус deployed (под может не стартовать)
upgrade --wait          ──► ждёт готовности ──► готово: deployed / тайм-аут: failed
upgrade --rollback-on-failure ► при failed Helm откатывает на прошлую удачную ревизию
```

Схема 8. Три режима: без ожидания «успех» ничего не проверяет, `--wait` фиксирует ошибку, а `--rollback-on-failure` ещё и возвращает прошлую версию.

Таймаут должен превышать `progressDeadlineSeconds` Deployment (по умолчанию 600 с, 02-2) только тогда, когда выкатка медленная по замыслу. Во всех остальных случаях хватает 2–5 минут.

Откат делает `helm rollback <релиз> [ревизия]`. Он не возвращает старый номер, а создаёт новую ревизию с манифестом выбранной, поэтому история только растёт.

### Server-side apply и конфликты

Helm 4 применяет объекты новых релизов методом server-side apply с именем менеджера `helm`. Метод задаёт флаг `--server-side`: значение `auto` (по умолчанию) берёт метод прошлого релиза, а для новых релизов выбирает server-side. Управление полями устроено так же, как в 01-3 §3: каждое поле принадлежит менеджеру, и чужое поле Helm перезаписать не может.

```
helm upgrade ──► SSA: поле spec.template принадлежит менеджеру kubectl?
                      │ да  ─► конфликт, upgrade отклонён
                      │ нет ─► поле обновлено, владелец helm
 --force-conflicts ──► забрать поле себе, несмотря на чужого владельца
```

Схема 9. Конфликт SSA: ручная правка делает kubectl владельцем поля, и следующий upgrade останавливается. Смотрите на владельца в `managedFields`.

Правило простое: объекты релиза меняют только через Helm. Экстренный откат делают командой `helm rollback`, а не `kubectl rollout undo`.

### Публикация и проверка чарта

Чарт можно проверить до рендера и опубликовать как артефакт. Файл `values.schema.json` задаёт JSON Schema для значений: Helm проверяет её при `install`, `upgrade`, `template` и `lint`, поэтому `--set replicaCount=abc` отклоняется до создания объектов. Команда `helm package` собирает архив `orders-api-0.1.0.tgz`, а `helm push orders-api-0.1.0.tgz oci://host/charts` кладёт его в OCI-реестр. Для реестра без TLS, как реестр стенда на `localhost:5001`, понадобится флаг `--plain-http`. Установка из реестра выглядит как `helm install r oci://host/charts/orders-api --version 0.1.0`. Объект с аннотацией `helm.sh/hook: test` запускается командой `helm test` и проверяет релиз после установки; эти механизмы в лабораторных не проверяются.

---

## 4. Как увидеть состояние релиза

Состояние релиза видно с трёх сторон: статус и история, содержимое ревизии и реальные объекты в кластере. Расхождение между ними и есть главный признак проблемы.

### Статус и история

Команда `helm list` показывает релизы, а `helm history` — их ревизии со статусом и описанием. Статус ревизии принимает одно из значений.

```
install ─► pending-install ─► deployed ─► upgrade ─► pending-upgrade ─► deployed
                  │                │   (старая ревизия superseded)           │
                  └─► failed       └─► rollback ─► pending-rollback ─► deployed
 uninstall ─► uninstalling ─► uninstalled (при --keep-history) или запись удалена
```

Схема 10. Статусы ревизии: состояния `pending-*` существуют только пока команда работает, а если команду убили, они остаются навсегда.

- **deployed** — текущая успешная ревизия.
- **superseded** — устаревшая ревизия, заменённая новой.
- **failed** — операция завершилась ошибкой или истёк тайм-аут.
- **pending-install**, **pending-upgrade**, **pending-rollback** — операция идёт или была прервана.
- **uninstalled** — релиз удалён с флагом `--keep-history`.

### Содержимое ревизии

Что именно ушло в кластер, показывают команды `helm get`. Команда `get values` печатает только значения, которые передал пользователь (блок `USER-SUPPLIED VALUES`), а с флагом `--all` — ещё и значения чарта. Команда `get manifest` показывает отрендеренные объекты релиза, `get hooks` — хуки, `get notes` — текст `NOTES.txt`. Hook в манифест не входит: он хранится отдельно.

Рендер можно посмотреть без установки: `helm template` печатает манифесты локально, а `helm lint` проверяет чарт. Сравнить рендер с кластером помогает `kubectl diff` (07-2).

### Объекты в кластере

Объекты релиза помечены метками `app.kubernetes.io/managed-by: Helm` и аннотациями `meta.helm.sh/release-name` и `meta.helm.sh/release-namespace`. По ним Helm узнаёт «свои» объекты, а вы находите их командой `kubectl get all -l app.kubernetes.io/instance=<релиз>`. Владельцев полей показывает `kubectl get <объект> --show-managed-fields`: менеджер `helm` с операцией `Apply` — норма, менеджер `kubectl` с операцией `Update` на поле шаблона пода — след ручной правки.

---

## 5. Что ломается и как найти причину

Три поломки встречаются чаще остальных: «успех» без готовности, конфликт после ручной правки и зависшая операция. У каждой свой признак и свой способ лечения.

### Успех без готовности

Upgrade на несуществующий тег образа без `--wait` печатает `STATUS: deployed`, а под в кластере сидит в `ErrImagePull`. Причина проста: Helm 4 по умолчанию ждёт только hooks, как `kubectl apply` без `rollout status` (02-2). Лечение — `--wait` с `--timeout`. Но и `--wait` сам по себе оставляет релиз в статусе `failed` с частично обновлённым кластером: старые поды работают, сломанный висит. Чтобы вернуться автоматически, добавляют `--rollback-on-failure`. Если `--wait` падает сразу с ошибкой прав, ищите нехватку глагола `watch` у учётной записи CI (06-1).

### Конфликт после ручной правки

Когда кто-то правит объект релиза руками, `helm upgrade` падает с сообщением `conflicts with "kubectl"`. Ручная команда делает менеджера `kubectl` владельцем полей, а server-side apply не затирает чужое. Флаг `--force-conflicts` проходит конфликт, но след менеджера в `managedFields` остаётся, и без флага конфликт возвращается. Чистое решение — не править руками; полностью след убирает переустановка релиза.

### Зависшая операция

Сообщение `another operation (install/upgrade/rollback) is in progress` значит, что последняя ревизия осталась в статусе `pending-*`. Так бывает, когда процесс helm убили: отменили job в CI, закончился тайм-аут раннера, упал узел. Статус `pending-upgrade` Helm сам не снимет.

Выход зависит от операции. Для `pending-upgrade` и `pending-rollback` делают `helm rollback <релиз>` на последнюю удачную ревизию. Для `pending-install` откатываться некуда, поэтому удаляют Secret зависшей ревизии командой `kubectl delete secret sh.helm.release.v1.<релиз>.v<N>`, проверяют объекты вручную и повторяют установку. Профилактика состоит из двух правил: тайм-аут job в CI больше `--timeout` самого helm и один деплой релиза за раз (`resource_group` в GitLab, курс `cicd`).

### Ошибки рендера и hooks

Ошибка `execution error at (…): database.secretName обязателен` приходит из функции `required` до обращения к кластеру. Ошибка `rendered manifests contain a resource that already exists` значит, что объект создан не этим релизом: у него нет меток и аннотаций Helm, и его нужно либо удалить, либо передать Helm. Если упал hook, upgrade не начинается и релиз получает статус `failed`. Если hook-Job остался с прошлого раза и в аннотации нет `before-hook-creation`, повторный upgrade упадёт на «already exists». Job без `activeDeadlineSeconds` может держать upgrade до истечения `--timeout`.

---

## 6. Пределы и значения по умолчанию

Ограничения Helm задают его клиентская природа и способ хранения: все числа ниже нужно знать, чтобы не удивляться в CI.

### Значения по умолчанию

- **Тайм-аут.** `--timeout` равен 5m0s на каждую операцию, например на каждый hook.
- **История.** `--history-max` равен 10 ревизиям; более старые Secret удаляются.
- **Ожидание.** Без `--wait` Helm 4 ждёт только hooks (стратегия `hookOnly`).
- **Метод применения.** `--server-side=auto`: у нового релиза это server-side apply.
- **Политика удаления hook.** `before-hook-creation`.
- **Драйвер хранилища.** `secret` (переменная `HELM_DRIVER`).

### Ограничения

- **Имя релиза.** До 53 символов, только строчные буквы, цифры и дефис.
- **Размер ревизии.** Запись лежит в Secret, а Secret не больше около 1 МиБ, поэтому огромные чарты с большими значениями не устанавливаются.
- **CRD.** Каталог `crds/` ставится только при первой установке; upgrade его не обновляет и uninstall не удаляет.
- **Дрейф.** Helm не сверяет кластер с чартом сам: ручную правку он заметит только при следующем upgrade или diff.
- **Namespace.** Релиз привязан к namespace, где лежат его Secret; одно имя можно использовать в разных namespace.

---

## Лабораторные работы

Все четыре работы идут на стенде 00-1 в namespace `lab-07-1`. Чарт `orders-api` собирается в каталоге `~/lab/k8s/charts/orders-api`: этот путь нужен частям 07-2 и 07-3, поэтому правило каталога `~/lab/k8s/07-1/` здесь не применяется, а чарт остаётся после уборки. Ключи `-n lab-07-1` стоят в командах Helm явно, а для kubectl задана функция `k`.

Подготовку выполняют один раз. Первая команда только проверяет контекст: она должна вывести `kind-lab`; если нет, переключитесь на контекст стенда самостоятельно перед продолжением.

```bash
kubectl config current-context
kubectl create ns lab-07-1
kubectl -n lab-07-1 create secret generic postgres \
  --from-literal=DATABASE_URL=postgresql://orders:orders-lab-pass@postgres.orders:5432/orders
mkdir -p ~/lab/k8s/charts/orders-api/templates
k() { kubectl -n lab-07-1 "$@"; }
```

Первая команда показывает текущий контекст, вторая создаёт namespace работы. Третья кладёт в него Secret с адресом базы стенда (учебный пароль из 00-1). Четвёртая создаёт каталог чарта, а функция `k` сокращает запись `kubectl -n lab-07-1`. Функцию снимает уборка работы 4; если вы закрыли терминал, объявите её снова.

### Лабораторная работа 1. Свой чарт

**Риски.** Работа меняет только кластер стенда: создаёт namespace, Secret и релиз, а на хосте пишет файлы чарта в `~/lab/k8s/charts`.

- **Что меняется:** в `lab-07-1` появляются релиз `shop`, его Deployment, Service, ConfigMap и HTTPRoute, а в каталоге хоста — файлы чарта.
- **Надолго ли:** релиз живёт до уборки работы 4, чарт остаётся.
- **Безопасность:** привилегий не нужно; пароль базы — учебный пароль стенда, он виден в `helm get values` только если передан через `--set`, а здесь не передаётся.
- **Влияние на систему:** нагрузка — два пода orders-api с запросом 100m CPU и 64 МиБ; namespace `orders` не меняется.
- **Откат:** `helm uninstall` и удаление namespace в уборке работы 4.

**Цель.** Написать чарт из helpers, условного `replicas`, хэша конфигурации и `required`, проверить его линтером и установить релиз. Затем найти запись релиза в Secret и владельца полей.

**Что понадобится.**

- Стенд 00-1 и подготовка выше.
- Helm 4.2.x и `jq`.
- Образ `localhost:5001/orders-api:2.0`.
- Около 40 минут, из них 15 на набор файлов.

**Схема опыта.** Файлы чарта превращаются в объекты релиза, а запись о релизе падает в Secret; смотреть нужно на оба результата.

```
~/lab/k8s/charts/orders-api ──► helm install shop ──► Deployment, Service, ConfigMap, HTTPRoute
                                        │
                                        └──► Secret sh.helm.release.v1.shop.v1   ← сюда смотрим
```

Схема показывает, что установка даёт два вида следов: объекты приложения и запись ревизии.

#### Шаг 1. Написать Chart.yaml и values.yaml

Создаём паспорт чарта и значения по умолчанию. Тег образа оставляем пустым, чтобы он брался из `appVersion`.

```bash
cd ~/lab/k8s/charts/orders-api
cat > Chart.yaml <<'E'
apiVersion: v2
name: orders-api
description: orders-api, демо-нагрузка курса kubernetes
type: application
version: 0.1.0
appVersion: "2.0"
E
cat > values.yaml <<'E'
replicaCount: 2
image:
  repository: localhost:5001/orders-api
  tag: ""          # пусто: берётся appVersion из Chart.yaml
  digest: ""       # если задан, образ берётся по дайджесту
autoscaling:
  enabled: false
  minReplicas: 2
  maxReplicas: 6
  targetCPU: 70
database:
  secretName: postgres     # Secret с ключом DATABASE_URL
config:
  discount_percent: 0
  banner: welcome
resources:
  requests: {cpu: 100m, memory: 64Mi}
  limits: {memory: 256Mi}
route:
  enabled: true
  hostname: orders.localhost
  gateway: {name: lab, namespace: envoy-gateway-system}
migration:
  enabled: false
E
```

| Часть команды | Значение |
|---|---|
| `cat > Chart.yaml <<'E'` | записать текст до строки `E` в файл |
| `appVersion: "2.0"` | версия приложения, она же тег по умолчанию |
| `tag: ""` | пустой тег: сработает `default` в шаблоне |
| `autoscaling.enabled: false` | HPA выключен, значит `replicas` пишется |
| `route.gateway` | Gateway `lab` из стенда 00-1 |

Вывода у команды нет. Проверьте, что файлы созданы: `ls` в каталоге чарта покажет `Chart.yaml` и `values.yaml`.

#### Шаг 2. Написать helpers, ConfigMap и Deployment

Файл `_helpers.tpl` задаёт общие метки, селектор и имя образа. ConfigMap берёт конфигурацию из значений, а Deployment собирает их вместе.

```bash
cat > templates/_helpers.tpl <<'E'
{{- define "orders-api.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Values.image.tag | default .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end }}
{{- define "orders-api.selector" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
{{- define "orders-api.image" -}}
{{- if .Values.image.digest -}}
{{ .Values.image.repository }}@{{ .Values.image.digest }}
{{- else -}}
{{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}
{{- end -}}
{{- end }}
E
cat > templates/configmap.yaml <<'E'
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ .Release.Name }}-config
  labels: {{- include "orders-api.labels" . | nindent 4 }}
data:
  config.json: {{ .Values.config | toJson | quote }}
E
cat > templates/deployment.yaml <<'E'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .Release.Name }}
  labels: {{- include "orders-api.labels" . | nindent 4 }}
spec:
  {{- if not .Values.autoscaling.enabled }}
  replicas: {{ .Values.replicaCount }}
  {{- end }}
  selector:
    matchLabels: {{- include "orders-api.selector" . | nindent 6 }}
  template:
    metadata:
      labels: {{- include "orders-api.selector" . | nindent 8 }}
      annotations:
        checksum/config: {{ include (print $.Template.BasePath "/configmap.yaml") . | sha256sum }}
    spec:
      containers:
      - name: api
        image: {{ include "orders-api.image" . }}
        ports:
        - {name: http, containerPort: 8000}
        env:
        - name: DATABASE_URL
          valueFrom:
            secretKeyRef:
              name: {{ required "database.secretName обязателен" .Values.database.secretName }}
              key: DATABASE_URL
        - {name: SHUTDOWN_DELAY, value: "5"}
        readinessProbe:
          httpGet: {path: /ready, port: http}
          periodSeconds: 2
        livenessProbe:
          httpGet: {path: /health, port: http}
          periodSeconds: 10
        resources: {{- toYaml .Values.resources | nindent 10 }}
        volumeMounts:
        - {name: config, mountPath: /etc/orders}
      volumes:
      - name: config
        configMap: {name: {{ .Release.Name }}-config}
E
```

| Часть шаблона | Значение |
|---|---|
| `define "orders-api.labels"` | именованный фрагмент, его вызывает `include` |
| `include … \| nindent 4` | вставить фрагмент со сдвигом в 4 пробела |
| `.Values.config \| toJson \| quote` | значения конфига как строка JSON |
| `if not .Values.autoscaling.enabled` | писать `replicas` только без HPA |
| `checksum/config: … sha256sum` | хэш ConfigMap меняет шаблон пода |
| `required "…" .Values.database.secretName` | остановить рендер, если значение пустое |

Вывода у команды нет. Файл `deployment.yaml` отдаёт поду Secret по имени из значений, читает конфиг из тома `/etc/orders` и содержит все четыре приёма из раздела 2.

#### Шаг 3. Дописать Service, HPA, HTTPRoute и NOTES

Эти шаблоны проще Deployment: Service открывает порт 80, HPA включается значением, HTTPRoute подключает хост к Gateway `lab`.

```bash
cat > templates/service.yaml <<'E'
apiVersion: v1
kind: Service
metadata:
  name: {{ .Release.Name }}
  labels: {{- include "orders-api.labels" . | nindent 4 }}
spec:
  selector: {{- include "orders-api.selector" . | nindent 4 }}
  ports:
  - {name: http, port: 80, targetPort: http}
E
cat > templates/hpa.yaml <<'E'
{{- if .Values.autoscaling.enabled }}
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: {{ .Release.Name }}
  labels: {{- include "orders-api.labels" . | nindent 4 }}
spec:
  scaleTargetRef: {apiVersion: apps/v1, kind: Deployment, name: {{ .Release.Name }}}
  minReplicas: {{ .Values.autoscaling.minReplicas }}
  maxReplicas: {{ .Values.autoscaling.maxReplicas }}
  metrics:
  - type: Resource
    resource:
      name: cpu
      target: {type: Utilization, averageUtilization: {{ .Values.autoscaling.targetCPU }}}
{{- end }}
E
cat > templates/httproute.yaml <<'E'
{{- if .Values.route.enabled }}
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: {{ .Release.Name }}
  labels: {{- include "orders-api.labels" . | nindent 4 }}
spec:
  parentRefs:
  - {name: {{ .Values.route.gateway.name }}, namespace: {{ .Values.route.gateway.namespace }}}
  hostnames: [{{ .Values.route.hostname | quote }}]
  rules:
  - backendRefs:
    - {name: {{ .Release.Name }}, port: 80}
{{- end }}
E
cat > templates/NOTES.txt <<'E'
orders-api {{ include "orders-api.image" . }}, релиз {{ .Release.Name }}, ревизия {{ .Release.Revision }}.
{{- if .Values.route.enabled }}
Проверка: curl http://{{ .Values.route.hostname }}:8088/api/orders
{{- end }}
E
```

| Часть шаблона | Значение |
|---|---|
| `{{- if .Values.autoscaling.enabled }}` | HPA создаётся только по значению |
| `parentRefs` | привязка маршрута к Gateway (03-4) |
| `hostnames: [ … \| quote ]` | имя хоста из значений в кавычках |
| `NOTES.txt` | текст, который Helm печатает после установки |

Вывода у команды нет. Файлов в `templates/` теперь шесть плюс `_helpers.tpl`, а шаблон `migration-job.yaml` появится только в работе 4.

#### Шаг 4. Проверить чарт: lint, рендер и required

Сначала линтер ищет ошибки структуры. Затем `helm template` рендерит манифесты без кластера, а второй запуск с пустым именем Secret проверяет `required`.

```bash
helm lint .
helm template t . | grep '^kind:'
helm template t . --set database.secretName=
```

| Часть команды | Значение |
|---|---|
| `helm lint .` | проверить чарт в текущем каталоге |
| `helm template t .` | отрендерить манифесты релиза `t`, кластер не нужен |
| `grep '^kind:'` | оставить строки с типами объектов |
| `--set database.secretName=` | передать пустое значение |

Результат первой команды (сокращён):

```
==> Linting .
[INFO] Chart.yaml: icon is recommended

1 chart(s) linted, 0 chart(s) failed
```

Результат второй (ожидаемый):

```
kind: ConfigMap
kind: Service
kind: Deployment
kind: HTTPRoute
```

Результат третьей:

```
Error: execution error at (orders-api/templates/deployment.yaml:…): database.secretName обязателен
```

Разбор вывода:

1. Линтер не нашёл ошибок; совет про `icon` необязателен.
2. В рендере четыре объекта: HPA и hook-Job выключены значениями, поэтому их нет.
3. Пустое значение остановило рендер сообщением из `required`, а до кластера дело не дошло.

#### Шаг 5. Установить релиз и найти его следы

Ставим релиз `shop` с ожиданием готовности, затем смотрим список релизов, Secret с ревизией, владельцев полей Deployment и ответ приложения.

```bash
cd ~/lab/k8s/charts
helm install shop ./orders-api -n lab-07-1 --set route.hostname=lab071.localhost \
  --wait --timeout 2m
helm list -n lab-07-1
k get secret -l owner=helm --show-labels
k get deploy shop --show-managed-fields -o json | jq -c '.metadata.managedFields[] | {manager, operation}'
curl -s http://lab071.localhost:8088/api/orders | jq -c '{n: (.orders|length), pod}'
```

| Часть команды | Значение |
|---|---|
| `helm install shop ./orders-api` | релиз `shop` из локального чарта |
| `--set route.hostname=…` | свой хост, чтобы не пересечься с `orders` |
| `--wait --timeout 2m` | ждать готовности не дольше двух минут |
| `-l owner=helm` | только Secret, созданные Helm |
| `--show-managed-fields` | показать владельцев полей |
| `jq -c '{manager, operation}'` | оставить менеджера и операцию |

Результат (сокращён):

```
NAME: shop
NAMESPACE: lab-07-1
STATUS: deployed
REVISION: 1
…
sh.helm.release.v1.shop.v1   helm.sh/release.v1   modifiedAt=…,name=shop,owner=helm,status=deployed,version=1
{"manager":"helm","operation":"Apply"}
{"n":5,"pod":"shop-…"}
```

Разбор вывода:

1. `STATUS: deployed` и `REVISION: 1` значат, что первая ревизия применена и поды готовы.
2. Secret `sh.helm.release.v1.shop.v1` хранит ревизию; в метках видны имя релиза, статус и номер.
3. Менеджер `helm` с операцией `Apply` значит, что Deployment создан через server-side apply.
4. Ответ `n: 5` приходит от нового пода `shop-…` через Gateway, значит маршрут и база работают.

**Итог.**

| Что узнали | Где видно |
|---|---|
| Чарт состоит из шаблонов и значений | шаги 1–3 |
| `required` останавливает рендер до кластера | шаг 4 |
| Ревизия хранится в Secret | шаг 5, метка `owner=helm` |
| Helm 4 применяет объекты через SSA | шаг 5, менеджер `helm` |

**Уборка.** Релиз `shop` нужен работам 2–4, поэтому удаляется в уборке работы 4. Если вы останавливаетесь здесь, выполните её сейчас.

**Вопросы для самопроверки.**

1. Чем `version` отличается от `appVersion`?

<details><summary>Ответ</summary>
`version` — версия чарта, растёт при любом изменении шаблонов. `appVersion` — версия приложения; в этом чарте она служит тегом образа по умолчанию.
</details>

2. Почему `replicas` в Deployment стоит под условием?

<details><summary>Ответ</summary>
Когда работает HPA, он сам задаёт число реплик. Если чарт пишет `replicas`, каждый upgrade сбрасывает масштаб к значению из values.
</details>

3. Где Helm хранит ревизию релиза и что будет, если удалить эти объекты?

<details><summary>Ответ</summary>
В Secret `sh.helm.release.v1.<релиз>.v<N>` в namespace релиза. Helm «забудет» релиз, а Deployment, Service и остальные объекты останутся в кластере.
</details>

4. Какое значение побеждает: из `values.yaml`, из `-f` или из `--set`?

<details><summary>Ответ</summary>
`--set`. Порядок такой: значения чарта, затем файлы `-f` слева направо, затем `--set`.
</details>

### Лабораторная работа 2. Ожидание и откат

**Риски.** Работа ломает релиз `shop` в собственном namespace; хост и узлы не затрагиваются.

- **Что меняется:** образ Deployment `shop` временно указывает на несуществующий тег `2.9`.
- **Надолго ли:** на минуты; каждый шаг возвращает рабочую версию.
- **Безопасность:** привилегий не нужно.
- **Влияние на систему:** узлы пытаются скачать образ `orders-api:2.9` и получают `ErrImagePull`, остальные поды и namespace не затронуты.
- **Откат:** шаг 2 и шаг 4 возвращают образ `2.0`.

**Цель.** Увидеть, что `deployed` без `--wait` ничего не гарантирует, и сравнить три режима: без ожидания, с `--wait` и с `--rollback-on-failure`.

**Что понадобится.**

- Релиз `shop` из работы 1.
- Около 15 минут: тайм-ауты по 30 секунд.

**Схема опыта.** Один и тот же сломанный upgrade выполняется трижды с разными флагами; смотреть нужно на статус релиза и на поды.

```
upgrade tag=2.9 ──► без флагов              ──► deployed, под в ErrImagePull
                ├─► --wait                   ──► failed, старые поды живы
                └─► --rollback-on-failure    ──► failed + откат на рабочую ревизию
```

Схема показывает, что только третий режим возвращает кластер в рабочее состояние сам.

#### Шаг 1. Сломать образ без ожидания

Обновляем образ на несуществующий тег без `--wait` и смотрим, что Helm скажет и что будет с подами.

```bash
cd ~/lab/k8s/charts
helm upgrade shop ./orders-api -n lab-07-1 --reuse-values --set image.tag=2.9
k get pods
```

| Часть команды | Значение |
|---|---|
| `--reuse-values` | взять значения прошлой ревизии |
| `--set image.tag=2.9` | тега `2.9` в реестре нет |
| `k get pods` | поды релиза |

Результат (сокращён):

```
STATUS: deployed
REVISION: 2
…
```

Под нового ReplicaSet на этом шаге ожидаемо находится в `ErrImagePull` или `ImagePullBackOff`.

Разбор вывода:

1. Helm записал `deployed` почти сразу (в прогоне автора за 1 с), потому что API принял объекты.
2. Готовность подов Helm 4 без `--wait` не проверяет.
3. Новый под не стартует, а команда `k get pods` показывает это.

#### Шаг 2. Откатиться командой rollback

Возвращаем рабочую версию через Helm. Команда создаёт новую ревизию с манифестом предыдущей.

```bash
helm rollback shop -n lab-07-1
k rollout status deploy/shop --timeout=60s
helm history shop -n lab-07-1
```

| Часть команды | Значение |
|---|---|
| `helm rollback shop` | вернуть прошлую ревизию (без номера: предыдущую) |
| `rollout status` | дождаться готовности Deployment |
| `helm history` | показать ревизии с описанием |

Результат (ожидаемый, сокращён):

```
Rollback was a success! Happy Helming!
deployment "shop" successfully rolled out
…
```

Разбор вывода:

1. `Rollback was a success!` значит, что Helm применил манифест прошлой ревизии.
2. В истории появилась новая ревизия с описанием `Rollback to …`: номер не возвращается назад.
3. Поды снова на образе `2.0`.

#### Шаг 3. Повторить с ожиданием

Теперь тот же сломанный upgrade идёт с `--wait` и коротким тайм-аутом в 30 секунд.

```bash
helm upgrade shop ./orders-api -n lab-07-1 --reuse-values --set image.tag=2.9 \
  --wait --timeout 30s
k get pods
```

| Часть команды | Значение |
|---|---|
| `--wait` | ждать готовности ресурсов |
| `--timeout 30s` | не дольше 30 секунд |

Результат (сокращён):

```
Error: UPGRADE FAILED: resource Deployment/lab-07-1/shop not ready. status: InProgress, message: Updated: 1/2
shop-6584744848-6j8gd   Running
shop-6584744848-h58hj   Running
shop-6b598d6f8b-vmh7c   ErrImagePull
```

Разбор вывода:

1. Команда упала через 30 с, релиз получил статус `failed`.
2. Строка `Updated: 1/2` — сообщение kstatus: обновлена одна реплика из двух.
3. Два старых пода работают, а сломанный висит: кластер остался в промежуточном состоянии.

#### Шаг 4. Включить автоматический откат

Заменяем `--wait` на `--rollback-on-failure`: флаг включает ожидание и при неудаче сам возвращает последнюю удачную ревизию.

```bash
helm upgrade shop ./orders-api -n lab-07-1 --reuse-values --set image.tag=2.9 \
  --rollback-on-failure --timeout 30s
helm history shop -n lab-07-1 --max 3
k get deploy shop -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
```

| Часть команды | Значение |
|---|---|
| `--rollback-on-failure` | при ошибке откатить на прошлую удачную ревизию |
| `history --max 3` | последние три ревизии |
| `jsonpath=…image` | образ в шаблоне пода |

Результат (сокращён; номер ревизии зависит от вашей истории):

```
Error: UPGRADE FAILED: release shop failed, and has been rolled back due to rollback-on-failure being set: resource Deployment/lab-07-1/shop not ready…
4   …   deployed   …   Rollback to 1
localhost:5001/orders-api:2.0
```

Разбор вывода:

1. Ошибка остаётся ошибкой: команда завершается с ненулевым кодом, но добавляет `has been rolled back`.
2. Последняя ревизия имеет статус `deployed` и описание `Rollback to …`.
3. Образ вернулся на `2.0` без ручных действий.

**Итог.**

| Что узнали | Где видно |
|---|---|
| Без `--wait` upgrade «успешен» при неработающем образе | шаг 1 |
| `rollback` создаёт новую ревизию | шаг 2 |
| `--wait` фиксирует ошибку, но кластер остаётся смешанным | шаг 3 |
| `--rollback-on-failure` возвращает рабочую версию сам | шаг 4 |

**Уборка.** Отдельной уборки нет: релиз остаётся на образе `2.0` для работы 3.

**Вопросы для самопроверки.**

1. Почему в Helm 4 `deployed` не означает, что приложение работает?

<details><summary>Ответ</summary>
Без `--wait` Helm ждёт только hooks. Статус `deployed` значит, что API принял объекты, а запустились ли поды, он не проверял.
</details>

2. В каком состоянии остаётся кластер после `--wait`, который истёк?

<details><summary>Ответ</summary>
Релиз получает статус `failed`, но старые поды работают, а новый сломанный висит. Откат нужно делать вручную или флагом `--rollback-on-failure`.
</details>

3. Что происходит с номером ревизии при `helm rollback`?

<details><summary>Ответ</summary>
Номер растёт: создаётся новая ревизия с манифестом выбранной. История только удлиняется.
</details>

### Лабораторная работа 3. Конфликт server-side apply и зависший pending-upgrade

**Риски.** Работа меняет релиз `shop` и убивает процесс helm; хост и узлы не затрагиваются.

- **Что меняется:** Deployment правится вручную, затем релиз переустанавливается; последняя ревизия ненадолго зависает в `pending-upgrade`.
- **Надолго ли:** до конца работы; шаг 5 выводит релиз из зависания.
- **Безопасность:** привилегий не нужно; Secret зависшей ревизии не удаляется.
- **Влияние на систему:** кратковременный перезапуск подов `shop`; другие namespace не затронуты.
- **Откат:** `helm rollback` в шаге 5 и переустановка в шаге 3.

**Цель.** Воспроизвести конфликт владельцев полей после ручной правки и оставить релиз в статусе `pending-upgrade`, а затем вылечить обе ситуации.

**Что понадобится.**

- Релиз `shop` из работ 1–2 на образе `2.0`.
- Образ `localhost:5001/orders-api:2.1`.
- Около 25 минут.

**Схема опыта.** Сначала ручная правка отнимает поле у Helm, потом убитая команда оставляет ревизию в промежуточном статусе.

```
kubectl rollout undo ──► владелец поля: kubectl ──► helm upgrade: конфликт
timeout -s KILL helm ──► ревизия pending-upgrade ──► upgrade: "operation in progress"
                                                     └─► helm rollback лечит
```

Схема показывает два независимых сбоя; их причины разные, а вылечить помогает Helm.

#### Шаг 1. Подготовить две рабочие версии

Чтобы `rollout undo` вернул рабочий образ, а не сломанный, переводим релиз на 2.1: прошлый ReplicaSet с образом 2.0 останется в истории Deployment.

```bash
cd ~/lab/k8s/charts
helm upgrade shop ./orders-api -n lab-07-1 --reuse-values --set image.tag=2.1 \
  --wait --timeout 60s
k rollout history deploy/shop
```

| Часть команды | Значение |
|---|---|
| `--set image.tag=2.1` | рабочая версия 2.1 |
| `--wait --timeout 60s` | дождаться выкатки |
| `rollout history` | ревизии самого Deployment |

Результат (ожидаемый): `STATUS: deployed`, а в истории Deployment есть минимум две ревизии.

Разбор вывода: у Deployment теперь два ReplicaSet, 2.0 и 2.1, и у `kubectl` есть куда откатываться.

#### Шаг 2. Откатить вручную и получить конфликт

Откатываем Deployment командой kubectl, а затем просим Helm вернуть образ 2.0 своим upgrade.

```bash
k rollout undo deploy/shop
helm upgrade shop ./orders-api -n lab-07-1 --reuse-values --set image.tag=2.0 \
  --wait --timeout 60s
```

| Часть команды | Значение |
|---|---|
| `rollout undo deploy/shop` | вернуть прошлый ReplicaSet мимо Helm |
| `--set image.tag=2.0` | то, что Helm хочет поставить |

Результат (сокращён):

```
Error: UPGRADE FAILED: conflict occurred while applying object lab-07-1/shop apps/v1, Kind=Deployment: Apply failed with 2 conflicts: conflicts with "kubectl" using apps/v1: …
```

Разбор вывода:

1. Ручной `rollout undo` изменил поля шаблона пода, и их владельцем стал `kubectl`.
2. Helm отправил ту же правку через server-side apply и получил отказ вместо молчаливой перезаписи.
3. В сообщении названы два конфликтующих поля и менеджер, который ими владеет.

#### Шаг 3. Найти владельца и пройти конфликт

Смотрим владельцев полей, затем повторяем upgrade с флагом `--force-conflicts`, который забирает поля себе.

```bash
k get deploy shop --show-managed-fields -o json | jq -c '.metadata.managedFields[] | {manager, operation}'
helm upgrade shop ./orders-api -n lab-07-1 --reuse-values --set image.tag=2.0 \
  --force-conflicts --wait --timeout 60s
```

| Часть команды | Значение |
|---|---|
| `managedFields[]` | список владельцев полей |
| `--force-conflicts` | перезаписать поля, которыми владеют другие |

Результат (сокращён):

```
{"manager":"helm","operation":"Apply"}
{"manager":"kubectl","operation":"Update"}
…
```

Затем `helm upgrade` с флагом завершается статусом `deployed`.

Разбор вывода:

1. Менеджер `kubectl` с операцией `Update` — след ручной правки.
2. С `--force-conflicts` upgrade проходит, но запись менеджера `kubectl` остаётся.
3. Без флага конфликт может вернуться на следующих upgrade.

#### Шаг 4. Убрать след переустановкой

Чтобы начать без следа ручного менеджера, удаляем релиз и ставим заново.

```bash
helm uninstall shop -n lab-07-1 --wait
helm install shop ./orders-api -n lab-07-1 --set route.hostname=lab071.localhost \
  --wait --timeout 2m
```

| Часть команды | Значение |
|---|---|
| `helm uninstall --wait` | удалить релиз и дождаться исчезновения объектов |
| `helm install` | новая установка с ревизии 1 |

Результат (ожидаемый): `STATUS: deployed` и `REVISION: 1`.

Разбор вывода: нумерация ревизий началась заново, а владелец полей Deployment снова только `helm`.

#### Шаг 5. Убить helm посреди upgrade

Запускаем upgrade на сломанный тег и убиваем процесс через 5 секунд сигналом KILL, как это делает сборщик CI при отмене job. Затем читаем статус и пробуем обновить снова.

```bash
timeout -s KILL 5 helm upgrade shop ./orders-api -n lab-07-1 --reuse-values \
  --set image.tag=2.9 --wait --timeout 2m; echo "exit=$?"
helm status shop -n lab-07-1 -o json | jq -r .info.status
helm upgrade shop ./orders-api -n lab-07-1 --reuse-values --set image.tag=2.1
helm history shop -n lab-07-1 --max 2
k get secret -l owner=helm -L status
```

| Часть команды | Значение |
|---|---|
| `timeout -s KILL 5` | убить процесс через 5 секунд без возможности завершиться |
| `echo "exit=$?"` | код возврата убитой команды |
| `status -o json \| jq -r .info.status` | статус релиза |
| `-L status` | показать метку `status` колонкой |

Результат (сокращён; номера ревизий у вас будут другие):

```
exit=137
pending-upgrade
Error: UPGRADE FAILED: another operation (install/upgrade/rollback) is in progress
… deployed          …
… pending-upgrade   Preparing upgrade
sh.helm.release.v1.shop.v…   helm.sh/release.v1   …   deployed
sh.helm.release.v1.shop.v…   helm.sh/release.v1   …   pending-upgrade
```

Разбор вывода:

1. Код 137 значит, что процесс убит сигналом KILL (128 + 9) и не успел записать итог.
2. Статус `pending-upgrade` остался в последней ревизии: Helm сам его не снимет.
3. Следующий upgrade отклонён сообщением `another operation … is in progress`.
4. В Secret видны две записи: прошлая `deployed` и зависшая `pending-upgrade`.

#### Шаг 6. Вылечить зависание

Откатываем релиз на последнюю удачную ревизию, затем проверяем, что upgrade снова работает и приложение отвечает версией 2.1.

```bash
helm rollback shop -n lab-07-1
helm upgrade shop ./orders-api -n lab-07-1 --reuse-values --set image.tag=2.1 \
  --wait --timeout 60s
curl -s http://lab071.localhost:8088/version
```

| Часть команды | Значение |
|---|---|
| `helm rollback shop` | вернуться к последней удачной ревизии |
| `curl …/version` | версия, которую сообщает приложение |

Результат (сокращён):

```
Rollback was a success! Happy Helming!
…
{"version": "2.1", "pod": "shop-…"}
```

Разбор вывода:

1. `Rollback was a success!` значит, что зависшая ревизия заменена новой в статусе `deployed`.
2. Upgrade снова проходит без ошибки.
3. Поле `version` равно `2.1`, значит под нового образа отвечает через Gateway.

**Итог.**

| Что узнали | Где видно |
|---|---|
| Ручная правка делает `kubectl` владельцем поля | шаги 2–3 |
| `--force-conflicts` проходит конфликт, но след остаётся | шаг 3 |
| Убитый helm оставляет `pending-upgrade` | шаг 5 |
| `helm rollback` выводит релиз из зависания | шаг 6 |

**Уборка.** Отдельной уборки нет: релиз `shop` на образе `2.1` нужен работе 4.

**Вопросы для самопроверки.**

1. Почему Helm 3 молча перезаписал бы ручную правку, а Helm 4 нет?

<details><summary>Ответ</summary>
Helm 3 сравнивал три версии манифеста на клиенте и отправлял патч. Helm 4 применяет объекты через server-side apply, где чужие поля защищены и дают конфликт.
</details>

2. Как избежать конфликтов в CI без постоянного `--force-conflicts`?

<details><summary>Ответ</summary>
Менять объекты релиза только через Helm: срочный откат делать `helm rollback`, а не `kubectl rollout undo`. Если ручные правки неизбежны, использовать флаг осознанно.
</details>

3. Чем лечат `pending-install`, если откатываться некуда?

<details><summary>Ответ</summary>
Удаляют Secret зависшей ревизии, проверяют объекты в кластере вручную и повторяют установку.
</details>

4. Какие два правила защищают CI от зависших ревизий?

<details><summary>Ответ</summary>
Тайм-аут job больше `--timeout` самого helm, и один деплой релиза за раз.
</details>

### Лабораторная работа 4. Hook миграции и хэш конфигурации

**Риски.** Работа создаёт таблицу в базе namespace `orders` стенда.

- **Что меняется:** в базе `orders` появляется таблица `schema_version`; в чарте появляется шаблон `migration-job.yaml`; релиз `shop` получает новые значения.
- **Надолго ли:** до уборки этой работы.
- **Безопасность:** Job берёт адрес базы из Secret `postgres` в `lab-07-1`; пароль в командах не виден. Образ `postgres:17.6-alpine` скачивается с Docker Hub (около 100 МБ).
- **Влияние на систему:** одна короткая запись в базу; приложение `orders-api` не затрагивается.
- **Откат:** уборка удаляет таблицу, релиз и namespace.

**Цель.** Добавить в чарт hook миграции, увидеть порядок «Job, затем Deployment» и проверить, что изменение конфига меняет хэш и перезапускает поды.

**Что понадобится.**

- Релиз `shop` из работ 1–3.
- Работающий `postgres-0` в namespace `orders`.
- Около 20 минут.

**Схема опыта.** Upgrade включает hook, и Job записывает номер ревизии в базу до обновления Deployment.

```
helm upgrade ──► pre-upgrade hook: Job migrate ──► строка в schema_version
             └─► Deployment: новый хэш ConfigMap ──► новый ReplicaSet
```

Схема показывает два следствия одного upgrade: запись в базе и перезапуск подов.

#### Шаг 1. Добавить шаблон hook

Создаём Job с аннотациями pre-install и pre-upgrade. Политика `before-hook-creation,hook-succeeded` удаляет Job перед следующим запуском и после успеха.

```bash
cd ~/lab/k8s/charts/orders-api
cat > templates/migration-job.yaml <<'E'
{{- if .Values.migration.enabled }}
apiVersion: batch/v1
kind: Job
metadata:
  name: {{ .Release.Name }}-migrate-{{ .Release.Revision }}
  labels: {{- include "orders-api.labels" . | nindent 4 }}
  annotations:
    "helm.sh/hook": pre-install,pre-upgrade
    "helm.sh/hook-weight": "0"
    "helm.sh/hook-delete-policy": before-hook-creation,hook-succeeded
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 120
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: migrate
        image: postgres:17.6-alpine
        env:
        - name: DATABASE_URL
          valueFrom:
            secretKeyRef: {name: {{ .Values.database.secretName }}, key: DATABASE_URL}
        command:
        - sh
        - -c
        - |
          psql "$DATABASE_URL" -c 'CREATE TABLE IF NOT EXISTS schema_version (v int);
            INSERT INTO schema_version VALUES ({{ .Release.Revision }})'
{{- end }}
E
```

| Часть шаблона | Значение |
|---|---|
| `if .Values.migration.enabled` | Job создаётся только по значению |
| `helm.sh/hook: pre-install,pre-upgrade` | запуск до установки и до обновления |
| `hook-delete-policy` | удалить прошлый Job и успешный Job |
| `backoffLimit: 0` | без повторов при ошибке |
| `activeDeadlineSeconds: 120` | не дольше двух минут, иначе upgrade не зависнет |
| `{{ .Release.Revision }}` | номер ревизии записывается в базу |

Вывода у команды нет. Job пишет в таблицу `schema_version` номер ревизии, по которому видно, какой upgrade его запустил.

#### Шаг 2. Выполнить upgrade с миграцией и новым конфигом

Запоминаем хэш конфигурации до upgrade, затем обновляем релиз: меняем скидку в конфиге и включаем hook.

```bash
cd ~/lab/k8s/charts
H1=$(k get deploy shop -o jsonpath='{.spec.template.metadata.annotations.checksum/config}')
helm upgrade shop ./orders-api -n lab-07-1 --reuse-values \
  --set config.discount_percent=10 --set migration.enabled=true --wait --timeout 90s
H2=$(k get deploy shop -o jsonpath='{.spec.template.metadata.annotations.checksum/config}')
echo "${H1:0:12} -> ${H2:0:12}"
```

| Часть команды | Значение |
|---|---|
| `H1=$(… checksum/config)` | хэш конфигурации в шаблоне пода до upgrade |
| `--set config.discount_percent=10` | новая скидка в ConfigMap |
| `--set migration.enabled=true` | включить hook |
| `${H1:0:12}` | первые 12 символов хэша |

Результат:

```
3a12bfdf1e09 -> b300b04a65b2
```

Разбор вывода:

1. Хэш изменился, потому что изменился отрендеренный ConfigMap.
2. Новый хэш в шаблоне пода создал новый ReplicaSet и перезапустил поды.
3. Upgrade завершился после выполнения hook: иначе `--wait` не дошёл бы до Deployment.

#### Шаг 3. Проверить Job, базу и приложение

Hook должен уже исчезнуть, запись о миграции появиться в базе, а приложение — отдавать новую скидку.

```bash
k get jobs
kubectl -n orders exec postgres-0 -- psql -U orders -d orders -tAc "select v from schema_version"
curl -s http://lab071.localhost:8088/config
```

| Часть команды | Значение |
|---|---|
| `k get jobs` | Job в namespace релиза |
| `psql -tAc "select v …"` | прочитать номер ревизии без оформления |
| `curl …/config` | конфигурация, которую видит приложение |

Результат (сокращён):

```
No resources found in lab-07-1 namespace.
8
{… "discount_percent": 10 …}
```

Разбор вывода:

1. Job удалён политикой `hook-succeeded`, поэтому список пуст.
2. Число в базе равно номеру ревизии, с которой запускался hook: в прогоне автора это 8, у вас будет другое.
3. Приложение отдаёт `discount_percent: 10`, значит новый ConfigMap подключён.

#### Шаг 4. Посмотреть значения, манифест и hook

Смотрим, что Helm считает значениями пользователя, какие объекты входят в релиз и где хранится hook.

```bash
helm get values shop -n lab-07-1
helm get manifest shop -n lab-07-1 | grep '^kind:'
helm get hooks shop -n lab-07-1 | grep '^kind:'
```

| Часть команды | Значение |
|---|---|
| `get values` | только значения, которые передал пользователь |
| `get manifest` | манифест релиза без hooks |
| `get hooks` | манифесты hooks |

Результат (ожидаемый, сокращён):

```
USER-SUPPLIED VALUES:
config:
  discount_percent: 10
image:
  tag: "2.1"
migration:
  enabled: true
route:
  hostname: lab071.localhost
kind: ConfigMap
kind: Service
kind: Deployment
kind: HTTPRoute
kind: Job
```

Разбор вывода:

1. В блоке `USER-SUPPLIED VALUES` только то, что вы передали флагами; значений по умолчанию из чарта там нет.
2. В манифесте релиза четыре объекта, и Job среди них нет.
3. Job виден только в `get hooks`: hook хранится отдельно и в релиз не входит.

**Итог.**

| Что узнали | Где видно |
|---|---|
| Hook выполняется до обновления объектов | шаги 2–3 |
| Политика удаления убирает успешный Job | шаг 3 |
| Изменение ConfigMap меняет хэш и перезапускает поды | шаг 2 |
| Hook не входит в манифест релиза | шаг 4 |

**Уборка.** Удаляем релиз, таблицу миграций, namespace и функцию `k`. Чарт остаётся в `~/lab/k8s/charts/orders-api`.

```bash
helm uninstall shop -n lab-07-1 --wait
kubectl -n orders exec postgres-0 -- psql -U orders -d orders -c "DROP TABLE IF EXISTS schema_version"
kubectl delete ns lab-07-1
unset -f k
```

Первая команда удаляет релиз и его объекты, вторая — таблицу в базе стенда. Третья удаляет namespace вместе с Secret `postgres`, а четвёртая снимает функцию. Проверьте, что `helm list -A` не содержит `shop`.

**Вопросы для самопроверки.**

1. Что произойдёт при `helm rollback`, если миграция уже изменила схему?

<details><summary>Ответ</summary>
Схема останется новой: hooks не откатываются. Поэтому миграцию делают совместимой с предыдущей версией приложения (expand/contract).
</details>

2. Зачем в hook-Job нужны `before-hook-creation` и `activeDeadlineSeconds`?

<details><summary>Ответ</summary>
Первая политика удаляет прошлый Job, иначе повторный upgrade упадёт на «already exists». Вторая ограничивает время, чтобы зависший Job не держал upgrade до конца `--timeout`.
</details>

3. Как изменение ConfigMap приводит к перезапуску подов?

<details><summary>Ответ</summary>
Хэш отрендеренного ConfigMap записан в аннотацию шаблона пода. Новый хэш меняет шаблон, и Deployment выкатывает новый ReplicaSet.
</details>

4. Почему `helm get manifest` не показывает Job?

<details><summary>Ответ</summary>
Объект с аннотацией `helm.sh/hook` Helm хранит отдельно от манифеста релиза. Его показывает `helm get hooks`.
</details>

---

## → Дальше

Вы собрали чарт сами и знаете, что в нём происходит при установке, обновлении и откате, поэтому в 07-2 можно читать чужие чарты. Там вы поставите чарт PostgreSQL из публичного источника, найдёте шаблон, который порождает нужное поле, сравните рендер с кластером перед upgrade и разберёте, что происходит с PVC при мажорном обновлении чарта. Эта часть идёт следующей, потому что без понимания шаблонов и релизов чужие значения превращаются в набор непонятных ключей.
