# 04-2. Хранилище: PV, PVC, StorageClass, CSI

> Модуль 04 «Конфигурация и данные» · часть 2 из 3 · ~1,5 ч чтения + ~1 ч лабы · Нужно: стенд 00-1 (контекст `kind-lab`, StorageClass `standard`), доступ узлов к образу `busybox:1.37`, docker на хосте для лабораторных работ 1, 3 и 4 · Опирается на: 01-2 (kubelet и монтирование), 01-3 (finalizers), 02-3 (PVC у StatefulSet)

## Где мы на карте

Эта часть объясняет, откуда у пода берётся диск, который переживает перезапуск контейнера и самого пода. До неё мы встречали PVC только снаружи: StatefulSet создавал заявки (02-3), а kubelet монтировал тома при старте пода (01-2). Здесь мы разберём весь путь: объекты хранилища, привязку заявки к тому, драйвер CSI и то, что ломается на этом пути.

Следующая часть, 04-3, строит на этом бэкапы. Снапшот тома и дамп БД имеют смысл, только когда понятно, где лежат данные и кто их удаляет. Планирование подов с учётом тома и drain узла вернутся в 05-3 и 05-5.

```
Pod ── volumes: persistentVolumeClaim ──► PVC (заявка, namespace)
                                            │ привязка (binding)
                                            ▼
StorageClass ── как создать ──────────►  PV (том, весь кластер)
  provisioner / драйвер CSI                 │ nodeAffinity
                                            ▼
                                   диск, каталог или NFS-путь
```

Схема 1. Путь от пода к данным: под ссылается на PVC, PVC привязан к PV, а PV создаёт StorageClass через драйвер. Смотрите на стрелки: каждая из них — отдельное место для поломки (§5).

---

## 1. Какую задачу решает хранилище

Файловая система контейнера исчезает вместе с контейнером, а многим нагрузкам нужны данные, которые живут дольше пода. Kubernetes делит эту задачу на три роли, чтобы разработчик не знал, какой диск стоит под его приложением.

### Тома живут не дольше пода, пока вы не выберете другое

**Том** (volume) — каталог, который kubelet монтирует в контейнеры пода. Тип тома определяет, где лежат данные и сколько они живут. Самые частые типы такие:

- **emptyDir** — пустой каталог на диске узла (или в памяти, если `medium: Memory`); живёт, пока под на узле, и переживает перезапуск контейнера.
- **hostPath** — каталог самого узла; kubelet не считает его в ephemeral-storage, а доступ к нему открывает путь на хост, поэтому им пользуются только системные поды.
- **projected, configMap, secret** — файлы из API-объектов (04-1).
- **persistentVolumeClaim** — ссылка на постоянный том, который не зависит от пода.

Первые типы подходят для кэша и временных файлов. Всё, что нельзя потерять вместе с подом, лежит на постоянном томе.

### Три объекта: PV, PVC и StorageClass

Постоянный том описывают три объекта, и у каждого своя роль и свой владелец.

- **PersistentVolume, PV** — конкретный том: облачный диск, каталог узла или NFS-путь. Объект живёт на уровне кластера, без namespace.
- **PersistentVolumeClaim, PVC** — заявка на том: размер, режим доступа и класс. Объект живёт в namespace, и под ссылается именно на него.
- **StorageClass** — рецепт создания PV: драйвер, параметры, политика удаления и режим привязки. Классом заведует администратор.

Разделение нужно, чтобы разработчик писал «10 ГиБ, быстрый диск», а администратор отвечал за то, что значит «быстрый» в этом кластере. На стенде всё это играет один класс `standard` (§4).

### Статическая и динамическая выдача

Том появляется двумя путями. При **статической выдаче** (static provisioning) администратор создаёт PV вручную, а заявка находит подходящий. При **динамической** (dynamic provisioning) заявка называет класс, и **provisioner** — программа, которая умеет создавать тома в конкретном хранилище, — создаёт PV сама. Динамический путь стал нормой: в нём никто не создаёт PV руками, а каждая заявка получает свой том.

### Том из образа

Кроме дисков, том может быть содержимым OCI-образа. Такой **image volume** (том из образа) монтирует файлы образа в под только для чтения. Он нужен для данных, которые не стоит запекать в образ приложения: моделей, справочников, плагинов.

Функция стала GA в Kubernetes 1.36 и требует рантайма с поддержкой (containerd 2.1+ или CRI-O); на стенде containerd 2.3.1. Источник тома задают полем `image`, остальное работает как у обычного тома.

```yaml
volumes:
- name: models
  image:
    reference: registry.example.com/team/models:v3
    pullPolicy: IfNotPresent
```

Фрагмент манифеста: `reference` — адрес образа, `pullPolicy` — те же значения, что у образов контейнеров (`Always` для тега `latest`, иначе `IfNotPresent`). Образ скачивается при старте пода, а сбой загрузки задерживает запуск контейнеров. Запись в такой том невозможна, а `subPath` работает с 1.33.

---

## 2. Как устроено хранилище

Под ссылается на заявку, заявку привязывает контроллер, а создание и подключение диска делает драйвер. Разберём эти шаги по порядку.

### Привязка заявки к тому

**Привязка** (binding) — связь «один PVC — один PV», которую создаёт контроллер в kube-controller-manager. Связь записана с двух сторон: в PVC в поле `spec.volumeName`, а в PV в поле `spec.claimRef`. Пока связи нет, заявка остаётся в статусе `Pending`.

При статической выдаче контроллер ищет самый маленький PV с четырьмя совпадениями: класс, ёмкость не меньше запрошенной, режимы доступа и `volumeMode`. При динамической выдаче он создаёт PV сам и тут же привязывает.

### Когда создаётся том: режим привязки

**volumeBindingMode** — поле StorageClass, которое решает, когда создавать и привязывать PV. По умолчанию стоит `Immediate`: том создаётся сразу после заявки, где придётся. Значение `WaitForFirstConsumer` откладывает привязку до выбора узла для первого пода, который использует заявку.

```
Immediate:           PVC создан ──► диск создан в зоне A ──► под нужен в зоне B: Pending навсегда
WaitForFirstConsumer: PVC создан (Pending) ──► scheduler выбрал узел ──► диск создан рядом с ним
```

Схема 2. Порядок событий: при `WaitForFirstConsumer` место тома выбирает scheduler с учётом ограничений пода, поэтому том не оказывается в зоне, где под запускать нельзя.

Поэтому `Pending` у PVC с этим режимом до появления пода — норма, а не ошибка. Поле `nodeName` в поде с такой заявкой не используют: оно обходит scheduler, и заявка так и остаётся в `Pending`. Вместо него задают `nodeSelector` по метке `kubernetes.io/hostname`.

### Режимы доступа и привязка к узлу

**Режим доступа** (access mode) — заявка на то, как том можно монтировать. Это обещание хранилища, а не защита: сам Kubernetes запись не блокирует, кроме режима с одним подом.

| Режим | Сокращение | Кто может писать | Типичное хранилище |
|---|---|---|---|
| ReadWriteOnce | RWO | один узел, любое число подов на нём | блочные диски, local |
| ReadOnlyMany | ROX | много узлов, только чтение | NFS, CephFS, снапшоты |
| ReadWriteMany | RWX | много узлов | NFS, CephFS, EFS, Azure Files |
| ReadWriteOncePod | RWOP | один под во всём кластере | CSI-диски, stable с 1.29 |

RWO ограничивает **узлы**, а не поды: два пода на одном узле спокойно портят друг другу файлы. Когда писатель должен быть ровно один, берут RWOP. Его соблюдает сам Kubernetes на двух уровнях: scheduler не назначает второй под на заявку RWOP, а kubelet не монтирует такой том второму поду на узле. Режим «много» действует только внутри одного namespace.

У PV есть поле `nodeAffinity` — условия, которым должен соответствовать узел с подом. Каталог local-path лежит на диске одного узла, облачный диск существует в одной зоне (метка `topology.kubernetes.io/zone`). Scheduler учитывает это условие, и под с таким PVC другой узел не получит.

