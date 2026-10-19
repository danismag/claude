# 11-3. Узел и control plane

> Модуль 11 «Диагностика» · часть 3 из 3 · 🟡🔴 · ~45 мин чтения + ~1 ч лабы · Нужно: стенд 00-1, orders. Опирается на 01-1 (компоненты), 01-2 (kubelet и CRI), 05-1 (eviction), 10-2/10-3 (обслуживание).

---

## Зачем это DevOps-у

Когда ломается узел или control plane, страдают не один под, а десятки сервисов. Первые минуты решают, будет ли это «небольшой инцидент» или «простой на полдня». Надо понимать:
- что продолжает работать без apiserver;
- через сколько секунд и минут Kubernetes сам переносит поды;
- где смотреть логи компонентов, которых нет в `kubectl logs`.

На собеседовании Senior/SRE это любимая тема: «узел NotReady, что происходит с подами и когда?», «apiserver лежит — сайт работает?».

На стенде проверены пять сценариев:
- kubelet остановлен;
- containerd остановлен;
- apiserver выключен;
- scheduler выключен;
- под превысил лимит ephemeral-storage.

Цифры ниже — с них.

---

## 1. Узел NotReady: хронология 🟡

Проверено: `systemctl stop kubelet` на `lab-worker3`, Kubernetes 1.36.5:

| Время от остановки | Что происходит |
|---|---|
| 0 с | kubelet перестаёт обновлять Lease узла; контейнеры **продолжают работать** (`crictl inspect` → `CONTAINER_RUNNING`) |
| **47 с** | node-lifecycle-controller: `Ready=Unknown NodeStatusUnknown: Kubelet stopped posting node status`; taints `node.kubernetes.io/unreachable` NoSchedule + NoExecute; поды узла → `Ready=False`, их адреса в EndpointSlice → `ready:false` |
| 47 с + **300 с** | истекает `tolerationSeconds: 300` (добавляется ко всем подам DefaultTolerationSeconds admission) → эвикция: поды узла `Terminating`, контроллеры создают замены на других узлах (на стенде: 16:25:41 taint → 16:30:41–51 замены) |
| +20 с | новые поды Running, трафик восстановлен (16:31:12) |
| kubelet вернулся | узел Ready за ~1 с, зависшие `Terminating` поды удалены за 17 с |

Откуда цифры:
- `--node-monitor-grace-period` у controller-manager — **50 с** по умолчанию (проверено `kube-controller-manager --help` в 1.36.5; до 1.32 было 40 с). Отсчёт идёт от последнего обновления Lease, которое было за несколько секунд до остановки, поэтому на стенде вышло 47 с;
- 300 с — `--default-unreachable-toleration-seconds` у apiserver.

Для stateful-подов и DaemonSet своя логика:
- DaemonSet толерирует эти taints бессрочно;
- под StatefulSet на недоступном узле остаётся `Terminating` до возврата узла или ручного решения (`kubectl delete pod --force` — только если узел точно мёртв, 02-3).

**Остановка containerd** (проверено):
- через **32 с** `Ready=False KubeletNotReady: container runtime is down`;
- в журнале kubelet: `GenericPLEG: Unable to retrieve pods … dial unix /run/containerd/containerd.sock`;
- taint `node.kubernetes.io/not-ready` NoExecute — тот же отсчёт 300 с;
- работающие контейнеры **не падают**: shim-процессы живут без containerd;
- после `systemctl start containerd` узел Ready через 10 с, под `s1` — `Running 0` рестартов.

## 2. Главный урок стенда: единственная реплика на «больном» узле 🔴

Во время опыта с kubelet сквозной запрос не проходил **все 6 минут**: 0 из 50 успешных, `Failed to connect … port 30080 after 0 ms`. orders-api жил на двух узлах, так что дело было не в нём. **Единственная реплика Envoy** и контроллер Envoy Gateway стояли на `lab-worker3`:
- у Service Envoy не осталось ready-эндпоинтов;
- kube-proxy на всех узлах отказывал в соединении на NodePort;
- через 300 с Envoy пересоздался на `lab-worker2`, через 20 с трафик пошёл.

