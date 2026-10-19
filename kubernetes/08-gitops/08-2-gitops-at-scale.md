# 08-2. GitOps в масштабе

> Модуль 08 «GitOps» · часть 2 из 2 · ~1,5 ч чтения + ~1,5 ч лабы (с повторной установкой Gitea и Argo CD) · Нужно: шаги 1–4 работы 1 из 08-1 (Gitea 1.27.0, Argo CD 3.5.5, репозиторий `~/lab/k8s/08-1/orders-gitops`), overlay prod из 07-3, образ `orders-api:2.1` в реестре стенда (03-4) · Опирается на: 08-1 (Application, sync, selfHeal, prune, `ignoreDifferences`), 07-3 (overlays и `digest`), 01-3 (finalizer)

## Где мы на карте

В 08-1 один Application следил за одним каталогом. Эта часть отвечает на вопрос, что меняется, когда сервисов десятки, окружений несколько, а кластеров больше одного. Мы разберём, как описать конфигурацию в Git и как перенести версию из staging в prod. Отдельно посмотрим, где хранить секреты, если в Git им не место.

Часть опирается на 08-1: Application, sync и health, `selfHeal`, `prune`, `ignoreDifferences`. Дальше курс переходит от доставки приложений к расширению самого API. Часть 09-1 разбирает CRD и операторы, а ApplicationSet и Application из этой части тоже относятся к CRD.

```
 Git: config-репозиторий
   argocd/                     ← какие приложения существуют
   apps/<сервис>/base          ← общее
   apps/<сервис>/overlays/<env>← различия окружений
        │
        ▼
 root (Application) ──► ApplicationSet ──► Application staging, Application prod ──► ресурсы
        ▲
        └── CI сервиса пишет в Git новый дайджест образа (промоушен)
```

Схема 1. Что хранит Git и кто на что ссылается: корневое Application читает каталог `argocd/`, ApplicationSet создаёт по Application на каждое окружение.

---

## 1. Какую задачу решает GitOps в масштабе

Один Application создают руками за минуту, а сотню так создавать нельзя. Здесь собраны проблемы, которые появляются с ростом, и приёмы, которые их закрывают.

### Что ломается при росте

Рост добавляет три измерения: сервисы, окружения и кластеры. Для 30 сервисов в 3 окружениях получается 90 Application, и каждое нужно создать, изменить и удалить, не открывая UI. Ручной `kubectl apply` для самих Application возвращает все проблемы, от которых избавлял GitOps: нет ревью, нет истории, нельзя воспроизвести.

Вторая проблема — версии. Образ собирают один раз, а в окружениях он должен появляться по очереди, и каждое появление должно оставлять след в Git. Третья — секреты: Git остаётся единственным источником истины, но хранить в нём пароли нельзя.

### Приёмы, которые это решают

Каждая проблема закрывается своим приёмом, и дальше они разобраны по порядку.

- **Структура репозиториев** — где лежат код и конфигурация и чем отличаются окружения (§2).
- **Генерация Application** — один шаблон вместо сотни ручных объектов (§2).
- **Промоушен** — перенос проверенной версии между окружениями коммитом (§3).
- **Секреты вне открытого текста** — шифрование или ссылки на внешнее хранилище (§3).
- **Мультикластерность** — одно описание, много адресатов (§2).

### Чем отличается от 08-1

В 08-1 механизм один: Application сравнивает Git и кластер. Здесь тот же механизм работает на многих объектах сразу, поэтому ошибка в одном файле задевает все окружения, а не одно. Такую цену платят за автоматизацию, и она определяет всё, что идёт дальше: защиту от массового удаления, ревью каталога `argocd/` и промоушен по дайджесту.

---

## 2. Как устроена конфигурация в Git

Конфигурацию масштабного GitOps описывают три слоя: структура репозиториев, объекты Argo CD в Git и генераторы, которые создают Application по шаблону.

### Структура репозиториев

**Config-репозиторий** (config repository) — репозиторий, в котором лежат только манифесты и версии, без кода сервиса. Рядом с ним стоит **app-репозиторий** (application repository): код, Dockerfile и тесты одного сервиса. CI сервиса собирает образ из app-репозитория и записывает его версию в config-репозиторий.

```
app-репо сервиса                         config-репо
  src/, Dockerfile                         apps/orders-api/base/
  CI: сборка, тесты, push образа  ───►     apps/orders-api/overlays/staging/
       коммит дайджеста                    apps/orders-api/overlays/prod/
                                           argocd/orders-appset.yaml
```

Схема 2. Две стороны разделены: CI пишет в config-репозиторий, а Argo CD читает только его.

Разделение нужно по двум причинам. Коммит с новой версией не запускает сборку заново, потому что лежит в другом репозитории. А права на prod-каталог выдают отдельно от прав на код.

Схем размещения четыре, и у каждой своя область применения.

- **Monorepo конфигурации** — манифесты всех сервисов в одном репозитории, как на стенде. Подходит одной платформенной команде и десяткам сервисов.
- **Репозиторий на сервис** — манифесты рядом с кодом. Команды независимы, но промоушен требует запроса на слияние в каждом репозитории.
- **App- и config-репозитории** — самый частый вариант в средних компаниях: код отдельно, версии и манифесты отдельно.
- **Окружения ветками** — ветки `staging` и `prod`. Это анти-рецепт: слияние между ветками тащит лишние изменения, а истории расходятся.

Окружения различают каталогами: overlay Kustomize (07-3) или файл значений Helm. Каталог можно защитить правилом владельцев (CODEOWNERS) и сравнить с соседним командой `diff`, а ветку так не сравнить.

### Корневое Application: app-of-apps

**App-of-apps** — приём, при котором Application указывает на каталог, где лежат другие объекты Argo CD. Корневое Application создают вручную один раз, остальное приходит из Git.

```
kubectl apply (один раз)
        │
        ▼
 Application root ── path: argocd/ ──► ApplicationSet orders-api
                                       Application platform-tools
                                       AppProject team-a
```

Схема 3. Один объект создан руками, всё остальное — из каталога `argocd/`.

Выигрыш в том, что настройки самих приложений, включая `ignoreDifferences` из 08-1, лежат в Git и проходят ревью. Новый кластер поднимается применением одного корневого объекта. Проблема классического приёма — каждое дочернее Application пишут руками, и для однотипных приложений это превращается в копирование. Эту работу берёт ApplicationSet.

### ApplicationSet и генераторы

**ApplicationSet** — объект Argo CD, который состоит из шаблона Application и **генератора** (generator): источника параметров. Контроллер ApplicationSet запускает генератор, подставляет каждый набор параметров в шаблон и создаёт по одному Application на набор.

```
 генератор ──► набор параметров ──► шаблон Application ──► Application
 (каталоги,      {path.basename:      name: orders-{{...}}
  список,         staging}            destination: lab-08-2-{{...}}
  кластеры)      {path.basename: prod}
```

