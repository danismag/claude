# 11-4. Узел и control plane

> Модуль 11 «Наблюдаемость и диагностика» · часть 4 из 4 · ~2 ч чтения + ~1,5 ч лабы · Нужно: стенд 00-1 (контекст `kind-lab`), `docker exec` на узлы kind, jq из 00-2, образ `busybox:1.37` · Опирается на: 01-1 (control plane), 01-2 (узел), 05-2 и 05-5 (диск и выселение), 10-2 (etcd)

## Где мы на карте

Части 11-2 и 11-3 учили искать причину в поде и в сети. Если с подом всё в порядке, а беда остаётся, поиск спускается ниже: на узел и на control plane. Механизмы этих уровней уже разобраны в 01-1, 01-2, 05-5 и 10-2, поэтому здесь они не повторяются. Часть собирает их в порядок поиска: по какому признаку понять, какой компонент сломан, и чем это подтвердить.

Следующий модуль, 12, превращает пройденное в банк вопросов с эталонами (12-1), тренажёры «сломай и почини» (12-2) и задачи по проектированию (12-3).

```
пользователь ──► Gateway ──► поды                          11-2, 11-3
                               │
узел:           kubelet ──► containerd ──► контейнеры, диск   эта часть, работы 1 и 3
                  │ Lease и статус узла
control plane:  API-сервер ◄──► etcd                          эта часть, работы 2 и 3
                scheduler, controller-manager
```

Схема 1. Три уровня поиска: под и сеть, узел, control plane. Чем ниже уровень, тем больше объектов он затрагивает.

---

## 1. Какую задачу решает диагностика узла и control plane

Сломанный под затрагивает одно приложение, а сломанный узел или control plane затрагивает десятки. Поэтому здесь порядок действий важнее знания отдельных команд. Раздел объясняет, почему у одного признака много причин, как оценить масштаб и с чего начать поиск.

### Один признак, много причин

Признак показывает, где порвалась цепочка, но не говорит почему. Узел `NotReady` может означать остановленный kubelet, упавший containerd, пропавшую сеть до API-сервера или выключенную машину. Под в `Pending` без событий значит остановленный scheduler или чужое имя планировщика в поде. Отказ `connection refused` от kubectl говорит об упавшем API-сервере, а таймаут — о сети или балансировщике.

Метод один для всех случаев: сначала сузить место поломки по признаку, затем читать журнал именно этого компонента. Пары «признак — причина» разобраны в разделе 5.

### Радиус поражения

**Радиус поражения** (blast radius) — всё, что перестаёт работать при отказе одного компонента. Его оценивают первым, потому что он определяет срочность. Без control plane уже запущенные поды и трафик продолжают работать, но кластер не меняется: нет деплоя и замены упавших подов (01-1 §5). Без узла пропадают его поды, и пользователи замечают это сразу.

Пример со стенда: kubelet остановили на `lab-worker3`, и сквозной запрос к orders не проходил все 6 минут, 0 успешных из 50. Реплики orders-api стояли на двух других узлах, дело было не в них. На больном узле жила единственная реплика Envoy: с 47-й секунды у его Service не осталось готовых адресов. Через 300 с Envoy пересоздался на другом узле, и ещё через 20 с трафик вернулся.

Вывод для диагностики: отказ узла опасен тем, что на нём стоит. Защита — не меньше двух реплик на разных узлах и бюджет прерываний (03-4, 05-5).

### Порядок поиска: снаружи внутрь

Поиск идёт от того, что видит пользователь, к тому, что видит компонент.

1. Оцените масштаб: `kubectl get nodes` и `kubectl get pods -A` без подов в Running. Затронуты один узел, одна зона или весь кластер?
2. Проверьте, отвечает ли API-сервер. Если нет, переходите к пункту 5: остальные команды kubectl бесполезны.
3. Прочитайте условия проблемного узла. Ready=Unknown и Ready=False ведут в разные места (раздел 2).
4. Зайдите на узел: состояние служб, журнал kubelet и containerd, `crictl`, диск.
5. Проверьте control plane: `/readyz?verbose`, static pod через `crictl`, Lease лидеров, etcd (10-2).
6. Запишите время начала и последние изменения: события, историю деплоев и GitOps, работы на инфраструктуре.

```
kubectl get nodes отвечает?
 ├─ нет ─► control plane: crictl на узле, /readyz, etcd             раздел 5, API-сервер
 └─ да ──► условие Ready узла
            ├─ Unknown ─► kubelet молчит: служба, машина, сеть     раздел 5, п. 1
            ├─ False ───► kubelet жив и жалуется: runtime, CNI     раздел 5, п. 2
            └─ True, но поды выселены или Pending ─► диск, scheduler, лидеры
```

Схема 2. Дерево поиска: читайте сверху вниз, каждая ветка ведёт в свой подраздел раздела 5.

---

## 2. Как устроены сигналы здоровья

Узел и компоненты control plane сообщают о здоровье небольшим набором сигналов, и если знать, кто пишет каждый сигнал, по нему видно, где искать.

### Условие Ready собирает kubelet

Kubelet выставляет условие Ready по состоянию трёх частей: контейнерного runtime, сетевого плагина и PLEG (01-2 §5). Когда одна из них неисправна, kubelet ставит Ready=False с причиной `KubeletNotReady` и называет виновника в сообщении. Чаще всего встречаются три сообщения:

- `container runtime is down` — kubelet не достучался до containerd.
- `PLEG is not healthy` — сверка состояния контейнеров не завершалась дольше порога в 3 минуты.
- `container runtime network not ready` — сетевой плагин (CNI) не готов, например, нет конфигурации сети на узле.

Нехватка памяти, диска или PID на Ready не влияет: для неё у kubelet есть отдельные условия (ниже).

### Два голоса: kubelet и контроллер узлов

Условие Ready принимает три значения, и их пишут разные компоненты, поэтому место поиска зависит от того, кто записал значение.

| Ready | Кто ставит | Что случилось | С чего начать |
|---|---|---|---|
| True | kubelet | узел исправен | — |
| False | kubelet | kubelet жив и видит неисправность | журнал kubelet и containerd |
| Unknown | node lifecycle controller | kubelet перестал присылать статус | служба kubelet, машина, сеть |

Ключевое различие: False пишет сам kubelet, поэтому он точно работает, а Unknown пишет контроллер, потому что от kubelet ничего нет. Живость kubelet быстро проверяет возраст Lease узла (01-2 §2). Kubelet продлевает его примерно раз в 10 с, а контроллер объявляет Unknown, когда `renewTime` отстаёт больше чем на 50 с.

Есть ловушка: node lifecycle controller живёт внутри controller-manager. Если тот остановлен, мёртвый узел не получит Unknown и будет выглядеть Ready, хотя его Lease давно устарел.

### Давление и диск

Кроме Ready kubelet ставит три условия давления: `MemoryPressure`, `DiskPressure` и `PIDPressure`. Когда условие истинно, узел получает taint `node.kubernetes.io/*-pressure:NoSchedule`, и kubelet начинает выселять поды (05-5 §2). Пороги по умолчанию собраны в разделе 6.

Выселение бывает и без давления на узел: kubelet выселяет под, который превысил собственный лимит `limits.ephemeral-storage` (05-2). Условия узла при этом не меняются.

```
kubelet измеряет диск
 ├─ свободно меньше порога узла ─► DiskPressure=True, taint, выселение по очереди (05-5)
 └─ под превысил свой лимит ─────► выселен только этот под, условия узла прежние
```

Схема 3. Два источника выселения по диску. Различить их помогают условие `DiskPressure` и текст в `status.message` пода.

На стенде kind пороги диска равны 0%, поэтому `DiskPressure` не появится, даже если диск хоста заполнен (раздел 5).

### Здоровье control plane

API-сервер отвечает на три проверки: `/livez` (процесс жив), `/readyz` (готов принимать запросы) и `/livez/etcd` (доступно хранилище). С параметром `?verbose` они перечисляют отдельные проверки (01-1 §4). У scheduler и controller-manager такой точки для клиента нет, и их здоровье видно по объектам Lease. Лидер продлевает аренду, а растущий возраст `renewTime` означает, что лидера нет.

