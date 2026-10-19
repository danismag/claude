# 00-1. Стенд курса

> Модуль 00 «Стенд и инструменты» · часть 1 из 2 · ~1 ч чтения + ~1,5 ч лабораторных · Нужно: Docker 27+, 8 ГБ RAM, 20 ГБ диска, интернет · Опирается на: ничего, это первая часть.

## Где мы на карте

Это первая часть курса, и все остальные части выполняют лабораторные работы на стенде, который собирается здесь. Следующая часть (00-2) разбирает инструменты, которыми смотрят на стенд: kubectl, crictl, k9s, stern. Модули 01–11 используют стенд как готовую среду и ничего в нём не устанавливают заново.

```
модули 01 … 11      лабораторные работы: поды, сеть, диски, доступ, GitOps, диагностика
      │
      ▼
00-2 инструменты    kubectl, crictl, k9s, stern
      │
      ▼
00-1 стенд          кластер kind + реестр + вход + демо-приложение   <- эта часть
      │
      ▼
хост                Docker, ядро Linux, ваш ~/.kube/config
```

Схема 1. Стенд лежит под всеми лабораторными работами и работает поверх Docker на вашей машине; смотрите на строку «эта часть».

---

## 1. Какую задачу решает стенд

Стенд даёт один и тот же кластер для всех частей и поднимается за пару минут. Разберём, что в нём настоящее, а чего в нём нет.

### Один кластер на весь курс

Лабораторные работы нужны на настоящем кластере, а не на имитации, поэтому стенд запускает те же kube-apiserver, etcd, kubelet и containerd, что работают в проде. Кластер можно ломать смело: в худшем случае его пересоздают двумя командами (§3).

Расширений (cert-manager, Argo CD, Gitea, CloudNativePG и других) в стенде нет. Каждая работа ставит свои расширения командами в начале и удаляет их в конце, поэтому стенд остаётся одинаковым для всех частей.

### Что такое kind

**kind** (Kubernetes in Docker) — инструмент, который запускает узлы Kubernetes как контейнеры Docker: один контейнер — один узел. Внутри контейнера работают systemd, kubelet и containerd, поэтому кластер из четырёх узлов целиком помещается на ноутбук.

**Узел** (node) — машина, на которой kubelet запускает поды. В kind роль машины играет контейнер, поэтому на узел заходят командой `docker exec`, а не по SSH.

### Чего стенд не воспроизводит

Стенд моделирует управляющие компоненты и работу узлов, но не железо и не облако.

- **Нет настоящей сети между узлами.** Узлы — контейнеры в одной docker-сети, задержек и потерь между ними нет.
- **Нет облачного балансировщика.** Service типа LoadBalancer остаётся в состоянии `<pending>` (§6).
- **Нет изоляции ресурсов между узлами.** Все четыре узла делят CPU и память одной машины (§6).

Эти пределы названы там, где они влияют на опыт: в частях о ресурсах (05-1, 05-5) и о сети (03-1, 03-2).

---

## 2. Как устроен стенд

Стенд состоит из четырёх узлов kind, реестра образов, входа в кластер и нескольких дополнений, и всё это работает в docker-сети `kind` на одной машине.

### Топология

Схема показывает, какие порты хоста ведут к каким компонентам; смотрите на левый край, где перечислены три порта хоста.

```
хост (127.0.0.1)
 ├─ :6443x ────────► lab-control-plane   apiserver, etcd, scheduler, controller-manager,
 │                                        CoreDNS, local-path-provisioner
 ├─ :8088 ─────────►   :30080 (NodePort) ─► Envoy Gateway ─► HTTPRoute ─► Service orders-api
 │                   lab-worker           ┐
 │                   lab-worker2          ├ kubelet + containerd, kube-proxy, kindnet
 │                   lab-worker3          ┘
 └─ :5001 ─────────► kind-registry        registry:2.8.3 — образы стенда
                     (всё — в docker-сети kind)
```

Схема 2. Три входа с хоста: apiserver на случайном порту 6443x, веб-вход на 8088, реестр на 5001.

Таблица перечисляет компоненты стенда, место их работы и части, где они разбираются.

| Компонент | Где работает | Где разбирается |
|---|---|---|
| kind, Kubernetes 1.36.1 | 4 контейнера lab-* | 01-1, 01-2, 10-1 |
| kindnet | DaemonSet в kube-system | 03-1 |
| kube-proxy, режим iptables | DaemonSet в kube-system | 03-2 |
| CoreDNS | Deployment в kube-system | 03-3 |
| local-path-provisioner | namespace local-path-storage | 04-2 |
| metrics-server 0.8.0 | kube-system | 05-4, 11-1 |
| Envoy Gateway 1.9.2 | envoy-gateway-system | 03-4 |
| реестр kind-registry | контейнер Docker | 02-1, 06-4 |
| orders-api и PostgreSQL | namespace orders | лабораторная работа 3 |

### Узел как контейнер

В кластере один **control plane** (управляющий узел, где работают apiserver, etcd, scheduler и controller-manager) и три **worker** (рабочих узла, на которых запускаются поды). Узлы называются `lab-control-plane`, `lab-worker`, `lab-worker2` и `lab-worker3`.

На узел заходят командой `docker exec -it lab-worker bash`, и внутри доступны привычные инструменты узла. Это `crictl`, `journalctl -u kubelet`, `iptables-save` и каталог `/etc/kubernetes/manifests` со static pods (01-2).

### Реестр образов

**Реестр** (registry) — сервер, который хранит образы контейнеров. Стенд запускает собственный реестр `registry:2.8.3` в контейнере `kind-registry`, который слушает `127.0.0.1:5001` и хранит образы в томе `kind-registry-data`.

Образы собирает Docker на хосте и отправляет в `localhost:5001`, а узлы тянут их по тому же имени. Внутри узла `localhost` — это сам узел, а не хост. Поэтому скрипт пишет в каждый узел файл `hosts.toml`, который перенаправляет `localhost:5001` на `http://kind-registry:5000`. Этот файл читает **containerd** — среда запуска контейнеров на узле (01-2).

### Вход в кластер

**Gateway API** — набор объектов Kubernetes для входящего HTTP-трафика, а **Envoy Gateway** — реализация этого API на прокси Envoy. Стенд создаёт Gateway с именем `lab` на порту 80, который принимает маршруты (**HTTPRoute**) из любых namespace.

Сервис Envoy имеет тип **NodePort**: kube-proxy открывает фиксированный порт (здесь 30080) на каждом узле. Kind пробрасывает порт 30080 узла `lab-control-plane` на `127.0.0.1:8088` хоста, поэтому запрос на `http://orders.localhost:8088` попадает в Gateway. Браузеры и curl сами разрешают любые имена `*.localhost` в `127.0.0.1`, так что править `/etc/hosts` не нужно.

### Дополнения

**metrics-server** собирает CPU и память подов и узлов; без него не работают `kubectl top` и HPA (05-4). В kind у kubelet самоподписанный сертификат, поэтому скрипт добавляет флаг `--kubelet-insecure-tls`.

**local-path-provisioner** создаёт тома в каталогах на диске узла; в kind он встроен и даёт StorageClass `standard`. Каждый **PVC** (PersistentVolumeClaim, запрос на том, 04-2) получает каталог на том узле, где запущен под.

---

## 3. Как управлять стендом

Стендом управляют два скрипта в каталоге `kubernetes/lab/`, и оба безопасно запускать повторно.

### Подъём: lab-up.sh

Команда `bash kubernetes/lab/lab-up.sh`, запущенная из корня репозитория, выполняет пять шагов. Каждый шаг сначала проверяет, сделано ли уже его дело, поэтому повторный запуск ничего не ломает.

1. Запускает реестр `kind-registry` на `127.0.0.1:5001` с томом `kind-registry-data` и политикой `--restart=always`.
2. Пишет конфиг `~/lab/k8s/kind.yaml` и создаёт кластер `lab`: 1 control-plane и 3 worker.
3. Подключает реестр к docker-сети `kind`, пишет `hosts.toml` в каждый узел и создаёт ConfigMap `local-registry-hosting`.
4. Ставит metrics-server и добавляет флаг `--kubelet-insecure-tls`.
5. Ставит Envoy Gateway Helm-чартом, затем создаёт GatewayClass `eg` и Gateway `lab`.

Первый запуск на машине автора занял 2 мин 9 с, повторный — 18 с. По ходу работы скрипт переключает текущий контекст kubectl на `kind-lab`.

### Выключение и включение

Стенд не нужно держать запущенным. Команда `bash kubernetes/lab/lab-down.sh` без аргументов выполняет `docker stop` для узлов и реестра, а данные etcd, тома PVC и образы в узлах остаются. Команда `lab-up.sh` запускает те же контейнеры и ждёт apiserver. Цикл «выключить и включить» на машине автора занял 51 с (лабораторная работа 4).

### Полная уборка

