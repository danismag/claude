# 04-2. Хранилище: PV, PVC, StorageClass, CSI

> Модуль 4 «Конфигурация и данные» · часть 2 из 3 · 🟢🟡🔴 · ~1,5 ч чтения + ~45 мин лабы · Нужно: стенд 00-1 (StorageClass `standard` — local-path-provisioner)

---

## Зачем это DevOps-у

С томами связаны самые неприятные инциденты: данные потеряны, потому что удалили PVC с `reclaimPolicy: Delete`; под с БД не стартует после drain, потому что его диск в другой зоне; место на узле кончилось, потому что «том на 1 ГиБ» на деле не ограничен. На собеседовании: «PV и PVC — в чём разница», «что такое StorageClass и WaitForFirstConsumer», «почему RWO, а под на другом узле не видит том».

В сквозном сценарии PostgreSQL хранит данные в PVC `data-postgres-0` на local-path — уже видели, что он привязан к узлу (01-2) и что его «1Gi» — это весь диск хоста (02-3).

---

## 1. Объекты 🟢

| Объект | Кто создаёт | Что это |
|---|---|---|
| **PersistentVolume (PV)** | администратор (статически) или provisioner (динамически) | конкретный том: диск облака, каталог узла, NFS-путь, LUN; cluster-scoped |
| **PersistentVolumeClaim (PVC)** | пользователь/StatefulSet | заявка: «нужно 10 ГиБ, RWO, класс fast»; в namespace |
| **StorageClass** | администратор | «как создавать» PV: provisioner, параметры (тип диска, IOPS), reclaimPolicy, режим привязки, расширение |
| **CSIDriver / CSINode** | драйвер хранилища | регистрация CSI-драйвера и что он умеет на узле |
| **VolumeSnapshot(Class)** | пользователь | снимок тома (CSI, требует snapshot-controller) |

Связь: PVC → (контроллер привязки) → PV. Связь один-к-одному: `pvc.spec.volumeName` ↔ `pv.spec.claimRef`.

StorageClass стенда (проверено):

```
NAME                 PROVISIONER             RECLAIMPOLICY   VOLUMEBINDINGMODE      ALLOWVOLUMEEXPANSION
standard (default)   rancher.io/local-path   Delete          WaitForFirstConsumer   false
```

`kubectl get csidrivers` — `No resources found`: local-path-provisioner **не CSI**, это внешний provisioner, создающий PV типа `hostPath`. Большинство функций (снапшоты, расширение, лимиты ёмкости) у него нет — в проде за ними идут к CSI-драйверам.

## 2. WaitForFirstConsumer 🟡

| `volumeBindingMode` | Когда создаётся/привязывается PV |
|---|---|
| `Immediate` | сразу при создании PVC — где придётся |
| `WaitForFirstConsumer` | когда scheduler выбрал узел для первого пода, использующего PVC, — PV создаётся там, где под может работать |

Проверено: PVC без пода — `Pending` с событием `WaitForFirstConsumer: waiting for first consumer to be created before binding`. Это **не ошибка**. С `Immediate` в многозонном кластере диск создаётся в зоне A, а под с nodeSelector'ом на зону B никогда не запустится — классический «под Pending из-за тома».

## 3. Access modes и привязка к узлу 🟡🔴

| Режим | Значит | Типовые хранилища |
|---|---|---|
| `ReadWriteOnce` (RWO) | запись с **одного узла** (несколько подов на этом узле — можно) | блочные диски облака, local |
| `ReadOnlyMany` (ROX) | чтение с многих узлов | NFS, CephFS, снапшоты |
| `ReadWriteMany` (RWX) | запись с многих узлов | NFS, CephFS, EFS, Azure Files |
| `ReadWriteOncePod` (RWOP) | запись **одним подом** во всём кластере | stable с 1.29 |

Проверено (PVC `data` RWO, под `writer` на `lab-worker`):

