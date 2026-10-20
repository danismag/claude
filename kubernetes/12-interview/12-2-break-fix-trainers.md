# 12-2. Тренажёры «сломай и почини»

> Модуль 12 «Подготовка к собеседованию» · часть 2 из 4 · ~4 ч (по 5–15 минут на сценарий) · Нужно: стенд 00-1 с `orders` (контекст `kind-lab`), `docker exec` на узлы kind, `curl`, `jq`; для отдельных сценариев — результаты работ 04-3, 06-4, 07-1, 08-1, 08-2 и образ `kindest/node:v1.36.1` · Опирается на: части 01–11, из которых взяты поломки.

## Где мы на карте

Модули 01–10 объясняли механизмы, модуль 11 учил искать причину по слоям, а эта часть проверяет, что навык работает без подсказок. Каждый сценарий ломает стенд одной командой, показывает симптом и ждёт, что вы назовёте причину и исправление. Так устроены live-собеседования: вам дают сломанную систему и просят вслух разобраться.

```
12-1 вопросы ──► 12-2 поломки на стенде ──► 12-3 проектирование ──► 12-4 самопроверка
(что вы знаете)  (что вы умеете)             (как вы строите)        (где пробелы)
```

Схема 1. Место части в модуле 12: здесь вы чините, а в 12-3 проектируете так, чтобы поломка не случилась.

В части 47 сценариев: 10 для Junior, 18 для Middle, 19 для Senior. Каждый сценарий ссылается на часть курса, где объяснён механизм, поэтому сначала решайте сами, а потом открывайте разбор и идите по ссылке.

---

## Как пользоваться

Работайте парой: один ломает по блоку «Поломка», второй видит только «Симптом» и ищет причину. Спойлеры «Решение» и «Разбор» открывайте после того, как назвали причину вслух. Засекайте время: ориентир для Junior — до 5 минут, для Middle — до 10, для Senior — до 15.

Правило для ломающего: каждую поломку откатывайте до перехода к следующей, и блок «Уборка» возвращает стенд в исходное состояние. После сценариев на `orders` команда проверки `C` должна снова отвечать 200.

Перед сценарием без вывода из прежней версии части стоит фраза «Эту работу вы выполняете сами, результаты в ней — ожидаемые». Такие сценарии написаны по документации и по соседним частям курса, а точные строки вывода у вас могут отличаться. Симптомы остальных сценариев опираются на реальный вывод прежней версии части и частей курса, на которые они ссылаются.

Сценарии, которые меняют узлы, control plane или рабочее приложение `orders`, начинаются блоком «Риски», и его нужно прочитать до первой команды.

---

## Подготовка

Подготовку выполняют один раз в каждом терминале, а контекст и текущий namespace kubectl эта часть не меняет. Первая команда проверяет контекст: она должна напечатать `kind-lab`.

```bash
kubectl config current-context
mkdir -p ~/lab/k8s/12-2
docker pull busybox:1.37
docker tag busybox:1.37 localhost:5001/busybox:1.37
docker push localhost:5001/busybox:1.37
```

Вторая команда создаёт каталог файлов части, а три последние кладут образ `busybox` в реестр стенда, если его там ещё нет (02-1). Остальные образы — `localhost:5001/orders-api:2.0` и `2.1` — уже лежат в реестре после 00-1.

Теперь определим три помощника, которые живут только в текущем терминале.

```bash
mk() { NS="lab-12-2-$1"; kubectl create ns "$NS" && kubectl label ns "$NS" lab-12-2=trainer; }
k() { kubectl -n "${NS:?сначала выполните mk tNN}" "$@"; }
C() { curl -s -m 20 -o /tmp/lab-12-2.body -w '%{http_code} %{time_total}s ' \
      http://orders.localhost:8088/api/orders; head -c 100 /tmp/lab-12-2.body; echo; }
C
```

Назначение помощников в таблице:

| Часть | Значение |
|---|---|
| `mk t01` | создать namespace `lab-12-2-t01` с меткой `lab-12-2=trainer` и запомнить его в `NS` |
| `k …` | `kubectl -n "$NS" …`: команды сценария идут в его namespace |
| `C` | запрос к `orders` через Gateway: код ответа, время и начало тела |

Последняя команда должна напечатать `200`, время в миллисекундах и начало списка заказов: это исходное состояние. Если ответа нет, сначала почините стенд по 00-1 §5.

Имена, которые создают сценарии, следуют правилу курса: namespace называются `lab-12-2-tNN`, метки и taints узлов начинаются с `lab-12-2/`, файлы лежат в `~/lab/k8s/12-2/`.

---

## Junior: под не стартует

Эти сценарии учат читать статус пода и сообщение под ним, а методика поиска описана в 11-2.

### T01. Тега нет в реестре

Уровень Junior, механизм объяснён в частях 11-2 §5, 00-1.

**Поломка:** Команда создаёт Deployment с тегом, которого нет в реестре стенда.

```bash
mk t01
k create deploy t01 --image=localhost:5001/orders-api:9.9
```

**Симптом:** «Деплой не поднимается»: подов в состоянии `Running` нет, `READY` равен `0/1`.

<details><summary>Решение</summary>

Поставить в Deployment тег, который есть в реестре стенда, и дождаться готовности пода:

```bash
k set image deploy/t01 orders-api=localhost:5001/orders-api:2.0
k rollout status deploy/t01
```

На проде сначала выясняют, почему CI не опубликовал тег: тег в реестре — результат сборки, а не ручной операции.
</details>

<details><summary>Разбор</summary>

1. `k get pods` показывает `ErrImagePull`, затем `ImagePullBackOff`: kubelet не может скачать образ и повторяет попытки с нарастающей паузой.
2. Причина записана в состоянии контейнера: `k get pod -l app=t01 -o jsonpath='{.items[0].status.containerStatuses[0].state.waiting.message}'`.
3. Сообщение заканчивается словами `localhost:5001/orders-api:9.9: not found`. Реестр ответил, но такого тега в нём нет.
4. Теги реестра стенда видны командой `curl -s http://127.0.0.1:5001/v2/orders-api/tags/list`.
</details>

**Уборка:** `kubectl delete ns lab-12-2-t01`.

### T02. Реестр недоступен

Уровень Junior, механизм объяснён в частях 11-2 §5, 00-1 §5.

**Поломка:** Образ ссылается на реестр, которого нет.

```bash
mk t02
k run t02 --image=registry.invalid.lab/app:1.0
```

**Симптом:** Под в `ImagePullBackOff`, как в T01, но причина другая: чем она отличается?

<details><summary>Решение</summary>

Исправить адрес реестра в образе либо вернуть реестру доступность (DNS, сеть, TLS), а для приватного реестра проверить `imagePullSecrets`.

```bash
k delete pod t02
k run t02 --image=localhost:5001/busybox:1.37 -- sleep 60
```
</details>

<details><summary>Разбор</summary>

1. Сообщение `state.waiting.message` начинается с `failed to do request: Head "https://registry.invalid.lab/v2/app/manifests/1.0…`.
2. В T01 реестр ответил «не найдено». Здесь ошибка случилась до ответа: имя не разрешилось или соединение не открылось.
3. К этому же классу относятся `401` и `403` (нет или неверный `imagePullSecrets`) и `429` (лимиты публичного реестра).
4. Порядок поиска: ответил ли реестр, потом есть ли тег, потом права.
</details>

**Уборка:** `kubectl delete ns lab-12-2-t02`.

### T03. Приложение падает при старте

Уровень Junior, механизм объяснён в частях 11-2 §5, 02-1 §5.

**Поломка:** Контейнер печатает ошибку и завершается с кодом 1.

```bash
mk t03
k run t03 --image=localhost:5001/busybox:1.37 --restart=Always -- \
  sh -c "echo 'db config missing' >&2; exit 1"
```

**Симптом:** «Под постоянно перезапускается»: `RESTARTS` растёт, статус чередует `Error` и `CrashLoopBackOff`.

<details><summary>Решение</summary>

Передать приложению конфигурацию, которую оно ждёт (переменные или Secret), и пересоздать под. В этом сценарии достаточно удалить под, потому что причина была в самой команде:

```bash
k delete pod t03
```
</details>

<details><summary>Разбор</summary>

1. `k describe pod t03` показывает `Last State: Terminated`, причина `Error`, код выхода 1.
2. `k logs t03` печатает `db config missing`. Это причина падения.
3. В паузе между перезапусками `--previous` может ответить `unable to retrieve container logs`. Тогда читайте логи без этого флага.
4. Если логов нет вообще, смотрите сообщение завершения (termination message, 02-1) и код выхода.
</details>

**Уборка:** `kubectl delete ns lab-12-2-t03`.

### T04. Нет ConfigMap

Уровень Junior, механизм объяснён в частях 11-2 §5, 04-1 §5.

**Поломка:** Под берёт переменные из ConfigMap, которого нет.

```bash
mk t04
k apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata: {name: t04}
spec:
  containers:
  - name: app
    image: localhost:5001/busybox:1.37
    command: ["sleep", "3600"]
    envFrom: [{configMapRef: {name: app-config}}]
EOF
```

**Симптом:** Под не стартует, при этом `RESTARTS` равен 0: контейнер ни разу не запускался.

<details><summary>Решение</summary>

Создать объект, которого не хватает, и понаблюдать за подом, пока он не станет готовым:

```bash
k create configmap app-config --from-literal=MODE=prod
k get pod t04 -w
```

Под оживает без пересоздания, но не мгновенно, потому что kubelet повторяет попытку с паузой. Через 6 секунд после создания ConfigMap под ещё был в ошибке, поэтому подождите десятки секунд или пересоздайте его.
</details>

<details><summary>Разбор</summary>

1. Статус `CreateContainerConfigError` значит, что контейнер не удалось собрать из-за конфигурации.
2. Сообщение: `configmap "app-config" not found` (`k describe pod t04`).
3. Контейнер не создавался, поэтому логов нет и `RESTARTS` равен 0.
4. Опечатка в имени лечится так же: поправить имя или создать объект.
</details>

**Уборка:** `kubectl delete ns lab-12-2-t04`.

### T05. Нет узла с нужной меткой

Уровень Junior, механизм объяснён в частях 11-2 §5, 05-3 §5.

**Поломка:** Под требует метку узла, которой нет ни у одного узла.

```bash
mk t05
k apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata: {name: t05}
spec:
  nodeSelector: {lab-12-2/disk: nvme}
  containers:
  - {name: app, image: "localhost:5001/busybox:1.37", command: ["sleep", "3600"]}
EOF
```

**Симптом:** Под в `Pending`, у него есть событие, а `NODE` пуст.

<details><summary>Решение</summary>

Либо убрать `nodeSelector` и пересоздать под (поле нельзя менять у существующего пода), либо повесить метку на узел:

```bash
kubectl label node lab-worker lab-12-2/disk=nvme
k get pod t05 -o wide
kubectl label node lab-worker lab-12-2/disk-
```
</details>

<details><summary>Разбор</summary>

1. `k get events --field-selector reason=FailedScheduling` показывает сообщение `0/4 nodes are available`.
2. В нём есть группа `3 node(s) didn't match Pod's node affinity/selector`: три рабочих узла не подошли по метке. Четвёртый (control plane) отсеян taint'ом.
3. Читайте сообщение целиком: каждая группа узлов отсеяна по своей причине.
4. Метки узлов смотрят командой `kubectl get nodes --show-labels`.
</details>

**Уборка:** `kubectl delete ns lab-12-2-t05`; метку с узла снимает последняя команда решения.

## Junior: трафик и данные не доходят

Теперь под запускается, но запрос или том не доходит до него, а методика поиска описана в 11-2 и 11-3.

### T06. Селектор Service не совпадает

Уровень Junior, механизм объяснён в частях 03-2 §5, 11-3 §5.

**Риски:** сценарий меняет Service рабочего приложения в namespace `orders`, а не объекты своего namespace.

- **Что меняется:** селектор Service `orders-api` в namespace `orders`.
- **Влияние:** пока поломка активна, `orders.localhost:8088` отвечает 503.
- **Откат:** команда в «Решении»; она же в «Уборке».

**Поломка:** Опечатка в селекторе, как после переименования метки в Deployment.

```bash
kubectl -n orders patch svc orders-api -p '{"spec":{"selector":{"app":"orders-apl"}}}'
sleep 4
C
```

**Симптом:** `C` отвечает `503` почти мгновенно (около 1 мс), поды при этом `Running 1/1`.

<details><summary>Решение</summary>

```bash
kubectl -n orders patch svc orders-api -p '{"spec":{"selector":{"app":"orders-api"}}}'
sleep 4
C
```
</details>

<details><summary>Разбор</summary>

1. Поды здоровы, значит, ищем между Gateway и подами. Ответ за миллисекунду без тела — признак `direct_response` Envoy: у бэкенда нет адресов.
2. `kubectl -n orders get endpointslice -l kubernetes.io/service-name=orders-api -o jsonpath='{.items[*].endpoints}'` печатает `null`.
3. Сравните `kubectl -n orders get svc orders-api -o jsonpath='{.spec.selector}'` с `kubectl -n orders get pods --show-labels`.
4. Профилактика: метки и селектор живут в одном чарте или одном kustomize-наборе, проверка эндпоинтов — в смоук-тесте после деплоя.
</details>

**Уборка:** Команда из «Решения» уже вернула селектор; `C` должен отвечать 200.

### T07. Чужой Host

Уровень Junior, механизм объяснён в частях 03-4 §5, 11-3 §5.

**Поломка:** Клиенту выдали адрес с другим именем хоста.

```bash
curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: orders.local' http://127.0.0.1:8088/api/orders
```

**Симптом:** Ответ `404` приходит мгновенно и с пустым телом, хотя приложение при этом работает.

<details><summary>Решение</summary>

Исправить адрес у клиента на `orders.localhost` или добавить нужное имя в `hostnames` у HTTPRoute `orders-api`.

```bash
curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: ORDERS.localhost' \
  http://127.0.0.1:8088/api/orders
```

Регистр имени хоста не важен, поэтому вторая команда вернёт 200.
</details>

<details><summary>Разбор</summary>

1. 404 без тела от Gateway значит, что ни один маршрут не совпал с заголовком `Host`.
2. В логе Envoy флаг `NR` и детали `route_not_found`: `kubectl -n envoy-gateway-system logs -l gateway.envoyproxy.io/owning-gateway-name=lab -c envoy --tail=3`.
3. Сверьте `kubectl -n orders get httproute orders-api -o jsonpath='{.spec.hostnames}'` с тем, что реально приходит. За CDN или балансировщиком заголовок может быть переписан.
</details>

**Уборка:** не нужна, потому что сценарий только отправляет запрос и состояние стенда не меняет.

### T08. PVC с несуществующим StorageClass

Уровень Junior, механизм объяснён в частях 04-2 §5, 11-2 §5.

**Поломка:** Заявка на том ссылается на класс, которого в кластере нет.

