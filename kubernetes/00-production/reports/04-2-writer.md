# Отчёт писателя 04-2

Файл: /home/user/claude/kubernetes/04-config-storage/04-2-storage.md (1235 строк).

## Заголовки
## Где мы на карте; ## 1 Какую задачу решает хранилище (### Тома...; Три объекта; Статическая и динамическая выдача; Том из образа); ## 2 Как устроено (Привязка; Режим привязки; Режимы доступа и привязка к узлу; CSI: драйвер и путь тома; local-path); ## 3 Как управлять (StorageClass; Освобождение и защита; Расширение и восстановление; VolumeAttributesClass; Снапшоты); ## 4 Как увидеть (Классы и драйверы; Заявки и тома; Внутри пода; Какую команду выбрать); ## 5 Что ломается (Pending; Том не монтируется и узел недоступен; Данные пропали...; SELinux); ## 6 Пределы (Классы и политики; Размеры; Что устарело); ## Лабораторные работы 1-4; ## → Дальше.
Лабы: 1 Класс, WFFC, ёмкость; 2 RWO, RWOP, cordon; 3 Узел тома остановлен (docker stop, Риски, целиком ожидаемая); 4 Delete, Retain, расширение.

## Объём
Проза без кода и таблиц: ~5100 слов всего с прозой лабораторных; теория (§1-6) около 3,6 тыс. Читаемость: средняя длина 11,8, >25 слов: 0, нарушений 1 (строка вывода sc 104 знака, реальный вывод).

## Сомнительные места
- Ожидаемый (не из старой части) вывод: лаба 3 целиком; лаба 2 шаг 4 последняя строка `lab-worker` после uncordon (в старой части "вернулся на lab-worker"); лаба 4 шаг 2 `patch claimRef null` -> `Available`; лаба 3 шаг 1 распределение подов.
- Форма строк вывода собрана мной из фактов старой части: `get pvc phase` Pending/Bound (jsonpath), `writer Running lab-worker` (строка writer не в старой части), `data Terminating` (awk по get pvc), строка `path=… nodeAffinity=["lab-worker"] reclaim=Delete` (формат jsonpath массива), `pvc-… Retain Released lab-04-2/keep` (старый текст давал те же слова, форма jsonpath), столбцы REASON/MSG события WaitForFirstConsumer.
- NotFound-строки в лабе 4 шаг 1 (стандартный формат kubectl, в старой части "оба NotFound").
- `allocatedResourceStatuses`: значения ControllerResizeInProgress/ControllerResizeFailed/NodeResizeInProgress — по памяти (документация указывает только поле).
- VAC: status.currentVolumeAttributesClassName / modifyVolumeStatus — по памяти; пример driverName csi.example.com вымышлен и помечен.
- RWOP: документация говорит "только CSI", опыт на local-path показал запрет — отмечено в §6 и лабе 2.
- SELinux: стадии GA 1.36/1.37 по docs security-context; "RHEL-семейство" — моё пояснение.
- Лимиты дисков EBS 39/PD 16/Azure 16 — storage-limits docs; 6 минут force-detach и taint out-of-service — по памяти/старой части.
- Условие Unused (PersistentVolumeClaimUnusedSinceTime) "в 1.36 по умолчанию выключено" — по исследованию (alpha 1.36).
- "Portworx на CSI в 1.36", "flexvolume убран из kubeadm 1.36", "cephfs, rbd удалены 1.31" — по исследованию.
- Таймаут Ready узла "по умолчанию 50 с" (лаба 3) и 300 с tolerationSeconds — по плану 01-2 / умолчанию Kubernetes.
- Скорость dd 1,9 ГБ/с объяснена кэшем страниц (моя интерпретация).
- Имя контейнера узла = имя узла (`docker stop lab-worker3`) — соглашение kind.
- Образ в реестр: отсылка на 02-1.
- Лаба 1 помечена без Риски (запись 300 МБ на диск узла) — указано в разборе; при желании добавить блок.

## Выброшено/перенесено в модуль 12
- Кейс: удалили namespace стенда (debug) с привязанным прод-PV на Delete — потеря БД; бэкапы лежали на том же диске.
- Вопросы: PV vs PVC; что такое StorageClass; PVC Pending (причины); RWO vs RWOP; что с данными при удалении PVC; под не стартует после drain (nodeAffinity PV); зачем WaitForFirstConsumer; устройство CSI и поломки (VolumeAttachment 6 мин, лимит дисков, node-плагин).
- Подводные камни: Pending при WFFC норма; RWO про узел; local-path без лимитов; привязка к узлу/зоне; Delete по умолчанию; Released не переиспользуется; расширение только при allowVolumeExpansion; nodeName прячет сообщение scheduler; снапшот БД crash-consistent.
- Задание со звёздочкой: csi-driver-host-path со снапшотами и расширением (снапшоты в лабах не делаются, только теория).
- Не вошло: ссылки VolumeGroupSnapshot/CBT/storage capacity scoring/mutable CSINode allocatable (одна фраза про VolumeGroupSnapshot; про allocatable — в таблице команд только `allocatable.count`).