```
same-node   Running             lab-worker      ← второй под на том же узле смонтировал RWO-том
other-node  ContainerCreating   lab-worker2
FailedMount  MountVolume.NodeAffinity check failed for volume "pvc-5ca8…" : no matching NodeSelectorTerms
/data/log: writer, same-node                     ← оба пишут в один файл
```

RWO — про **узлы**, а не про поды: два пода на одном узле прекрасно испортят файлы друг друга. Если нужно ровно один писатель — `ReadWriteOncePod` (проверено: второй под получил `1 node(s) unavailable due to PersistentVolumeClaim with ReadWriteOncePod access mode already in-use by another pod` — работает даже с local-path, проверку делает scheduler).

PV local-path несёт `nodeAffinity` на свой узел (проверено: `nodeAffinity=["lab-worker"]`, `path=/var/local-path-provisioner/pvc-…_lab-04-2_data`). Узел недоступен для планирования — под с этим PVC никуда не встанет (проверено, `lab-worker` cordon'нут):

```
0/4 nodes are available: 1 node(s) had untolerated taint(s), 1 node(s) were unschedulable, 2 node(s) didn't match PersistentVolume's node affinity.
```

После `uncordon` под вернулся на `lab-worker`. Облачные блочные диски ведут себя так же, только привязка — к **зоне** (`topology.kubernetes.io/zone`): под с диском зоны A не переедет в зону B. Отсюда правила: StatefulSet по зонам с отдельным PVC в каждой, `WaitForFirstConsumer`, и при drain — запас узлов в той же зоне.

`nodeName` в манифесте пода обходит scheduler — тогда вместо понятного `FailedScheduling` вы видите `FailedMount … NodeAffinity check failed` от kubelet (как `other-node` выше).

## 4. Ёмкость: что на самом деле ограничено 🟡

Проверено: в PVC на 100Mi записали 300 МБ — успешно:

```
314572800 bytes (300.0MB) copied, 0.154761 seconds, 1.9GB/s
300.0M	/data
```

`resources.requests.storage` у local-path и hostPath — **только запись в объекте**: каталог на диске узла без квоты. Реальное ограничение даёт драйвер: облачный диск создаётся нужного размера, CSI local-драйверы (TopoLVM, OpenEBS LVM) — LVM-том. С local-path один под может заполнить диск узла целиком, после чего kubelet начнёт выселять поды по `nodefs` (05-4), а на kind — сломаются все узлы сразу (у них общий диск хоста).

`emptyDir` без `sizeLimit` — то же самое, с `sizeLimit` — выселение пода при превышении (как ephemeral-storage, 05-1 §8).

## 5. Жизнь тома: удаление, reclaimPolicy, защита 🟡🔴

**Защита от удаления используемого PVC** — finalizer `kubernetes.io/pvc-protection` (проверено): `kubectl delete pvc data` при работающем поде оставляет PVC в `Terminating`; удалили под — PVC исчез. Аналогично `pv-protection` у PV.

**`reclaimPolicy`** — что делать с PV, когда освободился его PVC:

| Политика | PV после удаления PVC | Данные |
|---|---|---|
| `Delete` (дефолт динамических классов) | удаляется | **удалены** (проверено: PV `NotFound`, каталог на узле удалён — `0` совпадений в `/var/local-path-provisioner/`) |
| `Retain` | `Released`, остаётся с `claimRef` на старый PVC | на месте (проверено: `pvc-43cd… Retain Released lab-04-2/keep`, файл `precious` на узле) |

`Released` PV **не привяжется** к новому PVC сам: нужно вручную убрать `spec.claimRef` (тогда он станет `Available`) или создать новый PV на те же данные. Retain — для прод-БД и всего, что нельзя потерять из-за `kubectl delete`; удаление ресурса тогда ручное, включая диск в облаке.

Для существующего PV политику меняют патчем: `kubectl patch pv <pv> -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'` — первое, что делают перед любой рискованной операцией с данными (удаление namespace, переустановка чарта).

## 6. Расширение и снапшоты 🟡

Расширение PVC — правка `spec.resources.requests.storage` в большую сторону, если `allowVolumeExpansion: true` у класса и драйвер умеет. Проверено на стенде (класс без расширения):

```
Error from server (Forbidden): persistentvolumeclaims "grow" is forbidden: only dynamically provisioned pvc can be resized and the storageclass that provisions the pvc must support resize
```

С CSI: контроллер увеличивает диск, затем kubelet расширяет файловую систему (онлайн для большинства драйверов, иначе — при перезапуске пода); условие `FileSystemResizePending`. Уменьшение не поддерживается. Для StatefulSet `volumeClaimTemplates` неизменяемы — расширяют каждый PVC (02-3).

Снапшоты (`VolumeSnapshot`) — точка восстановления на уровне хранилища, создаётся за секунды; восстановление — новый PVC с `dataSource: {kind: VolumeSnapshot}`. Снапшот диска БД без её участия — crash-consistent (как выдернули питание); для согласованности — заморозка или логический бэкап (04-3). ⚠️ Снапшоты на стенде недоступны (нужен CSI-драйвер и snapshot-controller).

## 7. CSI в двух словах 🔴

CSI-драйвер — два компонента: **controller** (Deployment: создать/удалить/подключить диск через API хранилища, снапшоты, расширение) и **node** (DaemonSet: смонтировать на узле, отформатировать, bind mount в под). Kubernetes общается с ними через sidecar'ы (external-provisioner, external-attacher, external-resizer, external-snapshotter). Этапы: Provision → Attach (VolumeAttachment, для блочных) → Stage (mount на узел) → Publish (в под). Зависший `VolumeAttachment` после отказа узла — частая причина «под не может подключить диск 6 минут» (таймаут force-detach).

---

## 🔧 Лаба

### Шаг 0. Подготовка

```bash
kubectl config use-context kind-lab
kubectl create ns lab-04-2
kubectl config set-context --current --namespace=lab-04-2
kubectl get sc -o wide; kubectl get csidrivers
mk() { kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata: {name: $1}
spec:
  terminationGracePeriodSeconds: 1
  ${2:+nodeName: $2}
  containers:
  - {name: c, image: busybox:1.37, command: ["sh","-c","echo \$(hostname) >> /data/log; sleep infinity"], volumeMounts: [{name: d, mountPath: /data}]}
  volumes: [{name: d, persistentVolumeClaim: {claimName: ${3:-data}}}]
EOF
}
```

### Шаг 1. WaitForFirstConsumer

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: data}
spec:
  accessModes: [ReadWriteOnce]
  resources: {requests: {storage: 100Mi}}
