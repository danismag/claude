# 08-1. Argo CD

> Модуль 8 «GitOps» · часть 1 из 2 · 🟢🟡🔴 · ~1,5 ч чтения + ~1,5 ч лабы (установка + ожидания опроса Git) · Нужно: стенд 00-1, каталог Kustomize из 07-3. Argo CD v3.5.5 и Gitea 1.27.0 ставятся в лабе и **остаются до конца 08-2**.

---

## Зачем это DevOps-у

GitOps — модель, в которой кластер сам приводит себя к состоянию из Git: CI собирает образ и меняет манифест, а применяет его агент в кластере (pull-модель, курс `cicd` 05-3). В работе с Argo CD повторяются одни и те же вопросы: «почему приложение OutOfSync, хотя никто ничего не менял», «я поправил руками — а оно откатилось», «как откатить релиз», «почему изменение из Git не доехало». На собеседовании: «push vs pull деплой», «что такое drift», «как откатиться в GitOps».

Сквозной сценарий: overlay staging orders-api из 07-3 переезжает в Git-репозиторий в Gitea внутри кластера, и деплой делает Argo CD.

---

## 1. Модель 🟢

```
Git (lab/orders-gitops)            Argo CD (namespace argocd)                  кластер
  apps/orders-api/overlays/staging ─► repo-server: клонирует, рендерит      ─► application-controller:
                                       (Kustomize/Helm/plain)                    сравнивает «как в Git» и «как в кластере»,
                                                                                 применяет (sync), следит за здоровьем
```

| Компонент | Что делает |
|---|---|
| `argocd-repo-server` | клонирует репозитории, рендерит манифесты (Kustomize, Helm, plain YAML, плагины); кэш — в Redis |
| `argocd-application-controller` | сравнение (diff), sync, health; StatefulSet, шардируется по кластерам |
| `argocd-server` | API и UI |
| `argocd-applicationset-controller` | генерирует Application из шаблонов (08-2) |
| `argocd-redis` | кэш рендеров и состояния |
| `argocd-dex-server` | SSO |