Команда `bash kubernetes/lab/lab-down.sh --purge` удаляет кластер `lab`, контейнер `kind-registry`, том `kind-registry-data` и каталог `~/lab/k8s`. В каталоге лежат исходники orders-api, поэтому правленый код сохраните заранее. После `--purge` стенд поднимается заново командой `lab-up.sh`, но образы в реестре придётся собрать и отправить снова.

### Контекст kubectl

Скрипт добавляет в `~/.kube/config` контекст `kind-lab` и делает его текущим. Если у вас есть рабочие кластеры, проверяйте контекст командой `kubectl config current-context` перед каждой опасной командой. Стенд можно и вынести в отдельный файл: для этого перед запуском скрипта выполните `export KUBECONFIG=~/lab/k8s/kubeconfig`.

### Как в курсе выполняются команды

Все команды запускаются с хоста: `kubectl` с контекстом `kind-lab` и `docker exec lab-<узел> …`, когда нужно заглянуть в узел. Каждая работа живёт в своём namespace `lab-NN-M` (по номеру части) и удаляет его в уборке. Файлы работы лежат в `~/lab/k8s/NN-M/`, метки и taints узлов имеют префикс `lab-NN-M/`, образы называются `localhost:5001/lab-NN-M/…`.

Namespace `orders` с демо-приложением работы не удаляют. Если работа его меняет, уборка возвращает исходное состояние командой `kubectl apply -f ~/lab/k8s/orders-api/k8s/`. Имена подов, IP-адреса, UID и время в выводах взяты с прогона автора, поэтому у вас они будут другими: сверяйте структуру и порядок величин.

---

## 4. Как увидеть состояние стенда

Состояние стенда видно на трёх уровнях: контейнеры Docker, объекты кластера и путь запроса. Проверку начинайте снизу, с Docker.

### Контейнеры Docker

Узлы и реестр — обычные контейнеры, поэтому их видно в Docker. Таблица показывает команды этого уровня и то, что они сообщают.

| Команда | Что показывает |
|---|---|
| `docker ps --filter name=lab- --filter name=kind-registry` | пять контейнеров стенда и их порты |
| `docker stats --no-stream` | CPU и память каждого контейнера |
| `docker exec lab-worker crictl ps` | контейнеры, запущенные внутри узла |
| `kind get clusters` | список кластеров kind, должен быть `lab` |

Если контейнеров стенда меньше пяти, стенд остановлен целиком или частично, и его запускает `lab-up.sh`.

### Объекты кластера

Если Docker в порядке, смотрим на объекты кластера; все команды ниже только читают состояние.

| Команда | Что показывает |
|---|---|
| `kubectl get nodes` | четыре узла в состоянии Ready |
| `kubectl get pods -A` | все поды; не должно быть Pending и CrashLoopBackOff |
| `kubectl top nodes` | CPU и память узлов (работает metrics-server) |
| `kubectl -n envoy-gateway-system get gateway lab` | Gateway в состоянии Programmed |
| `kubectl config current-context` | текущий контекст, должен быть `kind-lab` |

### Путь запроса

Последний уровень — сквозной запрос к демо-приложению: `curl http://orders.localhost:8088/api/orders`. Он проходит порт хоста, NodePort, Envoy, Service и под, поэтому ответ с данными из PostgreSQL подтверждает, что работают все звенья. Если ответа нет, идите по цепочке от приложения к хосту: под, Service, HTTPRoute, Gateway, NodePort (§5).

---

## 5. Что ломается при подъёме и как найти причину

Большинство сбоев происходит в трёх местах: на хосте (порты, Docker, ядро), на пути образа от реестра к узлу и на входе в кластер. Ниже симптомы сгруппированы по месту, где искать причину.

### Не стартует подъём

Эти сбои происходят до появления кластера, и причина у них на хосте.

- **`Bind for 0.0.0.0:8080 failed: port is already allocated`.** Порт хоста занят другим контейнером, а список занятых портов даёт `docker ps --format '{{.Names}} {{.Ports}}'`. Стенд выбрал 8088, потому что на машине автора порт 8080 занят другим сервисом. Порт меняют в `hostPort` скрипта `lab-up.sh` и в командах курса.
- **`error getting credentials … docker-credential-desktop`.** В `~/.docker/config.json` прописан `credsStore` от Docker Desktop. Удалите ключ или запустите скрипт с `DOCKER_CONFIG=$(mktemp -d)`.
- **`too many open files` в логах kubelet или kube-proxy, узлы NotReady.** Не хватает лимитов inotify. Поднимите их (лабораторная работа 1) и пересоздайте стенд: `lab-down.sh --purge`, затем `lab-up.sh`.
- **kubelet не стартует, в журнале ошибка о cgroup v1.** С Kubernetes 1.35 kubelet по умолчанию отказывается работать на cgroup v1, а образы kind 0.31+ его не поддерживают. Команда `stat -fc %T /sys/fs/cgroup/` на хосте должна вывести `cgroup2fs` (лабораторная работа 1).

### Узлы не скачивают образ

Образ из реестра стенда не приходит на узел, и под зависает до запуска контейнера.

- **`ImagePullBackOff`, в событиях `dial tcp [::1]:5001: connect: connection refused`.** В узле нет файла `/etc/containerd/certs.d/localhost:5001/hosts.toml` или он пустой. Внутри узла `localhost` — сам узел, поэтому без файла pull идёт в никуда. Посмотрите файл через `docker exec lab-worker cat …/hosts.toml` и перезапустите `lab-up.sh`.
- **`manifest unknown` или `not found`.** Образ не отправлен в реестр или у него другой тег. Список тегов даёт `curl -s http://127.0.0.1:5001/v2/orders-api/tags/list`.

### Вход не отвечает

Запрос на `:8088` не доходит до приложения, и здесь важно различать два симптома: отказ и зависание.

- **`curl … :8088` → `Connection refused`.** Gateway не создан или не имеет состояния Programmed. Проверьте `kubectl -n envoy-gateway-system get gateway lab` и повторите `lab-up.sh`.
- **Запрос висит до таймаута, а из пода через Service всё работает.** У Service Envoy стоит `externalTrafficPolicy: Local`, и kube-proxy на узле без пода Envoy сбрасывает пакеты NodePort правилом `has no local endpoints … DROP`. Скрипт задаёт `Cluster` через объект EnvoyProxy; если вы меняли значение, верните его (разбор в 03-2).

### Демо-приложение не готово

Если orders-api висит в `0/1 Running`, а в логах есть `db not ready: …`, то PostgreSQL не готов или неверен `DATABASE_URL`. Смотрите `kubectl -n orders get pods` и `kubectl -n orders logs deploy/orders-api`. Приложение делает 30 попыток подключения с паузой и таймаутом соединения по 2 секунды, то есть ждёт от 60 до 120 секунд. Затем процесс завершается, и kubelet перезапускает контейнер.

### Нет доступа к кластеру

Если после перезагрузки машины `kubectl` получает `connection refused`, контейнеры узлов остановлены: kind не запускает их сам. Запуск `lab-up.sh` стартует узлы и дожидается apiserver. Если же `kubectl` ходит не в тот кластер, текущий контекст не `kind-lab`, и его возвращает `kubectl config use-context kind-lab`.

---

## 6. Пределы и значения по умолчанию

Стенд ограничен ресурсами машины и особенностями kind; числа ниже измерены на машине автора или взяты из скриптов.

### Ресурсы

Пустой стенд с orders-api занимает около 2,5 ГиБ RAM по замеру `docker stats`. Из них control-plane берёт 1,3 ГиБ, каждый worker — 0,3–0,4 ГиБ, реестр — 18 МиБ. С расширениями модулей 08–09 потребление доходит до 5 ГиБ. Образ узла kind занимает около 1 ГБ диска, весь стенд — около 3 ГБ.

Скрипт `lab-up.sh` ждёт создания кластера до 120 секунд и готовности узлов до 180 секунд. Для metrics-server и Gateway предел тоже 180 с, а для установки Envoy Gateway Helm-чартом — 5 мин.

### Особенности kind

Эти три свойства отличают стенд от настоящего кластера и встречаются в лабораторных работах.

- **Каждый узел видит все CPU и всю память хоста.** На машине автора у каждого из четырёх узлов `cpu: 12` и `memory: 16315248Ki`, хотя узлы делят одно железо.
- **Пороги eviction отключены.** **Eviction** — выселение подов kubelet при нехватке памяти или диска. Kind задаёт пороги диска `0%`, и тогда kubelet обнуляет и остальные пороги, включая память; резервов тоже нет (05-1, 05-5).
- **LoadBalancer не работает.** Service этого типа остаётся в `<pending>`, поэтому вход в кластер идёт через NodePort 30080, проброшенный на `127.0.0.1:8088`; вариант с cloud-provider-kind разбирает 03-2.

### Версии

