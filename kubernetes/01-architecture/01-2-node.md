# 01-2. Узел: kubelet, CRI, CNI, kube-proxy

> Модуль 01 «Архитектура» · часть 2 из 3 · ~1,5 ч чтения + ~1 ч лабы (из них 7 мин — ожидание вытеснения) · Нужно: стенд 00-1 (контекст `kind-lab`), crictl из 00-2, доступ узлов к образу `busybox:1.37` · Опирается на: 01-1 (control plane)

## Где мы на карте

В 01-1 мы разобрали control plane: API-сервер принимает объекты, scheduler выбирает узел, controller-manager держит желаемое состояние. Все они только читают и пишут записи в API. Эта часть показывает, кто превращает запись «под P на узле N» в работающий процесс: компоненты узла kubelet, containerd, CNI-плагины и kube-proxy.

Следующая часть, 01-3, вернётся к API и разберёт сами объекты: метки, владельцев, apply и finalizers. А всё, что запускают в кластере, упирается в узел: под (02-1), Service (03-2), тома (04-2) и лимиты (05-1) работают через механизмы, которые описаны здесь.

```
   control plane (01-1)    решает: под P → узел N, пишет в API
          │ watch
   ┌──────▼──────────────────────────────────────────────────┐
   │ узел N                                                   │
   │  kubelet ─CRI─► containerd ─► shim ─► runc ─► процесс    │
   │     │               └─ CNI-плагины ─► интерфейс и IP     │
   │     └─ статус и Lease ─► apiserver                       │
   │  kube-proxy ─► правила Service (03-2)                    │
   └──────────────────────────────────────────────────────────┘
```

Схема 1. Что стоит на узле. Стрелки показывают, кто кого вызывает; вверх от kubelet идут только статусы и heartbeat.

---

## 1. Какую задачу решает узел

Узел превращает записи в API в процессы и следит, чтобы они жили. Разберём, что на нём работает и почему для этого не нужен Docker.

### От записи в API к процессу в ядре

Когда scheduler записывает в под поле `spec.nodeName`, в кластере появляется только строка в etcd, а процесса ещё нет. Узел (00-1) — машина, физическая или виртуальная, на которой работают поды. kubelet (00-2) — агент на каждом узле: он следит за подами, назначенными его узлу, и приводит узел в соответствие с записью.

kubelet запускает контейнеры через рантайм, монтирует тома, выполняет пробы (02-5) и перезапускает упавшие контейнеры по `restartPolicy`. Он пишет в API статус подов и узла и регулярно сообщает «я жив». Если kubelet молчит, control plane считает узел потерянным (§5).

### Что ещё стоит на узле

Кроме kubelet, на узле работают пять компонентов, и у каждого своя задача.

- **containerd** (00-1) — **контейнерный рантайм** (container runtime): служба, которая хранит образы и запускает контейнеры; работает как systemd-служба.
- **runc** — **OCI runtime**: программа, которая создаёт процесс в нужных namespaces и cgroups. **OCI** (Open Container Initiative) — стандарт формата образа и запуска контейнера.
- **CNI-плагины** — бинарники в `/opt/cni/bin` с конфигом в `/etc/cni/net.d`. Они дают поду интерфейс, IP и маршруты (§2).
- **kube-proxy** — агент, который пишет на узле правила iptables, nftables или ipvs для Service (03-2); работает как DaemonSet.
- **CNI-агент** (kindnet на стенде, Calico, Cilium) — тоже DaemonSet: раздаёт подсети, строит маршруты и применяет NetworkPolicy (03-6).

**DaemonSet** — контроллер, который держит ровно один под на каждом узле (02-4). Поэтому kube-proxy и CNI-агент видны как обычные поды в `kube-system`, хотя работают на уровне узла.

### Docker на узле не нужен

Раньше kubelet умел говорить только с Docker через встроенный слой dockershim, но с версии 1.24 этот слой удалён. Теперь kubelet общается с любым рантаймом по единому интерфейсу CRI (Container Runtime Interface, 00-2; устройство — в §2). На стенде работает containerd 2.3.1, требования к его версии — в §6.

Образы, собранные Docker'ом, продолжают работать: это обычные OCI-образы, и меняется только то, кто их запускает. Отсюда практическое следствие: на узле команда `docker ps` ничего не покажет, контейнеры смотрят через `crictl` (карточка инструмента — 00-2).

---

## 2. Как устроен узел

Разберём цепочку вызовов от kubelet до процесса, затем sandbox пода, путь пода до статуса Running, получение IP и heartbeat.

### Цепочка kubelet → containerd → runc

CRI — это gRPC-интерфейс между kubelet и рантаймом из двух служб: одна управляет sandbox'ами и контейнерами, другая — образами. kubelet подключается к unix-сокету рантайма; у containerd это `/run/containerd/containerd.sock`.

Сам containerd процессы не создаёт. Для каждого sandbox он запускает **shim** — маленький процесс-посредник, который держит ввод-вывод контейнеров и запоминает код выхода. Shim вызывает runc, а runc делает системные вызовы, создаёт namespaces и cgroups и запускает процесс. Поэтому перезапуск kubelet или containerd не убивает контейнеры: они живут под присмотром shim.

```
kubelet ──CRI (gRPC, unix-сокет)──► containerd ──► shim ──► runc ──► процесс пода
                                        │
                                        └──► CNI-плагины ──► veth, IP, маршруты
```

Схема 2. Цепочка запуска. runc выходит сразу после старта процесса; shim остаётся и держит контейнер.

### Sandbox и контейнер pause

**Namespace ядра** (Linux namespace) — механизм ядра, который даёт процессам собственный вид ресурса: сеть, список процессов (PID), IPC, точки монтирования. Это не namespace Kubernetes: слова совпадают, смысл разный.

**Sandbox** пода (pod sandbox) — набор общих namespaces, в которых работают контейнеры пода. Его держит крошечный процесс `/pause` (образ `registry.k8s.io/pause:3.10` на стенде), который ничего не делает: создаёт сетевой namespace и ждёт.

Контейнеры пода присоединяются к namespaces pause: общими становятся сеть (IP, порты, `localhost`) и IPC, а PID и файловая система остаются раздельными. Флаг `shareProcessNamespace: true` объединяет и PID-namespace: тогда PID 1 — pause, и сигналы ведут себя иначе. Отладочный контейнер `kubectl debug --target` присоединяется к PID-namespace одного контейнера (00-2).

Pause нужен потому, что контейнер приложения может упасть и перезапуститься. Если бы namespace принадлежал ему, при каждом перезапуске исчезали бы IP и сетевое состояние пода. Pause живёт, пока жив под, поэтому IP, правила kube-proxy и endpoints не меняются при перезапусках.

```
      sandbox пода (процесс /pause держит net и IPC)
   ┌──────────────────────────────────────────────┐
   │ pause   ── net:[4026534532]                  │
   │ api     ── net:[4026534532]  ← тот же netns  │
   │         ── pid:[…599]        ← свой pid-ns   │
   └──────────────────────────────────────────────┘
```

Схема 3. Pause и контейнер приложения делят сетевой namespace и различаются по PID. Номера взяты из лабораторной работы 1.

### Путь пода от привязки до Running

Получив под с `nodeName`, kubelet проходит фиксированную последовательность шагов. По тому, где остановился под, видно, какой шаг сломан.

```
apiserver: pod.spec.nodeName = lab-worker3
   │ watch
kubelet: syncPod
   1. проверка на узле (ресурсы, nodeSelector, taints) — последний барьер
   2. cgroup пода (по QoS-классу, 05-1)
   3. тома: Secret, ConfigMap, PVC — смонтировать и дождаться attach (04-2)
   4. CRI RunPodSandbox → containerd → pause + CNI ADD → IP
   5. pull образов (imagePullPolicy, секреты реестра)
   6. init-контейнеры по очереди, затем sidecar, затем основные (02-1)
   7. пробы: startup → readiness и liveness (02-5)
   8. статус → apiserver: PodReadyToStartContainers, Initialized, Ready
```

