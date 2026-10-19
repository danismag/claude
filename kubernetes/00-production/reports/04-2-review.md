# 04-2 Хранилище: PV, PVC, StorageClass, CSI — отчёт ревьюера

Файл: /home/user/claude/kubernetes/04-config-storage/04-2-storage.md. Правки — инструментом Edit и короткими python-заменами (точные строки). Документы сверки скачаны в scratchpad/docs042/.

## Найденные ошибки (было → стало)
- §3 allocatedResourceStatuses: `ControllerResizeFailed` (такого значения нет) → полный список из core/v1 types.go (release-1.36): `ControllerResizeInProgress`, `ControllerResizeInfeasible`, `NodeResizePending`, `NodeResizeInProgress`, `NodeResizeInfeasible`; добавлены условия `ControllerResizeError`/`NodeResizeError`. Формулировка восстановления приведена к документации: после сбоя размер меньше прежнего запроса, но больше `status.capacity`.
- §3 VAC: добавлено «в 1.36 нельзя выключить» (гейт locked с 1.36), VAC применяется и при создании тома; статус расписан: `currentVolumeAttributesClassName`, `modifyVolumeStatus` (целевой класс + `Pending`/`InProgress`/`Infeasible`, поле есть только во время смены), условия `ModifyingVolume`/`ModifyVolumeError`.
- §5 SELinux: «теперь он монтирует том с -o context» (как будто для всех томов в 1.36) → в 1.36 по умолчанию только тома RWOP (`SELinuxMountReadWriteOncePod` GA 1.36); для всех томов — `SELinuxMount`: beta выкл. 1.33–1.36, GA вкл. 1.37. Добавлены условия схемы (PVC, `seLinuxOptions`, CSIDriver `seLinuxMount: true`), пример конфликта (привилегированный и обычный под), полный путь поля `spec.securityContext.seLinuxChangePolicy`, флаг `--controllers=*,selinux-warning-controller`.
- RWOP «только CSI, но сработал на local-path»: объяснено по коду. Scheduler (плагин VolumeRestrictions) смотрит на accessModes заявки, kubelet (operation_generator.go) — на accessModes PV на своём узле; ни одна проверка не зависит от драйвера. «Только CSI» в документации — про обещанный полный путь через драйвер (SINGLE_NODE_SINGLE_WRITER, версии sidecar). Исправлены §2, §6 и разбор лабы 2 шаг 3.
- §5 Multi-Attach: «VolumeAttachment висит до принудительного отключения через 6 минут» → под выселяется через 300 с, затем ещё 6 минут неудачного удаления пода, и только если узел нездоров; добавлены риск повреждения данных (нарушение спецификации CSI), флаг `--disable-force-detach-on-timeout`, эффект taint `NoExecute`/`NoSchedule`, ручное снятие taint. Ответ 2 лабы 3 и §6 приведены в соответствие.
- Лимиты дисков: «39 у EBS, 16 у PD и Azure Disk» подавались как текущие → это старые значения scheduler по умолчанию для встроенных плагинов; реальный лимит сообщает CSI-драйвер по типу машины (на GCE до 127, на Azure до 64); добавлено: mutable CSINode allocatable GA 1.36.
- §6 устаревшее: «Portworx переведён на CSI в 1.36» → миграция GA 1.33, гейт убран в 1.36; добавлено удаление встроенного кода облачных дисков (gcePersistentDisk — 1.28); FlexVolume — устарел с 1.23.
- Давление диска на kind: «kubelet начнёт выселять поды» → на стенде пороги выселения по диску 0 % (kind config.go v0.32.0, 00-1): диск хоста просто заполнится. Исправлены §5, ответ 3 лабы 1.
- Лаба 1: добавлен блок «Риски» первым (запись 300 МБ в каталог local-path узла = на диск хоста; пороги выселения отключены; проверка `df -h /var/lib/docker`; откат — удаление PVC). Решение: по AGENTS §3.2/§4 и brief-writer это изменение узла с влиянием на хост и соседей, блок нужен — по аналогии с лабой 4.
- Лаба 2: «Риски» перенесены первым блоком (§3.2).
- Лаба 3 шаг 1: `awk '{print $8}'` по `-o wide` ломается при RESTARTS вида `1 (5m ago)` → `-o custom-columns=NODE:.spec.nodeName`; выдуманное «по четыре–восемь подов на узел» убрано. «Риски» и откат проверены: на месте, полные (docker start + wait, пересоздание стенда, возврат orders).
- Лаба 1 шаг 1: строка вывода 104 знака → отступы колонок сжаты на 1 знак (выравнивание сохранено), в подписи сказано, что `AGE` опущена и отступы сжаты.
- Мелкое: «Полю nodeName верить нельзя» → «nodeName с такой заявкой не используют…»; «Расширение не растёт» → «Том не растёт»; уточнена отсылка ручной процедуры («не больше текущей ёмкости»); вступление к лабораторным перечисляет, какие работы чем рискуют.
- Добавлено по исследованию: `status.lastPhaseTransitionTime` PV (GA 1.31); `Unused` alpha 1.36 / beta вкл. 1.37; `recursiveReadOnly: Enabled` (GA 1.33); §6 — 50 с до недоступности узла и 300 с до выселения.