Версии в курсе: kind 0.32.0, Kubernetes 1.36.1 и containerd 2.3.1. Дополнения — Envoy Gateway 1.9.2 и metrics-server 0.8.0, база — PostgreSQL 17.6. Kubernetes 1.37 и kind 0.33 уже вышли, но стенд остаётся на 1.36, а важные отличия 1.37 названы в частях. С kind 0.32 патчи kubeadm в конфиге kind для 1.36+ пишутся в формате `v1beta4` (10-1).

Версия kubectl может отличаться от версии кластера не больше чем на одну минорную, то есть для кластера 1.36 подходят 1.35–1.37. Это правило **version skew** (допустимое расхождение версий компонентов, 10-3). Пароль PostgreSQL в манифестах учебный, а как хранят секреты на самом деле, разбирают части 04-1 и 08-2.

---

## Лабораторные работы

Работы идут по порядку: установка инструментов, подъём стенда, демо-приложение, выключение и включение. Работа 3 нужна всем остальным частям курса, поэтому не пропускайте её. Namespace `lab-NN-M` здесь не нужен, потому что работы настраивают сам стенд, а демо-приложение живёт в namespace `orders` (§3).

### Лабораторная работа 1. Установка инструментов и лимиты inotify

Эту работу вы выполняете сами, результаты в ней — ожидаемые.

**Цель.** Установить Docker, kind, kubectl и helm, проверить cgroup v2 и поднять лимиты **inotify** (механизм ядра Linux, который сообщает программам об изменениях файлов). Без нужных лимитов кластер из четырёх узлов падает при старте.

**Что понадобится.**

- Ubuntu 24.04 или Manjaro, права `sudo`, доступ в интернет.
- Около 1 ГБ свободного диска под бинарники и пакеты.
- Docker 27 или новее, если он уже установлен.
- Около 15 минут.

**Схема опыта.** Каждый узел kind запускает systemd и kubelet, и оба расходуют inotify-экземпляры. Лимит считается по пользователю, а не по контейнеру: процессы узлов работают от root хоста, поэтому все узлы делят один счётчик.

```
fs.inotify.max_user_instances (128 по умолчанию в ядре)
   ├─ узел lab-control-plane   systemd + kubelet + containerd
   ├─ узел lab-worker          systemd + kubelet + containerd
   ├─ узел lab-worker2         systemd + kubelet + containerd
   └─ узел lab-worker3         systemd + kubelet + containerd
        вместе с другими процессами root упираются в лимит -> too many open files
```

Схема показывает общий счётчик пользователя root; если он мал, первыми отказывают kubelet и kube-proxy.

**Риски.** Работа меняет пакеты и параметры ядра на хосте.

- **Что меняется:** ставятся пакеты Docker, бинарники `kind` и `helm` в `/usr/local/bin`, пакет `kubectl`; создаётся файл `/etc/sysctl.d/99-kind.conf` и меняются два параметра ядра.
- **Надолго ли:** до ручной отмены; sysctl-файл переживает перезагрузку.
- **Безопасность:** участник группы `docker` получает права, равные root на хосте. Добавляйте в группу только свою учётную запись. Бинарники и ключи скачиваются с официальных адресов по HTTPS.
- **Влияние на систему:** лимит inotify поднимает потолок памяти ядра, которую могут занять наблюдатели. Значения 512 и 524288 рекомендует документация kind (Known Issues).
- **Откат:** блок «Уборка» в конце работы.

#### Шаг 1. Проверить, что уже есть

Смотрим версии инструментов, версию cgroup и свободное место; команды только читают состояние. Если инструмент уже стоит нужной версии, соответствующий шаг пропустите.

```bash
docker --version
kind version
kubectl version --client
helm version --short
stat -fc %T /sys/fs/cgroup/
df -h /var/lib/docker /home
```

Разбор команд:

| Часть команды | Значение |
|---|---|
| `docker --version` | версия Docker; нужна 27 или новее |
| `kind version` | версия kind; в курсе 0.32.0 |
| `kubectl version --client` | версия kubectl без обращения к кластеру |
| `helm version --short` | версия helm; в курсе 4.2.x |
| `stat -fc %T /sys/fs/cgroup/` | тип файловой системы cgroup; нужен `cgroup2fs` |
| `df -h … /home` | свободное место в каталогах Docker и дома |

Результат на чистой машине (ожидаемый):

```
Command 'docker' not found, but can be installed with: …
Command 'kind' not found …
cgroup2fs
```

Разбор вывода:

1. Сообщение `not found` значит, что инструмента нет и его надо установить.
2. Строка `cgroup2fs` значит, что хост работает на cgroup v2. Вывод `tmpfs` означает cgroup v1, на котором kubelet 1.35+ не стартует: сначала переведите систему на cgroup v2.
3. На диске должно оставаться не меньше 20 ГБ свободного места.

#### Шаг 2. Установить Docker

Docker запускает узлы kind. На Ubuntu подойдёт пакет `docker.io` из стандартного репозитория, если его версия не ниже 27; иначе поставьте `docker-ce` из репозитория Docker. На Manjaro пакет называется `docker`, а службу нужно включить вручную.

```bash
# Ubuntu
sudo apt-get update && sudo apt-get install -y docker.io
sudo usermod -aG docker "$USER"

# Manjaro
sudo pacman -S docker
sudo systemctl enable --now docker
sudo usermod -aG docker "$USER"
```

Разбор команд:

| Часть команды | Значение |
|---|---|
| `apt-get install -y docker.io` | поставить Docker из репозитория Ubuntu |
| `pacman -S docker` | поставить Docker из репозитория Manjaro |
| `systemctl enable --now docker` | включить службу и запустить сразу |
| `usermod -aG docker "$USER"` | добавить вас в группу `docker`, чтобы не писать `sudo` |

Выйдите из сеанса и войдите снова, потому что группа применяется при входе, а затем проверьте Docker.

```bash
docker run --rm hello-world
```

Результат (ожидаемый):

```
Hello from Docker!
This message shows that your installation appears to be working correctly.
…
```

Разбор вывода: приветствие значит, что демон работает и вы можете запускать контейнеры без `sudo`.

#### Шаг 3. Установить kind, kubectl и helm

Три инструмента ставятся независимо, и команды ниже даны для Ubuntu. На Manjaro все три ставятся одной командой `sudo pacman -S kind kubectl helm`.

```bash
# kind — один статический бинарник
curl -Lo /tmp/kind https://kind.sigs.k8s.io/dl/v0.32.0/kind-linux-amd64
sudo install -m 0755 /tmp/kind /usr/local/bin/kind && rm /tmp/kind

# kubectl — официальный репозиторий, ветка минорной версии v1.36
K8S_REPO=https://pkgs.k8s.io/core:/stable:/v1.36/deb
KEYRING=/etc/apt/keyrings/kubernetes-apt-keyring.gpg
sudo mkdir -p /etc/apt/keyrings
curl -fsSL "$K8S_REPO/Release.key" | sudo gpg --dearmor -o "$KEYRING"
echo "deb [signed-by=$KEYRING] $K8S_REPO/ /" | \
  sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt-get update && sudo apt-get install -y kubectl

# helm — бинарник с релиза (версию сверьте на github.com/helm/helm/releases)
curl -fsSL https://get.helm.sh/helm-v4.2.2-linux-amd64.tar.gz | \
  tar -xz -C /tmp linux-amd64/helm
sudo install -m 0755 /tmp/linux-amd64/helm /usr/local/bin/helm
```

Разбор команд:

| Часть команды | Значение |
|---|---|
| `install -m 0755 … /usr/local/bin/kind` | положить бинарник в `PATH` с правом запуска |
| `gpg --dearmor -o "$KEYRING"` | сохранить ключ репозитория в формате apt |
| `signed-by=$KEYRING` | доверять пакетам этого репозитория только по этому ключу |
| `/v1.36/` | ветка репозитория: kubectl версии 1.36 |
| `tar -xz -C /tmp linux-amd64/helm` | распаковать из архива один файл `helm` |

Проверяем версии.

```bash
kind version
kubectl version --client
helm version --short
```

Результат (ожидаемый, сокращён):

```
kind v0.32.0 go… linux/amd64
Client Version: v1.36.x
v4.2.2+g…
```

Разбор вывода:

1. kind версии 0.32.0 поддерживает образ узла `kindest/node:v1.36.1`, который скрипт стенда задаёт явно.
2. kubectl 1.36.x подходит кластеру 1.36 по правилу version skew (§6).
3. helm нужен скрипту подъёма для установки Envoy Gateway.

#### Шаг 4. Поднять лимиты inotify

Смотрим текущие значения и записываем новые в файл `/etc/sysctl.d/99-kind.conf`, а команда `sysctl --system` применяет все файлы настроек без перезагрузки.

```bash
sysctl fs.inotify.max_user_instances fs.inotify.max_user_watches
sudo tee /etc/sysctl.d/99-kind.conf <<'EOF'
fs.inotify.max_user_instances = 512
fs.inotify.max_user_watches = 524288
EOF
sudo sysctl --system
sysctl fs.inotify.max_user_instances fs.inotify.max_user_watches
```