Схема 4. Работа kubelet над одним подом. Условие `PodReadyToStartContainers` ставится после шага 4: песочница и сеть готовы.

### Откуда у пода IP: CNI

**CNI** (Container Network Interface) — стандарт, по которому рантайм вызывает сетевой плагин. Когда containerd создаёт sandbox, он читает конфиг из `/etc/cni/net.d` и запускает указанные плагины с командой ADD и путём к netns пода. На стенде работает kindnet (сокращённый конфиг):

```json
{ "cniVersion": "0.3.1", "name": "kindnet",
  "plugins": [
    { "type": "ptp", "ipam": { "type": "host-local",
        "ranges": [[ { "subnet": "10.244.1.0/24" } ]] }, "mtu": 1500 },
    { "type": "portmap", "capabilities": { "portMappings": true } } ] }
```

Разбор:

1. `ptp` — плагин создаёт **veth-пару**: два виртуальных сетевых интерфейса, соединённых напрямую. Один конец лежит в netns пода, другой на узле.
2. `host-local` — модуль **IPAM** (IP address management): выдаёт адрес из подсети узла `10.244.1.0/24`.
3. `portmap` — открывает `hostPort` пода на узле.

Подсеть узла берётся из поля `spec.podCIDR` объекта Node, а таблица маршрутов узла `lab-worker3` (сокращена) показывает, как достичь подов:

```
default via 172.20.0.1 dev eth0
10.244.0.0/24 via 172.20.0.2 dev eth0       ← подсеть другого узла: через его IP
10.244.1.3 dev vethc3005564 scope host       ← под на этом узле: прямо в veth
10.244.1.5 dev veth6a79cd61 scope host
10.244.2.0/24 via 172.20.0.3 dev eth0
10.244.3.0/24 via 172.20.0.5 dev eth0
```

Модель Kubernetes требует, чтобы каждый под получал IP и поды видели друг друга без NAT. Как это сделано, решает плагин: маршруты (kindnet, Calico в режиме BGP), оверлей VXLAN или Geneve, eBPF (Cilium). Трассировка пакета и сравнение вариантов — 03-1.

### Heartbeat: Lease и статус узла

Узел сообщает о себе двумя способами, и оба идут от kubelet к API-серверу.

Lease (аренда, 01-1 §2) — маленький объект в namespace `kube-node-lease`, по одному на узел. kubelet продлевает его примерно каждые 10 с (четверть срока аренды 40 с), меняя только поле `renewTime`. Объект крошечный, поэтому heartbeat почти ничего не стоит.

**Статус узла** (`node.status`) — крупный объект с условиями (Ready, MemoryPressure, DiskPressure, PIDPressure), ресурсами и списком образов. kubelet проверяет его каждые 10 с, а полную запись отправляет при изменении или раз в 5 минут.

Роль судьи играет **node lifecycle controller** в controller-manager. Если Lease не обновлялся дольше `node-monitor-grace-period` (50 с), он ставит условию Ready значение Unknown; что происходит дальше, разбирает §5.

---

## 3. Как управлять узлом

Параметры узла задаёт конфиг kubelet, раскладкой ресурсов управляет драйвер cgroups, локальными подами — каталог static pods, а логами и образами — настройки ротации и сборки мусора.

### Конфигурация kubelet

Конфиг kubelet — YAML-файл вида **KubeletConfiguration**. Путь передаёт флаг `--config`; в kubeadm и kind это `/var/lib/kubelet/config.yaml`. Параметры из файла — `nodeStatusUpdateFrequency`, `maxPods`, `evictionHard`, `cgroupDriver` — проверяются при старте. Чтобы применить правку, перезапускают службу `systemctl restart kubelet`, и контейнеры при этом продолжают работать, потому что их держит shim. С 1.35 kubelet после перезапуска восстанавливает состояние контейнеров и не сбрасывает готовность подов.

Кроме основного файла, kubelet читает **drop-in каталог** (drop-in directory) — каталог с дополнительными файлами конфигурации, который задаёт флаг `--config-dir` (stable с 1.35). Файлы с суффиксом `.conf` из него применяются по алфавиту поверх основного конфига. Так правку держат отдельным файлом и не трогают файл, который пишет kubeadm.

Эффективные значения с учётом умолчаний, флагов и drop-in файлов видны только в работающем kubelet (§4), поэтому после правки значение проверяют там, а не по файлу.

### Драйвер cgroups и раскладка по QoS

**cgroup** (control group) — механизм ядра, который объединяет процессы в группу и ограничивает её ресурсы: память, CPU, число процессов. kubelet создаёт cgroup для каждого пода и каждого контейнера, а лимиты из манифеста превращаются в значения файлов этой иерархии (05-1).

**QoS-класс** (quality of service) — категория пода по его requests и limits: Guaranteed, Burstable, BestEffort. Поды раскладываются в ветки по классу, чтобы при нехватке памяти ядро и kubelet выбирали жертву предсказуемо (05-5).

**Драйвер cgroups** (cgroup driver) определяет, кто создаёт эти группы: сам kubelet (`cgroupfs`) или systemd (`systemd`). Драйвер kubelet и рантайма обязан совпадать, иначе два менеджера работают с одной иерархией, и под нагрузкой узел ведёт себя непредсказуемо. На дистрибутивах с systemd (Ubuntu, Manjaro) выбирают `systemd`, в containerd это `SystemdCgroup = true`.

С 1.34 (stable) kubelet сам узнаёт драйвер у рантайма через вызов CRI `RuntimeConfig`, и при поддержке этого вызова рассогласование исключено. Поле `cgroupDriver` в конфиге kubelet при этом игнорируется и нужно только как запасной вариант для старых рантаймов. Вызов поддерживают containerd 2.0+ и CRI-O 1.28+, поэтому настраивают драйвер теперь в одном месте — в рантайме.

### Static pods

Static pod (статический под, 00-2) — под, который kubelet запускает из файла, без scheduler и без API-сервера. Каталог указывает параметр `staticPodPath`; на стенде это `/etc/kubernetes/manifests` на всех узлах. kubelet перечитывает каталог раз в 20 с (`fileCheckFrequency`): появился файл — запускается под, исчез — останавливается.

Чтобы под был виден в кластере, kubelet создаёт в API его копию — mirror pod (зеркальный под, 01-1 §2). У зеркального пода к имени добавлен суффикс узла, а владелец в `ownerReferences` — объект Node. Зеркало только отражает файл: `kubectl delete` удалит его, но kubelet создаст зеркало заново, а контейнер останется прежним. Остановить static pod можно только удалением файла на узле.

Так запущен control plane в kubeadm: API-сервер, scheduler и controller-manager — static pods. Это удобно для компонентов, которые должны работать до того, как кластер начнёт принимать объекты.

Это же и риск: файл в каталоге манифестов на любом узле запускает под в обход RBAC и admission-проверок. Admission-плагин `NodeRestriction` запрещает зеркальным подам ссылаться на Secret, ConfigMap и ServiceAccount, а в 1.37 такие static pods отклоняет и сам kubelet. Но под с `hostPath` это не остановит, поэтому права на запись в `/etc/kubernetes/manifests` приравнивают к правам root на узле.

### Логи контейнеров и образы

kubelet через containerd пишет stdout и stderr контейнера в файл `/var/log/pods/<ns>_<под>_<uid>/<контейнер>/N.log`. Каталог `/var/log/containers/` содержит симлинки на эти файлы, и из него читают агенты сбора логов (Fluent Bit, Promtail). Ротацию делает kubelet: файл растёт до `containerLogMaxSize` (10Mi по умолчанию), хранится до `containerLogMaxFiles` файлов (по умолчанию 5). Логи удаляются вместе с подом.

Образы чистит **сборка мусора образов** (image GC). Когда диск заполнен выше `imageGCHighThresholdPercent` (по умолчанию 85%), kubelet удаляет неиспользуемые образы, пока занятость не упадёт до `imageGCLowThresholdPercent` (80%). Образы тянутся по одному, потому что параметр `serializeImagePulls` по умолчанию равен `true`, и один огромный образ из медленного реестра задерживает старт других подов узла.

---

## 4. Как увидеть состояние узла

