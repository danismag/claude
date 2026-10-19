# 00-2. Инструменты

> Модуль 0 «Стенд и инструменты» · часть 2 из 2 · 🟢🟡 · ~1 ч чтения + ~30 мин практики · Нужно: стенд 00-1

---

## Зачем это DevOps-у

В работе с Kubernetes 90% времени — это `kubectl get/describe/logs/exec` по чужим объектам. Скорость разбора инцидента определяется тем, насколько быстро вы достаёте нужное поле из сотни подов, видите разницу между тем, что в Git, и тем, что в кластере, и заходите в под без shell. На собеседовании на live-кодинге по Kubernetes дают кластер и просят «найди, почему не работает» — здесь собраны приёмы, которыми пользуется весь курс.

---

## 1. kubectl: контексты и namespace 🟢

```bash
kubectl config get-contexts                     # все кластеры из kubeconfig; * — текущий
kubectl config current-context                  # kind-lab
kubectl config use-context kind-lab
kubectl config set-context --current --namespace=orders   # namespace по умолчанию для текущего контекста
kubectl auth whoami                             # кто я для этого кластера
```

Проверено (`auth whoami` на стенде):

```
ATTRIBUTE                                           VALUE
Username                                            kubernetes-admin
Groups                                              [kubeadm:cluster-admins system:authenticated]
Extra: authentication.kubernetes.io/credential-id   [X509SHA256=d6cd0ad7…]
```

На стенде вы — `cluster-admin` по клиентскому сертификату. В проде так быть не должно (права — по документации Kubernetes «Using RBAC Authorization»; часть 06-1 не опубликована, 00-plan §0).

Несколько кластеров — несколько файлов: `KUBECONFIG=~/.kube/prod:~/.kube/stage` склеивает их. Правило, которое спасает от `delete` не в том кластере: **контекст — в приглашении shell** (kube-ps1, starship) и отдельный kubeconfig для прода, который подключается явно.

`kubectx`/`kubens` — переключение контекста/namespace одной командой с автодополнением (🅼 `sudo pacman -S kubectx` — 0.11.0 в extra; 🐧 — бинарник с GitHub или `kubectl krew install ctx ns`). ⚠️ в среде агента не устанавливались.

## 2. Достать нужное: `-o` 🟢🟡

| Формат | Когда |
|---|---|
| `-o wide` | узел, IP пода, образ — первым делом |
| `-o yaml` | весь объект, включая `status` и `managedFields` |
| `-o name` | для конвейеров: `kubectl get pods -o name \| xargs …` |
| `-o jsonpath='…'` | одно-два поля, циклы `range` |
| `-o custom-columns=…` | своя таблица |
| `-o go-template` | условия и форматирование сложнее jsonpath |

Проверено на стенде:

```bash
kubectl -n orders get pods -o custom-columns=NAME:.metadata.name,NODE:.spec.nodeName,IP:.status.podIP,QOS:.status.qosClass,RESTARTS:.status.containerStatuses[0].restartCount
```

```
NAME                          NODE          IP           QOS         RESTARTS
orders-api-6d54d4c46b-fvq75   lab-worker3   10.244.1.2   Burstable   1
orders-api-6d54d4c46b-ksf5v   lab-worker2   10.244.3.3   Burstable   1
postgres-0                    lab-worker    10.244.2.3   Burstable   1
```

```bash
kubectl -n orders get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[0].image}{"\n"}{end}'
```

```
orders-api-6d54d4c46b-fvq75	localhost:5001/orders-api:2.0
orders-api-6d54d4c46b-ksf5v	localhost:5001/orders-api:2.0
postgres-0	postgres:17.6-alpine
```

Полезные фильтры:

```bash
kubectl get pods -A --field-selector=status.phase!=Running      # всё, что не Running (No resources found — хорошо)
kubectl get pods -A --field-selector=spec.nodeName=lab-worker   # что живёт на узле
kubectl get pods -l app=orders-api,tier!=db                     # по меткам
kubectl get events -A --sort-by=.lastTimestamp | tail           # последние события кластера
kubectl events -n orders --for pod/postgres-0                   # события одного объекта (kubectl 1.26+)
```