Правду о процессах знает узел. Mirror pod в API может показывать устаревшее состояние, а `crictl ps` на узле control plane показывает контейнеры, которые действительно запущены.

---

## 3. Как управлять при диагностике

Диагностика требует доступа к узлу и журналам, а иногда и остановки компонента, поэтому здесь собраны способы доступа и безопасные приёмы.

### Дорога к узлу

К узлу ведут три пути.

- **ssh** — основной путь на рабочих кластерах.
- **`docker exec <узел>`** — путь на стенде kind: узлы там — контейнеры.
- **`kubectl debug node/<имя>`** (00-2) — запасной путь, когда ssh нет.

Третий путь работает только при живом API-сервере. Профиль `sysadmin` даёт root на узле, поэтому право создавать такие поды выдают немногим. Когда API-сервер лежит, остаются ssh и консоль машины, и доступ к ним проверяют заранее, а не во время аварии.

### Журналы компонентов

Kubelet и containerd пишут в journald (11-1 §2) — службу systemd, которая собирает журналы служб; читают её командой `journalctl`. Остальное читают так:

- `journalctl -u kubelet --since -10min` — журнал kubelet за 10 минут.
- `journalctl -u containerd -p err` — только ошибки containerd.
- `crictl logs --tail=50 <id>` — лог контейнера, в том числе static pod control plane при лежащем API-сервере.
- `/var/log/pods/<namespace>_<под>_<uid>/<контейнер>/` — файлы логов контейнеров; kubelet ротирует их по 10 МиБ и хранит 5 файлов (01-2 §6).
- `kubectl -n kube-system logs <static pod>` — тот же лог через API, если он жив.

С Kubernetes 1.36 (GA) журнал узла можно прочитать и через API без ssh: `kubectl get --raw "/api/v1/nodes/<узел>/proxy/logs/?query=kubelet&tailLines=50"`. По умолчанию запрос закрыт настройками kubelet (`enableSystemLogHandler`, `enableSystemLogQuery`, 11-1 §3), а пользователю через API нужно право на `nodes/proxy`, и это широкое право (06-1). Поэтому на аварию не рассчитывают на этот путь, если его не включили заранее.

### Остановка, запуск и перезапуск

Пять правил делают вмешательство безопасным.

- **kubelet** перезапускают командой `systemctl restart kubelet`. Контейнеры при этом живут, а с 1.35 поды остаются Ready (KEP-4781, 01-2).
- **containerd** при перезапуске не убивает работающие контейнеры, их держат процессы shim. Пока runtime недоступен, узел остаётся `NotReady`.
- **Static pod** control plane останавливают переносом манифеста из `/etc/kubernetes/manifests` (01-1 §3). Копию держите вне каталога: kubelet запускает каждый нескрытый файл как static pod, и `kube-apiserver.yaml.bak` рядом даст второй API-сервер или ошибки в журнале.
- **Перед долгой работой** на узле поставьте cordon (05-5 §3), чтобы scheduler не клал новые поды.
- **Не удаляйте** объект Node и не выселяйте поды принудительно, пока не уверены, что узел мёртв (01-2 §5).

---

## 4. Как увидеть состояние

Состояние видно с трёх сторон: из API, с самого узла и по метрикам. Начинайте с API, а на узел идите, когда нужны причины.

### Узел глазами API

Команды читают условия узла, возраст Lease, события узла и статистику файловой системы по данным kubelet. Подставьте имя узла в переменную `N`.

```bash
N=lab-worker3
kubectl get nodes -o wide
kubectl get node $N -o jsonpath=\
'{range .status.conditions[*]}{.type}={.status} {.reason}{"\n"}{end}'
kubectl -n kube-node-lease get lease $N -o jsonpath='{.spec.renewTime}{"\n"}'; date -u +%FT%TZ
kubectl describe node $N | tail -20
kubectl get --raw /api/v1/nodes/$N/proxy/stats/summary | jq '.node.fs'
```

Что в выводе:

1. Условия: `Ready` с причиной, затем `MemoryPressure`, `DiskPressure`, `PIDPressure`.
2. Две строки времени: `renewTime` Lease и текущее время. Разница больше 50 с означает, что kubelet молчит.
3. Блок `Events` в конце `describe node`: сообщения о смене Ready, о давлении, о выселении.
4. Поле `availableBytes` в `.node.fs` — свободное место, по которому kubelet сверяется с порогом `nodefs.available`.

### Узел изнутри

Команды выполняют на узле (на стенде — через `docker exec lab-worker3`), и они проверяют службы, журнал, состояние runtime и диск.

```bash
systemctl is-active kubelet containerd
journalctl -u kubelet --since -5min --no-pager | tail -20
crictl info | jq '.status.conditions[] | {type, status}'
crictl ps -a | head
df -h /var/lib/containerd /var/lib/kubelet; df -i /var/lib/kubelet
du -sh /var/log/pods/* | sort -h | tail -5
```

Что в выводе:

1. `active` или `inactive` по строке на службу.
2. Конец журнала kubelet: ищите строки с `error`, `Unable to`, `Failed to`.
3. Условия `RuntimeReady` и `NetworkReady` у runtime со значением `true` или `false`.
4. Колонка `STATE` в `crictl ps -a`: много `Exited` говорит о накопившихся мёртвых контейнерах.
5. Занятость диска и **inode** — записей файловой системы о файлах. Их число ограничено: диск с свободными байтами может исчерпать inode.
6. Пять самых больших каталогов логов подов.

Давление на узел видно раньше порогов выселения по счётчикам PSI (05-1 §4). На узле их читают из `/proc/pressure/memory`, `/proc/pressure/cpu` и `/proc/pressure/io` (05-5 §4), а kubelet с 1.36 (GA) отдаёт PSI контейнеров метриками `container_pressure_*` (11-1). Рост строки `some` у памяти означает, что задачи ждут память, хотя `memory.available` ещё выше порога.

### Control plane глазами клиента

Команды проверяют готовность API-сервера, доступность etcd, лидеров и время ответа.

```bash
kubectl get --raw '/readyz?verbose' | tail -5
kubectl get --raw /livez/etcd; echo
kubectl -n kube-system get lease kube-scheduler kube-controller-manager
kubectl get nodes -v=6 2>&1 | grep milliseconds
```

Что в выводе:

1. Конец списка проверок `readyz`; последняя строка `readyz check passed` значит, что все проверки прошли.
2. `ok` от `/livez/etcd` — API-сервер видит etcd.
3. Колонка `HOLDER` у Lease: имя узла и суффикс процесса лидера.
4. Строка с `milliseconds`: флаг `-v=6` печатает каждый запрос со статусом и временем, поэтому видно, где медленно — на сервере или у клиента.

Страницы `/statusz` и `/flagz` (версия, время работы и действующие флаги) компоненты отдают с 1.36 в стадии beta (01-1 §4).

### Метрики

Метрики собирает система наблюдения (11-1), а в таблице — те, что быстрее всего показывают, где проблема. Метрики API-сервера можно прочитать и вручную командой `kubectl get --raw /metrics`.

| Метрика | Что показывает | Когда тревожно |
|---|---|---|
| `apiserver_request_duration_seconds` | задержка запросов по глаголу и ресурсу | p99 выше целей раздела 6 |
| `apiserver_current_inflight_requests` | запросы в обработке | держится у предела 400 и 200 |
| `apiserver_flowcontrol_rejected_requests_total` | отказы APF с ответом 429 | растёт у любого уровня приоритета |
| `etcd_request_duration_seconds` | время обращений к etcd со стороны API | растёт вместе с общей задержкой |
| `apiserver_admission_webhook_admission_duration_seconds` | время вебхуков допуска | секунды у одного вебхука |
| `etcd_disk_wal_fsync_duration_seconds` | fsync журнала etcd | p99 больше 10 мс |
| `leader_election_master_status` | 1, если этот экземпляр лидер | ни у одного экземпляра нет 1 |
| `kubelet_pleg_relist_duration_seconds` | время сверки PLEG | растёт к порогу в 3 минуты |
| `kubelet_evictions` | выселения по сигналам | растёт без вашего участия |

---

## 5. Что ломается и как найти причину

