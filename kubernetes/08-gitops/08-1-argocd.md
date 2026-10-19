# 08-1. Argo CD

> Модуль 08 «GitOps» · часть 1 из 2 · ~1,5 ч чтения + ~2 ч лабы (установка и ожидание опроса Git) · Нужно: стенд 00-1 (контекст `kind-lab`), kubectl из 00-2, каталог base из 07-3, образы `orders-api:2.0` и `2.1` в реестре стенда, доступ узлов к quay.io, ghcr.io и public.ecr.aws · Опирается на: 07-3 (Kustomize), 01-3 (server-side apply, finalizer), 02-2 (Deployment), 05-4 (HPA)

## Где мы на карте

Эта часть открывает модуль 08 и показывает, как кластер приводит себя к состоянию из Git. В 07-3 вы собирали манифесты окружения из base и overlay и применяли их командой `kubectl apply -k`. Теперь применять будет агент внутри кластера: он читает тот же каталог из Git, сравнивает его с кластером и исправляет расхождения. Часть опирается на 07-3 (каталог Kustomize), 01-3 (server-side apply и finalizer) и 02-2 (rollout Deployment). От 05-4 нужен HPA: с Argo CD у него возникает спор за поле `replicas`.

Следующая часть, 08-2, поднимает схему на уровень платформы: много приложений и окружений, секреты и промоушен. Все её приёмы опираются на механизм из этой части: сверку Git и кластера, политику синхронизации и правила отката.

```
CI (курс cicd)        Git                    Argo CD (эта часть)             кластер
сборка, тесты ──► коммит манифеста ──► repo-server: рендер из Git ──► application-controller:
                                                                   сравнение, sync, health
                                                                       │ применяет ▼
                                                                   Deployment, Service, ...
```

Схема 1. Место Argo CD между Git и кластером: CI только пишет в Git, а применяет изменения агент в кластере.

---

## 1. Какую задачу решает Argo CD

Argo CD держит кластер в состоянии, описанном в Git, и показывает любое расхождение. Разберём, что такое GitOps, чем pull-деплой отличается от push-деплоя и чего Argo CD не делает.

### GitOps: желаемое состояние в Git

**GitOps** — способ эксплуатации, при котором манифесты кластера лежат в Git, а менять кластер можно только коммитом. **Желаемое состояние** (desired state) — это манифесты в репозитории. **Живое состояние** (live state) — объекты, которые существуют в кластере сейчас. **Дрейф** (drift) — расхождение между ними: кто-то поправил объект руками или контроллер дописал в него поле.

Git даёт то, что в ручном деплое приходится строить отдельно. Журнал коммитов отвечает, кто, когда и зачем изменил кластер, ревью merge request защищает прод от случайных правок, а откат превращается в обычный `git revert`.

### Push и pull

В **push-модели** (push) CI после сборки сам применяет манифесты командой `kubectl apply`, поэтому хранит ключи от кластера. В **pull-модели** (pull) агент внутри кластера сам забирает манифесты из Git, а CI доступа к кластеру не имеет. Argo CD работает по pull-модели.

```
push:   CI ──(ключи кластера)──► kubectl apply ──► кластер
pull:   CI ──► Git ◄── агент в кластере (читает сам) ──► кластер
```

Схема 2. В push-модели ключи кластера лежат в CI, в pull-модели они остаются внутри кластера.

У pull-модели три следствия. Ключи не покидают кластер, поэтому взлом CI не даёт доступа к проду. Дрейф виден и исправляется постоянно, а не только в момент выкатки. Изменение доезжает с задержкой, потому что агент узнаёт о новом коммите опросом или сигналом из Git (§3).

### Чего Argo CD не делает

**Argo CD** — агент GitOps для Kubernetes: он берёт манифесты из Git, сравнивает их с кластером и применяет. Он не собирает образы: это задача CI (курс `cicd`). Он не расшифровывает секреты из Git без дополнительных инструментов (08-2). Helm и Kustomize он не заменяет, а запускает для рендера (07-1, 07-3). Второй популярный агент GitOps — Flux; сравнение с ним в 08-2.

---

## 2. Как устроен Argo CD

Argo CD состоит из нескольких компонентов в одном namespace, а работа вокруг одного объекта — Application. Разберём компоненты, объект Application, цикл сверки, два статуса и способ, которым Argo CD помечает свои объекты.

### Компоненты

Установка создаёт в namespace `argocd` семь рабочих нагрузок.

- **argocd-repo-server** — клонирует репозитории и рендерит манифесты (Kustomize, Helm, обычный YAML); результат кэширует в Redis.
- **argocd-application-controller** — сравнивает Git и кластер, запускает синхронизацию и считает здоровье; это StatefulSet.
- **argocd-server** — отдаёт API и веб-интерфейс, к нему подключается CLI.
- **argocd-applicationset-controller** — создаёт объекты Application из шаблонов (08-2).
- **argocd-redis** — кэш отрендеренных манифестов и состояния.
- **argocd-dex-server** — единый вход (SSO) через внешних поставщиков.
- **argocd-notifications-controller** — отправляет уведомления о событиях Application.

```
 браузер / argocd (CLI) ──► argocd-server ──► Kubernetes API (объекты Application)
                                                     ▲
 Git ◄── argocd-repo-server ◄──► argocd-redis        │ читает и пишет статус
              ▲ рендер                                │
              └──── argocd-application-controller ───┘ сравнивает и применяет в кластер
```

Схема 3. Контроллер просит repo-server отрендерить Git, сравнивает результат с кластером и пишет итог в статус Application.

Состояние Argo CD хранит в самом Kubernetes: Application, AppProject и ApplicationSet — это **CRD** (custom resource definition, пользовательский тип объекта, 09-1). Поэтому приложениями управляют и через `kubectl`, и через CLI.

### Application: источник и назначение