Разбор команд:

| Часть команды | Значение |
|---|---|
| `max_user_instances` | сколько inotify-объектов может создать один пользователь |
| `max_user_watches` | сколько файлов он может отслеживать |
| `tee /etc/sysctl.d/99-kind.conf` | записать значения в файл, который читается при загрузке |
| `sysctl --system` | перечитать все файлы настроек и применить |

Результат (ожидаемый, на Ubuntu с настройками по умолчанию):

```
fs.inotify.max_user_instances = 128
fs.inotify.max_user_watches = …
…
fs.inotify.max_user_instances = 512
fs.inotify.max_user_watches = 524288
```

Разбор вывода:

1. Первые две строки — значения до изменения. Лимит экземпляров по умолчанию равен 128, а лимит наблюдений ядро считает при загрузке от объёма памяти: от 8192 до 1048576. На машине автора (Manjaro) лимит экземпляров уже был 1024, и ошибок не было.
2. Последние две строки — значения после изменения.
3. Если в первых строках значения уже были больше новых, файл их понизил. Тогда впишите в файл прежние значения или удалите его и перезагрузитесь.

#### Итог

Что вы узнали:

| Что узнали | Как проверить |
|---|---|
| Для стенда нужны Docker, kind, kubectl и helm | `docker --version`, `kind version`, `kubectl version --client`, `helm version --short` |
| Хост работает на cgroup v2 | `stat -fc %T /sys/fs/cgroup/` |
| Узлы kind делят один лимит inotify | `sysctl fs.inotify.max_user_instances` |
| Версия kubectl не дальше чем на одну минорную от кластера | `kubectl version` (после подъёма стенда) |
| Параметры ядра сохраняются в `/etc/sysctl.d` | `cat /etc/sysctl.d/99-kind.conf` |

#### Уборка

Инструменты нужны всему курсу, поэтому их оставляем, а настройку ядра удаляем, только если хотите вернуть исходное состояние. Делайте это после окончания курса: без неё стенд может не подняться на машине с лимитом 128.

```bash
sudo rm /etc/sysctl.d/99-kind.conf
sudo sysctl --system
```

Разбор: первая команда удаляет файл, вторая перечитывает оставшиеся настройки. Значения ядра возвращаются к исходным после следующей загрузки, потому что `sysctl --system` не сбрасывает параметр, которого нет в файлах.

#### Вопросы для самопроверки

1. Почему лимит `max_user_instances` важнее для kind, чем для обычного Docker?

<details><summary>Ответ</summary>

Каждый узел kind — это systemd и kubelet, а они создают inotify-экземпляры. Процессы всех узлов работают от root хоста и делят один лимит, поэтому четыре узла быстро исчерпывают 128, и kubelet получает `too many open files`.

</details>

2. Чем опасно добавление пользователя в группу `docker`?

<details><summary>Ответ</summary>

Участник группы управляет демоном Docker, который работает от root. Он может смонтировать любой каталог хоста в контейнер, читать и менять его, поэтому права группы `docker` равны правам root.

</details>

3. kubectl 1.38 и кластер 1.36: допустимо ли?

<details><summary>Ответ</summary>

Нет. Допустимое расхождение — одна минорная версия в обе стороны, поэтому для кластера 1.36 подходят kubectl 1.35, 1.36 и 1.37. Разница в две версии выходит за поддерживаемые границы.

</details>

### Лабораторная работа 2. Подъём стенда и проверка

**Цель.** Поднять стенд скриптом `lab-up.sh` и убедиться, что узлы, реестр, metrics-server и Gateway работают, а узлы кластера — обычные контейнеры Docker.

**Что понадобится.**

- Инструменты из работы 1: Docker, kind, kubectl, helm.
- Клон репозитория курса, в примерах каталог `~/ai/runbooks`.
- Свободные порты хоста 5001 и 8088.
- Около 3 ГБ диска, 2,5 ГиБ RAM; скачивание порядка 1,5 ГБ образов.
- Около 3 минут на подъём.

**Схема опыта.** Скрипт создаёт реестр и кластер, затем ставит дополнения, а мы проверяем результат по слоям, как в §4: контейнеры, объекты, дополнения.

```
lab-up.sh ─► kind-registry ─► кластер lab (4 узла) ─► hosts.toml в узлах
                                                          │
                                  metrics-server ◄────────┤
                                  Envoy Gateway + Gateway lab
проверяем:  docker ps ─► kubectl get nodes ─► kubectl top ─► get gateway
```

Схема показывает порядок подъёма слева направо; нижняя строка — проверка в том же порядке.

**Риски.** Работа создаёт контейнеры, том и запись в kubeconfig.

- **Что меняется:** пять контейнеров Docker (`lab-*`, `kind-registry`), том `kind-registry-data`, образы `kindest/node` и `registry`, каталог `~/lab/k8s`, контекст `kind-lab` в `~/.kube/config`, порты `127.0.0.1:5001` и `127.0.0.1:8088`.
- **Надолго ли:** до `lab-down.sh --purge`. Контейнер реестра запущен с `--restart=always`, поэтому он стартует вместе с Docker.
- **Безопасность:** порты слушают только `127.0.0.1`. Узлы kind работают в режиме privileged, то есть имеют почти полный доступ к ядру хоста, поэтому не публикуйте порты стенда наружу.
- **Влияние на систему:** около 2,5 ГиБ RAM и 3 ГБ диска; чужие контейнеры и сети не затрагиваются. Текущий контекст kubectl меняется на `kind-lab`.
- **Откат:** `lab-down.sh --purge` (уборка этой работы); контекст возвращается командой `kubectl config use-context <прежний>`.

#### Шаг 1. Запомнить текущий контекст

Перед подъёмом запоминаем контекст, который скрипт заменит, и смотрим занятые порты; команды только читают состояние.

```bash
kubectl config current-context
docker ps --format '{{.Names}} {{.Ports}}'
```

Разбор команд:

| Часть команды | Значение |
|---|---|
| `config current-context` | имя контекста, который скрипт переключит на `kind-lab` |
| `--format '{{.Names}} {{.Ports}}'` | показать имена контейнеров и занятые порты хоста |

Результат: имя вашего прежнего контекста и список контейнеров с портами. Если у вас нет kubectl-конфига, первая команда сообщит `error: current-context is not set`.

Разбор вывода:

1. Запишите прежний контекст, он понадобится для отката.
2. Если в списке портов есть `5001` или `8088`, освободите их или смените порт (§5).

#### Шаг 2. Запустить lab-up.sh

Запускаем скрипт из корня репозитория: он работает около двух минут и печатает заголовки шагов `== …`.

```bash
cd ~/ai/runbooks
bash kubernetes/lab/lab-up.sh
```

Разбор команд:

| Часть команды | Значение |
|---|---|
| `cd ~/ai/runbooks` | корень репозитория курсов |
| `bash kubernetes/lab/lab-up.sh` | поднять реестр, кластер и дополнения |

Результат (конец вывода первого запуска, 2 мин 9 с):

```
== Envoy Gateway 1.9.2 (+ CRD Gateway API)
gateway.gateway.networking.k8s.io/lab condition met

== готово
NAME                STATUS   ROLES           AGE    VERSION
lab-control-plane   Ready    control-plane   2m2s   v1.36.1
lab-worker          Ready    <none>          108s   v1.36.1
lab-worker2         Ready    <none>          108s   v1.36.1
lab-worker3         Ready    <none>          108s   v1.36.1

Контекст: kind-lab · реестр: localhost:5001 · вход: http://<имя>.localhost:8088 (Gateway lab)
```

Разбор вывода:

1. `condition met` — Gateway `lab` получил состояние Programmed: Envoy готов принимать трафик.
2. Строка `== готово` значит, что скрипт дошёл до конца.
3. Все четыре узла в состоянии `Ready`, версия `v1.36.1`.
4. Control plane старше рабочих узлов: kind создаёт его первым.
5. Последняя строка напоминает контекст и адрес входа.

#### Шаг 3. Проверить узлы как контейнеры

Узлы кластера видны в Docker, поэтому смотрим список контейнеров и заглядываем внутрь одного узла.

```bash
docker ps --format '{{.Names}}\t{{.Image}}' | sort
docker exec lab-worker crictl ps
```

Разбор команд:

| Часть команды | Значение |
|---|---|
| `docker ps --format …` | имя и образ каждого запущенного контейнера |
| `sort` | упорядочить имена |
| `docker exec lab-worker` | выполнить команду внутри узла `lab-worker` |
| `crictl ps` | контейнеры, которые containerd запустил на узле |

Результат (сокращён, образы без дайджестов):

```
kind-registry          registry:2.8.3
lab-control-plane      kindest/node:v1.36.1
lab-worker             kindest/node:v1.36.1
lab-worker2            kindest/node:v1.36.1
lab-worker3            kindest/node:v1.36.1
CONTAINER      IMAGE      …   NAME          POD
…              …          …   kindnet-cni   kindnet-…
…              …          …   kube-proxy    kube-proxy-…
```