**Application** — объект «вот источник в Git → вот куда в кластере»:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: {name: orders-staging, namespace: argocd}
spec:
  project: default
  source:
    repoURL: http://gitea.gitea.svc:3000/lab/orders-gitops.git
    targetRevision: main
    path: apps/orders-api/overlays/staging
  destination: {server: https://kubernetes.default.svc, namespace: lab-07-3-staging}
  syncPolicy:
    automated: {prune: true, selfHeal: true}
```

Два независимых статуса: **sync** (`Synced` / `OutOfSync` — совпадает ли кластер с Git) и **health** (`Healthy` / `Progressing` / `Degraded` / `Missing` — работает ли то, что в кластере). `Synced/Degraded` — применили, но не работает; `OutOfSync/Healthy` — работает, но не то, что в Git.

## 2. Sync, self-heal, prune 🟡

| Настройка | Без неё | С ней |
|---|---|---|
| `automated` | sync — вручную (UI/CLI) | при расхождении Argo CD применяет сам |
| `selfHeal` | ручная правка в кластере → OutOfSync, висит | правка откатывается к Git |
| `prune` | объект удалили из Git → остаётся в кластере (OutOfSync) | удаляется |

Проверено:

```
self-heal: replicas 4 -> 1 after 2s                                  ← kubectl scale откатился за 2 с
{"automated":true} successfully synced (all tasks run)
prune: HTTPRoute deleted after 1s (rev 3816a67)                      ← убрали route.yaml из kustomization
```

**Доставка изменения из Git** — опросом: по умолчанию раз в 180 с (`timeout.reconciliation` в `argocd-cm`, пусто = дефолт) с разбросом. Проверено: коммит `9ed2707` подхвачен через **178 с** без вмешательства. Ускорить — webhook из Git-сервера в Argo CD (Gitea/GitLab/GitHub умеют) или принудительный refresh: аннотация `argocd.argoproj.io/refresh=normal` (с ней изменения в лабе подхватывались за 1–2 с).

Ручные правки в кластере при `selfHeal` бессмысленны — это и защита (никто не «подкрутит» прод мимо ревью), и неудобство в инциденте. Экстренная правка: выключить auto-sync у Application (или поставить `argocd.argoproj.io/sync-options: …` / пауза), поправить, затем перенести правку в Git и включить обратно.

## 3. Вечный OutOfSync 🟡🔴

Самая частая жалоба: «OutOfSync каждые несколько минут, хотя никто ничего не меняет». Почти всегда — **второй владелец поля** в кластере. Проверено: в overlay добавили HPA с `minReplicas: 3`, а в base у Deployment `replicas: 1`:

```
t=+0s  spec.replicas=1 app=Synced
t=+28s spec.replicas=3 app=OutOfSync      ← HPA поднял до minReplicas
t=+30s spec.replicas=1 app=Synced          ← self-heal вернул значение из Git
t=+43s spec.replicas=3 app=OutOfSync
t=+82s spec.replicas=1 app=Synced
t=+87s spec.replicas=3 app=OutOfSync

ScalingReplicaSet   Scaled down replica set orders-api-5f74d848b8 from 3 to 1
SuccessfulRescale   New size: 3; reason: Current number of replicas below Spec.MinReplicas
ScalingReplicaSet   Scaled up replica set orders-api-5f74d848b8 from 1 to 3
```

Пила: поды создаются и убиваются каждые 15–40 секунд. Это та же война за `replicas`, что у `kubectl apply` с HPA (01-3), только автоматическая и вечная.

Фикс — два варианта:

1. Убрать `replicas` из манифеста (лучший): владельцем поля остаётся только HPA.
2. Сказать Argo CD игнорировать поле **и** не перезаписывать его при sync:

```yaml
spec:
  ignoreDifferences:
  - {group: apps, kind: Deployment, jsonPointers: [/spec/replicas]}
  syncPolicy:
    syncOptions: [RespectIgnoreDifferences=true]    # без этого поле всё равно перезапишется при sync
```

Проверено: после патча — 90 секунд стабильно `spec.replicas=3 app=Synced`.

Другие частые источники вечного OutOfSync:

| Источник | Что расходится | Решение |
|---|---|---|
| мутирующие webhook'и (инжекторы sidecar'ов) | контейнеры, аннотации | `ignoreDifferences` по пути или `managedFieldsManagers` |
| дефолты API, которых нет в Git (`protocol: TCP`, `imagePullPolicy`) | поля «по умолчанию» | обычно Argo CD нормализует; иначе — явно прописать в Git |
| cert-manager/контроллеры, дописывающие `caBundle` | webhook-конфигурации, CRD | `ignoreDifferences` по `jqPathExpressions` |
| `kubectl edit` при выключенном selfHeal | любое поле | вернуть через Git |
| генераторы с недетерминированным выводом (случайные пароли в Helm, `now`) | Secret'ы, аннотации | убрать недетерминизм; пароли — снаружи (08-2) |

`ignoreDifferences` — точечно: путь и, по возможности, менеджер поля (`managedFieldsManagers: [kube-controller-manager]`), а не «игнорировать весь Deployment».

## 4. Откат 🟡

В GitOps откат — **изменение Git**: `git revert` проблемного коммита. Проверено:

```
25bda53 Revert "staging: route back + HPA min 3"
0bf8387 staging: route back + HPA min 3
3816a67 staging: drop route
HPA removed by revert after 1s; app=Synced/Healthy
```

Откат в UI Argo CD (History and Rollback) возможен только при выключенном auto-sync и работает как временная мера: следующий sync вернёт то, что в Git. `kubectl rollout undo` при `selfHeal` откатится обратно за секунды (как scale в §2). Поэтому процедура инцидента в GitOps: revert в Git (через MR с упрощённым ревью или break-glass, курс `cicd` 05-3) → refresh → проверка.

## 5. Порядок, hooks, health 🟡🔴

- **Sync waves**: аннотация `argocd.argoproj.io/sync-wave: "-1"` — объект применяется раньше остальных (CRD до CR, namespace и Secret'ы до Deployment, миграция до приложения).
- **Hooks**: `argocd.argoproj.io/hook: PreSync|Sync|PostSync|SyncFail` — Job'ы вокруг sync. Helm-hooks чартов Argo CD транслирует в свои (07-1 §6).
- **Health** — встроенные проверки для стандартных типов (Deployment готов, PVC Bound, Ingress с адресом) и Lua-скрипты для CRD. Application `Healthy` только если здоровы все его ресурсы; `Progressing` бесконечно — часто CRD без health-проверки или Service типа LoadBalancer без адреса (как в kind).
- **Projects** (`AppProject`) — какие репозитории, кластеры, namespace'ы и типы ресурсов доступны набору приложений; основа мультитенантности Argo CD. `default` разрешает всё — в проде так нельзя.
- **Масштаб**: один application-controller обрабатывает все приложения; на сотнях кластеров и тысячах Application — шардирование контроллера, настройка `--status-processors`/`--operation-processors`, отдельные инстансы Argo CD.

---

## 🔧 Лаба

### Шаг 0. Gitea в кластере

```bash
kubectl config use-context kind-lab
kubectl create ns gitea
kubectl -n gitea apply -f - <<'EOF'
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
        volumeMounts: [{name: data, mountPath: /var/lib/gitea}, {name: data, mountPath: /etc/gitea, subPath: conf}]
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
kubectl -n gitea rollout status deploy/gitea --timeout=300s
GP=$(head -c 18 /dev/urandom | base64 | tr -d '/+=')
printf 'GITEA_USER=lab\nGITEA_PASS=%s\n' "$GP" > ~/lab/k8s/gitea.env; chmod 600 ~/lab/k8s/gitea.env
kubectl -n gitea exec deploy/gitea -- gitea admin user create --admin --username lab --password "$GP" --email lab@lab.local --must-change-password=false
unset GP; . ~/lab/k8s/gitea.env
curl -s http://git.localhost:8088/api/v1/version
```

Проверено: `New user 'lab' has been successfully created!`, `{"version":"1.27.0"}`. Пароль — только в `~/lab/k8s/gitea.env`.

### Шаг 1. Репозиторий с манифестами

```bash
curl -s -u "$GITEA_USER:$GITEA_PASS" -H 'Content-Type: application/json' \
  -d '{"name":"orders-gitops","default_branch":"main","auto_init":false}' http://git.localhost:8088/api/v1/user/repos | jq -r .full_name
R=~/lab/k8s/gitops; rm -rf $R; mkdir -p $R/apps
cp -r ~/lab/k8s/kustomize/orders-api $R/apps/
rm -rf $R/apps/orders-api/overlays/helm $R/apps/orders-api/overlays/helm-chart
cd $R && git init -q -b main && git add -A && git commit -qm "orders-api: base + overlays"
git push -q "http://$GITEA_USER:$GITEA_PASS@git.localhost:8088/lab/orders-gitops.git" main
gpush() { git -C ~/lab/k8s/gitops add -A && git -C ~/lab/k8s/gitops commit -qm "$1" && \
  git -C ~/lab/k8s/gitops push -q "http://$GITEA_USER:$GITEA_PASS@git.localhost:8088/lab/orders-gitops.git" main && \
  git -C ~/lab/k8s/gitops rev-parse --short HEAD; }
```

Проверено: `lab/orders-gitops`, ветка `main`. Агент выполнял git в контейнере `alpine/git` в сети kind на имя `gitea.lab` — имена `*.localhost` git и curl резолвят в `127.0.0.1` сами, и `--add-host` для них не работает; у читателя `git.localhost:8088` с хоста работает напрямую. Пароль в URL — для стенда; в работе — credential helper или токен.

### Шаг 2. Argo CD

```bash
kubectl create ns argocd
kubectl apply -n argocd --server-side --force-conflicts -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.5.5/manifests/install.yaml
kubectl -n argocd rollout status deploy/argocd-server --timeout=600s
kubectl -n argocd rollout status deploy/argocd-repo-server --timeout=600s
kubectl -n argocd get pods
```

Проверено: всё, кроме Redis и Dex, поднялось за 54 с. Образ `public.ecr.aws/docker/library/redis:8.2.3-alpine` не скачался: `toomanyrequests: Rate exceeded` (лимит анонимных скачиваний ECR Public), после чего repo-server не мог рендерить: `ComparisonError … context deadline exceeded`. Обход — тот же официальный образ с Docker Hub:

```bash
docker pull redis:8.2.3-alpine
docker tag redis:8.2.3-alpine public.ecr.aws/docker/library/redis:8.2.3-alpine
kind load docker-image public.ecr.aws/docker/library/redis:8.2.3-alpine --name lab
kubectl -n argocd delete pod -l app.kubernetes.io/name=argocd-redis
kubectl -n argocd rollout status deploy/argocd-redis
```

`server-side` нужен из-за размера CRD (аннотация `last-applied-configuration` не помещается в 256 КБ — 01-3). UI (по желанию, ⚠️ в среде агента не открывался): `kubectl -n argocd port-forward svc/argocd-server 8443:443`, логин `admin`, пароль — `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d`.

### Шаг 3. Application

```bash
kubectl create ns lab-07-3-staging
kubectl -n lab-07-3-staging create secret generic postgres \
  --from-literal=DATABASE_URL=postgresql://orders:orders-lab-pass@postgres.orders:5432/orders   # секрет — не из Git
kubectl apply -f - <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: {name: orders-staging, namespace: argocd}
spec:
  project: default
  source:
    repoURL: http://gitea.gitea.svc:3000/lab/orders-gitops.git
    targetRevision: main
    path: apps/orders-api/overlays/staging
  destination: {server: https://kubernetes.default.svc, namespace: lab-07-3-staging}
  syncPolicy:
    automated: {prune: true, selfHeal: true}
EOF
until [ "$(kubectl -n argocd get app orders-staging -o jsonpath='{.status.sync.status}/{.status.health.status}')" = "Synced/Healthy" ]; do sleep 3; done
kubectl -n argocd get app orders-staging -o jsonpath='{range .status.resources[*]}{.kind}/{.name} {.status}{"\n"}{end}'
```

Проверено: `Synced/Healthy rev=641d5184…`, четыре ресурса `Synced`. `refresh() { kubectl -n argocd annotate app orders-staging argocd.argoproj.io/refresh=normal --overwrite; }` — пригодится дальше.

### Шаг 4. Self-heal и опрос Git

```bash
kubectl -n lab-07-3-staging scale deploy orders-api --replicas=4
for i in $(seq 1 30); do r=$(kubectl -n lab-07-3-staging get deploy orders-api -o jsonpath='{.spec.replicas}'); [ "$r" = 1 ] && break; sleep 1; done; echo "replicas=$r after ${i}s"
sed -i 's/newTag: "2.1"/newTag: "2.0"/' ~/lab/k8s/gitops/apps/orders-api/overlays/staging/kustomization.yaml
REV=$(gpush "staging: 2.0"); t0=$(date +%s)
until kubectl -n argocd get app orders-staging -o jsonpath='{.status.sync.revision}' | grep -q "^$REV"; do sleep 5; done
echo "picked after $(( $(date +%s)-t0 ))s"
```

Проверено: 2 с и 178 с (§2).

### Шаг 5. Prune и вечный OutOfSync

```bash
O=~/lab/k8s/gitops/apps/orders-api/overlays/staging
sed -i 's|resources: \[../../base, route.yaml\]|resources: [../../base]|' $O/kustomization.yaml
gpush "staging: drop route"; refresh
sleep 5; kubectl -n lab-07-3-staging get httproute                    # пусто — prune
cat > $O/hpa.yaml <<'E'
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata: {name: orders-api}
spec:
  scaleTargetRef: {apiVersion: apps/v1, kind: Deployment, name: orders-api}
  minReplicas: 3
  maxReplicas: 6
  metrics: [{type: Resource, resource: {name: cpu, target: {type: Utilization, averageUtilization: 70}}}]
E
sed -i 's|resources: \[../../base\]|resources: [../../base, route.yaml, hpa.yaml]|' $O/kustomization.yaml
gpush "staging: route back + HPA min 3"; refresh; sleep 20
prev=""; for i in $(seq 1 45); do
  s="spec.replicas=$(kubectl -n lab-07-3-staging get deploy orders-api -o jsonpath='{.spec.replicas}') app=$(kubectl -n argocd get app orders-staging -o jsonpath='{.status.sync.status}')"
  [ "$s" != "$prev" ] && echo "t=+$((i*2))s $s" && prev=$s; sleep 2; done
```

Проверено: вывод в §3 — пила 1↔3.

### Шаг 6. Фикс и откат

```bash
kubectl -n argocd patch app orders-staging --type=merge -p '{"spec":{"ignoreDifferences":[{"group":"apps","kind":"Deployment","jsonPointers":["/spec/replicas"]}],"syncPolicy":{"automated":{"prune":true,"selfHeal":true},"syncOptions":["RespectIgnoreDifferences=true"]}}}'
# повторите цикл наблюдения из шага 5 — стабильно replicas=3, Synced
git -C ~/lab/k8s/gitops revert --no-edit HEAD
git -C ~/lab/k8s/gitops push -q "http://$GITEA_USER:$GITEA_PASS@git.localhost:8088/lab/orders-gitops.git" main
refresh; sleep 5; kubectl -n lab-07-3-staging get hpa,httproute
kubectl -n argocd get app orders-staging -o jsonpath='{.status.sync.status}/{.status.health.status}{"\n"}'
```

Проверено: §3 и §4. `ignoreDifferences` здесь — в объекте Application в кластере; в работе он живёт в Git вместе с Application (08-2: app-of-apps).

### Уборка

Argo CD, Gitea и репозиторий нужны в 08-2 — не удаляйте их. Удалите только приложение:

```bash
kubectl -n argocd delete app orders-staging
kubectl delete ns lab-07-3-staging
```

Удаление Application **не** удаляет ресурсы в кластере, если у него нет finalizer'а `resources-finalizer.argocd.argoproj.io` (каскадное удаление — 01-3 §5). Проверено: у `orders-staging` finalizer'ов не было, после удаления Application Deployment и Service остались — поэтому namespace удаляем явно. Полная уборка Argo CD и Gitea — в конце 08-2.

---

## 🔥 Кейс из прода: «Argo CD показывает OutOfSync каждые 3 минуты, а реплики пилит»

**Контекст.** orders-api деплоится через Argo CD с auto-sync и self-heal. В Git у Deployment `replicas: 3`, к нему добавили HPA (min 3, max 10). В часы нагрузки приложение каждые несколько минут становится OutOfSync, Argo CD синхронизирует — и реплики падают с 8 до 3, через минуту HPA снова поднимает их. На графике задержек — пила, в истории Argo CD — десятки синхронизаций в час.

**Разбор.**
1. Diff приложения — расхождение только в `spec.replicas`: в Git 3, в кластере 8.
2. Поле `replicas` — общее для двух владельцев: Argo CD (из Git) и HPA (через подресурс `scale`). Self-heal возвращает «желаемое из Git», HPA — своё. Воспроизведение — шаг 5 лабы.
3. Тот же класс проблемы дают мутирующие webhook'и и контроллеры, дописывающие поля (§3, таблица).

**Фикс.**
- Убрать `replicas` из манифеста в Git; при создании Deployment получит 1 реплику, HPA сразу поднимет до `minReplicas`.
- Если чарт обязательно рендерит `replicas` — `ignoreDifferences` по `/spec/replicas` и `RespectIgnoreDifferences=true` (шаг 6), иначе поле всё равно перезапишется при sync.
- Для мутируемых полей — `ignoreDifferences` с `managedFieldsManagers`, а не целые объекты.

**Что запомнить.**
- OutOfSync без изменений в Git — почти всегда второй владелец поля в кластере.
- Self-heal + HPA + `replicas` в манифесте = пила реплик.
- Игнорировать нужно точечно: поле и владельца, а не весь ресурс.

---

## 💼 Вопросы с собеседования

### 🟢 Junior

**1. Чем pull-модель (GitOps) отличается от push-деплоя из CI?**
В push CI имеет доступ к кластеру и применяет манифесты сам. В pull агент в кластере (Argo CD, Flux) читает Git и приводит кластер к нему: кластеру не нужно отдавать креды CI, состояние описано в Git, дрейф обнаруживается и исправляется, откат — revert.

**2. Что значат Synced/OutOfSync и Healthy/Degraded?**
Sync — совпадает ли кластер с Git; health — работают ли ресурсы. Это независимые оси: можно быть Synced и Degraded (применили, не работает) или OutOfSync и Healthy (работает, но не то, что в Git).

### 🟡 Middle

**3. Что делают selfHeal и prune?**
SelfHeal откатывает ручные изменения в кластере к Git (на стенде — 2 с); prune удаляет из кластера объекты, удалённые из Git. Без них дрейф только показывается.

**4. Почему изменение из Git доезжает через несколько минут?**
Argo CD опрашивает репозиторий раз в 180 с (`timeout.reconciliation`), на стенде — 178 с. Быстрее — webhook из Git-сервера или refresh.

**5. Как откатиться в GitOps?**
`git revert` проблемного коммита (через быстрый MR/break-glass) — Argo CD применит предыдущее состояние. Откат в UI или `kubectl rollout undo` при auto-sync и self-heal не держится.

### 🔴 Senior

**6. Приложение вечно OutOfSync. Как разбираетесь?**
Diff в Argo CD — какое поле расходится; `managedFields` объекта — кто им владеет (HPA, webhook, контроллер). Затем: убрать поле из Git, если владелец другой; иначе `ignoreDifferences` (точечно, с `managedFieldsManagers`) и `RespectIgnoreDifferences=true`; недетерминированные генераторы — убрать.

**7. Как устроить права в Argo CD для 30 команд?**
AppProject на команду: разрешённые репозитории, кластеры/namespace'ы, типы ресурсов (без cluster-scoped), роли проекта с SSO-группами; Application только в своих проектах; запрет `default`-проекта. Приложения — через ApplicationSet/app-of-apps из Git (08-2).

**8. Что ломается в Argo CD при росте числа приложений?**
Один application-controller и repo-server становятся узким местом: долгие рендеры (Helm/Kustomize с большими зависимостями), память контроллера, частые refresh'и. Решения: шардирование контроллера, масштабирование repo-server, кэш в Redis, webhook вместо частого опроса, несколько инстансов Argo CD.

---

## ⚠️ Подводные камни

- Поля, которыми владеет кто-то ещё (HPA, webhook'и), в Git + selfHeal = вечный OutOfSync и пила.
- `ignoreDifferences` без `RespectIgnoreDifferences=true` не защищает поле при sync.
- Изменения из Git — с задержкой до 3 минут без webhook.
- Ручные правки и `rollout undo` при selfHeal откатываются за секунды.
- Удаление Application без finalizer'а не удаляет ресурсы.
- Проект `default` разрешает всё.
- Секреты в Git — нельзя; Argo CD показывает их в diff (08-2).
- Образы самого Argo CD с `public.ecr.aws` и `ghcr.io` упираются в лимиты и медленную сеть — зеркалируйте.
- CRD большие: устанавливать с `--server-side`.

---

## Чеклист

- [ ] Объясню pull-модель, компоненты Argo CD, sync и health.
- [ ] Создам Application из каталога Kustomize с auto-sync, self-heal, prune.
- [ ] Объясню задержку доставки и ускорю её.
- [ ] Найду и устраню вечный OutOfSync.
- [ ] Откачу релиз через Git.
- [ ] Расскажу про sync waves, hooks, health и AppProject.

---

## Задание со звёздочкой

Подключите сквозной сценарий к Argo CD целиком:

1. Перенесите в репозиторий `~/lab/k8s/orders-api/k8s/` (orders-api + PostgreSQL) как `apps/orders-prod/`; секрет `postgres` оставьте вне Git.
2. Создайте Application `orders` с `syncPolicy.automated` **без** prune (БД!) и с `sync-wave` для PostgreSQL раньше orders-api.
3. Настройте webhook Gitea → `http://argocd-server.argocd.svc/api/webhook` и измерьте время доставки коммита.
4. Почему для StatefulSet БД опасно `prune: true` вместе с удалением из Git? Что защитит PVC (02-3, 04-2)?

---

→ Следующая часть: **08-2. GitOps в масштабе** — app-of-apps и ApplicationSet на два окружения, структура репозиториев, промоушен коммитом дайджеста, секреты в GitOps (SOPS, External Secrets, Sealed Secrets), сравнение с Flux; в конце — уборка Argo CD и Gitea.