```
PV pvc-5ca8…  nodeAffinity: kubernetes.io/hostname In [lab-worker]
        │
под с PVC ──► scheduler: подходят только узлы, где метка hostname = lab-worker
```

Схема 3. Условие PV сужает список узлов для пода до одного. Если этот узел недоступен, под ждёт его, а не переезжает.

Отсюда практика для баз данных: по одному PVC на реплику (02-3), `WaitForFirstConsumer` и запас узлов в каждой зоне.

### CSI: драйвер и путь тома

**CSI** (Container Storage Interface) — стандартный интерфейс между Kubernetes и хранилищем, по которому драйвер любого производителя подключается без правок кластера. Драйвер состоит из двух частей, и обе работают как обычные поды.

- **Controller** — Deployment, который создаёт и удаляет диски, подключает их к узлам, делает снапшоты и расширяет тома через API хранилища.
- **Node** — DaemonSet, который форматирует диск, монтирует его на узле и пробрасывает в под.

Kubernetes говорит с драйвером через контейнеры-помощники (sidecar): external-provisioner создаёт тома, external-attacher подключает, external-resizer расширяет, external-snapshotter делает снапшоты. Драйвер регистрируется объектом **CSIDriver**, а каждый узел описывает объект **CSINode** — какие драйверы работают на нём и сколько дисков можно подключить.

Диск проходит четыре этапа, и сбой на каждом выглядит по-своему.

1. **Provision** — драйвер создаёт диск в хранилище, контроллер создаёт PV.
2. **Attach** — диск подключается к узлу; для блочных дисков это объект **VolumeAttachment**.
3. **Stage** — драйвер форматирует диск и монтирует его в общий каталог узла.
4. **Publish** — каталог монтируется (bind mount) в контейнер пода.

Для ReadWriteMany-хранилищ вроде NFS этапа Attach нет: том уже доступен по сети.

### local-path: не CSI

На стенде работает **local-path-provisioner** от Rancher. Это внешний provisioner без CSI: он создаёт PV типа `hostPath` с `nodeAffinity` и каталог `/var/local-path-provisioner/<pv>_<namespace>_<pvc>` на выбранном узле. Объектов CSIDriver у него нет, а снапшотов, расширения и квот — тоже (лабораторная работа 1 показывает это командами).

---

## 3. Как управлять хранилищем

Управление сводится к пяти решениям. Класс заявки, судьба тома после неё, расширение, смена параметров и копия — каждое получает свой подраздел.

### StorageClass и класс по умолчанию

Заявка выбирает класс полем `storageClassName`. Если поле не задано, берётся **класс по умолчанию** — тот, у которого есть аннотация `storageclass.kubernetes.io/is-default-class: "true"`. Если таких несколько, побеждает созданный последним, поэтому держат один. Значение `storageClassName: ""` значит «без класса»: тогда заявка ищет только статические PV без класса.

Ключевые поля класса:

- `provisioner` — какой драйвер создаёт тома.
- `parameters` — параметры драйвера (тип диска, файловая система); не больше 512 штук и 256 КиБ.
- `reclaimPolicy` — что делать с PV после заявки; по умолчанию `Delete`.
- `volumeBindingMode` — `Immediate` (по умолчанию) или `WaitForFirstConsumer`.
- `allowVolumeExpansion` — можно ли увеличивать заявки этого класса.
- `mountOptions` — опции монтирования; драйвер их не проверяет, ошибка проявится при монтировании.

### Освобождение тома и защита от удаления

**reclaimPolicy** — поле PV, которое решает, что станет с PV и данными, когда заявку удалили. Динамические PV наследуют его от класса.

| Политика | PV после удаления PVC | Данные |
|---|---|---|
| Delete | удаляется | удаляются вместе с диском |
| Retain | остаётся в статусе Released | остаются на месте |

PV в статусе **Released** сам не привяжется к новой заявке, потому что его `claimRef` ещё указывает на старую. Администратор очищает `claimRef`, и PV становится `Available`, либо создаёт новый PV на те же данные. Политику существующего PV меняют патчем, и это первое действие перед любой рискованной операцией с данными: удалением namespace, переустановкой чарта.

```bash
kubectl patch pv <имя-pv> -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'
```

Команда переключает политику на `Retain`, и дальше удаление PVC диск не тронет. Удалять диск придётся вручную, зато опечатка в `kubectl delete` не уничтожит БД.

Использование тома защищают два **finalizer** — метки в `metadata.finalizers`, которые не дают API удалить объект, пока контроллер их не снимет (01-3). Финалайзер `kubernetes.io/pvc-protection` держит PVC, пока его монтирует под, а `kubernetes.io/pv-protection` держит PV, пока он привязан. Удаление в таком случае оставляет объект в состоянии `Terminating` и завершается само, когда под удалён.

CSI-тома получают третий финалайзер, `external-provisioner.volume.kubernetes.io/finalizer` (с 1.31). Он гарантирует порядок: при `Delete` объект PV исчезает только после того, как удалён диск в хранилище, в каком бы порядке ни удаляли PV и PVC. Гарантия стала GA в 1.33.

### Расширение тома и восстановление после сбоя

Расширение — это правка `spec.resources.requests.storage` заявки в большую сторону. Оно работает, когда у класса стоит `allowVolumeExpansion: true`, а драйвер умеет менять размер. Контроллер расширяет диск, затем kubelet расширяет файловую систему (ext3, ext4, XFS), для большинства драйверов — без перезапуска пода. Пока файловая система не выросла, у PVC есть условие `FileSystemResizePending`. Уменьшить том нельзя.

Раньше заявка застревала, если расширение не удалось: хранилище отказало или в пуле не хватило места, а контроллер повторял попытки бесконечно. С 1.34 (GA) работает **восстановление после неудачного расширения** (recovery from volume expansion failure). После сбоя заявке можно задать размер меньше прежнего запроса, но всё ещё больше текущей ёмкости `status.capacity`, и контроллер попробует расширить том до него.

Прогресс виден в событиях и в поле `status.allocatedResourceStatuses`. Значения поля называют этап: `ControllerResizeInProgress`, `ControllerResizeInfeasible` (хранилище отказало), `NodeResizePending`, `NodeResizeInProgress`, `NodeResizeInfeasible`. Ошибки дублируются условиями PVC `ControllerResizeError` и `NodeResizeError`.

Если нужен размер меньше этого, остаётся ручная процедура администратора:

1. Поставить у PV политику `Retain`.
2. Удалить PVC.
3. Очистить у PV `claimRef`, чтобы он стал `Available`.
4. Создать PVC с меньшим размером и полем `volumeName` на этот PV.
5. Вернуть PV прежнюю политику.

Для StatefulSet шаблон `volumeClaimTemplates` неизменяем, поэтому расширяют каждый PVC отдельно (02-3).

### VolumeAttributesClass: параметры тома без пересоздания

Размер — не единственное, что нужно менять на живом томе: часто требуется поднять IOPS или пропускную способность. **VolumeAttributesClass, VAC** — объект `storage.k8s.io/v1` (GA с 1.34, в 1.36 его нельзя выключить), который хранит именованный набор таких параметров для драйвера. StorageClass задаёт параметры при создании диска и потом не меняется, а VAC применяется и при создании, и к уже работающему тому.

```yaml
apiVersion: storage.k8s.io/v1
kind: VolumeAttributesClass
metadata: {name: gold}
driverName: csi.example.com
parameters: {iops: "6000", throughput: "200Mi"}
```

Манифест: `driverName` указывает драйвер, `parameters` — его ключи, имена зависят от драйвера (здесь вымышленные). Чтобы применить класс, в PVC задают `spec.volumeAttributesClassName: gold`; смена имени на другой класс изменяет том. Параметры у существующего класса неизменяемы. Работает только с CSI-драйвером, который реализует вызов ModifyVolume; local-path не подходит.