Разбор вывода:

1. Пять контейнеров: четыре узла из образа `kindest/node` и реестр.
2. Внутри узла `crictl ps` показывает системные контейнеры: `kindnet-cni` (сеть) и `kube-proxy` (правила Service). На вашем узле набор может быть шире, потому что там работают и поды дополнений.

#### Шаг 4. Проверить реестр и доступ узла к нему

Убеждаемся, что реестр отвечает с хоста и что узел видит его как `localhost:5001` благодаря файлу `hosts.toml`, который создал скрипт.

```bash
curl -s http://127.0.0.1:5001/v2/_catalog
docker exec lab-worker cat /etc/containerd/certs.d/localhost:5001/hosts.toml
```

Разбор команд:

| Часть команды | Значение |
|---|---|
| `curl -s …/v2/_catalog` | список репозиториев в реестре |
| `cat …/hosts.toml` | файл, который перенаправляет `localhost:5001` в реестр |

Результат (ожидаемый; пока образов нет):

```
{"repositories":[]}
[host."http://kind-registry:5000"]
```

Разбор вывода:

1. Реестр пуст: образ orders-api появится в работе 3.
2. Во второй строке containerd получает адрес `kind-registry:5000` для запросов к `localhost:5001`.

#### Шаг 5. Проверить metrics-server и Gateway

Проверяем дополнения и класс томов. Метрики появляются примерно через минуту после старта metrics-server.

```bash
kubectl top nodes
kubectl -n envoy-gateway-system get gateway lab
kubectl get storageclass
```

Разбор команд:

| Часть команды | Значение |
|---|---|
| `top nodes` | CPU и память узлов из metrics-server |
| `get gateway lab` | состояние Gateway |
| `get storageclass` | классы томов; нужен `standard` |

Результат (ожидаемый, сокращён; цифры у вас другие):

```
NAME                CPU(cores)   CPU(%)   MEMORY(bytes)   MEMORY(%)
lab-control-plane   …            …        …               …
…
NAME   CLASS   ADDRESS   PROGRAMMED   AGE
lab    eg      …         True         …
NAME                 PROVISIONER             …
standard (default)   rancher.io/local-path   …
```

Разбор вывода:

1. Таблица `top nodes` с цифрами значит, что metrics-server собирает метрики. При `Metrics API not available` подождите минуту.
2. `PROGRAMMED True` — Gateway готов принимать трафик.
3. StorageClass `standard` назначен классом по умолчанию.

#### Шаг 6. Увидеть, что узлы делят ресурсы хоста

Спрашиваем у каждого узла, сколько CPU и памяти он видит, чтобы увидеть особенность kind из §6.

```bash
kubectl get nodes \
  -o custom-columns='NODE:.metadata.name,CPU:.status.capacity.cpu,MEM:.status.capacity.memory'
```

Разбор команд:

| Часть команды | Значение |
|---|---|
| `-o custom-columns=…` | вывести только выбранные поля |
| `.status.capacity.cpu` | сколько ядер видит узел |
| `.status.capacity.memory` | сколько памяти видит узел |

Результат (на машине автора; формат колонок ожидаемый):

```
NODE                CPU   MEM
lab-control-plane   12    16315248Ki
lab-worker          12    16315248Ki
lab-worker2         12    16315248Ki
lab-worker3         12    16315248Ki
```

Разбор вывода:

1. У всех узлов одинаковые значения: это CPU и память всего хоста.
2. Сумма ёмкостей узлов вчетверо больше физического железа. Scheduler считает каждый узел отдельно и может разместить на стенде больше, чем выдержит хост, поэтому манифесты лабораторных задают requests и limits явно.

#### Итог

Что вы узнали:

| Что узнали | Как проверить |
|---|---|
| `lab-up.sh` поднимает реестр, кластер и дополнения за 2–3 минуты | строка `== готово` |
| Узлы — контейнеры Docker, четыре штуки | `docker ps` |
| Узлы видят реестр как `localhost:5001` | `hosts.toml` в узле |
| Metrics-server и Gateway работают | `kubectl top nodes`, `get gateway lab` |
| Каждый узел видит все ресурсы хоста | `-o custom-columns` по `capacity` |

#### Уборка

Стенд нужен следующим работам, поэтому здесь ничего не удаляем; полная уборка описана в конце работы 4 и выполняется после окончания курса.

#### Вопросы для самопроверки

1. Почему узел не может скачать образ с `localhost:5001` без дополнительного файла?

<details><summary>Ответ</summary>

Внутри контейнера-узла `localhost` — сам узел, а реестр работает в другом контейнере. Файл `hosts.toml` говорит containerd, что за `localhost:5001` стоит адрес `http://kind-registry:5000` в docker-сети.

</details>

2. Как отличить сбой подъёма в Docker от сбоя в кластере?

<details><summary>Ответ</summary>

Начните с `docker ps`, где должны работать пять контейнеров; если их меньше, проблема в Docker или в скрипте. Если контейнеры есть, а `kubectl get nodes` не отвечает или показывает NotReady, проблема в кластере. Тогда смотрите `docker logs lab-control-plane` и `journalctl -u kubelet` внутри узла.

</details>

3. Что значит `PROGRAMMED True` у Gateway?

<details><summary>Ответ</summary>

Контроллер Envoy Gateway принял конфигурацию и настроил прокси, который слушает порт 80. Без этого состояния запрос `curl` к `:8088` получит `Connection refused`.

</details>

### Лабораторная работа 3. Демо-приложение orders-api и PostgreSQL

**Цель.** Собрать образ orders-api, отправить его в реестр стенда и развернуть приложение вместе с PostgreSQL в namespace `orders`, где оно служит демонстрационной нагрузкой для всех частей.

**Что понадобится.**

- Работающий стенд из работы 2.
- Доступ в интернет: образы `python:3.12-slim` и `postgres:17.6-alpine`, пакет `psycopg` с PyPI.
- До 1 ГБ диска под базовые образы и образ приложения (оценка).
- Около 25 минут.

**Схема опыта.** orders-api — небольшой HTTP-сервис на Python, который читает заказы из PostgreSQL и отвечает на пробы готовности. Запрос идёт от хоста через Gateway.

```
curl orders.localhost:8088 ─► NodePort 30080 ─► Envoy ─► HTTPRoute orders-api
                                                              │
                                  Service orders-api (80) ◄───┘
                                       │  2 пода
                                       ▼
                           orders-api :8000 ─► Service postgres (headless)
                                                       │
                                             StatefulSet postgres-0 + PVC 1 Gi
```

Схема показывает путь запроса сверху вниз. Данные лежат в PVC на диске узла, поэтому они переживают перезапуск пода.

**Риски.** Работа собирает образ на хосте и создаёт объекты в кластере.

- **Что меняется:** локальный образ Docker `localhost:5001/orders-api:2.0`, каталог `~/lab/k8s/orders-api`, namespace `orders` с подами, Secret, PVC и HTTPRoute.
- **Надолго ли:** до `lab-down.sh --purge`. Namespace `orders` остальные работы не удаляют.
- **Безопасность:** пароль PostgreSQL лежит в манифесте открытым текстом, он учебный. Контейнер orders-api работает от пользователя 10001, не от root.
- **Влияние на систему:** запросы памяти подов — 384 МиБ, пределы — 1 ГиБ, том — 1 ГиБ; хост и другие кластеры не затрагиваются.
- **Откат:** `kubectl delete ns orders` и `docker image rm localhost:5001/orders-api:2.0`.

#### Шаг 1. Создать код приложения

Создаём каталоги и файл `app/main.py`. Сервис отвечает на шесть путей, которые перечислены в таблице после кода, а переменные окружения управляют его поведением.