Выводы для прода:
- Gateway/Ingress — ≥ 2 реплики, `topologySpreadConstraints` по узлам/зонам, PDB (03-4, 05-2);
- 5 минут по умолчанию — слишком долго для stateless-критичных подов: можно задать свои `tolerations` с `tolerationSeconds: 30` для `unreachable`/`not-ready`, но тогда короткие сетевые моргания будут вызывать массовые переезды;
- эндпоинты убираются из Service уже на 47-й секунде (под `Ready=False`), так что при ≥ 2 репликах на разных узлах пользователь видит лишь ~40 с ошибок на долю запросов, а не 6 минут.

## 3. Control plane лежит 🟡

**apiserver выключен** (манифест static pod перенесён из `/etc/kubernetes/manifests`, проверено):
- `kubectl` → `The connection to the server lab-control-plane:6443 was refused`;
- **трафик orders — 30 из 30 успешных**: data plane (kube-proxy, iptables, CNI, контейнеры) работает без control plane;
- kubelet узлов: `Failed to ensure lease exists, will retry` — копит ошибки, но ничего не убивает;
- scheduler и controller-manager работают, но ждут apiserver (`Waiting for caches to sync`);
- возврат манифеста — apiserver `readyz check passed` через 4 с (образ в кэше).

Что **не** работает без apiserver: деплой, масштабирование, HPA, замена упавших подов, изменение Endpoints. Новый под не появится, упавший не заменится, а сменивший IP под не попадёт в Service. Кластер «замораживается» в последнем состоянии.

**scheduler выключен** (проверено): новый под `Pending`, у него **нет событий** (`No resources found`), а `renewTime` Lease `kube-system/kube-scheduler` перестал обновляться. После возврата: `Scheduled` за 3 с. Признак «Pending без единого события» — смотреть scheduler (или `schedulerName` пода, 01-1).

**controller-manager выключен** — ⚠️ не проверено отдельно, ожидаемо: Deployment не создаёт ReplicaSet/поды, удалённые поды не заменяются, узлы не помечаются NotReady (node-lifecycle-controller в нём же), GC не удаляет зависимые объекты.

## 4. Где логи компонентов 🟡

| Компонент | kubeadm / kind | Managed (EKS/GKE/AKS) |
|---|---|---|
| kubelet, containerd | `journalctl -u kubelet`, `-u containerd` на узле (`docker exec <node> journalctl …` в kind, `kubectl debug node/…` + `chroot /host`) | так же на узле; control plane — в облачных логах |
| apiserver, scheduler, controller-manager, etcd | static pods: `kubectl -n kube-system logs kube-apiserver-<cp>`; если apiserver лежит — `crictl ps -a`, `crictl logs <id>` на control-plane, `/var/log/pods/` | CloudWatch / Cloud Logging / Azure Monitor (включить заранее) |
| состояние apiserver | `kubectl get --raw '/readyz?verbose'`, `/livez`, `/livez/etcd` | то же |
| лидеры | `kubectl -n kube-system get lease kube-scheduler kube-controller-manager` | то же |

etcd (проверено, etcdctl внутри пода etcd с сертификатом healthcheck-client):

```
VERSION 3.6.8 | DB SIZE 9.0 MB | IN USE 5.5 MB | QUOTA 2.1 GB | IS LEADER true
https://127.0.0.1:2379 is healthy: successfully committed proposal: took = 5.022125ms
```

На что смотреть:
- **DB SIZE против QUOTA**: при исчерпании квоты (2 ГиБ по умолчанию) etcd поднимает alarm `NOSPACE` и принимает только чтение и удаление;
- `took` у health (на SSD — единицы мс);
- метрики `etcd_disk_wal_fsync_duration_seconds` (p99 < 10 мс) и `etcd_server_leader_changes_seen_total`;
- у apiserver — `apiserver_storage_size_bytes` (на стенде `9.02e+06`, то же значение).