Результат смотрят в статусе заявки. Поле `status.currentVolumeAttributesClassName` называет класс, который уже применён к тому. Поле `status.modifyVolumeStatus` появляется на время смены: в нём целевой класс и состояние `Pending`, `InProgress` или `Infeasible` (драйвер отверг параметры). Ход смены дублируют условия PVC `ModifyingVolume` и `ModifyVolumeError`.

### Снапшоты и клонирование

**Снапшот** (VolumeSnapshot) — копия тома на уровне хранилища: создаётся за секунды и служит точкой восстановления. Три объекта (`VolumeSnapshot`, `VolumeSnapshotContent`, `VolumeSnapshotClass`) повторяют схему PVC, PV и StorageClass. Они не входят в ядро API: это CRD группы `snapshot.storage.k8s.io/v1`, которые вместе с контроллером **snapshot-controller** ставит дистрибутив, а драйвер добавляет sidecar csi-snapshotter.

Восстановление — это новый PVC с полем `dataSource` (или `dataSourceRef`, GA с 1.33), которое указывает на снапшот. Снапшот одного диска БД без её участия получается crash-consistent: как после выдернутого питания. Для согласованности БД замораживают на время снимка или делают логический дамп (04-3). С 1.36 есть и **VolumeGroupSnapshot** (GA) — согласованный снимок нескольких PVC сразу.

На стенде снапшоты недоступны: нужен CSI-драйвер с поддержкой снимков, а local-path её не даёт.

---

## 4. Как увидеть состояние хранилища

Состояние читают сверху вниз по цепочке из схемы 1: класс, заявка, том, затем драйвер и узел.

### Классы и драйверы

Класс виден командой `kubectl get sc`; колонка `PROVISIONER` называет драйвер, а `ALLOWVOLUMEEXPANSION` показывает, можно ли расширять. Драйверы CSI перечисляют `kubectl get csidrivers`, а возможности узла — `kubectl get csinode`. Объекты `VolumeAttachment` (`kubectl get volumeattachments`) показывают, какой диск к какому узлу подключён.

### Заявки и тома

`kubectl get pvc` показывает статус и имя тома, а `kubectl get pv` — политику, статус и заявку, к которой том привязан. Подробности и события заявки даёт `kubectl describe pvc <имя>`: причину `Pending` почти всегда пишет туда provisioner. У PV смотрят `nodeAffinity` и источник (`hostPath`, `csi`) в `kubectl get pv <имя> -o yaml`.

Статусы PV такие: `Available` — свободен, `Bound` — привязан, `Released` — заявка удалена, но данные не освобождены, `Failed` — автоматическое освобождение не удалось. Время последней смены статуса PV хранит поле `status.lastPhaseTransitionTime` (GA с 1.31). У PVC в 1.36 есть и условие `Unused`: его время показывает, с какого момента заявку не использует ни один под. Условие включает функция `PersistentVolumeClaimUnusedSinceTime`, которая в 1.36 в стадии alpha и выключена, а в 1.37 включена по умолчанию.

### Внутри пода

Под видит том как обычный каталог, и размер даёт `df`. Если том смонтирован с настоящей квотой, `df` покажет размер тома. Если нет (как на local-path), покажет размер всего диска узла: это быстрый способ понять, ограничен ли том.

### Какую команду выбрать

Пять вопросов покрывают почти все разборы, и у каждого своя команда.

- Класс по умолчанию — `kubectl get sc`, пометка `(default)` в имени.
- Причина `Pending` у заявки — `kubectl describe pvc`, события внизу.
- Узел, к которому привязан PV — `kubectl get pv -o yaml`, поле `nodeAffinity`.
- Подключённые диски — `kubectl get volumeattachments`, колонки `ATTACHED` и `NODE`.
- Лимит дисков узла — `kubectl get csinode -o yaml`, поле `allocatable.count`.

---

## 5. Что ломается и как найти причину

Поломки хранилища делятся по этапам пути: заявка не получила том, том не смонтировался, под не может переехать, данные исчезли или не выросли.

### PVC в состоянии Pending

Заявка в `Pending` бывает по одной из пяти причин, и событие в `describe pvc` обычно называет нужную.

- Нет пода, а режим `WaitForFirstConsumer`: это нормально.
- Нет класса по умолчанию или класса, который указан в заявке: `storageclass … not found`.
- Provisioner не работает, лежит или упёрся в квоту хранилища.
- Статический PV не подходит по классу, размеру, режиму или `volumeMode`.
- Режим `Immediate` и ограничения пода не совпали с зоной диска.

Для пода это видно как `pod has unbound immediate PersistentVolumeClaims`. Чинят причину в заявке или в провайдере, а не в поде.

### Том не монтируется и узел недоступен

Если под долго стоит в `ContainerCreating`, смотрят события пода: `FailedMount` и `FailedAttachVolume` показывают, на каком этапе (§2) остановился том. Три частые причины:

- **Multi-Attach.** Диск RWO ещё подключён к другому узлу. После отказа узла под выселяется через 300 с, но удалить его некому, и VolumeAttachment остаётся. Ещё через 6 минут неудачного удаления пода контроллер отключает диск принудительно, если узел всё ещё нездоров. Быстрее работает taint `node.kubernetes.io/out-of-service`, который администратор ставит, когда убедился, что узел выключен.
- **Не совпал `nodeAffinity`.** При запуске через `nodeName` событие приходит от kubelet: `MountVolume.NodeAffinity check failed … no matching NodeSelectorTerms`. Без `nodeName` то же сообщает scheduler (`FailedScheduling`).
- **Лимит дисков на узле.** Один узел принимает ограниченное число дисков, и CSI-драйвер сообщает этот лимит в CSINode по типу машины. Под сверх лимита остаётся `Pending`.

Принудительное отключение нарушает спецификацию CSI: если узел на деле ещё работает и пишет в диск, данные могут повредиться. Поэтому его можно выключить флагом `--disable-force-detach-on-timeout` у kube-controller-manager, и тогда остаётся только ручной taint. Taint ставят с эффектом `NoExecute` или `NoSchedule`: поды узла удаляются принудительно, а диски отключаются сразу. Снимает taint тоже администратор, когда поды переехали, а узел починен.

Под с local-путём или зональным диском не переезжает на другой узел и ждёт возвращения старого. Ответ scheduler в такой момент: `0/4 nodes are available: … didn't match PersistentVolume's node affinity`. Узел возвращают или готовят архитектурное решение: реплики данных на уровне приложения, запас узлов в той же зоне, снапшоты для переноса.

### Данные пропали, не выросли или заняли весь диск

Данные пропадают в трёх случаях:

1. Удалён PVC при `Delete`: PV и диск исчезли. Спасает только копия, поэтому ценные тома держат на `Retain`.
2. Удалён namespace: он удаляет все PVC, а `Delete` удаляет вслед за ними диски.
3. `Retain`-том остался в статусе `Released`, и его случайно удалили вручную или забыли привязать.

Расширение не растёт, если у класса нет `allowVolumeExpansion` (API отвечает `Forbidden`), драйвер не умеет менять размер или файловая система ждёт монтирования в режиме записи. Состояние показывают условия PVC и `allocatedResourceStatuses` (§3).

Поле `resources.requests.storage` у local-path и hostPath — только запись в объекте, а реального лимита нет. Один под способен занять весь диск узла. Тогда kubelet начнёт выселять поды по давлению диска (05-5), а на kind сломаются все узлы, потому что диск хоста у них общий. Настоящий размер дают облачные диски и CSI-драйверы с LVM-томами (TopoLVM, OpenEBS LVM). У emptyDir без `sizeLimit` та же проблема, а с `sizeLimit` под при превышении выселяется (05-2).

### SELinux на узлах

Если на узлах включён **SELinux** (подсистема ядра Linux, которая помечает файлы метками безопасности), поду нужен доступ к файлам тома с его меткой. По старой схеме runtime рекурсивно меняет метку у каждого файла, и на больших томах это занимает минуты. По новой схеме kubelet монтирует том с опцией `-o context=<метка>`, и метка применяется мгновенно. Новая схема работает для PVC, когда у пода задан `seLinuxOptions`, а CSI-драйвер объявил `seLinuxMount: true` в своём CSIDriver.