Схема 4. Из двух каталогов генератор получает два набора параметров, а шаблон превращает их в два Application.

Генераторов несколько, и в таблице собраны основные.

| Генератор | Откуда параметры | Типичный случай |
|---|---|---|
| `list` | список в самом объекте | несколько окружений с явными значениями |
| `git`, каталоги | подкаталоги репозитория | папка равна окружению |
| `git`, файлы | JSON и YAML файлы в репозитории | параметры лежат в файле |
| `clusters` | кластеры, зарегистрированные в Argo CD | одно приложение во все кластеры |
| `matrix`, `merge` | комбинация других генераторов | сервисы на кластеры |
| `pullRequest` | открытые запросы на слияние | preview-окружение на запрос |

Шаблон ссылается на параметры в фигурных скобках. Мы включаем `goTemplate: true`, тогда параметры читаются через точку, например `.path.basename`. Без этой настройки работает простая подстановка с другим синтаксисом, и перепутать их легко.

Главное свойство ApplicationSet: он владеет созданными Application через ссылку-владельца (ownerReference, 01-3). Исчез набор параметров — исчезло и Application. Если Application с нужным именем уже есть и никому не принадлежит, контроллер забирает его себе и переписывает по шаблону. Эта связь делает ApplicationSet удобным и опасным одновременно (§5).

Генератор каталогов опрашивает Git сам, по умолчанию раз в 3 минуты. Интервал меняют полем `requeueAfterSeconds` в генераторе или переменной `ARGOCD_APPLICATIONSET_CONTROLLER_REQUEUE_AFTER` для всего контроллера. Аннотация `argocd.argoproj.io/application-set-refresh=true` запускает генераторы сразу, ею мы пользуемся в лабораторных.

### Генератор pullRequest

**Preview-окружение** (preview environment) — временная копия приложения, которую поднимают под каждый открытый запрос на слияние (pull request) и убирают после закрытия. Генератор `pullRequest` опрашивает Git-сервер и выдаёт параметр на каждый открытый запрос.

```
 PR #12 открыт  ──┐
 PR #15 открыт  ──┼─► генератор pullRequest ─► Application orders-pr-12, orders-pr-15
 PR #12 закрыт  ──┘                            Application orders-pr-12 удалён
```

Схема 5. Жизнь preview-окружения привязана к запросу: открыт — есть Application, закрыт — генератор перестал его выдавать.

Генератор поддерживает Gitea, GitHub, GitLab, Bitbucket и Azure DevOps. Для Gitea обязательны поля `owner`, `repo` и `api`, а токен задаётся ссылкой `tokenRef` на Secret. Шаблон получает параметры `number`, `branch`, `branch_slug` (ветка в виде имени по RFC 1123, не длиннее 50 знаков) и `head_sha`. Метки запроса доступны как `labels` только при `goTemplate: true`.

Опрашивает Git-сервер генератор раз в `requeueAfterSeconds`, по умолчанию раз в 1800 с, то есть раз в 30 минут. Ускоряет доставку webhook, но по документации Argo CD webhook ApplicationSet умеет события GitHub и GitLab, а Gitea в списке нет. На стенде мы этот генератор не запускаем: он описан для понимания, а preview-окружения требуют отдельного токена и решения, куда их публиковать.

### Многокластерность

**Кластерный генератор** (cluster generator, ключ `clusters`) выдаёт набор параметров на каждый кластер, который зарегистрирован в Argo CD. Регистрация — это Secret с меткой `argocd.argoproj.io/secret-type: cluster` в namespace `argocd`.

```
 Secret cluster-prod-eu  (метка env=prod) ┐
 Secret cluster-prod-us  (метка env=prod) ┼─► clusters{selector env=prod}
 Secret cluster-dev      (метка env=dev)  ┘        │
                                                   ▼
                              Application <кластер>-orders, destination.server = адрес кластера
```

Схема 6. Селектор по меткам выбирает кластеры, а `server` каждого кластера попадает в `destination` шаблона.

Шаблон получает параметры `name`, `nameNormalized`, `server`, `project` и метки кластера `metadata.labels.<ключ>`. Без селектора генератор выбирает все кластеры, включая локальный, где работает Argo CD. У локального кластера по умолчанию нет Secret, поэтому селектор по метке его не выбирает; чтобы включить его, Secret для него создают явно. Генераторы комбинируют: `matrix` берёт список сервисов и список кластеров и создаёт Application на каждую пару.

Многокластерная схема меняет и модель доступа. Один Argo CD хранит учётные данные всех кластеров, значит, его компрометация открывает все кластеры. Альтернатива — отдельный Argo CD в каждом кластере (так обычно работает Flux, §3).

---

## 3. Как управлять версиями и секретами

Управление масштабом сводится к трём действиям: перенести версию между окружениями, связать это с CI и спрятать секреты. Затем сравним Argo CD с Flux.

### Промоушен по окружениям

**Промоушен** (promotion) — перенос проверенной версии из одного окружения в другое. В GitOps это коммит: в overlay следующего окружения записывается тот же **дайджест** (digest) образа, что проверен в предыдущем. Дайджест — хеш содержимого образа вида `sha256:…`, он однозначно определяет образ, в отличие от тега, который можно переписать (07-3).

```
 CI: сборка ─► push образа ─► дайджест sha256:…
        │
        ▼
 коммит в overlays/staging ─► Argo CD ─► rollout в staging ─► проверки
        │
        ▼  запрос на слияние с тем же дайджестом
 overlays/prod (ревью владельцев) ─► Argo CD ─► rollout в prod
```

Схема 7. Версия идёт по цепочке коммитов: каждый шаг оставляет запись в Git, а дайджест остаётся одним и тем же.

Тот же дайджест нужен затем, что в prod должен попасть именно проверенный образ, а не новая сборка из того же исходного кода. История промоушенов читается командой `git log` по каталогу prod: кто, когда и какой дайджест выкатил. Доступ CI к config-репозиторию выдают отдельным ключом или токеном, и только на запись в нужные каталоги. Кластер CI при этом не нужен вообще, в этом и состоит pull-модель.

### Связь с CI: коммит или автоматика

Записывать дайджест можно тремя способами. Первый: шаг пайплайна CI делает коммит в config-репозиторий (курс `cicd`). Он прост, прозрачен и годится большинству команд.

Второй способ — **Argo CD Image Updater**, отдельный контроллер, который следит за реестром и при появлении нового образа обновляет приложение. Он умеет два вида записи: в параметры Application в кластере или коммитом в Git. Первый вид обходит Git и ломает принцип «Git — источник истины», поэтому для prod выбирают запись в Git. В линии 1.x (v1.3.1 на 08.10.2026) правила слежения задают объектом собственного типа `ImageUpdater`, а не аннотациями на Application, как в старых версиях.

