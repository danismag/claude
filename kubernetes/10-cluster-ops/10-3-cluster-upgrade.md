# 10-2. Обновление кластера

> Модуль 10 «Эксплуатация кластера» · часть 2 из 3 · 🟡🔴 · ~1 ч чтения + ~1 ч лабы · Нужно: стенд 00-1. В лабе стенд обновляется с v1.36.1 до **v1.36.5** (патч-версия) — дальше курс работает на 1.36.5.

> Отличие от плана: часть 10-1 «etcd» в этой версии курса не опубликована (см. `00-plan.md`). Резервное копирование etcd упоминается здесь только как обязательный шаг перед обновлением.

---

## Зачем это DevOps-у

Kubernetes выпускает минорную версию примерно раз в 4 месяца и поддерживает три последних. Кластер, который не обновляют, через год выходит из поддержки: нет исправлений безопасности, managed-облака начинают обновлять его принудительно. Обновление — регулярная плановая работа, и на собеседовании спрашивают: «в каком порядке обновлять», «что такое version skew», «что ломается при обновлении».

Сквозной сценарий: обновляем control plane и узлы стенда, пока клиенты непрерывно ходят в `orders.localhost/api/orders`, и считаем ошибки.

---

## 1. Версии и правила перекоса (version skew) 🟢🟡

Версия `1.36.5`: `1` — мажор, `36` — минор (новые функции, удаление устаревших API), `5` — патч (исправления). Патч-обновление — безопасная рутина; минорное — проект с проверкой API.

Правила перекоса между компонентами (официальная политика):

| Компонент | Относительно kube-apiserver |
|---|---|
| kube-apiserver (несколько экземпляров) | соседние минорные версии только во время обновления |
| kube-controller-manager, kube-scheduler | не новее apiserver, не старше на 1 минор |
| kubelet, kube-proxy | не новее apiserver, старше **до 3 миноров** |
| kubectl | ±1 минор |

Отсюда порядок: **сначала control plane, потом узлы**; минорные версии — **по одной** (1.36 → 1.37 → 1.38), перепрыгнуть нельзя. Проверено на стенде: после обновления control plane узлы остались на v1.36.1 при apiserver v1.36.5 — кластер работает (§3).

## 2. Что проверить до обновления 🟡🔴

| Проверка | Как |
|---|---|
| бэкап etcd и проверка восстановления | снапшот etcd вне кластера; в managed — средства облака |
| удалённые и устаревшие API | метрика `apiserver_requested_deprecated_apis` (01-3), инструменты `pluto`/`kubent` по манифестам и Helm-релизам (⚠️ на стенде не запускались), release notes раздела «Deprecations and Removals» |
| совместимость дополнений | CNI, CSI, Ingress/Gateway-контроллер, операторы, cert-manager, Argo CD — матрицы поддерживаемых версий Kubernetes |
| PDB и drain | `kubectl get pdb -A`: нет ли нулевых бюджетов (05-4); stateful-нагрузка на local-томах |
| ёмкость | запас на узлах на время drain'а одного узла |
| `storedVersions` CRD | не удалены ли версии, в которых объекты ещё лежат в etcd (09-1) |
| план отката | для control plane — бэкап манифестов и etcd; на практике откат минорной версии apiserver не поддерживается — откат = восстановление |

`kubeadm upgrade plan` показывает, до чего можно обновиться, и что придётся сделать руками. Проверено (kubeadm v1.36.5 на стенде v1.36.1):

```
Components that must be upgraded manually after you have upgraded the control plane with 'kubeadm upgrade apply':
COMPONENT   NODE                CURRENT   TARGET
kubelet     lab-control-plane   v1.36.1   v1.36.5
kubelet     lab-worker          v1.36.1   v1.36.5
…
Upgrade to the latest version in the v1.36 series:
kube-apiserver            lab-control-plane   v1.36.1   v1.36.5
kube-proxy                                    1.36.1    v1.36.5
etcd                      lab-control-plane   3.6.8-0   3.6.8-0
You can now apply the upgrade by executing the following command:
	kubeadm upgrade apply v1.36.5
```

Для минорного обновления (kubeadm v1.37.1, проверено, без применения): `Target version: v1.37.1`, kubelet'ы всех узлов в списке ручных обновлений.

## 3. Обновление control plane 🟡

На kubeadm-кластере: установить новый `kubeadm` → `kubeadm upgrade plan` → `kubeadm upgrade apply vX.Y.Z` на первом узле control plane (`kubeadm upgrade node` — на остальных). Kubeadm по очереди заменяет манифесты static pod'ов (etcd, apiserver, controller-manager, scheduler), ждёт перезапуска каждого, обновляет kube-proxy и CoreDNS, ConfigMap'ы кластера.