Состояние узла видно с трёх сторон: из API, из рантайма на самом узле и из журналов.

### Узел глазами API

Команда `kubectl get nodes` показывает статус и версию. Подробности даёт `kubectl describe node <имя>`: блок Conditions со статусами Ready, MemoryPressure, DiskPressure, PIDPressure, блок Capacity и Allocatable и список подов узла. **Capacity** — все ресурсы машины, **Allocatable** — то, что остаётся подам после резервов системы и порога вытеснения (05-1, 05-5); в kind они совпадают.

Heartbeat читают из Lease: `kubectl -n kube-node-lease get lease <узел>`. Если `renewTime` старше минуты, kubelet молчит, и причину ищут на узле, а не в API.

### Конфигурация, которую применяет kubelet

kubelet отдаёт свою эффективную конфигурацию через эндпоинт `configz`. Запрос идёт через API-сервер как через прокси: `kubectl get --raw /api/v1/nodes/<узел>/proxy/configz`. Ответ содержит все параметры с умолчаниями. Запрос через прокси API-сервера требует права `nodes/proxy`; узкий подресурс `nodes/configz` (с 1.36) действует только при прямом обращении к kubelet на порт 10250 (06-1). Работа 2 показывает, как выбрать нужные поля через `jq`.

### Контейнеры и sandbox на узле

API знает только про поды, а что реально запущено, знает рантайм. Утилита `crictl` (карточка — 00-2) говорит с containerd по CRI: `crictl pods` показывает sandbox'ы, `crictl ps` — контейнеры, `crictl inspectp` — детали sandbox, включая IP и путь к netns. Узлы kind — контейнеры Docker, поэтому на них заходят через `docker exec`, а на обычный узел — по ssh с правами root.

### Раскладка cgroup

Дерево cgroup узла показывает `systemd-cgls`. На стенде kubelet сам работает внутри контейнера kind, поэтому к именам добавлен префикс `kubelet-` (сокращено):

```
kubelet.slice
├─kubelet.service
│ └─222 /usr/bin/kubelet ...
└─kubelet-kubepods.slice
  ├─kubelet-kubepods-pod01b8c840_….slice           ← Guaranteed: прямо в kubepods
  │ ├─cri-containerd-e6f0….scope  └─724 /bin/kindnetd
  │ └─cri-containerd-eec6….scope  └─466 /pause
  ├─kubelet-kubepods-besteffort.slice
  │ └─kubelet-kubepods-besteffort-pode619e41a_….slice
  │   ├─cri-containerd-b7c7….scope  └─480 /pause
  │   └─cri-containerd-906e….scope  └─559 /usr/local/bin/kube-proxy ...
  └─kubelet-kubepods-burstable.slice …
```

Схема 5. Ветки по QoS-классам. Под Guaranteed лежит прямо в `kubepods`, Burstable и BestEffort — в своих ветках. Каждый контейнер — отдельный `scope`.

**Slice** — узел иерархии systemd, группирующий cgroup. **Scope** — группа внешних процессов, которую systemd не запускал сам: containerd создаёт по одному scope на контейнер. На обычном узле путь короче: `/sys/fs/cgroup/kubepods.slice/kubepods-burstable.slice/kubepods-burstable-pod<uid>.slice/cri-containerd-<id>.scope`.

### Журналы компонентов

Журналы kubelet и containerd лежат в journald: `journalctl -u kubelet` и `journalctl -u containerd`, для kind — через `docker exec <узел>`. События пода (`kubectl describe pod`) показывают то, что kubelet отправил в API, а журнал — остальное, например жалобы на рантайм.

---

## 5. Что ломается и как найти причину

Поломки узла бывают двух видов: узел перестал отвечать, или под не проходит шаг запуска. Сначала разберём потерю узла, потому что она ломает больше всего и требует точных цифр.

### Узел потерял kubelet: хронология

Когда kubelet остановлен, контейнеры продолжают работать, потому что их держит containerd. Но control plane этого не видит: Lease не обновляется. Хронология с цифрами стенда (лабораторная работа 4):

| Момент | Что видно | Что сработало |
|---|---|---|
| 0 | kubelet остановлен, контейнеры живы | — |
| +10 с и дальше | время продления Lease не меняется | kubelet молчит |
| +53 с | узел Unknown, taint'ы unreachable | grace period 50 с |
| +53 с | поды узла не готовы, endpoints неготовы | endpoint-контроллеры |
| +353 с | поды помечены на удаление, создаются замены | toleration 300 с |

**Taint** (метка-запрет) — отметка на узле: новые поды на него не попадут, а текущие уйдут, если не терпят её. **Toleration** (терпимость) — запись в поде, которая позволяет терпеть taint.

Когда узел становится Unknown, node lifecycle controller вешает на него два taint'а: `node.kubernetes.io/unreachable:NoSchedule` и `unreachable:NoExecute`. Первый запрещает новые поды, второй вытесняет уже работающие.

Каждый под получает при создании toleration к `unreachable:NoExecute` на `tolerationSeconds: 300`, его добавляет admission-плагин `DefaultTolerationSeconds`. Через 300 с после taint'а под помечается на удаление, и его контроллер создаёт замену на другом узле. Итого с умолчаниями 50 + 300 ≈ 350 секунд, а замер на стенде показал +353 с.

### Почему сервис лёг, а процессы живы

Самое неприятное происходит на 53-й секунде, задолго до вытеснения. Поды узла становятся неготовыми, и их адреса исчезают из endpoint'ов. Если на узле работает единственная база данных, зависимый сервис теряет её, хотя процесс PostgreSQL при этом работает.

На стенде так и вышло: headless Service `postgres` перестал отдавать адрес в DNS, и orders-api, не подключившись к БД, ответил 503 на readiness. Оба пода orders-api выпали из Service, и сквозной запрос получил 503, хотя ни один процесс не упал.

Из этого следует правило проектирования: readiness, которая жёстко зависит от единственной внешней зависимости, превращает сбой одного узла в сбой всех реплик. Варианты защиты — реплика БД с автоматическим переключением (09-1) и readiness, которая допускает деградированный ответ (02-5).

### StatefulSet не переезжает сам

Через 353 с под `web` из Deployment получил `deletionTimestamp`, и контроллер создал замену. `postgres-0` из StatefulSet тоже получил отметку удаления, но остался в Terminating и не пересоздался. StatefulSet — контроллер подов с постоянным именем и своим томом (00-1, 02-3).

Причина в гарантии StatefulSet: одновременно существует не больше одного пода с этим именем, иначе два PostgreSQL писали бы в один том. Контроллер не знает, мёртв узел или просто потерял связь, поэтому ждёт подтверждения бесконечно, пока узел не вернётся.

Для действительно мёртвого узла есть три выхода:

1. Удалить объект Node: контроллер сборки подов (PodGC) удалит поды, привязанные к несуществующему узлу.
2. Выполнить `kubectl delete pod --force --grace-period=0`. Это снимает запись из API, но не останавливает процесс, и если узел на самом деле жив, получится два экземпляра на одном томе.
3. Повесить taint `node.kubernetes.io/out-of-service=nodeshutdown:NoExecute` (**non-graceful node shutdown**, stable с 1.28). Это явное заявление «узел выключен», после которого поды удаляются, а тома освобождаются; ставят его, только убедившись, что узел действительно выключен.

Том local-path привязан к диску узла, поэтому даже после удаления пода новый `postgres-0` не запустится на другом узле (04-2).

### Замена зависла в Pending

Замена пода `web` осталась в Pending до возврата узла. Причина в `topologySpreadConstraints` с `maxSkew: 1` по `kubernetes.io/hostname` (05-3). Узел с taint'ом по умолчанию остаётся доменом распределения (`nodeTaintsPolicy: Ignore`). Новый под не может встать на узел, где уже есть `web`, а на мёртвый узел его не пускает taint, о чём и говорит событие `FailedScheduling`:

```
0/4 nodes are available: 2 node(s) didn't match pod topology spread constraints,
2 node(s) had untolerated taint(s). ...
```

### Ошибки пути пода и PLEG

