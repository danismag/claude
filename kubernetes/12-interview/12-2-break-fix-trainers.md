# 12-2. Тренажёры «сломай и почини»

> Модуль 12 «Подготовка к собеседованию» · часть 2 из 4 · 🟢🟡🔴 · ~3 ч (по 5–15 мин на сценарий) · Нужно: стенд 00-1 с orders.
>
> **Как пользоваться.** Работайте парой: один ломает (блок «Поломка»), второй чинит, видя только «Симптом». Спойлеры открывайте после того, как назвали причину вслух. Засекайте время: ориентир — 🟢 до 5 мин, 🟡 до 10, 🔴 до 15. Live-собеседования устроены именно так.
>
> Все сценарии, кроме помеченных ⚠️, проверены на стенде курса. В части по ссылке — полный вывод.

---

## Подготовка

```bash
kubectl config use-context kind-lab
kubectl create ns lab-12-2
kubectl config set-context --current --namespace=lab-12-2
C(){ curl -s -m 20 -o /tmp/b -w '%{http_code} %{time_total}s ' http://orders.localhost:8088/api/orders; head -c 100 /tmp/b; echo; }
C      # 200 — исходное состояние
```

Правило для ломающего: каждая поломка откатывается командой из спойлера «Решение» до перехода к следующей. Сценарии на `orders` после отката должны снова давать `C` → 200.

---

## 🟢 Junior

### T01. Образ не скачивается

**Поломка:** `kubectl create deploy t01 --image=localhost:5001/orders-api:9.9`

**Симптом:** «деплой не поднимается».

<details><summary>Диагностика</summary>

`kubectl get pods` → `ImagePullBackOff`. `kubectl get pod -l app=t01 -o jsonpath='{.items[0].status.containerStatuses[0].state.waiting.message}'` → `…localhost:5001/orders-api:9.9: not found`. Тега нет в реестре (11-1).
</details>

<details><summary>Решение</summary>

`kubectl set image deploy/t01 orders-api=localhost:5001/orders-api:2.0`; затем `kubectl delete deploy t01`. На проде — проверить, почему CI не опубликовал тег.
</details>

### T02. Падает при старте

**Поломка:** `kubectl run t02 --image=python:3.12-slim --restart=Always -- python -c "import sys; print('db config missing', file=sys.stderr); sys.exit(1)"`

**Симптом:** «под постоянно перезапускается».

<details><summary>Диагностика</summary>

`Error`/`CrashLoopBackOff`, `lastState: Error/1`. `kubectl logs t02` → `db config missing`. В период back-off `--previous` может отвечать `unable to retrieve container logs` — пробуйте без него (11-1).
</details>

<details><summary>Решение</summary>

Передать конфигурацию (env/Secret), которую ждёт приложение. `kubectl delete pod t02`.
</details>

### T03. Нет ConfigMap

**Поломка:** под с `envFrom: [{configMapRef: {name: app-config}}]` (манифест t04 из 11-1).

**Симптом:** под не стартует, рестартов нет.

<details><summary>Диагностика</summary>

`CreateContainerConfigError`, message `configmap "app-config" not found` (11-1).
</details>

<details><summary>Решение</summary>

`kubectl create configmap app-config --from-literal=MODE=prod`. Под оживёт сам после очередной попытки kubelet (back-off). Через 6 с он ещё был в ошибке — подождите или пересоздайте под.
</details>

### T04. Selector Service

**Поломка:** `kubectl -n orders patch svc orders-api -p '{"spec":{"selector":{"app":"orders-apl"}}}'`

**Симптом:** `C` → `503` мгновенно, поды Running 1/1.

<details><summary>Диагностика</summary>

`kubectl -n orders get endpointslice -l kubernetes.io/service-name=orders-api -o jsonpath='{.items[*].endpoints}'` → `null`. Сравнить `svc.spec.selector` с `get pods --show-labels`. В логе Envoy — `direct_response` (11-2).
</details>

<details><summary>Решение</summary>

`kubectl -n orders patch svc orders-api -p '{"spec":{"selector":{"app":"orders-api"}}}'`
</details>

### T05. Чужой Host

**Поломка:** клиенту дали адрес `http://orders.local:8088`.

**Симптом:** `404` мгновенно, пустое тело.

<details><summary>Диагностика</summary>

Маршрут не совпал: `hostnames` HTTPRoute — `orders.localhost`. В логе Envoy `NR route_not_found` (11-2).
</details>

<details><summary>Решение</summary>

Исправить адрес у клиента или добавить имя в `hostnames`.
</details>