Третий способ — **Kargo**, платформа промоушена, где каждое понятие описано объектом Kubernetes. Warehouse следит за реестрами и репозиториями и упаковывает новые версии в Freight — набор конкретных ревизий образов и манифестов. Stage — цель промоушена, обычно окружение, а Promotion переносит Freight в следующую Stage; применяет изменение по-прежнему Argo CD. Kargo подходит, когда цепочка длинная, а правила переноса сложные. Для одного сервиса и двух окружений хватает коммита из CI.

Есть и смежная идея: **Source Hydrator** в Argo CD рендерит манифесты и записывает готовый результат в отдельную ветку. Своё состояние он хранит в git note с версии 3.3. Так в Git виден итоговый YAML, а не только исходные шаблоны. Приём молодой, и в курсе мы его не разбираем.

### Секреты в GitOps

Секреты хранить в Git открытым текстом нельзя, и base64 не шифрование: значение остаётся в истории навсегда (04-1). Четыре подхода решают задачу по-разному; общие принципы работы с секретами и ключами разобраны в курсе security.

| Подход | Что лежит в Git | Кто расшифровывает |
|---|---|---|
| External Secrets Operator | ссылка на значение во внешнем хранилище | оператор в кластере |
| SOPS | файл с зашифрованными значениями | плагин Argo CD или Flux |
| Sealed Secrets | SealedSecret, зашифрованный публичным ключом | контроллер в кластере |
| секрет вне GitOps | ничего | человек или скрипт |

```
 ESO:            Git: ExternalSecret ──► оператор ──► Vault / облако ──► Secret в кластере
 SOPS:           Git: файл, значения зашифрованы ──► плагин или Flux + ключ age/KMS ──► Secret
 Sealed Secrets: Git: SealedSecret ──► контроллер + закрытый ключ кластера ──► Secret
```

Схема 8. Три пути от Git к Secret: везде в Git лежит то, что без ключа или хранилища бесполезно, а обычный Secret появляется только в кластере.

**External Secrets Operator** (ESO) читает значения из внешнего хранилища, например Vault или облачного менеджера секретов, и создаёт из них обычный Secret. Работают два объекта. **SecretStore** описывает, как подключиться к хранилищу и с какими учётными данными; ClusterSecretStore делает то же для всего кластера. **ExternalSecret** говорит, какой ключ хранилища прочитать и в какой Secret его положить.

В Git лежат только эти два объекта, и в них нет значений. Оператор перечитывает хранилище раз в `refreshInterval`, поэтому ротация делается в хранилище, а Secret догоняет её сам; значение 0 означает «создать один раз и не обновлять». Минус: нужно само хранилище, а созданный Secret всё равно лежит в etcd (04-1). Актуальная линия — v2.x (v2.13.0 на 16.10.2026), версия API — `external-secrets.io/v1`; `v1beta1` ESO перестал обслуживать с v0.17.0.

**SOPS** (Secrets OPerationS) шифрует значения в YAML-файле и оставляет ключи видимыми, поэтому в ревью видно, какой параметр изменился. Каждый файл шифруется своим ключом данных, а этот ключ, в свою очередь, зашифрован одним или несколькими мастер-ключами. Мастер-ключ берут из облачного KMS или из **age** — простой утилиты шифрования с короткими ключами. Файл `.sops.yaml` в корне репозитория задаёт правила: какие пути каким ключом шифровать и какие поля трогать.

Flux расшифровывает SOPS сам, а Argo CD нужен плагин, например KSOPS или helm-secrets. Закрытый мастер-ключ приходится хранить в кластере. Смена мастер-ключа означает перешифровку ключей данных во всех файлах, а утечка значения — смену самого секрета. Актуальная версия — v3.13.3 (июль 2026).

**Sealed Secrets** шифрует Secret открытым ключом контроллера, который работает в кластере. Утилита `kubeseal` создаёт `SealedSecret`, и расшифровать его может только контроллер этого кластера. По умолчанию шифр привязан к имени и namespace (режим strict): переименовать SealedSecret или перенести в другой namespace нельзя. Режимы `namespace-wide` и `cluster-wide` ослабляют эту привязку.

Это просто и не требует внешних систем. Платой становится привязка к кластеру: без резервной копии закрытого ключа восстановить секреты в новом кластере нельзя. Контроллер создаёт новый ключ шифрования каждые 30 дней (флаг `--key-renew-period`, 0 выключает), старые ключи не удаляет. Готовые SealedSecret при этом не перешифровываются: это делают вручную командой `kubeseal --re-encrypt`. Смена ключа не заменяет ротацию самих паролей. Актуальная версия контроллера — v0.40.0 (сентябрь 2026).

Выбор такой: есть Vault или облачный менеджер — ESO; нет внешнего хранилища — SOPS с age или KMS, либо Sealed Secrets для одного кластера. Во всех вариантах Argo CD маскирует значения Secret в diff, но плагины рендеринга видят их открытыми. Поэтому права на `argocd-repo-server` и его логи защищают так же строго, как сами секреты.

### Argo CD и Flux

**Flux** — второй GitOps-инструмент уровня CNCF graduated, набор контроллеров вместо одного центрального. Источник (GitRepository или OCIRepository) отделён от применения (Kustomization и HelmRelease). Сравним по основным свойствам.

| Свойство | Argo CD | Flux |
|---|---|---|
| Модель | Application «что куда», центральный контроллер | набор контроллеров, источник и применение раздельно |
| Интерфейс | свой UI, наглядный diff | своего UI нет, есть сторонние |
| Много кластеров | один Argo CD управляет многими | обычно Flux в каждом кластере |
| Helm | рендерит сам, список релизов Helm пуст (07-1) | HelmRelease создаёт настоящий релиз Helm |
| SOPS | через плагины | встроен |
| Генерация приложений | ApplicationSet | Kustomization с подстановками, ResourceSet |

Из свежих изменений Flux: версия 2.7 (сентябрь 2025) перевела API автоматизации образов в GA и добавила ExternalArtifact и ArtifactGenerator. Версия 2.8 (февраль 2026) поддержала Helm 4, актуальная линия — 2.9 (2.9.6 на 01.10.2026). Ближайший аналог ApplicationSet — ResourceSet: он генерирует объекты Flux по входным наборам, но входит не в сам Flux, а во Flux Operator компании ControlPlane. Flux выбирают, когда нужны отдельные «кирпичики», нативный SOPS и релизы Helm. Argo CD выбирают, когда важны UI и централизованное управление кластерами.

---

## 4. Как увидеть состояние

Состояние GitOps в масштабе читается на трёх уровнях: ApplicationSet, порождённые Application и сам Git.

### ApplicationSet и его условия

Команда `kubectl -n argocd get applicationset` показывает объекты, а их условия лежат в `status.conditions`. Нас интересуют три условия: `ErrorOccurred` (генератор, шаблон или запись Application дали ошибку), `ParametersGenerated` (параметры получены) и `ResourcesUpToDate` (Application созданы и обновлены). Условие `RolloutProgressing` появляется только при поэтапной синхронизации (стратегия RollingSync), которую мы не включаем. Сначала смотрят `ErrorOccurred`: опечатка в шаблоне или недоступный репозиторий видны именно там. Журнал контроллера: `kubectl -n argocd logs deploy/argocd-applicationset-controller`.