Остальные поломки узла относятся к шагам схемы 4, и ошибки видны в событиях и статусе пода:

- `FailedMount` — шаг 3, том не смонтировался (04-2).
- `FailedCreatePodSandBox` — шаг 4, часто CNI не выдал IP (03-1).
- `ErrImagePull`, `ImagePullBackOff` — шаг 5, образ или доступ к реестру.
- `CreateContainerConfigError` — шаг 6, нет ключа в Secret или ConfigMap.
- `CrashLoopBackOff` — процесс падает, kubelet ждёт перед повтором (02-1).

Методика разбора каждой ошибки — 11-2.

Отдельный случай — узел NotReady из-за рантайма. **PLEG** (Pod Lifecycle Event Generator) — часть kubelet, которая раз в секунду сверяет состояние контейнеров с рантаймом и узнаёт, что контейнер умер. Сообщение `PLEG is not healthy` в журнале kubelet значит, что рантайм не отвечает дольше порога в 3 минуты, и узел становится NotReady.

Причины — перегруженный или зависший containerd, тысячи остановленных контейнеров, медленный диск. Смотрят `journalctl -u kubelet -u containerd` и число контейнеров в `crictl ps -a`. Перезапуск containerd лечит симптом, а не причину.

---

## 6. Пределы и значения по умолчанию

Ниже собраны числа этой части для Kubernetes 1.36 и требования к узлу; значения стенда видны через `configz` (работа 2).

### Heartbeat и вытеснение

- Продление Lease — раз в ~10 с; `nodeLeaseDurationSeconds` — 40.
- `nodeStatusUpdateFrequency` — 10 с; `nodeStatusReportFrequency` — 5 минут.
- `node-monitor-grace-period` — 50 с (в старых версиях было 40 с).
- Toleration к `unreachable` и `not-ready` с `tolerationSeconds` — 300 с.
- Полная задержка до замены подов Deployment — около 350 с; на стенде измерено 353 с.
- Для StatefulSet задержка не ограничена без вмешательства.

Сокращать `tolerationSeconds` можно, но не ниже минуты, иначе короткий сетевой сбой вызовет массовую миграцию подов.

### Узел и поды

- `maxPods` — 110 на узел. Предел накладывает и подсеть узла: `/24` даёт 254 адреса.
- `serializeImagePulls` — `true`; при `false` число параллельных загрузок ограничивает `maxParallelImagePulls` (stable с 1.35).
- `fileCheckFrequency` для static pods — 20 с.
- Allocatable равен capacity минус `kube-reserved`, `system-reserved` и порог вытеснения (05-1, 05-5).

### Логи и образы

- `containerLogMaxSize` — 10Mi; `containerLogMaxFiles` — 5.
- `imageGCHighThresholdPercent` — 85; `imageGCLowThresholdPercent` — 80.

### Особенности стенда

В kind настройки отличаются от умолчаний: `imageGCHighThresholdPercent` равен 100, то есть сборка образов выключена, а пороги `evictionHard` равны `0%`, и kubelet не защищает диск хоста. Заполнение диска легко не заметить, поэтому на стенде проверяют `docker system df` вручную.

### Требования к узлу: cgroup v2 и containerd 2.x

Узел для Kubernetes 1.36 должен работать на **cgroup v2** (unified hierarchy) — второй версии cgroup, где все контроллеры собраны в одно дерево. С 1.35 параметр kubelet `failCgroupV1` по умолчанию равен `true`, и на узле с cgroup v1 kubelet не запускается. Проверка kubeadm `SystemVerification` при этом даёт ошибку в `init`, `join` и `upgrade`.

Версию cgroup на узле показывает тип файловой системы `/sys/fs/cgroup`:

```bash
stat -fc %T /sys/fs/cgroup/
```

```
cgroup2fs
```

Что в выводе: `cgroup2fs` означает cgroup v2; любой другой тип — cgroup v1, и kubelet 1.36 на таком узле с умолчаниями не стартует.

Обход `failCgroupV1: false` в конфиге kubelet ещё работает, но это анти-рецепт: cgroup v1 в режиме сопровождения с 1.31, а удаление обхода запланировано на 1.38. Правильный путь — перевести узел на cgroup v2. Ядру для этого нужна версия 5.8+, для Memory QoS — 5.9+. Ubuntu с 21.10 и Manjaro используют cgroup v2 по умолчанию.

Рантайм тоже должен быть свежим. Для Kubernetes 1.36 проект containerd указывает версии 2.2+ и 2.3+. Ветка 1.x не поддерживается: последний релиз Kubernetes с её поддержкой — 1.35. containerd 2.3 — первая LTS-ветка с поддержкой до 30 апреля 2028 года.

- **Версия конфига `version = 3`** — формат `/etc/containerd/config.toml` для containerd 2.0+.
- **Версия `version = 4`** — формат для containerd 2.3+.
- **Миграция** — старый конфиг переводится в новый формат в памяти при каждом старте; `containerd config migrate` печатает его в новом формате.
- **Откат** — после записи конфига v4 вернуться на containerd ниже 2.3 нельзя.

---

## Лабораторные работы

Работы идут на стенде 00-1 в namespace `lab-01-2`. Работы 1 и 2 только читают состояние, а работы 3 и 4 меняют узлы стенда и начинаются с блока «Риски». Хост не меняется, потому что узлы kind — контейнеры Docker; единственное исключение — namespace по умолчанию в `~/.kube/config`, его возвращает уборка последней работы. Файлы с манифестами, если они понадобятся, лежат в `~/lab/k8s/01-2/`. Образ `busybox:1.37` узлы тянут из Docker Hub; если он недоступен, положите его в реестр стенда по схеме из начала лабораторных работ 00-2 под именем `localhost:5001/lab-01-2/busybox:1.37`.

Подготовка выполняется один раз.

```bash
kubectl config use-context kind-lab
kubectl create ns lab-01-2
kubectl config set-context --current --namespace=lab-01-2
kubectl -n orders get pods -o wide
```

Первая команда выбирает кластер стенда, вторая создаёт namespace, третья делает его текущим, чтобы не писать `-n lab-01-2`. Четвёртая показывает, на каком узле работает `postgres-0`: у автора это `lab-worker`, а если у вас иначе, подставьте свой узел в работе 4. Namespace удаляется в уборке работы 4.

### Лабораторная работа 1. Sandbox, pause и namespaces пода

**Цель.** Найти на узле sandbox пода, убедиться, что pause и контейнер приложения делят сетевой namespace, и сопоставить IP пода с конфигом CNI и маршрутами узла.

**Что понадобится.** Стенд 00-1, работающий под orders-api в namespace `orders`, `crictl` на узлах kind.

**Схема опыта.**

```
kubectl ──► узел W (docker exec)
              ├─ crictl pods / inspectp  → sandbox, IP, путь netns
              ├─ /proc/<pid>/ns/net, pid → pause и api: net общий, pid разный
              └─ /etc/cni/net.d, ip route → подсеть и маршруты узла
```

Схема 6. Три источника на узле: рантайм, `/proc` и конфигурация сети. Сравниваем их между собой.

#### Шаг 1. Найти sandbox пода

Команда определяет узел, где работает orders-api, и показывает три поля sandbox: образ pause, путь к netns и IP.

```bash
W=$(kubectl -n orders get pod -l app=orders-api \
  -o jsonpath='{.items[0].spec.nodeName}')
echo "узел: $W"
docker exec $W sh -c '
  P=$(crictl pods --namespace orders --name orders-api -q | head -1)
  crictl inspectp $P | grep -E "\"(ip|path|image)\"" | head -4'
```

| Часть команды | Значение |
|---|---|
| `jsonpath='{.items[0].spec.nodeName}'` | узел первого пода с меткой `app=orders-api` |
| `docker exec $W sh -c '…'` | выполнить блок внутри узла kind |
| `crictl pods … -q` | вывести только идентификаторы sandbox'ов |
| `crictl inspectp $P` | подробности sandbox в JSON |
| `grep -E` | оставить поля `ip`, `path`, `image` |

Результат (у автора узел `lab-worker3`, значения у вас другие):