---

## 🟡 Middle

### T06. Не хватает CPU

**Поломка:** `kubectl create deploy t06 --image=busybox:1.37 -- sleep 3600 && kubectl set resources deploy t06 --requests=cpu=64`

**Симптом:** `Pending`.

<details><summary>Диагностика</summary>

`FailedScheduling`: `0/4 nodes are available: 1 node(s) had untolerated taint(s), 3 Insufficient cpu.` (11-1).
</details>

<details><summary>Решение</summary>

Реалистичный request (`--requests=cpu=100m`). Проверить `kubectl describe node | grep -A6 Allocated`. `kubectl delete deploy t06`.
</details>

### T07. Taint на всех рабочих узлах

**Поломка:** `kubectl taint node lab-worker lab-worker2 lab-worker3 dedicated=db:NoSchedule` и `kubectl run t07 --image=busybox:1.37 --restart=Never -- sleep 3600`.

**Симптом:** новый под Pending; старые работают.

<details><summary>Диагностика</summary>

Проверено: `0/4 nodes are available: 4 node(s) had untolerated taint(s). … Preemption is not helpful for scheduling.` `kubectl describe node | grep Taints` (05-2).
</details>

<details><summary>Решение</summary>

`kubectl taint node lab-worker lab-worker2 lab-worker3 dedicated=db:NoSchedule-` — под стал Running через 6 с. Или tolerations для подов, которым положено на эти узлы. `kubectl delete pod t07`.
</details>

### T08. Локальный том на другом узле

**Поломка:**

```bash
kubectl apply -f - <<'EOF'
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
  containers: [{name: c, image: busybox:1.37, command: [sleep, "3600"], volumeMounts: [{name: d, mountPath: /d}]}]
  volumes: [{name: d, persistentVolumeClaim: {claimName: data}}]
EOF
kubectl wait --for=condition=Ready pod/w1; kubectl delete pod w1
# тот же PVC, но под на lab-worker3
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata: {name: w2}
spec:
  nodeSelector: {kubernetes.io/hostname: lab-worker3}
  containers: [{name: c, image: busybox:1.37, command: [sleep, "3600"], volumeMounts: [{name: d, mountPath: /d}]}]
  volumes: [{name: d, persistentVolumeClaim: {claimName: data}}]
EOF
```

**Симптом:** «после переезда на другой узел под с данными не стартует».

<details><summary>Диагностика</summary>

Проверено: `0/4 nodes are available: 1 node(s) didn't match PersistentVolume's node affinity, 1 node(s) had untolerated taint(s), 2 node(s) didn't match Pod's node affinity/selector.` PV local-path привязан к `lab-worker` (`kubectl get pv -o jsonpath='{..nodeAffinity}'`). Читайте сообщение целиком: каждая группа узлов отсеяна по своей причине (04-2, кейс 11-1).
</details>

<details><summary>Решение</summary>

Убрать конфликтующий `nodeSelector` (под поедет к тому), либо перенести данные. Для облачных дисков — то же с зонами. `kubectl delete pod w2; kubectl delete pvc data`.
</details>

### T09. OOM

**Поломка:** манифест t05 из 11-1 (python выделяет 300 MiB при `limits.memory: 128Mi`); флага `--limits` у `kubectl run` в актуальных версиях нет.

**Симптом:** рестарты, в логах пусто.

<details><summary>Диагностика</summary>

`lastState: OOMKilled/137`, событий про OOM нет (05-1, 11-1).
</details>

<details><summary>Решение</summary>

Лимит выше рабочего набора или исправить потребление. `kubectl delete pod t09`.
</details>

### T10. Квота без LimitRange

**Поломка:** `kubectl create quota q --hard=requests.cpu=500m,limits.memory=1Gi` и `kubectl create deploy t10 --image=busybox:1.37 --replicas=2 -- sleep 3600`.

**Симптом:** Deployment `0/2`, подов нет вообще.

<details><summary>Диагностика</summary>

У Deployment ошибки не видно — смотрите события ReplicaSet: `kubectl get events --field-selector reason=FailedCreate`. Проверено: `pods "t10-…" is forbidden: failed quota: q: must specify limits.memory for: busybox; requests.cpu for: busybox` (05-1).
</details>

<details><summary>Решение</summary>

Задать requests/limits в шаблоне или создать LimitRange с дефолтами. `kubectl delete deploy t10; kubectl delete quota q`.
</details>

### T11. targetPort

**Поломка:** `kubectl -n orders patch svc orders-api --type=json -p '[{"op":"replace","path":"/spec/ports/0/targetPort","value":8080}]'`