### Что сгенерируется до слияния

Команда `argocd appset generate <файл>` отправляет ApplicationSet из файла на сервер Argo CD и печатает Application, которые получились бы из него, ничего не создавая. Генераторы при этом работают на сервере, поэтому нужен вход через `argocd login` (08-1) или флаг `--core`. Ею проверяют изменение генератора в запросе на слияние: какие Application появятся и какие исчезнут. Это единственная защита от массового удаления, которая срабатывает до слияния, а не после.

### Git как журнал

Кто и что выкатил в prod, читается из `git log` каталога prod. Application показывает, какая ревизия применена: `kubectl -n argocd get app -o custom-columns=NAME:.metadata.name,REV:.status.sync.revision`. Сравнение ревизии Application с `git rev-parse` ветки отвечает на вопрос, доехал ли коммит.

---

## 5. Что ломается и как найти причину

Поломки масштаба связаны с тем, что один объект управляет многими. Ошибка в одном месте задевает все окружения сразу.

### Удаление каталога удаляет окружение

Если каталог пропал из Git, генератор перестаёт выдавать его параметры, и ApplicationSet удаляет Application. Сгенерированному Application по умолчанию ставится finalizer `resources-finalizer.argocd.argoproj.io` (01-3), поэтому удаление каскадное: пропадают Deployment, Service, ConfigMap и HTTPRoute. Опечатка в пути генератора, перенос каталогов или принудительная отправка не той ветки действуют так же. PVC из `volumeClaimTemplates` StatefulSet не принадлежат Application и остаются, поэтому данные целы, но доступность потеряна.

```
 коммит без каталога ─► генератор: набор параметров пропал
        ─► ApplicationSet: Application лишнее ─► delete Application
        ─► finalizer: Argo CD удаляет ресурсы ─► finalizer снят ─► Application исчез
```

Схема 8a. Цепочка удаления: каждое звено работает правильно, а итог — потерянное окружение.

Причину находят по следам этой цепочки. Контроллер ApplicationSet пишет событие `Deleted` на ApplicationSet и строку в свой журнал с именем удалённого Application. Сам Application в этот момент уже исчез, поэтому событие ищут на ApplicationSet: `kubectl -n argocd get events --field-selector involvedObject.kind=ApplicationSet`. Затем `git log` по каталогу `argocd/` и по маске генератора показывает коммит, после которого набор параметров изменился.

Защита состоит из слоёв.

- **`preserveResourcesOnDeletion: true`** — Application удаляется без каскада, ресурсы остаются.
- **`applicationsSync: create-update`** — ApplicationSet создаёт и обновляет Application, но не удаляет. Значения: `create-only`, `create-update`, `create-delete`, `sync` (по умолчанию).
- **Защита ветки** — запрет принудительной отправки в `main` и обязательное ревью каталога `argocd/`.
- **Проверка до слияния** — `argocd appset generate` на ветке запроса.
- **`prune: false`** — у Application с данными, чтобы удаление из Git не удаляло объекты.

Оговорка из документации: `create-only` и `create-update` не защищают от удаления самого ApplicationSet, потому что тогда Application удаляет владелец-ссылка. От этого помогает finalizer `resources-finalizer.argocd.argoproj.io` на самом ApplicationSet и каскад в фоне.

### Корневое Application и порядок удаления

Корневое Application без finalizer при удалении оставляет все созданные им объекты, в том числе ApplicationSet. Это удобно для уборки: сначала удаляют корневое, потом ApplicationSet. Обратный порядок не работает, потому что корневое Application с `selfHeal` пересоздаёт удалённый ApplicationSet из Git.

### Другие причины

Типичные случаи, у каждого свой признак.

- **Опечатка в `path` генератора** — Application не создаются, `ErrorOccurred` или пустой список параметров.
- **Application не создаётся** — одноимённый Application уже принадлежит другому ApplicationSet, или два набора параметров дают одно имя; в `ErrorOccurred` видна ошибка.
- **Ручная правка Application откатывается** — ApplicationSet переписывает порождённые Application по шаблону; менять нужно шаблон в Git.
- **Prod ушёл вперёд staging** — дайджест записали в prod, минуя staging; ловится ревью и CODEOWNERS.
- **Расшифровка не работает** — нет ключа age или плагина; Secret не создан, а Application в `Degraded`.
- **Секрет в Git открытым текстом** — удаление коммита не помогает, значение считается скомпрометированным и меняется.

---

## 6. Пределы и значения по умолчанию

Числа и версии части собраны здесь, по группам. На стенде стоят Argo CD 3.5.5 (на 12.10.2026 это последняя версия), Gitea 1.27.0 и Kubernetes 1.36.

### Опрос и генераторы

- **Опрос Git** — раз в 180 с (`timeout.reconciliation`, 08-1); ускоряют webhook и аннотация `refresh`.
- **Генератор git** — раз в 180 с (`requeueAfterSeconds`); webhook ApplicationSet по документации принимает события GitHub и GitLab.
- **Генератор pullRequest** — `requeueAfterSeconds` по умолчанию 1800 с, `branch_slug` не длиннее 50 знаков.

### Защита от удаления

- **`applicationsSync`** — по умолчанию `sync`: создание, изменение и удаление разрешены.
- **Флаги контроллера ApplicationSet** — `--policy` (те же четыре значения) и `--enable-policy-override` (по умолчанию `false`).
- **`--dryrun true`** — контроллер ничего не создаёт и не удаляет.

### Версии и безопасность

- **ESO** — линия v2.x, API `external-secrets.io/v1`.
- **Sealed Secrets** — v0.40.0; новый ключ шифрования каждые 30 дней по умолчанию, старые ключи хранятся.
- **SOPS** — v3.13.3; **Argo CD Image Updater** — v1.3.1; **Flux** — 2.9.6.
- **CVE октября 2026** — обход ограничений AppProject через PreDelete и PostDelete хуки исправлен в 3.3.15, 3.4.10 и 3.5.4, поэтому 3.5.5 на стенде его содержит.
- **CRD ApplicationSet** слишком велик для client-side apply: Argo CD ставят с `--server-side` (08-1).
- **Argo CD 3.5** встраивает Helm 4 и игнорирует параметр `helm.version: v3`.

---

## Лабораторные работы

Работы начинаются со стенда, который оставила 08-1: Gitea в namespace `lab-08-1`, Argo CD 3.5.5 в `argocd` и репозиторий `~/lab/k8s/08-1/orders-gitops` с base и overlay staging. Если вы выполнили необязательную полную уборку 08-1, сначала повторите шаги 1–4 её работы 1. Окружения этой части живут в namespace `lab-08-2-staging` и `lab-08-2-prod`, временные файлы — в `~/lab/k8s/08-2/`. Полная уборка стенда GitOps — в конце работы 3, поэтому работы выполняйте по порядку.