```bash
mk t08
k apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: t08}
spec:
  storageClassName: fast-ssd
  accessModes: [ReadWriteOnce]
  resources: {requests: {storage: 1Gi}}
---
apiVersion: v1
kind: Pod
metadata: {name: t08}
spec:
  containers:
  - name: app
    image: localhost:5001/busybox:1.37
    command: ["sleep", "3600"]
    volumeMounts: [{name: d, mountPath: /d}]
  volumes: [{name: d, persistentVolumeClaim: {claimName: t08}}]
EOF
```

**Симптом:** Под в `Pending` и не получает узел, хотя свободных ресурсов на узлах достаточно.

<details><summary>Решение</summary>

Поле `storageClassName` у PVC менять нельзя, поэтому удалите под и PVC и создайте их заново с классом `standard`, который есть на стенде:

```bash
k delete pod t08; k delete pvc t08
k get storageclass
```
</details>

<details><summary>Разбор</summary>

1. У пода событие: `pod has unbound immediate PersistentVolumeClaims`. Оно называет следствие, а не причину.
2. Причина в событиях самого PVC: `k describe pvc t08` показывает `storageclass.storage.k8s.io "fast-ssd" not found`.
3. Правило: если под ждёт том, читайте события PVC, а не только пода.
</details>

**Уборка:** `kubectl delete ns lab-12-2-t08`.

### T09. Readiness-проба бьёт не в тот путь

Уровень Junior, механизм объяснён в частях 02-5 §5, 11-2 §5.

**Поломка:** Проба проверяет путь, которого нет у приложения.

```bash
mk t09
k apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata: {name: t09}
spec:
  containers:
  - name: app
    image: localhost:5001/orders-api:2.0
    readinessProbe: {httpGet: {path: /healthz, port: 8000}, periodSeconds: 3}
EOF
```

**Симптом:** Под `Running`, но `READY` равен `0/1`, рестартов нет, трафик к нему не идёт.

<details><summary>Решение</summary>

Поставить путь, который отдаёт приложение (`/ready`), и пересоздать под, потому что поле пробы у существующего пода менять нельзя:

```bash
k delete pod t09
k apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata: {name: t09}
spec:
  containers:
  - name: app
    image: localhost:5001/orders-api:2.0
    readinessProbe: {httpGet: {path: /ready, port: 8000}, periodSeconds: 3}
EOF
k wait --for=condition=Ready pod/t09
```

Сверяйте пробы с тем, что приложение реально отдаёт, например тестом в CI.
</details>

<details><summary>Разбор</summary>

1. Процесс жив, поэтому статус `Running` и нет перезапусков. Не готов он только по результату пробы.
2. Событие `Readiness probe failed: HTTP probe failed with statuscode: 404` видно в `k describe pod t09`.
3. Неготовый под не попадает в EndpointSlice, и Service его не использует (03-2).
4. Если бы это была liveness-проба, kubelet перезапускал бы контейнер. Различие — в 02-5.
</details>

**Уборка:** `kubectl delete ns lab-12-2-t09`.

### T10. ServiceAccount получает 403

Уровень Junior, механизм объяснён в частях 06-1 §5, 06-1 ЛР 3.

Эту работу вы выполняете сами, результаты в ней — ожидаемые.

**Поломка:** CI использует токен ServiceAccount, которому не выдали роль.

```bash
mk t10
k create sa ci
SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
kubectl config view --raw --minify \
  -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d \
  > ~/lab/k8s/12-2/ca.crt
TOKEN=$(k create token ci --duration=10m)
curl -s --cacert ~/lab/k8s/12-2/ca.crt -H "Authorization: Bearer $TOKEN" \
  "$SERVER/api/v1/namespaces/$NS/pods" | grep '"message"'
```

**Симптом:** Сообщение об отказе, в котором названы пользователь, действие и ресурс.

<details><summary>Решение</summary>

Выдать роль на чтение подов и привязать её к ServiceAccount:

```bash
k create role pod-reader --verb=get,list --resource=pods
k create rolebinding ci-pods --role=pod-reader --serviceaccount=$NS:ci
kubectl auth can-i list pods -n $NS --as system:serviceaccount:$NS:ci
```

Последняя команда должна ответить `yes`, потому что роль теперь привязана к ServiceAccount.
</details>

<details><summary>Разбор</summary>

1. Ответ 403 значит: кластер узнал субъекта, но не разрешил действие. Ответ 401 значил бы, что токен не признан.
2. Сообщение содержит пять частей: субъект `system:serviceaccount:lab-12-2-t10:ci`, глагол `list`, ресурс `pods`, группу API и namespace. Это готовая заявка на правило.
3. Проверка без реального запроса — `kubectl auth can-i … --as system:serviceaccount:<ns>:<имя>`.
4. Выдавайте минимальную роль на нужный namespace, а не `edit` или `cluster-admin`.
</details>

**Уборка:** `kubectl delete ns lab-12-2-t10`; `rm -f ~/lab/k8s/12-2/ca.crt`; `unset TOKEN SERVER`.

## Middle: ресурсы и квоты

Здесь причина лежит в числах — requests, limits и квотах, и чтобы найти её, нужно знать, где проверяется каждое число (05-1, 05-2, 05-4).

### T11. Не хватает CPU

Уровень Middle, механизм объяснён в частях 05-1 §5, 05-3 §5, 11-2 §5.

**Поломка:** Deployment просит 64 ядра, на узлах их нет.

```bash
mk t11
k create deploy t11 --image=localhost:5001/busybox:1.37 -- sleep 3600
k set resources deploy t11 --requests=cpu=64
```

**Симптом:** Новый под в `Pending`, хотя узлы `Ready` и другие поды на них запускаются.

<details><summary>Решение</summary>

Поставить реалистичный request и проверить, сколько ресурсов уже занято на узлах:

```bash
k set resources deploy t11 --requests=cpu=100m
kubectl describe node | grep -A6 'Allocated resources'
```
</details>

<details><summary>Разбор</summary>

1. Событие `FailedScheduling`: `0/4 nodes are available: 1 node(s) had untolerated taint(s), 3 Insufficient cpu.`
2. Control plane отсеян taint'ом, три рабочих узла — нехваткой CPU. Scheduler сравнивает request пода с allocatable узла за вычетом requests других подов.
3. Request больше любого узла не исправит ни перебалансировка, ни автоскейлер узлов, если нет узла такого размера.
4. Лимиты на планирование не влияют, только requests (05-1).
</details>

**Уборка:** `kubectl delete ns lab-12-2-t11`.

### T12. OOMKilled

Уровень Middle, механизм объяснён в частях 05-1 §5 и ЛР 2.

**Поломка:** Процесс выделяет 300 МиБ при лимите 128 МиБ.

```bash
mk t12
k apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata: {name: t12}
spec:
  containers:
  - name: app
    image: localhost:5001/orders-api:2.0
    command: ["python", "-c", "b = b'x' * (300 * 2**20)"]
    resources: {limits: {memory: 128Mi}}
EOF
```

Флага `--limits` у `kubectl run` в актуальных версиях нет, поэтому лимит задан манифестом.

**Симптом:** Под перезапускается снова и снова, а в его логах пусто.

<details><summary>Решение</summary>

Поднять лимит выше реального рабочего набора либо исправить потребление памяти и пересоздать под; в этом сценарии достаточно удалить под.

```bash
k delete pod t12
```
</details>

<details><summary>Разбор</summary>

1. `k get pod t12 -o jsonpath='{.status.containerStatuses[0].lastState.terminated.reason}/{.status.containerStatuses[0].lastState.terminated.exitCode}'` печатает `OOMKilled/137`. Код 137 — это 128 плюс сигнал 9.
2. Событий про OOM нет: убивает ядро, а не kubelet. Причина видна в `Last State` и в журнале ядра узла (`dmesg`).
3. Логов нет, потому что процесс убит без записи.
4. Профилактика: лимит памяти равен запросу (QoS Guaranteed), мониторинг рабочего набора, алерт на рестарты.
</details>

**Уборка:** `kubectl delete ns lab-12-2-t12`.

### T13. Квота требует requests, а их нет

Уровень Middle, механизм объяснён в частях 05-2 §5 и ЛР 3.

**Поломка:** В namespace стоит квота на CPU и память, а LimitRange с умолчаниями нет.

```bash
mk t13
k create quota q --hard=requests.cpu=500m,limits.memory=1Gi
k create deploy t13 --image=localhost:5001/busybox:1.37 --replicas=2 -- sleep 3600
```

**Симптом:** Deployment `0/2`, подов нет вообще, у Deployment нет ни ошибок, ни событий.

<details><summary>Решение</summary>

Задать requests и limits в шаблоне пода или создать LimitRange с умолчаниями:

```bash
k set resources deploy t13 --requests=cpu=100m --limits=memory=128Mi
k get deploy t13
```
</details>

<details><summary>Разбор</summary>

1. Ошибку создаёт ReplicaSet, поэтому ищите в его событиях: `k get events --field-selector reason=FailedCreate`.
2. Сообщение: `pods "t13-…" is forbidden: failed quota: q: must specify limits.memory for: busybox; requests.cpu for: busybox`.
3. Если квота ограничивает ресурс, каждый под обязан его указать. Без LimitRange подставить умолчание некому.
4. Чем это отличается от T14: здесь отказ из-за отсутствия значений, там — из-за исчерпания.
</details>

**Уборка:** `kubectl delete ns lab-12-2-t13`.

### T14. Квота не даёт выкатить новую версию

Уровень Middle, механизм объяснён в частях 05-2 §5, 02-2 §5.

Эту работу вы выполняете сами, результаты в ней — ожидаемые.

**Поломка:** Квота на число подов равна числу реплик, и для временного лишнего пода при выкатке места нет.

```bash
mk t14
k create quota q --hard=pods=3
k create deploy t14 --image=localhost:5001/busybox:1.37 --replicas=3 -- sleep 3600
k rollout status deploy/t14
k set env deploy/t14 REV=2
sleep 15
k rollout status deploy/t14 --timeout=10s
```

**Симптом:** Первый `rollout status` проходит, а после смены шаблона выкатка зависает: часть реплик не обновляется.

<details><summary>Решение</summary>

Дать квоте запас на лишний под выкатки (`pods=4` или больше) либо выкатывать без лишнего пода:

```bash
k patch deploy t14 -p '{"spec":{"strategy":{"rollingUpdate":{"maxSurge":0,"maxUnavailable":1}}}}'
k rollout status deploy/t14
```
</details>

<details><summary>Разбор</summary>

1. Для 3 реплик по умолчанию `maxSurge` 25 % округляется вверх до 1, а `maxUnavailable` 25 % вниз до 0. Выкатка должна сначала создать четвёртый под.
2. Квота пропускает три пода, четвёртый отклоняет. Событие у нового ReplicaSet: `Error creating: pods "…" is forbidden: exceeded quota: q, requested: pods=1, used: pods=3, limited: pods=3`.
3. Старые поды работают, поэтому сервис жив, а выкатка стоит. Её видно только в `rollout status` и событиях ReplicaSet.
4. Профилактика: квота с запасом на `maxSurge` самого крупного Deployment и алерт на расход квоты выше 80 %.
</details>

**Уборка:** `kubectl delete ns lab-12-2-t14`.

### T15. HPA не видит загрузку

Уровень Middle, механизм объяснён в частях 05-4 §5 и ЛР 1.

Эту работу вы выполняете сами, результаты в ней — ожидаемые.

**Поломка:** HPA считает процент от requests, а requests у подов нет.

```bash
mk t15
k create deploy t15 --image=localhost:5001/orders-api:2.0 --port=8000
k apply -f - <<'EOF'
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata: {name: t15}
spec:
  scaleTargetRef: {apiVersion: apps/v1, kind: Deployment, name: t15}
  minReplicas: 1
  maxReplicas: 5
  metrics:
  - type: Resource
    resource: {name: cpu, target: {type: Utilization, averageUtilization: 50}}
EOF
sleep 45
k get hpa t15
```

**Симптом:** В столбце `TARGETS` стоит `cpu: <unknown>/50%`, число реплик не меняется под нагрузкой.

<details><summary>Решение</summary>

Задать requests и дождаться следующего расчёта (30–60 секунд):

```bash
k set resources deploy t15 --requests=cpu=100m
sleep 60
k get hpa t15
```
</details>

<details><summary>Разбор</summary>

1. Условия HPA называют причину: `k get hpa t15 -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}: {.message}{"\n"}{end}'`.
2. Ожидаемая строка: `ScalingActive=False FailedGetResourceMetric: … missing request for cpu in container orders-api …`.
3. Для метрики в процентах requests нужны у всех контейнеров пода, включая sidecar.
4. Если условия показывают другую причину, проверьте metrics-server (T28).
</details>

**Уборка:** `kubectl delete ns lab-12-2-t15`.

## Middle: размещение и узлы

Причину здесь ищут в scheduler и на узле: taints, привязка тома, профили безопасности и бюджеты прерываний (05-3, 05-5, 04-2, 06-2).

### T16. Taint на всех рабочих узлах

Уровень Middle, механизм объяснён в частях 05-3 ЛР 3, 05-3 §5.

**Риски:**

- **Что меняется:** на трёх рабочих узлах появляется taint `lab-12-2/dedicated=db:NoSchedule`.
- **Влияние:** запущенные поды работают дальше, но новые поды в любом namespace встанут в `Pending`, пока taint есть. Не выкатывайте ничего параллельно.
- **Откат:** команда `taint … -` из «Решения»; она же в «Уборке».

**Поломка:** Узлы пометили под выделенную нагрузку и забыли про остальные.

```bash
mk t16
kubectl taint node lab-worker lab-worker2 lab-worker3 lab-12-2/dedicated=db:NoSchedule
k run t16 --image=localhost:5001/busybox:1.37 --restart=Never -- sleep 3600
```

**Симптом:** Новый под в `Pending`, а старые поды на тех же узлах работают.

<details><summary>Решение</summary>

Снять taint или дать поду, которому положено работать на этих узлах, toleration:

```bash
kubectl taint node lab-worker lab-worker2 lab-worker3 lab-12-2/dedicated=db:NoSchedule-
k get pod t16 -o wide
```

Под становится `Running` примерно через 6 секунд после снятия taint.
</details>

<details><summary>Разбор</summary>

1. Событие: `0/4 nodes are available: 4 node(s) had untolerated taint(s). … Preemption is not helpful for scheduling.`
2. Все четыре узла отсеяны taint'ами: три нашими и один taint'ом control plane.
3. Taint с эффектом `NoSchedule` не трогает уже запущенные поды. Эффект `NoExecute` выселил бы и их.
4. Taints узлов видны командой `kubectl describe node | grep Taints`.
</details>

**Уборка:** `kubectl delete ns lab-12-2-t16`; проверьте `kubectl describe node | grep Taints` — наших taints быть не должно.

### T17. Том остался на другом узле