Проверено (под непрерывной нагрузкой на сквозной сценарий):

```
exit=0 took 105s
[upgrade/staticpods] Preparing for "etcd" upgrade
[upgrade/staticpods] Renewing etcd-server certificate
[upgrade/staticpods] Renewing etcd-peer certificate
[upgrade/staticpods] Restarting the etcd static pod and backing up its manifest to "/etc/kubernetes/tmp/kubeadm-backup-manifests-…/etcd.yaml"
[upgrade/staticpods] Component "etcd" upgraded successfully!
[upgrade/staticpods] Preparing for "kube-apiserver" upgrade
[upgrade/staticpods] Renewing apiserver certificate
…
server v1.36.5
kube-proxy registry.k8s.io/kube-proxy:v1.36.5
orders during upgrade: ok=1359 fail=0
```

- Клиенты не заметили обновления control plane: **0 ошибок из 1359** — данные-плоскость не зависит от apiserver (01-1).
- Kubeadm **продлевает сертификаты** компонентов при `upgrade apply` — регулярные обновления заодно решают проблему годовых сертификатов (10-3).
- Резервные копии манифестов — в `/etc/kubernetes/tmp/kubeadm-backup-manifests-*`.

### Что пошло не так на стенде (и бывает в жизни) 🔴

1. **Образы тянулись 20+ минут.** Kubeadm на этапе preflight скачивает образы новой версии с `registry.k8s.io`; образа `coredns` на узле не оказалось (раньше в курсе образы в узлах чистились), pull шёл очень медленно, и kubeadm висел без явной ошибки. Решение — заранее: `kubeadm config images pull` (или зеркало реестра), а для kind — `kind load docker-image`.
2. **`failed to create etcd client: error syncing endpoints with etcd: context deadline exceeded`.** Серверный сертификат etcd был выписан на старый IP узла (`IP Address:172.20.0.4`), а после перезапусков Docker узел получил `172.20.0.2`. apiserver ходит в etcd через `127.0.0.1` и проблемы не видит, kubeadm — через IP узла и падает на TLS. Решение (проверено): перевыпустить сертификаты etcd с текущим адресом — `kubeadm init phase certs etcd-server` и `etcd-peer` с конфигурацией, где указан новый `advertiseAddress`, затем перезапуск etcd. Смена IP узла control plane на реальном кластере — та же история с сертификатами и манифестами.
3. **Свой шелл, убитый `pkill -f`.** При остановке зависшего kubeadm `pkill -f "kubeadm-1.36.5 upgrade"` убил и `sh -c`, в командной строке которого была та же подстрока. Останавливайте по PID (`pgrep -x`) — ровно предупреждение из правил курса.

## 4. Обновление узлов 🟡

Для каждого узла: **drain → обновить kubelet (и kubeadm-конфиг узла: `kubeadm upgrade node`) → перезапустить kubelet → uncordon**. Проверено:

```
node/lab-worker3 drained
Kubernetes v1.36.5
active
kubelet swap+ready in 4s
lab-worker done in 139s          ← на нём PostgreSQL на local-томе: drain ждал, БД была недоступна
lab-worker2 done in 8s
lab-control-plane done in 2s
lab-control-plane Ready v1.36.5 … lab-worker3 Ready v1.36.5
orders: 200
```

- Узел обновляется после drain — поды переезжают по PDB (05-4); stateful-поды на local-томах ждут возвращения узла (139 с простоя БД на стенде).
- Рабочие узлы в облаке обычно не обновляют «на месте», а **заменяют**: новый node pool/шаблон с новой версией → cordon/drain старых → удаление (blue-green узлов). Чище и откатывается возвратом старого пула.
- На узлах kind `/tmp` — `tmpfs` с `noexec` (проверено: `/tmp/kubelet: Permission denied`) — бинарники кладите в `/root` или `/usr/local/bin`.

## 5. Минорное обновление: удалённые API 🔴

Главный риск минорного обновления — **удаление API-версий**: манифесты, Helm-шаблоны, операторы и CI, которые используют `…/v1beta1` удалённого ресурса, перестают применяться (объекты в etcd apiserver переписывает в новую версию сам, ломаются клиенты). Порядок:

1. По release notes целевой версии — список удаляемых API.
2. В кластере — `apiserver_requested_deprecated_apis` (кто ходит в устаревшее) и аудит-лог (какой клиент).
3. В Git — `pluto`/`kubent` по манифестам и отрендеренным чартам.
4. Обновить манифесты и чарты **до** обновления кластера (новая версия API уже доступна в текущей).
5. Обновить дополнения (CNI, контроллеры, операторы) до версий, поддерживающих целевой Kubernetes.
6. Стенд → staging → prod, по одной минорной версии.

## 6. Managed-кластеры 🟡

В EKS/GKE/AKS/YC control plane обновляет облако (кнопкой или по расписанию), узлы — вы (node groups) или облако (auto-upgrade). Те же правила перекоса, те же удалённые API; плюс — окна обслуживания, принудительные обновления при выходе версии из поддержки, совместимость облачных дополнений (CNI, CSI, LB-контроллер). ⚠️ На стенде не проверялось.

---

## 🔧 Лаба

### Шаг 0. Подготовка и план

```bash
kubectl config use-context kind-lab
curl -s https://dl.k8s.io/release/stable-1.36.txt; echo         # последняя патч-версия ветки (у автора — v1.36.5)
CP=lab-control-plane
docker exec $CP sh -c 'curl -sfL -o /usr/local/bin/kubeadm-1.36.5 https://dl.k8s.io/release/v1.36.5/bin/linux/amd64/kubeadm && chmod +x /usr/local/bin/kubeadm-1.36.5'
docker exec $CP /usr/local/bin/kubeadm-1.36.5 upgrade plan
docker exec $CP /usr/local/bin/kubeadm-1.36.5 config images list
```

Проверено: вывод `upgrade plan` — в §2.

### Шаг 1. Образы заранее

```bash
for img in $(docker exec $CP /usr/local/bin/kubeadm-1.36.5 config images list 2>/dev/null); do
  docker pull -q $img && kind load docker-image $img --name lab --nodes lab-control-plane
done
```

Так kubeadm не будет ждать pull'а с registry.k8s.io (§3, пункт 1).

### Шаг 2. Сертификаты etcd и текущий IP

```bash
docker inspect -f '{{.NetworkSettings.Networks.kind.IPAddress}}' $CP
docker exec $CP openssl x509 -in /etc/kubernetes/pki/etcd/server.crt -noout -ext subjectAltName
```

Если IP узла нет в SAN (после перезапусков стенда он мог смениться) — перевыпустите сертификаты etcd:

```bash
docker exec $CP sh -c 'IP=$(hostname -I | cut -d" " -f1)
{ printf "apiVersion: kubeadm.k8s.io/v1beta4\nkind: InitConfiguration\nlocalAPIEndpoint: {advertiseAddress: %s}\nnodeRegistration: {name: lab-control-plane}\n---\n" $IP
  kubectl --kubeconfig /etc/kubernetes/admin.conf -n kube-system get cm kubeadm-config -o jsonpath="{.data.ClusterConfiguration}"; } > /root/kubeadm-certs.yaml
mkdir -p /root/old-etcd-certs && mv /etc/kubernetes/pki/etcd/server.* /etc/kubernetes/pki/etcd/peer.* /root/old-etcd-certs/
kubeadm init phase certs etcd-server --config /root/kubeadm-certs.yaml
kubeadm init phase certs etcd-peer --config /root/kubeadm-certs.yaml
mv /etc/kubernetes/manifests/etcd.yaml /root/ && sleep 15 && mv /root/etcd.yaml /etc/kubernetes/manifests/'
sleep 20; docker exec $CP sh -c 'curl -s --cacert /etc/kubernetes/pki/etcd/ca.crt --cert /etc/kubernetes/pki/apiserver-etcd-client.crt --key /etc/kubernetes/pki/apiserver-etcd-client.key https://$(hostname -I | cut -d" " -f1):2379/health'
```

Проверено: новые SAN `IP Address:172.20.0.2, …`, `{"health":"true","reason":""}`.

### Шаг 3. Control plane под нагрузкой

```bash
( end=$(( $(date +%s)+300 )); ok=0; fail=0
  while [ $(date +%s) -lt $end ]; do
    curl -s -m 2 -o /dev/null -w '%{http_code}' http://orders.localhost:8088/api/orders | grep -q 200 && ok=$((ok+1)) || fail=$((fail+1)); sleep 0.2
  done; echo "orders during upgrade: ok=$ok fail=$fail" ) > /tmp/upg-load.txt &
docker exec $CP sh -c '/usr/local/bin/kubeadm-1.36.5 upgrade apply v1.36.5 -y > /root/kubeadm-upgrade.log 2>&1; echo exit=$?'
docker exec $CP grep -E 'SUCCESS|upgrade/staticpods' /root/kubeadm-upgrade.log
kubectl version; kubectl get nodes
wait; cat /tmp/upg-load.txt
```