Сначала подготовка. Команды загружают пароль Gitea, задают функцию коммита, добавляют в репозиторий overlay prod из 07-3 и переводят оба overlay в namespace этой части. Оболочка не помнит функции и переменные между сессиями, поэтому `gpush` задаётся заново.

```bash
mkdir -p ~/lab/k8s/08-2
. ~/lab/k8s/08-1/gitea.env
R=~/lab/k8s/08-1/orders-gitops
GIT_URL="http://$GITEA_USER:$GITEA_PASS@git.localhost:8088/lab/orders-gitops.git"
gpush() { git -C $R add -A && git -C $R commit -qm "$1" && \
  git -C $R push -q "$GIT_URL" main && git -C $R rev-parse --short HEAD; }
kubectl -n argocd delete app orders-staging --ignore-not-found
kubectl delete ns lab-08-1-staging --ignore-not-found
O=$R/apps/orders-api/overlays
cp -r ~/lab/k8s/07-3/orders-api/overlays/prod $O/
sed -i 's/^namespace: .*/namespace: lab-08-2-staging/' $O/staging/kustomization.yaml
sed -i 's/^namespace: .*/namespace: lab-08-2-prod/' $O/prod/kustomization.yaml
gpush "orders-api: prod overlay, namespaces lab-08-2"
for ns in lab-08-2-staging lab-08-2-prod; do
  kubectl create ns $ns
  kubectl -n $ns create secret generic postgres \
    --from-literal=DATABASE_URL=postgresql://orders:orders-lab-pass@postgres.orders:5432/orders
done
```

| Часть команды | Значение |
|---|---|
| `. ~/lab/k8s/08-1/gitea.env` | загрузить `GITEA_USER` и `GITEA_PASS` из файла 08-1 |
| `gpush() { … }` | функция из 08-1: коммит, отправка в Gitea, печать короткого хеша |
| `delete app orders-staging --ignore-not-found` | убрать Application 08-1, если он остался |
| `cp -r …/07-3/orders-api/overlays/prod` | взять overlay prod из 07-3: 3 реплики и образ по дайджесту |
| `sed -i 's/^namespace: .*/…/'` | перевести overlay в namespace этой части |
| `create secret generic postgres` | секрет базы; в Git его нет |

Результат: короткий хеш коммита, затем строки `namespace/… created` и `secret/postgres created` для двух namespace. Секрет создан вне Git намеренно: способы хранить его в Git описаны в §3.

Application `orders-staging` из 08-1 удаляется на случай, если уборка 08-1 пропущена. Иначе ApplicationSet забрал бы одноимённый объект себе и переписал его по шаблону, а старые объекты остались бы в `lab-08-1-staging`.

### Лабораторная работа 1. ApplicationSet и корневое Application

**Цель.** Описать окружения одним ApplicationSet в Git, подключить его корневым Application и увидеть, что Application появляются без ручных объектов.

**Что понадобится.**

- стенд после 08-1 и подготовка выше;
- overlays `staging` и `prod` в `apps/orders-api/overlays/`;
- около 2 минут на ожидание синхронизации.

**Схема опыта.**

```
 Git: argocd/orders-appset.yaml
        ▲ читает
 Application root ──► ApplicationSet orders-api ──► Application orders-staging ─► lab-08-2-staging
 (создан вручную)      generator: каталоги            Application orders-prod    ─► lab-08-2-prod
                       apps/orders-api/overlays/*
```

Схема 8. Руками создан один объект `root`; остальные породили Git и генератор.

#### Шаг 1. Записать ApplicationSet в Git

Команда создаёт файл ApplicationSet в каталоге `argocd/` репозитория и отправляет его в Gitea.

```bash
mkdir -p $R/argocd
cat > $R/argocd/orders-appset.yaml <<'E'
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata: {name: orders-api, namespace: argocd}
spec:
  goTemplate: true
  generators:
  - git:
      repoURL: http://gitea.lab-08-1.svc:3000/lab/orders-gitops.git
      revision: main
      directories:
      - path: apps/orders-api/overlays/*
  template:
    metadata:
      name: 'orders-{{ .path.basename }}'
      labels: {app.kubernetes.io/part-of: orders, env: '{{ .path.basename }}'}
    spec:
      project: default
      source:
        repoURL: http://gitea.lab-08-1.svc:3000/lab/orders-gitops.git
        targetRevision: main
        path: '{{ .path.path }}'
      destination:
        server: https://kubernetes.default.svc
        namespace: 'lab-08-2-{{ .path.basename }}'
      ignoreDifferences:
      - {group: apps, kind: Deployment, jsonPointers: [/spec/replicas]}
      syncPolicy:
        automated: {prune: true, selfHeal: true}
        syncOptions: [RespectIgnoreDifferences=true]
E
gpush "argocd: ApplicationSet for orders overlays"
```

| Часть команды | Значение |
|---|---|
| `generators: - git: directories` | выдавать набор параметров на каждый подкаталог |
| `path: apps/orders-api/overlays/*` | маска каталогов: `staging` и `prod` |
| `name: 'orders-{{ .path.basename }}'` | имя Application из имени каталога |
| `path: '{{ .path.path }}'` | источник Application — найденный каталог |
| `namespace: 'lab-08-2-{{ .path.basename }}'` | namespace, совпадающий с тем, что задаёт overlay |
| `ignoreDifferences`, `RespectIgnoreDifferences=true` | защита `replicas` от HPA, как в 08-1 |

Результат: команда печатает короткий хеш нового коммита. Хеш у каждого свой; в тексте дальше он не нужен.

Разбор: хеш показывает, что файл попал в `main`. ApplicationSet пока только лежит в Git, в кластере его нет, и Application не созданы.

#### Шаг 2. Создать корневое Application

Команда создаёт в кластере единственный объект, вручную: Application `root`, который читает каталог `argocd/`.

```bash
kubectl apply -f - <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: {name: root, namespace: argocd}
spec:
  project: default
  source:
    repoURL: http://gitea.lab-08-1.svc:3000/lab/orders-gitops.git
    targetRevision: main
    path: argocd
  destination: {server: https://kubernetes.default.svc, namespace: argocd}
  syncPolicy: {automated: {prune: true, selfHeal: true}}
EOF
```

| Часть команды | Значение |
|---|---|
| `path: argocd` | источник — каталог с ApplicationSet |
| `destination … namespace: argocd` | объекты Argo CD живут в своём namespace |
| `automated: {prune, selfHeal}` | применять и возвращать к Git без ручного sync |
| нет `finalizers` | при удалении `root` дочерние объекты останутся |

Результат: `application.argoproj.io/root created`.

Разбор: `root` не содержит ни одного приложения, он только указывает на каталог. Все остальные объекты придут оттуда.

#### Шаг 3. Проверить, что Application появились