Уровень Middle, механизм объяснён в частях 04-2 §5, 05-3 §5.

**Поломка:** Том создан на одном узле, а новый под принудительно отправлен на другой.

```bash
mk t17
k apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: data}
spec: {accessModes: [ReadWriteOnce], resources: {requests: {storage: 100Mi}}}
---
apiVersion: v1
kind: Pod
metadata: {name: w1}
spec:
  nodeSelector: {kubernetes.io/hostname: lab-worker}
  containers:
  - name: c
    image: localhost:5001/busybox:1.37
    command: ["sleep", "3600"]
    volumeMounts: [{name: d, mountPath: /d}]
  volumes: [{name: d, persistentVolumeClaim: {claimName: data}}]
EOF
k wait --for=condition=Ready pod/w1
k delete pod w1
k apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata: {name: w2}
spec:
  nodeSelector: {kubernetes.io/hostname: lab-worker3}
  containers:
  - name: c
    image: localhost:5001/busybox:1.37
    command: ["sleep", "3600"]
    volumeMounts: [{name: d, mountPath: /d}]
  volumes: [{name: d, persistentVolumeClaim: {claimName: data}}]
EOF
```

**Симптом:** «После переезда на другой узел под с данными не стартует»: `w2` в `Pending`.

<details><summary>Решение</summary>

Убрать конфликтующий `nodeSelector`, тогда под поедет на узел тома, либо перенести данные на другой узел; для облачных дисков то же самое касается зон доступности.

```bash
k delete pod w2
k apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata: {name: w2}
spec:
  containers:
  - name: c
    image: localhost:5001/busybox:1.37
    command: ["sleep", "3600"]
    volumeMounts: [{name: d, mountPath: /d}]
  volumes: [{name: d, persistentVolumeClaim: {claimName: data}}]
EOF
k get pod w2 -o wide
```
</details>

<details><summary>Разбор</summary>

1. Событие: `0/4 nodes are available: 1 node(s) didn't match PersistentVolume's node affinity, 1 node(s) had untolerated taint(s), 2 node(s) didn't match Pod's node affinity/selector.`
2. Каждая группа узлов отсеяна по своей причине: том привязан к `lab-worker`, а селектор требует `lab-worker3`.
3. Привязку тома показывает `kubectl get pv -o jsonpath='{..nodeAffinity}'`. Класс `standard` (local-path) создаёт том на узле первого потребителя.
4. Общий вывод: том с локальным диском привязывает под к узлу навсегда.
</details>

**Уборка:** `kubectl delete ns lab-12-2-t17`; том `local-path` удаляется вместе с PVC.

### T18. Drain не проходит из-за PDB

Уровень Middle, механизм объяснён в частях 05-5 §5 и ЛР 1.

**Риски:**

- **Что меняется:** выбранный узел помечается `SchedulingDisabled` (cordon).
- **Влияние:** новые поды на узел не встанут, пока вы не выполните `uncordon`. Флаг `--pod-selector` ограничивает выселение подами сценария, чужие поды не трогаются.
- **Откат:** `kubectl uncordon` из «Уборки».

**Поломка:** Бюджет прерываний не разрешает убрать единственную реплику.

```bash
mk t18
k create deploy t18 --image=localhost:5001/busybox:1.37 -- sleep 3600
k create pdb t18 --selector=app=t18 --min-available=1
k rollout status deploy/t18
NODE=$(k get pod -l app=t18 -o jsonpath='{.items[0].spec.nodeName}')
kubectl drain "$NODE" --pod-selector=app=t18 --ignore-daemonsets \
  --delete-emptydir-data --timeout=20s
```

**Симптом:** Drain «висит» и заканчивается ошибкой по таймауту.

<details><summary>Решение</summary>

Сделать реплик не меньше двух, тогда бюджет разрешит выселить одну, или задать `maxUnavailable: 1`, но не удалять PDB молча, а договориться с владельцем сервиса.

```bash
k scale deploy t18 --replicas=2
k get pdb t18
```
</details>

<details><summary>Разбор</summary>

1. `k get pdb t18` показывает `ALLOWED DISRUPTIONS 0`.
2. Drain повторяет `Cannot evict pod as it would violate the pod's disruption budget.`, затем печатает `global timeout reached`.
3. `minAvailable: 1` при одной реплике значит «не трогать её никогда». Бюджет защищает сервис от drain.
4. Бюджет, который никогда не разрешает прерывание, блокирует обновление узлов и кластера (10-3).
</details>

**Уборка:**

```bash
kubectl uncordon "$NODE"
kubectl delete ns lab-12-2-t18
kubectl get nodes
```

Все узлы должны быть в состоянии `Ready` и без пометки `SchedulingDisabled`.

### T19. Профиль seccomp не найден на узле

Уровень Middle, механизм объяснён в частях 06-2 §5 и ЛР 1–2.

Эту работу вы выполняете сами, результаты в ней — ожидаемые.

**Поломка:** Под требует профиль seccomp из локального файла, которого на узлах нет.

```bash
mk t19
k apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata: {name: t19}
spec:
  securityContext:
    seccompProfile: {type: Localhost, localhostProfile: lab-12-2/missing.json}
  containers:
  - name: app
    image: localhost:5001/busybox:1.37
    command: ["sleep", "3600"]
EOF
sleep 10
k get pod t19
```

**Симптом:** Под назначен на узел, но контейнер не создаётся: статус `CreateContainerError`.

<details><summary>Решение</summary>

Разложить файл профиля на все узлы, где может оказаться под, в каталог `/var/lib/kubelet/seccomp/lab-12-2/`, либо перейти на профиль рантайма:

```bash
k delete pod t19
k apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata: {name: t19}
spec:
  securityContext:
    seccompProfile: {type: RuntimeDefault}
  containers:
  - name: app
    image: localhost:5001/busybox:1.37
    command: ["sleep", "3600"]
EOF
k wait --for=condition=Ready pod/t19
```
</details>

<details><summary>Разбор</summary>

1. Под прошёл admission и scheduler: проблема возникла на узле, при создании контейнера.
2. `k describe pod t19` показывает событие про seccomp-профиль и `no such file or directory` (текст зависит от версии containerd).
3. Путь `localhostProfile` отсчитывается от `/var/lib/kubelet/seccomp`. Admission-политики (PSA) проверяют только тип профиля, но не наличие файла.
4. Профили доставляют на узлы DaemonSet'ом или образом узла и проверяют на каждом новом узле.
</details>

**Уборка:** `kubectl delete ns lab-12-2-t19`.

## Middle: сеть

Все сценарии этого раздела читают ответ Gateway: код, время и тело подсказывают слой (11-3 §4).

### T20. Неверный targetPort

Уровень Middle, механизм объяснён в частях 03-2 §5, 11-3 §5.

**Риски:** сценарий меняет Service рабочего приложения в namespace `orders`, а не объекты своего namespace.

- **Что меняется:** порт `targetPort` у Service `orders-api`.
- **Влияние:** пока поломка активна, `orders.localhost:8088` отвечает 503.
- **Откат:** команда из «Решения»; она же в «Уборке».

**Поломка:**

```bash
kubectl -n orders patch svc orders-api --type=json \
  -p '[{"op":"replace","path":"/spec/ports/0/targetPort","value":8080}]'
sleep 4
C
```

**Симптом:** `C` отвечает `503` примерно за 1 мс и пишет `reset reason: remote connection failure`.

<details><summary>Решение</summary>

Вернуть именованный порт `http` и повторить запрос через Gateway:

```bash
kubectl -n orders patch svc orders-api --type=json \
  -p '[{"op":"replace","path":"/spec/ports/0/targetPort","value":"http"}]'
sleep 4
C
```
</details>

<details><summary>Разбор</summary>

1. В отличие от T06 здесь эндпоинты есть, но порт у них 8080, а контейнер слушает 8000.
2. SYN упирается в закрытый порт, приходит RST, Envoy отвечает 503 с флагом `UF`.
3. Проверка из пода: `curl podIP:8080` отказывает, `podIP:8000` отвечает 200.
4. Именованный `targetPort: http` устойчивее числа: он берётся из `containerPort` с этим именем.
</details>

**Уборка:** Команда из «Решения» вернула порт; `C` должен отвечать 200.

### T21. Всплеск 503 при каждом деплое

Уровень Middle, механизм объяснён в частях 02-5 §5 и ЛР 1–2.

Эту работу вы выполняете сами, результаты в ней — ожидаемые.

**Поломка:** Приложение закрывает порт сразу по SIGTERM, `preStop` нет, а нагрузка идёт во время `rollout restart`.

```bash
mk t21
k apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata: {name: t21}
spec:
  replicas: 4
  selector: {matchLabels: {app: t21}}
  template:
    metadata: {labels: {app: t21}}
    spec:
      containers:
      - name: api
        image: localhost:5001/orders-api:2.0
        ports: [{name: http, containerPort: 8000}]
        env: [{name: SHUTDOWN_DELAY, value: "0"}]
        readinessProbe: {httpGet: {path: /ready, port: http}, periodSeconds: 2}
        resources: {requests: {cpu: 50m, memory: 32Mi}, limits: {memory: 128Mi}}
---
apiVersion: v1
kind: Service
metadata: {name: t21}
spec:
  selector: {app: t21}
  ports: [{name: http, port: 80, targetPort: http}]
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: t21}
spec:
  parentRefs: [{name: lab, namespace: envoy-gateway-system}]
  hostnames: ["t21.localhost"]
  rules: [{backendRefs: [{name: t21, port: 80}]}]
EOF
k rollout status deploy/t21
(seq 1 1200 | xargs -P4 -I{} sh -c 'curl -s -o /dev/null -m 3 -w "%{http_code}\n" \
  http://t21.localhost:8088/version; sleep 0.05' | sort | uniq -c \
  > ~/lab/k8s/12-2/t21.txt) &
sleep 3
k rollout restart deploy/t21
k rollout status deploy/t21
wait
cat ~/lab/k8s/12-2/t21.txt
```

**Симптом:** «Каждый релиз — всплеск ошибок 503 у клиентов»: среди кодов ответа в файле есть не только `200`.

<details><summary>Решение</summary>

Дать потребителям адресов время убрать под из списков, а приложению — дожить до этого момента. Добавить `preStop` с паузой и проверить, что срок остановки не короче суммы:

```bash
k patch deploy t21 --type=json -p '[{"op":"add",
  "path":"/spec/template/spec/containers/0/lifecycle",
  "value":{"preStop":{"sleep":{"seconds":5}}}}]'
k rollout status deploy/t21
```

Повторите нагрузку и `rollout restart` из «Поломки»: ошибок должно стать меньше или не быть. Срока `terminationGracePeriodSeconds` по умолчанию (30 секунд) хватает для паузы в 5 секунд.
</details>

<details><summary>Разбор</summary>

1. Гонка: под удаляют из EndpointSlice и одновременно посылают SIGTERM. Envoy и kube-proxy обновляют правила за секунды и ещё шлют запросы в закрытый порт.
2. В измерениях 02-5 без паузы такой выкатки через Gateway было 10 и 19 ошибок в двух прогонах, с `preStop sleep 5` — 0 и 0.
3. Приложение здорово и все поды `Ready`: ошибки порождает порядок остановки, а не код.
4. Тот же эффект дают `SHUTDOWN_DELAY=5` в самом приложении и корректная обработка SIGTERM.
</details>

**Уборка:** `kubectl delete ns lab-12-2-t21`; `rm -f ~/lab/k8s/12-2/t21.txt`.

### T22. NetworkPolicy закрыла вход от Gateway

Уровень Middle, механизм объяснён в частях 03-6 §5 и ЛР 5, 11-3 §5.

Эту работу вы выполняете сами, результаты в ней — ожидаемые.

**Риски:** сценарий меняет рабочее приложение стенда в namespace `orders`, а не объекты своего namespace.

- **Что меняется:** в namespace `orders` создаются четыре NetworkPolicy из файла 03-6.
- **Влияние:** пока политика с ошибкой действует, `orders.localhost:8088` отвечает 503 через 10 секунд.
- **Откат:** `kubectl delete -f` из «Уборки».

**Поломка:** Набор политик 03-6 применён, но в правиле входа опечатка: namespace Gateway назван неверно. Если файла нет, выполните шаг 1 работы 5 из 03-6.

```bash
kubectl apply -f ~/lab/k8s/03-6/orders-netpol.yaml
kubectl -n orders patch networkpolicy orders-api --type=json -p '[{"op":"replace",
  "path":"/spec/ingress/0/from/0/namespaceSelector/matchLabels/kubernetes.io~1metadata.name",
  "value":"envoy-gateway"}]'
sleep 5
C
kubectl -n orders get pods -l app=orders-api
```

**Симптом:** `C` отвечает `503` ровно через 10 секунд, хотя поды при этом `1/1`.

<details><summary>Решение</summary>

Вернуть правильное имя namespace Gateway и повторить запрос:

```bash
kubectl -n orders patch networkpolicy orders-api --type=json -p '[{"op":"replace",
  "path":"/spec/ingress/0/from/0/namespaceSelector/matchLabels/kubernetes.io~1metadata.name",
  "value":"envoy-gateway-system"}]'
sleep 5
C
```
</details>

<details><summary>Разбор</summary>

1. Поды `Ready`: kubelet проверяет пробы с узла, а политика этот трафик не режет.
2. Ответ приходит ровно через 10 секунд с `reset reason: connection timeout`: пакеты от Envoy молча отбрасываются, а не отклоняются.
3. «Поды Ready, а сервис недоступен, и ответ приходит ровно через таймаут» — почти всегда NetworkPolicy. Ищите политики, которые выбирают под: `kubectl -n orders get netpol -o wide`.
4. Правило входа выбирает отправителя по метке namespace `kubernetes.io/metadata.name`. Опечатка в значении даёт «никого не пускать» без ошибки.
</details>

**Уборка:**

```bash
kubectl delete -f ~/lab/k8s/03-6/orders-netpol.yaml
kubectl -n orders get networkpolicy
C
```

Вторая команда должна ответить `No resources found`, третья — `200`, а файл политик остаётся на диске для других сценариев.

### T23. Egress разрешён без DNS

Уровень Middle, механизм объяснён в частях 03-6 ЛР 3, 03-3 §5, 11-3 §5.

**Риски:** сценарий меняет рабочее приложение стенда в namespace `orders`, а не объекты своего namespace.

- **Что меняется:** политика исходящего трафика для подов `orders-api`.
- **Влияние:** пока она есть, поды `orders-api` не готовы, а `orders.localhost:8088` отвечает 504 через 15 секунд.
- **Откат:** `kubectl delete networkpolicy` из «Уборки».

**Поломка:** Разрешили только соединение с PostgreSQL и забыли про DNS.