## Читаемость
До: 247 предложений, средняя 11,7, короче 10 слов 33 %, нарушений 1 (строка вывода 104 знака). После: 268, средняя 12,0, 32 %, нарушений 0 (поделено предложение 29 слов, два абзаца по 6 предложений ужаты сшиванием). Эмодзи, «Проверено», значков нет; строки кода ≤100 знаков.

## Подтверждено (источник)
- Стадии гейтов: ImageVolume (GA 1.36), SELinuxMount (beta выкл. 1.33–1.36, GA 1.37), SELinuxMountReadWriteOncePod и SELinuxChangePolicy (GA 1.36), VolumeAttributesClass (GA 1.34, locked 1.36), RecoverVolumeExpansionFailure (GA 1.34), HonorPVReclaimPolicy (GA 1.33), ReadWriteOncePod (GA 1.29), PersistentVolumeClaimUnusedSinceTime (alpha 1.36, beta 1.37), MutableCSINodeAllocatableCount (GA 1.36), AnyVolumeDataSource и RecursiveReadOnlyMounts (GA 1.33), PersistentVolumeLastPhaseTransitionTime (GA 1.31), CSIMigrationPortworx (GA 1.33, удалён 1.36): website feature-gates/*.md.
- Значения allocatedResourceStatuses, modifyVolumeStatus, условия PVC: kubernetes release-1.36 staging/src/k8s.io/api/core/v1/types.go.
- RWOP в scheduler и kubelet без привязки к драйверу; текст сообщения scheduler: pkg/scheduler/framework/plugins/volumerestrictions/volume_restrictions.go, pkg/volume/util/operationexecutor/operation_generator.go; примечание «только CSI»: persistent-volumes.md.
- Восстановление расширения, ручная процедура, XFS/ext3/ext4, finalizers pvc/pv-protection и external-provisioner (1.31), класс по умолчанию — новейший, «Many» только в одном namespace, статусы PV: persistent-volumes.md.
- VAC: только CSI с ModifyVolume, параметры класса неизменяемы, 512 параметров / 256 КиБ: volume-attributes-classes.md; те же пределы StorageClass, Immediate по умолчанию, mountOptions не проверяются, nodeName при WFFC: storage-classes.md.
- Image volume: только чтение, pullPolicy по умолчанию, subPath с 1.33, сбой загрузки блокирует старт: volumes.md.
- Лимиты 39/16/16, 127 GCE, 64 Azure, CSI NodeGetInfo: storage-limits.md.
- 6 минут, out-of-service (NoExecute/NoSchedule), `disable-force-detach-on-timeout`: node-shutdown.md, kube-controller-manager.md; `--node-monitor-grace-period` 50 с, выселение через 5 минут: kube-controller-manager.md, nodes.md.
- SELinux: условия схемы, текст ошибки, контроллер и метрика: tasks/configure-pod-container/security-context.md.
- cephfs/rbd недоступны с 1.31, gcePersistentDisk удалён в 1.28, FlexVolume устарел с 1.23, gitRepo отключён: persistent-volumes.md, volumes.md.
- kind: evictionHard nodefs/imagefs 0 %: kubernetes-sigs/kind v0.32.0 pkg/cluster/internal/kubeadm/config.go.
- Реальный вывод лаб 1, 2, 4 (sc, событие WFFC, path/nodeAffinity, dd, FailedMount, RWOP, cordon, finalizer, Retain Released, Forbidden): старая версия e755ced.

## Не подтверждено (для 00-plan)
- Лаба 3 целиком — ожидаемая (docker stop узла; текст FailedScheduling с unreachable taint и время возврата узла не прогонялись).
- Лаба 3 сверх списка 00-plan §4 (там 3 работы) — внести в 00-plan как отличие от плана.
- Лаба 1 шаг 2: форма вывода `custom-columns` REASON/MSG и jsonpath фазы собрана по фактам старой части.
- Лаба 1 шаг 1: отступы колонок `kubectl get sc` сжаты на 1 знак относительно реального вывода.
- Лаба 2 шаг 2: форма строк `awk` (writer/same-node/other-node) собрана по фактам старой части.
- Лаба 4 шаг 2: `Available` после `claimRef: null` — ожидаемый, по документации.
- Лаба 4 шаг 1: строки NotFound — стандартный формат kubectl, в прогоне записано только «оба NotFound».
- RWOP: что kubelet остановит второй под с `nodeName` на том же узле для local-path — вывод из кода, не прогонялся.
- Image volume: требование containerd 2.1+ — из исследования (блог 1.35), документацией не сверено.
- VolumeGroupSnapshot GA 1.36 — из исследования (KEP-3476), гейт в документации не найден.
- kubeadm 1.36 убрал каталог flex-volume — из исследования (CHANGELOG), не сверено.
- Скорость dd 1,9 ГБ/с объяснена кэшем страниц — интерпретация (dd без fsync).