**Симптом:** `503 … reset reason: remote connection failure` мгновенно.

<details><summary>Диагностика</summary>

EndpointSlice с портом 8080, а контейнер слушает 8000. `curl podIP:8080` — refused, `:8000` — 200 (11-2).
</details>

<details><summary>Решение</summary>

`kubectl -n orders patch svc orders-api --type=json -p '[{"op":"replace","path":"/spec/ports/0/targetPort","value":"http"}]'` — именованный порт.
</details>

### T12. Readiness не на тот путь

**Поломка:** под orders-api с `readinessProbe.httpGet.path: /healthz` (t09 из 11-1).

**Симптом:** Running `0/1`, рестартов нет.

<details><summary>Диагностика</summary>

Событие `Readiness probe failed: HTTP probe failed with statuscode: 404` (02-5, 11-1).
</details>

<details><summary>Решение</summary>

Путь `/ready`. Сверять пробы с тем, что реально отдаёт приложение (тест в CI).
</details>

### T13. 502 при каждом деплое

**Поломка:** orders-api без `preStop` и с мгновенным выходом по SIGTERM (`SHUTDOWN_DELAY=0`), нагрузка в 4 потока, `kubectl -n orders rollout restart deploy orders-api`.

**Симптом:** «каждый релиз — всплеск ошибок 503 у клиентов».

<details><summary>Диагностика</summary>

Гонка: эндпоинт удаляется из Service одновременно с SIGTERM. Envoy и kube-proxy ещё шлют запросы в закрытый порт (02-5 — замер ошибок без graceful и с ним).
</details>

<details><summary>Решение</summary>

`preStop: sleep 5` или задержка в приложении (`SHUTDOWN_DELAY=5`), корректная обработка SIGTERM, `terminationGracePeriodSeconds` больше суммы. Вернуть `SHUTDOWN_DELAY=5`.
</details>

### T14. Egress default-deny без DNS

**Поломка:** NetworkPolicy `t-egress-db-only` из 11-2 n6.

**Симптом:** `504 upstream request timeout` через 15 с, поды `0/1`.

<details><summary>Диагностика</summary>

Изнутри пода: `getaddrinfo('postgres')` → `Temporary failure in name resolution` через 20 с, TCP по IP к БД — 3 мс. В Envoy — `UT response_timeout` (11-2).
</details>

<details><summary>Решение</summary>

Правило egress к kube-dns (53 UDP+TCP). `kubectl -n orders delete networkpolicy t-egress-db-only`.
</details>

### T15. Helm-релиз завис

**Поломка:** `timeout -s KILL 5 helm upgrade orders ./charts/orders-api --wait …` (07-1 §5).

**Симптом:** следующий деплой: `Error: UPGRADE FAILED: another operation (install/upgrade/rollback) is in progress`.

<details><summary>Диагностика</summary>

`helm history orders` → последняя ревизия `pending-upgrade` (07-1, проверено там).
</details>

<details><summary>Решение</summary>

`helm rollback orders <последняя deployed>`, затем повторный upgrade. В CI — таймаут helm меньше таймаута job'а и запрет параллельных деплоев одного релиза.
</details>

### T16. Drain не проходит

**Поломка:** `kubectl create deploy t16 --image=busybox:1.37 -- sleep 3600 && kubectl create pdb t16 --selector=app=t16 --min-available=1`, затем `kubectl drain <узел пода> --ignore-daemonsets --delete-emptydir-data`.

**Симптом:** drain «висит».

<details><summary>Диагностика</summary>

Проверено: `ALLOWED DISRUPTIONS 0`, повторяющееся `Cannot evict pod as it would violate the pod's disruption budget.`, затем `global timeout reached` (при `--timeout=20s`) (10-3).
</details>

<details><summary>Решение</summary>

≥ 2 реплики (тогда PDB разрешит 1) или `maxUnavailable: 1`. Не удалять PDB молча — договориться с владельцем сервиса. `kubectl uncordon <узел>`; `kubectl delete deploy,pdb t16`.
</details>

---

## 🔴 Senior

### T17. Вебхук положил деплои

**Поломка:** ValidatingWebhookConfiguration с `failurePolicy: Fail`, ссылающаяся на несуществующий Service, на поды namespace `lab-12-2` (манифест 09-2 §1).

**Симптом:** «Deployment 0/1, ошибок в поде нет, потому что пода нет».

<details><summary>Диагностика</summary>