У новой схемы есть цена: все поды на узле, которые одновременно используют том, обязаны иметь одну метку. Под с другой меткой остаётся в `ContainerCreating` с ошибкой `conflicting SELinux labels of volume`. Так бывает, например, у привилегированного и обычного пода с общим томом.

Стадии зависят от томов. В 1.36 новая схема по умолчанию работает только для томов RWOP (`SELinuxMountReadWriteOncePod`, GA), где конфликт невозможен. Для всех томов её включает `SELinuxMount`, который в 1.36 выключен, а в 1.37 становится GA и включён по умолчанию. Обход — поле пода `spec.securityContext.seLinuxChangePolicy: Recursive` (GA в 1.36), которое возвращает старое поведение.

До обновления до 1.37 включают в kube-controller-manager контроллер `selinux-warning-controller` (флаг `--controllers=*,selinux-warning-controller`) и смотрят метрику `selinux_warning_controller_selinux_volume_conflict`. Узлы на Ubuntu и Manjaro, где SELinux не используется, это не затрагивает, а кластеры на дистрибутивах семейства RHEL затрагивает.

---

## 6. Пределы и значения по умолчанию

Ниже собраны значения из документации Kubernetes для версии стенда 1.36 и результаты прогона на стенде.

### Классы и политики

- `volumeBindingMode` — `Immediate`, если не указано другое; у `standard` на стенде `WaitForFirstConsumer`.
- `reclaimPolicy` — `Delete`; у `standard` на стенде он тоже `Delete`.
- `allowVolumeExpansion` — `false`; у `standard` на стенде `false`.
- Параметры класса — не больше 512 штук и 256 КиБ; те же пределы у VolumeAttributesClass.
- Несколько классов по умолчанию: выбирается созданный последним.

### Размеры и ёмкость

- `requests.storage` у local-path не ограничивает размер: на стенде в PVC на 100 МиБ записали 300 МБ без ошибки.
- Расширение есть, уменьшения нет.
- Лимиты дисков на узел сообщает CSI-драйвер в CSINode, с 1.36 (GA) драйвер может обновлять их на ходу. Старые значения scheduler по умолчанию из документации — 39 для Amazon EBS, 16 для Google PD и Azure Disk; реальные зависят от типа машины, например до 127 на GCE и до 64 на Azure.
- Принудительное отключение диска — через 6 минут неудачного удаления пода на нездоровом узле; выключается флагом `--disable-force-detach-on-timeout`.
- Выселение подов с недоступного узла — через 300 с, узел считается недоступным через 50 с без ответа.

### Что устарело и что изменилось

- Тип тома `gitRepo` отключён (02-1), клонируйте репозиторий в init-контейнере.
- Встроенные драйверы `cephfs` и `rbd` удалены в 1.31, код облачных дисков вроде `gcePersistentDisk` удалён раньше (1.28), а старые поля обслуживает CSI-драйвер облака. Миграция Portworx на CSI стала GA в 1.33, и в 1.36 её переключатель убран.
- FlexVolume устарел с 1.23, а kubeadm в 1.36 убрал поддержку его каталога: новые драйверы FlexVolume не ставят, берут CSI.
- Флаг монтирования `readOnly: true` не распространяется на вложенные точки монтирования; поле `recursiveReadOnly: Enabled` (GA 1.33) закрывает и их.
- RWOP документация называет поддерживаемым только для CSI-томов: так обещан полный путь через драйвер. Но проверки в scheduler и kubelet смотрят на режим в заявке и PV, а не на драйвер, поэтому на стенде с local-path запрет тоже срабатывает (работа 2).

---

## Лабораторные работы

Работы идут на стенде 00-1 в namespace `lab-04-2`. Манифесты подаются через stdin, поэтому каталог `~/lab/k8s/04-2/` создавать не нужно. Конфигурацию хоста и узлов работы не меняют, но занимают место на диске узла (работы 1 и 4), закрывают узел для планирования (работа 2) и останавливают узел kind (работа 3). Поэтому у этих работ есть блок «Риски». Лабораторные 1 и 4 заглядывают на диск узла командой `docker exec`, поэтому docker на хосте должен быть доступен.

Узлы тянут образ `busybox:1.37` из Docker Hub. Если он недоступен, положите образ в реестр стенда (02-1) и замените имя на `localhost:5001/busybox:1.37`.

Кластер готовят один раз: выбирают контекст стенда и создают namespace для всех работ.

```bash
kubectl config use-context kind-lab
kubectl create ns lab-04-2
kubectl config set-context --current --namespace=lab-04-2
```

Первая команда выбирает кластер стенда, вторая создаёт namespace, а третья делает его текущим для kubectl. Namespace удаляется в уборке последней, четвёртой работы.

### Лабораторная работа 1. Класс, WaitForFirstConsumer и ёмкость

**Риски.** Работа пишет 300 МБ в каталог local-path на узле kind.

- **Что меняется.** Файл ложится в `/var/local-path-provisioner/` внутри контейнера узла, а физически — на диск хоста, в хранилище docker.
- **Надолго ли.** До уборки: удаление заявки по политике `Delete` удаляет каталог.
- **Безопасность.** Внешних последствий нет, конфигурация узла не меняется.
- **Влияние.** Узлы kind делят диск хоста. Если на нём меньше 1–2 ГБ свободно, kubelet может начать выселять поды по давлению диска на всех узлах. Проверьте место заранее: `df -h /var/lib/docker`.
- **Откат.** Уборка в конце работы; если она прервалась — `kubectl delete pvc data -n lab-04-2`.

**Цель.** Увидеть, что local-path не CSI, как PVC ждёт первый под и что размер заявки на этом хранилище ничего не ограничивает.

**Что понадобится.** Стенд 00-1, namespace `lab-04-2`, образ `busybox:1.37`, docker на хосте.

**Схема опыта.**

```
PVC data (100Mi) ──► Pending (нет пода)
        │ создаём под writer
        ▼
Pod writer ──► scheduler выбирает узел ──► provisioner создаёт каталог ──► PVC Bound
        │
        └─► dd 300 МБ в том на 100Mi: ошибки нет
```

Схема 4. Привязка наступает после выбора узла; ёмкость проверяется записью большего объёма, чем запрошено.

#### Шаг 1. Посмотреть класс и драйверы

Команды выводят StorageClass стенда и список CSI-драйверов.

```bash
kubectl get sc
kubectl get csidrivers
```

| Часть команды | Значение |
|---|---|
| `get sc` | список StorageClass |
| `get csidrivers` | список зарегистрированных CSI-драйверов |

Результат (колонка `AGE` опущена, отступы между колонками сжаты):

```
NAME                PROVISIONER            RECLAIMPOLICY  VOLUMEBINDINGMODE     ALLOWVOLUMEEXPANSION
standard (default)  rancher.io/local-path  Delete         WaitForFirstConsumer  false
No resources found
```

Разбор:

1. `standard (default)` — единственный класс, он же класс по умолчанию.
2. `rancher.io/local-path` — внешний provisioner, не CSI.
3. `Delete` и `WaitForFirstConsumer` — политика удаления и режим привязки.
4. `ALLOWVOLUMEEXPANSION false` — расширение запрещено (проверим в работе 4).
5. `No resources found` — CSI-драйверов в кластере нет, значит снапшотов и расширения тоже нет.

#### Шаг 2. Создать заявку без пода

Команды создают PVC на 100 МиБ и показывают его статус и события.

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: data}
spec:
  accessModes: [ReadWriteOnce]
  resources: {requests: {storage: 100Mi}}
EOF
sleep 5
kubectl get pvc data -o jsonpath='{.status.phase}{"\n"}'
kubectl get events --field-selector involvedObject.name=data \
  -o custom-columns=REASON:.reason,MSG:.message
