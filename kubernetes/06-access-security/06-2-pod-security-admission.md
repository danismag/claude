# 06-2. Pod Security и admission

> Модуль 6 «Доступ и безопасность» · часть 2 из 2 · 🟡🔴 · ~1 ч чтения + ~40 мин лабы · Нужно: стенд 00-1. Глубже — курс `security` (hardening узлов, supply chain, политики образов).

> Отличие от плана: часть 06-1 «Аутентификация и RBAC» в этой версии курса не опубликована (см. `00-plan.md`); основы RBAC, ServiceAccount и токенов — в курсе `security`. Здесь — как кластер проверяет, **что** можно запускать.

---

## Зачем это DevOps-у

Кластер по умолчанию запускает любой под, который прошёл RBAC: от root, с привилегиями, с сетью узла, с образом `:latest`. Pod Security Admission и политики admission — способ сказать «в этом namespace так нельзя» до того, как под попадёт на узел. В работе это выглядит так: деплой падает с `violates PodSecurity "restricted"`, и нужно быстро понять, какие поля добавить. На собеседовании: «что такое Pod Security Standards», «как запретить latest», «чем ValidatingAdmissionPolicy отличается от вебхука».

Сквозной сценарий: проверим, готов ли namespace `orders` к уровню `restricted`, и соберём для orders-api `securityContext`, который его проходит.

---

## 1. securityContext: из чего состоит «безопасный под» 🟡

| Поле | Уровень | Что даёт |
|---|---|---|
| `runAsNonRoot: true`, `runAsUser` | под/контейнер | процесс не root (у orders-api в образе `USER 10001`) |
| `allowPrivilegeEscalation: false` | контейнер | `no_new_privs`: процесс не получит больше прав через setuid-бинарники |
| `capabilities: {drop: [ALL]}` | контейнер | без Linux capabilities |
| `seccompProfile: {type: RuntimeDefault}` | под/контейнер | фильтр системных вызовов рантайма |
| `readOnlyRootFilesystem: true` | контейнер | корневая ФС только для чтения; запись — в смонтированные тома |
| `privileged`, `hostNetwork`, `hostPID`, `hostPath` | под/контейнер | **не использовать** в прикладных подах |

Проверено — orders-api с полным набором (лаба, шаг 1):

```
uid 10001 {"version": "2.0", "pod": "hardened"}
write to /srv: OSError                 ← корень только для чтения
write to /tmp: ok                      ← emptyDir для временных файлов
CapEff:	0000000000000000               ← ни одной capability
NoNewPrivs:	1
Seccomp:	2                              ← фильтр seccomp включён
```

Приложение работает без изменений кода; потребовался только `emptyDir` для `/tmp`. Большинство сервисов переводятся так же: найти, куда они пишут (кэш, `/tmp`, pid-файлы), и дать туда тома.

## 2. Pod Security Standards и Admission 🟡

Три стандарта (уровня):

| Уровень | Смысл |
|---|---|
| `privileged` | без ограничений (системные компоненты: CNI, CSI, агенты узлов) |
| `baseline` | запрещено очевидно опасное: host-namespaces, привилегированные контейнеры, hostPath, лишние capabilities |
| `restricted` | плюс обязательный «безопасный под» из §1 |

Встроенный контроллер Pod Security Admission включается **метками namespace**, в трёх режимах:

| Метка | Что делает |
|---|---|
| `pod-security.kubernetes.io/enforce=<уровень>` | отклоняет под |
| `…/warn=<уровень>` | пропускает, но пишет предупреждение клиенту (видно в kubectl и в CI) |
| `…/audit=<уровень>` | пропускает, пишет аннотацию в аудит-лог |
| `…/<режим>-version=v1.36` или `latest` | версия стандарта |

Проверено: под без `securityContext` в namespace с `enforce=restricted`:

```
Error from server (Forbidden): pods "plain" is forbidden: violates PodSecurity "restricted:latest": allowPrivilegeEscalation != false (container "plain" must set securityContext.allowPrivilegeEscalation=false), unrestricted capabilities (container "plain" must set securityContext.capabilities.drop=["ALL"]), runAsNonRoot != true (pod or container "plain" must set securityContext.runAsNonRoot=true), seccompProfile (pod or container "plain" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
```

Сообщение — готовый список того, что добавить. Под с `hostNetwork: true` в namespace с `enforce=baseline` (проверено): `violates PodSecurity "baseline:latest": host namespaces (hostNetwork=true)`.

Режимы вместе — путь внедрения без аварий (проверено, namespace с `enforce=baseline, warn=restricted, audit=restricted`): обычный под создаётся с предупреждением `Warning: would violate PodSecurity "restricted:latest": …` — команды видят, что надо поправить, ничего не ломается.

Перед ужесточением существующего namespace — **dry-run** (проверено на `orders`):