Медленный диск etcd проявляется как `etcdserver: request timed out` в apiserver и медленные `kubectl apply`, а не как ошибки у подов.

## 5. Давление на узел и eviction 🟡

Kubelet выселяет поды при нехватке ресурса узла (05-1 §5):
- **пороги по умолчанию**: `memory.available<100Mi`, `nodefs.available<10%`, `nodefs.inodesFree<5%`, `imagefs.available<15%`;
- условия узла `MemoryPressure`, `DiskPressure`, `PIDPressure` + taints `node.kubernetes.io/*-pressure`.

На стенде kind **отключает дисковые пороги** (`evictionHard: imagefs.available: 0%, nodefs.available: 0%, nodefs.inodesFree: 0%` в `/var/lib/kubelet/config.yaml`, проверено). Поэтому DiskPressure не воспроизводится. На обычном узле стенд уже был бы в DiskPressure: на диске хоста 9,2 ГБ свободно из 98 (9,4 % < 10 %). ⚠️ DiskPressure узла в среде агента не проверено.

Воспроизводимо — **превышение лимита `ephemeral-storage` подом** (проверено): `dd` 50 MiB при `limits.ephemeral-storage: 20Mi` → через ~10 с `Failed Evicted`, сообщение `Pod ephemeral local storage usage exceeds the total limit of containers 20Mi.` Типичные пожиратели:
- логи в файлы внутри контейнера;
- `emptyDir` без `sizeLimit`;
- кэши и временные файлы;
- образы (imagefs).

Диагностика диска узла:

```bash
kubectl describe node <n> | grep -A8 Conditions
kubectl get --raw /api/v1/nodes/<n>/proxy/stats/summary | python3 -m json.tool | grep -A3 '"fs"'
# на узле:
df -h /var/lib/containerd /var/lib/kubelet; crictl imagefsinfo; du -sh /var/log/pods/* | sort -h | tail
crictl rmi --prune          # неиспользуемые образы (образы, загруженные kind load, — только по имени)
```

## 6. Runbook «упало всё» 🔴

1. **Масштаб**:
   - `kubectl get nodes` отвечает? Нет — control plane или сеть до него, переходим к п. 4.
   - Отвечает — `kubectl get pods -A | grep -v Running` и `kubectl get nodes`: один узел, одна зона, все?
2. **Узлы NotReady**:
   - `describe node` → Conditions (`NodeStatusUnknown` — kubelet молчит; `container runtime is down`; `*Pressure`);
   - затем `journalctl -u kubelet -u containerd` на узле.
3. **Data plane или control plane**: трафик идёт, а `kubectl` нет — data plane жив, пользователей это пока не касается, но ничего нельзя менять. Не делайте rollout'ов, пока apiserver нестабилен.
4. **apiserver**:
   - `crictl ps -a | grep apiserver` и `crictl logs` на control-plane;
   - частые причины: истёкшие сертификаты (10-3), etcd недоступен/медленный, OOM узла control-plane, ошибочный флаг в манифесте после правки.
5. **etcd**: `endpoint health/status`, alarms, место на диске, `took`, смены лидера.
6. **Фиксация**: время начала, что менялось (`kubectl get events -A --sort-by=.lastTimestamp`, история деплоев/GitOps, изменения инфраструктуры).

---

## 🔧 Лаба

Все шаги обратимы. Порядок важен: сначала узел, затем control plane.

### Шаг 1. kubelet остановлен