jsonpath-фильтр по условию: `'{.items[?(@.status.phase=="Pending")].metadata.name}'`. Для сложного — `-o json | jq`.

## 3. Понять объект: `explain`, `api-resources` 🟢

```bash
kubectl explain deployment.spec.strategy.rollingUpdate.maxSurge
```

Проверено (начало):

```
GROUP:      apps
KIND:       Deployment
VERSION:    v1

FIELD: maxSurge <IntOrString>

DESCRIPTION:
    The maximum number of pods that can be scheduled above the desired number of
    pods. Value can be an absolute number (ex: 5) or a percentage of desired
    pods (ex: 10%). This can not be 0 if MaxUnavailable is 0. Absolute number is
    calculated from percentage by rounding up. Defaults to 25%. ...
```

`explain` берёт схему из **вашего** кластера (OpenAPI), включая CRD — надёжнее, чем документация другой версии. `kubectl explain pod.spec --recursive | less` — все поля дерева.

```bash
kubectl api-resources                                     # все типы, короткие имена, namespaced или нет
kubectl api-resources --api-group=gateway.networking.k8s.io -o wide
kubectl api-versions | grep gateway
```

Проверено: на стенде `gateways` (короткое `gtw`), `httproutes`, `grpcroutes`, `backendtlspolicies` — все в `gateway.networking.k8s.io/v1`.

## 4. Изменять безопасно: `diff`, `--dry-run=server` 🟡

```bash
kubectl diff -f orders-api.yaml          # что изменится; exit 1 — есть разница, 0 — нет
kubectl apply -f orders-api.yaml --dry-run=server
```

Проверено (`replicas: 2 → 3` в файле):

```
-  generation: 1
+  generation: 2
...
-  replicas: 2
+  replicas: 3
diff exit=1
configmap/orders-config unchanged (server dry run)
deployment.apps/orders-api configured (server dry run)
service/orders-api unchanged (server dry run)
```

`--dry-run=client` только печатает объект; `--dry-run=server` проходит admission и валидацию в apiserver, но не пишет в etcd. Разница (проверено):

```
$ kubectl create deploy bad --image=x --replicas=-1 --dry-run=client -o name
deployment.apps/bad
$ kubectl create deploy bad --image=x --replicas=-1 --dry-run=server
error: failed to create deployment: Deployment.apps "bad" is invalid: spec.replicas: Invalid value: -1: must be greater than or equal to 0
```

В CI для манифестов используют именно `--dry-run=server` (или `kubeconform` без кластера) — client-режим ошибку пропустил.

## 5. Что kubectl делает на самом деле: `-v` 🟡

```bash
kubectl -n orders get deploy orders-api -v=8 2>&1 | grep -E '"Request"|"Response"|milliseconds'
```

Проверено (сокращено):

```
round_trippers.go] "Request" verb="GET" url="https://…:6443/apis/apps/v1/namespaces/orders/deployments/orders-api" headers=<
	Accept: application/json;as=Table;v=v1;g=meta.k8s.io,application/json;as=Table;v=v1beta1;g=meta.k8s.io,application/json
round_trippers.go] "Response" status="200 OK" headers=< … > milliseconds=9
```

Видно: путь API (`/apis/<группа>/<версия>/namespaces/<ns>/<ресурс>/<имя>`), что колонки таблицы считает сервер (`as=Table`), время ответа. `-v=6` — только URL и коды, `-v=9` — тела без обрезки. Так отлаживают «почему kubectl висит» (медленный apiserver, auth-плагин), 403 от RBAC и пишут curl-запросы к API (01-1).

## 6. Внутрь пода: `logs`, `exec`, `debug`, `port-forward` 🟢🟡

```bash
kubectl logs deploy/orders-api                    # один под из Deployment (печатает, какой)
kubectl logs -l app=orders-api --prefix --tail=20  # все поды по метке
kubectl logs pod/x -c api --previous               # предыдущий экземпляр контейнера (после рестарта)
kubectl logs pod/x --since=10m -f                  # хвост в реальном времени
kubectl exec -it pod/x -- sh
```

`stern` — хвост логов многих подов с цветом и регулярками: `stern -n orders orders-api` (🅼 `sudo pacman -S stern` — 1.34.0 в extra; 🐧 — бинарник с GitHub или `krew install stern`). ⚠️ в среде агента не устанавливался.