```
$ kubectl label --dry-run=server --overwrite ns orders pod-security.kubernetes.io/enforce=restricted
Warning: existing pods in namespace "orders" violate the new PodSecurity enforce level "restricted:latest"
Warning: orders-api-7f45b67f95-c47t8 (and 2 other pods): allowPrivilegeEscalation != false, unrestricted capabilities, runAsNonRoot != true, seccompProfile
namespace/orders labeled (server dry run)
```

Работающие поды enforce не убивает, но после следующего rollout'а новые поды не создадутся — Deployment будет «зелёным», а ReplicaSet — с `FailedCreate`, как при квоте (05-1 §6).

Что PSA не умеет: исключения по образам и пользователям тоньше, чем на весь namespace (есть только глобальные exemptions в конфиге apiserver), проверки чего-то кроме полей пода (теги образов, реестры, метки, ресурсы). Для этого — политики.

## 3. ValidatingAdmissionPolicy: свои правила на CEL 🟡🔴

Встроенный механизм (stable с 1.30): правила на языке CEL выполняются **внутри apiserver**, без отдельного сервиса-вебхука. Два объекта — политика (что проверять) и привязка (где и как применять).

```yaml
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
        (c.image.split('/')[size(c.image.split('/'))-1].contains(':') && !c.image.endsWith(':latest')))
    messageExpression: "'образ без тега или с :latest запрещён: ' + object.spec.containers.map(c, c.image).join(', ')"
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata: {name: no-latest-tag}
spec:
  policyName: no-latest-tag
  validationActions: [Warn]          # затем [Deny]; есть ещё Audit
  matchResources:
    namespaceSelector: {matchLabels: {policy.lab/images: pinned}}
```

Тег ищется в **последнем** сегменте пути — иначе двоеточие порта реестра (`localhost:5001/…`) сойдёт за тег. Проверено:

```
--- Warn
Warning: Validation failed for ValidatingAdmissionPolicy 'no-latest-tag' with binding 'no-latest-tag': образ без тега или с :latest запрещён: busybox
--- Deny
busybox                       -> … ValidatingAdmissionPolicy 'no-latest-tag' with binding 'no-latest-tag' denied request
busybox:latest                -> … denied request
busybox:1.37                  -> pod/… created
localhost:5001/orders-api:2.0 -> pod/… created
localhost:5001/orders-api     -> … denied                   ← порт реестра не принят за тег
localhost:5001/orders-api@sha256:ad4f8fd… -> pod/… created
```

Порядок внедрения тот же, что у PSA: `Warn` → смотрим, кого задевает → `Deny`. Привязка через `namespaceSelector` позволяет включать правило по namespace'ам.

| | ValidatingAdmissionPolicy | Admission webhook (Kyverno, OPA Gatekeeper, свой) |
|---|---|---|
| Где выполняется | в apiserver | отдельный сервис, вызов по HTTPS |
| Отказ сервиса | не бывает | `failurePolicy: Fail` → кластер не принимает изменения (09-2) |
| Задержка | микросекунды | сетевой вызов |
| Возможности | проверки объекта и параметров (CEL) | плюс мутация, генерация объектов, обращение к внешним данным, проверка подписей образов |

Мутация на CEL — MutatingAdmissionPolicy (⚠️ на стенде не проверялась; уровень зрелости сверяйте с версией кластера). Проверка подписи образов (cosign) — Kyverno `verifyImages` или Sigstore policy-controller — курс `cicd` 04-2 и курс `security`.

## 4. Порядок admission 🔴

```
запрос → аутентификация → авторизация (RBAC)
       → mutating admission (встроенные дефолты, MutatingAdmissionPolicy, mutating webhooks)
       → валидация схемы
       → validating admission (PodSecurity, ResourceQuota, LimitRanger, ValidatingAdmissionPolicy, validating webhooks)
       → etcd
```

Мутация до валидации: вебхук, добавляющий sidecar без `securityContext`, сделает под несовместимым с `restricted` — ошибка будет от PodSecurity, хотя автор манифеста ни при чём. Решается настройкой инжектора или исключением.

---

## 🔧 Лаба

### Шаг 0. Подготовка

```bash
kubectl config use-context kind-lab
kubectl create ns lab-06-2
kubectl label ns lab-06-2 pod-security.kubernetes.io/enforce=restricted pod-security.kubernetes.io/enforce-version=latest
kubectl config set-context --current --namespace=lab-06-2
```

### Шаг 1. restricted: отказ и исправление

```bash
kubectl run plain --image=localhost:5001/orders-api:2.0
kubectl apply -f - <<'EOF'
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
kubectl wait --for=condition=Ready pod/hardened
kubectl exec hardened -- python -c "
import os,urllib.request
print('uid', os.getuid(), urllib.request.urlopen('http://127.0.0.1:8000/version').read().decode())
try: open('/srv/x','w')
except Exception as e: print('write to /srv:', type(e).__name__)
open('/tmp/x','w').write('ok'); print('write to /tmp: ok')"
kubectl exec hardened -- grep -E 'CapEff|NoNewPrivs|Seccomp:' /proc/1/status
```