Поломки разбиты на пять групп, и каждая идёт по схеме «признак — проверка — причина».

### Узел Unknown: kubelet молчит

Unknown появляется через `node-monitor-grace-period` (50 с) после последнего обновления Lease, на стенде это было на 47-й секунде. Контейнеры при этом живы, а хронология до выселения (50 + 300 с) описана в 01-2 §5. Задача диагностики: понять, что молчит — служба, машина или сеть до API-сервера.

Проверки идут по порядку:

1. Достижим ли узел по ssh? Если нет, машина выключена или изолирована, и причину ищут в гипервизоре или облаке.
2. Что говорит `systemctl is-active kubelet`? При `inactive` или `failed` читайте `journalctl -u kubelet -n 50`.
3. Если служба `active`, журнал покажет, что kubelet не достучался до API-сервера: `Failed to ensure lease exists` или `Unable to update node status`. Проверяйте сеть и клиентский сертификат kubelet (10-4).

Служба часто не стартует по четырём причинам: ошибка в `config.yaml`, cgroup v1 при `failCgroupV1` (01-2 §6), истёкший клиентский сертификат и переполненный диск. Не удаляйте поды и объект Node «на всякий случай»: процессы живы, и диск может быть смонтирован. Когда служба вернулась, Ready восстанавливается примерно за 1 с.

### Узел False: runtime, PLEG и сеть

Если containerd остановлен, узел становится `Ready=False` через 32 с с причиной `KubeletNotReady` и сообщением `container runtime is down`. В журнале kubelet появляется строка `GenericPLEG: Unable to retrieve pods … dial unix /run/containerd/containerd.sock`. Узел получает taint `node.kubernetes.io/not-ready:NoExecute` с тем же отсчётом в 300 с до выселения. Контейнеры не падают, потому что их держат shim-процессы, а после запуска containerd узел становится Ready за 10 с без перезапуска подов.

Порядок поиска такой:

1. Прочитайте сообщение условия Ready: оно называет runtime, PLEG или сеть.
2. Проверьте `systemctl status containerd` и `journalctl -u containerd -p err`.
3. Сравните с `crictl info`: условие `RuntimeReady` или `NetworkReady` в состоянии `false` указывает на часть, которая отказала.
4. Посчитайте контейнеры: `crictl ps -a | wc -l`. Тысячи остановленных контейнеров и медленный диск перегружают runtime, и PLEG не успевает завершить сверку.

Сообщение `PLEG is not healthy` значит, что сверка отстала больше чем на 3 минуты. Перезапуск containerd лечит симптом, но не причину (01-2 §5). Если сообщение называет сеть (`NetworkPluginNotReady`, `cni plugin not initialized`), смотрите под CNI на этом узле и конфигурацию в `/etc/cni/net.d` (03-1). В 1.37 релист PLEG по требованию становится GA.

### Диск и выселение

Диск узла заполняют логи подов, образы, слой записи контейнера и `emptyDir` без `sizeLimit` (05-2). При нехватке kubelet сначала удаляет мёртвые контейнеры и неиспользуемые образы, а затем выселяет поды (05-5 §2). Проверьте оба показателя: байты через `df -h` и inode через `df -i`.

На стенде kind картина искажена: пороги диска равны 0%, а сборка образов выключена (`imageGCHighThresholdPercent: 100`), поэтому `DiskPressure` не появится. На тестовой машине на диске хоста оставалось 9,2 ГБ из 98 (9,4 % при пороге 10 %): обычный узел был бы уже под давлением. Поэтому на стенде проверяют `docker system df` и свободное место хоста вручную (01-2 §6).

Воспроизвести можно выселение по лимиту пода. Под, который записал 50 МиБ при `limits.ephemeral-storage: 20Mi`, выселяется с сообщением `Pod ephemeral local storage usage exceeds the total limit of containers 20Mi`. Отличие от давления узла видно по условию `DiskPressure`: у узла оно остаётся False, а выселен только один под. Для очистки узла используют `crictl rmi --prune` (неиспользуемые образы) и ротацию логов. Образы, загруженные в kind командой `kind load`, удаляйте только по имени: prune заберёт и их, если на них нет подов.

### API-сервер: недоступен, медленный, отвечает 429

Ответ клиента сразу сужает место поломки.

| Признак | Что означает | Первый шаг |
|---|---|---|
| `connection refused` | порт никто не слушает | посмотреть контейнеры на узле через crictl |
| таймаут | сеть, firewall или балансировщик | проверить порт 6443 с другой машины |
| `etcdserver: request timed out` и ответы 5xx | API-сервер жив, плох etcd или вебхук | проверки readyz и livez etcd |
| `429` | сработал APF | метрика отказов и FlowSchema клиента |
| `x509: certificate has expired` | истёк сертификат | продление сертификатов (10-4) |

Если API-сервер не запущен после правки манифеста, ищите ошибку флага: kubelet пересоздаёт контейнер, а `crictl ps -a` показывает `Exited`. Причину читают командой `crictl logs` или в каталоге `/var/log/pods`. Другие причины — OOM на узле control plane и недоступный etcd.

Ответ 429 приходит от APF (01-1 §3), когда очередь приоритета полна. API-сервер добавляет заголовок **Retry-After** — через сколько секунд повторить запрос; клиенты client-go ждут и повторяют. Найдите шумного клиента по метрике отказов с меткой `priority_level` и по FlowSchema, под которую он попал.

Если ошибок нет, но всё медленно, разделите задержку на части. Общее время запроса показывает `apiserver_request_duration_seconds`. Из него вычитают время etcd (`etcd_request_duration_seconds`) и время вебхуков допуска. Остаток уходит на работу самого API-сервера: тяжёлые LIST без пагинации и тысячи watch-соединений (01-1 §6).

Отдельный случай — недоступный вебхук с `failurePolicy: Fail`: он блокирует записи (09-2). Медленный диск etcd и квоту базы разбирает 10-2 §5.

### Scheduler, controller-manager и лидеры

Два признака указывают на эти компоненты. Под в `Pending` без единого события значит, что scheduler не работает или в поде указан несуществующий `schedulerName`. Если же событие `FailedScheduling` есть, scheduler жив, но места нет (05-3). Replicas у Deployment меняются, а ReplicaSet и поды нет, когда остановлен controller-manager (01-1 §5).

Подтверждает диагноз Lease лидера: если `renewTime` стоит на месте, лидера нет. В кластере с несколькими экземплярами действует только один, поэтому читайте журнал того, кто держит Lease (колонка `HOLDER`).

Есть и обратный сценарий: процесс жив, но теряет аренду. Если API-сервер или etcd отвечают медленно, лидер не успевает продлить Lease за 10 с и завершается с кодом 1, а kubelet перезапускает контейнер. Последняя строка его лога — `leaderelection lost` (у scheduler — `Leaderelection lost`). Признак в `kubectl -n kube-system get pods` — растущий счётчик рестартов у scheduler или controller-manager. Лечат причину задержки (API-сервер или etcd), а не сами компоненты, ведь пока API-сервера нет, они пишут `Waiting for caches to sync` и ничего не делают.

---

## 6. Пределы и значения по умолчанию

Ниже собраны числа этой части для Kubernetes 1.36. Измеренные значения взяты из замера на тестовом стенде (kind 0.32.0, Kubernetes 1.36.5 после 10-3, containerd 2.3.1), остальные — из документации.

### Время реакции на отказ узла

Числа задают, как быстро кластер замечает отказ и реагирует.

- `node-monitor-grace-period` — 50 с (раньше 40 с); Unknown на стенде наступил на 47-й секунде.
- Продление Lease узла — раз в ~10 с, срок аренды 40 с (01-2 §6).
- `tolerationSeconds` для `unreachable` и `not-ready` — по 300 с: задают флаги `--default-unreachable-toleration-seconds` и `--default-not-ready-toleration-seconds` API-сервера.
- Остановленный containerd: Ready=False через 32 с, возврат Ready после запуска — 10 с.
- Порог PLEG — 3 минуты; kubelet вернул Ready за ~1 с после запуска.
- Условие давления держится минимум `evictionPressureTransitionPeriod` — 5 минут.

### Диск и выселение

Пороги и интервалы, которые определяют выселение по диску.