Команда ждёт минуту, пока Argo CD прочитает Git, и показывает ApplicationSet, Application и образ prod.

```bash
sleep 60
kubectl -n argocd get applicationset,app
kubectl -n lab-08-2-prod get deploy orders-api -o jsonpath=\
'prod replicas={.status.readyReplicas} image={.spec.template.spec.containers[0].image}{"\n"}'
```

| Часть команды | Значение |
|---|---|
| `get applicationset,app` | оба типа объектов за один запрос |
| `jsonpath … readyReplicas` | число готовых реплик prod |
| `containers[0].image` | образ, который сейчас в Deployment |

Результат:

```
NAME                                    AGE
applicationset.argoproj.io/orders-api   23s
NAME                                     SYNC STATUS   HEALTH STATUS
application.argoproj.io/orders-prod      Synced        Healthy
application.argoproj.io/orders-staging   Synced        Healthy
application.argoproj.io/root             Synced        Healthy
prod replicas=3 image=localhost:5001/orders-api@sha256:ad4f8fd2…
```

Разбор:

1. `applicationset … orders-api` — `root` применил файл из Git; руками этот объект не создавали.
2. `orders-prod` и `orders-staging` — Application создал ApplicationSet, по одному на каталог.
3. `Synced / Healthy` у всех трёх — Git и кластер совпадают, ресурсы работают.
4. `prod replicas=3 image=…@sha256:…` — prod работает на образе, закреплённом дайджестом (07-3).

**Итог.**

| Что узнали | Где видно |
|---|---|
| Руками создан один объект, остальное идёт из Git | шаг 2, шаг 3 |
| Каталог в Git превращается в Application | `orders-staging`, `orders-prod` |
| Корневое Application читает не приложения, а описание приложений | `path: argocd` |

**Уборка.** Ничего не удаляется: ApplicationSet и Application нужны для работ 2 и 3.

**Вопросы для самопроверки.**

1. Что сделает ApplicationSet, если Application `orders-staging` уже существует и никому не принадлежит?
2. Что произойдёт, если добавить каталог `overlays/qa` и отправить коммит?
3. Зачем у `root` нет finalizer'а?

<details>
<summary>Ответ</summary>

1. Заберёт его себе: поставит себя владельцем и перепишет spec и finalizer по шаблону. Поэтому подготовка удаляет старый Application заранее, чтобы не получить смесь настроек 08-1 и шаблона.
2. Генератор найдёт новый каталог в течение опроса Git (по умолчанию до 180 с), и появится Application `orders-qa`. Namespace `lab-08-2-qa` при этом нужно создать заранее, как в подготовке.
3. Без finalizer'а удаление `root` не каскадирует на ApplicationSet и порождённые Application. Это нужно для порядка уборки в работе 3.

</details>

### Лабораторная работа 2. Промоушен дайджеста

**Цель.** Перенести версию 2.1 в prod одним коммитом с дайджестом и прочитать историю промоушена из Git.

**Что понадобится.**

- работа 1 выполнена: Application `orders-prod` существует;
- образ `orders-api:2.1` в реестре стенда `127.0.0.1:5001`;
- подготовленные функции `gpush` и данные Gitea.

**Схема опыта.**

```
 реестр :5001  ── HEAD /v2/orders-api/manifests/2.1 ──► Docker-Content-Digest
                                                         │
 overlays/prod/kustomization.yaml  ◄── digest: sha256:… ─┘  (коммит в Git)
                      │
                      ▼
          Argo CD: sync ─► rollout ─► /version отвечает 2.1
```

Схема 9. Дайджест берётся из реестра, записывается в Git, а в кластер его доставляет Argo CD.

#### Шаг 1. Получить дайджест образа

Команда спрашивает у реестра заголовок `Docker-Content-Digest` для тега 2.1.

```bash
D=$(curl -sI \
  -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' \
  http://127.0.0.1:5001/v2/orders-api/manifests/2.1 \
  | tr -d '\r' | awk -F': ' 'tolower($1)=="docker-content-digest"{print $2}')
echo "2.1 digest: $D"
```

| Часть команды | Значение |
|---|---|
| `curl -sI` | запрос HEAD без тела, молча |
| `Accept: …manifest.v2+json` | запросить манифест в формате v2, чтобы реестр вернул его дайджест |
| `tr -d '\r'` | убрать возврат каретки из заголовков HTTP |
| `awk … tolower($1)==…` | взять значение заголовка независимо от регистра |

Результат:

```
2.1 digest: sha256:053e1ef23615b9db38c3aef750040bf4a3770532248bd13a2956c8d26c4ffd36
```

Разбор: 64 шестнадцатеричных знака после `sha256:` — хеш манифеста образа. Он не изменится, пока образ тот же, даже если тег `2.1` переставят.

#### Шаг 2. Записать дайджест в prod-overlay

Команда подставляет дайджест в overlay prod, отправляет коммит и запоминает время.

```bash
t0=$(date +%s)
sed -i "s/digest: sha256:.*/digest: $D/" \
  $R/apps/orders-api/overlays/prod/kustomization.yaml
gpush "prod: promote orders-api 2.1 ($D)"
```

| Часть команды | Значение |
|---|---|
| `t0=$(date +%s)` | момент старта для замера |
| `sed -i "s/digest: sha256:.*/digest: $D/"` | заменить строку `digest` на новую |
| `gpush "prod: promote …"` | коммит с дайджестом в сообщении |

Результат: хеш коммита, на стенде автора это было `def057c`; у вас он другой.

Разбор: изменилась одна строка в одном файле. Это и есть промоушен: ревью видит ровно то, что уйдёт в prod.

#### Шаг 3. Дождаться выкатки и проверить версию

Команда просит Argo CD перечитать Git, ждёт rollout и спрашивает у приложения версию.

```bash
kubectl -n argocd annotate app orders-prod argocd.argoproj.io/refresh=normal --overwrite
kubectl -n lab-08-2-prod rollout status deploy/orders-api
echo "after $(( $(date +%s)-t0 ))s"
kubectl -n lab-08-2-prod exec deploy/orders-api -- python -c \
  "import urllib.request as u;print(u.urlopen('http://127.0.0.1:8000/version').read().decode())"
kubectl -n argocd get app orders-prod \
  -o jsonpath='{.status.sync.status}/{.status.health.status} {.status.sync.revision}{"\n"}'
git -C $R log --oneline -3 -- apps/orders-api/overlays/prod
```

| Часть команды | Значение |
|---|---|
| `annotate … refresh=normal` | не ждать опроса в 180 с (08-1) |
| `rollout status` | блокироваться, пока Deployment не обновится |
| `exec … urlopen('…/version')` | спросить версию у самого пода |
| `-o jsonpath … sync.revision` | какую ревизию Git применил Argo CD |
| `git log --oneline -3 -- <каталог>` | три последних коммита, затронувших prod |

Результат:

```
deployment "orders-api" successfully rolled out
after 6s
{"version": "2.1", "pod": "orders-api-864d698dfc-8l6pc"}
Synced/Healthy def057c16fdeeaf7ac9e4119fb6d73672ce1ed39
```

Команда `git log` печатает три строки: хеш и сообщение, первая из которых начинается с `prod: promote orders-api 2.1`.

Разбор:

1. `successfully rolled out`, `after 6s` — от коммита до готового rollout прошло 6 с, потому что мы ускорили опрос аннотацией `refresh`.
2. `"version": "2.1"` — работает новая версия; имя пода у вас будет другим.
3. `Synced/Healthy` и ревизия `def057c…` совпадают с хешем коммита: кластер применил именно его.
4. `git log` по каталогу prod — готовый журнал промоушенов: кто, когда и какой дайджест.

**Итог.**

| Что узнали | Где видно |
|---|---|
| Промоушен — коммит одной строки с дайджестом | шаг 2 |
| Ревизия Application равна хешу коммита | шаг 3, строка `Synced/Healthy` |
| История выкаток читается из `git log` каталога | шаг 3 |
| `refresh` заменяет ожидание опроса в 180 с | `after 6s` |

**Уборка.** Ничего не удаляется: состояние prod нужно работе 3.

**Вопросы для самопроверки.**

1. Чем дайджест лучше тега `2.1` в overlay prod?
2. Что Argo CD покажет в `sync.revision` после промоушена?
3. Зачем CI в этой схеме не нужен доступ к кластеру?

<details>
<summary>Ответ</summary>

1. Тег можно переписать, и тогда prod получит не тот образ, что проверили в staging. Дайджест определяет содержимое образа, и кластер не запустит другой.
2. Полный хеш коммита с промоушеном, в нашем прогоне `def057c…`. Совпадение с `git rev-parse` ветки значит, что изменение доехало.
3. CI пишет только в Git, а применяет изменение Argo CD изнутри кластера. Поэтому ключ CI даёт запись в config-репозиторий и не даёт доступа к API кластера.

</details>

### Лабораторная работа 3. Удаление окружения и защита от него

**Цель.** Увидеть, как удаление каталога из Git сносит окружение, и включить защиту `preserveResourcesOnDeletion` и `applicationsSync`. После этого убрать стенд GitOps целиком.

**Что понадобится.**

- работы 1 и 2 выполнены;
- каталог `overlays/staging` в репозитории и два Application;
- около 10 минут.

**Схема опыта.**

```
 Шаг 1:  убрать overlays/staging из Git ─► Application исчез ─► ресурсы удалены
 Шаг 2:  вернуть каталог                ─► Application создан заново
 Шаг 3:  preserveResourcesOnDeletion    ─► Application исчез, ресурсы остались
 Шаг 4:  applicationsSync: create-update─► Application не удалён вовсе
```

Схема 10. Четыре исхода одного и того же действия «убрать каталог из Git» при разных настройках.

#### Шаг 1. Убрать каталог и замерить удаление

Команда читает finalizer Application, переносит каталог `staging` из репозитория, отправляет коммит и ждёт исчезновения Application.

```bash
kubectl -n argocd get app orders-staging -o jsonpath='{.metadata.finalizers}{"\n"}'
mv $R/apps/orders-api/overlays/staging ~/lab/k8s/08-2/staging-saved
gpush "remove staging overlay"
t0=$(date +%s)
kubectl -n argocd annotate applicationset orders-api \
  argocd.argoproj.io/application-set-refresh=true --overwrite
until ! kubectl -n argocd get app orders-staging >/dev/null 2>&1; do sleep 1; done
echo "Application gone after $(( $(date +%s)-t0 ))s"
echo "resources in lab-08-2-staging: $(kubectl -n lab-08-2-staging \
  get deploy,svc,httproute --no-headers 2>/dev/null | wc -l)"
```

| Часть команды | Значение |
|---|---|
| `get app … {.metadata.finalizers}` | какие finalizer'ы висят на Application |
| `mv … staging-saved` | убрать каталог из репозитория, сохранив копию вне его |
| `annotate applicationset … application-set-refresh=true` | заставить контроллер сразу запустить генератор |
| `until ! kubectl … get app` | ждать, пока Application перестанет существовать |
| `get deploy,svc,httproute … wc -l` | посчитать оставшиеся объекты в namespace |

Результат:

```
["resources-finalizer.argocd.argoproj.io"]
Application gone after 4s
resources in lab-08-2-staging: 0
```

Разбор:

1. Finalizer `resources-finalizer.argocd.argoproj.io` — он делает удаление Application каскадным.
2. `gone after 4s` — Application исчез через 4 секунды после того, как контроллер перечитал Git.
3. `resources … : 0` — вместе с ним удалены Deployment, Service и HTTPRoute: окружения больше нет.
4. Никто не нажимал «удалить»: действие выполнил генератор, который перестал находить каталог.

#### Шаг 2. Вернуть каталог

Команда возвращает каталог и коммитит, после чего ждёт нового Application.

```bash
mv ~/lab/k8s/08-2/staging-saved $R/apps/orders-api/overlays/staging
gpush "restore staging overlay"
t0=$(date +%s)
kubectl -n argocd annotate applicationset orders-api \
  argocd.argoproj.io/application-set-refresh=true --overwrite
until kubectl -n argocd get app orders-staging >/dev/null 2>&1; do sleep 1; done
echo "Application back after $(( $(date +%s)-t0 ))s"
kubectl -n argocd get app orders-staging
```

| Часть команды | Значение |
|---|---|
| `mv … staging-saved … staging` | вернуть каталог на место |
| `until kubectl … get app` | ждать, пока Application снова появится |
| `get app orders-staging` | показать статус возвращённого Application |

Результат: Application возвращается примерно через 4 секунды; затем, после синхронизации, `orders-staging` снова `Synced` и `Healthy`. Строки `back after …` и таблицы статуса точно не снимались, у вас значения будут свои.

Разбор: возврат каталога так же прост, как удаление, и окружение собирается заново из Git. Но на пересборку нужно время, а данные в томах, которых нет в манифестах, при этом не вернуть.

#### Шаг 3. Включить preserveResourcesOnDeletion

Команда добавляет защиту в ApplicationSet через Git, ждёт обновления Application и повторяет удаление каталога. Ожидаемый результат ниже на стенде автора не снимался.

```bash
sed -i '/^  goTemplate: true/a\  syncPolicy:\n    preserveResourcesOnDeletion: true' \
  $R/argocd/orders-appset.yaml
gpush "appset: preserveResourcesOnDeletion"
kubectl -n argocd annotate applicationset orders-api \
  argocd.argoproj.io/application-set-refresh=true --overwrite
sleep 20
kubectl -n argocd get app orders-staging -o jsonpath='{.metadata.finalizers}{"\n"}'
mv $R/apps/orders-api/overlays/staging ~/lab/k8s/08-2/staging-saved
gpush "remove staging overlay again"
kubectl -n argocd annotate applicationset orders-api \
  argocd.argoproj.io/application-set-refresh=true --overwrite
sleep 15
kubectl -n argocd get app
kubectl -n lab-08-2-staging get deploy,svc,httproute --no-headers | wc -l
```