Проверено: вывод в §3 (105 с, 0 ошибок клиентов).

### Шаг 4. Узлы

```bash
curl -sfL -o /tmp/kubelet-1.36.5 https://dl.k8s.io/release/v1.36.5/bin/linux/amd64/kubelet
for W in lab-worker3 lab-worker lab-worker2 lab-control-plane; do
  s=$(date +%s)
  kubectl drain $W --ignore-daemonsets --delete-emptydir-data --force --timeout=180s
  docker cp /tmp/kubelet-1.36.5 $W:/root/kubelet-1.36.5
  docker exec $W sh -c 'chmod +x /root/kubelet-1.36.5 && cp /usr/bin/kubelet /root/kubelet-old && systemctl stop kubelet && cp /root/kubelet-1.36.5 /usr/bin/kubelet && systemctl start kubelet'
  until [ "$(kubectl get node $W -o jsonpath='{.status.nodeInfo.kubeletVersion}')" = v1.36.5 ]; do sleep 2; done
  kubectl uncordon $W; echo "$W done in $(( $(date +%s)-s ))s"
done
kubectl get nodes
curl -s -o /dev/null -w '%{http_code}\n' http://orders.localhost:8088/api/orders
```

Проверено: вывод в §4. На kubeadm-узлах в проде вместо копирования бинарника — пакеты `kubelet`/`kubeadm` нужной версии из `pkgs.k8s.io` (00-1 §2) и `kubeadm upgrade node`.

### Шаг 5. План минорного обновления

```bash
docker exec $CP sh -c 'curl -sfL -o /usr/local/bin/kubeadm-1.37.1 https://dl.k8s.io/release/v1.37.1/bin/linux/amd64/kubeadm && chmod +x /usr/local/bin/kubeadm-1.37.1'
docker exec $CP /usr/local/bin/kubeadm-1.37.1 upgrade plan v1.37.1
kubectl get --raw /metrics | grep '^apiserver_requested_deprecated_apis'
```

Применять не нужно: дальше курс рассчитан на 1.36. Посмотрите, какие API удаляются в 1.37, по release notes.

### Уборка

```bash
docker exec $CP sh -c 'rm -f /usr/local/bin/kubeadm-1.36.5 /usr/local/bin/kubeadm-1.37.1 /root/kubeadm-certs.yaml'
for W in lab-control-plane lab-worker lab-worker2 lab-worker3; do docker exec $W rm -f /root/kubelet-1.36.5 /root/kubelet-old; done
rm -f /tmp/kubelet-1.36.5 /tmp/upg-load.txt
```

Пересоздание стенда (`lab-down.sh --purge && lab-up.sh`) вернёт 1.36.1 — `NODE_IMAGE` в `lab-up.sh`.

---

## 🔥 Кейс из прода: «после обновления упал деплой: удалили API-версию»

**Контекст.** Кластер обновили с 1.24 до 1.25 (managed, кнопкой, в окно обслуживания). Через день CI сервиса биллинга не смог задеплоиться: `no matches for kind "PodSecurityPolicy" in version "policy/v1beta1"` и `no matches for kind "CronJob" in version "batch/v1beta1"`. Работающие CronJob'ы продолжали выполняться.

**Разбор.**
1. В 1.25 удалены `batch/v1beta1` CronJob (замена — `batch/v1`, доступна с 1.21) и PodSecurityPolicy целиком (замена — Pod Security Admission, 06-3).
2. Объекты в etcd apiserver хранит в актуальной версии — поэтому существующие CronJob работали; сломались **манифесты** в Git и Helm-шаблон чарта, отправляющие удалённую версию.
3. Предупреждения о deprecated API были год (01-3: `Warning: … is deprecated`), но их никто не читал — CI скрывал вывод kubectl.

**Фикс.**
- Манифесты переведены на `batch/v1`; PSP заменены метками Pod Security Admission на namespace.
- В CI — проверка манифестов и отрендеренных чартов `pluto`/`kubent` против **следующей** минорной версии; падение сборки при найденных удалённых API.
- Алерт на `apiserver_requested_deprecated_apis` с указанием `removed_release`.
- Порядок обновлений: release notes → проверка → стенд → staging → prod, не «кнопкой в окно».

**Что запомнить.**
- Минорное обновление удаляет API — ломаются клиенты и манифесты, а не объекты в кластере.
- Предупреждения `deprecated` надо видеть и чинить до обновления.
- Новая версия API почти всегда доступна заранее — переходите на неё в текущем кластере.