- Жёсткие пороги по умолчанию: `nodefs.available` 10 %, `nodefs.inodesFree` 5 %, `imagefs.available` 15 % (05-5 §6).
- В kind пороги диска равны 0 %, `imageGCHighThresholdPercent` равен 100.
- Сборка образов в обычном узле начинается при 85 % занятости и идёт до 80 %.
- Лимит `ephemeral-storage` по умолчанию не задан, его выдают LimitRange или манифест.
- Kubelet проверяет пороги раз в 10 с; под с превышенным лимитом диска выселен на стенде через 10–25 с.
- Логи контейнера — 10 МиБ на файл и 5 файлов.

### Control plane

Границы, при которых control plane начинает вести себя иначе.

- Аренда лидера: 15 с срок, 10 с на продление, 2 с между попытками (01-1 §6).
- Квота etcd — 2 ГиБ, рекомендуемый максимум 8 ГиБ; p99 fsync журнала — до 10 мс, commit backend — до 25 мс (10-2 §6).
- Общий предел одновременных запросов API-сервера — 600: 400 на чтение и 200 на изменение; APF делит его между приоритетами (01-1 §6).
- Цели SIG Scalability для p99 за сутки: 1 с на изменение и на чтение одного объекта, 30 с на list в namespace и по кластеру (раньше для namespace было 5 с).
- События живут 1 час (`--event-ttl`). В 1.37 значение `eventRecordQPS: 0` у kubelet означает «без лимита».

---

## Лабораторные работы

Работы идут на стенде 00-1 в namespace `lab-11-4`. Работы 1 и 2 останавливают компоненты стенда, поэтому у каждой первым стоит блок «Риски», а работа 3 ничего не останавливает. Образ `busybox:1.37` узлы берут из Docker Hub; запасной путь через реестр стенда описан в 02-1.

Подготовку делают один раз: создают namespace, функцию `k` и переменную с узлом. Функцию, переменные и namespace снимает уборка работы 3.

```bash
kubectl create ns lab-11-4
k() { kubectl -n lab-11-4 "$@"; }
NODE=lab-worker3
```

| Часть команды | Значение |
|---|---|
| `kubectl create ns lab-11-4` | создать namespace для всех работ части |
| `k() { kubectl -n lab-11-4 "$@"; }` | функция: kubectl с namespace работы |
| `NODE=lab-worker3` | узел, которому ломают kubelet и containerd |

Результат:

```
namespace/lab-11-4 created
```

Разбор: namespace создан, а текущий контекст kubectl не менялся, потому что namespace задаёт функция `k`.

### Лабораторная работа 1. Узел без kubelet и без containerd

Эту работу вы выполняете сами, результаты в ней — ожидаемые. Числа в разборе взяты из замера на тестовом стенде.

**Риски.** Работа останавливает kubelet и containerd на рабочем узле стенда.

- **Что меняется:** на `lab-worker3` по очереди останавливаются службы kubelet и containerd. Узел становится Unknown, затем False. Контейнеры узла продолжают работать. В namespace `lab-11-4` создаётся под `s1`.
- **Надолго ли:** kubelet стоит около 2 минут, containerd около 1 минуты. Вернуть обе службы нужно в пределах 300 с после появления taint, иначе контроллер в controller-manager начнёт выселять поды узла, и восстановление затянется.
- **Безопасность:** привилегий сверх `docker exec` не нужно, секреты не затрагиваются.
- **Влияние на систему:** на `lab-worker3` могут стоять Envoy Gateway и PostgreSQL стенда. Пока узел не Ready, их адреса пропадают из Service, и `orders` отвечает ошибкой. Шаг 1 покажет, что именно стоит на узле. Если там `postgres-0` или единственный Envoy, а ошибки orders для вас недопустимы, выберите другой узел в переменной `NODE`. Не запускайте другие работы параллельно.
- **Откат:** `docker exec $NODE systemctl start containerd kubelet`; если терминал потерян, подставьте имя `lab-worker3`. Затем `kubectl get nodes` должен показать все узлы Ready. Если 300 с уже истекли, контроллеры пересоздали поды на других узлах, а старые копии в `Terminating` исчезнут вскоре после возврата kubelet.

**Цель.** Увидеть, как отличаются Ready=Unknown (молчит kubelet) и Ready=False (жалуется kubelet), и прочитать признаки каждого случая в API и на узле.

**Что понадобится.**

- Стенд 00-1 с приложением `orders` и подготовка выше.
- Команда `docker exec` на узлы и `jq` на хосте.
- Образ `busybox:1.37`.

**Схема опыта.**

```
шаги 1–3   stop kubelet     Lease стареет ─► Ready=Unknown (~50 с), контейнеры живы
шаг 4      start kubelet    Ready=True за ~1 с
шаги 5–6   stop containerd  kubelet жив ─► Ready=False (~30 с), в журнале PLEG
           start containerd Ready=True за ~10 с, под s1 без рестартов
```

Схема 4. Две остановки на одном узле: молчит kubelet и недоступен runtime. Смотрите на значение Ready и на того, кто его записал.

#### Шаг 1. Снимок до поломки

Команды читают условия узла и возраст Lease, показывают поды на узле и создают под `s1`, привязанный к узлу.

```bash
kubectl get node $NODE -o jsonpath=\
'{range .status.conditions[*]}{.type}={.status} {.reason}{"\n"}{end}'
kubectl -n kube-node-lease get lease $NODE -o jsonpath='{.spec.renewTime}{"\n"}'; date -u +%FT%TZ
kubectl get pods -A -o wide --field-selector spec.nodeName=$NODE --no-headers | awk '{print $1, $2}'
k run s1 --image=busybox:1.37 --restart=Never \
  --overrides="{\"spec\":{\"nodeName\":\"$NODE\"}}" -- sleep 3600
```

| Часть команды | Значение |
|---|---|
| `jsonpath='{range .status.conditions[*]}…'` | напечатать тип, статус и причину каждого условия |
| `get lease $NODE` | аренда узла в `kube-node-lease` |
| `date -u +%FT%TZ` | текущее время в том же формате |
| `--field-selector spec.nodeName=$NODE` | только поды этого узла |
| `awk '{print $1, $2}'` | оставить namespace и имя пода |
| `--overrides=…nodeName` | поставить под на узел, минуя scheduler |

Результат (времена у вас другие; список подов зависит от стенда и сокращён):

```
MemoryPressure=False KubeletHasSufficientMemory
DiskPressure=False KubeletHasNoDiskPressure
PIDPressure=False KubeletHasSufficientPID
Ready=True KubeletReady
2026-10-19T09:10:02.512931Z
2026-10-19T09:10:07Z
kube-system kindnet-…
kube-system kube-proxy-…
envoy-gateway-system envoy-…
pod/s1 created
```

Разбор:

1. Все условия здоровы, у Ready причина `KubeletReady`.
2. Две строки времени отличаются на несколько секунд: kubelet продлевает Lease примерно раз в 10 с.
3. Список подов показывает, что умрёт для пользователей вместе с узлом. Если там `postgres-0` или Envoy, вы увидите ошибку в шаге 3.
4. Под `s1` привязан к узлу: он нужен как свидетель, что контейнеры переживут отказ.

#### Шаг 2. Остановить kubelet и дождаться Unknown

Команды останавливают kubelet и опрашивают узел раз в 2 с, пока Ready не станет Unknown.

```bash
SECONDS=0
docker exec $NODE systemctl stop kubelet
until [ "$(kubectl get node $NODE \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" = Unknown ]; do sleep 2; done
echo "Unknown через $SECONDS с"
```

| Часть команды | Значение |
|---|---|
| `SECONDS=0` | обнулить счётчик секунд bash |
| `systemctl stop kubelet` | остановить службу на узле |
| `?(@.type=="Ready")].status` | статус условия Ready |
| `until … = Unknown` | опрашивать, пока статус не станет Unknown |

Результат:

```
Unknown через 47 с
```

Разбор:

1. Около 50 с — `node-monitor-grace-period`. Отсчёт идёт от последнего обновления Lease, которое произошло за несколько секунд до остановки, поэтому в замере вышло 47 с.
2. Пока вы читаете результат, kubelet стоит. Вернуть его нужно в шаге 4, не позже чем через 2 минуты.