```

| Часть команды | Значение |
|---|---|
| `accessModes: [ReadWriteOnce]` | том для записи с одного узла |
| `requests: {storage: 100Mi}` | запрос ёмкости 100 МиБ |
| `-o jsonpath='{.status.phase}…'` | вывести только фазу заявки |
| `--field-selector involvedObject.name=data` | события, относящиеся к PVC `data` |
| `-o custom-columns=…` | показать причину и текст события |

Результат:

```
Pending
REASON                MSG
WaitForFirstConsumer  waiting for first consumer to be created before binding
```

Разбор:

1. `Pending` — тома ещё нет.
2. Причина `WaitForFirstConsumer` — событие объясняет, что заявка ждёт под.
3. Это не ошибка: provisioner не работает, пока scheduler не выбрал узел.

#### Шаг 3. Запустить под и найти каталог тома

Команды создают под, который пишет имя хоста в файл на томе, и читают данные о PV.

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata: {name: writer}
spec:
  terminationGracePeriodSeconds: 1
  containers:
  - name: c
    image: busybox:1.37
    command: ["sh", "-c", "echo $(hostname) >> /data/log; sleep infinity"]
    volumeMounts: [{name: d, mountPath: /data}]
  volumes:
  - {name: d, persistentVolumeClaim: {claimName: data}}
EOF
kubectl wait --for=condition=Ready pod/writer
kubectl get pvc data -o jsonpath='{.status.phase}{"\n"}'
PV=$(kubectl get pvc data -o jsonpath='{.spec.volumeName}')
T='path={.spec.hostPath.path} '
T+='nodeAffinity={.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values} '
T+='reclaim={.spec.persistentVolumeReclaimPolicy}{"\n"}'
kubectl get pv $PV -o jsonpath="$T"
```

| Часть команды | Значение |
|---|---|
| `terminationGracePeriodSeconds: 1` | быстрое удаление пода в уборке |
| `persistentVolumeClaim: {claimName: data}` | подключить том по заявке |
| `PV=$(… .spec.volumeName)` | имя PV, который привязали к заявке |
| `.spec.hostPath.path` | каталог тома на диске узла |
| `nodeSelectorTerms[0]…values` | узел, к которому привязан PV |

Результат (суффикс имени PV у вас будет другим):

```
Bound
path=/var/local-path-provisioner/pvc-…_lab-04-2_data nodeAffinity=["lab-worker"] reclaim=Delete
```

Разбор:

1. `Bound` — после старта пода заявка получила том.
2. `path` — каталог на диске узла: имя состоит из имени PV, namespace и имени PVC.
3. `nodeAffinity=["lab-worker"]` — PV привязан к узлу, где запущен под (у вас может быть другой).
4. `reclaim=Delete` — политика унаследована от класса `standard`.

#### Шаг 4. Записать больше, чем запросили

Команда пишет в том 300 МБ и показывает размер каталога.

```bash
kubectl exec writer -- sh -c \
  'dd if=/dev/zero of=/data/big bs=1M count=300 2>&1 | tail -1; du -sh /data'
```

| Часть команды | Значение |
|---|---|
| `dd … bs=1M count=300` | записать 300 блоков по 1 МиБ |
| `2>&1 \| tail -1` | оставить итоговую строку `dd` |
| `du -sh /data` | размер каталога тома |

Результат:

```
314572800 bytes (300.0MB) copied, 0.154761 seconds, 1.9GB/s
300.0M	/data
```

Разбор:

1. Запись успешна, хотя запрошено 100 МиБ: заявка ничего не ограничивает.
2. Скорость 1,9 ГБ/с получилась из-за кэша страниц ядра, её не нужно сравнивать с диском.
3. Файл займёт место на диске узла (и хоста) до уборки.

**Итог.**

| Что узнали | Где видно |
|---|---|
| local-path — не CSI, драйверов в кластере нет | шаг 1 |
| Заявка ждёт первый под, это не ошибка | шаг 2, событие |
| PV привязан к узлу и лежит каталогом на его диске | шаг 3 |
| Размер в заявке не ограничивает запись | шаг 4 |

**Уборка.**

```bash
kubectl delete pod writer --now
kubectl delete pvc data
```

Первая команда останавливает под, вторая удаляет заявку, а вместе с ней по политике `Delete` — том и 300 МБ файла.

**Вопросы для самопроверки.**

1. Почему PVC в `Pending` на шаге 2 не нужно чинить?
2. Какой каталог создаёт local-path и на каком узле?
3. Что произойдёт на стенде, если под запишет в «маленький» PVC больше, чем свободно на диске?

<details>
<summary>Ответы</summary>

1. Класс `standard` работает в режиме `WaitForFirstConsumer`: том создаётся после выбора узла для первого пода.
2. Каталог `/var/local-path-provisioner/<pv>_<namespace>_<pvc>` на узле, где scheduler разместил под.
3. Диск узла, а на kind и диск хоста, заполнится; kubelet начнёт выселять поды по давлению диска, и пострадают все соседи (05-5).

</details>

### Лабораторная работа 2. RWO, RWOP и недоступный для планирования узел

**Цель.** Проверить, что RWO ограничивает узлы, а не поды, что RWOP запрещает второй под, и что PV с `nodeAffinity` не пускает под на другой узел.

**Риски.** Работа выполняет `kubectl cordon` на одном рабочем узле. Узел остаётся рабочим, но новые поды на него не планируются, пока не выполнен `uncordon`. Ничего не удаляется, поды стенда не выселяются. Откат: `kubectl uncordon <узел>` (он же есть в шаге 4 и в уборке).

**Что понадобится.** Стенд 00-1, namespace `lab-04-2`, образ `busybox:1.37`.

**Схема опыта.**

```
lab-worker:   writer ─┐
              same-node ┴─► PVC data (RWO) ── оба пишут в один файл
lab-worker2:  other-node ───► FailedMount: nodeAffinity PV указывает на lab-worker

PVC rwop (RWOP): rwop-1 Running, rwop-2 на том же узле — Pending
cordon lab-worker: moved не планируется, пока узел закрыт
```

Схема 5. Три опыта: RWO на одном и другом узле, RWOP и закрытый для планирования узел.

#### Шаг 1. Создать заявку и первого писателя

Определяем функцию `mk`, которая создаёт под с томом, и запускаем `writer`.

```bash
mk() { kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata: {name: $1}
spec:
  terminationGracePeriodSeconds: 1
  ${2:+nodeName: $2}
  containers:
  - name: c
    image: busybox:1.37
    command: ["sh", "-c", "echo \$(hostname) >> /data/log; sleep infinity"]
    volumeMounts: [{name: d, mountPath: /data}]
  volumes:
  - {name: d, persistentVolumeClaim: {claimName: ${3:-data}}}
EOF
}
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: data}
spec:
  accessModes: [ReadWriteOnce]
  resources: {requests: {storage: 100Mi}}
EOF
mk writer
kubectl wait --for=condition=Ready pod/writer
```

| Часть команды | Значение |
|---|---|
| `mk() { … }` | функция: имя пода, необязательный узел, необязательная заявка |
| `${2:+nodeName: $2}` | добавить `nodeName`, только если передан второй аргумент |
| `${3:-data}` | заявка по умолчанию `data` |
| `\$(hostname)` | подстановка выполнится в контейнере, а не в вашем shell |

Результат: под `writer` запущен и создал файл `/data/log`. Разбор: заявка привязалась к PV на узле, где стартовал `writer`; этот узел мы используем в шаге 2.

#### Шаг 2. Второй под на том же узле и на другом

Команды определяют узел `writer`, выбирают другой рабочий узел и запускают два пода с `nodeName`.

```bash
NODE=$(kubectl get pod writer -o jsonpath='{.spec.nodeName}')
OTHER=$(kubectl get nodes -o name | sed 's|node/||' | grep worker | grep -v "^$NODE$" | head -1)
mk same-node $NODE
mk other-node $OTHER
sleep 15
kubectl get pods -o wide --no-headers | awk '{print $1, $3, $7}'
kubectl get events --field-selector involvedObject.name=other-node \
  -o custom-columns=REASON:.reason,MSG:.message | tail -1
kubectl exec writer -- cat /data/log
```