EOF
sleep 5; kubectl get pvc data
kubectl get events --field-selector involvedObject.name=data -o custom-columns=REASON:.reason,MSG:.message
mk writer; kubectl wait --for=condition=Ready pod/writer
kubectl get pvc data
PV=$(kubectl get pvc data -o jsonpath='{.spec.volumeName}')
kubectl get pv $PV -o jsonpath='path={.spec.hostPath.path} nodeAffinity={.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values} reclaim={.spec.persistentVolumeReclaimPolicy}{"\n"}'
```

Проверено: `Pending` → `Bound` после старта пода; PV на `lab-worker`, путь `/var/local-path-provisioner/pvc-…_lab-04-2_data`.

### Шаг 2. RWO: тот же узел и другой узел

```bash
NODE=$(kubectl get pod writer -o jsonpath='{.spec.nodeName}')
OTHER=$(kubectl get nodes -o name | sed 's|node/||' | grep worker | grep -v "^$NODE$" | head -1)
mk same-node $NODE; mk other-node $OTHER; sleep 15
kubectl get pods -o wide
kubectl get events --field-selector involvedObject.name=other-node -o custom-columns=REASON:.reason,MSG:.message | tail -1
kubectl exec writer -- cat /data/log
```

Проверено: вывод в §3.

### Шаг 3. Ёмкость

```bash
kubectl exec writer -- sh -c 'dd if=/dev/zero of=/data/big bs=1M count=300 2>&1 | tail -1; du -sh /data'
```

Проверено: 300 МБ в PVC на 100Mi (§4). Файл удалится вместе с PVC (шаг 5).

### Шаг 4. Узел тома недоступен; RWOP

```bash
kubectl delete pod other-node same-node writer --now
kubectl cordon $NODE
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata: {name: moved}
spec:
  containers: [{name: c, image: busybox:1.37, command: ["sleep","infinity"], volumeMounts: [{name: d, mountPath: /data}]}]
  volumes: [{name: d, persistentVolumeClaim: {claimName: data}}]