#### Шаг 3. Прочитать признаки снаружи и изнутри

Команды показывают условия, taints и возраст Lease, готовность подов и адресов узла, процесс контейнера на узле и сквозной запрос.

```bash
kubectl get node $NODE -o jsonpath=\
'{range .status.conditions[*]}{.type}={.status} {.reason}: {.message}{"\n"}{end}'
kubectl get node $NODE -o jsonpath='{.spec.taints[*].key}{"\n"}'
kubectl -n kube-node-lease get lease $NODE -o jsonpath='{.spec.renewTime}{"\n"}'; date -u +%FT%TZ
k get pod s1 -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}{"\n"}'
docker exec $NODE systemctl is-active kubelet
docker exec $NODE crictl ps --name s1
curl -s -m 3 -o /dev/null -w '%{http_code}\n' http://orders.localhost:8088/api/orders
```

| Часть команды | Значение |
|---|---|
| `{.reason}: {.message}` | добавить к статусу причину и сообщение |
| `{.spec.taints[*].key}` | ключи taints узла |
| `get pod s1 … Ready` | условие Ready пода на этом узле |
| `systemctl is-active kubelet` | состояние службы |
| `crictl ps --name s1` | контейнер `s1` на узле, мимо API |
| `curl … %{http_code}` | код сквозного запроса к orders |

Результат (сообщение условий переведено в одну строку; код curl зависит от шага 1):

```
MemoryPressure=Unknown NodeStatusUnknown: Kubelet stopped posting node status.
DiskPressure=Unknown NodeStatusUnknown: Kubelet stopped posting node status.
PIDPressure=Unknown NodeStatusUnknown: Kubelet stopped posting node status.
Ready=Unknown NodeStatusUnknown: Kubelet stopped posting node status.
node.kubernetes.io/unreachable node.kubernetes.io/unreachable
2026-10-19T09:10:21.118204Z
2026-10-19T09:11:12Z
False
inactive
CONTAINER   IMAGE   CREATED   STATE     NAME   ATTEMPT   …
…           …       …         Running   s1     0         …
200
```

Разбор:

1. Все четыре условия стали Unknown с причиной `NodeStatusUnknown`: их записал контроллер, а не kubelet.
2. Два одинаковых ключа `unreachable` — это два taint'а, `NoSchedule` и `NoExecute`. С `NoExecute` начинается отсчёт 300 с до выселения.
3. `renewTime` отстаёт от текущего времени больше чем на 50 с: kubelet молчит.
4. Условие Ready у `s1` — `False`: контроллер пометил поды узла неготовыми, а их адреса вышли из Service.
5. Служба `inactive`, а контейнер `s1` в состоянии `Running`: процессы живы, пропал только их менеджер.
6. Код `200` значит, что Envoy и PostgreSQL стоят на других узлах. Если они на этом, вы увидите `000` или `503`: радиус поражения определяется тем, что стоит на узле.

#### Шаг 4. Вернуть kubelet

Команды запускают kubelet, ждут Ready и проверяют, что контейнер `s1` не перезапускался.

```bash
SECONDS=0
docker exec $NODE systemctl start kubelet
until [ "$(kubectl get node $NODE \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" = True ]; do sleep 1; done
echo "Ready через $SECONDS с"
k get pod s1
```

| Часть команды | Значение |
|---|---|
| `systemctl start kubelet` | запустить службу |
| `until … = True` | опрашивать раз в секунду до Ready=True |
| `k get pod s1` | состояние свидетеля |

Результат:

```
Ready через 1 с
NAME   READY   STATUS    RESTARTS   AGE
s1     1/1     Running   0          2m
```

Разбор:

1. Узел вернулся в Ready за секунду: kubelet сразу отправил свежий статус и Lease.
2. `RESTARTS 0`: контейнер за всё время не перезапускался, потому что его держал containerd.
3. Выселение не успело начаться: вы вернулись раньше 300 с после taint.

#### Шаг 5. Остановить containerd и прочитать журнал

Команды останавливают runtime, ждут Ready=False, читают причину, строку PLEG и ищут процесс контейнера среди процессов узла.

```bash
SECONDS=0
docker exec $NODE systemctl stop containerd
until [ "$(kubectl get node $NODE \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" = False ]; do sleep 2; done
echo "False через $SECONDS с"
R='.status.conditions[?(@.type=="Ready")]'
kubectl get node $NODE -o jsonpath="{$R.reason}: {$R.message}{\"\\n\"}"
docker exec $NODE journalctl -u kubelet --since -1min --no-pager | grep PLEG | tail -1
docker top $NODE | grep 'sleep 3600'
```

| Часть команды | Значение |
|---|---|
| `systemctl stop containerd` | остановить runtime |
| `until … = False` | ждать, пока kubelet сам запишет False |
| `R='…'` | путь к условию Ready, чтобы не повторять его |
| `{$R.reason}: {$R.message}` | причина и сообщение условия Ready |
| `journalctl -u kubelet --since -1min` | журнал kubelet за минуту |
| `grep PLEG \| tail -1` | последняя строка про PLEG |
| `docker top $NODE \| grep 'sleep 3600'` | процесс контейнера `s1` среди процессов узла |

Результат (строка журнала сокращена):

```
False через 32 с
KubeletNotReady: container runtime is down
… GenericPLEG: Unable to retrieve pods … dial unix /run/containerd/containerd.sock …
root  4821  4713  0  09:12  ?  00:00:00  sleep 3600
```

Разбор:

1. Значение `False`, а не Unknown: kubelet работает и сам записал условие.
2. Сообщение `container runtime is down` называет виновника, а журнал подтверждает, что kubelet не может подключиться к сокету containerd. Если отказов несколько, kubelet перечисляет их в одном сообщении.
3. Процесс `sleep 3600` жив: работающие контейнеры не падают без containerd. Номера процессов у вас другие.
4. Узел получил taint `node.kubernetes.io/not-ready:NoExecute` с тем же отсчётом до выселения в 300 с, поэтому не задерживайтесь.

#### Шаг 6. Вернуть containerd

Команды запускают runtime и проверяют, что `s1` остался на месте без рестартов.

```bash
SECONDS=0
docker exec $NODE systemctl start containerd
until [ "$(kubectl get node $NODE \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" = True ]; do sleep 2; done
echo "Ready через $SECONDS с"
k get pod s1
kubectl get nodes
```

| Часть команды | Значение |
|---|---|
| `systemctl start containerd` | запустить runtime |
| `k get pod s1` | проверить свидетеля |
| `kubectl get nodes` | все ли узлы Ready |

Результат (Ready через 10 с — число из замера; версия v1.36.5 — после работ 10-3, на заново созданном стенде будет v1.36.1):

```
Ready через 10 с
NAME   READY   STATUS    RESTARTS   AGE
s1     1/1     Running   0          4m
NAME                 STATUS   ROLES           AGE   VERSION
lab-control-plane    Ready    control-plane   …     v1.36.5
lab-worker           Ready    <none>          …     v1.36.5
lab-worker2          Ready    <none>          …     v1.36.5
lab-worker3          Ready    <none>          …     v1.36.5
```

Разбор:

1. Узел вернулся в Ready примерно за 10 с: kubelet заново подключился к сокету и завершил сверку.
2. `s1` без рестартов: containerd восстановил картину из своих данных и shim-процессов.
3. Все четыре узла Ready, откат выполнен.

**Итог.**

| Что узнали | Где видно |
|---|---|
| Unknown пишет контроллер, когда kubelet молчит | шаг 3, `NodeStatusUnknown` |
| Контейнеры живут без kubelet | шаг 3, `crictl ps`, `Running` |
| False пишет сам kubelet при отказе runtime | шаг 5, `KubeletNotReady` |
| Отказ containerd виден в журнале как PLEG | шаг 5, `GenericPLEG` |
| Радиус поражения определяется содержимым узла | шаг 3, код `curl` |

**Уборка.** Проверяем, что обе службы активны и все узлы Ready.

```bash
docker exec $NODE systemctl is-active kubelet containerd
kubectl get nodes
k delete pod s1 --now
```