```bash
mkdir -p ~/lab/k8s/orders-api/{app,k8s} && cd ~/lab/k8s/orders-api
touch app/__init__.py

cat > app/main.py <<'E'
import json
import os
import signal
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

VERSION = os.environ.get("APP_VERSION", "dev")
# без DATABASE_URL (из Secret) данные хранятся в памяти
DATABASE_URL = os.environ.get("DATABASE_URL")
# файл из ConfigMap, смонтированный томом
CONFIG_FILE = os.environ.get("CONFIG_FILE", "/etc/orders/config.json")
# имитация медленного старта: пока идёт задержка, порт закрыт (02-5)
STARTUP_DELAY = float(os.environ.get("STARTUP_DELAY", "0"))
# сколько ещё обслуживать запросы после SIGTERM (02-5)
SHUTDOWN_DELAY = float(os.environ.get("SHUTDOWN_DELAY", "0"))
STATIC_ORDERS = [{"id": 1, "item": "book", "qty": 2}, {"id": 2, "item": "pen", "qty": 5}]
state = {"ready": False, "terminating": False}


def db():
    import psycopg
    return psycopg.connect(DATABASE_URL, connect_timeout=2)


def init_db():
    with db() as conn:
        conn.execute(
            "CREATE TABLE IF NOT EXISTS orders "
            "(id serial PRIMARY KEY, item text NOT NULL, qty int NOT NULL)")
        if conn.execute("SELECT count(*) FROM orders").fetchone()[0] == 0:
            conn.cursor().executemany(
                "INSERT INTO orders (item, qty) VALUES (%s, %s)",
                [("book", 2), ("pen", 5)])


def get_orders():
    if not DATABASE_URL:
        return STATIC_ORDERS
    with db() as conn:
        rows = conn.execute("SELECT id, item, qty FROM orders ORDER BY id").fetchall()
    return [{"id": r[0], "item": r[1], "qty": r[2]} for r in rows]


def read_config():
    try:
        with open(CONFIG_FILE) as f:
            return json.load(f)
    except (OSError, ValueError) as e:
        return {"error": str(e)}


def burn(ms):                       # ~ms миллисекунд чистого CPU (05-1, 05-4)
    end = time.thread_time() + ms / 1000
    while time.thread_time() < end:
        pass


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        url = urlparse(self.path)
        pod = os.environ.get("HOSTNAME", "")
        try:
            if url.path == "/health":                 # liveness: процесс жив и отвечает
                self._send(200, {"status": "ok"})
            elif url.path == "/ready":                # readiness: готов принимать трафик
                if state["terminating"] or not state["ready"]:
                    self._send(503, {"ready": False, "terminating": state["terminating"]})
                else:
                    if DATABASE_URL:
                        with db() as conn:
                            conn.execute("SELECT 1")
                    self._send(200, {"ready": True})
            elif url.path == "/version":
                self._send(200, {"version": VERSION, "pod": pod})
            elif url.path == "/api/orders":
                orders = get_orders()
                self._send(200, {
                    "orders": orders,
                    "total_items": sum(o["qty"] for o in orders),
                    "pod": pod})
            elif url.path == "/config":
                self._send(200, {
                    "env_FEATURE_DISCOUNT": os.environ.get("FEATURE_DISCOUNT"),
                    "file": read_config()})
            elif url.path == "/work":
                ms = int(parse_qs(url.query).get("ms", ["100"])[0])
                t = time.perf_counter()
                burn(ms)
                wall = round((time.perf_counter() - t) * 1000)
                self._send(200, {"cpu_ms": ms, "wall_ms": wall})
            else:
                self._send(404, {"error": "not found"})
        except Exception as e:                        # БД недоступна и т. п.
            self._send(503, {"error": type(e).__name__, "detail": str(e)[:200]})

    def log_message(self, fmt, *args):
        print(f"{self.address_string()} {fmt % args}", flush=True)


def startup():
    if DATABASE_URL:
        for _ in range(30):
            try:
                init_db()
                break
            except Exception as e:
                print(f"db not ready: {type(e).__name__}: {e}", flush=True)
                time.sleep(2)
        else:
            print("db unavailable, exit", flush=True)
            os._exit(1)
    state["ready"] = True
    print("ready", flush=True)


def main():
    port = int(os.environ.get("PORT", "8000"))
    time.sleep(STARTUP_DELAY)                     # пока «стартуем», порт закрыт
    server = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    server.daemon_threads = True

    def stop_later():
        time.sleep(SHUTDOWN_DELAY)
        server.shutdown()

    def on_sigterm(signum, frame):
        print(f"SIGTERM: not ready, serving {SHUTDOWN_DELAY:g}s more", flush=True)
        state["terminating"] = True
        threading.Thread(target=stop_later, daemon=True).start()

    signal.signal(signal.SIGTERM, on_sigterm)
    print(f"orders-api {VERSION} listening on :{port} db={'yes' if DATABASE_URL else 'no'}",
          flush=True)
    threading.Thread(target=startup, daemon=True).start()
    server.serve_forever()
    server.server_close()
    print("bye", flush=True)


if __name__ == "__main__":
    main()
E
```

Разбор команд:

| Часть команды | Значение |
|---|---|
| `mkdir -p …/{app,k8s}` | каталоги для кода и манифестов |
| `touch app/__init__.py` | сделать `app` пакетом Python |
| `cat > app/main.py <<'E' … E` | записать код; кавычки у `'E'` отключают подстановки |

Что умеет приложение:

| Путь | Что отвечает | Где используется |
|---|---|---|
| `/health` | 200, пока процесс жив | liveness (02-5) |
| `/ready` | 200, если старт закончен и БД отвечает | readiness (02-5), Service (03-2) |
| `/api/orders` | заказы из PostgreSQL и имя пода | сквозной запрос |
| `/version` | версия и имя пода | rollout (02-2), canary (03-4) |
| `/config` | переменная FEATURE_DISCOUNT и файл конфига | ConfigMap (04-1) |
| `/work?ms=N` | сжечь N мс CPU | троттлинг, HPA (05-1, 05-4) |

Приложение читает три переменные окружения:

- **`DATABASE_URL`** — адрес базы из Secret; без него заказы берутся из памяти;
- **`STARTUP_DELAY`** — сколько секунд порт остаётся закрытым, для опытов со startupProbe;
- **`SHUTDOWN_DELAY`** — сколько секунд обслуживать запросы после SIGTERM.

После SIGTERM путь `/ready` отвечает 503, поэтому под выходит из Service ещё до остановки процесса.

Разбор результата: команды ничего не печатают, а созданные файлы показывает `ls app/`.

#### Шаг 2. Собрать образ и отправить в реестр

Пишем Dockerfile и файл зависимостей, собираем образ и отправляем его в реестр стенда. Процесс работает от пользователя 10001, а не от root, а версия приложения передаётся аргументом сборки.

```bash
echo 'psycopg[binary]==3.2.10' > requirements.txt

cat > Dockerfile <<'E'
FROM python:3.12-slim
WORKDIR /srv
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app/ app/
USER 10001
ARG APP_VERSION=dev
ENV APP_VERSION=$APP_VERSION PORT=8000 PYTHONUNBUFFERED=1
EXPOSE 8000
CMD ["python", "-m", "app.main"]
E

docker build -t localhost:5001/orders-api:2.0 --build-arg APP_VERSION=2.0 .
docker push localhost:5001/orders-api:2.0
curl -s http://127.0.0.1:5001/v2/orders-api/tags/list
```

Разбор команд:

| Часть команды | Значение |
|---|---|
| `psycopg[binary]==3.2.10` | драйвер PostgreSQL с готовым бинарником |
| `USER 10001` | запускать процесс не от root |
| `-t localhost:5001/orders-api:2.0` | имя образа: адрес реестра, имя, тег |
| `--build-arg APP_VERSION=2.0` | версия, которую отдаёт `/version` |
| `docker push …` | загрузить образ в реестр стенда |
| `…/v2/orders-api/tags/list` | спросить у реестра, какие теги есть |

Результат (push; сборка занимает около минуты, вывод сокращён):

```
2.0: digest: sha256:ad4f8fd2cabaef73e735d9a623a3499270fd5f3a5d7f640719bfd0982e772465 size: 1991
{"name":"orders-api","tags":["2.0"]}
```

Разбор вывода:

1. `digest: sha256:…` — **дайджест** (digest), хэш содержимого образа. У вас он будет другой: он зависит от времени сборки и слоёв базового образа.
2. `size: 1991` — размер манифеста образа в байтах, а не самого образа.
3. Ответ реестра подтверждает тег `2.0`.

Проверяем, что узел тянет образ из реестра.

```bash
docker exec lab-worker crictl pull localhost:5001/orders-api:2.0
```

Результат (ожидаемый):

```
Image is up to date for sha256:…
```

Разбор вывода: узел достиг реестра по `hosts.toml` и получил образ. Фразу `Image is up to date for` crictl печатает после любого успешного pull, даже если образ скачан впервые.

#### Шаг 3. Развернуть PostgreSQL

Создаём namespace `orders`, Secret с учётными данными, headless Service и StatefulSet. **StatefulSet** — контроллер для подов со стабильным именем и собственным томом (02-3). **Headless Service** (`clusterIP: None`) не получает виртуальный адрес, и DNS возвращает адреса подов напрямую.

