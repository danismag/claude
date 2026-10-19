# 08-2. GitOps в масштабе

> Модуль 8 «GitOps» · часть 2 из 2 · 🟡🔴 · ~1,5 ч чтения + ~45 мин лабы · Нужно: Argo CD, Gitea и репозиторий `lab/orders-gitops` из 08-1. В конце лабы Argo CD и Gitea удаляются.

---

## Зачем это DevOps-у

Одно Application руками — это демо. В работе — десятки сервисов в нескольких окружениях и кластерах, и вопросы другие: «как добавить новый сервис, не трогая Argo CD руками», «как промоутить версию из staging в prod», «где хранить секреты, если всё в Git», «почему удаление одной папки в Git снесло окружение» (кейс части). На собеседовании: «app-of-apps vs ApplicationSet», «как хранить секреты в GitOps», «Argo CD или Flux».

Сквозной сценарий: overlays staging и prod orders-api становятся двумя Application, которые создаёт ApplicationSet; prod обновляется коммитом дайджеста, собранного CI.

---

## 1. Как Argo CD управляет самим собой: app-of-apps 🟡

Application, источником которого служит каталог с **другими** Application/ApplicationSet. Один корневой объект создаётся руками (или при установке), всё остальное — из Git.

```
Git: lab/orders-gitops
  argocd/orders-appset.yaml          ← описание «какие приложения есть»
  apps/orders-api/base/
  apps/orders-api/overlays/{staging,prod}/

кластер: Application root (path: argocd) ─► ApplicationSet orders-api ─► Application orders-staging, orders-prod
```

Проверено:

```
NAME                                    AGE
applicationset.argoproj.io/orders-api   23s
NAME                                     SYNC STATUS   HEALTH STATUS
application.argoproj.io/orders-prod      Synced        Healthy
application.argoproj.io/orders-staging   Synced        Healthy
application.argoproj.io/root             Synced        Healthy
prod replicas=3 image=localhost:5001/orders-api@sha256:ad4f8fd2…
```

Плюсы: настройки приложений (включая `ignoreDifferences` из 08-1) — в Git и на ревью; новый кластер поднимается применением одного корневого объекта. Минус классического app-of-apps — каждое дочернее Application пишут руками; для «одинаковых» приложений это делает ApplicationSet.

## 2. ApplicationSet: генераторы 🟡

ApplicationSet — шаблон Application + **генератор** параметров:

| Генератор | Откуда параметры | Типичный случай |
|---|---|---|
| `list` | список в самом объекте | несколько окружений с явными параметрами |
| `git` (directories / files) | каталоги или JSON/YAML-файлы в репозитории | «папка = приложение/окружение» |
| `cluster` | зарегистрированные в Argo CD кластеры (по меткам) | одно приложение во все кластеры |
| `matrix`, `merge` | комбинация генераторов | сервисы × кластеры |
| `scmProvider`, `pullRequest` | репозитории организации, открытые PR | preview-окружения на PR |

Стенд — генератор каталогов (проверено):

```yaml
spec:
  goTemplate: true
  generators:
  - git:
      repoURL: http://gitea.gitea.svc:3000/lab/orders-gitops.git
      revision: main
      directories: [{path: apps/orders-api/overlays/*}]
  template:
    metadata:
      name: 'orders-{{ .path.basename }}'
    spec:
      source: {repoURL: …, targetRevision: main, path: '{{ .path.path }}'}
      destination: {server: https://kubernetes.default.svc, namespace: 'lab-07-3-{{ .path.basename }}'}
      ignoreDifferences: [{group: apps, kind: Deployment, jsonPointers: [/spec/replicas]}]
      syncPolicy:
        automated: {prune: true, selfHeal: true}
        syncOptions: [RespectIgnoreDifferences=true]
```

Новое окружение — новый каталог overlay в Git; Argo CD создаст Application сам.

### Ловушка: удаление каталога удаляет окружение 🔴

Проверено: у сгенерированного Application есть `finalizers: ["resources-finalizer.argocd.argoproj.io"]`. Каталог `overlays/staging` убрали из Git:

```
commit ca290d0
Application gone after 4s
resources in lab-07-3-staging: 0          ← Deployment, Service, ConfigMap, HTTPRoute удалены каскадно
```

Опечатка в пути генератора, неудачный рефакторинг структуры репозитория, force-push не той ветки — и ApplicationSet удаляет приложения **вместе с ресурсами**. Защита:

```yaml
spec:
  syncPolicy:
    preserveResourcesOnDeletion: true     # Application удаляется, ресурсы остаются
    applicationsSync: create-update        # ApplicationSet не удаляет Application вообще (create-only — и не обновляет)
```

⚠️ Эти два поля на стенде не включались — проверено только поведение по умолчанию. Плюс защита ветки `main` (без force-push), ревью изменений в каталоге `argocd/`, и для stateful-приложений — `prune: false` у Application.

## 3. Структура репозиториев 🟡

| Схема | Как | Когда |
|---|---|---|
| **monorepo конфигурации** | все манифесты всех сервисов и окружений в одном репозитории (как стенд) | одна платформенная команда, десятки сервисов |
| **repo на сервис** | манифесты рядом с кодом сервиса | команды независимы, но промоушен = MR в каждый репозиторий |
| **app-репо + config-репо** | код и Dockerfile — в репозитории сервиса; манифесты и версии — в отдельном config-репозитории | самый частый: CI сервиса пишет версию в config-репо |
| окружения — ветки | `staging`, `prod` ветки | анти-рецепт: merge между ветками тащит лишнее, история расходится; окружения — каталоги |

Принципы: окружения различаются **каталогами** (overlays/values), а не ветками; в Git — только то, что применяется к кластеру (нет секретов, нет сгенерированных артефактов); права на каталог prod — у меньшего круга, чем на staging.

## 4. Промоушен: CI пишет дайджест в Git 🟡🔴

```
CI сервиса: сборка → push образа → дайджест sha256:…
          → коммит в config-репо: overlays/staging/kustomization.yaml (images.digest)
          → тесты на staging → MR в overlays/prod (тот же дайджест) → ревью → merge
Argo CD:  видит коммит → sync → rollout
```

Проверено на стенде: дайджест `2.1` получен из реестра (`HEAD /v2/orders-api/manifests/2.1` → `Docker-Content-Digest`), записан в prod-overlay коммитом `def057c`:

```
2.1 digest: sha256:053e1ef23615b9db38c3aef750040bf4a3770532248bd13a2956c8d26c4ffd36
commit def057c
deployment "orders-api" successfully rolled out
after 6s
{"version": "2.1", "pod": "orders-api-864d698dfc-8l6pc"}
Synced/Healthy def057c16fdeeaf7ac9e4119fb6d73672ce1ed39
```

Промоушен — **тот же дайджест**, а не пересборка (курс `cicd` 03-1). История промоушенов — это `git log` каталога prod: кто, когда, какой дайджест. Автоматизация вместо CI-коммитов — Argo CD Image Updater (следит за реестром и пишет в Git или в параметры Application) или Kargo (стадии и промоушен как объекты) — ⚠️ на стенде не ставились.

Доступ CI к config-репо — отдельным ключом/токеном только на запись в нужные каталоги; кластер CI не нужен вообще.

## 5. Секреты в GitOps 🔴

Git — источник истины, но секреты в нём хранить нельзя, даже base64 (04-1). Варианты:

| Подход | В Git | Кто расшифровывает | Плюсы | Минусы |
|---|---|---|---|---|
| **External Secrets Operator** | `ExternalSecret`: ссылка «ключ X из Vault/AWS SM/Lockbox» | ESO в кластере, кладёт обычный Secret | секреты живут в менеджере, ротация там же | нужен внешний менеджер секретов; Secret в etcd (04-1 — шифрование) |
| **Secrets Store CSI Driver** | `SecretProviderClass` | драйвер, монтирует файлом | секрет может не попадать в etcd | только тома; синхронизация в Secret — опционально |
| **SOPS** (+ age/KMS) | зашифрованный файл, ключи видны, значения — нет | плагин Argo CD (KSOPS, helm-secrets) или Flux (нативно) | секреты версионируются рядом с манифестами | ключ расшифровки в кластере; ротация — перешифровать файлы |
| **Sealed Secrets** | `SealedSecret`, зашифрованный публичным ключом контроллера | контроллер в кластере | просто, без внешних систем | привязан к ключу кластера; бэкап ключа обязателен |
| секрет создаётся вне GitOps | ничего | человек/скрипт | быстро на стенде (так сделано в лабах) | не воспроизводимо, нет аудита |