События ReplicaSet: `Error creating: … failed calling webhook … service "…" not found` — отказ за 226 мс. При молчащем сервере — `context deadline exceeded` за ~5 с (09-2). `kubectl get validatingwebhookconfiguration`.
</details>

<details><summary>Решение</summary>

Поднять сервис вебхука или временно `failurePolicy: Ignore`. Исключить системные ns `namespaceSelector`, реплики и PDB для вебхука. Удалить тестовую конфигурацию.
</details>

### T18. Namespace не удаляется

**Поломка:** ConfigMap с `metadata.finalizers: [example.com/cleanup]` в ns, затем `kubectl delete ns …` (09-2 §2).

**Симптом:** namespace `Terminating` бесконечно.

<details><summary>Диагностика</summary>

`kubectl get ns <ns> -o jsonpath='{.status.conditions}'` — `NamespaceContentRemaining`/`NamespaceFinalizersRemaining` называют тип объекта и finalizer (09-2).
</details>

<details><summary>Решение</summary>

Вернуть контроллер, который снимает finalizer, или осознанно снять его: `kubectl patch cm <name> -n <ns> --type=merge -p '{"metadata":{"finalizers":null}}'`. Помнить: finalizer охраняет внешний ресурс — проверить, что он удалён.
</details>

### T19. Узел пропал, сайт лежит 6 минут

**Поломка:** определить узел единственной реплики Envoy (`kubectl -n envoy-gateway-system get pods -o wide`) и `docker exec <узел> systemctl stop kubelet`.

**Симптом:** `C` → `000` (соединение отклонено) несколько минут, orders-api на двух узлах.

<details><summary>Диагностика</summary>

Узел NotReady через 47 с, у Service Envoy нет ready-эндпоинтов, эвикция через 300 с, восстановление ещё через ~20 с (11-3).
</details>

<details><summary>Решение</summary>

`docker exec <узел> systemctl start kubelet`. Архитектурно — ≥ 2 реплики Gateway с spread по узлам/зонам, PDB, уменьшенный `tolerationSeconds` для критичных подов.
</details>

### T20. Pending без событий

**Поломка:** `docker exec lab-control-plane mv /etc/kubernetes/manifests/kube-scheduler.yaml /root/kube-scheduler.yaml`, создать под.

**Симптом:** новый под Pending, у него нет ни одного события.

<details><summary>Диагностика</summary>

Нет событий — значит, никто не пытался планировать. Lease `kube-system/kube-scheduler`: `renewTime` отстаёт. На control-plane `crictl ps --name kube-scheduler` пусто (11-3).
</details>

<details><summary>Решение</summary>

`docker exec lab-control-plane mv /root/kube-scheduler.yaml /etc/kubernetes/manifests/kube-scheduler.yaml`. Под получил `Scheduled` через 3 с после возврата.
</details>

### T21. Вечный OutOfSync ⚠️

**Поломка:** Argo CD Application для orders-api с `replicas: 2` в Git и HPA на тот же Deployment (08-1 §3). ⚠️ Argo CD на стенде после 08-2 удалён — для повторения установите его по 08-1.

**Симптом:** приложение то Synced, то OutOfSync; число подов «прыгает».

<details><summary>Диагностика</summary>

Diff в Argo CD — поле `spec.replicas`: HPA меняет, self-heal возвращает значение из Git (08-1).
</details>

<details><summary>Решение</summary>

Убрать `replicas` из манифеста (владелец — HPA) или `ignoreDifferences` на `/spec/replicas` с `RespectIgnoreDifferences=true`.
</details>

---

## Уборка

```bash
kubectl config set-context --current --namespace=default
kubectl delete ns lab-12-2
kubectl get nodes                                              # все Ready, без taints dedicated
kubectl -n orders get networkpolicy                            # No resources found
kubectl -n orders get svc orders-api -o jsonpath='{.spec.selector} {.spec.ports}{"\n"}'   # app=orders-api, targetPort http
C                                                              # 200
```

---

## Как проходить на собеседовании

1. **Проговаривайте гипотезы вслух**: «Pending — значит, планирование; смотрю события пода». Интервьюер оценивает ход мысли.
2. **От общего к частному**: `get` всего namespace → `describe` проблемного → события → логи.
3. **Не чините сразу**: сначала назовите причину и как проверили, потом исправление и как предотвратить.
4. **Упомяните профилактику**: проверку в CI, алерт, политику — это уровень Senior.

→ Следующая часть: **12-3. System design** — платформа для 30 команд, zero-downtime поставка orders-api с БД и откатом через GitOps, кластер в двух зонах с DR.