| Часть команды | Значение |
|---|---|
| `$NODE`, `$OTHER` | узел тома и любой другой рабочий узел |
| `mk same-node $NODE` | под сразу на узле тома, минуя scheduler |
| `awk '{print $1, $3, $7}'` | вывести имя, статус и узел из `-o wide` |
| `tail -1` | оставить последнее событие |
| `cat /data/log` | файл, в который пишут все поды |

Результат (узлы у вас могут отличаться):

```
writer Running lab-worker
same-node Running lab-worker
other-node ContainerCreating lab-worker2
FailedMount  MountVolume.NodeAffinity check failed for volume "pvc-5ca8…" :
  no matching NodeSelectorTerms
writer
same-node
```

Разбор:

1. `same-node` работает: RWO разрешает много подов на одном узле.
2. `other-node` застрял в `ContainerCreating` на другом узле.
3. `FailedMount … NodeAffinity check failed` — kubelet узла `lab-worker2` увидел, что PV привязан к другому узлу.
4. Сообщение пришло от kubelet, а не от scheduler, потому что `nodeName` обходит планировщик.
5. В файле две строки: оба пода на одном узле пишут в один файл без защиты.

#### Шаг 3. Заявка ReadWriteOncePod

Команды создают заявку RWOP и два пода, второй из которых нацелен на тот же узел.

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: rwop}
spec:
  accessModes: [ReadWriteOncePod]
  resources: {requests: {storage: 10Mi}}
EOF
mk rwop-1 "" rwop
kubectl wait --for=condition=Ready pod/rwop-1
N2=$(kubectl get pod rwop-1 -o jsonpath='{.spec.nodeName}')
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata: {name: rwop-2}
spec:
  nodeSelector: {kubernetes.io/hostname: $N2}
  containers:
  - name: c
    image: busybox:1.37
    command: ["sleep", "infinity"]
    volumeMounts: [{name: d, mountPath: /data}]
  volumes:
  - {name: d, persistentVolumeClaim: {claimName: rwop}}
EOF
sleep 8
kubectl get pod rwop-2 --no-headers | awk '{print $1, $3}'
kubectl get events --field-selector involvedObject.name=rwop-2 \
  -o jsonpath='{.items[-1:].message}{"\n"}'
```

| Часть команды | Значение |
|---|---|
| `ReadWriteOncePod` | один под во всём кластере |
| `mk rwop-1 "" rwop` | под без `nodeName` с заявкой `rwop` |
| `nodeSelector … hostname: $N2` | второй под строго на узле первого |
| `.items[-1:].message` | текст последнего события |

Результат (сообщение приведено фрагментом):

```
rwop-2 Pending
… 1 node(s) unavailable due to PersistentVolumeClaim with ReadWriteOncePod
  access mode already in-use by another pod
```

Разбор:

1. `Pending` — scheduler не нашёл узла: том занят другим подом.
2. Отказ дал планировщик по режиму заявки, а не файловая система: на том же узле RWO пустил бы второй под (шаг 2).
3. Проверка сработала даже на local-path.

#### Шаг 4. Узел тома закрыт для планирования

Команды удаляют поды, закрывают узел и пытаются запустить под с той же заявкой, затем открывают узел.

```bash
kubectl delete pod other-node same-node writer rwop-2 rwop-1 --now
kubectl cordon $NODE
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata: {name: moved}
spec:
  containers:
  - name: c
    image: busybox:1.37
    command: ["sleep", "infinity"]
    volumeMounts: [{name: d, mountPath: /data}]
  volumes:
  - {name: d, persistentVolumeClaim: {claimName: data}}
EOF
sleep 6
kubectl get pod moved --no-headers | awk '{print $1, $3}'
kubectl get events --field-selector involvedObject.name=moved,reason=FailedScheduling \
  -o jsonpath='{.items[-1:].message}{"\n"}'
kubectl uncordon $NODE
kubectl wait --for=condition=Ready pod/moved
kubectl get pod moved -o jsonpath='{.spec.nodeName}{"\n"}'
```

| Часть команды | Значение |
|---|---|
| `kubectl cordon $NODE` | пометить узел недоступным для новых подов |
| `reason=FailedScheduling` | события scheduler |
| `kubectl uncordon $NODE` | вернуть узлу планирование |
| `jsonpath='{.spec.nodeName}…'` | узел, где оказался `moved` |

Результат:

```
moved Pending
0/4 nodes are available: 1 node(s) had untolerated taint(s), 1 node(s) were unschedulable,
  2 node(s) didn't match PersistentVolume's node affinity.
lab-worker
```

Разбор:

1. `Pending` — подходящего узла нет.
2. `1 node(s) had untolerated taint(s)` — control-plane с taint.
3. `1 node(s) were unschedulable` — закрытый командой cordon узел тома: он единственный подходит по тому, но закрыт.
4. `2 node(s) didn't match PersistentVolume's node affinity` — два других рабочих узла.
5. После `uncordon` под занял `lab-worker`: том вернул его туда же.

**Итог.**

| Что узнали | Где видно |
|---|---|
| RWO ограничивает узлы, поды на одном узле пишут вместе | шаг 2, файл `log` |
| `nodeName` прячет ответ scheduler за ошибкой kubelet | шаг 2, `FailedMount` |
| RWOP запрещает второй под, даже на том же узле | шаг 3 |
| Под с local-томом ждёт свой узел, а не переезжает | шаг 4 |

**Уборка.**

```bash
kubectl uncordon $NODE
kubectl delete pod moved --now
kubectl delete pvc data rwop
```

Первая команда безопасно повторяет открытие узла, остальные удаляют под и заявки (вместе с ними по `Delete` — тома).

**Вопросы для самопроверки.**

1. Почему `same-node` запустился при RWO?
2. Чем сообщение `FailedMount … NodeAffinity` отличается от `FailedScheduling`?
3. Что произойдёт с `moved`, если `lab-worker` сломан и не вернётся?

<details>
<summary>Ответ</summary>

1. RWO ограничивает число узлов, а не подов: оба пода на одном узле.
2. `FailedMount` приходит от kubelet, когда под уже назначен на узел (при `nodeName`), а `FailedScheduling` — от scheduler до назначения.
3. Он останется `Pending`: PV привязан к недоступному узлу. Спасут копия данных, снапшот и новый PVC.

</details>

### Лабораторная работа 3. Узел тома остановлен

Эту работу вы выполняете сами, результаты в ней — ожидаемые.

**Риски.** Оцените их до запуска.

- **Что меняется.** Командой `docker stop` останавливается контейнер узла kind. Все поды этого узла, включая системные (kube-proxy, kindnet) и возможно PostgreSQL или Envoy стенда, перестают работать.
- **Надолго ли.** Примерно на 3–5 минут. Автоматических изменений на хосте нет.
- **Безопасность.** Внешних последствий нет, образы и сеть хоста не меняются.
- **Влияние.** Демо-приложение в `orders` может стать недоступным, если на узле стоит PostgreSQL. Узел для опыта выбирают так, чтобы он был свободен (шаг 1). Через 300 секунд недоступности узла контроллер начнёт выселять с него поды, поэтому работу укладывают в пять минут.
- **Откат.** `docker start <узел>`, затем `kubectl wait --for=condition=Ready node/<узел>`. Если узел не вернулся, пересоздайте стенд скриптами `lab-down.sh` и `lab-up.sh` из 00-1 §3 и верните демо-приложение: `kubectl apply -f ~/lab/k8s/orders-api/k8s/`.

**Цель.** Увидеть, что происходит с томом и новым подом, когда узел с PV отказал.

**Что понадобится.** Стенд 00-1, namespace `lab-04-2`, образ `busybox:1.37`, docker на хосте, терминал, в котором вы можете запускать `docker` без sudo.

**Схема опыта.**

```
victim ── PVC data ── PV (nodeAffinity: $NODE)           [$NODE работает]
docker stop $NODE ──► NotReady ──► taint unreachable
second ── та же PVC ──► Pending: другие узлы не подходят по PV, этот закрыт taint'ом
docker start $NODE ──► Ready ──► second стартует на $NODE
```

Схема 6. Узел остановлен, и под с тем же томом не может запуститься нигде, пока узел не вернётся.

#### Шаг 1. Выбрать свободный узел и запустить под

Команда показывает, сколько подов на каждом узле, а затем создаёт под на выбранном узле.

```bash
kubectl get pods -A -o wide --no-headers | awk '{print $8}' | sort | uniq -c
kubectl -n orders get pods -o wide
```

| Часть команды | Значение |
|---|---|
| `get pods -A -o wide` | поды всех namespace с узлами |
| `awk '{print $8}'` | колонка NODE |
| `sort \| uniq -c` | число подов на каждом узле |
| `-n orders get pods -o wide` | где стоит PostgreSQL стенда |

Ожидаемый результат: по четыре–восемь подов на узел и в `orders` узел с PostgreSQL. Разбор: выберите рабочий узел, на котором нет подов `orders` (ниже `lab-worker3`) и сохраните его имя.

```bash
NODE=lab-worker3
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: data}
spec:
  accessModes: [ReadWriteOnce]
  resources: {requests: {storage: 100Mi}}