⚠️ Ни один из инструментов на стенде не ставился — секрет `postgres` в лабах создаётся командой вне Git. Практичный выбор: есть Vault или облачный менеджер — ESO; нет — SOPS с age/KMS (Flux) или Sealed Secrets. В любом варианте Argo CD не должен показывать значения в diff: для Secret'ов он маскирует данные, но плагины рендеринга видят их в открытом виде — права на repo-server и логи.

## 6. Argo CD и Flux 🟡

| | Argo CD | Flux |
|---|---|---|
| Модель | Application (что → куда), центральный контроллер | набор контроллеров: GitRepository/OCIRepository → Kustomization / HelmRelease |
| UI | встроенный, сильный | нет своего (Weave GitOps, Headlamp — сторонние) |
| Мультикластер | из одного Argo CD во многие кластеры | обычно Flux в каждом кластере |
| Helm | рендерит сам (`helm template`), `helm list` пуст (07-3) | HelmRelease через Helm SDK — настоящий релиз с историей |
| SOPS | через плагины | встроено |
| Генерация приложений | ApplicationSet | Kustomization с подстановками, ResourceSet в новых версиях |
| Порог входа | ниже (UI, наглядный diff) | выше, но меньше «магии» |

Оба — проекты CNCF graduated. Типичный выбор: Argo CD, когда важны UI и централизованное управление многими кластерами; Flux — когда нужны «кирпичики» и нативный SOPS/Helm-релизы.

---

## 🔧 Лаба

### Шаг 0. Подготовка

Нужны Argo CD, Gitea, `~/lab/k8s/gitops` и функции `gpush`/`refresh` из 08-1 (`. ~/lab/k8s/gitea.env`).

```bash
kubectl -n argocd delete app orders-staging --ignore-not-found        # осталось из 08-1 — теперь им управляет ApplicationSet
for ns in lab-07-3-staging lab-07-3-prod; do
  kubectl create ns $ns 2>/dev/null
  kubectl -n $ns get secret postgres >/dev/null 2>&1 || kubectl -n $ns create secret generic postgres \
    --from-literal=DATABASE_URL=postgresql://orders:orders-lab-pass@postgres.orders:5432/orders
done
```

### Шаг 1. ApplicationSet в Git и корневое Application

```bash
mkdir -p ~/lab/k8s/gitops/argocd
cat > ~/lab/k8s/gitops/argocd/orders-appset.yaml <<'E'
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata: {name: orders-api, namespace: argocd}
spec:
  goTemplate: true
  generators:
  - git:
      repoURL: http://gitea.gitea.svc:3000/lab/orders-gitops.git
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
        repoURL: http://gitea.gitea.svc:3000/lab/orders-gitops.git
        targetRevision: main
        path: '{{ .path.path }}'
      destination: {server: https://kubernetes.default.svc, namespace: 'lab-07-3-{{ .path.basename }}'}
      ignoreDifferences:
      - {group: apps, kind: Deployment, jsonPointers: [/spec/replicas]}
      syncPolicy:
        automated: {prune: true, selfHeal: true}
        syncOptions: [RespectIgnoreDifferences=true]
E
gpush "argocd: ApplicationSet for orders overlays"
kubectl apply -f - <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: {name: root, namespace: argocd}
spec:
  project: default
  source: {repoURL: http://gitea.gitea.svc:3000/lab/orders-gitops.git, targetRevision: main, path: argocd}
  destination: {server: https://kubernetes.default.svc, namespace: argocd}
  syncPolicy: {automated: {prune: true, selfHeal: true}}
EOF
sleep 60; kubectl -n argocd get applicationset,app
kubectl -n lab-07-3-prod get deploy orders-api -o jsonpath='{.status.readyReplicas} {.spec.template.spec.containers[0].image}{"\n"}'
```

Проверено: вывод в §1.

### Шаг 2. Промоушен дайджеста в prod

```bash
D=$(curl -sI -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' http://127.0.0.1:5001/v2/orders-api/manifests/2.1 \
  | tr -d '\r' | awk -F': ' 'tolower($1)=="docker-content-digest"{print $2}'); echo $D
sed -i "s/digest: sha256:.*/digest: $D/" ~/lab/k8s/gitops/apps/orders-api/overlays/prod/kustomization.yaml
gpush "prod: promote orders-api 2.1 ($D)"
kubectl -n argocd annotate app orders-prod argocd.argoproj.io/refresh=normal --overwrite
kubectl -n lab-07-3-prod rollout status deploy/orders-api
kubectl -n lab-07-3-prod exec deploy/orders-api -- python -c "import urllib.request;print(urllib.request.urlopen('http://127.0.0.1:8000/version').read().decode())"
git -C ~/lab/k8s/gitops log --oneline -3 -- apps/orders-api/overlays/prod
```