EOF
sleep 6; kubectl get pod moved
kubectl get events --field-selector involvedObject.name=moved,reason=FailedScheduling -o jsonpath='{.items[-1:].message}{"\n"}'
kubectl uncordon $NODE; kubectl wait --for=condition=Ready pod/moved

kubectl apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: rwop}
spec:
  accessModes: [ReadWriteOncePod]
  resources: {requests: {storage: 10Mi}}
---
apiVersion: v1
kind: Pod
metadata: {name: rwop-1}
spec:
  containers: [{name: c, image: busybox:1.37, command: ["sleep","infinity"], volumeMounts: [{name: d, mountPath: /data}]}]
  volumes: [{name: d, persistentVolumeClaim: {claimName: rwop}}]
EOF
kubectl wait --for=condition=Ready pod/rwop-1
N2=$(kubectl get pod rwop-1 -o jsonpath='{.spec.nodeName}')
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata: {name: rwop-2}
spec:
  nodeSelector: {kubernetes.io/hostname: $N2}
  containers: [{name: c, image: busybox:1.37, command: ["sleep","infinity"], volumeMounts: [{name: d, mountPath: /data}]}]
  volumes: [{name: d, persistentVolumeClaim: {claimName: rwop}}]
EOF
sleep 8; kubectl get pod rwop-2
kubectl get events --field-selector involvedObject.name=rwop-2 -o jsonpath='{.items[-1:].message}{"\n"}'
```

Проверено: вывод в §3.

### Шаг 5. Защита, Delete и Retain

```bash
kubectl get pvc data -o jsonpath='finalizers={.metadata.finalizers}{"\n"}'
kubectl delete pvc data --wait=false; sleep 2; kubectl get pvc data           # Terminating
PV=$(kubectl get pvc data -o jsonpath='{.spec.volumeName}')
kubectl delete pod moved --now; sleep 10
kubectl get pvc data; kubectl get pv $PV                                       # оба NotFound
docker exec $NODE sh -c "ls /var/local-path-provisioner/ | grep -c $PV"       # 0 — каталог удалён

kubectl apply -f - <<'EOF'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata: {name: local-retain}
provisioner: rancher.io/local-path
reclaimPolicy: Retain
volumeBindingMode: WaitForFirstConsumer
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: keep, namespace: lab-04-2}
spec:
  storageClassName: local-retain
  accessModes: [ReadWriteOnce]
  resources: {requests: {storage: 10Mi}}
---
apiVersion: v1
kind: Pod
metadata: {name: keeper, namespace: lab-04-2}
spec:
  terminationGracePeriodSeconds: 1
  containers: [{name: c, image: busybox:1.37, command: ["sh","-c","echo precious > /data/file; sleep infinity"], volumeMounts: [{name: d, mountPath: /data}]}]
  volumes: [{name: d, persistentVolumeClaim: {claimName: keep}}]