```
"image": "registry.k8s.io/pause:3.10",
"path": "/var/run/netns/cni-542787ea-dd36-7a95-0fc7-860c6ccbef33",
"ip": "10.244.1.5"
```

Разбор:

1. `image` — образ pause, который держит sandbox.
2. `path` — netns пода; имя начинается с `cni-`, потому что его создал containerd при вызове CNI.
3. `ip` — адрес пода из подсети узла; он должен совпасть с `kubectl get pod -o wide`.

#### Шаг 2. Сравнить namespaces

Команда берёт PID процесса pause и PID контейнера `api`, затем сравнивает их ссылки на сетевой и PID-namespace.

```bash
docker exec $W sh -c '
  P=$(crictl pods --namespace orders --name orders-api -q | head -1)
  PP=$(crictl inspectp -o go-template --template "{{.info.pid}}" $P)
  C=$(crictl ps --pod $P -q)
  CP=$(crictl inspect -o go-template --template "{{.info.pid}}" $C)
  ls -l /proc/$PP/ns/net /proc/$CP/ns/net /proc/$PP/ns/pid /proc/$CP/ns/pid
  ps -eo pid,args | grep "[/]pause" | head -3'
```

| Часть команды | Значение |
|---|---|
| `inspectp -o go-template` | вывести только поле `.info.pid` sandbox |
| `crictl ps --pod $P -q` | контейнеры этого пода |
| `/proc/<pid>/ns/net` | ссылка на сетевой namespace процесса |
| `/proc/<pid>/ns/pid` | ссылка на PID-namespace процесса |
| `grep "[/]pause"` | найти pause, не находя сам `grep` |

Результат (сокращён до пути и ссылки):

```
/proc/1616/ns/net -> net:[4026534532]      ← pause
/proc/1643/ns/net -> net:[4026534532]      ← контейнер api: тот же сетевой namespace
/proc/1616/ns/pid -> pid:[4026534597]
/proc/1643/ns/pid -> pid:[4026534599]      ← PID namespace у каждого свой
```

Последняя команда должна показать по одному процессу `/pause` на каждый под узла; их число совпадает с числом sandbox'ов в `crictl pods`.

Разбор:

1. Номер `net:[4026534532]` одинаковый: pause и `api` в одном сетевом namespace, поэтому у них общий IP.
2. Номера `pid:[…]` разные: PID-namespace у контейнеров раздельные.
3. Процесс pause не принадлежит контейнеру приложения, поэтому перезапуск `api` не меняет сеть пода.

#### Шаг 3. Сопоставить IP, CNI и маршруты

Команды показывают конфиг CNI узла, таблицу маршрутов и подсети всех узлов.

```bash
docker exec $W cat /etc/cni/net.d/10-kindnet.conflist
docker exec $W ip route
kubectl get nodes -o custom-columns=\
NAME:.metadata.name,PODCIDR:.spec.podCIDR,IP:.status.addresses[0].address
```

| Часть команды | Значение |
|---|---|
| `10-kindnet.conflist` | список CNI-плагинов kindnet на этом узле |
| `ip route` | таблица маршрутов узла |
| `custom-columns=…` | свои колонки: имя, подсеть подов, IP узла |
| `.spec.podCIDR` | подсеть, которую узлу выдал control plane |

Результат конфига и маршрутов (сокращён) — как в §2. Ожидаемый результат команды `get nodes` — по строке на каждый из четырёх узлов с подсетью вида `10.244.N.0/24` в колонке PODCIDR.

Разбор:

1. `subnet` в конфиге CNI совпадает с `podCIDR` этого узла: kindnet берёт подсеть из объекта Node.
2. Маршрут `10.244.1.5 dev veth… scope host` ведёт к поду из шага 1 прямо в veth.
3. Маршрут `10.244.0.0/24 via 172.20.0.2` — подсеть другого узла достигается через IP этого узла.
4. Маршрутов к подсетям других узлов столько, сколько этих узлов: три.

**Итог.**

| Что узнали | Где видно |
|---|---|
| Под — это sandbox с процессом pause и контейнеры в нём | шаг 1, образ pause |
| Контейнеры пода делят сетевой namespace, но не PID | шаг 2, номера `net` и `pid` |
| IP выдаёт CNI из подсети узла | шаг 3, `subnet` и `podCIDR` |
| Поды чужих узлов достигаются маршрутом через IP узла | шаг 3, `ip route` |

**Уборка.** Работа ничего не создавала. Убираем только переменную.

```bash
unset W
```

**Вопросы для самопроверки.**

1. Почему перезапуск контейнера приложения не меняет IP пода?
2. По какому признаку в `/proc` видно, что два процесса делят сетевой namespace?
3. Откуда в конфиге CNI подсеть `10.244.1.0/24`?

<details>
<summary>Ответы</summary>

1. Сетевой namespace принадлежит процессу pause, а не контейнеру приложения, а pause живёт, пока жив под.
2. Совпадают числа в ссылках `/proc/<pid>/ns/net -> net:[…]`.
3. Это `podCIDR` объекта Node, выданный control plane; kindnet записывает его в конфиг плагина `host-local`.

</details>

### Лабораторная работа 2. cgroups и конфигурация kubelet

**Цель.** Увидеть раскладку подов по QoS-веткам cgroup, прочитать эффективную конфигурацию kubelet и проверить heartbeat узла.

**Что понадобится.** Стенд 00-1, `jq` на хосте, узел `lab-worker`.

**Схема опыта.**

```
docker exec lab-worker   → systemd-cgls          (дерево cgroup)
kubectl get --raw …/configz → jq                 (параметры kubelet с умолчаниями)
kubectl get lease        → renewTime             (heartbeat, меняется каждые ~10 с)
docker exec lab-worker   → /var/log/containers   (симлинки на логи)
```

Схема 7. Четыре источника: дерево cgroup, настройки kubelet, объект Lease и каталог логов.

#### Шаг 1. Дерево cgroup

Команда показывает первые строки дерева systemd для kubelet и всех его подов.

```bash
N=lab-worker
docker exec $N systemd-cgls --no-pager -u kubelet.slice | head -25
```

| Часть команды | Значение |
|---|---|
| `N=lab-worker` | узел, на котором смотрим |
| `systemd-cgls` | вывести дерево cgroup |
| `--no-pager` | не запускать постраничный просмотр |
| `-u kubelet.slice` | показать только ветку этого slice |

Результат — дерево, показанное в §4 (схема 5); идентификаторы и PID у вас другие.

Разбор:

1. `kubelet.service` — сам kubelet, отдельный процесс в корне slice.
2. `kubelet-kubepods-besteffort.slice` и `…-burstable.slice` — ветки по QoS, а под Guaranteed лежит прямо в `kubepods`.
3. `cri-containerd-<id>.scope` — один scope на контейнер; в каждом поде есть scope с процессом `/pause`.
4. Префикс `kubelet-` — особенность kind, на обычном узле имена начинаются с `kubepods`.

#### Шаг 2. Конфигурация kubelet

Команда запрашивает `configz` у kubelet через API-сервер и выбирает нужные поля.

```bash
kubectl get --raw /api/v1/nodes/$N/proxy/configz | jq '.kubeletconfig | {
  cgroupDriver, nodeStatusUpdateFrequency, nodeStatusReportFrequency,
  nodeLeaseDurationSeconds, containerLogMaxSize, containerLogMaxFiles,
  imageGCHighThresholdPercent, imageGCLowThresholdPercent,
  evictionHard, maxPods, serializeImagePulls }'
```

| Часть команды | Значение |
|---|---|
| `get --raw …/proxy/configz` | запрос к kubelet узла через API-сервер |
| `jq '.kubeletconfig'` | войти в объект с настройками |
| `{ cgroupDriver, … }` | оставить перечисленные поля |

Результат (сокращён):