Первая команда должна напечатать две строки `active`, вторая — все узлы `Ready`. Третья удаляет под `s1`. Namespace и функцию снимает уборка работы 3.

**Вопросы для самопроверки.**

1. Чем отличается Ready=Unknown от Ready=False, и кто записывает каждое значение?
2. Почему контейнеры продолжают работать при остановленном kubelet и при остановленном containerd?
3. Какой признак в Lease показывает, что kubelet молчит?
4. Почему важно знать, что стоит на узле, до его поломки?

<details>
<summary>Ответ</summary>

1. False записывает kubelet: он жив и видит неисправность, например недоступный runtime. Unknown записывает node lifecycle controller, когда статус и Lease перестали приходить.
2. Контейнеры принадлежат процессам shim и ядру, а не kubelet или containerd. Пока службы стоят, процессы продолжают работать, а новых запусков и проверок нет.
3. Время `renewTime` отстаёт от текущего больше чем на 50 с, при том что kubelet продлевает Lease примерно раз в 10 с.
4. Радиус поражения зависит от подов на узле. Единственная реплика критичного компонента (Envoy, БД) превращает отказ узла в отказ сервиса для пользователей.

</details>

### Лабораторная работа 2. API-сервер и scheduler выключены

Эту работу вы выполняете сами, результаты в ней — ожидаемые. Числа в разборе взяты из замера на тестовом стенде.

**Риски.** Работа выключает scheduler и API-сервер в узле control plane стенда.

- **Что меняется:** внутри контейнера `lab-control-plane` манифесты `kube-scheduler.yaml` и `kube-apiserver.yaml` переносятся из `/etc/kubernetes/manifests` в `/root` и обратно. Kubelet узла останавливает и запускает static pod.
- **Надолго ли:** пока файл вне каталога, компонент стоит; сам он не вернётся. Работа занимает 5–10 минут. Во время шагов 3–4 kubectl не работает.
- **Безопасность:** привилегий сверх `docker exec` не нужно, секреты и порты не затрагиваются.
- **Влияние на систему:** новые поды всех пользователей стенда зависают в Pending, пока scheduler выключен; деплой и изменения невозможны, пока выключен API-сервер. Приложение `orders` продолжает отвечать. Не запускайте другие работы параллельно.
- **Откат:** `docker exec lab-control-plane sh -c 'mv /root/kube-*.yaml /etc/kubernetes/manifests/'`. Затем в каталоге манифестов должно быть четыре файла.

**Цель.** Отличить остановленный scheduler от нехватки места по признаку «Pending без событий» и пройти диагностику без kubectl, когда API-сервер выключен.

**Что понадобится.**

- Стенд 00-1 с приложением `orders`, подготовка работы 1 (namespace `lab-11-4`, функция `k`).
- Образ `busybox:1.37`.

**Схема опыта.**

```
шаги 1–2   scheduler off ─► Pending без событий, Lease стареет ─► scheduler on ─► Scheduled
                            (контраст: FailedScheduling, когда scheduler жив)
шаги 3–5   API-сервер off ─► kubectl: refused, трафик идёт ─► диагностика на узле ─► on
```

Схема 5. Два выключения одного узла control plane. Сравните, какие признаки видит kubectl и что остаётся доступным на узле.

Подготовьте переменную для узла control plane:

```bash
CP=lab-control-plane
```

#### Шаг 1. Выключить scheduler

Команды переносят манифест scheduler, создают под без привязки к узлу и читают его состояние, события, Lease и процесс на узле.

```bash
docker exec $CP mv /etc/kubernetes/manifests/kube-scheduler.yaml /root/
sleep 15
k run p1 --image=busybox:1.37 --restart=Never -- sleep 3600
sleep 10
k get pod p1
k get events --field-selector involvedObject.name=p1
kubectl -n kube-system get lease kube-scheduler \
  -o jsonpath='{.spec.renewTime}{"\n"}'; date -u +%FT%TZ
docker exec $CP crictl ps --name kube-scheduler
```

| Часть команды | Значение |
|---|---|
| `mv … kube-scheduler.yaml /root/` | остановить static pod: kubelet больше не видит файл |
| `k run p1 … sleep 3600` | создать под без `nodeName` |
| `--field-selector involvedObject.name=p1` | события только этого пода |
| `get lease kube-scheduler` | аренда лидера scheduler |
| `crictl ps --name kube-scheduler` | работающие контейнеры scheduler на узле |

Результат (времена ваши; важна разница):

```
NAME   READY   STATUS    RESTARTS   AGE
p1     0/1     Pending   0          10s
No resources found in lab-11-4 namespace.
2026-10-19T09:20:14.301552Z
2026-10-19T09:20:41Z
CONTAINER   IMAGE   CREATED   STATE   NAME   ATTEMPT   …
```

Разбор:

1. `Pending` и событий нет вовсе: ни `Scheduled`, ни `FailedScheduling`. Никто не пытался планировать под.
2. `renewTime` отстаёт на десятки секунд: scheduler обновлял бы Lease каждые 2 с.
3. `crictl ps` печатает только заголовок: работающего контейнера scheduler на узле нет.

#### Шаг 2. Вернуть scheduler и сравнить с нехваткой места

Команды возвращают манифест, ждут запуска `p1`, читают события и создают под `p2` с несуществующим селектором узла.

```bash
docker exec $CP mv /root/kube-scheduler.yaml /etc/kubernetes/manifests/
k wait --for=jsonpath='{.status.phase}'=Running pod/p1 --timeout=60s
k get events --field-selector involvedObject.name=p1 \
  -o custom-columns=REASON:.reason,FROM:.source.component
k run p2 --image=busybox:1.37 --restart=Never \
  --overrides='{"spec":{"nodeSelector":{"lab-11-4/none":"x"}}}' -- sleep 3600
sleep 5
k get events --field-selector involvedObject.name=p2 \
  -o custom-columns=REASON:.reason,MESSAGE:.message
```

| Часть команды | Значение |
|---|---|
| `mv /root/… /etc/kubernetes/manifests/` | вернуть файл: kubelet запустит scheduler |
| `wait --for=jsonpath='{.status.phase}'=Running` | ждать, пока `p1` станет Running |
| `custom-columns=REASON:…,FROM:…` | причина события и его источник |
| `nodeSelector: {lab-11-4/none: x}` | метка, которой нет ни на одном узле |

Результат (сообщение сокращено):

```
pod/p1 condition met
REASON      FROM
Scheduled   default-scheduler
Pulled      kubelet
Created     kubelet
Started     kubelet
REASON             MESSAGE
FailedScheduling   0/4 nodes are available: … 3 node(s) didn't match Pod's node affinity/selector. …
```

Разбор:

1. `Scheduled` от `default-scheduler`: после возврата файла scheduler сразу взял накопленный под. В замере событие появилось через 3 с.
2. Дальше идут события kubelet: образ уже был на узле.
3. У `p2` событие `FailedScheduling` есть и называет причину по узлам. Это контраст: scheduler жив, но места нет. «Pending без событий» и «Pending с `FailedScheduling`» ведут в разные места.

#### Шаг 3. Выключить API-сервер

Команды переносят манифест API-сервера и пробуют два запроса: к API и к приложению через Gateway.

```bash
docker exec $CP mv /etc/kubernetes/manifests/kube-apiserver.yaml /root/
sleep 20
kubectl get nodes
for i in $(seq 1 30); do
  curl -s -m 5 -o /dev/null -w '%{http_code} ' http://orders.localhost:8088/api/orders
done; echo
```

| Часть команды | Значение |
|---|---|
| `mv … kube-apiserver.yaml /root/` | остановить API-сервер |
| `kubectl get nodes` | запрос к API |
| `seq 1 30` | тридцать запросов подряд |
| `-w '%{http_code} '` | печатать код ответа |

Результат (первая строка перенесена; адрес в сообщении kubectl у вас другой):

```
The connection to the server lab-control-plane:6443 was refused -
did you specify the right host or port?
200 200 200 200 200 200 200 200 200 200 …
```

Разбор:

1. `connection refused`: порт никто не слушает, процесса API-сервера нет (раздел 5).
2. Все 30 запросов вернули 200 (в выводе показаны первые десять): Envoy, kube-proxy, поды и PostgreSQL не зависят от API-сервера.
3. Управление кластером недоступно: kubectl, деплой и замена упавших подов не работают.