Проверено: вывод в §4. Агент брал дайджест из сети kind (`kind-registry:5000`), с хоста — `127.0.0.1:5001`.

### Шаг 3. Удаление каталога — удаление окружения

```bash
kubectl -n argocd get app orders-staging -o jsonpath='{.metadata.finalizers}{"\n"}'
git -C ~/lab/k8s/gitops mv apps/orders-api/overlays/staging /tmp/staging-saved 2>/dev/null || mv ~/lab/k8s/gitops/apps/orders-api/overlays/staging /tmp/staging-saved
gpush "remove staging overlay"
kubectl -n argocd annotate applicationset orders-api argocd.argoproj.io/application-set-refresh=true --overwrite
sleep 10; kubectl -n argocd get app; kubectl -n lab-07-3-staging get deploy,svc,cm
mv /tmp/staging-saved ~/lab/k8s/gitops/apps/orders-api/overlays/staging
gpush "restore staging overlay"
kubectl -n argocd annotate applicationset orders-api argocd.argoproj.io/application-set-refresh=true --overwrite
sleep 10; kubectl -n argocd get app orders-staging
```

Проверено: вывод в §2 — 4 с до удаления Application и всех ресурсов, 4 с до восстановления.

### Уборка: GitOps-стенд целиком

Порядок важен: сначала ApplicationSet (его приложения удалят свои ресурсы finalizer'ом), затем корневое Application, затем Argo CD и Gitea.

```bash
kubectl -n argocd delete app root                       # без finalizer: ApplicationSet остаётся
kubectl -n argocd delete applicationset orders-api      # удалит orders-staging/prod и их ресурсы
kubectl delete -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.5.5/manifests/install.yaml
kubectl delete ns argocd gitea lab-07-3-staging lab-07-3-prod
kubectl get crd -o name | grep argoproj.io | xargs -r kubectl delete
rm -f ~/lab/k8s/gitea.env                                # репозиторий ~/lab/k8s/gitops остаётся локально
curl -s -o /dev/null -w '%{http_code}\n' http://orders.localhost:8088/api/orders     # 200 — сквозной сценарий не затронут
```

---

## 🔥 Кейс из прода: «рефакторинг репозитория удалил прод»

**Контекст.** Платформенная команда перекладывала config-репозиторий: `apps/<сервис>/overlays/<env>` → `services/<сервис>/<env>`. ApplicationSet с генератором каталогов `apps/*/overlays/*` и дефолтной политикой. MR с перемещением файлов смержили утром; ApplicationSet в той же ветке обновили вторым MR — через час.

**Разбор.**
1. После первого MR генератор не нашёл ни одного каталога по старой маске — и удалил все сгенерированные Application.
2. У сгенерированных Application стоит `resources-finalizer.argocd.argoproj.io` — удаление каскадное: Deployment'ы, Service'ы, HTTPRoute'ы 40 сервисов в трёх окружениях (воспроизведение — шаг 3 лабы на одном окружении: 4 секунды).
3. PVC StatefulSet'ов уцелели (PVC из `volumeClaimTemplates` не принадлежат Application), поэтому данные не потеряны — потерян час доступности.

**Фикс.**
- `preserveResourcesOnDeletion: true` в ApplicationSet; для критичных — `applicationsSync: create-update` (ApplicationSet не удаляет Application).
- Изменения в каталоге `argocd/` и структуре репозитория — одним MR с ApplicationSet и с обязательным ревью платформенной команды; защита `main` от force-push.
- Dry-run генератора перед merge: `argocd appset generate` (CLI) на ветке MR — какие Application появятся/исчезнут.
- Алерт на массовое удаление Application.

**Что запомнить.**
- ApplicationSet по умолчанию удаляет приложения, которые генератор перестал находить, — вместе с ресурсами.
- Перемещение каталогов в GitOps-репозитории — изменение прода.
- `preserveResourcesOnDeletion` и ревью `argocd/` — обязательны.

---

## 💼 Вопросы с собеседования

### 🟢 Junior

**1. Что такое app-of-apps?**
Application, чей источник — каталог с другими Application/ApplicationSet. Позволяет держать конфигурацию самого Argo CD в Git и поднимать всё из одного корневого объекта.

**2. Как добавить новый сервис в GitOps?**
Добавить манифесты/overlay в config-репозиторий (и Application или каталог, который подхватит ApplicationSet), пройти ревью; Argo CD синхронизирует сам. Руками в кластере ничего не создаётся.

### 🟡 Middle

**3. App-of-apps или ApplicationSet?**
App-of-apps — явный список Application (каждое пишется руками), гибко для разнородных приложений. ApplicationSet — шаблон и генератор (каталоги, кластеры, список, PR) для однотипных; меньше копипасты, но изменения генератора массово создают и удаляют приложения.

**4. Как промоутить версию из staging в prod?**
CI собирает образ один раз, записывает дайджест в staging-каталог config-репозитория; после проверки — тот же дайджест MR'ом в prod-каталог; Argo CD применяет. История промоушенов — git log. Автоматизация — Image Updater, Kargo.

**5. Где хранить секреты в GitOps?**
Не в Git открытым текстом. External Secrets Operator (ссылки на Vault/облачный менеджер), Secrets Store CSI, SOPS (зашифрованные файлы, расшифровка плагином/Flux), Sealed Secrets (шифрование ключом контроллера). Выбор — по наличию внешнего менеджера и требованиям к ротации.

### 🔴 Senior

**6. Чем опасен ApplicationSet и как защититься?**
Генератор перестал находить источник (опечатка, рефакторинг, неверная ветка) — ApplicationSet удаляет Application, а finalizer каскадно удаляет ресурсы. Защита: `preserveResourcesOnDeletion`, `applicationsSync: create-update`, ревью и защита ветки, dry-run генерации, алерты.

**7. Как организовать GitOps для 30 сервисов в 3 окружениях и 2 кластерах?**
App-репо + config-репо; в config-репо — каталоги сервис/окружение (Kustomize overlays или Helm values); ApplicationSet с matrix (сервисы × кластеры); AppProject на команду; промоушен MR'ом дайджеста; секреты — ESO; права на prod-каталоги через CODEOWNERS; webhook для быстрой доставки.

**8. Argo CD или Flux?**
Argo CD — UI, наглядный diff, централизованное управление многими кластерами, ApplicationSet; Helm рендерится без релиза. Flux — модульные контроллеры в каждом кластере, нативные HelmRelease и SOPS, меньше центральной точки отказа. Оба graduated CNCF; выбор — по модели эксплуатации и требованиям к UI.

---

## ⚠️ Подводные камни

- ApplicationSet удаляет приложения и их ресурсы, когда генератор их больше не видит.
- Перемещение каталогов и смена масок генератора — изменение прода.
- Окружения ветками — расходящиеся истории; используйте каталоги.
- Секреты в Git даже в base64 — утечка навсегда (история Git).
- Промоушен пересборкой вместо дайджеста — в prod не то, что тестировали.
- Корневое Application без finalizer'а при удалении оставляет ApplicationSet и всё, что он создал.
- CI с доступом к кластеру «на всякий случай» сводит на нет смысл pull-модели.

---

## Чеклист

- [ ] Подниму app-of-apps с корневым Application.
- [ ] Напишу ApplicationSet с генератором каталогов и объясню другие генераторы.
- [ ] Защищу окружения от каскадного удаления ApplicationSet'ом.
- [ ] Промоутну версию коммитом дайджеста.
- [ ] Выберу способ хранения секретов и аргументирую.
- [ ] Сравню Argo CD и Flux.

---

## Задание со звёздочкой

Настройте preview-окружение на каждый Pull Request:

1. Включите в Gitea Actions или вручную создавайте ветки `pr-<N>` с изменённым overlay.
2. ApplicationSet с генератором `pullRequest` (провайдер `gitea`, ⚠️ на стенде не проверялся) или `git` по веткам: Application `orders-pr-<N>` в namespace `lab-pr-<N>`, HTTPRoute `pr-<N>.lab.localhost`.
3. Закройте PR — окружение должно исчезнуть. Какие ресурсы останутся (PVC? Secret'ы?) и как их убирать?
4. Добавьте `preserveResourcesOnDeletion` и объясните, почему для preview-окружений он **не** нужен, а для prod — обязателен.

---

→ Следующая часть: **09-1. CRD и операторы** — модуль «Расширение API»: свой CRD со схемой и валидацией, что делает оператор и reconcile, CloudNativePG: кластер PostgreSQL из трёх реплик, failover при удалении primary с замером.