---

## 💼 Вопросы с собеседования

### 🟢 Junior

**1. В каком порядке обновлять кластер?**
Бэкап etcd → control plane (по одному узлу) → дополнения → рабочие узлы по одному (drain, обновление kubelet, uncordon). Минорные версии — по одной.

**2. Можно ли обновиться с 1.34 сразу на 1.36?**
Нет: control plane обновляется по одной минорной версии. Kubelet'ы могут отставать до трёх миноров, но не опережать apiserver.

### 🟡 Middle

**3. Что такое version skew и зачем его знать?**
Допустимая разница версий компонентов: kubelet до 3 миноров старше apiserver, controller-manager/scheduler — не старше на 1, kubectl ±1. Определяет порядок обновления и сколько узлов можно оставить на старой версии.

**4. Что проверить перед минорным обновлением?**
Удаляемые API (release notes, `apiserver_requested_deprecated_apis`, pluto/kubent), совместимость CNI/CSI/контроллеров/операторов, PDB с нулевым бюджетом, ёмкость для drain, бэкап etcd, порядок окружений.

**5. Заметят ли клиенты обновление control plane?**
Нет, если всё в порядке: поды, сеть и Service'ы не зависят от apiserver (на стенде — 0 ошибок из 1359 за время обновления). Деплои, HPA и самовосстановление на время перезапуска apiserver приостанавливаются.

### 🔴 Senior

**6. Как обновлять узлы в облаке без риска?**
Заменой, а не на месте: новый node pool с новой версией, cordon/drain старого по одному узлу (PDB, graceful shutdown), проверка, удаление старого пула; откат — вернуть нагрузку на старый пул. Учитывать stateful-нагрузку на локальных дисках и зоны PV.

**7. kubeadm upgrade зависает или падает. Где искать?**
Лог `kubeadm upgrade apply --v=2+`: этап (preflight-pull образов, static pods, addons). Типичные: образы не скачиваются (лимиты, медленный реестр — заранее `config images pull`), etcd недоступен по адресу узла (сертификаты на старый IP, сеть), static pod не стартует с новым манифестом (резервная копия в `/etc/kubernetes/tmp`), webhook'и блокируют обновление дополнений.

**8. Как откатить неудачное минорное обновление?**
Откат apiserver на предыдущую минорную версию не поддерживается (схема хранения в etcd могла измениться). Реальный откат — восстановление control plane из бэкапа etcd, снятого до обновления, с потерей изменений после него; поэтому обновление идёт через стенд/staging, а prod — с проверенным бэкапом и окном.

---

## ⚠️ Подводные камни

- Перепрыгнуть минорную версию control plane нельзя.
- Удалённые API ломают манифесты и чарты, а не объекты в etcd.
- Kubeadm молча ждёт pull'а образов — скачивайте заранее.
- Сертификаты etcd на старый IP узла ломают kubeadm, хотя apiserver работает.
- `pkill -f` с подстрокой из собственной команды убивает свой шелл — останавливайте по PID.
- Drain узла с local-томами — простой stateful-подов.
- `/tmp` в узлах kind — `noexec`.
- Дополнения (CNI, CSI, контроллеры) должны поддерживать новую версию до обновления.
- Пересоздание стенда возвращает исходную версию образа узла.

---

## Чеклист

- [ ] Назову правила version skew и порядок обновления.
- [ ] Составлю чек-лист проверок перед минорным обновлением.
- [ ] Выполню `kubeadm upgrade plan/apply` и обновлю узлы через drain.
- [ ] Измерю влияние обновления на клиентов.
- [ ] Разберу зависший или упавший `kubeadm upgrade`.
- [ ] Найду удаляемые API до обновления.

---

## Задание со звёздочкой

Отрепетируйте минорное обновление на отдельном кластере:

1. Создайте второй kind-кластер на `kindest/node:v1.36.x` (`kind create cluster --name upg`).
2. Примените в нём манифест с намеренно устаревшим API (найдите в release notes 1.37 удаляемый ресурс) и убедитесь, что метрика `apiserver_requested_deprecated_apis` его показывает.
3. Обновите control plane до 1.37.1 kubeadm'ом (шаги 1–3 этой части) — что произошло с устаревшим манифестом при повторном `kubectl apply`?
4. Удалите кластер: `kind delete cluster --name upg`.

---

→ Следующая часть: **10-3. Сертификаты и обслуживание узлов** — PKI kubeadm, срок действия сертификатов (год) и `kubeadm certs check-expiration/renew`, ротация клиентского сертификата kubelet, плановое обслуживание узла по runbook'у.