#### Шаг 4. Диагностика на узле без kubectl

Команды находят контейнер API-сервера, каталог его логов и жалобу kubelet на недоступный API.

```bash
docker exec $CP crictl ps -a --name kube-apiserver
docker exec $CP sh -c 'ls /var/log/pods | grep apiserver'
docker exec lab-worker journalctl -u kubelet --since -1min --no-pager | grep -m1 lease
```

| Часть команды | Значение |
|---|---|
| `crictl ps -a --name kube-apiserver` | все контейнеры API-сервера, и остановленные |
| `ls /var/log/pods \| grep apiserver` | каталог логов static pod |
| `journalctl -u kubelet … grep -m1 lease` | первая строка про lease в журнале worker |

Результат (сокращён):

```
CONTAINER   IMAGE   CREATED   STATE    NAME             ATTEMPT   …
…           …       …         Exited   kube-apiserver   0         …
kube-system_kube-apiserver-lab-control-plane_…
… Failed to ensure lease exists, will retry …
```

Разбор:

1. Контейнер в состоянии `Exited`: его остановил kubelet после переноса манифеста. При падении процесса вы увидели бы то же состояние, а причину нашли бы в `crictl logs` или в каталоге из второй строки. Сборщик мёртвых контейнеров kubelet удаляет контейнер и каталог логов удалённого пода примерно через минуту, поэтому при медленном выполнении эти строки могут пропасть.
2. Kubelet worker'а пишет, что не может обновить Lease узла. Он накапливает ошибки, но ничего не убивает.

#### Шаг 5. Вернуть API-сервер

Команды возвращают манифест, ждут готовности и проверяют состояние подов.

```bash
docker exec $CP mv /root/kube-apiserver.yaml /etc/kubernetes/manifests/
SECONDS=0
until kubectl get --raw /readyz >/dev/null 2>&1; do sleep 1; done
echo "readyz ok через $SECONDS с"
kubectl get --raw '/readyz?verbose' | tail -1
k get pods
```

| Часть команды | Значение |
|---|---|
| `mv /root/… /etc/kubernetes/manifests/` | вернуть файл |
| `until kubectl get --raw /readyz` | ждать успешного ответа API |
| `readyz?verbose \| tail -1` | итоговая строка проверок |
| `k get pods` | поды работы |

Результат:

```
readyz ok через 4 с
readyz check passed
NAME   READY   STATUS    RESTARTS   AGE
p1     1/1     Running   0          5m
p2     0/1     Pending   0          4m
```

Разбор:

1. API-сервер ответил через 4 с: образ уже был на узле.
2. Строка `readyz check passed` значит, что все проверки прошли, включая etcd.
3. `p1` пережил отключение без изменений. `p2` остаётся Pending по своей причине, не связанной с отключением.

**Итог.**

| Что узнали | Где видно |
|---|---|
| Pending без событий — признак остановленного scheduler | шаг 1 |
| Lease лидера перестаёт обновляться | шаг 1, `renewTime` |
| `FailedScheduling` значит, что scheduler жив | шаг 2, `p2` |
| Без API-сервера трафик идёт, а kubectl нет | шаг 3 |
| Причину падения API-сервера ищут через `crictl` и `/var/log/pods` | шаг 4 |
| После возврата API готов за секунды | шаг 5 |

**Уборка.** Проверяем, что все четыре манифеста на месте.

```bash
docker exec $CP ls /etc/kubernetes/manifests
docker exec $CP ls /root
k delete pod p1 p2 --now
```

Первая команда должна показать четыре файла: `etcd.yaml`, `kube-apiserver.yaml`, `kube-controller-manager.yaml`, `kube-scheduler.yaml`. Вторая не должна показывать файлов `kube-*.yaml`. Если файл остался в `/root`, верните его командой `mv` из соответствующего шага. Третья удаляет поды работы.

**Вопросы для самопроверки.**

1. Под в Pending, событий нет. Какой компонент проверять первым?
2. Чем это отличается от `FailedScheduling`?
3. Почему при выключенном API-сервере 30 запросов из 30 вернули 200?
4. Где читать логи API-сервера, если kubectl не работает?

<details>
<summary>Ответ</summary>

1. Scheduler: сначала Lease `kube-scheduler` и процесс через `crictl ps` на узле control plane. Затем проверьте, не указан ли в поде чужой `schedulerName`.
2. `FailedScheduling` пишет сам scheduler: он пытался и не нашёл узел. Отсутствие любых событий значит, что под никто не обработал.
3. Трафик идёт через Envoy, kube-proxy и поды. Эти части data plane не обращаются к API-серверу во время работы.
4. На узле control plane: `crictl logs <id>` и файлы в `/var/log/pods/kube-system_kube-apiserver-…/`.

</details>

### Лабораторная работа 3. Состояние etcd и ephemeral storage

Эту работу вы выполняете сами, результаты в ней — ожидаемые. Числа в разборе взяты из замера на тестовом стенде.

**Риски.**

- **Что меняется:** etcd и API-сервер только читаются, ничего не останавливается. Под `eph` записывает 50 МиБ в слой записи контейнера на одном из узлов kind.
- **Надолго ли:** пока существует под; уборка удаляет его.
- **Безопасность:** привилегий сверх `docker exec` не нужно.
- **Влияние на систему:** 50 МиБ занимают место на разделе хоста; другие поды узла не затрагиваются, потому что выселяется только `eph`.
- **Откат:** `kubectl -n lab-11-4 delete pod eph --now`.

**Цель.** Прочитать состояние etcd и метрики API-сервера, увидеть, что kind отключает пороги диска, и отличить выселение по лимиту пода от давления на узел.

**Что понадобится.**

- Стенд 00-1, подготовка работы 1 (namespace `lab-11-4`, функция `k`, переменная `NODE`).
- Доступ к `docker exec` на узлы, образ `busybox:1.37`.

**Схема опыта.**

```
шаг 1   etcd:        /livez/etcd (со стороны API) + etcdctl health, status, alarm
шаг 2   API-сервер:  метрики inflight, rejected, storage
шаг 3   узел kind:   evictionHard, imageGC в config.yaml
шаги 4–5  под eph с лимитом 20Mi ─► Evicted, DiskPressure=False, диск узла
```

Схема 6. Три проверки состояния и один опыт с выселением. Сравните условие DiskPressure узла и статус выселенного пода.

#### Шаг 1. Здоровье etcd с двух сторон

Команды проверяют etcd через API-сервер и через etcdctl внутри пода etcd (карточка etcdctl — в 01-1 §4). Функция `ecs` собирает адрес и сертификаты.

```bash
ecs() { kubectl -n kube-system exec etcd-lab-control-plane -- etcdctl \
  --endpoints=https://127.0.0.1:2379 --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt --key=/etc/kubernetes/pki/etcd/server.key "$@"; }
kubectl get --raw /livez/etcd; echo
ecs endpoint health
ecs endpoint status -w table
ecs alarm list
```

| Часть команды | Значение |
|---|---|
| `kubectl get --raw /livez/etcd` | проверка etcd с точки зрения API-сервера |
| `endpoint health` | записать пробное значение и измерить время |
| `endpoint status -w table` | версия, размер базы, лидер, тревоги |
| `alarm list` | активные тревоги etcd |

Результат (таблица сокращена до нужных столбцов; цифры из замера):

```
ok
https://127.0.0.1:2379 is healthy: successfully committed proposal: took = 5.022125ms
| VERSION | DB SIZE | IN USE | QUOTA  | IS LEADER | ERRORS |
| 3.6.8   | 9.0 MB  | 5.5 MB | 2.1 GB | true      |        |
```

Команда `alarm list` ничего не печатает.

Разбор:

1. `ok` от `/livez/etcd`: API-сервер видит etcd.
2. `took = 5.022125ms` — время записи. На SSD это единицы миллисекунд; десятки миллисекунд указывают на медленный диск (10-2 §5).
3. `DB SIZE` 9,0 МБ при квоте 2,1 ГБ (2 ГиБ): до `NOSPACE` далеко.
4. Пустой `alarm list` и пустой `ERRORS` — тревог нет.