```
{
  "cgroupDriver": "systemd",
  "nodeStatusUpdateFrequency": "10s",
  "nodeStatusReportFrequency": "5m0s",
  "nodeLeaseDurationSeconds": 40,
  "containerLogMaxSize": "10Mi",
  "containerLogMaxFiles": 5,
  "imageGCHighThresholdPercent": 100,
  "imageGCLowThresholdPercent": 80,
  "evictionHard": {
    "imagefs.available": "0%",
    "nodefs.available": "0%",
    "nodefs.inodesFree": "0%"
  },
  "maxPods": 110,
  "serializeImagePulls": true
}
```

Разбор:

1. `cgroupDriver: systemd` — kubelet работает с cgroup через systemd; containerd 2.x сообщает тот же драйвер по CRI (§3).
2. `nodeStatusUpdateFrequency` 10 с и `nodeLeaseDurationSeconds` 40 — параметры heartbeat из §2.
3. `imageGCHighThresholdPercent: 100` и `evictionHard` по `0%` — настройки kind: сборка образов и вытеснение по диску выключены. Умолчания Kubernetes — 85 и конкретные пороги.
4. `maxPods: 110`, `serializeImagePulls: true`, `containerLogMaxSize: 10Mi` — умолчания.

#### Шаг 3. Lease и логи

Команды читают Lease узла несколько раз и показывают симлинки логов.

```bash
for i in 1 2 3; do
  kubectl -n kube-node-lease get lease $N -o jsonpath='{.spec}{"\n"}'
  sleep 10
done
docker exec $N ls -l /var/log/containers | head -3
```

| Часть команды | Значение |
|---|---|
| `get lease $N` | Lease узла в namespace `kube-node-lease` |
| `jsonpath='{.spec}'` | вывести только спецификацию |
| `sleep 10` | пауза между чтениями |
| `ls -l /var/log/containers` | симлинки на логи контейнеров |

Результат одного чтения Lease и первой строки каталога логов (строка перенесена; время и идентификаторы у вас другие):

```
{"holderIdentity":"lab-worker","leaseDurationSeconds":40,"renewTime":"2026-10-14T08:51:49.053074Z"}
lrwxrwxrwx 1 root root 140 Oct 14 08:25 envoy-…_envoy-gateway-system_envoy-e2d4….log ->
  /var/log/pods/envoy-gateway-system_envoy-…_1cefb68a-…/envoy/0.log
```

Разбор:

1. `holderIdentity` — узел, который держит аренду; он совпадает с именем узла.
2. `leaseDurationSeconds: 40` — срок аренды.
3. В трёх чтениях `renewTime` сдвигается примерно на 10 с: так выглядит heartbeat, секунды у вас будут свои.
4. Файл в `/var/log/containers` — симлинк на `/var/log/pods/<ns>_<под>_<uid>/<контейнер>/N.log`, и именно этот каталог читают агенты сбора логов.

**Итог.**

| Что узнали | Где видно |
|---|---|
| Поды раскладываются по cgroup в ветки QoS | шаг 1, `besteffort` и `burstable` |
| Драйвер cgroups — systemd | шаг 2, `cgroupDriver` |
| Умолчания kubelet и отличия kind | шаг 2, GC и `evictionHard` |
| Heartbeat — обновление Lease раз в ~10 с | шаг 3, `renewTime` |
| Логи подов лежат в `/var/log/pods`, ссылки — в `/var/log/containers` | шаг 3 |

**Уборка.** Работа ничего не создавала.

```bash
unset N
```

**Вопросы для самопроверки.**

1. Почему драйвер cgroups у kubelet и containerd должен совпадать?
2. Как по Lease понять, что kubelet завис, не заходя на узел?
3. Где искать лог упавшего контейнера на узле, если под уже удалён?

<details>
<summary>Ответы</summary>

1. Иначе два менеджера (systemd и cgroupfs) управляют одной иерархией, и под нагрузкой возможны сбои создания подов и неверные лимиты. С 1.34 kubelet берёт драйвер у рантайма по CRI, и это совпадение обеспечивается само.
2. Смотреть `renewTime`: если он не меняется больше минуты, kubelet не продлевает аренду.
3. Нигде: логи удаляются вместе с подом, поэтому нужен внешний сбор (агент читает `/var/log/containers` заранее).

</details>

### Лабораторная работа 3. Static pod на worker'е

**Риски.** Работа добавляет файл на узел стенда.

- **Что меняется:** на узле `lab-worker2` (контейнер Docker) появляется файл в `/etc/kubernetes/manifests`, и kubelet запускает по нему под с busybox.
- **Надолго ли:** на время работы, около 2 минут; уборка удаляет файл.
- **Безопасность:** под без привилегий и `hostPath`, образ `busybox:1.37` закреплён по версии. Файл в этом каталоге обходит RBAC и admission, поэтому не оставляйте его после работы.
- **Влияние на систему:** затрагивается один узел стенда; хост и другие кластеры не меняются.
- **Откат:** удалить файл (`rm`, см. шаг 4 и «Уборка»).

**Цель.** Запустить static pod на worker'е, увидеть его зеркало в API и убедиться, что `kubectl delete` не останавливает контейнер.

**Что понадобится.** Стенд 00-1, namespace `lab-01-2`, образ `busybox:1.37`, узел `lab-worker2`.

**Схема опыта.**

```
файл в /etc/kubernetes/manifests (lab-worker2)
        │ kubelet читает каталог (≤ 20 с)
        ▼
контейнер web  ──► mirror pod static-web-lab-worker2 в API
        ▲                       │ kubectl delete
        └── тот же контейнер ◄──┘ зеркало пересоздаётся
```

Схема 8. Источник истины — файл. Объект в API лишь отражает его.

#### Шаг 1. Положить манифест

Команда записывает манифест в каталог static pods узла и через 15 с показывает поды.

```bash
docker exec -i lab-worker2 sh -c 'cat > /etc/kubernetes/manifests/static-web.yaml' <<'EOF'
apiVersion: v1
kind: Pod
metadata: {name: static-web, namespace: lab-01-2}
spec:
  containers:
  - name: web
    image: busybox:1.37
    command: ["sleep", "infinity"]
EOF
sleep 15
kubectl get pods -o wide
```

| Часть команды | Значение |
|---|---|
| `docker exec -i lab-worker2 sh -c 'cat > …'` | записать stdin в файл на узле |
| `<<'EOF'` | передать манифест как stdin |
| `namespace: lab-01-2` | static pod сам указывает namespace зеркала |
| `sleep 15` | дать kubelet время заметить файл |

Результат (сокращён):

```
NAME                     READY   STATUS    RESTARTS   AGE   IP            NODE          ...
static-web-lab-worker2   1/1     Running   0          15s   10.244.3.10   lab-worker2   ...
```

Разбор:

1. Имя `static-web-lab-worker2` — имя из манифеста плюс суффикс узла.
2. Scheduler этот под не выбирал: узел определён тем, где лежит файл.
3. Под стал Running меньше чем за 15 с.

#### Шаг 2. Прочитать признаки зеркала

Команда выводит аннотации и владельца зеркального пода.

```bash
kubectl get pod static-web-lab-worker2 \
  -o jsonpath='{.metadata.annotations}{"\n"}{.metadata.ownerReferences}{"\n"}'
```

| Часть команды | Значение |
|---|---|
| `.metadata.annotations` | аннотации, которые поставил kubelet |
| `.metadata.ownerReferences` | владелец объекта |

Результат (хеши и время сокращены):

```
{"kubernetes.io/config.hash":"17b2e4f7…","kubernetes.io/config.mirror":"17b2e4f7…",
 "kubernetes.io/config.seen":"2026-10-14T08:52:06…","kubernetes.io/config.source":"file"}
[{"apiVersion":"v1","controller":true,"kind":"Node","name":"lab-worker2","uid":"8eddb6f6-…"}]
```

Разбор:

1. `config.source: file` — под пришёл из файла, а не из API.
2. `config.mirror` — отметка зеркального пода.
3. Владелец — объект Node `lab-worker2`, а не ReplicaSet или другой контроллер.

#### Шаг 3. Удалить зеркало

Команда удаляет объект пода в API и сразу сверяет контейнер на узле.

```bash
kubectl delete pod static-web-lab-worker2
sleep 5
kubectl get pods
docker exec lab-worker2 crictl ps --name '^web$'
```