```bash
kubectl -n orders apply -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: t-egress-db-only}
spec:
  podSelector: {matchLabels: {app: orders-api}}
  policyTypes: [Egress]
  egress:
  - to: [{podSelector: {matchLabels: {app: postgres}}}]
    ports: [{port: 5432, protocol: TCP}]
EOF
sleep 15
C
kubectl -n orders get pods -l app=orders-api
```

**Симптом:** `C` отвечает `504 upstream request timeout` через 15 секунд, поды `0/1`.

<details><summary>Решение</summary>

Добавить правило исходящего трафика к kube-dns на порт 53 по UDP и TCP. Политики складываются, поэтому достаточно создать вторую политику рядом с первой:

```bash
kubectl -n orders apply -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: t-allow-dns}
spec:
  podSelector: {matchLabels: {app: orders-api}}
  policyTypes: [Egress]
  egress:
  - to:
    - namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: kube-system}}
      podSelector: {matchLabels: {k8s-app: kube-dns}}
    ports: [{port: 53, protocol: UDP}, {port: 53, protocol: TCP}]
EOF
sleep 15
C
```
</details>

<details><summary>Разбор</summary>

1. Изнутри пода `getaddrinfo('postgres')` падает с `Temporary failure in name resolution` примерно через 20 секунд: `kubectl -n orders exec <под> -- python -c "import socket; print(socket.getaddrinfo('postgres',5432)[0][4])"`.
2. TCP по IP к базе при этом проходит за миллисекунды. Значит, сломан именно DNS, а не сеть.
3. Readiness `/ready` проверяет базу, поэтому поды стали `0/1`. В Envoy флаг `UT` и `response_timeout`.
4. Классика при внедрении default-deny: разрешили базу и забыли kube-dns.
</details>

**Уборка:**

```bash
kubectl -n orders delete networkpolicy t-egress-db-only t-allow-dns --ignore-not-found
kubectl -n orders get networkpolicy
C
```

### T24. Весь трафик уходит в одну версию

Уровень Middle, механизм объяснён в частях 03-4 §5 и ЛР 2.

Эту работу вы выполняете сами, результаты в ней — ожидаемые.

**Поломка:** Canary должен получать 10 % запросов, но в маршруте скопирована строка с неверным именем backend.

```bash
mk t24
for v in a:2.0 b:2.1; do
k apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata: {name: api-${v%%:*}}
spec:
  replicas: 2
  selector: {matchLabels: {app: api-${v%%:*}}}
  template:
    metadata: {labels: {app: api-${v%%:*}}}
    spec:
      containers:
      - name: api
        image: localhost:5001/orders-api:${v##*:}
        ports: [{name: http, containerPort: 8000}]
        readinessProbe: {httpGet: {path: /ready, port: http}, periodSeconds: 2}
---
apiVersion: v1
kind: Service
metadata: {name: api-${v%%:*}}
spec:
  selector: {app: api-${v%%:*}}
  ports: [{name: http, port: 80, targetPort: http}]
EOF
done
k apply -f - <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: t24}
spec:
  parentRefs: [{name: lab, namespace: envoy-gateway-system}]
  hostnames: ["t24.localhost"]
  rules:
  - backendRefs:
    - {name: api-b, port: 80, weight: 90}
    - {name: api-b, port: 80, weight: 10}
EOF
k rollout status deploy/api-a; k rollout status deploy/api-b
sleep 3
for i in $(seq 1 200); do curl -s http://t24.localhost:8088/version; echo; done \
  | jq -r .version | sort | uniq -c
```

**Симптом:** Команда считает версии в 200 ответах: нужное распределение — около 180 ответов на `2.0` и 20 на `2.1`, а фактическое другое.

<details><summary>Решение</summary>

В первой строке `backendRefs` должен стоять `api-a`, после чего замер нужно повторить:

```bash
k patch httproute t24 --type=json \
  -p '[{"op":"replace","path":"/spec/rules/0/backendRefs/0/name","value":"api-a"}]'
sleep 3
for i in $(seq 1 200); do curl -s http://t24.localhost:8088/version; echo; done \
  | jq -r .version | sort | uniq -c
```

Распределение случайное: ожидайте около 180 ответов `2.0` и около 20 ответов `2.1`, а не ровно эти числа.
</details>

<details><summary>Разбор</summary>

1. Обе строки `backendRefs` указывают на `api-b`, поэтому делить трафик не между чем: все 200 ответов приходят с версии `2.1`. Веса 90 и 10 складываются в 100 %, и ошибка не видна по сумме.
2. `k get httproute t24 -o jsonpath='{.spec.rules[0].backendRefs[*].name}'` показывает `api-b api-b`. Условия маршрута при этом нормальные: Gateway принимает такой манифест.
3. Вес делит запросы между Service, а не между подами: число реплик на долю не влияет (03-4 ЛР 2).
4. Другие причины того же симптома: вес `0` у старой версии, правило с заголовком без пути перехватывает весь трафик. Проверяйте распределение замером, а не чтением манифеста.
</details>

**Уборка:** `kubectl delete ns lab-12-2-t24`.

## Middle: выкатка и политики

Здесь поломку вносит процесс поставки: чарт, политика допуска или компонент платформы (07-1, 06-3, 06-4, 11-1).

### T25. Pod Security отклонил Deployment

Уровень Middle, механизм объяснён в частях 06-3 §5 и ЛР 1.

Эту работу вы выполняете сами, результаты в ней — ожидаемые.

**Поломка:** В namespace включён уровень `restricted`, а Deployment написан без `securityContext`.

```bash
mk t25
kubectl label ns "$NS" pod-security.kubernetes.io/enforce=restricted
k create deploy t25 --image=localhost:5001/orders-api:2.0 --port=8000
sleep 5
k get deploy t25
```

**Симптом:** Deployment `0/1`, подов нет, у самого Deployment ошибки не видно.

<details><summary>Решение</summary>

Добавить в шаблон пода поля, которые требует `restricted`: сообщение об отказе перечисляет их все, поэтому угадывать не нужно:

```bash
k delete deploy t25
k apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata: {name: t25}
spec:
  replicas: 1
  selector: {matchLabels: {app: t25}}
  template:
    metadata: {labels: {app: t25}}
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
k rollout status deploy/t25
```
</details>

<details><summary>Разбор</summary>

1. Deployment создаёт ReplicaSet, а тот пытается создать под. Отказ PSA приходит ReplicaSet: `k describe rs | grep -m1 FailedCreate`.
2. Сообщение: `violates PodSecurity "restricted:latest": allowPrivilegeEscalation != false …, runAsNonRoot != true …, seccompProfile …`.
3. Режим `enforce` не проверяет уже работающие поды: они продолжают жить. Поэтому поломка проявляется при очередном деплое.
4. Внедряйте уровень через `warn` и `audit`, а `enforce` включайте после очистки манифестов.
</details>

**Уборка:** `kubectl delete ns lab-12-2-t25`.

### T26. Образ из неразрешённого реестра

Уровень Middle, механизм объяснён в частях 06-4 §5 и ЛР 2, 06-3 §5.

Эту работу вы выполняете сами, результаты в ней — ожидаемые.

**Поломка:** Политика допуска разрешает образы только из реестра стенда, а команда выкатывает образ без указания реестра.

```bash
mk t26
kubectl apply -f - <<'EOF'
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata: {name: lab-12-2-t26-registries}
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
    - {apiGroups: [""], apiVersions: [v1], operations: [CREATE, UPDATE], resources: [pods]}
  validations:
  - expression: object.spec.containers.all(c, c.image.startsWith('localhost:5001/'))
    messageExpression: >-
      'образ не из разрешённых реестров: ' + object.spec.containers.map(c, c.image).join(', ')
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata: {name: lab-12-2-t26-registries}
spec:
  policyName: lab-12-2-t26-registries
  validationActions: [Deny]
  matchResources:
    namespaceSelector:
      matchLabels: {kubernetes.io/metadata.name: lab-12-2-t26}
EOF
sleep 3
k create deploy t26 --image=busybox:1.37 -- sleep 3600
sleep 5
k get deploy t26
```

**Симптом:** Deployment `0/1` и подов нет, хотя в образе, как кажется, нет ничего плохого.

<details><summary>Решение</summary>

Указать образ из разрешённого реестра: политика сравнивает строку образа, поэтому `busybox:1.37`, то есть образ из `docker.io`, не проходит проверку:

```bash
k set image deploy/t26 busybox=localhost:5001/busybox:1.37
k rollout status deploy/t26
```
</details>

<details><summary>Разбор</summary>

1. Отказ приходит ReplicaSet: `k describe rs | grep -m1 'denied request'`.
2. Сообщение называет политику, привязку и текст из `messageExpression`: `образ не из разрешённых реестров: busybox:1.37`.
3. Системные поды и Job'ы иногда тоже тянут образы из других реестров. Перед переходом на `Deny` включайте `Warn` и смотрите, кого заденет.
4. Образ без префикса реестра разворачивается в `docker.io`, и префиксная проверка его отклоняет. Чинят явным полным именем в манифесте.
</details>

**Уборка:**

```bash
kubectl delete validatingadmissionpolicybinding lab-12-2-t26-registries
kubectl delete validatingadmissionpolicy lab-12-2-t26-registries
kubectl delete ns lab-12-2-t26
```

Привязку удаляют раньше политики, на которую она ссылается, а namespace — последним.

### T27. Helm-релиз завис в pending-upgrade

Уровень Middle, механизм объяснён в частях 07-1 §5 и ЛР 3.

**Поломка:** CI убил `helm upgrade` посреди выкатки. Сценарий опирается на релиз `shop` в namespace `lab-07-1` и чарт в `~/lab/k8s/charts/orders-api` из 07-1; если релиза нет, выполните работы 1–3 из 07-1.

```bash
cd ~/lab/k8s/charts
timeout -s KILL 5 helm upgrade shop ./orders-api -n lab-07-1 --reuse-values \
  --set image.tag=2.9 --wait --timeout 2m; echo "exit=$?"
helm upgrade shop ./orders-api -n lab-07-1 --reuse-values --set image.tag=2.1
```

**Симптом:** Следующий деплой того же релиза отклоняется с сообщением `Error: UPGRADE FAILED: another operation (install/upgrade/rollback) is in progress`.

<details><summary>Решение</summary>

Откатить релиз на последнюю удачную ревизию и повторить upgrade:

```bash
helm rollback shop -n lab-07-1
helm upgrade shop ./orders-api -n lab-07-1 --reuse-values --set image.tag=2.1 \
  --wait --timeout 60s
```

В CI сделайте таймаут helm меньше таймаута задания и запретите параллельные деплои одного релиза.
</details>

<details><summary>Разбор</summary>

1. Код 137 у убитой команды — это 128 плюс сигнал 9: helm не успел записать итог.
2. `helm history shop -n lab-07-1` показывает последнюю ревизию в статусе `pending-upgrade`. Helm сам его не снимет.
3. В Secret релиза видны две записи: прошлая `deployed` и зависшая `pending-upgrade`: `kubectl -n lab-07-1 get secret -l owner=helm -L status`.
4. Для зависшей первой установки (`pending-install`) откатываться некуда: удаляют Secret зависшей ревизии, проверяют объекты и повторяют установку.
</details>

**Уборка:** релиз `shop` остаётся на образе `2.1`, как в конце работы 3 из 07-1, и `helm status shop -n lab-07-1` показывает `deployed`. Если вы поднимали релиз только ради сценария, уберите его по уборке работы 4 из 07-1.

### T28. kubectl top не работает

Уровень Middle, механизм объяснён в частях 11-1 §5, 09-2 ЛР 4.

Эту работу вы выполняете сами, результаты в ней — ожидаемые.

**Риски:**

- **Что меняется:** Deployment `metrics-server` в `kube-system` масштабируется до нуля.
- **Влияние:** на 1–2 минуты не работают `kubectl top` и HPA. Поды и сервисы работают как раньше.
- **Откат:** `scale --replicas=1` из «Решения».

**Поломка:**

```bash
kubectl -n kube-system scale deploy metrics-server --replicas=0
sleep 20
kubectl top nodes
```

**Симптом:** Команда `kubectl top nodes` печатает `error: Metrics API not available`, хотя узлы и поды работают.

<details><summary>Решение</summary>

Вернуть metrics-server и подождать, пока APIService снова станет доступным для запросов:

```bash
kubectl -n kube-system scale deploy metrics-server --replicas=1
kubectl -n kube-system rollout status deploy/metrics-server
sleep 20
kubectl top nodes
```

Если `top` всё ещё отвечает ошибкой, подождите ещё 20 секунд: APIService становится доступным не сразу после старта пода.
</details>

<details><summary>Разбор</summary>

1. Сообщение значит, что API-сервер не нашёл ответчика для группы `metrics.k8s.io`.
2. `kubectl get apiservice v1beta1.metrics.k8s.io` показывает `AVAILABLE False`, причина `MissingEndpoints`: у Service нет подов.
3. Другие причины недоступности: `FailedDiscoveryCheck`, `x509: certificate signed by unknown authority` в логе metrics-server (нужен `--kubelet-insecure-tls` или подписанные сертификаты kubelet), `i/o timeout` до порта 10250.
4. Сообщение `metrics not available yet` — другое: metrics-server работает, но замеров для нового пода ещё нет (30–60 секунд).
5. Побочный эффект: HPA остаются без метрик и перестают масштабировать (T15).
</details>

**Уборка:** откат уже сделан в «Решении»; проверьте, что `kubectl -n kube-system get deploy metrics-server` показывает `1/1`.

## Senior: доступ и токены

Сценарии этого раздела выглядят как «приложение не работает», но причина лежит в аутентификации и RBAC (06-1). Главный вопрос в них — какой код вернул API-сервер, 401 или 403.

### T29. Токен ServiceAccount не смонтирован

Уровень Senior, механизм объяснён в частях 06-1 §5 и ЛР 3.

Эту работу вы выполняете сами, результаты в ней — ожидаемые.

**Поломка:** У ServiceAccount есть права, но токен в под не кладётся: ему отключён `automountServiceAccountToken`.

```bash
mk t29
k create sa app
k create role pod-reader --verb=get,list --resource=pods
k create rolebinding app-pods --role=pod-reader --serviceaccount=$NS:app
k patch sa app -p '{"automountServiceAccountToken":false}'
k apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata: {name: t29}
spec:
  serviceAccountName: app
  containers:
  - name: app
    image: localhost:5001/busybox:1.37
    command:
    - sh
    - -c
    - |
      until test -s /var/run/secrets/kubernetes.io/serviceaccount/token
      do echo 'токен не найден' >&2; sleep 5; done; sleep 3600
EOF
sleep 10
k logs t29
kubectl auth can-i list pods -n $NS --as system:serviceaccount:$NS:app
```

**Симптом:** «Приложение не может обратиться к API»: в логах жалоба на отсутствие токена, а проверка прав отвечает `yes`.

<details><summary>Решение</summary>

Значение в поде главнее значения в ServiceAccount, поэтому пересоздайте под, которому токен нужен, с `automountServiceAccountToken: true`:

```bash
k delete pod t29
k apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata: {name: t29}
spec:
  serviceAccountName: app
  automountServiceAccountToken: true
  containers:
  - name: app
    image: localhost:5001/busybox:1.37
    command: ["sleep", "3600"]
EOF
k wait --for=condition=Ready pod/t29
k exec t29 -- ls /var/run/secrets/kubernetes.io/serviceaccount
```

Лучше разделить ServiceAccount: один без токена для приложений, которым API не нужен, другой с токеном для остальных.
</details>

<details><summary>Разбор</summary>

1. Права и токен — разные вещи. Роль даёт право, токен доказывает, кто делает запрос. Без токена запрос не будет авторизован этим ServiceAccount.
2. `k get pod t29 -o jsonpath='{.spec.volumes}'` не показывает projected-том с токеном: kubelet его не создал.
3. Каталог `/var/run/secrets/kubernetes.io/serviceaccount` в поде отсутствует, поэтому `ls` отвечает `No such file or directory`.
4. Отключение токена у приложений, которым API не нужен, — защита: украденный токен не даёт доступа. Здесь защита сработала против приложения, которому токен нужен.
</details>

**Уборка:** `kubectl delete ns lab-12-2-t29`.

### T30. Токен умер вместе с подом

Уровень Senior, механизм объяснён в частях 06-1 §5 и ЛР 3 (шаг 5).

Эту работу вы выполняете сами, результаты в ней — ожидаемые.

**Поломка:** CI использует токен, выпущенный с привязкой к поду-раннеру, а раннер пересоздали.

```bash
mk t30
k create sa runner
k create role pod-reader --verb=get,list --resource=pods
k create rolebinding runner-pods --role=pod-reader --serviceaccount=$NS:runner
k apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata: {name: runner}
spec:
  serviceAccountName: runner
  terminationGracePeriodSeconds: 1
  containers:
  - {name: c, image: "localhost:5001/busybox:1.37", command: ["sleep", "3600"]}
EOF
k wait --for=condition=Ready pod/runner
SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
kubectl config view --raw --minify \
  -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d \
  > ~/lab/k8s/12-2/ca.crt
POD_UID=$(k get pod runner -o jsonpath='{.metadata.uid}')
BOUND=$(k create token runner --duration=10m --bound-object-kind=Pod \
  --bound-object-name=runner --bound-object-uid="$POD_UID")
api() { curl -s -o /dev/null -w '%{http_code}\n' --cacert ~/lab/k8s/12-2/ca.crt \
  -H "Authorization: Bearer $BOUND" "$SERVER/api/v1/namespaces/$NS/pods"; }
api
k delete pod runner
sleep 5
api
```

**Симптом:** Первый вызов `api` отвечает `200`, второй — `401`, хотя до конца срока токена ещё около 8 минут.

<details><summary>Решение</summary>

Не привязывать долгоживущую работу CI к объекту, который пересоздаётся, а выпускать токен без привязки к поду, на короткий срок и в начале задания:

```bash
BOUND=$(k create token runner --duration=10m)
api
```

Для CI вне кластера лучше короткоживущие учётные данные от внешнего провайдера идентичности, чем постоянные токены.
</details>

<details><summary>Разбор</summary>

1. 401 значит, что кластер больше не признаёт токен субъектом. 403 значил бы, что токен признан, но роль не разрешает действие.
2. Токен, привязанный к поду, действителен, пока жив этот под (его UID). После удаления пода проверка привязки не проходит.
3. Токен в файле пода kubelet обновляет заранее, а приложение, которое прочитало файл один раз при старте, получит 401, когда истечёт срок прочитанного токена. Современные клиентские библиотеки перечитывают файл сами, самописный код нужно проверять.
4. С 1.24 Secret-токены без срока не создаются автоматически, а с 1.30 неиспользуемые старые токены помечаются и удаляются. Создавать такой Secret вручную ради CI не нужно.
</details>

**Уборка:** `kubectl delete ns lab-12-2-t30`; `rm -f ~/lab/k8s/12-2/ca.crt`; `unset BOUND POD_UID SERVER; unset -f api`.

### T31. Ошибочная привязка edit

Уровень Senior, механизм объяснён в частях 06-1 §5 и ЛР 4.

Эту работу вы выполняете сами, результаты в ней — ожидаемые.

**Поломка:** Группе разработчиков выдали роль `edit` вместо `view`.

```bash
mk t31
k create rolebinding oops-edit --clusterrole=edit --group=lab-12-2-devs
```

**Симптом:** Аудит безопасности: участники группы разработчиков читают Secret в namespace. Проверьте это одной командой, не заходя в кластер под этой группой.

<details><summary>Решение</summary>

Проверить, найти привязку и заменить её на роль без доступа к Secret:

```bash
kubectl auth can-i get secrets -n $NS --as lab-anna --as-group lab-12-2-devs
k delete rolebinding oops-edit
k create rolebinding devs-view --clusterrole=view --group=lab-12-2-devs
kubectl auth can-i get secrets -n $NS --as lab-anna --as-group lab-12-2-devs
```

Первая проверка отвечает `yes`, а последняя после замены привязки — `no`.
</details>

<details><summary>Разбор</summary>

1. Подмена `--as` и `--as-group` показывает права без смены учётных данных. Субъекта кластер не проверяет: пользователя `lab-anna` может не существовать.
2. Роли `admin`, `edit` и `cluster-admin` читают Secret. Роль `view` — нет.
3. Найти такие привязки по всему кластеру можно запросом `jq` по `rolebindings,clusterrolebindings` из 06-1 ЛР 4: сначала список ролей, читающих Secret, затем привязки к ним.
4. Правило эскалации прав: тот, кто создаёт привязку, должен сам иметь эти права. Администратор стенда имеет, поэтому привязка создана без возражений.
5. Привязки с группами `system:authenticated` и `system:unauthenticated` ищите отдельно: они выдают права всем сразу.
</details>

**Уборка:** `kubectl delete ns lab-12-2-t31`.

## Senior: расширение API и защита API-сервера

Вебхуки и finalizers могут остановить кластер, а шумные клиенты отнимают у него пропускную способность; механизмы описаны в 09-2 и 01-1 §3.

### T32. Вебхук положил деплои

Уровень Senior, механизм объяснён в частях 09-2 §5 и ЛР 1–2.

**Риски:**

- **Что меняется:** создаётся `ValidatingWebhookConfiguration`, которая отказывает во всех создаваемых подах namespace `lab-12-2-t32`.
- **Влияние:** другие namespace не затронуты, пока на них нет метки `lab-12-2/policy=on`. Если ошибиться в селекторе, вебхук охватит больше.
- **Откат:** `kubectl delete validatingwebhookconfiguration lab-12-2-t32-policy`. Объекты конфигураций вебхуков через вебхуки не проходят, поэтому удаление работает при любой блокировке.

**Поломка:** Вебхук с `failurePolicy: Fail` ссылается на Service, которого нет.

```bash
mk t32
kubectl label ns "$NS" lab-12-2/policy=on
kubectl apply -f - <<'EOF'
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingWebhookConfiguration
metadata: {name: lab-12-2-t32-policy}
webhooks:
- name: pods.policy.lab.local
  admissionReviewVersions: [v1]
  sideEffects: None
  failurePolicy: Fail
  timeoutSeconds: 5
  namespaceSelector:
    matchLabels: {lab-12-2/policy: "on"}
  rules:
  - {apiGroups: [""], apiVersions: [v1], operations: [CREATE], resources: [pods]}
  clientConfig:
    service: {name: policy-webhook, namespace: lab-12-2-t32, path: /validate, port: 443}
EOF
sleep 2
k create deploy t32 --image=localhost:5001/busybox:1.37 -- sleep 3600
sleep 5
k get deploy t32
```

**Симптом:** «Deployment `0/1`, в поде ошибок нет, потому что пода нет».

<details><summary>Решение</summary>

Поднять сервис вебхука либо аварийно удалить конфигурацию и перезапустить выкатку:

```bash
kubectl delete validatingwebhookconfiguration lab-12-2-t32-policy
k rollout restart deploy/t32
k rollout status deploy/t32
```

Для постоянного решения вебхуку нужны 2–3 реплики с PodDisruptionBudget, `namespaceSelector`, исключающий системные namespace и сам вебхук, и `timeoutSeconds` 2–5 секунд.
</details>

<details><summary>Разбор</summary>

1. Поды создаёт ReplicaSet, поэтому ошибка видна в его событиях: `k describe rs | grep -m1 'Error creating'`.
2. Сообщение: `Error creating: Internal error occurred: failed calling webhook "pods.policy.lab.local": … service "policy-webhook" not found`. Отказ пришёл за сотни миллисекунд: до адреса даже не дошли.
3. Если бы сервер принимал соединение и молчал, отказ пришёл бы только через `timeoutSeconds`, около 5 секунд, с текстом `context deadline exceeded`.
4. Вебхук на поды без исключений может заблокировать и собственный под вебхука, и системные поды: взаимная блокировка (09-2 §5).
5. Дежурному нужна команда аварийного удаления конфигурации заранее в runbook. В 1.30+ CEL-политики (VAP) сети не используют и такой блокировки не имеют.
</details>

**Уборка:**

```bash
kubectl delete validatingwebhookconfiguration lab-12-2-t32-policy --ignore-not-found
kubectl delete ns lab-12-2-t32
```

### T33. Namespace завис в Terminating

Уровень Senior, механизм объяснён в частях 09-2 §5 и ЛР 3, 01-3 §5.

**Поломка:** ConfigMap с finalizer, который никто не обрабатывает, лежит в удаляемом namespace.

```bash
mk t33
k create cm stuck --from-literal=a=1
k patch cm stuck -p '{"metadata":{"finalizers":["example.com/external-cleanup"]}}'
kubectl delete ns "$NS" --wait=false
sleep 8
kubectl get ns "$NS"
```

**Симптом:** Namespace бесконечно остаётся в `Terminating`, хотя команда удаления давно вернула управление.

<details><summary>Решение</summary>

Найти объект и владельца finalizer, затем вернуть контроллер, который его снимает, или осознанно снять finalizer вручную:

```bash
kubectl api-resources --verbs=list --namespaced -o name | xargs -n 30 | tr ' ' ',' \
  | while read t; do kubectl -n "$NS" get $t --ignore-not-found -o name; done
k patch cm stuck --type=merge -p '{"metadata":{"finalizers":null}}'
kubectl get ns "$NS"
```

Помните, что finalizer охраняет внешний ресурс, поэтому перед снятием проверьте, что этот ресурс удалён.
</details>

<details><summary>Разбор</summary>

1. Условия namespace называют причину: `kubectl get ns "$NS" -o jsonpath='{range .status.conditions[*]}{.type}={.status}: {.message}{"\n"}{end}' | grep -v '=False'`.
2. `NamespaceContentRemaining` называет тип оставшихся объектов (`configmaps`), `NamespaceFinalizersRemaining` — сам finalizer `example.com/external-cleanup`. Домен подсказывает владельца.
3. Перебор типов находит имя объекта: условие называет тип, но не имя.
4. Рецепт с `kubectl replace --raw …/finalize` убирает namespace, но оставляет объекты в хранилище без очистки. Не используйте его без понимания последствий.
5. Другая причина зависания — недоступный APIService (`NamespaceDeletionDiscoveryFailure`): проверьте `kubectl get apiservice` на `False`.
</details>

**Уборка:** Если namespace не исчез, `kubectl get ns "$NS"` должен ответить `NotFound` после снятия finalizer.

### T34. Шумный клиент получает 429

Уровень Senior, механизм объяснён в частях 01-1 §3.

Эту работу вы выполняете сами, результаты в ней — ожидаемые.

**Риски:**

- **Что меняется:** создаются `PriorityLevelConfiguration` и `FlowSchema` (объекты кластера), которые действуют только на один ServiceAccount.
- **Влияние:** на остальных клиентов и kubelet они не влияют. Нагрузка — до 100 параллельных запросов `curl` на 2–3 секунды.
- **Откат:** удаление обоих объектов в «Уборке».

**Поломка:** ServiceAccount получает отдельную очередь с минимальным лимитом одновременных запросов. Затем он отправляет много запросов подряд, как оператор с неудачным циклом опроса.

```bash
mk t34
k create sa noisy
k create rolebinding noisy-view --clusterrole=view --serviceaccount=$NS:noisy
kubectl apply -f - <<'EOF'
apiVersion: flowcontrol.apiserver.k8s.io/v1
kind: PriorityLevelConfiguration
metadata: {name: lab-12-2-t34-tiny}
spec:
  type: Limited
  limited:
    nominalConcurrencyShares: 1
    lendablePercent: 0
    borrowingLimitPercent: 0
    limitResponse: {type: Reject}
---
apiVersion: flowcontrol.apiserver.k8s.io/v1
kind: FlowSchema
metadata: {name: lab-12-2-t34-noisy}
spec:
  priorityLevelConfiguration: {name: lab-12-2-t34-tiny}
  matchingPrecedence: 8000
  distinguisherMethod: {type: ByUser}
  rules:
  - subjects:
    - kind: ServiceAccount
      serviceAccount: {name: noisy, namespace: lab-12-2-t34}
    resourceRules:
    - {verbs: ["*"], apiGroups: ["*"], resources: ["*"], namespaces: ["*"]}
EOF
SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
kubectl config view --raw --minify \
  -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d \
  > ~/lab/k8s/12-2/ca.crt
TOKEN=$(k create token noisy --duration=10m)
seq 1 2000 | xargs -P100 -I{} curl -s -o /dev/null -w '%{http_code}\n' \
  --cacert ~/lab/k8s/12-2/ca.crt -H "Authorization: Bearer $TOKEN" \
  "$SERVER/api/v1/namespaces/$NS/pods" | sort | uniq -c
kubectl get nodes
```

**Симптом:** Среди кодов ответа есть `429`, а `kubectl get nodes` от администратора работает без задержек; если `429` нет, увеличьте параллелизм `-P`.

<details><summary>Решение</summary>

Чинят клиента, а не сервер: вместо опроса использовать `watch` или informer, добавить экспоненциальный backoff и учитывать заголовок `Retry-After`. Если клиенту нужна своя очередь, ей задают отдельную `PriorityLevelConfiguration` с достаточным числом долей.
</details>

<details><summary>Разбор</summary>

1. Ответ 429 `Too Many Requests` — защита API Priority and Fairness: запросы делятся на очереди по приоритетам, и шумный клиент не занимает весь сервер.
2. Метрика `apiserver_flowcontrol_rejected_requests_total` растёт для нашей очереди: `kubectl get --raw /metrics | grep apiserver_flowcontrol_rejected_requests_total | grep t34`.
3. Запросы kubelet идут в уровни `node-high` и `system`, выбор лидера — в `leader-election`. Поэтому узлы и компоненты продолжают работать.
4. Поле `borrowingLimitPercent: 0` запрещает уровню занимать места у соседей. Без него лимит заимствования бесконечен, и уровень с одной долей мог бы не отказать ни разу.
5. ServiceAccount по умолчанию попадает в `workload-low` (FlowSchema `service-accounts`). Наша схема стоит раньше, потому что порядок 8000 меньше 9000.
6. Не помечайте клиентов как `exempt` ради «чтобы не падало»: так вы убираете защиту целиком.
</details>