EOF
kubectl wait --for=condition=Ready pod/keeper
PV2=$(kubectl get pvc keep -o jsonpath='{.spec.volumeName}')
NODE2=$(kubectl get pv $PV2 -o jsonpath='{.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values[0]}')
kubectl delete pod keeper --now; kubectl delete pvc keep; sleep 3
kubectl get pv $PV2
docker exec $NODE2 cat /var/local-path-provisioner/${PV2}_lab-04-2_keep/file
```

Проверено: `Retain Released lab-04-2/keep`, `precious`.

### Шаг 6. Расширение

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: grow}
spec:
  accessModes: [ReadWriteOnce]
  resources: {requests: {storage: 10Mi}}
EOF
kubectl run g --image=busybox:1.37 --overrides='{"spec":{"containers":[{"name":"g","image":"busybox:1.37","command":["sleep","infinity"],"volumeMounts":[{"name":"d","mountPath":"/data"}]}],"volumes":[{"name":"d","persistentVolumeClaim":{"claimName":"grow"}}]}}'
kubectl wait --for=condition=Ready pod/g
kubectl patch pvc grow -p '{"spec":{"resources":{"requests":{"storage":"50Mi"}}}}'
```

Проверено: `Forbidden: only dynamically provisioned pvc can be resized and the storageclass that provisions the pvc must support resize`.

### Уборка

Retain-том не удаляется сам — это и есть его смысл:

```bash
kubectl config set-context --current --namespace=default
kubectl delete ns lab-04-2
kubectl delete pv $PV2
docker exec $NODE2 rm -rf /var/local-path-provisioner/${PV2}_lab-04-2_keep
kubectl delete sc local-retain
kubectl get pv | grep lab-04-2      # пусто
```

---

## 🔥 Кейс из прода: «удалили namespace стенда — пропала база прода»

**Контекст.** Для отладки инцидента команда подключила к копии сервиса в namespace `debug` существующий PV прод-БД (статический PV на облачный диск, `reclaimPolicy: Delete`, созданный когда-то вручную): освободили его (`claimRef` убрали после удаления старого PVC в ходе миграции) и привязали новым PVC в `debug`. После отладки `kubectl delete ns debug` удалил PVC — и по `Delete` облачный диск вместе с данными.

**Разбор.**
1. PV — cluster-scoped объект, его судьбу решает `persistentVolumeReclaimPolicy`, а не namespace.
2. `Delete` у PV, к которому был привязан «временный» PVC, означало: удаление PVC = удаление диска. Защиты finalizer'ом нет — PVC больше никем не использовался.
3. Снапшотов диска не было: «на этом диске есть бэкапы БД» оказалось неправдой — бэкапы писались на тот же диск.

**Фикс.**
- Восстановление из бэкапа недельной давности в отдельном хранилище (единственного внешнего), потеря данных за неделю.
- Все PV с данными прода — `Retain` (патч существующих, отдельный StorageClass `*-retain` для новых); удаление дисков — только вручную по процедуре.
- Политика (Kyverno/VAP, 06-2): запрет PVC с `volumeName` на PV чужих namespace; запрет `Delete` для классов прода.
- Бэкапы — в другом хранилище и другом аккаунте, с регулярной проверкой восстановления (04-3).

**Что запомнить.**
- `reclaimPolicy: Delete` — удаление PVC удаляет данные. Для ценного — `Retain`.
- Перед рискованной операцией — `kubectl patch pv … Retain` и снапшот.
- Бэкап на том же диске — не бэкап.

---

## 💼 Вопросы с собеседования

### 🟢 Junior

**1. Чем PV отличается от PVC?**
PV — конкретный том в кластере (диск, каталог, NFS), cluster-scoped. PVC — заявка пода на хранилище (размер, режим доступа, класс) в namespace. Kubernetes связывает PVC с подходящим PV или создаёт PV через StorageClass.

**2. Что такое StorageClass?**
Описание того, как динамически создавать тома: provisioner (CSI-драйвер), параметры (тип диска), reclaimPolicy, режим привязки, разрешено ли расширение. Класс по умолчанию используется для PVC без `storageClassName`.

### 🟡 Middle

**3. PVC висит в Pending. Почему?**
`WaitForFirstConsumer` и ещё нет пода (это нормально); нет StorageClass по умолчанию или класс не существует; provisioner не работает или упёрся в квоту; статический PV не подходит по размеру/режиму/классу. Смотреть события PVC.