| Часть команды | Значение |
|---|---|
| `sed -i '/^  goTemplate: true/a\…'` | вставить блок `syncPolicy` после строки `goTemplate` |
| `preserveResourcesOnDeletion: true` | не вешать каскадный finalizer на Application |
| `get app orders-staging … finalizers` | проверить, что finalizer снят |
| `get app` | какие Application остались |
| `get deploy,svc,httproute … wc -l` | сколько объектов окружения уцелело |

Ожидаемый результат (на стенде автора не снимался):

```
(пусто или [])
NAME            SYNC STATUS   HEALTH STATUS
orders-prod     Synced        Healthy
root            Synced        Healthy
3
```

Разбор:

1. Пустой список finalizer'ов — контроллер обновил существующий Application и снял каскад.
2. В списке нет `orders-staging` — Application удалён, как и раньше.
3. Число 3 (Deployment, Service, HTTPRoute) — ресурсы остались в кластере без владельца, а не удалены.
4. Если в пункте 1 finalizer остался, ресурсы будут удалены, как в шаге 1: защиту проверяют до удаления каталога.

Теперь вернём каталог: ApplicationSet создаст Application заново и примет уцелевшие ресурсы, без пересоздания подов.

```bash
mv ~/lab/k8s/08-2/staging-saved $R/apps/orders-api/overlays/staging
gpush "restore staging overlay"
kubectl -n argocd annotate applicationset orders-api \
  argocd.argoproj.io/application-set-refresh=true --overwrite
sleep 15
kubectl -n argocd get app orders-staging
```

Ожидаемый результат: `orders-staging` снова `Synced` и `Healthy`; возраст подов в `lab-08-2-staging` не сбросился.

#### Шаг 4. Запретить ApplicationSet удалять Application

Команда добавляет `applicationsSync: create-update` и повторяет удаление каталога. Ожидаемый результат на стенде автора не снимался.

```bash
sed -i '/preserveResourcesOnDeletion/a\    applicationsSync: create-update' \
  $R/argocd/orders-appset.yaml
gpush "appset: applicationsSync create-update"
mv $R/apps/orders-api/overlays/staging ~/lab/k8s/08-2/staging-saved
gpush "remove staging overlay third time"
kubectl -n argocd annotate applicationset orders-api \
  argocd.argoproj.io/application-set-refresh=true --overwrite
sleep 20
kubectl -n argocd get app orders-staging
kubectl -n lab-08-2-staging get deploy --no-headers | wc -l
```

| Часть команды | Значение |
|---|---|
| `applicationsSync: create-update` | ApplicationSet создаёт и обновляет Application, но не удаляет |
| вторая строка `sed` | вставить поле после `preserveResourcesOnDeletion` |
| `get app orders-staging` | Application должен остаться |
| `get deploy … wc -l` | Deployment должен остаться |

Ожидаемый результат (на стенде автора не снимался): `orders-staging` остаётся в списке с ошибочным статусом, потому что путь источника не найден. Команда `get deploy` возвращает 1.

Разбор: Application не удалён, ресурсы работают, а Argo CD сообщает об ошибке источника. Так сбой превращается из аварии в сигнал, который видно в статусе. Вернём каталог и очистим стенд.

```bash
mv ~/lab/k8s/08-2/staging-saved $R/apps/orders-api/overlays/staging
gpush "restore staging overlay"
```

**Итог.**

| Что узнали | Где видно |
|---|---|
| Удаление каталога из Git каскадно удаляет окружение | шаг 1, 0 ресурсов за 4 с |
| Возврат каталога пересоздаёт Application | шаг 2 |
| `preserveResourcesOnDeletion` оставляет ресурсы | шаг 3 |
| `applicationsSync: create-update` оставляет и Application | шаг 4 |

**Уборка.** Порядок важен. Сначала удаляется корневое Application без каскада, затем ApplicationSet, затем Argo CD, Gitea и CRD. Ресурсы окружений уйдут вместе с их namespace. Команды убирают стенд GitOps целиком, но не трогают `orders` и сам кластер.

Репозиторий `$R` остаётся локально.

```bash
kubectl -n argocd delete app root
kubectl -n argocd delete applicationset orders-api
kubectl delete -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.5.5/manifests/install.yaml
kubectl delete ns argocd gitea lab-08-2-staging lab-08-2-prod
kubectl get crd -o name | grep argoproj.io | xargs -r kubectl delete
rm -f ~/lab/k8s/gitea.env
rm -rf ~/lab/k8s/08-2
unset -f gpush
curl -s -o /dev/null -w '%{http_code}\n' http://orders.localhost:8088/api/orders
```

| Часть команды | Значение |
|---|---|
| `delete app root` | удалить корень, не трогая ApplicationSet |
| `delete applicationset orders-api` | удалить генератор и его Application |
| `delete -f …install.yaml` | удалить компоненты Argo CD |
| `delete ns …` | удалить namespace Argo CD, Gitea и окружений вместе с содержимым |
| `grep argoproj.io … xargs delete` | удалить CRD Argo CD |
| `rm -f … gitea.env`, `rm -rf …/08-2` | убрать пароль и временные файлы работ |
| `curl … /api/orders` | проверить, что демо-приложение стенда работает |

Результат последней команды: `200`. Это значит, что namespace `orders` и вход стенда не затронуты.

**Вопросы для самопроверки.**

1. Почему в уборке сначала удаляют `root`, а не ApplicationSet?
2. Чем `preserveResourcesOnDeletion` отличается от `applicationsSync: create-update`?
3. Почему защита от удаления не заменяет ревью каталога `argocd/`?

<details>
<summary>Ответ</summary>

1. Корневое Application с `selfHeal` пересоздаст удалённый ApplicationSet из Git. Если сначала удалить корень, который не имеет finalizer'а, ApplicationSet остаётся и затем удаляется без повторного создания.
2. `preserveResourcesOnDeletion` позволяет Application исчезнуть, но оставляет его ресурсы. `applicationsSync: create-update` не даёт ApplicationSet удалять Application вовсе, поэтому окружение остаётся под управлением Argo CD.
3. Защита ограничивает последствия, но не исключает ошибку: неверная маска или неверная ветка всё равно оставят приложения без управления. Ревью и `argocd appset generate` ловят ошибку до слияния.

</details>

---

## → Дальше

GitOps доставляет любые манифесты, и многие из них описывают не приложения, а новые типы объектов: ApplicationSet, Application и ExternalSecret кто-то объявил в API. Модуль 09 показывает, как Kubernetes расширяют своими типами. Часть 09-1 разбирает CRD и операторы: как описывают тип и что делает контроллер. Без этого ApplicationSet остаётся магией, а оператор CloudNativePG держит базу из трёх реплик по тому же принципу.