**Application** — объект Argo CD, который связывает источник в Git с местом в кластере. Он лежит в namespace `argocd` и описывает три вещи: откуда брать манифесты, куда применять и как синхронизировать.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: {name: orders-staging, namespace: argocd}
spec:
  project: default
  source:
    repoURL: http://gitea.lab-08-1.svc:3000/lab/orders-gitops.git
    targetRevision: main
    path: apps/orders-api/overlays/staging
  destination: {server: https://kubernetes.default.svc, namespace: lab-08-1-staging}
  syncPolicy:
    automated: {prune: true, selfHeal: true}
```

Фрагмент манифеста: `source` задаёт репозиторий, ветку и каталог с `kustomization.yaml`, `destination` — кластер и namespace, а `syncPolicy.automated` включает автоматическую синхронизацию (§3). Адрес `kubernetes.default.svc` означает кластер, в котором работает сам Argo CD.

### Цикл сверки

**Сверка** (reconciliation) — повторяющийся цикл из четырёх шагов, который контроллер проходит для каждого Application.

1. Контроллер получает повод: истёк таймер опроса, пришёл сигнал из Git, или в кластере изменился отслеживаемый объект.
2. Контроллер просит repo-server отрендерить манифесты нужной ревизии; готовый результат берётся из кэша, если коммит и путь не изменились.
3. Контроллер сравнивает отрендеренные манифесты с живыми объектами и вычисляет различия (diff).
4. Если включена автоматическая синхронизация и различия есть, контроллер запускает **sync** — операцию, которая применяет манифесты в кластер.

Повод из Git и повод из кластера работают по-разному. Изменения в кластере контроллер видит сразу, потому что следит за объектами через watch (01-1), а Git он опрашивает по таймеру. Поэтому ручную правку Argo CD замечает за секунды, а новый коммит — до нескольких минут (§3).

### Два статуса

У Application два независимых статуса.

- **Sync** показывает, совпадает ли кластер с Git: `Synced`, `OutOfSync` или `Unknown`.
- **Health** показывает, работает ли то, что есть в кластере: `Healthy`, `Progressing`, `Degraded`, `Suspended`, `Missing` или `Unknown`.

Оси независимы. Приложение `Synced` и `Degraded` применено верно, но не работает, например под падает. Приложение `OutOfSync` и `Healthy` работает, но не так, как записано в Git. Здоровье Argo CD вычисляет встроенными проверками для стандартных типов (Deployment готов, PVC в `Bound`) и скриптами на Lua для CRD. Application здоров, только если здоровы все его объекты.

### Отслеживание объектов

Argo CD должен знать, какие объекты в кластере принадлежат Application, иначе он не сможет удалять лишнее. Для этого он ставит на каждый применённый объект аннотацию `argocd.argoproj.io/tracking-id` со значением вида `приложение:группа/Kind:namespace/имя`. Начиная с версии 3.0 аннотация — способ по умолчанию.

Прежний способ — метка `app.kubernetes.io/instance` — теперь анти-рецепт. Эту метку ставят и Helm-чарты, поэтому два владельца затирали значения друг друга, а Argo CD терял связь с объектом. Способ выбирает параметр `application.resourceTrackingMethod` в `argocd-cm`.

---

## 3. Как управлять Argo CD

Argo CD настраивают объектом Application и параметрами в ConfigMap, а управляют из CLI `argocd`. Ниже идут карточка инструмента, политика синхронизации, порядок применения, доставка изменений из Git и проекты.

### Карточка инструмента: argocd

**Назначение.** `argocd` — клиент командной строки к Argo CD. Он создаёт и смотрит Application, показывает разницу с Git, запускает sync и откат, а в скриптах CI ждёт готовности приложения.

**Как работает.** CLI не читает Git и кластер сам: он вызывает API сервера Argo CD, а сервер отвечает данными контроллера.

```
argocd app diff ... ──► argocd-server (gRPC/HTTPS :443) ──► Application в Kubernetes
                              │                                (статус пишет контроллер)
                              └─ токен из ~/.config/argocd/config
```

Схема 4. Команда идёт к серверу, а не к Git: ответ зависит от того, что контроллер уже сравнил.

**Откуда берёт данные.** Адрес сервера и токен лежат в `~/.config/argocd/config`, их записывает `argocd login`. Для скриптов их задают переменными `ARGOCD_SERVER` и `ARGOCD_AUTH_TOKEN`. Режим `--core` обходит сервер и ходит прямо в Kubernetes API. Ему нужен текущий namespace `argocd` в контексте, а мы контекст не меняем, поэтому в лабораторных режим не используем.

**Основные команды.** Блок показывает команды для повседневной работы; комментарий поясняет каждую строку.

```bash
argocd login 127.0.0.1:8443 --insecure --username admin  # войти, токен сохранится в config
argocd app list                           # все Application: sync, health, источник
argocd app get orders-staging             # состояние и ресурсы одного приложения
argocd app diff orders-staging            # разница Git и кластера; код 1, если она есть
argocd app sync orders-staging            # применить Git сейчас
argocd app history orders-staging         # применённые ревизии с номерами
argocd app rollback orders-staging 3      # вернуть ревизию 3 (нужен выключенный auto-sync)
argocd app set orders-staging --sync-policy none   # выключить автоматическую синхронизацию
argocd app delete orders-staging          # удалить Application (каскад зависит от finalizer)
argocd repo list                          # подключённые репозитории
argocd proj list                          # проекты
```

**Команды для скриптов.** В CI нужны токен вместо пароля, машинный вывод и ожидание результата.

```bash
argocd account generate-token --account ci       # токен учётной записи ci (создайте её в argocd-cm)
export ARGOCD_SERVER=argocd.example.com          # адрес сервера
export ARGOCD_AUTH_TOKEN=...                     # токен из команды выше, секрет CI
argocd app get orders-staging -o json | jq -r '.status.sync.status'  # статус без разбора текста
argocd app wait orders-staging --sync --health --timeout 300         # ждать Synced и Healthy
argocd app sync orders-staging --dry-run         # показать, что бы применилось
```

**Частые ошибки.**

- Сервер Argo CD отдаёт самоподписанный сертификат, и без флага `--insecure` вход не проходит.
- Порт-форвард упал или не запущен, и `login` ждёт до тайм-аута.
- `rollback` отказывает при включённом auto-sync: сначала выключите его командой `app set`.
- Версия CLI заметно старше сервера, и часть флагов не работает.
- За обратным прокси без HTTP/2 помогает флаг `--grpc-web`.

**Установка.** Версия CLI должна совпадать с версией сервера, в лабораторных это v3.5.5. В Ubuntu скачайте бинарник релиза и положите его в `/usr/local/bin`; рядом с релизом лежит файл с контрольными суммами `cli_checksums.txt`.

```bash
V=v3.5.5
curl -fsSL -o /tmp/argocd \
  "https://github.com/argoproj/argo-cd/releases/download/${V}/argocd-linux-amd64"
sudo install -m 0555 /tmp/argocd /usr/local/bin/argocd
```

Команды выше относятся к Ubuntu: `V` задаёт версию, `curl` скачивает бинарник, `install` кладёт его с правами только на чтение и запуск. В Manjaro достаточно `sudo pacman -S argocd`, но версия пакета может отличаться от версии сервера, поэтому сверяйте её по `argocd version --client`.

### Политика синхронизации

**Политика синхронизации** (sync policy) в поле `syncPolicy` решает, кто запускает sync и что он делает с лишним. Без раздела `automated` sync запускает человек командой или кнопкой, а Argo CD только показывает `OutOfSync`.

Три настройки автоматической синхронизации работают независимо.

| Настройка | Без неё | С ней |
|---|---|---|
| automated | sync только вручную | при расхождении Git и кластера Argo CD применяет сам |
| selfHeal | правка в кластере остаётся как OutOfSync | правка откатывается к Git |
| prune | объект, удалённый из Git, остаётся в кластере | объект удаляется из кластера |

**Self-heal** (самолечение) возвращает кластер к Git при ручной правке. Без него автоматическая синхронизация срабатывает только на новый коммит, а дрейф в кластере остаётся. **Prune** (чистка) удаляет объекты, которые Argo CD когда-то применил, а в Git их больше нет; опознаёт он их по аннотации отслеживания (§2). Если Git отрендерился в пустой набор, автоматический prune не сработает, пока не включён параметр `allowEmpty`: это защита от случайно пустого каталога.

Вместе с `automated` обычно задают `syncOptions` — список параметров sync. Нужны четыре:

- `CreateNamespace=true` — создать namespace назначения, если его нет.
- `ServerSideApply=true` — применять через server-side apply (01-3), без лимита аннотации на 256 КиБ.
- `PruneLast=true` — удалять лишнее после того, как остальное применено и здорово.
- `RespectIgnoreDifferences=true` — не перезаписывать игнорируемые поля при sync (§5).

Автоматический sync не повторяет операцию, которая уже упала на той же ревизии с теми же параметрами. Повторы настраивает раздел `retry`: по документации интервал стартует с 5 с, удваивается и ограничен 3 минутами.

### Порядок применения: волны и hooks

Argo CD применяет объекты в фиксированном порядке типов (namespace раньше Deployment), а для остального порядок задают сами. **Sync wave** (волна) — аннотация `argocd.argoproj.io/sync-wave` с целым числом, по умолчанию 0: объекты с меньшим числом применяются раньше и должны стать здоровыми до начала следующей волны. Так CRD ставят до своих объектов, а миграцию базы — до приложения.

**Hook** — объект (обычно Job), который Argo CD запускает на определённой фазе sync, заданной аннотацией `argocd.argoproj.io/hook`. Фаз четыре: `PreSync` до применения, `Sync` вместе с ним, `PostSync` после успеха и `SyncFail` при неудаче. Политика `argocd.argoproj.io/hook-delete-policy` решает, когда удалять завершённый hook. Отдельные фазы `PreDelete` и `PostDelete` запускаются при удалении приложения.

```
sync ► PreSync (Job миграции) ► волна -1 (CRD) ► волна 0 (Deployment) ► волна 1 ► PostSync
        любая неудача ► SyncFail
```

Схема 5. Фазы идут слева направо; внутри фазы Sync объекты делятся на волны по аннотации.

Hooks из Helm-чартов Argo CD переводит в свои (07-1), а CVE октября 2026 показала, что hooks удаления — место для ошибок политики безопасности (§6).

### Доставка изменений из Git

Изменение попадает в кластер тремя способами, и они различаются задержкой.

- **Опрос** — контроллер сам проверяет Git раз в 180 с (параметр `timeout.reconciliation` в `argocd-cm`) с небольшим случайным разбросом.
- **Webhook** — Git-сервер сообщает Argo CD о пуше запросом на адрес `/api/webhook` сервера; Gitea, GitHub и GitLab умеют это, задержка падает до секунд.
- **Refresh** — принудительная проверка: команда `argocd app get --refresh` или аннотация `argocd.argoproj.io/refresh=normal` на Application. Значение `hard` ещё и сбрасывает кэш манифестов.

Для боевой установки выбирают webhook и оставляют опрос как страховку. В лабораторной Git-сервер находится в кластере, и мы пользуемся аннотацией refresh.

### Проекты и доступ

**AppProject** — объект, который ограничивает набор Application: какие репозитории, кластеры, namespace и типы объектов им разрешены. Проект `default` разрешает всё, поэтому в боевой установке для каждой команды создают свой проект, а Application кладут только в него.

Права пользователей задаёт RBAC Argo CD в ConfigMap `argocd-rbac-cm` и роли внутри проектов. В версии 3.0 правила стали строже. Чтение логов требует отдельного права `logs, get`, а права `update` и `delete` на Application не распространяются на его подресурсы.

---

## 4. Как увидеть состояние

Состояние видно в трёх местах: в статусе Application, в выводе CLI и в логах компонентов. Начинать стоит со статуса, потому что он отвечает на вопросы «что расходится» и «что упало».

### Статус Application

Объект Application — обычный объект Kubernetes, поэтому его читают через `kubectl`. Нужные поля такие:

- `status.sync.status` — Synced или OutOfSync.
- `status.health.status` — здоровье приложения целиком.
- `status.sync.revision` — коммит, с которым сравнивался кластер.
- `status.resources` — список объектов приложения с их sync-статусом.
- `status.operationState` — итог последней операции sync и её сообщение.
- `status.conditions` — ошибки вроде `ComparisonError`.

Начиная с версии 3.0 здоровье отдельных ресурсов в `status.resources` по умолчанию не записывается, чтобы разгрузить Kubernetes API. Здоровье объектов видно в `argocd app get` и в интерфейсе, а здоровье приложения в `status.health` остаётся.

### Вывод CLI

Команда `argocd app get` выводит сводку: источник, назначение, статусы и таблицу объектов. Команда `argocd app diff` показывает различия в формате diff. Команда `argocd app history` перечисляет применённые ревизии. Все они показывают то, что контроллер уже посчитал, поэтому после свежего коммита сначала выполните refresh.

### Логи и интерфейс

Причину ошибки рендера ищут в логах repo-server, ошибку применения — в логах application-controller, а порядок событий — в `kubectl -n argocd get events`. Интерфейс Argo CD открывается через `kubectl port-forward svc/argocd-server 8443:443` на `https://127.0.0.1:8443`, логин `admin`, начальный пароль лежит в Secret `argocd-initial-admin-secret`. Интерфейс показывает дерево объектов с состоянием каждого и удобен для разбора, но для повторяемых проверок лучше CLI.

---

## 5. Что ломается и как найти причину

Поломки Argo CD сводятся к пяти классам: не сравнивается, не доезжает, вечный OutOfSync, правки не держатся и удаление ведёт себя неожиданно. Для каждого есть свой порядок поиска.

### ComparisonError: Argo CD не может сравнить

Условие `ComparisonError` в `status.conditions` значит, что контроллер не получил манифесты. Сообщение содержит причину: репозиторий недоступен, путь не найден, Kustomize или Helm не отрендерились, repo-server не успел ответить. Сообщение вроде `context deadline exceeded` указывает на кэш или перегрузку компонента, а не на ошибку в манифестах, поэтому проверьте `kubectl -n argocd get pods`: при остановленном Redis repo-server не рендерит.

Порядок поиска: сообщение условия, затем логи repo-server, затем проверка пути и ревизии (`argocd app get`), затем доступ к репозиторию с точки зрения repo-server.

### Изменение из Git не доехало

Причины перечислены от частых к редким.

1. Опрос ещё не прошёл: до 3 минут без webhook, поэтому сделайте refresh.
2. Ветка в `targetRevision` не та, в которую вы запушили.
3. Auto-sync выключен, и приложение `OutOfSync` ждёт ручного sync.
4. Прошлая попытка sync упала на той же ревизии, и автоматическая синхронизация её не повторяет (§3).
5. Каталог `path` не содержит `kustomization.yaml` или манифестов.

Диагностика: `argocd app get` показывает ревизию, с которой сравнивался кластер, — сверьте её с последним коммитом.

### Вечный OutOfSync

Приложение возвращается в `OutOfSync`, хотя Git не меняли. Почти всегда у поля **два владельца**: Argo CD пишет в него значение из Git, а второй участник — контроллер, webhook или человек — меняет его обратно. Причину находят в `managedFields` объекта (01-3): там видно, кто записал спорное поле.

Типичные источники собраны в таблице.

| Источник | Что расходится | Решение |
|---|---|---|
| HPA | число реплик Deployment | убрать реплики из манифеста |
| мутирующий webhook | контейнеры и аннотации | игнорировать путь поля |
| контроллер сертификатов | поле caBundle | игнорировать по выражению jq |
| генератор со случайными значениями | Secret и аннотации | убрать случайность из рендера |
| значения по умолчанию API | необязательные поля | прописать их в Git явно |

Лечение зависит от владельца. Если поле должен вести кто-то другой, уберите его из Git. Если убрать нельзя, укажите Argo CD игнорировать поле в разделе `ignoreDifferences` и добавьте `RespectIgnoreDifferences=true`, иначе поле всё равно перезапишется при sync. Игнорировать нужно точечно — путь и, если возможно, менеджера поля через `managedFieldsManagers`, а не весь объект. Опыт — лабораторная работа 3.

### Ручные правки не держатся

При включённом self-heal правка в кластере откатывается за секунды, и `kubectl scale` или `kubectl rollout undo` не работают. Это защита от обхода ревью и неудобство во время инцидента. Для экстренной правки сначала выключите auto-sync у Application (`argocd app set --sync-policy none`), поправьте кластер, затем перенесите правку в Git и включите auto-sync обратно.

### Удаление Application

Удаление Application не обязательно удаляет объекты приложения. Если у Application есть finalizer `resources-finalizer.argocd.argoproj.io`, удаление идёт каскадом и убирает все его объекты (01-3). Без finalizer объекты остаются в кластере, а Argo CD просто перестаёт ими управлять. От случайного prune защищает аннотация `argocd.argoproj.io/sync-options: Prune=false` на самом объекте — для PVC и других данных это обязательная страховка.

---

## 6. Пределы и значения по умолчанию

Ниже собраны версии, числа и пределы, которые встречались в части. Версии проверены на 19 октября 2026 года.

### Версии и безопасность

Текущая линия — 3.5.x, на стенде мы закрепляем v3.5.5 (выпуск 12 октября 2026). Поддерживаются также линии 3.4 (3.4.11) и 3.3 (3.3.16). Выпуск 3.6 пока в статусе release candidate, на стенд не берётся.

Выпуски 3.5.4, 3.4.10 и 3.3.15 от 6 октября 2026 закрыли критичные уязвимости. Одна позволяла обойти ограничения AppProject через hooks PreDelete и PostDelete. Две другие выполняли команды через удалённую ссылку Kustomize и через каталог настроек Helm в Kustomize. Используйте версию не ниже этих и не подключайте чужие репозитории как remote base. Версия Argo CD обновляется регулярно, поэтому перед установкой сверяйте страницу релизов `github.com/argoproj/argo-cd/releases`.

### Что менялось в 3.x

- 3.0: отслеживание по аннотации, RBAC на логи, строгие права на подресурсы, репозитории только в Secret, исключения ресурсов по умолчанию (Endpoints, EndpointSlice, Lease).
- 3.3: установка и обновление командой `kubectl apply --server-side --force-conflicts`, потому что CRD ApplicationSet не помещается в аннотацию client-side apply.
- 3.5: встроенный Helm 4, параметр `helm.version: v3` игнорируется; impersonation действует на все операции.

### Числа по умолчанию

- Опрос Git — 180 с (`timeout.reconciliation`).
- Волны — между волнами пауза в 2 с по документации; номер волны по умолчанию 0.
- Повтор sync — не задан, пока нет раздела `retry`.
- Обработчики контроллера — по документации 20 для статусов и 10 для операций.

### Масштаб

Один application-controller обрабатывает все приложения и становится узким местом на сотнях кластеров и тысячах Application. Решения: шардирование контроллера по кластерам (несколько реплик StatefulSet), больше реплик repo-server, webhook вместо частого опроса и отдельные установки Argo CD для разных команд. Рендер Helm и Kustomize с большими зависимостями — вторая причина медленной сверки, поэтому следите за временем рендера в логах repo-server.

---

## Лабораторные работы

Работы идут на стенде 00-1 по порядку: каждая использует Gitea, Argo CD и репозиторий из предыдущей. Gitea живёт в namespace `lab-08-1`, приложение — в `lab-08-1-staging`. Argo CD ставится в namespace `argocd`: это отступление от правила `lab-NN-M`, потому что манифест установки жёстко ссылается на это имя. Уборка в конце работы 4 удаляет всё, включая Argo CD.

Контекст kubectl не меняем. Проверьте, что активен кластер стенда, создайте каталог файлов и функцию для namespace `lab-08-1`.

```bash
kubectl config current-context
mkdir -p ~/lab/k8s/08-1
k() { kubectl -n lab-08-1 "$@"; }
```

Первая команда печатает имя активного контекста: ожидается `kind-lab`. Вторая создаёт каталог файлов части, третья задаёт функцию `k`, которая подставляет `-n lab-08-1`. Функция живёт до конца сессии оболочки; если закроете терминал, задайте её заново. Каталог base из 07-3 должен лежать в `~/lab/k8s/07-3/orders-api/base`; если его нет, выполните шаг 1 работы 1 из 07-3.

### Лабораторная работа 1. Gitea и Argo CD

**Риски.** Работа ставит в кластер стенда Git-сервер и Argo CD с cluster-wide правами и сохраняет файлы на хосте.

- **Что меняется:** в кластере — namespace `lab-08-1` (Gitea и том на 1 ГиБ) и `argocd`, CRD `Application`, `AppProject`, `ApplicationSet`, ClusterRole и ClusterRoleBinding Argo CD; на хосте — каталог `~/lab/k8s/08-1`, файл с паролем Gitea и файл `~/.config/argocd/config` после входа.
- **Надолго ли:** до уборки в конце работы 4.
- **Безопасность:** Argo CD получает права почти на весь кластер стенда, а пароль Gitea лежит открытым текстом в файле с правами 600. Репозиторий в Gitea публичный, пароль в URL при push годится только для стенда; в работе используйте токен и credential helper.
- **Влияние на систему:** образы идут с quay.io, ghcr.io, public.ecr.aws и Docker Hub; ориентир плана — до 5 ГиБ RAM на стенд с Argo CD. Порт 8443 хоста занят port-forward до уборки.
- **Откат:** блок «Уборка» в конце работы 4.

**Цель.** Поднять Git-сервер Gitea и Argo CD v3.5.5 в кластере стенда, создать репозиторий с манифестами из 07-3 и войти в Argo CD командой `argocd`.

**Что понадобится.**

- Стенд 00-1 с Gateway `lab` и портом `127.0.0.1:8088`.
- Base из 07-3 и образы `orders-api:2.0` и `2.1` в реестре стенда.
- Установленные `git`, `curl`, `jq` и CLI `argocd` (карточка в §3).
- Около 30 минут, из них 5–10 минут на скачивание образов.

**Схема опыта.**

```
хост ──8088──► Gateway lab ──► Gitea (lab-08-1)  ◄── repo-server (argocd) читает репозиторий
хост ──8443──► port-forward ──► argocd-server    ──► application-controller сравнивает с кластером
```

Схема 6. Хост ходит в Gitea через Gateway, а Argo CD читает тот же репозиторий по внутреннему имени Service.

#### Шаг 1. Развернуть Gitea

Команда создаёт namespace и четыре объекта: том, Deployment, Service и маршрут. Установочный мастер Gitea отключён, поэтому сервер готов сразу.

```bash
kubectl create ns lab-08-1
k apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: gitea-data}
spec: {accessModes: [ReadWriteOnce], resources: {requests: {storage: 1Gi}}}
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: gitea}
spec:
  replicas: 1
  strategy: {type: Recreate}
  selector: {matchLabels: {app: gitea}}
  template:
    metadata: {labels: {app: gitea}}
    spec:
      containers:
      - name: gitea
        image: gitea/gitea:1.27.0-rootless
        env:
        - {name: GITEA__security__INSTALL_LOCK, value: "true"}
        - {name: GITEA__database__DB_TYPE, value: sqlite3}
        - {name: GITEA__server__ROOT_URL, value: "http://git.localhost:8088/"}
        - {name: GITEA__server__HTTP_PORT, value: "3000"}
        - {name: GITEA__service__DISABLE_REGISTRATION, value: "true"}
        ports: [{name: http, containerPort: 3000}]
        readinessProbe: {httpGet: {path: /api/healthz, port: http}, periodSeconds: 5}
        resources: {requests: {cpu: 50m, memory: 128Mi}, limits: {memory: 512Mi}}
        volumeMounts:
        - {name: data, mountPath: /var/lib/gitea}
        - {name: data, mountPath: /etc/gitea, subPath: conf}
      volumes: [{name: data, persistentVolumeClaim: {claimName: gitea-data}}]
---
apiVersion: v1
kind: Service
metadata: {name: gitea}
spec:
  selector: {app: gitea}
  ports: [{name: http, port: 3000, targetPort: http}]
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: gitea}
spec:
  parentRefs: [{name: lab, namespace: envoy-gateway-system}]
  hostnames: ["git.localhost"]
  rules: [{backendRefs: [{name: gitea, port: 3000}]}]
EOF
k rollout status deploy/gitea --timeout=300s
```

| Часть команды | Значение |
|---|---|
| `k apply -f -` | применить манифест из stdin в namespace `lab-08-1` |
| `strategy: Recreate` | остановить старый под до запуска нового: том с SQLite один |
| `INSTALL_LOCK=true` | пропустить мастер установки |
| `DB_TYPE=sqlite3` | хранить данные в файле на томе, без отдельной БД |
| `ROOT_URL` | адрес, по которому Gitea видна с хоста через Gateway |
| `subPath: conf` | отдельный подкаталог тома под конфигурацию |
| `hostnames: ["git.localhost"]` | маршрут для запросов с этим именем хоста |

Результат (ожидаемый):

```
namespace/lab-08-1 created
persistentvolumeclaim/gitea-data created
…
deployment "gitea" successfully rolled out
```

Разбор:

1. `created` — namespace и объекты Gitea созданы.
2. `successfully rolled out` — под прошёл проверку готовности `/api/healthz`.

#### Шаг 2. Создать администратора

Команда генерирует пароль, сохраняет его в файл с правами 600 и создаёт в Gitea пользователя `lab`. Пароль не попадает в историю команд, кроме единственного вызова `gitea admin`.

```bash
GP=$(head -c 18 /dev/urandom | base64 | tr -d '/+=')
printf 'GITEA_USER=lab\nGITEA_PASS=%s\n' "$GP" > ~/lab/k8s/08-1/gitea.env
chmod 600 ~/lab/k8s/08-1/gitea.env
k exec deploy/gitea -- gitea admin user create --admin --username lab \
  --password "$GP" --email lab@lab.local --must-change-password=false
unset GP
. ~/lab/k8s/08-1/gitea.env
curl -s http://git.localhost:8088/api/v1/version
```

| Часть команды | Значение |
|---|---|
| `head -c 18 /dev/urandom \| base64` | 18 случайных байт в тексте |
| `tr -d '/+='` | убрать символы, неудобные в URL |
| `chmod 600` | читать файл может только владелец |
| `gitea admin user create --admin` | создать пользователя с правами администратора |
| `. файл` | загрузить `GITEA_USER` и `GITEA_PASS` в текущую оболочку |
| `curl …/api/v1/version` | проверить доступ к Gitea с хоста через Gateway |

Результат:

```
New user 'lab' has been successfully created!
{"version":"1.27.0"}
```

Разбор:

1. Первая строка — пользователь создан.
2. `{"version":"1.27.0"}` — запрос с хоста дошёл до Gitea через Gateway: имя `git.localhost` и порт 8088 работают.

#### Шаг 3. Установить Argo CD v3.5.5

Команда ставит Argo CD из манифеста релиза. Флаги `--server-side` и `--force-conflicts` обязательны с версии 3.3: CRD слишком велик для аннотации client-side apply (01-3).

```bash
kubectl create ns argocd
kubectl apply -n argocd --server-side --force-conflicts -f \
  https://raw.githubusercontent.com/argoproj/argo-cd/v3.5.5/manifests/install.yaml
kubectl -n argocd rollout status deploy/argocd-server --timeout=600s
kubectl -n argocd rollout status deploy/argocd-repo-server --timeout=600s
kubectl -n argocd get pods
```

| Часть команды | Значение |
|---|---|
| `apply -n argocd` | применить в namespace `argocd` |
| `--server-side` | применять через server-side apply, без лимита аннотации |
| `--force-conflicts` | забрать поля у других менеджеров при конфликте |
| `v3.5.5` | закреплённая версия: не ниже 3.5.4 с исправлениями CVE |
| `rollout status … --timeout=600s` | ждать готовности до 10 минут |

Результат (ожидаемый вид; в прогоне автора всё, кроме Redis и Dex, поднялось за 54 с):

```
NAME                              READY   STATUS             …
argocd-application-controller-0   1/1     Running            …
argocd-redis-…                    0/1     ImagePullBackOff   …
argocd-repo-server-…              1/1     Running            …
argocd-server-…                   1/1     Running            …
```

Разбор:

1. Контроллер, repo-server и сервер поднялись за 54 с.
2. Redis остался в `ImagePullBackOff`: образ `public.ecr.aws/docker/library/redis:8.2.3-alpine` не скачался из-за лимита анонимных скачиваний (`toomanyrequests: Rate exceeded`).
3. Без Redis repo-server не рендерит, и приложения получают `ComparisonError … context deadline exceeded` (§5).
4. Dex в лабораторных не нужен: единый вход мы не настраиваем. Если ECR отвечает свободно, Redis поднимется сам, а имена подов у вас будут другими.

Если Redis застрял, возьмите тот же официальный образ с Docker Hub и загрузите его в узлы kind под ожидаемым именем.

```bash
docker pull redis:8.2.3-alpine
docker tag redis:8.2.3-alpine public.ecr.aws/docker/library/redis:8.2.3-alpine
kind load docker-image public.ecr.aws/docker/library/redis:8.2.3-alpine --name lab
kubectl -n argocd delete pod -l app.kubernetes.io/name=argocd-redis
kubectl -n argocd rollout status deploy/argocd-redis
```

| Часть команды | Значение |
|---|---|
| `docker pull redis:8.2.3-alpine` | скачать образ с Docker Hub на хост |
| `docker tag …` | дать образу имя, которое ждёт манифест |
| `kind load docker-image … --name lab` | скопировать образ в containerd каждого узла |
| `delete pod -l …argocd-redis` | пересоздать под, он найдёт образ на узле |

Результат: `deployment "argocd-redis" successfully rolled out`. Ответ о выкатке подтверждает, что Redis готов и repo-server сможет рендерить.

#### Шаг 4. Создать репозиторий с манифестами

Команда создаёт в Gitea репозиторий `orders-gitops` через API, кладёт в него base из 07-3 и overlay staging и отправляет первый коммит. Функция `gpush` фиксирует и отправляет изменение, а затем печатает короткий хэш коммита.

```bash
curl -s -u "$GITEA_USER:$GITEA_PASS" -H 'Content-Type: application/json' \
  -d '{"name":"orders-gitops","default_branch":"main","auto_init":false}' \
  http://git.localhost:8088/api/v1/user/repos | jq -r .full_name
R=~/lab/k8s/08-1/orders-gitops
rm -rf $R; mkdir -p $R/apps/orders-api/overlays/staging
cp -r ~/lab/k8s/07-3/orders-api/base $R/apps/orders-api/
O=$R/apps/orders-api/overlays/staging
cat > $O/kustomization.yaml <<'E'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: lab-08-1-staging
resources: [../../base, route.yaml]
configMapGenerator:
- name: orders-env
  behavior: merge
  literals: [FEATURE_DISCOUNT=on]
images:
- name: localhost:5001/orders-api
  newTag: "2.1"
E
cat > $O/route.yaml <<'E'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: orders-api}
spec:
  parentRefs: [{name: lab, namespace: envoy-gateway-system}]
  hostnames: ["staging.lab081.localhost"]
  rules: [{backendRefs: [{name: orders-api, port: 80}]}]
E
GIT_URL="http://$GITEA_USER:$GITEA_PASS@git.localhost:8088/lab/orders-gitops.git"
cd $R && git init -q -b main && git add -A && git commit -qm "orders-api: base + staging"
git push -q "$GIT_URL" main
gpush() { git -C $R add -A && git -C $R commit -qm "$1" && \
  git -C $R push -q "$GIT_URL" main && git -C $R rev-parse --short HEAD; }
```

| Часть команды | Значение |
|---|---|
| `POST /api/v1/user/repos` | создать репозиторий пользователя `lab`; по умолчанию публичный |
| `cp -r …/base` | взять base из 07-3 без изменений |
| `namespace: lab-08-1-staging` | overlay переносит объекты в namespace приложения |
| `hostnames: [staging.lab081.localhost]` | свой хост маршрута: имя из 07-3 к этому моменту может быть занято |
| `GIT_URL` | адрес с паролем: только для стенда, в `.git/config` он не попадает |
| `git push -q "$GIT_URL" main` | отправить ветку, не сохраняя адрес как remote |
| `gpush "сообщение"` | добавить все изменения, закоммитить, отправить, напечатать хэш |

Результат:

```
lab/orders-gitops
```

Разбор:

1. `lab/orders-gitops` — репозиторий создан, владелец `lab`, ветка `main`.
2. Остальные команды ничего не печатают при успехе: ошибку push покажет `git`.
3. Репозиторий публичный, поэтому Argo CD читает его без учётных данных; для приватного нужен Secret с токеном или команда `argocd repo add`.

Имена вида `*.localhost` ваш `git` и `curl` разрешают в `127.0.0.1` сами, поэтому записи в `/etc/hosts` не нужны.

#### Шаг 5. Войти в Argo CD

Команды открывают port-forward в фоне с pid-файлом и входят в Argo CD под администратором. Начальный пароль лежит в Secret, который создал сам Argo CD.

```bash
kubectl -n argocd port-forward svc/argocd-server 8443:443 >/dev/null 2>&1 &
echo $! > ~/lab/k8s/08-1/pf.pid
sleep 3
AP=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d)
argocd login 127.0.0.1:8443 --insecure --username admin --password "$AP"
unset AP
argocd version
```

| Часть команды | Значение |
|---|---|
| `port-forward svc/argocd-server 8443:443` | открыть порт 8443 хоста на сервер Argo CD |
| `echo $! > pf.pid` | сохранить pid порт-форварда, kubectl запущен без sudo |
| `get secret argocd-initial-admin-secret` | взять начальный пароль администратора |
| `login --insecure` | не проверять самоподписанный сертификат сервера |
| `argocd version` | показать версии CLI и сервера |

Результат (ожидаемый, формат зависит от версии):

```
'admin:login' logged in successfully
Context '127.0.0.1:8443' updated
argocd: v3.5.5+…
argocd-server: v3.5.5+…
```

Разбор:

1. Первые две строки — вход выполнен, токен записан в `~/.config/argocd/config`.
2. Две версии `v3.5.5` — CLI и сервер совпадают.
3. Пароль в командной строке виден в списке процессов на время вызова; на стенде это допустимо, в работе используйте токен учётной записи (§3).

**Итог.**

| Что узнали | Где видно |
|---|---|
| Argo CD 3.3+ ставится через server-side apply | шаг 3, флаги `--server-side --force-conflicts` |
| Без Redis repo-server не рендерит | шаг 3, `ImagePullBackOff` и `ComparisonError` |
| Git-сервер в кластере доступен и снаружи, и изнутри | шаги 2 и 4, Gateway и имя Service |
| CLI ходит к серверу, а не к Git | шаг 5, `login` и версии |

**Уборка.** Работа 1 оставляет установку для работ 2–4. Полная уборка Gitea, Argo CD и файлов — в конце работы 4; если останавливаетесь здесь, выполните её сейчас.

**Вопросы для самопроверки.**

1. Зачем Argo CD ставят с `--server-side --force-conflicts`?
2. Почему Application, созданный при остановленном Redis, получает ошибку сравнения?
3. Чем адрес репозитория для Argo CD отличается от адреса для хоста?

<details>
<summary>Ответ</summary>

1. CRD ApplicationSet слишком велик для аннотации `last-applied-configuration` в client-side apply (лимит 256 КиБ), а `--force-conflicts` разрешает перехватить поля при обновлении.
2. Repo-server кэширует отрендеренные манифесты в Redis и без него не может ответить контроллеру вовремя; сообщение — `context deadline exceeded`.
3. Хост ходит через Gateway по имени `git.localhost:8088`, а repo-server внутри кластера — по имени Service `gitea.lab-08-1.svc:3000`.

</details>

### Лабораторная работа 2. Application, self-heal и опрос Git

**Цель.** Создать Application для overlay staging, увидеть, как self-heal откатывает ручную правку за секунды, а новый коммит доезжает по опросу за минуты.

**Что понадобится.**

- Работа 1 выполнена: Gitea, Argo CD, репозиторий `orders-gitops`, функция `gpush`, вход через `argocd`.
- Около 20 минут, из них 3 минуты ожидания опроса Git.

**Схема опыта.**

```
шаг 3: kubectl scale ─► контроллер видит правку (watch) ─► self-heal за секунды
шаг 4: git push ──────► контроллер узнаёт по таймеру ───► sync через ~3 минуты
```

Схема 7. Ручную правку контроллер видит через watch сразу, а коммит — только при опросе Git.

#### Шаг 1. Создать namespace и Application

Команды создают namespace приложения, Secret с адресом базы (его нет в Git намеренно) и Application с автоматической синхронизацией.

```bash
kubectl create ns lab-08-1-staging
kubectl -n lab-08-1-staging create secret generic postgres \
  --from-literal=DATABASE_URL=postgresql://orders:orders-lab-pass@postgres.orders:5432/orders
kubectl apply -f - <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: {name: orders-staging, namespace: argocd}
spec:
  project: default
  source:
    repoURL: http://gitea.lab-08-1.svc:3000/lab/orders-gitops.git
    targetRevision: main
    path: apps/orders-api/overlays/staging
  destination: {server: https://kubernetes.default.svc, namespace: lab-08-1-staging}
  syncPolicy:
    automated: {prune: true, selfHeal: true}
EOF
until [ "$(kubectl -n argocd get app orders-staging \
  -o jsonpath='{.status.sync.status}/{.status.health.status}')" = "Synced/Healthy" ]
do sleep 3; done
kubectl -n argocd get app orders-staging \
  -o jsonpath='{range .status.resources[*]}{.kind}/{.name} {.status}{"\n"}{end}'
```

| Часть команды | Значение |
|---|---|
| `create secret generic postgres` | секрет базы вне Git: Deployment читает из него `DATABASE_URL` |
| `kind: Application` | объект Argo CD в namespace `argocd` |
| `path: …/overlays/staging` | каталог с `kustomization.yaml` |
| `automated: {prune, selfHeal}` | автоматический sync, чистка и самолечение |
| `until … do sleep 3; done` | ждать, пока приложение станет Synced и Healthy |
| `range .status.resources[*]` | вывести каждый объект приложения и его sync-статус |

Результат (в прогоне автора ревизия начиналась с `641d5184`):

```
ConfigMap/orders-env-… Synced
Service/orders-api Synced
Deployment/orders-api Synced
HTTPRoute/orders-api Synced
```

Разбор:

1. Цикл завершился: приложение стало `Synced/Healthy`.
2. В списке четыре объекта: ConfigMap генератора, Service, Deployment и HTTPRoute — столько в сборке overlay.
3. Secret `postgres` в списке нет: он создан вручную и Argo CD им не управляет.

#### Шаг 2. Проверить отслеживание и вспомогательную функцию

Команда читает аннотацию отслеживания Deployment, а функция `refresh` запросит у Argo CD немедленную проверку Git.

```bash
kubectl -n lab-08-1-staging get deploy orders-api \
  -o jsonpath='{.metadata.annotations.argocd\.argoproj\.io/tracking-id}{"\n"}'
refresh() { kubectl -n argocd annotate app orders-staging \
  argocd.argoproj.io/refresh=normal --overwrite; }
argocd app get orders-staging
```

| Часть команды | Значение |
|---|---|
| `annotations.argocd\.argoproj\.io/tracking-id` | аннотация владельца; точки в имени экранированы |
| `annotate app … refresh=normal` | запросить проверку Git без сброса кэша |
| `--overwrite` | заменить аннотацию, если она уже стоит |
| `argocd app get` | сводка приложения через API сервера |

Результат (ожидаемый, формат зависит от версии):

```
orders-staging:apps/Deployment:lab-08-1-staging/orders-api
Name:               argocd/orders-staging
Sync Status:        Synced to main (…)
Health Status:      Healthy
…
```

Разбор:

1. Аннотация `tracking-id` называет Application, группу, тип, namespace и имя объекта: по ней Argo CD узнаёт свои объекты при prune.
2. `Synced to main` — приложение совпадает с веткой `main` на указанном коммите.
3. Функция `refresh` понадобится в работах 3 и 4.

#### Шаг 3. Self-heal: ручная правка откатывается

Команда меняет число реплик руками и считает секунды, пока Argo CD вернёт значение из Git (в base `replicas: 1`).

```bash
kubectl -n lab-08-1-staging scale deploy orders-api --replicas=4
for i in $(seq 1 30); do
  r=$(kubectl -n lab-08-1-staging get deploy orders-api -o jsonpath='{.spec.replicas}')
  [ "$r" = 1 ] && break; sleep 1; done
echo "replicas=$r after ${i}s"
```

| Часть команды | Значение |
|---|---|
| `scale … --replicas=4` | ручная правка живого объекта |
| `seq 1 30` | проверять раз в секунду до 30 раз |
| `[ "$r" = 1 ] && break` | выйти, когда реплик снова одна |

Результат:

```
deployment.apps/orders-api scaled
replicas=1 after 2s
```

Разбор:

1. `scaled` — правка принята Kubernetes.
2. `replicas=1 after 2s` — контроллер увидел отличие через watch и вернул значение из Git за 2 с.
3. `kubectl rollout undo` при включённом self-heal ведёт себя так же: правка живого объекта откатывается к Git.

#### Шаг 4. Опрос Git: коммит доезжает не сразу

Команды меняют тег образа в Git на 2.0, отправляют коммит и считают секунды, пока контроллер сам заметит новую ревизию — без refresh.

```bash
O=~/lab/k8s/08-1/orders-gitops/apps/orders-api/overlays/staging
sed -i 's/newTag: "2.1"/newTag: "2.0"/' $O/kustomization.yaml
REV=$(gpush "staging: 2.0"); t0=$(date +%s)
until kubectl -n argocd get app orders-staging -o jsonpath='{.status.sync.revision}' \
  | grep -q "^$REV"; do sleep 5; done
echo "picked after $(( $(date +%s)-t0 ))s"
```

| Часть команды | Значение |
|---|---|
| `sed -i 's/newTag: "2.1"/…/'` | заменить тег в overlay |
| `REV=$(gpush …)` | закоммитить, отправить, взять хэш коммита |
| `status.sync.revision` | ревизия, с которой сравнивался кластер |
| `grep -q "^$REV"` | сравнить с хэшем отправленного коммита |
| `$(( $(date +%s)-t0 ))` | сколько секунд прошло с push |

Результат (в прогоне автора коммит `9ed2707`):

```
picked after 178s
```

Разбор:

1. 178 с — контроллер подхватил коммит по таймеру опроса (`timeout.reconciliation`, 180 с по умолчанию) без вмешательства.
2. Сравните с 2 с в шаге 3: ручную правку контроллер видит сразу, а Git опрашивает.
3. Чтобы ускорить, вызовите `refresh` сразу после push: в прогоне автора изменения подхватывались за 1–2 с. Постоянное решение — webhook (§3).

**Итог.**

| Что узнали | Где видно |
|---|---|
| Application связывает путь в Git с namespace кластера | шаг 1, `Synced/Healthy` |
| Argo CD помечает свои объекты аннотацией | шаг 2, `tracking-id` |
| Self-heal откатывает ручную правку за секунды | шаг 3, `after 2s` |
| Git опрашивается по таймеру, около 3 минут | шаг 4, `after 178s` |

**Уборка.** Работа продолжается в работе 3 на том же Application; общая уборка — в конце работы 4.

**Вопросы для самопроверки.**

1. Почему правку в кластере Argo CD заметил за 2 с, а коммит — за 178 с?
2. Что произошло бы при выключенном self-heal после шага 3?
3. Как ускорить доставку коммита, не меняя таймер?

<details>
<summary>Ответ</summary>

1. Кластер контроллер отслеживает через watch и реагирует сразу, а Git опрашивает раз в 180 с.
2. Application остался бы `OutOfSync` с четырьмя репликами, а Argo CD ничего не исправил бы: без self-heal sync срабатывает только на новый коммит.
3. Webhook из Gitea или refresh-аннотация на Application.

</details>

### Лабораторная работа 3. Prune и вечный OutOfSync

**Риски.** Работа создаёт в кластере стенда цикл масштабирования на 1–2 минуты.

- **Что меняется:** Deployment `orders-api` в `lab-08-1-staging` несколько раз меняет число реплик между 1 и 3, поды создаются и удаляются каждые 15–40 с.
- **Надолго ли:** на время опыта, около 2 минут; цикл прекращает шаг 4.
- **Безопасность и влияние:** привилегий не нужно; нагрузка небольшая, но на слабой машине заметна; другие namespace не затронуты.
- **Откат:** шаг 4 и работа 4 возвращают состояние через Git.

**Цель.** Увидеть prune при удалении объекта из Git, воспроизвести вечный OutOfSync из-за спора HPA и Argo CD за поле `replicas` и закрепить решение через `ignoreDifferences`.

**Что понадобится.**

- Работа 2 выполнена: Application `orders-staging` в состоянии `Synced`, функции `gpush` и `refresh`.
- Metrics-server из стенда 00-1 для HPA.
- Около 25 минут.

**Схема опыта.**

```
Git: replicas=1 ──► Argo CD (self-heal) ──┐
                                           ├─► spec.replicas: 1 ↔ 3 ↔ 1 ↔ 3 ...
HPA: minReplicas=3 ───────────────────────┘
```

Схема 8. Два владельца одного поля: каждый возвращает своё значение, Application то `Synced`, то `OutOfSync`.

#### Шаг 1. Prune: убрать объект из Git

Команда убирает `route.yaml` из списка ресурсов overlay, отправляет коммит и проверяет, что HTTPRoute удалён из кластера.

```bash
O=~/lab/k8s/08-1/orders-gitops/apps/orders-api/overlays/staging
sed -i 's|resources: \[../../base, route.yaml\]|resources: [../../base]|' \
  $O/kustomization.yaml
gpush "staging: drop route"; refresh
sleep 5; kubectl -n lab-08-1-staging get httproute
```

| Часть команды | Значение |
|---|---|
| `sed -i 's\|…\|…\|'` | убрать `route.yaml` из `resources` |
| `gpush "staging: drop route"` | отправить коммит и напечатать его хэш |
| `refresh` | запросить немедленную проверку Git |
| `get httproute` | проверить маршруты в namespace приложения |

Результат (коммит `3816a67`):

```
No resources found in lab-08-1-staging namespace.
```

Разбор:

1. Список пуст: объект исчез из Git, а `prune: true` удалил его из кластера; в прогоне автора это заняло 1 с после refresh.
2. Argo CD нашёл объект по аннотации `tracking-id` — вручную созданный HTTPRoute он бы не тронул.

#### Шаг 2. Добавить HPA и наблюдать пилу

Команда добавляет в overlay маршрут обратно и HPA с `minReplicas: 3`, а затем раз в 2 секунды печатает число реплик и sync-статус при каждом изменении. В base у Deployment `replicas: 1`.

```bash
cat > $O/hpa.yaml <<'E'
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata: {name: orders-api}
spec:
  scaleTargetRef: {apiVersion: apps/v1, kind: Deployment, name: orders-api}
  minReplicas: 3
  maxReplicas: 6
  metrics:
  - type: Resource
    resource: {name: cpu, target: {type: Utilization, averageUtilization: 70}}
E
sed -i 's|resources: \[../../base\]|resources: [../../base, route.yaml, hpa.yaml]|' \
  $O/kustomization.yaml
gpush "staging: route back + HPA min 3"; refresh; sleep 20
prev=""
for i in $(seq 1 45); do
  s="spec.replicas=$(kubectl -n lab-08-1-staging get deploy orders-api \
    -o jsonpath='{.spec.replicas}') app=$(kubectl -n argocd get app orders-staging \
    -o jsonpath='{.status.sync.status}')"
  [ "$s" != "$prev" ] && echo "t=+$((i*2))s $s" && prev=$s
  sleep 2
done
```

| Часть команды | Значение |
|---|---|
| `minReplicas: 3` | HPA не опустит число реплик ниже трёх |
| `resources: [..., hpa.yaml]` | добавить HPA в сборку overlay |
| `sleep 20` | дать Argo CD применить коммит |
| `[ "$s" != "$prev" ] && echo` | печатать только изменения значения |
| `seq 1 45`, `sleep 2` | наблюдать около 90 секунд |

Результат (время у вас будет другим):

```
t=+0s spec.replicas=1 app=Synced
t=+28s spec.replicas=3 app=OutOfSync
t=+30s spec.replicas=1 app=Synced
t=+43s spec.replicas=3 app=OutOfSync
t=+82s spec.replicas=1 app=Synced
t=+87s spec.replicas=3 app=OutOfSync
```

Разбор:

1. `replicas=3 app=OutOfSync` — HPA поднял число реплик до `minReplicas`, и кластер разошёлся с Git.
2. `replicas=1 app=Synced` — self-heal вернул значение из Git.
3. Цикл повторяется без единого коммита: у поля два владельца, поэтому поды создаются и убиваются каждые 15–40 с.
4. Это та же война за `replicas`, что у `kubectl apply` с HPA (05-4), но автоматическая и вечная.

#### Шаг 3. Прочитать события

Команда показывает причину и сообщение событий Deployment и HPA в хронологическом порядке.

```bash
kubectl -n lab-08-1-staging get events --sort-by=.lastTimestamp --no-headers \
  -o custom-columns=REASON:.reason,MESSAGE:.message | grep -E 'Scaling|Rescale'
```

| Часть команды | Значение |
|---|---|
| `--sort-by=.lastTimestamp` | упорядочить по времени последнего возникновения |
| `-o custom-columns=…` | вывести только причину и сообщение |
| `grep -E 'Scaling\|Rescale'` | оставить события масштабирования |

Результат (сокращено до значимых строк):

```
ScalingReplicaSet   Scaled down replica set orders-api-5f74d848b8 from 3 to 1
SuccessfulRescale   New size: 3; reason: Current number of replicas below Spec.MinReplicas
ScalingReplicaSet   Scaled up replica set orders-api-5f74d848b8 from 1 to 3
```

Разбор:

1. `SuccessfulRescale … below Spec.MinReplicas` — это HPA поднимает число реплик.
2. `Scaled down … from 3 to 1` — это возврат Deployment к значению из Git после sync.
3. Один ReplicaSet прыгает 1 → 3 → 1: новые ReplicaSet не создаются, меняется только число реплик.

#### Шаг 4. Исправить: ignoreDifferences

Команда говорит Argo CD игнорировать `/spec/replicas` у Deployment и не перезаписывать поле при sync. Затем тот же цикл наблюдения показывает стабильное состояние.

```bash
kubectl -n argocd patch app orders-staging --type=merge -p '{"spec":{
  "ignoreDifferences":[{"group":"apps","kind":"Deployment","jsonPointers":["/spec/replicas"]}],
  "syncPolicy":{"automated":{"prune":true,"selfHeal":true},
  "syncOptions":["RespectIgnoreDifferences=true"]}}}'
sleep 10
kubectl -n lab-08-1-staging get deploy orders-api \
  -o jsonpath='{.spec.replicas} {.status.readyReplicas}{"\n"}'
kubectl -n argocd get app orders-staging -o jsonpath='{.status.sync.status}{"\n"}'
```

| Часть команды | Значение |
|---|---|
| `patch app … --type=merge` | слить указанные поля в Application |
| `ignoreDifferences … jsonPointers` | не считать расхождение в `/spec/replicas` различием |
| `RespectIgnoreDifferences=true` | не перезаписывать игнорируемое поле и при sync |
| `.spec.replicas` и `.readyReplicas` | желаемое и готовое число реплик |

Результат (после патча 90 секунд наблюдения подряд показали `replicas=3 app=Synced`):

```
3 3
Synced
```

Разбор:

1. `3 3` — три реплики стабильны: поле ведёт HPA, а Argo CD его не трогает.
2. `Synced` — расхождение в игнорируемом поле не считается.
3. Без `RespectIgnoreDifferences=true` поле перезаписалось бы при любом sync, например ручном.
4. Лучший вариант — убрать `replicas` из манифеста, тогда владелец один. `ignoreDifferences` здесь живёт в объекте в кластере; в работе его хранят в Git вместе с Application (08-2).

**Итог.**

| Что узнали | Где видно |
|---|---|
| Prune удаляет объект, пропавший из Git | шаг 1, пустой список маршрутов |
| Два владельца поля дают вечный OutOfSync | шаг 2, пила 1 ↔ 3 |
| Причина видна в событиях и в `managedFields` | шаг 3, `SuccessfulRescale` |
| `ignoreDifferences` с `RespectIgnoreDifferences` останавливает пилу | шаг 4, `3 3` и `Synced` |

**Уборка.** Работа продолжается в работе 4; общая уборка — в конце работы 4.

**Вопросы для самопроверки.**

1. Почему пила возникает без единого коммита?
2. Зачем нужен `RespectIgnoreDifferences=true`?
3. Какое решение лучше: убрать `replicas` из Git или игнорировать поле?

<details>
<summary>Ответ</summary>

1. HPA меняет реплики по своему правилу, а self-heal возвращает значение из Git: оба реагируют на состояние кластера, а не на коммиты.
2. `ignoreDifferences` скрывает различие в статусе, но при sync Argo CD всё равно применил бы значение из Git; параметр запрещает перезапись.
3. Убрать из Git: владелец поля остаётся один, и обход не нужен. Игнорирование — вынужденная мера, когда манифест генерирует чужой чарт.

</details>

### Лабораторная работа 4. Откат через Git и уборка

**Цель.** Откатить релиз коммитом `git revert`, убедиться, что откат из CLI при включённом auto-sync не работает, и полностью убрать Gitea, Argo CD и файлы работ.

**Что понадобится.**

- Работа 3 выполнена: в Git лежит коммит с HPA и маршрутом.
- Около 20 минут, из них 5 минут на уборку.

**Схема опыта.**

```
история: 3816a67 drop route ─► 0bf8387 route back + HPA ─► 25bda53 Revert 0bf8387
                                                    git revert + push
```

Схема 9. Откат в GitOps — новый коммит, который отменяет предыдущий; история остаётся.

#### Шаг 1. Откатить коммит

Команды создают коммит-отмену последнего коммита (с HPA и маршрутом), отправляют его и проверяют, что HPA исчез.

```bash
R=~/lab/k8s/08-1/orders-gitops
git -C $R revert --no-edit HEAD
git -C $R push -q "$GIT_URL" main
git -C $R log --oneline -3
refresh; sleep 5
kubectl -n lab-08-1-staging get hpa,httproute
kubectl -n argocd get app orders-staging \
  -o jsonpath='{.status.sync.status}/{.status.health.status}{"\n"}'
```

| Часть команды | Значение |
|---|---|
| `git revert --no-edit HEAD` | создать коммит, отменяющий последний |
| `git push -q "$GIT_URL" main` | отправить откат в Gitea |
| `log --oneline -3` | показать три последних коммита |
| `get hpa,httproute` | проверить, что объекты исчезли |

Результат:

```
25bda53 Revert "staging: route back + HPA min 3"
0bf8387 staging: route back + HPA min 3
3816a67 staging: drop route
No resources found in lab-08-1-staging namespace.
Synced/Healthy
```

Разбор:

1. В истории три коммита: откат не стёр прошлое, а добавил новый коммит.
2. Пустой вывод — HPA и маршрут удалены prune через 1 с после refresh.
3. `Synced/Healthy` — приложение совпадает с Git и работает.
4. В боевой установке такой откат идёт через ускоренный merge request или break-glass (курс `cicd`), но всегда через Git.

#### Шаг 2. Откат из CLI при включённом auto-sync

Команда пробует вернуть ревизию из истории Argo CD. Для этого ей нужен выключенный auto-sync.

```bash
argocd app history orders-staging
argocd app rollback orders-staging 1
```

| Часть команды | Значение |
|---|---|
| `app history` | список применённых ревизий с номерами |
| `app rollback … 1` | применить ревизию номер 1 из истории |

Результат (ожидаемый, текст зависит от версии): таблица с номерами ревизий и отказ второй команды. В сообщении сказано, что откат нельзя запустить при включённой автоматической синхронизации.

Разбор:

1. История показывает ревизии, которые применял Argo CD, но состояние Git остаётся главным.
2. Откат из CLI — временная мера: после выключения auto-sync и возврата ревизии следующий sync вернул бы то, что записано в Git.
3. Поэтому процедура инцидента одна: revert в Git, refresh, проверка статуса.

#### Шаг 3. Убрать всё

Команды останавливают порт-форвард, удаляют Application и namespace приложения, Argo CD вместе с CRD, Gitea с томом и файлы работ.

```bash
argocd logout 127.0.0.1:8443
kill "$(cat ~/lab/k8s/08-1/pf.pid)" && rm ~/lab/k8s/08-1/pf.pid
kubectl -n argocd delete app orders-staging
kubectl delete ns lab-08-1-staging
kubectl delete -n argocd -f \
  https://raw.githubusercontent.com/argoproj/argo-cd/v3.5.5/manifests/install.yaml
kubectl delete ns argocd
kubectl delete ns lab-08-1
rm -rf ~/lab/k8s/08-1
unset -f k gpush refresh; unset GIT_URL GITEA_USER GITEA_PASS R O
kubectl get ns,crd | grep -E 'argo|lab-08-1' || echo clean
```

| Часть команды | Значение |
|---|---|
| `argocd logout` | убрать токен из `~/.config/argocd/config` |
| `kill "$(cat pf.pid)"` | остановить порт-форвард по сохранённому pid |
| `delete app orders-staging` | удалить Application; объекты приложения остаются (нет finalizer) |
| `delete ns lab-08-1-staging` | удалить объекты приложения вместе с namespace |
| `delete -n argocd -f install.yaml` | удалить всё, что создал манифест установки, включая CRD |
| `delete ns lab-08-1` | удалить Gitea и том с репозиторием |
| `unset -f k gpush refresh` | убрать функции из оболочки |
| `grep … \|\| echo clean` | проверить, что следов не осталось |

Результат:

```
clean
```

Разбор:

1. Слово `clean` значит, что namespace и CRD Argo CD удалены.
2. У `orders-staging` не было finalizer, поэтому удаление Application не убрало Deployment и Service: в прогоне автора они остались, и namespace пришлось удалить явно.
3. Если шаг 3 работы 1 использовал образ Redis с Docker Hub, на узлах kind остался образ с именем ECR; удалять его необязательно. С хоста его убирает `docker rmi public.ecr.aws/docker/library/redis:8.2.3-alpine redis:8.2.3-alpine`.

**Итог.**

| Что узнали | Где видно |
|---|---|
| Откат в GitOps — новый коммит | шаг 1, `Revert` в истории |
| Откат из CLI не работает при auto-sync | шаг 2, отказ `rollback` |
| Удаление Application не удаляет объекты без finalizer | шаг 3, явное удаление namespace |

**Уборка.** Шаг 3 уже выполнил её: удалены Application, Argo CD, Gitea, namespace и файлы части. Для 08-2 установку придётся повторить по шагам работы 1.

**Вопросы для самопроверки.**

1. Почему откат делают коммитом, а не командой `kubectl rollout undo`?
2. Что произойдёт с объектами приложения, если удалить Application без finalizer?
3. Чем `git revert` лучше `git reset` для отката в общей ветке?

<details>
<summary>Ответ</summary>

1. При self-heal `rollout undo` откатывается к Git за секунды, а коммит меняет источник истины, и откат остаётся.
2. Объекты остаются в кластере без управления Argo CD; убрать их нужно явно или заранее поставить finalizer `resources-finalizer.argocd.argoproj.io`.
3. Revert добавляет коммит и сохраняет историю, а reset переписывает ветку и ломает клоны и сам Argo CD, который отслеживает ревизии.

</details>

---

## → Дальше

Argo CD уже умеет вести одно приложение из Git: он сравнивает, лечит дрейф и откатывает коммитом. Но на платформе приложений десятки, окружений несколько, а секреты нельзя класть в Git открытым текстом. Следующая часть, 08-2, строит на этом механизме app-of-apps и ApplicationSet, структуру репозиториев, промоушен коммитом дайджеста, секреты в GitOps и сравнение с Flux. Она идёт следом, потому что все её приёмы опираются на политику синхронизации, отслеживание объектов и правила отката, разобранные здесь.