**4. Чем ReadWriteOnce отличается от ReadWriteOncePod?**
RWO — запись с одного **узла**: несколько подов на этом узле могут писать одновременно. RWOP — с одного **пода** во всём кластере; второй под не будет запланирован.

**5. Что произойдёт с данными, если удалить PVC?**
Зависит от `reclaimPolicy` PV: `Delete` — PV и сам диск/каталог удаляются; `Retain` — PV переходит в `Released` с данными, переиспользование вручную. Пока PVC используется подом, finalizer `pvc-protection` держит его в Terminating.

### 🔴 Senior

**6. Под с PVC не стартует после drain узла. Почему и что делать?**
Том привязан к узлу (local, hostPath) или к зоне (облачные блочные диски) через `nodeAffinity` PV; на других узлах/зонах под не запланируется — `didn't match PersistentVolume's node affinity`. Лечение — вернуть узел или иметь запас в той же зоне; архитектурно — реплики данных на уровне приложения, RWX-хранилище, снапшоты для переноса.

**7. Зачем WaitForFirstConsumer?**
PV создаётся после выбора узла для пода, с учётом его ограничений (зона, nodeSelector, affinity, ресурсы). С `Immediate` диск может появиться в зоне, где под запускать нельзя, и под навсегда Pending.

**8. Как устроен CSI-драйвер и где он чаще ломается?**
Controller-часть (создание, attach, snapshot, resize через API хранилища) и node-часть (DaemonSet: stage/publish монтирования). Типовые поломки: зависший VolumeAttachment после отказа узла (под ждёт force-detach ~6 минут), лимит дисков на тип инстанса (attachable volumes), node-плагин не запущен на узле (tolerations), расхождение топологии драйвера и меток узлов.

---

## ⚠️ Подводные камни

- PVC `Pending` с `WaitForFirstConsumer` до появления пода — норма.
- RWO — про узел, не про под; нужен единственный писатель — RWOP.
- local-path и hostPath не ограничивают размер — PVC «на 100Mi» займёт сколько угодно.
- PV local и облачные блочные диски привязаны к узлу/зоне — под не переедет.
- `reclaimPolicy: Delete` по умолчанию у динамических классов.
- `Released` PV не переиспользуется без ручной правки `claimRef`.
- Расширение — только при `allowVolumeExpansion` и поддержке драйвера; уменьшения нет.
- `nodeName` в поде прячет понятное сообщение scheduler'а за ошибкой монтирования.
- Снапшот диска БД без её участия — crash-consistent.

---

## Чеклист

- [ ] Объясню PV, PVC, StorageClass и режим привязки.
- [ ] Отличу RWO, RWX и RWOP и покажу RWO на одном и разных узлах.
- [ ] Найду, к какому узлу/зоне привязан PV, и объясню, почему под не переезжает.
- [ ] Выберу reclaimPolicy и переключу её у существующего PV.
- [ ] Объясню, что реально ограничивает размер тома в моём хранилище.
- [ ] Назову компоненты CSI-драйвера и типовые поломки.

---

## Задание со звёздочкой

Поставьте на стенд настоящий CSI-драйвер и сравните:

1. Установите `csi-driver-host-path` (kubernetes-csi, демонстрационный драйвер со снапшотами и расширением) вместе с snapshot-controller и CRD снапшотов (⚠️ в среде агента не проверялось).
2. Создайте PVC 10Mi, запишите 50 МБ — ограничение срабатывает?
3. Сделайте `VolumeSnapshot`, удалите данные, восстановите в новый PVC через `dataSource`.
4. Увеличьте PVC до 100Mi онлайн и посмотрите условия PVC и `df` в поде.

---

→ Следующая часть: **04-3. Данные в кластере: PostgreSQL, бэкап и восстановление** — CronJob с `pg_dump`, проверенное восстановление сквозного сценария с замером RPO/RTO, логический бэкап против снапшота, когда БД в Kubernetes оправдана.