### Под без shell — `kubectl debug` 🟡

Образ orders-api — `python:3.12-slim`: нет `ps`, `curl`, `ss` (проверено: `which ps curl ss` → exit 1). Distroless-образы не содержат даже `sh`. Решение — **ephemeral container**: временный контейнер с инструментами в работающем поде, с общим сетевым и (с `--target`) PID-namespace:

```bash
P=$(kubectl -n orders get pod -l app=orders-api -o jsonpath='{.items[0].metadata.name}')
kubectl -n orders debug -it $P --image=busybox:1.37 --target=api --profile=general -c dbg -- sh
# внутри:
ps                                         # видны процессы контейнера api
wget -qO- http://127.0.0.1:8000/version    # сеть пода общая
ls /proc/1/root/srv/app                    # файловая система целевого контейнера через /proc
```

Проверено (вывод команд внутри):

```
PID   USER     TIME  COMMAND
    1 10001     0:00 python -m app.main
  148 root      0:00 sleep 600
…
{"version": "2.0", "pod": "orders-api-6d54d4c46b-fvq75"}
__init__.py
main.py
```

Ephemeral container нельзя удалить из пода — он остаётся в `spec.ephemeralContainers` до пересоздания пода. Для Deployment это не проблема (поды заменяемы), для «единственного» пода — помните.

Другие режимы:

```bash
kubectl debug $P --copy-to=orders-dbg --container=api -- sh    # копия пода с другой командой (под в CrashLoop)
kubectl debug node/lab-worker -it --image=busybox:1.37 --profile=sysadmin   # под на узле: hostPID, hostNetwork, / узла в /host
```

Проверено (`debug node`): под `node-debugger-lab-worker-…` с `hostPID=true hostNetwork=true`, `chroot /host crictl ps` показывает контейнеры узла. Под отладки остаётся после выхода — удалите: `kubectl delete pod node-debugger-lab-worker-…`.

### port-forward 🟢

```bash
kubectl -n orders port-forward svc/orders-api 9000:80     # localhost:9000 → под за Service
curl -s localhost:9000/version
```

Проверено: два запроса подряд ушли в **один и тот же** под (`orders-api-6d54d4c46b-fvq75`). `port-forward` к Service выбирает один под при старте и не балансирует — для проверки балансировки он не годится (03-2).

## 7. На узле: crictl, journalctl, etcdctl 🟡

В kind узел — контейнер, заходим `docker exec`. На реальном узле — ssh.

```bash
docker exec lab-worker crictl ps --name postgres                 # контейнеры CRI (не docker!)
docker exec lab-worker crictl logs <id>                          # логи мимо apiserver — если он лежит
docker exec lab-worker crictl inspect <id> | less                # pid, cgroup, mounts
docker exec lab-worker journalctl -u kubelet --no-pager -n 50    # логи kubelet
docker exec lab-worker ls /var/log/pods/                         # файлы логов подов
docker exec lab-control-plane ls /etc/kubernetes/manifests       # static pods control plane
```

Проверено (`crictl ps`):

```
CONTAINER           IMAGE               CREATED             STATE               NAME                ATTEMPT             POD ID              POD                 NAMESPACE
9099096da77e8       d741b37687468       3 minutes ago       Running             postgres            1                   a5d54697486e2       postgres-0          orders
```

etcd на стенде — static pod с `etcdctl` внутри:

```bash
E='etcdctl --endpoints=https://127.0.0.1:2379 --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt --key=/etc/kubernetes/pki/etcd/server.key'
kubectl -n kube-system exec etcd-lab-control-plane -- $E get /registry/deployments/orders/orders-api --keys-only
kubectl -n kube-system exec etcd-lab-control-plane -- $E endpoint status -w table
```

Проверено:

```
/registry/deployments/orders/orders-api

| ENDPOINT               | ID               | VERSION | ... | DB SIZE | IN USE | ... | QUOTA  | IS LEADER | ... | RAFT TERM | RAFT INDEX |
| https://127.0.0.1:2379 | 72f3761af4357e92 |   3.6.8 | ... |   14 MB | 7.4 MB | ... | 2.1 GB |      true | ... |         3 |       4392 |
```