**Уборка:**

```bash
kubectl delete flowschema lab-12-2-t34-noisy
kubectl delete prioritylevelconfiguration lab-12-2-t34-tiny
kubectl delete ns lab-12-2-t34
rm -f ~/lab/k8s/12-2/ca.crt
unset TOKEN SERVER
```

Схему удаляют раньше уровня приоритета, на который она ссылается, а namespace и файл — последними.

## Senior: control plane и etcd

Эти сценарии выключают компоненты control plane, поэтому перед каждым решите, что должно продолжать работать, а что нет (01-1, 11-4).

### T35. Pending без событий

Уровень Senior, механизм объяснён в частях 01-1 §5 и ЛР 3, 11-4 §5.

**Риски:**

- **Что меняется:** файл манифеста scheduler переносится из `/etc/kubernetes/manifests` в `/root` внутри `lab-control-plane`.
- **Влияние:** пока файл вне каталога, новые поды всех namespace остаются в `Pending`. Запущенные поды и трафик не страдают.
- **Откат:** команда `mv` обратно; она же в «Решении». Файл сам не вернётся.

**Поломка:**

```bash
docker exec lab-control-plane mv /etc/kubernetes/manifests/kube-scheduler.yaml /root/
sleep 20
mk t35
k run t35 --image=localhost:5001/busybox:1.37 --restart=Never -- sleep 3600
sleep 15
k get pod t35
k get events --field-selector involvedObject.name=t35
```

**Симптом:** Новый под в `Pending`, у него нет ни одного события.

<details><summary>Решение</summary>

Вернуть манифест на место, после чего kubelet запустит scheduler заново, и проверить, что под получил узел:

```bash
docker exec lab-control-plane mv /root/kube-scheduler.yaml /etc/kubernetes/manifests/
sleep 20
k get pod t35
docker exec lab-control-plane ls /etc/kubernetes/manifests
```

Под получает узел примерно через 2–3 секунды после возврата файла, а в каталоге манифестов должны лежать четыре файла.
</details>

<details><summary>Разбор</summary>

1. Нет событий: ни `Scheduled`, ни `FailedScheduling`. Значит, никто не пытался его планировать. Нехватка места дала бы `FailedScheduling`.
2. Lease `kube-scheduler` в `kube-system` не обновляется: `kubectl -n kube-system get lease kube-scheduler -o jsonpath='{.spec.renewTime}{"\n"}'`; сравните с `date -u +%T`.
3. На control plane `docker exec lab-control-plane crictl ps --name kube-scheduler` ничего не печатает. Mirror pod в API может висеть как `Completed`, поэтому проверяйте процесс на узле.
4. Ещё одна причина Pending без событий — чужой `schedulerName` в поде.
5. Deployment-контроллер и ReplicaSet-контроллер работают без scheduler: поды создаются, но не получают узел.
</details>

**Уборка:** `kubectl delete ns lab-12-2-t35`, затем проверьте, что `ls /etc/kubernetes/manifests` внутри узла показывает четыре файла.

### T36. Controller-manager выключен

Уровень Senior, механизм объяснён в частях 01-1 §5 и ЛР 3.

**Риски:**

- **Что меняется:** манифест controller-manager переносится в `/root` внутри `lab-control-plane`.
- **Влияние:** во всём кластере перестают работать контроллеры: реплики не меняются, упавшие поды не заменяются, узлы не получают `Unknown`. Запущенные поды и трафик живут.
- **Откат:** `mv` обратно из «Решения». Не держите выключенным дольше сценария.

**Поломка:**

```bash
mk t36
k create deploy t36 --image=localhost:5001/busybox:1.37 --replicas=2 -- sleep 3600
k rollout status deploy/t36
docker exec lab-control-plane mv /etc/kubernetes/manifests/kube-controller-manager.yaml /root/
sleep 10
k scale deploy t36 --replicas=4
k delete pod "$(k get pods -o jsonpath='{.items[0].metadata.name}')"
sleep 20
k get deploy,rs,pods
```

**Симптом:** «Масштабирование не работает, удалённый под не вернулся»: у Deployment `2/4`, а живой под один.

<details><summary>Решение</summary>

Вернуть манифест на место, и контроллеры выполнят накопленную работу разом:

```bash
SECONDS=0
docker exec lab-control-plane mv /root/kube-controller-manager.yaml /etc/kubernetes/manifests/
until [ "$(k get deploy t36 -o jsonpath='{.status.readyReplicas}')" = 4 ]; do sleep 1; done
echo "прошло ${SECONDS} с"
```

Около 15 секунд из примерно 21 новый экземпляр ждёт, пока истечёт аренда лидера.
</details>

<details><summary>Разбор</summary>

1. `scale` принят API-сервером, поле желаемых реплик у Deployment равно 4. Но ReplicaSet не получил новое значение: `DESIRED` у него остался 2, ведь передать его мог только controller-manager.
2. Удалённый под не пересоздан: ReplicaSet-контроллера нет.
3. Статусы Deployment и ReplicaSet устарели: они показывают два готовых пода, но жив один. Status пишет контроллер.
4. Узел с остановленным kubelet тоже не станет `NotReady`, пока контроллера узлов нет: он ставит `Unknown`.
5. Признак на практике: объекты принимаются, но ничего не происходит. Смотрите, живы ли static pod'ы control plane и кто держит Lease `kube-controller-manager`.
</details>

**Уборка:** `kubectl delete ns lab-12-2-t36`; `docker exec lab-control-plane ls /etc/kubernetes/manifests` показывает четыре файла.

### T37. API-сервер недоступен, а сайт работает

Уровень Senior, механизм объяснён в частях 01-1 §5 и ЛР 3, 11-4 §5.

**Риски:**

- **Что меняется:** манифест API-сервера переносится в `/root` внутри `lab-control-plane`.
- **Влияние:** `kubectl` перестаёт работать у всех, деплои и изменения кластера невозможны. Приложение `orders` продолжает отвечать.
- **Откат:** `mv` обратно из «Решения». Файл сам не вернётся.

**Поломка:**

```bash
docker exec lab-control-plane mv /etc/kubernetes/manifests/kube-apiserver.yaml /root/
sleep 25
kubectl get nodes
curl -s -o /dev/null -w '%{http_code}\n' http://orders.localhost:8088/api/orders
```

**Симптом:** `kubectl` отвечает `connection refused`, а запрос к приложению даёт `200`.

<details><summary>Решение</summary>

Вернуть манифест на место и дождаться, пока API-сервер ответит на проверку готовности:

```bash
docker exec lab-control-plane mv /root/kube-apiserver.yaml /etc/kubernetes/manifests/
until kubectl get --raw /readyz >/dev/null 2>&1; do sleep 2; done
kubectl get --raw '/readyz?verbose' | tail -1
```
</details>

<details><summary>Разбор</summary>

1. `connection refused` значит, что порт никто не слушает: процесса API-сервера нет. Таймаут говорил бы о сети.
2. Приложение работает, потому что Envoy, kube-proxy, поды и PostgreSQL от API-сервера не зависят. Data plane переживает отказ control plane.
3. Не работает всё, что меняет состояние: деплой, масштабирование, замена упавших подов, обновление эндпоинтов. Kubelet при этом перезапускает упавшие контейнеры без API.
4. Без `kubectl` причину ищут на узле: `docker exec lab-control-plane crictl ps -a --name kube-apiserver`, `crictl logs`, `/var/log/pods`, каталог манифестов.
5. Не оставляйте копию манифеста рядом, например `kube-apiserver.yaml.bak`: kubelet запускает каждый нескрытый файл каталога как static pod.
</details>

**Уборка:** `docker exec lab-control-plane ls /etc/kubernetes/manifests` показывает четыре файла; `kubectl get nodes` — все узлы `Ready`.

### T38. etcd упёрся в квоту

Уровень Senior, механизм объяснён в частях 10-2 §5 и ЛР 3, 11-4 ЛР 3.

Эту работу вы выполняете сами, результаты в ней — ожидаемые.

**Риски:**

- **Что меняется:** создаётся отдельный кластер kind `lab-12-2-t38` (один узел), в манифест etcd добавляется квота 32 МиБ.
- **Влияние:** около 1 ГиБ памяти и 1 ГБ диска рядом со стендом. Стенд, кластеры других частей и `~/.kube/config` не меняются. Во время тревоги кластер `lab-12-2-t38` не принимает записи.
- **Откат:** `kind delete cluster --name lab-12-2-t38` в «Уборке».

**Поломка:** Сценарий повторяет работу 3 из 10-2, но в своём кластере, поэтому кластер `lab-10-2` не нужен и не затрагивается. Функции называются `kx` и `ecx`, чтобы не заменить помощник `k` этой части.

```bash
KC=~/lab/k8s/12-2/t38.kubeconfig
kind create cluster --name lab-12-2-t38 --image kindest/node:v1.36.1 --kubeconfig "$KC" --wait 120s
kx() { kubectl --kubeconfig "$KC" "$@"; }
ecx() { kx -n kube-system exec etcd-lab-12-2-t38-control-plane -- etcdctl \
  --endpoints=https://127.0.0.1:2379 --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt --key=/etc/kubernetes/pki/etcd/server.key "$@"; }
docker exec lab-12-2-t38-control-plane sed -i \
  's|^    - etcd$|    - etcd\n    - --quota-backend-bytes=33554432|' \
  /etc/kubernetes/manifests/etcd.yaml
until [ "$(ecx endpoint status -w json 2>/dev/null | jq '.[0].Status.dbSizeQuota')" = 33554432 ]
do sleep 3; done
head -c 400000 /dev/zero | tr '\0' 'a' > ~/lab/k8s/12-2/payload.txt
kx create ns t38
kx -n t38 create configmap big --from-file=payload=$HOME/lab/k8s/12-2/payload.txt
for i in $(seq 1 200); do
  kx -n t38 patch configmap big --type merge -p "{\"data\":{\"n\":\"$i\"}}" >/dev/null || break
done
kx -n t38 create configmap small --from-literal=a=b
```


**Симптом:** Запись отклоняется с ошибкой `etcdserver: mvcc: database space exceeded`, а чтение при этом работает.

<details><summary>Решение</summary>

Порядок важен: сначала сжать историю, затем дефрагментировать базу и только потом снять тревогу.

```bash
ecx alarm list
REV=$(ecx endpoint status -w json | jq '.[0].Status.header.revision')
ecx compact "$REV" --physical
ecx defrag
ecx alarm disarm
kx -n t38 create configmap small --from-literal=a=b
```

Если снять тревогу раньше, база снова упрётся в квоту и тревога вернётся сразу.
</details>

<details><summary>Разбор</summary>

1. `ecx alarm list` печатает `alarm:NOSPACE`. Etcd перевёл кластер в режим «только чтение». Квота по умолчанию 2 ГиБ, здесь она уменьшена до 32 МиБ для опыта.
2. Каждое обновление объекта добавляет в базу полную копию, а старые ревизии живут до компакции. Значение одно, а история — десятки копий по 400 КБ.
3. Компакция освобождает страницы внутри файла, но размер файла не меняет. Файл уменьшает только дефрагментация. На рабочем кластере дефрагментацию делают по одному члену, потому что член на это время не обслуживает запросы.
4. Побочный эффект: scheduler и controller-manager могут перезапуститься, не продлив аренду лидера.
5. Если рост вызвала буря событий, найдите источник и остановите его: метрики `apiserver_resource_objects` и `apiserver_storage_size_bytes`.
</details>

**Уборка:**

```bash
kind delete cluster --name lab-12-2-t38 --kubeconfig "$KC"
rm -f ~/lab/k8s/12-2/payload.txt "$KC"
unset -f kx ecx; unset KC REV
kind get clusters
```

Последняя команда не должна показывать `lab-12-2-t38`, а кластеры других частей остаются на месте.

### T39. Аудит-лог не пишется

Уровень Senior, механизм объяснён в частях 06-4 §5 и ЛР 1.

Эту работу вы выполняете сами, результаты в ней — ожидаемые.

**Риски:**

- **Что меняется:** манифест API-сервера отдельного кластера `lab-06-4` из работы 1 в 06-4. Стенд не меняется.
- **Влияние:** API кластера `lab-06-4` недоступен 20–60 секунд, пока kubelet пересоздаёт static pod.
- **Откат:** копия манифеста в `/root` возвращается командой из «Решения».

**Поломка:** Путь файла аудита сменили на каталог, который не смонтирован с узла. Нужен кластер из работы 1 в 06-4; если вы его уже убрали, создайте его заново шагами 1–3 этой работы. Копию манифеста храним в `/root`, вне каталога манифестов, иначе kubelet запустит её как второй static pod.

```bash
N=lab-06-4-control-plane
KA=~/lab/k8s/06-4/kubeconfig
docker exec $N cp /etc/kubernetes/manifests/kube-apiserver.yaml /root/kube-apiserver.yaml.bak
docker exec $N sed -i \
  's|--audit-log-path=/var/log/kubernetes/|--audit-log-path=/var/log/lost/|' \
  /etc/kubernetes/manifests/kube-apiserver.yaml
sleep 40
until kubectl --kubeconfig $KA get --raw /readyz >/dev/null 2>&1; do sleep 2; done
docker exec $N wc -l /var/log/kubernetes/kube-apiserver-audit.log
kubectl --kubeconfig $KA create ns lab-12-2-t39
kubectl --kubeconfig $KA -n lab-12-2-t39 create cm probe --from-literal=a=b
docker exec $N wc -l /var/log/kubernetes/kube-apiserver-audit.log
```

**Симптом:** «Аудит включён, но новых событий нет»: число строк в логе на узле одинаково до и после изменений в кластере. Пауза `sleep 40` нужна потому, что kubelet замечает правку манифеста не сразу (до 20 секунд), и до этого отвечает ещё старый API-сервер.

<details><summary>Решение</summary>

Вернуть прежний манифест из копии и повторить действие, которое должно попасть в журнал:

```bash
docker exec $N cp /root/kube-apiserver.yaml.bak /etc/kubernetes/manifests/kube-apiserver.yaml
sleep 40
until kubectl --kubeconfig $KA get --raw /readyz >/dev/null 2>&1; do sleep 2; done
kubectl --kubeconfig $KA -n lab-12-2-t39 create cm probe2 --from-literal=a=b
docker exec $N wc -l /var/log/kubernetes/kube-apiserver-audit.log
```
</details>

<details><summary>Разбор</summary>