| Часть команды | Значение |
|---|---|
| `kubectl delete pod …` | удалить зеркальный объект |
| `crictl ps --name '^web$'` | найти контейнер `web` на узле |

Результат (колонки вывода `crictl` сокращены):

```
pod "static-web-lab-worker2" deleted from lab-01-2 namespace
NAME                     READY   STATUS    RESTARTS   AGE
static-web-lab-worker2   1/1     Running   0          6s
CONTAINER       IMAGE           CREATED          STATE     NAME   ATTEMPT   POD ID          POD  …
83462e6183552   30ecbe1509090   20 seconds ago   Running   web    0         b3d278488e485   …
```

Разбор:

1. Зеркало «помолодело» (`AGE 6s`): kubelet создал новое.
2. Контейнер создан 20 с назад, то есть это тот же контейнер, что и до удаления: он не пересоздавался.
3. `kubectl delete` убирает только объект в API.

#### Шаг 4. Удалить файл

Команда удаляет манифест с узла и проверяет, что под исчез.

```bash
docker exec lab-worker2 rm /etc/kubernetes/manifests/static-web.yaml
sleep 30
kubectl get pods
```

| Часть команды | Значение |
|---|---|
| `rm …/static-web.yaml` | убрать файл — источник static pod |
| `sleep 30` | подождать период опроса каталога (20 с) и остановку |

Результат:

```
No resources found in lab-01-2 namespace.
```

Разбор: файл исчез, и kubelet остановил контейнер и убрал зеркало. Ждать нужно до 20 с (`fileCheckFrequency`) плюс время остановки.

**Итог.**

| Что узнали | Где видно |
|---|---|
| Static pod запускает kubelet из файла, без scheduler | шаг 1 |
| В API он виден как зеркало с владельцем Node | шаг 2, `config.source: file` |
| `kubectl delete` не останавливает контейнер | шаг 3, возраст контейнера 20 с |
| Остановить static pod можно, только убрав файл | шаг 4 |

**Уборка.** Файл удалён в шаге 4. Убедитесь, что каталог чист.

```bash
docker exec lab-worker2 ls /etc/kubernetes/manifests
```

Результат — пустой вывод, потому что на worker'ах стенда в этом каталоге нет других манифестов. Работу можно повторить, ничего больше не меняя.

**Вопросы для самопроверки.**

1. Почему `kubectl delete` не останавливает static pod?
2. Кто выбирает узел для static pod?
3. Чем опасен записываемый каталог манифестов на узле?
4. Как узнать по API, что под — зеркальный?

<details>
<summary>Ответы</summary>

1. Объект в API — зеркало файла, и kubelet создаёт зеркало заново, пока файл существует.
2. Никто: под запускается на том узле, где лежит файл, scheduler не участвует.
3. Файл запускает под в обход RBAC и admission, а такой под может примонтировать `hostPath`, поэтому запись в каталог равна правам root на узле.
4. По аннотации `kubernetes.io/config.mirror` и владельцу `Node` в `ownerReferences`.

</details>

### Лабораторная работа 4. Узел без kubelet: NotReady и вытеснение

**Риски.** Работа останавливает kubelet на рабочем узле стенда.

- **Что меняется:** на узле `lab-worker` останавливается служба kubelet; контейнеры узла продолжают работать, но узел теряет связь с кластером. В namespace `lab-01-2` создаётся Deployment `web`.
- **Надолго ли:** около 7 минут наблюдения; kubelet возвращается командой в конце.
- **Безопасность:** привилегий сверх `docker exec` не нужно, секреты не затрагиваются.
- **Влияние на систему:** на `lab-worker` работает `postgres-0` из namespace `orders`, поэтому пока kubelet остановлен, `curl http://orders.localhost:8088/api/orders` отвечает 503. Не запускайте другие работы параллельно.
- **Откат:** `docker exec lab-worker systemctl start kubelet`; если терминал потерян, выполните эту команду в новом.

**Цель.** Измерить, через сколько секунд узел уходит в NotReady, когда поды получают метку удаления, и что при этом делают Deployment и StatefulSet.

**Что понадобится.** Стенд 00-1 с приложением orders и `postgres-0` на узле `lab-worker` (иначе подставьте свой узел в `NODE`). Ещё нужны образ `busybox:1.37`, `curl` и `jq` на хосте и два окна терминала.

**Схема опыта.**

```
lab-worker:      kubelet (остановлен) │ containerd │ postgres-0 (процесс жив)
lab-worker2,3:   kubelet работает     │ web ×2
                                       ▼
t=0     systemctl stop kubelet
t=+53 с узел Unknown + taint'ы unreachable → endpoint postgres неготов → api=503
t=+353 с поды узла получают deletionTimestamp → Deployment создаёт замену
```

Схема 9. Хронология опыта. Наблюдатель-цикл печатает строку при каждом изменении.

#### Шаг 1. Разложить поды

Команда создаёт Deployment из трёх подов, которые по `topologySpreadConstraints` занимают разные worker'ы, и показывает их расположение.

```bash
kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata: {name: web}
spec:
  replicas: 3
  selector: {matchLabels: {app: web}}
  template:
    metadata: {labels: {app: web}}
    spec:
      topologySpreadConstraints:
      - maxSkew: 1
        topologyKey: kubernetes.io/hostname
        whenUnsatisfiable: DoNotSchedule
        labelSelector: {matchLabels: {app: web}}
      containers:
      - {name: web, image: busybox:1.37, command: ["sleep", "infinity"]}
EOF
kubectl rollout status deploy/web
kubectl get pods -o wide
```

| Часть команды | Значение |
|---|---|
| `replicas: 3` | три пода |
| `maxSkew: 1` | разница числа подов между узлами не больше одного |
| `topologyKey: kubernetes.io/hostname` | распределять по узлам |
| `whenUnsatisfiable: DoNotSchedule` | не ставить под, если правило нарушается |
| `rollout status` | дождаться готовности всех подов |