Проверено: вывод в §1 и §2.

### Шаг 2. Мягкое внедрение: baseline + warn/audit restricted

```bash
kubectl create ns lab-06-2b
kubectl label ns lab-06-2b pod-security.kubernetes.io/enforce=baseline pod-security.kubernetes.io/warn=restricted pod-security.kubernetes.io/audit=restricted
kubectl -n lab-06-2b run plain --image=localhost:5001/orders-api:2.0
kubectl -n lab-06-2b run hostnet --image=busybox:1.37 --overrides='{"spec":{"hostNetwork":true}}' -- sleep 60
kubectl label --dry-run=server --overwrite ns orders pod-security.kubernetes.io/enforce=restricted
```

Проверено: `plain` создан с предупреждением, `hostnet` отклонён baseline'ом, dry-run для `orders` перечисляет нарушения (§2).

### Шаг 3. Политика «без latest»

```bash
kubectl label ns lab-06-2b policy.lab/images=pinned
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
        (c.image.split('/')[size(c.image.split('/'))-1].contains(':') && !c.image.endsWith(':latest')))
    messageExpression: "'образ без тега или с :latest запрещён: ' + object.spec.containers.map(c, c.image).join(', ')"
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata: {name: no-latest-tag}
spec:
  policyName: no-latest-tag
  validationActions: [Warn]
  matchResources:
    namespaceSelector: {matchLabels: {policy.lab/images: pinned}}
EOF
sleep 3; kubectl -n lab-06-2b run w1 --image=busybox -- sleep 60
kubectl patch validatingadmissionpolicybinding no-latest-tag --type=merge -p '{"spec":{"validationActions":["Deny"]}}'; sleep 3
for img in busybox busybox:latest busybox:1.37 localhost:5001/orders-api:2.0 localhost:5001/orders-api \
           localhost:5001/orders-api@sha256:ad4f8fd2cabaef73e735d9a623a3499270fd5f3a5d7f640719bfd0982e772465; do
  printf "%-40s -> " "${img:0:40}"; kubectl -n lab-06-2b run t-$RANDOM --image=$img -- sleep 60 2>&1 | tail -1 | cut -c1-110
done
```

Дайджест `orders-api:2.0` у вас другой — возьмите из вывода `docker push` в 00-1 §4.1. Проверено: вывод в §3.

### Шаг 4. Сквозной сценарий: orders-api под restricted

Добавьте в `~/lab/k8s/orders-api/k8s/orders-api.yaml` в шаблон пода `securityContext` из шага 1 (под и контейнер) и том `emptyDir` на `/tmp`, примените и проверьте dry-run ещё раз:

```bash
kubectl apply -f ~/lab/k8s/orders-api/k8s/orders-api.yaml && kubectl -n orders rollout status deploy/orders-api
kubectl label --dry-run=server --overwrite ns orders pod-security.kubernetes.io/enforce=restricted
```

PostgreSQL официального образа запускается от root и меняет владельца каталога данных — под `restricted` он не пройдёт без доработки (`runAsUser: 70` для alpine-образа, `fsGroup`, initContainer для прав). ⚠️ Полный перевод `orders` на `restricted` на стенде не выполнялся — это задание со звёздочкой.

### Уборка

```bash
kubectl delete validatingadmissionpolicybinding no-latest-tag; kubectl delete validatingadmissionpolicy no-latest-tag
kubectl config set-context --current --namespace=default
kubectl delete ns lab-06-2 lab-06-2b
```

---

## 🔥 Кейс из прода: «включили restricted — релиз “прошёл”, а подов нет»

**Контекст.** Платформенная команда включила `enforce=restricted` на всех namespace команд в пятницу вечером. Работающие поды не пострадали. В понедельник утренний релиз сервиса прошёл в CI зелёным, но через полчаса упал трафик: при rolling update новые поды не создавались, старые постепенно убирались HPA при снижении нагрузки… а утром нагрузка выросла, и масштабироваться было нечем.

**Разбор.**
1. `kubectl get deploy` — `READY 2/6`, `kubectl describe rs` — `FailedCreate … violates PodSecurity "restricted:latest"` (как отказ квоты — событие у ReplicaSet, не у Deployment).
2. CI проверял `kubectl apply`, а не `rollout status` (02-2, кейс).
3. Включение enforce без этапа warn/audit и без dry-run по существующим namespace.