1. Сначала проверяют, что флаги попали в манифест: `docker exec $N grep audit /etc/kubernetes/manifests/kube-apiserver.yaml`.
2. Затем смотрят тома: путь лога должен лежать внутри `hostPath`-тома, смонтированного в под. Если каталог не смонтирован, процесс пишет внутрь контейнера: файл не виден на узле и пропадёт при перезапуске.
3. Если API-сервер вообще не стартует, причину ищут в `crictl logs` и `/var/log/pods` на узле: частые причины — опечатка в политике, отсутствующий файл политики, том без описания.
4. Событий может не быть и при верном пути: слишком раннее правило `None` скрывает нужные запросы, а `omitStages` отрезает стадию (06-4 §5).
</details>

**Уборка:**

```bash
docker exec $N rm -f /root/kube-apiserver.yaml.bak
kubectl --kubeconfig $KA delete ns lab-12-2-t39
unset N KA
```

Сам кластер `lab-06-4` убирается по уборке работы 1 из 06-4, если он больше не нужен.

## Senior: узлы, DNS и сертификаты

Здесь ломаются узлы, общие службы и доверие между компонентами (01-2, 03-3, 05-5, 10-1, 10-4).

### T40. Узел пропал, сайт лежит 6 минут

Уровень Senior, механизм объяснён в частях 01-2 ЛР 4, 11-4 §5, 05-3 §5.

**Риски:**

- **Что меняется:** на узле, где работает Envoy, останавливается kubelet.
- **Влияние:** сайт стенда недоступен до 6 минут. Если на этом узле стоит `postgres-0`, он тоже будет выселен, а его том привязан к узлу.
- **Откат:** `systemctl start kubelet` из «Решения». Если вернуть kubelet до выселения (до 300 секунд), поды не пострадают.

**Поломка:** Узел, на котором стоит единственная реплика Envoy, перестаёт отвечать.

```bash
kubectl -n envoy-gateway-system get pods -o wide
NODE=$(kubectl -n envoy-gateway-system get pods \
  -l gateway.envoyproxy.io/owning-gateway-name=lab -o jsonpath='{.items[0].spec.nodeName}')
echo "$NODE"
docker exec "$NODE" systemctl stop kubelet
SECONDS=0
until [ "$SECONDS" -gt 420 ]; do
  printf '%s с: ' "$SECONDS"
  curl -s -m 2 -o /dev/null -w '%{http_code}\n' http://orders.localhost:8088/api/orders
  sleep 20
done
```

**Симптом:** Первые 50 секунд ответы `200`, затем несколько минут код `000` (соединение отклонено). Всё это время `orders-api` работает на двух узлах, а после замены Envoy снова приходит `200`.

<details><summary>Решение</summary>

Если kubelet вернули раньше, чем началось выселение, достаточно запустить его обратно:

```bash
docker exec "$NODE" systemctl start kubelet
kubectl get node "$NODE"
```

Архитектурно нужны не менее двух реплик Gateway с `topologySpreadConstraints` по узлам и зонам и PodDisruptionBudget. Для критичных подов уменьшают `tolerationSeconds` у taints `unreachable` и `not-ready`, например с 300 до 60 секунд, и добавляют алерт «все реплики на одном узле».
</details>

<details><summary>Разбор</summary>

1. Узел `NotReady` примерно через 53 секунды: это `node-monitor-grace-period` (50 секунд) плюс интервалы опроса.
2. Taints `unreachable` ставятся сразу, а выселение подов — через 300 секунд (`tolerationSeconds` по умолчанию), то есть примерно на 353-й секунде. Новая реплика Envoy стартует ещё примерно через 20 секунд.
3. У Service Envoy нет ready-эндпоинтов: контейнер на мёртвом узле формально продолжает работать, но kubelet не сообщает о нём.
4. Три реплики у бизнес-сервисов не спасают, если единственный вход стоит на одном узле: платформенные компоненты (Gateway, DNS) первые кандидаты на размещение с отказоустойчивостью.
5. `kubectl delete pod --force` для пода на недоступном узле опасен: возможны два экземпляра с одним томом.
</details>

**Уборка:** `docker exec "$NODE" systemctl start kubelet` (если не выполнено), затем `kubectl get nodes` — все узлы `Ready`; `C` отвечает `200`; `kubectl get pods -A | grep Terminating` скоро показывает пусто.

### T41. CoreDNS без реплик

Уровень Senior, механизм объяснён в частях 03-3 §5 и ЛР 2, 11-3 §5.

**Риски:**

- **Что меняется:** Deployment `coredns` в `kube-system` масштабируется до нуля.
- **Влияние:** во всём кластере не разрешаются имена. Открытые соединения работают, новые резолвы ломаются: `orders` отвечает 504, его поды становятся `0/1`.
- **Откат:** `scale --replicas=2` из «Решения».

**Поломка:**

```bash
mk t41
k run dns --image=localhost:5001/orders-api:2.0 --command -- sleep 3600
k wait --for=condition=Ready pod/dns
kubectl -n kube-system scale deploy coredns --replicas=0
sleep 10
C
k exec dns -- getent hosts postgres.orders || echo fail
kubectl -n orders get pods -l app=orders-api
```

**Симптом:** Снаружи `504` через 15 секунд, поды `orders-api` в состоянии `0/1`.

<details><summary>Решение</summary>

```bash
kubectl -n kube-system scale deploy coredns --replicas=2
kubectl -n kube-system rollout status deploy coredns
sleep 6
C
```
</details>

<details><summary>Разбор</summary>

1. У Service `kube-dns` нет эндпоинтов. Из пода `getent hosts` падает мгновенно: kube-proxy отвечает отказом, а не тишиной.
2. Приложение отвечает иначе: у драйвера базы свой цикл повторов. Запрос прямо в под даёт 503 примерно через 10 секунд (`Temporary failure in name resolution`), снаружи — 504 через 15 секунд.
3. Readiness `/ready` проверяет базу, поэтому поды стали `0/1`. Envoy при этом продолжает слать им запросы (panic mode), и ответ приходит как таймаут.
4. Проверка: `kubectl -n kube-system get endpointslice -l kubernetes.io/service-name=kube-dns`.
5. Защита: не менее двух реплик CoreDNS с anti-affinity и PDB, NodeLocal DNSCache, алерт на `SERVFAIL`.
</details>

**Уборка:** `kubectl delete ns lab-12-2-t41`; `kubectl -n kube-system get deploy coredns` показывает `2/2`; `C` отвечает `200`.

### T42. Узел в DiskPressure

Уровень Senior, механизм объяснён в частях 05-5 §5 и ЛР 3, 11-4 ЛР 3.

Эту работу вы выполняете сами, результаты в ней — ожидаемые.

**Риски:**

- **Что меняется:** файл `/var/lib/kubelet/config.yaml` внутри выбранного узла (по умолчанию `lab-worker3`) и перезапуск kubelet; порог диска kind `0%` заменяется на `99%`.
- **Влияние:** узел получает условие `DiskPressure` и taint `disk-pressure`. Давление само не уйдёт, поэтому kubelet выселяет поды по одному примерно раз в 10 секунд, пока порог не вернут. Нетронутыми остаются только static pod и критичные системные поды (`kube-proxy`, `kindnet`). Поды с томами `local-path` этого узла останутся в `Pending` до отката.
- **Откат:** копия конфигурации возвращается командами из «Решения». Держите поломку не дольше минуты.
- **Выбор узла:** первая команда показывает поды узла. Если там `postgres-0` или Envoy, поставьте в `W` другой рабочий узел, иначе ляжет сайт стенда.

**Поломка:** Порог свободного места задан так, что kubelet считает диск переполненным. На рабочем кластере то же даёт реальный рост занятого места.

```bash
W=lab-worker3
kubectl get pods -A -o wide --field-selector spec.nodeName=$W
docker exec $W cp /var/lib/kubelet/config.yaml /root/lab-12-2-config.yaml.bak
docker exec $W sed -i 's/^  nodefs.available: 0%$/  nodefs.available: 99%/' \
  /var/lib/kubelet/config.yaml
docker exec $W systemctl restart kubelet
sleep 30
kubectl describe node $W | grep -E 'DiskPressure|Taints'
kubectl get pods -A -o wide --field-selector spec.nodeName=$W
```

**Симптом:** Условие `DiskPressure=True`, на узле нет новых подов, часть подов в статусе `Evicted`.

<details><summary>Решение</summary>

В этом сценарии достаточно вернуть конфигурацию, а на рабочем кластере сначала освобождают место на диске.

```bash
docker exec $W cp /root/lab-12-2-config.yaml.bak /var/lib/kubelet/config.yaml
docker exec $W rm /root/lab-12-2-config.yaml.bak
docker exec $W systemctl restart kubelet
sleep 20
kubectl describe node $W | grep -E 'DiskPressure|Taints'
kubectl get pods -A --field-selector status.phase=Failed
```

Последняя команда показывает записи о выселенных подах; удаляйте из них только те, что принадлежат вашим namespace.
</details>

<details><summary>Разбор</summary>

1. `kubectl describe node` показывает условие `DiskPressure True` и taint `node.kubernetes.io/disk-pressure:NoSchedule`; события `EvictionThresholdMet` фиксируют решение.
2. На рабочем узле причины ищут на узле: `df -h`, затем `du` по `/var/lib/containerd`, `/var/lib/kubelet`, `/var/log/pods`.
3. Типичные источники: образы (kubelet сначала очищает их по порогам `imageGCHighThresholdPercent` и `imageGCLowThresholdPercent`), логи контейнеров без ротации, `emptyDir` без `sizeLimit`.
4. Затем kubelet выселяет поды по превышению requests локального диска. Профилактика — requests и limits для `ephemeral-storage`.
5. Kind по умолчанию ставит пороги диска `0%` и отключает сборку образов, поэтому настоящий `DiskPressure` на стенде недостижим. Выселение по лимиту пода (`Evicted` при превышении `ephemeral-storage`) показывает 11-4 ЛР 3.
</details>

**Уборка:** Конфигурация возвращена командами из «Решения»; проверьте `kubectl get node $W` и `kubectl get --raw /api/v1/nodes/$W/proxy/configz | jq -c '.kubeletconfig.evictionHard'`: пороги диска снова `0%`.

### T43. Истёк токен присоединения узла

Уровень Senior, механизм объяснён в частях 10-1 §5, 10-4 §3.

Эту работу вы выполняете сами, результаты в ней — ожидаемые.

**Поломка:** Команду `kubeadm join` взяли из вчерашней заметки, а токен в ней уже истёк. На стенде нового узла нет, поэтому токен с коротким сроком и его исчезновение вы проверяете на control plane.

```bash
docker exec lab-control-plane kubeadm token create --ttl 20s --print-join-command
kubectl -n kube-public get cm cluster-info -o json | jq -r '.data | keys[]'
sleep 40
docker exec lab-control-plane kubeadm token list
kubectl -n kube-public get cm cluster-info -o json | jq -r '.data | keys[]'
```

**Симптом:** Новый узел при `kubeadm join` останавливается на фазе обнаружения и дальше не идёт. До истечения токена в `cluster-info` есть ключ `jws-kubeconfig-<id>` с ID нового токена, после — его нет.

<details><summary>Решение</summary>

Выпустить новый токен и получить готовую команду для присоединения узла:

```bash
docker exec lab-control-plane kubeadm token create --print-join-command
```

Для узла control plane ключ сертификатов живёт 2 часа, и его заново загружают командой `kubeadm init phase upload-certs --upload-certs`.
</details>

<details><summary>Разбор</summary>

1. Токен живёт 24 часа (`ttl`). Просроченный токен удаляет контроллер очистки, а подпись `jws-kubeconfig-<id>` в ConfigMap `cluster-info` исчезает.
2. `kubeadm join` на фазе обнаружения скачивает `cluster-info` без аутентификации и проверяет подпись токеном. Если подписи для ID токена нет, `kubeadm join` пишет `token id "<id>" is invalid for this cluster or it has expired`.
3. Другие причины сбоя join: хеш CA от другого кластера (`cluster CA found in cluster-info ConfigMap is invalid`), порт 6443 недоступен (`curl -k https://<адрес>:6443/healthz`), расхождение часов (`x509: certificate has expired or is not yet valid`).
4. Если `kubeadm join` зависает до пяти минут, смотрят `kubectl get csr`: Pending значит, что автоодобрение сломано (удалена привязка `kubeadm:node-autoapprove-bootstrap`).
5. Флаг `--discovery-token-unsafe-skip-ca-verification` отключает проверку хеша CA и допустим только там, где подмена API-сервера невозможна.
</details>

**Уборка:** токены с коротким сроком удаляются сами, и `docker exec lab-control-plane kubeadm token list` не показывает токен из поломки. Токен `abcdef`, который kind создаёт при подъёме стенда, живёт свои 24 часа и к сценарию не относится.

### T44. Серверные CSR kubelet в Pending

Уровень Senior, механизм объяснён в частях 10-1 §5, 10-4 §2.

Эту работу вы выполняете сами, результаты в ней — ожидаемые.

**Риски:**

- **Что меняется:** в конфигурацию kubelet узла `lab-worker2` добавляется `serverTLSBootstrap: true`, kubelet перезапускается.
- **Влияние:** пока CSR не одобрен, `kubectl logs`, `exec` и `kubectl top` для подов этого узла не работают. Поды и трафик работают.
- **Откат:** копия конфигурации возвращается командами «Уборки».

**Поломка:** Включена ротация серверных сертификатов kubelet, но одобрять запросы некому.

```bash
W=lab-worker2
docker exec $W cp /var/lib/kubelet/config.yaml /root/lab-12-2-config.yaml.bak
docker exec $W sh -c 'echo "serverTLSBootstrap: true" >> /var/lib/kubelet/config.yaml'
docker exec $W systemctl restart kubelet
sleep 30
kubectl get csr
POD=$(kubectl get pods -A --field-selector spec.nodeName=$W,status.phase=Running \
  -o jsonpath='{.items[0].metadata.namespace}/{.items[0].metadata.name}')
kubectl -n "${POD%/*}" logs "${POD#*/}" --tail=1
```

**Симптом:** В списке CSR появляются запросы с подписантом `kubernetes.io/kubelet-serving` в состоянии `Pending`. `kubectl logs` для пода на этом узле отвечает ошибкой TLS, ожидаемый хвост сообщения — `remote error: tls: internal error`.

<details><summary>Решение</summary>

Одобрить запросы вручную, а для постоянного решения поставить контроллер автоодобрения:

```bash
kubectl get csr -o json | jq -r '.items[]
  | select(.spec.signerName=="kubernetes.io/kubelet-serving"
      and .spec.username=="system:node:lab-worker2") | .metadata.name' \
  | xargs -r kubectl certificate approve
sleep 15
kubectl get csr
kubectl -n "${POD%/*}" logs "${POD#*/}" --tail=1
```

Одобряйте только запросы от узлов кластера и проверяйте, что имя в запросе совпадает с узлом.
</details>

<details><summary>Разбор</summary>

