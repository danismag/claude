# 07-3. Kustomize и выбор инструмента

> Модуль 7 «Пакетирование» · часть 3 из 3 · 🟡🔴 · ~1 ч чтения + ~40 мин лабы · Нужно: стенд 00-1, `kubectl` 1.36 (встроенный kustomize v5.8.1), чарт orders-api из 07-1

---

## Зачем это DevOps-у

Kustomize — второй по популярности способ собирать манифесты и основной формат у многих команд, работающих через GitOps (08-1). Он не шаблонизирует, а **патчит** обычный YAML: base + overlays по окружениям. В работе: «как сделать отличия staging и prod без копипасты», «почему поменял ConfigMap — а prod не перезапустился», «как подправить чужой Helm-чарт, не форкая его». На собеседовании: «Helm vs Kustomize», «что делает configMapGenerator».

Сквозной сценарий: те же манифесты orders-api из 00-1, разложенные на base и overlays staging/prod.

---

## 1. Модель 🟢

```
kustomize/orders-api/
  base/                     обычные манифесты + kustomization.yaml
    deployment.yaml  service.yaml  kustomization.yaml
  overlays/
    staging/                namespace, тег 2.1, флаг функции, HTTPRoute
    prod/                   namespace, 3 реплики, дайджест, ресурсы, graceful shutdown
```

`kubectl kustomize <каталог>` — собрать, `kubectl apply -k <каталог>` — собрать и применить, `kubectl diff -k` — сравнить с кластером (код 1 — есть изменения; проверено). Kustomize встроен в kubectl (у стенда — v5.8.1, `kubectl version --client`).

Base стенда:

```yaml
resources: [deployment.yaml, service.yaml]
labels:
- pairs: {app.kubernetes.io/part-of: orders}
  includeSelectors: false          # метка на объекты, но не в selector (selector неизменяем — 02-2)
configMapGenerator:
- name: orders-env
  literals: [FEATURE_DISCOUNT=off]
images:
- name: localhost:5001/orders-api
  newTag: "2.0"
```

## 2. Что умеет kustomization 🟡

| Поле | Что делает | На стенде |
|---|---|---|
| `resources` | файлы, каталоги, другие kustomization (base) | overlay ссылается на `../../base` |
| `namespace` | ставит namespace всем объектам (кроме ссылок на чужие — проверено: `parentRefs.namespace: envoy-gateway-system` не тронут) | `lab-07-3-staging` |
| `images` | меняет тег/дайджест/имя образа без патчей | staging — `2.1`, prod — `@sha256:ad4f…` |
| `replicas` | число реплик | prod — 3 |
| `labels` / `commonAnnotations` | метки и аннотации всем объектам | `part-of: orders` |
| `configMapGenerator` / `secretGenerator` | создаёт ConfigMap/Secret с **хэшем в имени** и обновляет ссылки | `orders-env-hcdt7bmb5c` |
| `patches` | strategic merge (кусок YAML) или JSON 6902 (операции по пути) | prod — ресурсы и env |
| `components` | переиспользуемые куски для нескольких overlays | |
| `helmCharts` | отрендерить Helm-чарт (с `--enable-helm`) | §5 |

Проверено — сборка overlays:

```
== staging
  FEATURE_DISCOUNT: "on"
        image: localhost:5001/orders-api:2.1
  name: orders-env-hcdt7bmb5c           ← и ConfigMap, и ссылка в Deployment
  namespace: lab-07-3-staging            ← 4 объекта
    namespace: envoy-gateway-system      ← ссылка HTTPRoute на Gateway — не тронута
== prod
  replicas: 3
        image: localhost:5001/orders-api@sha256:ad4f8fd2…
            cpu: 250m
        - name: SHUTDOWN_DELAY
      terminationGracePeriodSeconds: 40
```

Patches в prod — оба вида:

```yaml
patches:
- path: resources.yaml               # strategic merge: контейнер api находится по name, меняются только resources
- target: {kind: Deployment, name: orders-api}
  patch: |-                           # JSON 6902: добавить в конец списка, добавить поле
    - op: add
      path: /spec/template/spec/containers/0/env/-
      value: {name: SHUTDOWN_DELAY, value: "10"}
    - op: add
      path: /spec/template/spec/terminationGracePeriodSeconds
      value: 40
```

Strategic merge понимает ключи слияния списков (контейнеры — по `name`, порты — по `containerPort`); JSON 6902 работает по индексам — точнее, но ломается, если порядок элементов изменится.

## 3. configMapGenerator и перезапуск подов 🟡

Хэш в имени ConfigMap — способ Kustomize сделать конфигурацию частью шаблона пода (как `checksum/config` в Helm, 07-1). Проверено: литерал `FEATURE_DISCOUNT=on` → `half`:

```
configmap/orders-env-65k4tf7cd9 created
deployment "orders-api" successfully rolled out
ReplicaSets 1 -> 2
{"env_FEATURE_DISCOUNT": "half", …}
```

Новый ConfigMap → новое имя в Deployment → rollout; приложение видит новое значение env, хотя env из ConfigMap сам по себе не обновляется (04-1).

Обратная сторона: **старый ConfigMap остаётся** (проверено: `orders-env-65k4tf7cd9` и `orders-env-hcdt7bmb5c` оба в namespace). Это даже полезно — откат ReplicaSet'а находит свой ConfigMap. Но они копятся. Уборка — `kubectl apply -k … --prune -l app.kubernetes.io/part-of=orders` (проверено: `configmap/orders-env-hcdt7bmb5c pruned`; попутно kubectl предупреждает о `v1 Endpoints` — prune перебирает все типы) или GitOps-инструмент с prune (08-1). `--prune` с неточным селектором удаляет чужое — ставьте уникальную метку.

Без генератора (обычный `ConfigMap` в `resources`) изменение конфигурации **не** перезапускает поды — частая разница «staging заметил, prod — нет», когда в одном overlay генератор, в другом — статический файл.

## 4. Helm или Kustomize 🟡🔴

| | Helm | Kustomize |
|---|---|---|
| Модель | шаблоны + values | обычный YAML + патчи |
| Логика (условия, циклы) | да | нет (намеренно) |
| Пакеты и версии, репозитории | да (chart, OCI) | нет (Git, `resources` по URL) |
| Состояние релиза, история, откат | да (Secret'ы релиза) | нет — «состояние» в Git |
| Hooks | да | нет |
| Прозрачность «что получится» | нужно рендерить | почти то, что видишь |
| Чужие компоненты | стандарт поставки | патчить отрендеренный чарт (§5) |
| Свои сервисы, разница окружений | ок, но values-файлы растут | естественно (overlays) |

Практичный ответ — «оба»: сторонние компоненты — Helm-чартами вендора (версия + values), свои сервисы — Kustomize или свой небольшой чарт; доводка чужого чарта без форка — Kustomize поверх `helm template`. В GitOps (Argo CD) поддерживаются оба, и состояние «релиза» хранит Git, а не Helm.

Анти-рецепты: копии манифестов по окружениям (`k8s-staging/`, `k8s-prod/` — расходятся за месяц); `sed`/`envsubst` в CI вместо overlays (нет проверки, ломается на спецсимволах); форк чужого чарта ради одной правки.

## 5. Helm-чарт внутри Kustomize 🔴

```yaml
# overlays/helm-chart/kustomization.yaml
helmGlobals: {chartHome: ../../../../charts}
helmCharts:
- name: orders-api
  releaseName: shop
  valuesInline: {route: {hostname: helm.lab073.localhost}, image: {tag: "2.1"}}
# overlays/helm/kustomization.yaml
resources: [../helm-chart]
patches: [ … JSON 6902 — env SHUTDOWN_DELAY_OVERRIDE … ]
```

Проверено — три сюрприза:

1. **Нужен `--enable-helm`**, а `kubectl apply -k` его не принимает: ``must specify --enable-helm``. Рабочий путь — `kubectl kustomize --enable-helm … | kubectl apply -f -`.
2. **Ограничитель загрузки**: чарт вне каталога kustomization не читается — ``security; file '…/charts/orders-api/values.yaml' is not in or below '…/overlays/helm'``. Нужен `--load-restrictor=LoadRestrictionsNone` или чарт внутри каталога.
3. **`namespace` не применился** к объектам из `helmCharts` — ни в той же kustomization, ни в родительской (проверено на kustomize v5.8.1: у ConfigMap/Deployment/Service нет `metadata.namespace`). Без явного `kubectl apply -n lab-07-3-helm` объекты ушли бы в namespace текущего контекста. Задавайте namespace при применении или в шаблонах чарта; проверяйте вывод сборки.

Результат (проверено): Deployment `shop` с добавленной переменной `SHUTDOWN_DELAY_OVERRIDE`, `/version` отвечает `2.1`, а `helm list` в namespace **пуст** — Helm-релиза нет, хотя на объектах метки `app.kubernetes.io/managed-by: Helm`. Hooks чарта в таком режиме не выполняются как hooks. Так же работает Argo CD с Helm-чартами (08-1) — `helm list` там тоже пуст.

---

## 🔧 Лаба

### Шаг 0. Base и overlays

```bash
K=~/lab/k8s/kustomize/orders-api; mkdir -p $K/base $K/overlays/{staging,prod,helm,helm-chart}; cd $K
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
cat > overlays/prod/kustomization.yaml <<'E'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: lab-07-3-prod
resources: [../../base]
replicas:
- name: orders-api
  count: 3
images:
- name: localhost:5001/orders-api
  digest: sha256:ad4f8fd2cabaef73e735d9a623a3499270fd5f3a5d7f640719bfd0982e772465
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
kubectl kustomize overlays/staging | grep -E '^kind:|name: orders-env|image:|FEATURE|namespace:' | sort | uniq -c
kubectl kustomize overlays/prod | grep -E 'replicas:|image:|SHUTDOWN|terminationGrace|cpu: 250m'
```

Дайджест в prod — ваш `orders-api:2.0` (00-1 §4.1). Проверено: вывод в §2.

### Шаг 1. Staging и генератор

```bash
for ns in lab-07-3-staging lab-07-3-prod lab-07-3-helm; do
  kubectl create ns $ns
  kubectl -n $ns create secret generic postgres --from-literal=DATABASE_URL=postgresql://orders:orders-lab-pass@postgres.orders:5432/orders
done
kubectl apply -k overlays/staging && kubectl -n lab-07-3-staging rollout status deploy/orders-api
curl -s -H 'Host: staging.lab073.localhost' http://127.0.0.1:8088/config; echo
sed -i 's/FEATURE_DISCOUNT=on/FEATURE_DISCOUNT=half/' overlays/staging/kustomization.yaml
kubectl apply -k overlays/staging && kubectl -n lab-07-3-staging rollout status deploy/orders-api
kubectl -n lab-07-3-staging get rs; kubectl -n lab-07-3-staging get cm
curl -s -H 'Host: staging.lab073.localhost' http://127.0.0.1:8088/config; echo
kubectl apply -k overlays/staging --prune -l app.kubernetes.io/part-of=orders
kubectl -n lab-07-3-staging get cm
```

Проверено: вывод в §3 (`file` в ответе `/config` — ошибка «нет файла»: в этой base конфиг только через env; файловый ConfigMap — в 07-1).

### Шаг 2. Prod

```bash
kubectl diff -k overlays/prod > /dev/null; echo "diff exit: $?"
kubectl apply -k overlays/prod && kubectl -n lab-07-3-prod rollout status deploy/orders-api
kubectl -n lab-07-3-prod get deploy orders-api -o jsonpath='replicas={.status.readyReplicas} grace={.spec.template.spec.terminationGracePeriodSeconds} cpu={.spec.template.spec.containers[0].resources.requests.cpu}{"\n"}'
```

Проверено: `diff exit: 1`, `replicas=3 grace=40 cpu=250m`, `imageID` — нужный дайджест.

### Шаг 3. Helm-чарт внутри Kustomize

```bash
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
kubectl apply -k overlays/helm                                            # must specify --enable-helm
kubectl kustomize --enable-helm overlays/helm                             # ограничитель загрузки
kubectl kustomize --enable-helm --load-restrictor=LoadRestrictionsNone overlays/helm | grep -E 'namespace:|via-kustomize'
kubectl kustomize --enable-helm --load-restrictor=LoadRestrictionsNone overlays/helm | kubectl apply -n lab-07-3-helm -f -
kubectl -n lab-07-3-helm rollout status deploy/shop
curl -s -H 'Host: helm.lab073.localhost' http://127.0.0.1:8088/version; echo
helm list -n lab-07-3-helm
```

Проверено: вывод в §5.

### Уборка

```bash
kubectl delete ns lab-07-3-staging lab-07-3-prod lab-07-3-helm
```

Каталог `~/lab/k8s/kustomize/orders-api` остаётся — он источник для Argo CD в 08-1.

---

## 🔥 Кейс из прода: «поменяли ConfigMap — staging заметил, prod нет»

**Контекст.** Флаг функции `FEATURE_DISCOUNT` в ConfigMap. В staging-overlay ConfigMap создавался `configMapGenerator`, в prod — лежал обычным файлом в `resources` («чтобы имя не менялось — на него ссылается мониторинг»). Флаг выключили в обоих overlays одним MR. В staging поды перезапустились и функция выключилась; в prod ConfigMap обновился, а поды продолжали работать со старым env — скидка действовала ещё сутки, до плановой перезагрузки узлов.

**Разбор.**
1. Generator меняет имя объекта (хэш) → меняется шаблон пода → rollout (шаг 1 лабы: `ReplicaSets 1 -> 2`). Статический ConfigMap меняет только содержимое; env подов фиксирован с момента старта (04-1).
2. В CI проверяли «apply прошёл», а не «поды видят новое значение».

**Фикс.**
- Одинаковый механизм во всех overlays: generator; мониторинг перевели со ссылки по имени на метку.
- Где имя должно быть стабильным — `generatorOptions: {disableNameSuffixHash: true}` **плюс** аннотация с хэшем содержимого в шаблоне пода (патчем) или перезапуск через `rollout restart` в пайплайне.
- Проверка после деплоя: `/config` (или аналог) отдаёт ожидаемое значение.

**Что запомнить.**
- Без хэша в имени изменение ConfigMap не перезапускает поды.
- Overlays не должны отличаться **механизмом**, только значениями.
- Проверять результат на подах, а не факт apply.

---

## 💼 Вопросы с собеседования

### 🟢 Junior

**1. Что такое base и overlay в Kustomize?**
Base — общие манифесты и kustomization; overlay — каталог, который ссылается на base и добавляет отличия окружения (namespace, образы, реплики, патчи). Сборка — `kubectl kustomize`, применение — `kubectl apply -k`.

**2. Чем Kustomize отличается от Helm?**
Kustomize патчит обычный YAML без шаблонов и логики, без пакетов и релизов; Helm — шаблоны с values, пакеты с версиями, история релизов, hooks, откат.

### 🟡 Middle

**3. Что делает configMapGenerator и зачем хэш в имени?**
Создаёт ConfigMap из литералов/файлов с суффиксом-хэшем содержимого и подставляет новое имя во все ссылки. Изменение содержимого → новое имя → изменение шаблона пода → rollout. Старые ConfigMap остаются — убирать prune'ом.

**4. Strategic merge patch или JSON 6902?**
Strategic merge — кусок YAML, сливается с учётом ключей списков (контейнеры по имени); удобно и читаемо. JSON 6902 — операции по пути (add/remove/replace/test), точно, но по индексам списков — ломается при перестановке элементов. Удалять поле проще JSON 6902.

**5. Когда выбрать Helm, а когда Kustomize?**
Сторонние компоненты — Helm-чарты вендора; свои сервисы с отличиями по окружениям — Kustomize (или небольшой свой чарт); доводка чужого чарта без форка — Kustomize поверх рендера. В GitOps оба работают, состояние — в Git.

### 🔴 Senior

**6. Как подправить чужой Helm-чарт, не форкая его?**
Kustomize `helmCharts` (или `helm template` + Kustomize, или post-renderer Helm) и патчи поверх. Учесть: `--enable-helm` и ограничитель загрузки, hooks не выполняются как hooks, `helm list` пуст, `namespace` может не примениться к сгенерированным объектам — проверять вывод сборки.

**7. Почему `--prune` опасен и как его безопасно использовать?**
Удаляет объекты кластера, совпавшие с селектором, но отсутствующие в сборке; неточный селектор удаляет чужое. Уникальная метка набора (или ApplySet), dry-run перед prune; в GitOps prune делает инструмент с учётом владения.

---

## ⚠️ Подводные камни

- Статический ConfigMap в одном overlay и генератор в другом — разное поведение при изменениях.
- Старые ConfigMap от генератора копятся без prune.
- `labels` с `includeSelectors: true` (как у старого `commonLabels`) меняют selector — Deployment не обновится (selector неизменяем).
- JSON 6902 по индексу ломается при изменении порядка элементов.
- `kubectl apply -k` не умеет `--enable-helm`.
- Чарт вне каталога kustomization требует `--load-restrictor=LoadRestrictionsNone`.
- `namespace` может не примениться к объектам из `helmCharts` — проверяйте вывод.
- Объекты из `helmCharts` не являются Helm-релизом; hooks не работают как hooks.
- `--prune` с неточной меткой удаляет чужие объекты.

---

## Чеклист

- [ ] Разложу манифесты на base и overlays без копипасты.
- [ ] Использую `images`, `replicas`, `namespace`, `labels` вместо патчей, где можно.
- [ ] Напишу strategic merge и JSON 6902 патчи и объясню разницу.
- [ ] Настрою configMapGenerator и уберу старые ConfigMap prune'ом.
- [ ] Подправлю Helm-чарт через Kustomize и учту его ловушки.
- [ ] Аргументирую выбор Helm или Kustomize.

---

## Задание со звёздочкой

Соберите `components` для общих вещей:

1. Компонент `components/graceful` — preStop sleep 5, `terminationGracePeriodSeconds: 30`, startupProbe (02-5).
2. Компонент `components/restricted` — `securityContext` из 06-2 и `emptyDir` на `/tmp`.
3. Подключите оба в prod, только `graceful` — в staging. Убедитесь, что prod проходит `pod-security.kubernetes.io/enforce=restricted` (dry-run, 06-2).
4. Сравните с тем, как то же сделали бы в Helm (values-флаги и условия в шаблоне): что читаемее для ревью?

---

→ Следующая часть: **08-1. Argo CD** — модуль «GitOps»: Argo CD и Gitea в кластере, Application из каталога Kustomize, sync, self-heal и prune, вечный OutOfSync от HPA и `ignoreDifferences`, откат через Git.