#### Шаг 2. Метрики API-сервера

Команда читает три метрики из `/metrics` API-сервера.

```bash
kubectl get --raw /metrics | grep \
  -e '^apiserver_current_inflight_requests' \
  -e '^apiserver_flowcontrol_rejected_requests_total' \
  -e '^apiserver_storage_size_bytes'
```

| Часть команды | Значение |
|---|---|
| `get --raw /metrics` | метрики API-сервера в текстовом формате |
| `grep -e '^имя' …` | оставить строки трёх метрик |

Результат (значения inflight у вас другие):

```
apiserver_current_inflight_requests{request_kind="mutating"} 0
apiserver_current_inflight_requests{request_kind="readOnly"} 1
apiserver_storage_size_bytes{…} 9.02e+06
```

Разбор:

1. `inflight` показывает запросы в обработке: далеко от предела 200 на изменения и 400 на чтение.
2. `apiserver_storage_size_bytes` совпадает с `DB SIZE` из шага 1: 9,02e+06 байт.
3. Строк `rejected_requests_total` нет: APF ещё никого не отклонял. У счётчика с метками строка появляется только после первого отказа с ответом 429.

#### Шаг 3. Пороги диска в kind

Команды читают конфигурацию kubelet на узле: пороги выселения и сборку образов.

```bash
docker exec $NODE grep -A3 '^evictionHard' /var/lib/kubelet/config.yaml
docker exec $NODE grep imageGC /var/lib/kubelet/config.yaml
```

| Часть команды | Значение |
|---|---|
| `grep -A3 '^evictionHard'` | ключ и три следующие строки |
| `grep imageGC` | пороги сборки образов, если они заданы |

Результат:

```
evictionHard:
  imagefs.available: 0%
  nodefs.available: 0%
  nodefs.inodesFree: 0%
imageGCHighThresholdPercent: 100
```

Разбор:

1. Все пороги диска равны `0%`: kubelet не выселит поды по давлению диска, пока диск не кончится совсем.
2. `imageGCHighThresholdPercent: 100` выключает сборку неиспользуемых образов.
3. На стенде `DiskPressure` недостижим. На рабочем узле здесь стояли бы 10 %, 5 % и 15 % (05-5 §6).

#### Шаг 4. Выселение по лимиту пода

Команда создаёт под, который пишет 50 МиБ при лимите 20 МиБ. Затем читает фазу, причину и сообщение, а также условие `DiskPressure` узла, где он работал.

```bash
k apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata: {name: eph}
spec:
  restartPolicy: Never
  containers:
  - name: app
    image: busybox:1.37
    command: ["sh", "-c", "dd if=/dev/zero of=/data.bin bs=1M count=50; sleep 3600"]
    resources: {limits: {ephemeral-storage: 20Mi}}
EOF
sleep 25
k get pod eph
k get pod eph -o jsonpath='{.status.phase} {.status.reason}: {.status.message}{"\n"}'
EN=$(k get pod eph -o jsonpath='{.spec.nodeName}')
kubectl get node $EN -o jsonpath='{.status.conditions[?(@.type=="DiskPressure")].status}{"\n"}'
```

| Часть команды | Значение |
|---|---|
| `limits: {ephemeral-storage: 20Mi}` | лимит локального диска пода 20 МиБ |
| `dd … bs=1M count=50` | записать 50 МиБ в слой записи контейнера |
| `sleep 25` | подождать выселения |
| `{.status.phase} {.status.reason}: …` | фаза, причина и сообщение пода |
| `EN=$(… spec.nodeName)` | узел, на котором работал под |
| `DiskPressure")].status` | условие давления диска у этого узла |

Результат (сообщение одной строкой):

```
NAME   READY   STATUS   RESTARTS   AGE
eph    0/1     Error    0          25s
Failed Evicted: Pod ephemeral local storage usage exceeds the total limit of containers 20Mi.
False
```

Разбор:

1. STATUS `Error`, а настоящая причина в `status.reason` — `Evicted` (05-2).
2. Сообщение называет превышенный лимит: 20 МиБ. Запись удалась, потому что диск ядро не ограничивает: под убрал kubelet после измерения. В замере выселение заняло 10–25 с.
3. `DiskPressure` узла равен `False`: давления на узел нет, выселен один под, и это источник «лимит пода» со схемы 3.

#### Шаг 5. Где на узле занят диск

Команды читают занятость диска и inode на узле, где работал под, и крупнейшие каталоги логов. Они ничего не меняют.

```bash
docker exec $EN df -h /var/lib/containerd /var/lib/kubelet
docker exec $EN df -i /var/lib/kubelet
docker exec $EN sh -c 'du -sh /var/log/pods/* | sort -h | tail -3'
```

| Часть команды | Значение |
|---|---|
| `df -h /var/lib/containerd /var/lib/kubelet` | занятость байт на двух ключевых каталогах |
| `df -i /var/lib/kubelet` | занятость inode |
| `du -sh /var/log/pods/* \| sort -h \| tail -3` | три самых больших каталога логов |

Результат (числа у вас свои, показан только формат):

```
Filesystem      Size  Used Avail Use% Mounted on
…
Filesystem      Inodes   IUsed    IFree IUse% Mounted on
…
…K  /var/log/pods/kube-system_…
```

Разбор:

1. В колонке `Use%` видно, далеко ли узел от порога `nodefs.available` (10 % свободного).
2. Колонка `IUse%` показывает inode: исчерпание вызывает те же симптомы, что и нехватка байт.
3. На стенде kind эти каталоги лежат на диске хоста, поэтому свободное место хоста проверяют отдельно (`docker system df`, `df -h`).

**Итог.**

| Что узнали | Где видно |
|---|---|
| Здоровье etcd видно с двух сторон | шаг 1, `/livez/etcd` и `endpoint health` |
| Размер базы совпадает в etcdctl и в метрике API | шаги 1–2 |
| kind отключает пороги диска | шаг 3, `0%` |
| Выселение по лимиту пода не меняет условия узла | шаг 4, `DiskPressure False` |
| Диск узла читают через `df` и `du` на узле | шаг 5 |

**Уборка.** Удаляем под, namespace, функции и переменные, затем проверяем стенд.

```bash
k delete pod eph --now
kubectl delete ns lab-11-4
unset -f k ecs
unset NODE CP EN
kubectl get nodes
curl -s -o /dev/null -w '%{http_code}\n' http://orders.localhost:8088/api/orders
```

Команды удаляют все объекты работы 3, namespace со всем содержимым и временные функции. `kubectl get nodes` должен показать все узлы Ready, а `curl` — код 200.

**Вопросы для самопроверки.**

1. Какие два сигнала подтверждают, что etcd здоров?
2. Почему на стенде kind нельзя получить `DiskPressure`?
3. Как по статусу выселенного пода отличить лимит пода от давления на узел?
4. Почему отсутствие строки `rejected_requests_total` — хороший признак?

<details>
<summary>Ответ</summary>

1. `ok` от `/livez/etcd` со стороны API-сервера и `is healthy` с коротким `took` от `endpoint health`; `alarm list` при этом пуст.
2. Конфигурация kubelet в kind задаёт пороги диска `0%`, а сборка образов выключена. Узел не считает диск заполненным.
3. Сообщение выселенного пода называет собственный лимит (`exceeds the total limit of containers 20Mi`), а условие `DiskPressure` узла остаётся False. При давлении на узел условие True, у узла есть taint `disk-pressure`.
4. Метрика появляется после первого отказа. Её отсутствие значит, что APF пока никого не отклонял.

</details>

---

## → Дальше

Эта часть завершает модуль 11: от пода (11-2) и сети (11-3) поиск дошёл до узла и control plane. Правило «снаружи внутрь» и умение отличать Unknown от False работают на любом уровне. Модуль 12 опирается на этот порядок. Он начинается с банка вопросов (12-1): вопросы проверяют, назовёт ли кандидат признак, компонент и первую команду, а эталоны ссылаются на части этого модуля. Тренажёры «сломай и почини» (12-2) дают те же поломки без подсказок и в массовом виде, поэтому подготовка к собеседованию идёт сразу после диагностики.