1. Серверный сертификат нужен kubelet, чтобы API-сервер и metrics-server могли проверить его при `logs`, `exec` и сборе метрик. По умолчанию он самоподписанный.
2. Запросы `kubelet-serving` controller-manager сам не одобряет: их одобряет человек или отдельный контроллер.
3. При включённой ротации Pending этих запросов — ожидаемое состояние, а не поломка, но без одобрения ротация не работает.
4. Клиентские запросы (`kube-apiserver-client-kubelet`) одобряются автоматически. Копящиеся Pending именно этого подписанта значат, что автоодобрение сломано.
5. Пока сертификата нет, kubelet вообще не может завершить TLS-рукопожатие: в его коде это ошибка `no serving certificate available for the kubelet`. Поэтому флаг `--kubelet-insecure-tls` у metrics-server не помогает, и метрики узла тоже пропадают.
</details>

**Уборка:**

```bash
docker exec $W cp /root/lab-12-2-config.yaml.bak /var/lib/kubelet/config.yaml
docker exec $W rm /root/lab-12-2-config.yaml.bak
docker exec $W sh -c 'rm -f /var/lib/kubelet/pki/kubelet-server-*.pem'
docker exec $W systemctl restart kubelet
sleep 20
kubectl get node $W
kubectl get csr -o json | jq -r '.items[]
  | select(.spec.username=="system:node:lab-worker2") | .metadata.name' \
  | xargs -r kubectl delete csr
unset W POD
```

Kubelet возвращается к самоподписанному `kubelet.crt`, который остался в `/var/lib/kubelet/pki`, и `kubectl logs` для подов узла снова работает. Третья команда удаляет выданные в сценарии серверные сертификаты; клиентские `kubelet-client-*` она не трогает.

## Senior: данные и GitOps

Последние сценарии проверяют, что процесс поставки и резервное копирование делают то, что от них ждут (04-3, 08-1, 08-2).

### T45. Velero восстановил объекты, а данных нет

Уровень Senior, механизм объяснён в частях 04-3 §5 и ЛР 3.

Эту работу вы выполняете сами, результаты в ней — ожидаемые.

**Поломка:** Сценарий опирается на Velero в namespace `lab-04-3` с бинарником `~/lab/k8s/04-3/bin/velero` из 04-3 ЛР 3. Уборка той работы удаляет Velero, поэтому при необходимости повторите её шаги 2–3. Бэкап снят для приложения с томом, но без аннотации тома.

```bash
mk t45
k apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: data}
spec:
  accessModes: [ReadWriteOnce]
  resources: {requests: {storage: 100Mi}}
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: writer}
spec:
  replicas: 1
  selector: {matchLabels: {app: writer}}
  template:
    metadata: {labels: {app: writer}}
    spec:
      containers:
      - name: app
        image: localhost:5001/busybox:1.37
        command: ["sleep", "infinity"]
        volumeMounts: [{name: data, mountPath: /data}]
      volumes: [{name: data, persistentVolumeClaim: {claimName: data}}]
EOF
k rollout status deploy/writer --timeout=120s
k exec deploy/writer -- sh -c 'echo "before backup" > /data/note.txt'
VEL=~/lab/k8s/04-3/bin/velero
$VEL backup create t45-1 --namespace lab-04-3 --include-namespaces "$NS" --wait
kubectl delete ns "$NS" --wait=true
$VEL restore create t45-1-r1 --namespace lab-04-3 --from-backup t45-1 --wait
kubectl -n "$NS" rollout status deploy/writer --timeout=180s
kubectl -n "$NS" exec deploy/writer -- cat /data/note.txt
```

**Симптом:** Восстановление закончилось статусом `Completed`, объекты вернулись, PVC на месте, но файла `note.txt` нет.

<details><summary>Решение</summary>

Включить копирование тома и снять бэкап заново: старый бэкап не вернёт данные, потому что их в нём никогда не было.

```bash
k patch deploy writer -p '{"spec":{"template":{"metadata":{"annotations":
  {"backup.velero.io/backup-volumes":"data"}}}}}'
k rollout status deploy/writer --timeout=120s
k exec deploy/writer -- sh -c 'echo "before backup" > /data/note.txt'
$VEL backup create t45-2 --namespace lab-04-3 --include-namespaces "$NS" --wait
```

Или включить режим «все тома» флагом `--default-volumes-to-fs-backup` при создании бэкапа.
</details>

<details><summary>Разбор</summary>

1. В режиме opt-in Velero копирует только тома, перечисленные в аннотации пода `backup.velero.io/backup-volumes`. Тома без аннотации в бэкап не попадают, и об этом нигде не сообщается.
2. Находят это в `$VEL backup describe t45-1 --namespace lab-04-3 --details`: раздел о томах (Pod Volume Backups) пуст или не содержит тома `data`.
3. Статус `Completed` описывает объекты API, а не содержимое томов. Единственная настоящая проверка бэкапа — восстановление в тестовый namespace.
4. Velero работает через API кластера и не бэкапит etcd. Снимок etcd (10-2) и Velero решают разные задачи.
</details>

**Уборка:**

```bash
$VEL restore delete t45-1-r1 --namespace lab-04-3 --confirm
$VEL backup delete t45-1 t45-2 --namespace lab-04-3 --confirm
kubectl delete ns lab-12-2-t45 --ignore-not-found
```

### T46. ApplicationSet удалил окружение

Уровень Senior, механизм объяснён в частях 08-2 §5 и ЛР 3.

**Риски:**

- **Что меняется:** каталог `overlays/staging` убирается из репозитория Gitea стенда GitOps (08-2), Application `orders-staging` исчезает вместе с объектами.
- **Влияние:** окружение `lab-08-2-staging` пропадает на секунды. Основной стенд и `orders` не затрагиваются.
- **Откат:** каталог возвращается в репозиторий, как в «Решении».

**Поломка:** Сценарий идёт на стенде 08-2 после работы 1: есть ApplicationSet `orders-api`, функция `gpush` и переменная `R` из 08-2. При чистке репозитория каталог окружения убирают, не заметив, что по нему генерируются Application.

```bash
mv $R/apps/orders-api/overlays/staging ~/lab/k8s/12-2/staging-saved
gpush "cleanup: remove unused overlay"
kubectl -n argocd annotate applicationset orders-api \
  argocd.argoproj.io/application-set-refresh=true --overwrite
sleep 10
kubectl -n argocd get app
kubectl -n lab-08-2-staging get deploy,svc --no-headers | wc -l
```

**Симптом:** «Окружение staging пропало, никто его не удалял»: Application `orders-staging` нет, а в namespace нет Deployment и Service.

<details><summary>Решение</summary>

Вернуть каталог в Git: ApplicationSet создаст Application заново, и окружение соберётся из репозитория.

```bash
mv ~/lab/k8s/12-2/staging-saved $R/apps/orders-api/overlays/staging
gpush "restore staging overlay"
kubectl -n argocd annotate applicationset orders-api \
  argocd.argoproj.io/application-set-refresh=true --overwrite
sleep 15
kubectl -n argocd get app orders-staging
```

Данные в томах, которых нет в манифестах, при пересоздании окружения теряются, поэтому защиту включают в самом ApplicationSet: `preserveResourcesOnDeletion: true` и `applicationsSync: create-update`.
</details>

<details><summary>Разбор</summary>

1. На Application висит finalizer `resources-finalizer.argocd.argoproj.io`: он делает удаление каскадным, поэтому исчезают и объекты окружения.
2. Никто не нажимал «удалить»: действие выполнил генератор, который перестал находить каталог. Application исчез через несколько секунд после опроса Git.
3. `preserveResourcesOnDeletion` позволяет Application исчезнуть, но оставляет ресурсы. `applicationsSync: create-update` не даёт ApplicationSet удалять Application вовсе: Application остаётся, а пропавший каталог виден как ошибка сравнения в его статусе, а не как авария.
4. Защита не заменяет ревью каталога `argocd/`: неверная маска или ветка всё равно оставят приложения без управления.
</details>

**Уборка:** Каталог возвращён; `kubectl -n argocd get app` показывает `orders-staging` в `Synced` и `Healthy`, а остальную уборку стенда GitOps выполняют по 08-2 ЛР 3.

### T47. Вечный OutOfSync

Уровень Senior, механизм объяснён в частях 08-1 §5 и ЛР 3.

**Риски:**

- **Что меняется:** в Git стенда 08-1 добавляется HPA с `minReplicas: 3`, Deployment `orders-api` в `lab-08-1-staging` скачет между 1 и 3 репликами.
- **Влияние:** цикл создаёт и удаляет поды каждые 15–40 секунд, около 2 минут. Основной стенд не затрагивается.
- **Откат:** `ignoreDifferences` из «Решения» и удаление HPA из Git в «Уборке».

**Поломка:** Сценарий повторяет шаг 2 работы 3 из 08-1. Он идёт на стенде 08-1 после работы 2: Argo CD установлен, Application `orders-staging` в `Synced`, определены `gpush` и `refresh`. Подготовка 08-2 удаляет этот Application и переводит overlay в `lab-08-2-staging`, поэтому после 08-2 сценарий в таком виде не воспроизводится. Конфликт простой: в Git `replicas: 1`, а HPA требует не меньше трёх реплик.

```bash
O=~/lab/k8s/08-1/orders-gitops/apps/orders-api/overlays/staging
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
sed -i 's|resources: \[../../base, route.yaml\]|resources: [../../base, route.yaml, hpa.yaml]|' \
  $O/kustomization.yaml
gpush "staging: add HPA min 3"; refresh; sleep 20
prev=""
for i in $(seq 1 45); do
  s="replicas=$(kubectl -n lab-08-1-staging get deploy orders-api \
    -o jsonpath='{.spec.replicas}') app=$(kubectl -n argocd get app orders-staging \
    -o jsonpath='{.status.sync.status}')"
  [ "$s" != "$prev" ] && echo "t=+$((i*2))с $s" && prev=$s
  sleep 2
done
```

**Симптом:** Application то `Synced`, то `OutOfSync`, число реплик прыгает между 1 и 3 без единого коммита.

<details><summary>Решение</summary>

Лучший вариант: убрать `replicas` из манифеста, чтобы у поля остался один владелец (HPA). Если манифест генерирует чужой чарт, настройте игнорирование поля и запретите его перезапись при sync:

```bash
kubectl -n argocd patch app orders-staging --type=merge -p '{"spec":{
  "ignoreDifferences":[{"group":"apps","kind":"Deployment","jsonPointers":["/spec/replicas"]}],
  "syncPolicy":{"automated":{"prune":true,"selfHeal":true},
  "syncOptions":["RespectIgnoreDifferences=true"]}}}'
sleep 10
kubectl -n lab-08-1-staging get deploy orders-api -o jsonpath='{.spec.replicas}{"\n"}'
```
</details>

<details><summary>Разбор</summary>

1. У поля `spec.replicas` два владельца: HPA поднимает значение до `minReplicas`, self-heal возвращает значение из Git. Оба реагируют на состояние кластера, а не на коммиты.
2. Причина видна в событиях: `kubectl -n lab-08-1-staging get events --sort-by=.lastTimestamp | grep -E 'Scaling|Rescale'`. Строки `SuccessfulRescale … below Spec.MinReplicas` (HPA) чередуются с `Scaled down … from 3 to 1` (возврат Argo CD).
3. Различие в diff Argo CD — поле `spec.replicas`.
4. Без `RespectIgnoreDifferences=true` игнорируемое поле перезаписывается при любом sync, например ручном.
5. Это та же война за `replicas`, что у `kubectl apply` с HPA (05-4), но автоматическая и вечная.
</details>

**Уборка:**

```bash
sed -i 's|, hpa.yaml||' $O/kustomization.yaml
rm -f $O/hpa.yaml
gpush "staging: drop HPA"; refresh
kubectl -n argocd patch app orders-staging --type=merge -p '{"spec":{"ignoreDifferences":null}}'
unset O prev
```

Остальную уборку стенда GitOps выполняют по 08-1 ЛР 4 и 08-2 ЛР 3.

---

## Общая уборка

Каждый сценарий убирает за собой сам, но после серии сценариев стоит убедиться, что на стенде не осталось ничего от этой части. Первая команда удаляет все namespace сценариев по метке, остальные проверяют узлы, политики, Service и приложение.

```bash
kubectl delete ns -l lab-12-2=trainer
kubectl get nodes
kubectl describe node | grep Taints
kubectl -n orders get networkpolicy
kubectl -n orders get svc orders-api -o jsonpath='{.spec.selector} {.spec.ports}{"\n"}'
kubectl -n kube-system get deploy coredns metrics-server
docker exec lab-control-plane ls /etc/kubernetes/manifests
C
```

В выводе этих команд должно быть следующее:

1. Все четыре узла `Ready`, без `SchedulingDisabled`.
2. В taints нет ключей `lab-12-2/…`: остался только taint control plane.
3. В `orders` нет NetworkPolicy (`No resources found`).
4. Селектор Service `orders-api` равен `app=orders-api`, `targetPort` равен `http`.
5. Deployment `coredns` показывает `2/2`, `metrics-server` — `1/1`.
6. В каталоге манифестов четыре файла: `etcd`, `kube-apiserver`, `kube-controller-manager`, `kube-scheduler`.
7. Команда `C` отвечает `200`.

Затем уберите объекты кластерного уровня, если сценарий прервался, и файлы части:

```bash
kubectl get validatingwebhookconfiguration,validatingadmissionpolicy,flowschema,\
prioritylevelconfiguration | grep lab-12-2
rm -rf ~/lab/k8s/12-2 /tmp/lab-12-2.body
unset -f mk k C
unset NS
```

Первая команда ничего не должна напечатать, а помощники `kx`, `ecx` и `api` снимаются в «Уборке» своих сценариев.

---

## Как проходить на собеседовании

Интервьюер оценивает ход мысли не меньше, чем результат, и четыре правила ниже работают на любом сценарии из этой части.

1. Гипотезы вслух. «Pending значит, что дело в планировании; смотрю события пода». Тишина выглядит как растерянность.
2. От общего к частному. Сначала `get` по всему namespace, затем `describe` проблемного объекта, события, логи. Слой определяют по статусу, коду ответа и времени отказа (11-2, 11-3).
3. Сначала причина, потом правка. Назовите причину и то, как её подтвердили. После этого исправляйте и проверяйте, что симптом ушёл.
4. Профилактика. Скажите, как не допустить повтора: проверка в CI, алерт, политика, число реплик, бюджет прерываний. Это отличает Senior.

---

## → Дальше

Тренажёры проверили, что вы умеете находить и чинить поломки в готовой системе. Следующая часть, 12-3, переворачивает задачу: теперь нужно спроектировать платформу так, чтобы эти поломки не случались или не расходились на всех. Задачи по проектированию собирают механизмы из частей 03–10 в архитектуру. Это мультитенантность на 30 команд, поставка без простоя с откатом через GitOps и кластер в двух зонах с восстановлением после аварии.