```bash
kubectl get pods -A -o wide --field-selector spec.nodeName=lab-worker3     # что живёт на узле
docker exec lab-worker3 systemctl stop kubelet
kubectl get node lab-worker3 -w                                             # NotReady через ~47 с
kubectl get node lab-worker3 -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}{"\n"}{end}{.spec.taints}{"\n"}'
kubectl -n orders get endpointslice -l kubernetes.io/service-name=orders-api -o jsonpath='{range .items[0].endpoints[*]}{.addresses[0]} {.nodeName} {.conditions.ready}{"\n"}{end}'
for i in $(seq 1 20); do curl -s -m 3 -o /dev/null -w '%{http_code} ' http://orders.localhost:8088/api/orders; done; echo
kubectl get pods -A -o wide -w | grep -E 'envoy-envoy|orders-api'          # эвикция через 300 с после taint
```

Проверено:
- `Ready=Unknown NodeStatusUnknown: Kubelet stopped posting node status`, taints `unreachable` NoSchedule+NoExecute;
- контейнеры на узле `CONTAINER_RUNNING`;
- если Envoy на этом узле — запросы `000` (отказ в соединении) до его переезда; у нас 6 минут.

```bash
docker exec lab-worker3 systemctl start kubelet
kubectl get pods -A | grep Terminating            # исчезают за ~17 с
```

### Шаг 2. containerd остановлен

```bash
kubectl create ns lab-11-3
kubectl -n lab-11-3 run s1 --image=busybox:1.37 --restart=Never --overrides='{"spec":{"nodeName":"lab-worker3"}}' -- sleep 3600
docker exec lab-worker3 systemctl stop containerd
kubectl get node lab-worker3 -w                   # NotReady через ~32 с: container runtime is down
docker exec lab-worker3 journalctl -u kubelet --since -1min --no-pager | grep PLEG | tail -1
docker exec lab-worker3 systemctl start containerd
kubectl -n lab-11-3 get pod s1                    # Running, RESTARTS 0
```

### Шаг 3. apiserver выключен — трафик идёт

```bash
docker exec lab-control-plane mv /etc/kubernetes/manifests/kube-apiserver.yaml /root/kube-apiserver.yaml
sleep 25; kubectl get nodes                       # connection … refused
for i in $(seq 1 30); do curl -s -m 5 -o /dev/null -w '%{http_code} ' http://orders.localhost:8088/api/orders; done; echo   # все 200
docker exec lab-control-plane crictl ps -a --name kube-apiserver
docker exec lab-worker journalctl -u kubelet --since -1min --no-pager | grep -m1 lease
docker exec lab-control-plane mv /root/kube-apiserver.yaml /etc/kubernetes/manifests/kube-apiserver.yaml
until kubectl get --raw /readyz >/dev/null 2>&1; do sleep 2; done; kubectl get --raw '/readyz?verbose' | tail -1
```

### Шаг 4. scheduler выключен — Pending без событий

```bash
docker exec lab-control-plane mv /etc/kubernetes/manifests/kube-scheduler.yaml /root/kube-scheduler.yaml; sleep 20
kubectl -n lab-11-3 run s2 --image=busybox:1.37 --restart=Never -- sleep 3600; sleep 15
kubectl -n lab-11-3 get pod s2; kubectl -n lab-11-3 get events --field-selector involvedObject.name=s2   # Pending, событий нет
kubectl -n kube-system get lease kube-scheduler -o jsonpath='{.spec.renewTime}{"\n"}'; date -u +%T          # renewTime отстаёт
docker exec lab-control-plane mv /root/kube-scheduler.yaml /etc/kubernetes/manifests/kube-scheduler.yaml; sleep 20
kubectl -n lab-11-3 get pod s2                    # Running, событие Scheduled
```

### Шаг 5. etcd и ephemeral-storage