etcd 3.6.8, квота базы 2,1 ГБ (дефолт 2 ГиБ) — к ней вернёмся в 11-3 §4. Значение ключа хранится в protobuf, не в JSON — читать его напрямую неудобно, это сделано в 01-1.

## 8. k9s и krew 🟢

- **k9s** — TUI поверх kubectl: `:pods`, `/фильтр`, `l` логи, `s` shell, `d` describe, `ctrl-d` удалить. Ускоряет навигацию, но на собеседовании и в runbook'ах пишите команды kubectl. 🅼 `sudo pacman -S k9s` (0.51.0 в extra); 🐧 — `.deb` с GitHub-релизов. ⚠️ в среде агента не запускался (нужен TTY).
- **krew** — менеджер плагинов kubectl: `kubectl krew install ctx ns stern neat tree`. `kubectl tree deploy/orders-api` — дерево владельцев (Deployment → ReplicaSet → Pod), `kubectl neat` — убрать из YAML `status` и `managedFields`. 🅼 `sudo pacman -S krew` (0.5.0); 🐧 — по инструкции krew.sigs.k8s.io. ⚠️ не проверено в среде агента.

Алиасы, которые стоит завести:

```bash
alias k=kubectl
source <(kubectl completion bash); complete -o default -F __start_kubectl k
export do='--dry-run=client -o yaml'       # k create deploy x --image=y $do > x.yaml
```

## 9. Уборка

```bash
kubectl -n orders rollout restart deploy/orders-api     # убрать под с ephemeral-контейнером
kubectl get pods -n default -o name | grep node-debugger | xargs -r kubectl delete --now   # поды debug node
kubectl config set-context --current --namespace=default
```

---

## 💼 Вопросы с собеседования

**🟢 Как посмотреть логи контейнера, который уже перезапустился?** `kubectl logs <pod> -c <container> --previous`. Если под удалён — логи только в системе сбора логов; на узле файлы живут в `/var/log/pods` до удаления пода.

**🟢 Как зайти в под, где нет shell?** `kubectl debug -it <pod> --image=busybox --target=<container>` — ephemeral container с общим сетевым и PID-namespace; файловая система цели — через `/proc/1/root`.

**🟡 Чем `--dry-run=client` отличается от `--dry-run=server`?** Client только формирует объект локально; server отправляет запрос в apiserver, где проходят валидация и admission (вебхуки, политики, квоты), но объект не сохраняется. Ошибки схемы и политик видны только в server.

**🟡 Как узнать, какой HTTP-запрос делает kubectl и почему он долгий?** `-v=6…9`: URL, коды, время, заголовки и тела. Дальше — метрики и аудит apiserver.

**🟡 Почему `port-forward` к Service не подходит для проверки балансировки?** Он выбирает один под при подключении и шлёт весь трафик в него; балансировку kube-proxy он не использует.

**🔴 apiserver недоступен, а надо понять, что с контейнером на узле. Ваши действия?** Ssh на узел: `crictl ps -a`, `crictl logs`, `crictl inspect`, `journalctl -u kubelet -u containerd`, файлы в `/var/log/pods`; для control plane — static pods в `/etc/kubernetes/manifests` и их логи через crictl.

---

## Чеклист

- [ ] Переключаю контекст и namespace, всегда знаю, в каком кластере работаю.
- [ ] Достаю поля через `jsonpath` и `custom-columns`, фильтрую по `--field-selector` и меткам.
- [ ] Проверяю изменения `kubectl diff` и `--dry-run=server` до `apply`.
- [ ] Читаю `-v=8` и понимаю путь API-запроса.
- [ ] Отлаживаю под без shell через `kubectl debug --target` и узел через `debug node`.
- [ ] Смотрю контейнеры и логи на узле через `crictl` и `journalctl`, читаю ключи etcd.

→ Следующая часть: **01-1. Control plane и путь запроса** — что происходит между `kubectl apply` и запущенным контейнером: apiserver, admission, etcd, watch, контроллеры, scheduler и kubelet; останавливаем scheduler и смотрим, что продолжает работать без control plane.