**Фикс.**
- Откат меток на `enforce=baseline`, `warn=restricted`, `audit=restricted`; список нарушений из `kubectl label --dry-run=server` по каждому namespace — командам.
- В CI: `kubectl apply --dry-run=server` (PSA и политики проверяются на этом этапе — 00-2 §4) и `rollout status`.
- Переход на enforce — по namespace, после нуля предупреждений за неделю.

**Что запомнить.**
- Enforce не трогает работающие поды — проблема всплывает на следующем rollout или масштабировании.
- Внедрение: warn/audit → исправления → dry-run → enforce.
- Ошибки admission у подов контроллеров видны в событиях ReplicaSet/Job.

---

## 💼 Вопросы с собеседования

### 🟢 Junior

**1. Что делает `securityContext`?**
Задаёт параметры безопасности процесса: пользователь (`runAsUser`, `runAsNonRoot`), capabilities, запрет повышения привилегий, seccomp, корень только для чтения. Без него контейнер получает дефолты рантайма — часто root.

**2. Что такое Pod Security Standards?**
Три уровня требований к подам: privileged, baseline, restricted. Pod Security Admission применяет их по меткам namespace в режимах enforce, warn, audit.

### 🟡 Middle

**3. Как безопасно включить restricted в существующем кластере?**
Сначала `warn` и `audit` (ничего не ломают), сбор и исправление нарушений, `kubectl label --dry-run=server` для проверки существующих подов, затем `enforce` по namespace. В CI — `apply --dry-run=server` и `rollout status`.

**4. Как запретить образы с тегом latest?**
ValidatingAdmissionPolicy с CEL-выражением по `spec.containers[].image` (тег в последнем сегменте, дайджест разрешён) и привязкой к нужным namespace; сначала `Warn`, потом `Deny`. Альтернатива — Kyverno/Gatekeeper.

### 🔴 Senior

**5. ValidatingAdmissionPolicy или вебхук?**
VAP — в apiserver, без сетевого вызова и без риска «упал вебхук — кластер не принимает изменения»; только проверка. Вебхук нужен для мутации, генерации объектов, внешних данных, проверки подписей. Часто — VAP для простых правил и Kyverno для остального, с `failurePolicy` и исключениями для системных namespace.

**6. Почему под может нарушить PodSecurity, хотя манифест автора корректен?**
Mutating admission выполняется раньше validating: вебхук-инжектор (sidecar mesh'а, агент) может добавить контейнер без нужного `securityContext`. Лечится настройкой инжектора или его исправлением, а не ослаблением уровня.

**7. Что сделать, чтобы сервис работал с `readOnlyRootFilesystem: true`?**
Найти, куда он пишет (временные файлы, кэш, pid, сокеты), и смонтировать туда `emptyDir` (при необходимости `medium: Memory`); логи — в stdout. Код обычно менять не нужно.

---

## ⚠️ Подводные камни

- Enforce не проверяет работающие поды — ломается следующий rollout.
- Ошибки PSA и политик у подов контроллеров — в событиях ReplicaSet, а не Deployment.
- `enforce-version: latest` меняет требования вместе с обновлением кластера; для предсказуемости фиксируйте версию.
- `readOnlyRootFilesystem` без `emptyDir` для `/tmp` ломает многие приложения.
- Официальные образы БД часто требуют root на старте — под restricted нужна доработка.
- Двоеточие порта реестра — не тег; проверяйте последний сегмент пути образа.
- Мутирующие вебхуки могут сделать под несовместимым с уровнем PodSecurity.

---

## Чеклист

- [ ] Соберу `securityContext`, проходящий restricted, и проверю его внутри контейнера.
- [ ] Включу PSA по меткам namespace в режимах warn/audit/enforce.
- [ ] Проверю существующий namespace dry-run'ом перед enforce.
- [ ] Напишу ValidatingAdmissionPolicy на CEL и внедрю её через Warn → Deny.
- [ ] Объясню порядок admission и разницу VAP и вебхуков.

---

## Задание со звёздочкой

Переведите namespace `orders` на `restricted` полностью:

1. orders-api — `securityContext` из лабы.
2. PostgreSQL: `runAsUser`/`runAsGroup` 70 (пользователь `postgres` в alpine-образе), `fsGroup: 70`, `PGDATA` в подкаталоге тома, `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]`, seccomp. Проверьте, что старый том читается (владелец файлов!).
3. `kubectl label ns orders pod-security.kubernetes.io/enforce=restricted` без предупреждений, `rollout restart` обоих, сквозной `curl` — 200.
4. Задайте ту же проверку в CI (`apply --dry-run=server` на namespace с меткой enforce).

---

→ Следующая часть: **07-1. Helm: чарты и релизы** — модуль «Пакетирование»: чарт orders-api, values и шаблоны, `helm template/lint/diff`, где Helm хранит релизы, `--atomic` и откат, «another operation is in progress» и выход из pending-upgrade; Helm 4 стенда.