```bash
E="kubectl -n kube-system exec etcd-lab-control-plane -- etcdctl --endpoints=https://127.0.0.1:2379 --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/healthcheck-client.crt --key=/etc/kubernetes/pki/etcd/healthcheck-client.key"
$E endpoint status -w table; $E endpoint health; $E alarm list
kubectl get --raw /livez/etcd; echo
docker exec lab-worker3 grep -A4 evictionHard /var/lib/kubelet/config.yaml
kubectl -n lab-11-3 apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata: {name: eph}
spec:
  restartPolicy: Never
  containers:
  - name: app
    image: busybox:1.37
    command: ["sh","-c","dd if=/dev/zero of=/data.bin bs=1M count=50; sleep 3600"]
    resources: {limits: {ephemeral-storage: 20Mi}}
EOF
sleep 25; kubectl -n lab-11-3 get pod eph -o jsonpath='{.status.phase} {.status.reason}: {.status.message}{"\n"}'
# Failed Evicted: Pod ephemeral local storage usage exceeds the total limit of containers 20Mi.
```

### Уборка

```bash
kubectl delete ns lab-11-3
docker exec lab-control-plane ls /etc/kubernetes/manifests     # etcd, kube-apiserver, kube-controller-manager, kube-scheduler
kubectl get nodes                                               # все Ready
curl -s -o /dev/null -w '%{http_code}\n' http://orders.localhost:8088/api/orders   # 200
```

---

## 🔥 Кейс из прода: «узел умер — сайт лежал 6 минут»

**Контекст.** Ночью у облачного провайдера отказал гипервизор: один из шести узлов пропал без drain. Сайт лежал 6 минут, хотя у всех сервисов было по 3 реплики.

**Разбор.**
1. По хронологии: NotReady через ~50 с, эвикция через 5 минут, восстановление ещё через ~30 с — совпадает с дефолтами (§1).
2. Все бизнес-сервисы потеряли лишь треть эндпоинтов, и уже через 45 с ошибки пропали. Не работал **ingress-контроллер**: его 2 реплики стояли на одном узле (anti-affinity не было, scheduler разместил их «по свободным ресурсам»).
3. Пять минут ждали эвикции, ещё 30 с — запуска контроллера на новом узле.

**Фикс.**
- `topologySpreadConstraints` по `kubernetes.io/hostname` и зоне с `whenUnsatisfiable: DoNotSchedule` для ingress и других критичных компонентов (CoreDNS, Gateway);
- `PodDisruptionBudget` `minAvailable: 1`;
- `tolerationSeconds: 60` для `unreachable`/`not-ready` у ingress-подов;
- алерт «все реплики deployment на одном узле» (kube-state-metrics + запрос по `kube_pod_info`).

**Что запомнить.**
- `replicas: 2` без правил распределения не защищает от потери узла.
- Дефолтные 5 минут до эвикции надо осознанно принимать или менять для критичных компонентов.
- Платформенные компоненты (ingress, DNS, Gateway) — первые кандидаты на отказоустойчивое размещение.

---

## 💼 Вопросы с собеседования

### 🟡 Middle

**1. Узел стал NotReady. Что происходит с подами и когда?**
Через ~50 с (`node-monitor-grace-period`, 50 с с 1.32, раньше 40) узел `Unknown`/`NotReady`, taints `unreachable`/`not-ready`, поды `Ready=False` и выпадают из Service. Через 300 с (`tolerationSeconds` по умолчанию) — эвикция и пересоздание контроллерами на других узлах. Контейнеры на самом узле могут продолжать работать. DaemonSet не трогается, StatefulSet ждёт.

**2. apiserver недоступен — работает ли приложение?**
Да: kube-proxy, CNI, контейнеры работают без control plane (на стенде 30/30 запросов при выключенном apiserver). Не работают изменения: деплой, масштабирование, замена упавших подов, обновление эндпоинтов.

**3. Под Pending, и у него вообще нет событий. Что проверите?**
Работает ли scheduler (static pod, лидер в Lease `kube-scheduler`, `renewTime`), не указан ли в поде чужой `schedulerName`. Нет событий — значит, никто не пытался его планировать.

### 🔴 Senior