---
apiVersion: v1
kind: Pod
metadata: {name: victim}
spec:
  terminationGracePeriodSeconds: 1
  nodeSelector: {kubernetes.io/hostname: $NODE}
  containers:
  - name: c
    image: busybox:1.37
    command: ["sh", "-c", "echo alive > /data/state; sleep infinity"]
    volumeMounts: [{name: d, mountPath: /data}]
  volumes:
  - {name: d, persistentVolumeClaim: {claimName: data}}
EOF
kubectl wait --for=condition=Ready pod/victim
```

| Часть команды | Значение |
|---|---|
| `NODE=lab-worker3` | узел для опыта, замените при необходимости |
| `nodeSelector … hostname: $NODE` | пустить под только на этот узел |
| `echo alive > /data/state` | запись на том |

Ожидаемый результат: `victim` в состоянии `Running`, PV привязан к `$NODE`.

#### Шаг 2. Остановить узел и запустить второй под

Команды останавливают контейнер узла и ждут, пока API пометит узел `NotReady`; затем создают под с той же заявкой.

```bash
docker stop $NODE
sleep 60
kubectl get node $NODE --no-headers | awk '{print $1, $2}'
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata: {name: second}
spec:
  containers:
  - name: c
    image: busybox:1.37
    command: ["sleep", "infinity"]
    volumeMounts: [{name: d, mountPath: /data}]
  volumes:
  - {name: d, persistentVolumeClaim: {claimName: data}}
EOF
sleep 8
kubectl get pod second --no-headers | awk '{print $1, $3}'
kubectl get events --field-selector involvedObject.name=second,reason=FailedScheduling \
  -o jsonpath='{.items[-1:].message}{"\n"}'
```

| Часть команды | Значение |
|---|---|
| `docker stop $NODE` | остановить контейнер узла kind |
| `sleep 60` | подождать, пока контроллер заметит отказ (по умолчанию 50 с) |
| `get node … awk` | имя и статус узла |
| `reason=FailedScheduling` | события scheduler |

Ожидаемый результат:

```
lab-worker3 NotReady
second Pending
0/4 nodes are available: … untolerated taint(s) … didn't match PersistentVolume's node affinity.
```

Разбор:

1. `NotReady` — kubelet не отвечает, и контроллер узлов ставит taint `node.kubernetes.io/unreachable`.
2. `second Pending` — PV привязан к остановленному узлу, а остальные узлы не подходят.
3. В сообщении ждите фрагменты `untolerated taint(s)` (узел с taint) и `didn't match PersistentVolume's node affinity`; точный текст и счётчики зависят от узлов.
4. Через 300 с недоступности контроллер начнёт выселять `victim`; здесь мы до этого не доходим.

#### Шаг 3. Вернуть узел

Команды запускают контейнер узла, дожидаются `Ready` и проверяют, что `second` стартовал и видит данные.

```bash
docker start $NODE
kubectl wait --for=condition=Ready node/$NODE --timeout=180s
kubectl wait --for=condition=Ready pod/second --timeout=120s
kubectl exec second -- cat /data/state
```

| Часть команды | Значение |
|---|---|
| `docker start $NODE` | запустить остановленный контейнер узла |
| `wait --for=condition=Ready node/…` | ждать, пока узел станет Ready |
| `cat /data/state` | прочитать файл, записанный `victim` |

Ожидаемый результат: узел возвращается в `Ready` в пределах нескольких минут, `second` запускается на `$NODE`, команда `cat` печатает `alive`. Разбор: том и данные остались на диске узла, поэтому под вернулся к ним; без узла данные недоступны.

**Итог.**

| Что узнали | Где видно |
|---|---|
| При отказе узла под с local-томом ждёт именно его | шаг 2, `Pending` |
| Причина видна в событии scheduler | шаг 2, `FailedScheduling` |
| Данные на диске узла переживают отключение | шаг 3, `alive` |

**Уборка.**

```bash
kubectl delete pod victim second --now
kubectl delete pvc data
docker start $NODE 2>/dev/null; kubectl get nodes
```

Команды удаляют поды и заявку и повторно убеждаются, что узел запущен. В списке узлов все должны быть `Ready`.

**Вопросы для самопроверки.**

1. Почему `second` не переехал на другой узел?
2. Как ускорить освобождение облачного RWO-диска после отказа узла?
3. Какие данные стенда пострадали бы, если бы остановили узел с PostgreSQL?

<details>
<summary>Ответы</summary>

1. PV local-path имеет `nodeAffinity` на остановленный узел, и другие узлы под не принимают.
2. Если администратор уверен, что узел выключен, он ставит на него taint `node.kubernetes.io/out-of-service`: диск отключается без ожидания 6 минут.
3. База `orders`: пока узел остановлен, PostgreSQL и приложение недоступны, данные остаются на диске узла.

</details>

### Лабораторная работа 4. Защита, Delete, Retain и расширение

**Риски.** Работа создаёт StorageClass `local-retain` и PV, который не удаляется вместе с заявкой. Он занимает каталог на диске узла, пока вы не уберёте его вручную в уборке. На сам стенд и остальные классы работа не влияет. Откат: уборка в конце работы.

**Цель.** Увидеть finalizer защиты, удаление тома при `Delete`, сохранение данных при `Retain` и отказ расширения без `allowVolumeExpansion`.

**Что понадобится.** Стенд 00-1, namespace `lab-04-2`, образ `busybox:1.37`, docker на хосте.

**Схема опыта.**

```
класс standard (Delete): pod → PVC → удалить PVC (Terminating) → удалить pod → PVC и PV исчезли
класс local-retain:      pod пишет файл → удалить PVC → PV Released, файл на узле цел
patch PVC на 50Mi в классе standard → Forbidden
```

Схема 7. Три исхода: защита использования, потеря данных при `Delete` и сохранение при `Retain`.

#### Шаг 1. Защита заявки и политика Delete

Команды создают заявку и под, пытаются удалить заявку при работающем поде, затем удаляют под.

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: data}
spec:
  accessModes: [ReadWriteOnce]
  resources: {requests: {storage: 100Mi}}
---
apiVersion: v1
kind: Pod
metadata: {name: user}
spec:
  terminationGracePeriodSeconds: 1
  containers:
  - name: c
    image: busybox:1.37
    command: ["sleep", "infinity"]
    volumeMounts: [{name: d, mountPath: /data}]
  volumes:
  - {name: d, persistentVolumeClaim: {claimName: data}}
EOF
kubectl wait --for=condition=Ready pod/user
NODE=$(kubectl get pod user -o jsonpath='{.spec.nodeName}')
PV=$(kubectl get pvc data -o jsonpath='{.spec.volumeName}')
kubectl get pvc data -o jsonpath='finalizers={.metadata.finalizers}{"\n"}'
kubectl delete pvc data --wait=false
sleep 2
kubectl get pvc data --no-headers | awk '{print $1, $2}'
kubectl delete pod user --now
sleep 10
kubectl get pvc data
kubectl get pv $PV
docker exec $NODE sh -c "ls /var/local-path-provisioner/ | grep -c $PV"
```