```bash
cd ~/lab/k8s/orders-api/k8s
cat > postgres.yaml <<'E'
apiVersion: v1
kind: Secret
metadata: {name: postgres, namespace: orders}
type: Opaque
stringData:
  POSTGRES_USER: orders
  POSTGRES_PASSWORD: orders-lab-pass        # учебный пароль стенда
  POSTGRES_DB: orders
  DATABASE_URL: postgresql://orders:orders-lab-pass@postgres:5432/orders
---
apiVersion: v1
kind: Service
metadata: {name: postgres, namespace: orders}
spec:
  clusterIP: None                            # headless: DNS-имена postgres-0.postgres
  selector: {app: postgres}
  ports: [{name: pg, port: 5432}]
---
apiVersion: apps/v1
kind: StatefulSet
metadata: {name: postgres, namespace: orders}
spec:
  serviceName: postgres
  replicas: 1
  selector: {matchLabels: {app: postgres}}
  template:
    metadata: {labels: {app: postgres}}
    spec:
      containers:
      - name: postgres
        image: postgres:17.6-alpine
        envFrom: [{secretRef: {name: postgres}}]
        env: [{name: PGDATA, value: /var/lib/postgresql/data/pgdata}]
        ports: [{name: pg, containerPort: 5432}]
        readinessProbe:
          exec: {command: ["pg_isready", "-U", "orders", "-d", "orders"]}
          periodSeconds: 5
        resources:
          requests: {cpu: 100m, memory: 256Mi}
          limits:   {memory: 512Mi}
        volumeMounts: [{name: data, mountPath: /var/lib/postgresql/data}]
  volumeClaimTemplates:
  - metadata: {name: data}
    spec:
      accessModes: [ReadWriteOnce]
      resources: {requests: {storage: 1Gi}}
E

kubectl create namespace orders
kubectl apply -f postgres.yaml
kubectl -n orders rollout status sts/postgres --timeout=180s
```

Разбор ключей:

| Часть манифеста | Значение |
|---|---|
| `stringData` | значения Secret в открытом виде; Kubernetes сам кодирует их в base64 |
| `clusterIP: None` | headless Service: у него нет виртуального IP |
| `envFrom: secretRef` | все ключи Secret становятся переменными контейнера |
| `PGDATA` | данные в подкаталоге тома, а не в его корне |
| `readinessProbe: pg_isready` | под готов, когда PostgreSQL принимает соединения |
| `limits: memory: 512Mi` | предел памяти; предела CPU нет |
| `volumeClaimTemplates` | свой том 1 Gi на каждую реплику, класс `standard` |

Результат (ожидаемый, сокращён):

```
namespace/orders created
secret/postgres created
service/postgres created
statefulset.apps/postgres created
…
statefulset rolling update complete 1 pods at revision postgres-…
```

Разбор вывода:

1. Namespace создан отдельной командой, а три объекта из файла — одним `apply`.
2. Последняя строка значит, что под `postgres-0` запущен и готов.

#### Шаг 4. Развернуть orders-api, Service и маршрут

Создаём ConfigMap с конфигом, Deployment из двух реплик, Service и HTTPRoute, который привязывает имя `orders.localhost` к Service через Gateway `lab`.

```bash
cat > orders-api.yaml <<'E'
apiVersion: v1
kind: ConfigMap
metadata: {name: orders-config, namespace: orders}
data:
  config.json: |
    {"discount_percent": 0, "banner": "welcome"}
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: orders-api, namespace: orders}
spec:
  replicas: 2
  selector: {matchLabels: {app: orders-api}}
  template:
    metadata: {labels: {app: orders-api}}
    spec:
      containers:
      - name: api
        image: localhost:5001/orders-api:2.0
        ports: [{name: http, containerPort: 8000}]
        env:
        - name: DATABASE_URL
          valueFrom: {secretKeyRef: {name: postgres, key: DATABASE_URL}}
        - {name: SHUTDOWN_DELAY, value: "5"}
        readinessProbe: {httpGet: {path: /ready, port: http}, periodSeconds: 2}
        livenessProbe:  {httpGet: {path: /health, port: http}, periodSeconds: 10}
        resources:
          requests: {cpu: 100m, memory: 64Mi}
          limits:   {memory: 256Mi}
        volumeMounts: [{name: config, mountPath: /etc/orders}]
      volumes:
      - name: config
        configMap: {name: orders-config}
---
apiVersion: v1
kind: Service
metadata: {name: orders-api, namespace: orders}
spec:
  selector: {app: orders-api}
  ports: [{name: http, port: 80, targetPort: http}]
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: orders-api, namespace: orders}
spec:
  parentRefs: [{name: lab, namespace: envoy-gateway-system}]
  hostnames: ["orders.localhost"]
  rules:
  - backendRefs: [{name: orders-api, port: 80}]
E

kubectl apply -f orders-api.yaml
kubectl -n orders rollout status deploy/orders-api --timeout=120s
kubectl -n orders get pods,svc,pvc,httproute
```

Разбор ключей:

| Часть манифеста | Значение |
|---|---|
| `replicas: 2` | две реплики приложения |
| `secretKeyRef` | взять `DATABASE_URL` из Secret `postgres` |
| `SHUTDOWN_DELAY: "5"` | после SIGTERM обслуживать запросы ещё 5 с |
| `readinessProbe /ready` | под получает трафик, когда БД отвечает; проверка каждые 2 с |
| `livenessProbe /health` | перезапуск, если процесс не отвечает; проверка каждые 10 с |
| `parentRefs: lab` | привязать маршрут к Gateway `lab` |
| `hostnames` | маршрут принимает запросы к `orders.localhost` |

Результат (сокращён):

```
NAME                              READY   STATUS    RESTARTS   AGE
pod/orders-api-6d54d4c46b-fvq75   1/1     Running   0          5m18s
pod/orders-api-6d54d4c46b-ksf5v   1/1     Running   0          5m18s
pod/postgres-0                    1/1     Running   0          8m8s

NAME                 TYPE        CLUSTER-IP     EXTERNAL-IP   PORT(S)    AGE
service/orders-api   ClusterIP   10.96.100.97   <none>        80/TCP     7m36s
service/postgres     ClusterIP   None           <none>        5432/TCP   8m8s

NAME                                    STATUS   VOLUME          CAPACITY   ACCESS MODES   …
persistentvolumeclaim/data-postgres-0   Bound    pvc-4c926342…   1Gi        RWO            …

NAME                                             HOSTNAMES              AGE
httproute.gateway.networking.k8s.io/orders-api   ["orders.localhost"]   7m36s
```

Разбор вывода:

1. Три пода `Running`, `1/1`: оба orders-api прошли проверку готовности.
2. Service `orders-api` имеет ClusterIP, а `postgres` — `None`: он headless.
3. PVC `data-postgres-0` в состоянии `Bound`: local-path-provisioner создал том на узле.
4. HTTPRoute принимает имя `orders.localhost`.

#### Шаг 5. Выполнить сквозной запрос

Отправляем запрос с хоста, и он проходит весь путь: порт 8088, Gateway, Service, под, PostgreSQL. Повторите команду несколько раз.

```bash
curl -s http://orders.localhost:8088/api/orders
```

Разбор команды:

| Часть команды | Значение |
|---|---|
| `curl -s` | тихий режим, только тело ответа |
| `orders.localhost:8088` | имя маршрута и порт входа стенда |
| `/api/orders` | путь, который читает заказы из БД |

Результат (длинная строка сокращена):

```
{"orders": [{"id": 1, …}, {"id": 2, …}], "total_items": 7, "pod": "orders-api-…-fvq75"}
```

Разбор вывода:

1. Список `orders` пришёл из PostgreSQL: без `DATABASE_URL` приложение отдавало бы список из памяти.
2. `total_items: 7` — сумма количеств: 2 книги и 5 ручек.
3. Поле `pod` меняется между запросами: Service распределяет их между двумя репликами.

Если с хоста ответа нет, повторите запрос изнутри сети kind: так ошибка входа отделяется от ошибки приложения.

```bash
docker exec lab-worker curl -s -H 'Host: orders.localhost' \
  http://lab-control-plane:30080/api/orders
```

Разбор вывода: если здесь пришёл тот же ответ, что выше, приложение и Gateway работают, а сбой лежит на пути от хоста до порта 8088 (§5).

#### Итог

Что вы узнали:

| Что узнали | Как проверить |
|---|---|
| Образ из реестра стенда доступен узлам | `crictl pull` на узле |
| StatefulSet создаёт PVC по шаблону | `kubectl -n orders get pvc` |
| Запрос идёт Gateway → Service → под → БД | `curl http://orders.localhost:8088/api/orders` |
| Поле `pod` показывает балансировку по репликам | несколько запросов подряд |
| Пароль в манифесте — только для стенда | `stringData` в `postgres.yaml` |

#### Уборка

Приложение нужно всем частям курса, поэтому остаётся в кластере. Чтобы вернуть его в исходное состояние после опытов в других частях, примените манифесты стенда заново.

```bash
kubectl apply -f ~/lab/k8s/orders-api/k8s/
kubectl -n orders get pods
```

Разбор: первая команда восстанавливает объекты `orders` из файлов, а вторая показывает, что три пода снова работают.

#### Вопросы для самопроверки

1. Почему у `postgres` Service нет ClusterIP?

<details><summary>Ответ</summary>

Это headless Service (`clusterIP: None`), поэтому DNS возвращает адреса подов напрямую, а под получает стабильное имя `postgres-0.postgres`. StatefulSet ссылается на такой Service в поле `serviceName` (02-3).