**4. Где смотреть логи kubelet и apiserver, если `kubectl` не работает?**
kubelet и containerd — `journalctl -u kubelet/-u containerd` на узле. apiserver (kubeadm) — `crictl ps -a`, `crictl logs`, `/var/log/pods` на control-plane; в managed-кластерах — облачные логи control plane, включённые заранее.

**5. Как etcd влияет на кластер и что мониторить?**
Все записи apiserver идут в etcd. Медленный fsync даёт таймауты apiserver и смены лидера; заполненная квота (2 ГиБ по умолчанию) даёт `NOSPACE` и запрет записи. Мониторить: `etcd_disk_wal_fsync_duration_seconds` p99 < 10 мс, `leader_changes`, DB size против quota, `took` у health, `apiserver_storage_size_bytes`.

**6. Как сократить простой при потере узла с критичным компонентом?**
≥ 2 реплики с topology spread по узлам/зонам, PDB; уменьшенный `tolerationSeconds` для `unreachable`/`not-ready` (60 с вместо 300, взвесив риск массовых переездов при сетевых морганиях); readiness, честно отражающая готовность; внешний балансировщик с health check на узлы/поды.

**7. Узел в DiskPressure. Что делать?**
`describe node` (Conditions), `stats/summary`, на узле `df`/`du` по `/var/lib/containerd`, `/var/lib/kubelet`, `/var/log/pods`. Причины: образы (imagefs, GC порогами `imageGCHigh/LowThresholdPercent`), логи контейнеров (ротация `containerLogMaxSize`), `emptyDir` без `sizeLimit`. Kubelet сначала чистит образы, затем выселяет поды по превышению requests ephemeral-storage. Профилактика — `ephemeral-storage` requests/limits.

---

## ⚠️ Подводные камни

- Узел NotReady ≠ контейнеры остановлены: при сетевом разделении старые поды продолжают работать (и писать в БД!), пока появляются замены. StatefulSet поэтому ждёт.
- `kubectl delete pod --force` для пода на недоступном узле — риск двух экземпляров с одним томом.
- Дефолтные 300 с до эвикции — для критичных компонентов это 5 минут простоя.
- kind отключает дисковые пороги eviction — поведение DiskPressure на стенде не совпадает с продом.
- Логи static pod control plane при лежащем apiserver — только через `crictl`/`/var/log/pods`.
- Kubelet пытается запустить каждый нескрытый файл в `/etc/kubernetes/manifests` как static pod: копия `kube-apiserver.yaml.bak` рядом с оригиналом — второй apiserver или ошибки в журнале kubelet. Храните копии вне этого каталога, как в лабе (`/root`).
- Без включённых заранее облачных логов control plane в managed-кластере причину падения apiserver не узнать.

---

## Чеклист

- [ ] Назову хронологию NotReady → taints → эвикция с цифрами и параметрами.
- [ ] Объясню, что работает и что нет при недоступном apiserver.
- [ ] Найду логи kubelet, containerd и static pods без `kubectl`.
- [ ] Проверю состояние etcd и назову ключевые метрики.
- [ ] Отличу eviction по давлению узла от eviction по лимиту пода.
- [ ] Расскажу runbook «упало всё».

---

## Задание со звёздочкой

1. Повторите шаг 1, но сначала масштабируйте Envoy до 2 реплик с `topologySpreadConstraints` (через `EnvoyProxy` `spec.provider.kubernetes.envoyDeployment`, 03-4) и замерьте долю ошибок и длительность простоя.
2. Добавьте orders-api `tolerations` для `unreachable`/`not-ready` с `tolerationSeconds: 30` и сравните время появления замены.
3. Верните исходные настройки и оформите результаты как runbook «потеря узла» на одну страницу.

---

→ Следующий модуль: **12. Подготовка к собеседованию** — банк из ~150 вопросов с эталонами, тренажёры «сломай и почини», system design и матрица самопроверки.