| Часть команды | Значение |
|---|---|
| `finalizers={.metadata.finalizers}` | список finalizer заявки |
| `delete pvc data --wait=false` | запросить удаление без ожидания |
| `get pvc data \| awk` | имя и статус после запроса удаления |
| `delete pod user --now` | удалить единственного пользователя тома |
| `docker exec $NODE … grep -c $PV` | сколько каталогов тома осталось на узле |

Результат (имена PV и тонкости у вас могут отличаться):

```
finalizers=["kubernetes.io/pvc-protection"]
data Terminating
Error from server (NotFound): persistentvolumeclaims "data" not found
Error from server (NotFound): persistentvolumes "pvc-…" not found
0
```

Разбор:

1. `kubernetes.io/pvc-protection` — финалайзер, который стоит на заявке, пока она используется.
2. `Terminating` — удаление принято, но не завершено: под ещё монтирует том.
3. После удаления пода заявка исчезает, затем и PV (оба `NotFound`).
4. `0` — каталога тома на узле больше нет: политика `Delete` удалила и данные.

#### Шаг 2. Политика Retain

Команды создают класс с `Retain`, пишут файл на том, удаляют заявку и читают файл прямо на узле.

```bash
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
metadata: {name: keep}
spec:
  storageClassName: local-retain
  accessModes: [ReadWriteOnce]
  resources: {requests: {storage: 10Mi}}
---
apiVersion: v1
kind: Pod
metadata: {name: keeper}
spec:
  terminationGracePeriodSeconds: 1
  containers:
  - name: c
    image: busybox:1.37
    command: ["sh", "-c", "echo precious > /data/file; sleep infinity"]
    volumeMounts: [{name: d, mountPath: /data}]
  volumes:
  - {name: d, persistentVolumeClaim: {claimName: keep}}
EOF
kubectl wait --for=condition=Ready pod/keeper
PV2=$(kubectl get pvc keep -o jsonpath='{.spec.volumeName}')
NODE2=$(kubectl get pod keeper -o jsonpath='{.spec.nodeName}')
kubectl delete pod keeper --now
kubectl delete pvc keep
sleep 3
T='{.metadata.name} {.spec.persistentVolumeReclaimPolicy} {.status.phase} '
T+='{.spec.claimRef.namespace}/{.spec.claimRef.name}{"\n"}'
kubectl get pv $PV2 -o jsonpath="$T"
docker exec $NODE2 cat /var/local-path-provisioner/${PV2}_lab-04-2_keep/file
```

| Часть команды | Значение |
|---|---|
| `reclaimPolicy: Retain` | сохранить PV и данные после заявки |
| `storageClassName: local-retain` | заявка использует новый класс |
| `echo precious > /data/file` | пометить данные |
| `jsonpath="$T"` | имя PV, политика, фаза, бывшая заявка |
| `docker exec $NODE2 cat …/file` | прочитать файл на диске узла |

Результат (имя PV сокращено):

```
pvc-… Retain Released lab-04-2/keep
precious
```

Разбор:

1. `Retain` — политика, взятая из класса.
2. `Released` — заявки нет, но данные не освобождены, а `claimRef` всё ещё указывает на `lab-04-2/keep`.
3. `precious` — файл цел на диске узла: удаление PVC данные не тронуло.

Чтобы отдать этот том новой заявке, очищают `claimRef`.

```bash
kubectl patch pv $PV2 -p '{"spec":{"claimRef":null}}'
kubectl get pv $PV2 -o jsonpath='{.status.phase}{"\n"}'
```

| Часть команды | Значение |
|---|---|
| `patch pv … claimRef: null` | снять привязку к старой заявке |
| `jsonpath='{.status.phase}'` | новая фаза PV |

Ожидаемый результат: `Available`. Разбор: PV снова свободен, и новая заявка с классом `local-retain` и подходящим размером может его занять; это ручная операция администратора.

#### Шаг 3. Расширение в классе без allowVolumeExpansion

Команды создают заявку класса `standard`, запускают под и пытаются увеличить заявку.

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: grow}
spec:
  accessModes: [ReadWriteOnce]
  resources: {requests: {storage: 10Mi}}
---
apiVersion: v1
kind: Pod
metadata: {name: g}
spec:
  terminationGracePeriodSeconds: 1
  containers:
  - name: c
    image: busybox:1.37
    command: ["sleep", "infinity"]
    volumeMounts: [{name: d, mountPath: /data}]
  volumes:
  - {name: d, persistentVolumeClaim: {claimName: grow}}
EOF
kubectl wait --for=condition=Ready pod/g
kubectl patch pvc grow -p '{"spec":{"resources":{"requests":{"storage":"50Mi"}}}}'
```

| Часть команды | Значение |
|---|---|
| `kubectl patch pvc grow -p …` | поднять запрос ёмкости с 10 до 50 МиБ |
| `storage: "50Mi"` | новое значение запроса |

Результат (одна строка, здесь перенесена):

```
Error from server (Forbidden): persistentvolumeclaims "grow" is forbidden: only dynamically
provisioned pvc can be resized and the storageclass that provisions the pvc must support resize
```

Разбор: API отвечает `Forbidden`, потому что у класса `standard` нет `allowVolumeExpansion: true`. На драйвере с поддержкой расширения и включённым флагом та же команда увеличит диск, а затем kubelet расширит файловую систему (§3).

**Итог.**

| Что узнали | Где видно |
|---|---|
| Используемую заявку защищает finalizer | шаг 1, `Terminating` |
| При `Delete` удаление заявки удаляет том и данные | шаг 1, `0` |
| При `Retain` том переходит в `Released`, данные целы | шаг 2 |
| Released-том возвращают в работу, очищая `claimRef` | шаг 2, `Available` |
| Расширение требует `allowVolumeExpansion` | шаг 3 |

**Уборка.** Retain-том сам не удаляется, это его назначение, поэтому его убираем вручную. Затем удаляем namespace и возвращаем namespace kubectl по умолчанию.

```bash
kubectl delete pod g --now
kubectl config set-context --current --namespace=default
kubectl delete ns lab-04-2
kubectl delete pv $PV2
docker exec $NODE2 rm -rf /var/local-path-provisioner/${PV2}_lab-04-2_keep
kubectl delete sc local-retain
kubectl get pv | grep lab-04-2
```

Последняя команда должна ничего не напечатать: томов работы не осталось.

**Вопросы для самопроверки.**

1. Что держит заявку в состоянии `Terminating` на шаге 1?
2. Почему `Released` PV не привязался бы к новой заявке без правки?
3. Чем опасен namespace с заявками на классе с `Delete`?
4. Что нужно для успешного расширения заявки?

<details>
<summary>Ответы</summary>

1. Финалайзер `kubernetes.io/pvc-protection`: под ещё использует заявку.
2. У PV остаётся `claimRef` на старую заявку, поэтому он закреплён за ней; администратор очищает поле.
3. `kubectl delete ns` удаляет PVC, и по политике `Delete` вместе с ними уходят PV и данные. Ценные тома держат на `Retain`.
4. Класс с `allowVolumeExpansion: true`, драйвер с поддержкой изменения размера и увеличение, а не уменьшение запроса.

</details>

---

## → Дальше

Теперь понятно, где лежат данные пода, кто их удаляет и почему том привязывает под к узлу или зоне. Часть 04-3 берёт эти знания и спрашивает, как вернуть данные после аварии: она сравнивает логический бэкап PostgreSQL, снапшот тома и копию объектов кластера. Идёт она следующей, потому что бэкап имеет смысл только тогда, когда известно, чем он защищает и что остаётся без защиты.