</details>

2. Что произойдёт с данными, если удалить под `postgres-0`?

<details><summary>Ответ</summary>

Данные сохранятся, потому что они лежат в PVC `data-postgres-0` на диске узла. StatefulSet создаст под с тем же именем, и он подключит тот же том.

</details>

3. Зачем в `PGDATA` указан подкаталог `pgdata`?

<details><summary>Ответ</summary>

На томах с файловой системой вроде ext4 в корне лежит каталог `lost+found`, а PostgreSQL отказывается инициализировать непустой каталог. Подкаталог `pgdata` всегда пуст при первом старте, поэтому манифест работает с любым классом томов, а не только с local-path.

</details>

4. Ответ orders-api пришёл, но поле `pod` не меняется. Что проверите?

<details><summary>Ответ</summary>

Проверьте число готовых эндпоинтов командой `kubectl -n orders get endpointslice`. Если готов только один под, весь трафик идёт на него, а причина обычно в провале проверки готовности у второго (`kubectl -n orders get pods`).

</details>

### Лабораторная работа 4. Выключить и включить стенд без потери данных

**Цель.** Остановить стенд, снова запустить его и убедиться, что данные PostgreSQL, образы и объекты кластера сохранились, а также понять, чем `--purge` отличается от остановки.

**Что понадобится.**

- Стенд с orders-api из работы 3.
- Около 10 минут.

**Схема опыта.** Добавляем в таблицу заказов новую строку, останавливаем стенд и запускаем его снова. Если строка на месте, данные пережили остановку.

```
INSERT lamp ─► lab-down.sh ─► docker stop (узлы, реестр)  etcd, PVC, образы целы
                                      │
              curl видит lamp ◄─ lab-up.sh ◄─ docker start + ожидание apiserver
```

Схема показывает цикл по часовой стрелке: остановка не удаляет контейнеры, а запуск поднимает те же самые.

**Риски.** Работа останавливает все контейнеры стенда.

- **Что меняется:** контейнеры стенда на время остановятся; в таблицу `orders` добавится строка.
- **Надолго ли:** на время опыта, около минуты; строку вы удалите в уборке.
- **Безопасность:** не меняется.
- **Влияние на систему:** на время остановки освобождается около 2,5 ГиБ RAM, а другие контейнеры Docker не затрагиваются. Процессы в подах не сохраняются: после запуска контейнеры подов стартуют заново.
- **Откат:** `lab-up.sh` возвращает стенд в рабочее состояние.

#### Шаг 1. Добавить строку в базу

Вставляем заказ напрямую в PostgreSQL клиентом `psql` внутри пода `postgres-0` и смотрим ответ приложения.

```bash
kubectl -n orders exec postgres-0 -- \
  psql -U orders -d orders -c "INSERT INTO orders (item, qty) VALUES ('lamp', 1);"
curl -s http://orders.localhost:8088/api/orders
```

Разбор команд:

| Часть команды | Значение |
|---|---|
| `exec postgres-0 --` | выполнить команду в поде `postgres-0` |
| `psql -U orders -d orders` | клиент PostgreSQL: пользователь и база `orders` |
| `-c "INSERT …"` | выполнить один SQL-запрос и выйти |

Результат (ожидаемый; длинная строка сокращена):

```
INSERT 0 1
{"orders": [{"id": 1, …}, {"id": 2, …}, {"id": 3, "item": "lamp", …}], "total_items": 8, …}
```

Разбор вывода:

1. `INSERT 0 1` — вставлена одна строка.
2. В ответе три заказа; `total_items` равно 8.

#### Шаг 2. Остановить и запустить стенд

Останавливаем стенд скриптом без аргументов и запускаем снова, замеряя время запуска. Команды выполняются из корня репозитория.

```bash
cd ~/ai/runbooks
bash kubernetes/lab/lab-down.sh
docker ps --filter name=lab- --filter name=kind-registry
time bash kubernetes/lab/lab-up.sh
```

Разбор команд:

| Часть команды | Значение |
|---|---|
| `cd ~/ai/runbooks` | корень репозитория курсов |
| `lab-down.sh` | `docker stop` узлов и реестра, без удаления |
| `docker ps --filter …` | убедиться, что контейнеры остановлены |
| `time … lab-up.sh` | запустить стенд и измерить время |

Результат (сокращён; строки `time` не показаны):

```
узлы kind и реестр остановлены, данные сохранены — запуск: bash kubernetes/lab/lab-up.sh
CONTAINER ID   IMAGE   COMMAND   CREATED   STATUS   PORTS   NAMES
…
== готово
```

Разбор вывода:

1. Скрипт сообщает, что данные сохранены.
2. Список `docker ps` без строк стенда значит, что его контейнеры остановлены.
3. Строка `== готово` значит, что стенд снова поднят. Цикл «выключить и включить» занял на машине автора 51 с, а не 2 мин 9 с, потому что кластер и образы уже есть.

#### Шаг 3. Проверить, что данные на месте

После запуска контейнеры подов стартуют заново, а данные остаются. Проверяем поды и повторяем сквозной запрос.

```bash
kubectl -n orders get pods
curl -s http://orders.localhost:8088/api/orders
```

Разбор команд:

| Часть команды | Значение |
|---|---|
| `get pods` | состояние подов после запуска |
| `curl …/api/orders` | заказы из PostgreSQL |

Результат (ответ на машине автора, длинная строка сокращена; вывод `get pods` не показан):

```
{"orders": [{"id": 1, …}, {"id": 2, …}, {"id": 3, "item": "lamp", "qty": 1}], "total_items": 8, …}
```

Разбор вывода:

1. Заказ `lamp` пережил остановку: PVC лежит на диске узла, а контейнеры узлов остановлены, но не удалены.
2. В `get pods` у подов `RESTARTS 1` (так было у автора), потому что остановка узла убивает контейнеры подов.
3. Имена подов остались прежними, а поле `pod` показывает ту реплику, которую выбрал Service.

#### Итог

Что вы узнали:

| Что узнали | Как проверить |
|---|---|
| `lab-down.sh` сохраняет etcd, PVC и образы | заказ `lamp` после `lab-up.sh` |
| Повторный подъём быстрее первого | 51 с против 2 мин 9 с у автора |
| Поды после остановки перезапускаются | колонка `RESTARTS` |
| `--purge` удаляет всё, включая исходники | список в §3 |

#### Уборка

Удаляем тестовую строку, чтобы вернуть таблицу в исходное состояние.

```bash
kubectl -n orders exec postgres-0 -- \
  psql -U orders -d orders -c "DELETE FROM orders WHERE item = 'lamp';"
curl -s http://orders.localhost:8088/api/orders
```

Результат (ожидаемый):

```
DELETE 1
{"orders": [{"id": 1, …}, {"id": 2, …}], "total_items": 7, …}
```

Разбор вывода: `DELETE 1` — строка удалена, сумма вернулась к 7.

Стенд остаётся для следующих частей. Полную уборку выполняйте только после окончания курса, потому что она удаляет кластер, реестр и исходники orders-api; правленый код сохраните заранее.

```bash
bash kubernetes/lab/lab-down.sh --purge
docker image rm kindest/node:v1.36.1 registry:2.8.3
```

Разбор команд: первая команда удаляет кластер, контейнер реестра, том `kind-registry-data` и `~/lab/k8s`; вторая освобождает около 1 ГБ диска и необязательна. Чтобы вернуться к прежнему кластеру, переключите контекст: `kubectl config use-context <прежний>`.

#### Вопросы для самопроверки

1. Что сохраняет `lab-down.sh` без аргументов и что удаляет `--purge`?

<details><summary>Ответ</summary>

Без аргументов выполняется `docker stop`, контейнеры остаются, поэтому сохраняются etcd, тома PVC и образы в узлах. С флагом `--purge` удаляются кластер, реестр, том с образами и каталог `~/lab/k8s`.

</details>

2. Почему после `lab-up.sh` у подов `RESTARTS 1`?

<details><summary>Ответ</summary>

Остановка контейнера узла убивает все процессы в нём, включая контейнеры подов. После запуска kubelet стартует их заново и увеличивает счётчик перезапусков на единицу, а объекты подов остаются те же.

</details>

3. Почему повторный подъём быстрее первого?

<details><summary>Ответ</summary>

Кластер и образы уже существуют, поэтому создание кластера и скачивание образов пропускаются. Скрипт только запускает контейнеры, ждёт apiserver и повторно применяет дополнения, которые уже на месте.

</details>

---

## → Дальше

Стенд поднят, и демо-приложение отвечает через Gateway. Чтобы работать с ним уверенно, нужны инструменты: форматы вывода kubectl, `explain`, подробные логи запросов, отладочный контейнер, `crictl` и `journalctl` на узле. Для запуска стенда они не нужны, но нужны в каждой следующей работе, поэтому часть 00-2 идёт сразу после стенда и вводит карточки инструментов.