Ожидаемый результат: три пода `web` Running, по одному на `lab-worker`, `lab-worker2` и `lab-worker3` (control plane закрыт taint'ом).

Разбор: на `lab-worker` стоят один под `web` и `postgres-0`, и они понадобятся для сравнения Deployment и StatefulSet.

#### Шаг 2. Остановить kubelet и наблюдать

Скрипт останавливает kubelet и 7 минут выводит строку при каждом изменении: состояние узла, `postgres-0`, endpoint БД, поды `web` и ответ API. Запустите его в первом окне.

```bash
NODE=lab-worker
NJ='{.status.conditions[?(@.type=="Ready")].status}/'
NJ+='{.status.conditions[?(@.type=="Ready")].reason} '
NJ+='taints={.spec.taints[*].key}:{.spec.taints[*].effect}'
PJ='{.status.phase}/ready={.status.conditions[?(@.type=="Ready")].status}'
PJ+='/del={.metadata.deletionTimestamp}'
t0=$(date +%s); prev=""
docker exec $NODE systemctl stop kubelet; echo "t=0 kubelet stopped on $NODE"
while [ $(( $(date +%s)-t0 )) -lt 420 ]; do
  n=$(kubectl get node $NODE -o jsonpath="$NJ")
  p=$(kubectl -n orders get pod postgres-0 -o jsonpath="$PJ")
  w=$(kubectl get pods -o wide --no-headers |
    awk '{printf "%s:%s:%s ", substr($1,length($1)-4), $3, $7}')
  ep=$(kubectl -n orders get endpointslice \
    -l kubernetes.io/service-name=postgres \
    -o jsonpath='{.items[0].endpoints[*].conditions.ready}')
  c=$(curl -s -o /dev/null -m 3 -w '%{http_code}' http://orders.localhost:8088/api/orders)
  cur="node=$n | pg=$p ep_ready=$ep | web=$w | api=$c"
  [ "$cur" != "$prev" ] && echo "t=+$(( $(date +%s)-t0 ))s $cur" && prev=$cur
  sleep 3
done
```

| Часть команды | Значение |
|---|---|
| `NJ`, `PJ` | шаблоны jsonpath для узла и для `postgres-0` |
| `docker exec $NODE systemctl stop kubelet` | остановить kubelet на узле |
| `substr($1,length($1)-4)` | последние пять знаков имени пода |
| `endpoints[*].conditions.ready` | готовность адресов БД в EndpointSlice |
| `curl -m 3 -w '%{http_code}'` | код ответа сквозного запроса, не дольше 3 с |
| `[ "$cur" != "$prev" ] && echo …` | печатать, только если строка изменилась |

Результат (строки перенесены; запросы идут из сети kind, 00-1 §4):

```
t=0 kubelet stopped on lab-worker
t=+1s node=True/KubeletReady taints=: | pg=Running/ready=True/del= ep_ready=true |
  web=j62pr:Running:lab-worker2 wz5nv:Running:lab-worker xpvrm:Running:lab-worker3  | api=200
t=+53s node=Unknown/NodeStatusUnknown taints=node.kubernetes.io/unreachable
  node.kubernetes.io/unreachable:NoSchedule NoExecute | pg=Running/ready=False/del=
  ep_ready=false | web=j62pr:Running:lab-worker2 wz5nv:Running:lab-worker
  xpvrm:Running:lab-worker3  | api=503
t=+353s node=Unknown/NodeStatusUnknown taints=node.kubernetes.io/unreachable
  node.kubernetes.io/unreachable:NoSchedule NoExecute | pg=Running/ready=False/
  del=2026-10-14T09:00:41Z ep_ready=false | web=5hmqj:Pending:<none> j62pr:Running:lab-worker2
  wz5nv:Terminating:lab-worker xpvrm:Running:lab-worker3  | api=503
```

Разбор:

1. `t=+1s` — узел `True/KubeletReady`, всё работает: за секунду control plane ещё ничего не заметил.
2. `t=+53s` — узел `Unknown/NodeStatusUnknown`, два taint'а `unreachable`, `postgres-0` стал `ready=False`, endpoint неготов, API отвечает 503. Процессы живы, а сервис уже лёг.
3. Между +53 и +353 с строк нет: состояние не менялось. Эти 300 с — `tolerationSeconds` по умолчанию.
4. `t=+353s` — у `postgres-0` есть `deletionTimestamp`, под `wz5nv` перешёл в Terminating, а контроллер создал замену `5hmqj`, которая стоит в Pending без узла.
5. Время +53 с — это `node-monitor-grace-period` (50 с) плюс интервалы опроса, а +353 с равно 53 + 300.

#### Шаг 3. Проверить, что БД жива, и найти причину Pending

Пока цикл работает, во втором окне проверим, что процесс PostgreSQL работает, и прочитаем событие планировщика.

```bash
docker exec $NODE crictl ps --name postgres
kubectl get events --field-selector reason=FailedScheduling \
  -o jsonpath='{.items[-1:].message}{"\n"}'
```

| Часть команды | Значение |
|---|---|
| `crictl ps --name postgres` | контейнеры с этим именем на узле |
| `--field-selector reason=FailedScheduling` | только события отказа планировщика |
| `{.items[-1:].message}` | текст последнего события |

Ожидаемый результат — контейнер postgres в состоянии `Running`. Сообщение события (сокращено):

```
0/4 nodes are available: 2 node(s) didn't match pod topology spread constraints,
2 node(s) had untolerated taint(s). ...
```

Разбор:

1. Контейнер Running: узел потерял связь с кластером, а процесс не пострадал.
2. Два узла не подошли из-за правила распределения: на каждом уже есть по поду `web`.
3. Два узла не подошли из-за taint'ов: control plane и мёртвый `lab-worker`.
4. Замена `web` стоит в Pending, хотя места в кластере достаточно.

#### Шаг 4. Вернуть kubelet и засечь восстановление

Команда запускает kubelet и ждёт, пока сквозной запрос снова вернёт 200.

```bash
t0=$(date +%s); docker exec $NODE systemctl start kubelet
until [ "$(curl -s -o /dev/null -m 3 -w '%{http_code}' \
  http://orders.localhost:8088/api/orders)" = 200 ]; do sleep 1; done
echo "api=200 after $(( $(date +%s)-t0 ))s"
kubectl -n orders get pods -o wide
kubectl get pods -o wide
curl -s http://orders.localhost:8088/api/orders | jq -c '[.orders[].item]'
```

| Часть команды | Значение |
|---|---|
| `systemctl start kubelet` | запустить службу на узле |
| `until [ … = 200 ]; do sleep 1; done` | опрашивать раз в секунду, пока не будет 200 |
| `get pods -o wide` | поды с узлами и IP |
| `jq -c '[.orders[].item]'` | список товаров из ответа |

Результат (сокращён):

```
api=200 after 8s
postgres-0 Running 0 10.244.2.7 lab-worker
web-747b449645-5hmqj Running lab-worker
...
["book","pen","lamp"]
```

Разбор:

1. `after 8s` — через 8 секунд API снова отвечает 200.
2. `postgres-0` — новый под (`RESTARTS 0`, новый IP) на том же узле, а прежний удалён после возврата kubelet.
3. Замена `web` стартовала на `lab-worker`: вернувшийся узел снова принимает поды.
4. Список заказов на месте: том local-path лежит на диске `lab-worker`, данные сохранились.

**Итог.**

| Что узнали | Где видно |
|---|---|
| Процессы живут, когда kubelet остановлен | шаг 3, `crictl ps` |
| Узел становится Unknown через ~50 с | шаг 2, `t=+53s` |
| Сервис падает на этом же шаге | шаг 2, `api=503`, `ep_ready=false` |
| Поды получают метку удаления через 300 с после taint'а | шаг 2, `t=+353s` |
| StatefulSet не создаёт замену без вмешательства | шаг 2, `postgres-0` в Terminating |
| Замена из Deployment может зависнуть из-за spread | шаг 3, `FailedScheduling` |

**Уборка.** Проверяем, что kubelet работает, удаляем созданное и namespace.

```bash
docker exec $NODE systemctl is-active kubelet
docker exec lab-worker2 ls /etc/kubernetes/manifests
kubectl -n orders get pods
kubectl config set-context --current --namespace=default
kubectl delete ns lab-01-2
unset NODE NJ PJ t0 prev
```

Первая команда должна вывести `active`, вторая — ничего, потому что `static-web` удалён в работе 3. Третья показывает поды `orders`, и все они должны быть Running. Остальные команды удаляют namespace вместе с Deployment `web` и переменные.

**Вопросы для самопроверки.**

1. Через сколько секунд после остановки kubelet узел становится Unknown и откуда берётся эта цифра?
2. Почему orders-api отвечал 503, если PostgreSQL не падал?
3. Почему `postgres-0` не появился на другом узле, а замена `web` появилась?
4. Почему замена `web` осталась Pending?
5. Как ускорить замену подов Deployment и что вы при этом рискуете?

<details>
<summary>Ответы</summary>

1. Через `node-monitor-grace-period` — 50 с по умолчанию в 1.36; на стенде замерено +53 с с учётом шага опроса.
2. Поды на узле Unknown становятся неготовыми, и адрес БД пропал из endpoint'ов и DNS. Readiness orders-api зависит от БД, поэтому оба пода вышли из Service.
3. StatefulSet гарантирует не больше одного пода с этим именем и ждёт подтверждения от узла, а том local-path к тому же привязан к диску узла. Deployment такой гарантии не даёт.
4. Spread с `maxSkew: 1` считает узел с taint'ом доменом (`nodeTaintsPolicy: Ignore`), а на остальных узлах уже стоят поды `web`.
5. Уменьшить `tolerationSeconds` в подах, но не ниже минуты, иначе короткий сетевой сбой приведёт к лишней миграции подов.

</details>

---

## → Дальше

Узел исполняет то, что записано в объектах API, и сообщает о себе через статусы и Lease. Мы уже встретили зеркальный под с владельцем Node, поды с `deletionTimestamp` и статус от kubelet, но не разбирали, как устроены сами объекты. Поэтому следующая часть, 01-3, опускается в API: откуда берутся владельцы объектов, как apply решает, чьи поля менять, и что держит объект в Terminating.
