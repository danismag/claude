# Приложение C. Стенд и расширения

Назначение: вспомнить, как устроен стенд, как его запустить, выключить и сбросить, какие расширения ставят части курса и как вернуть стенд в исходное состояние.

## Как пользоваться

Приложение — сводка для повторного прохождения и для восстановления после сбоя. Устройство стенда и разбор сбоев подъёма лежат в 00-1, а правила имён — в 00-plan §3 и §6.

Читайте по задаче:

- **C.2** — запуск, выключение, сброс;
- **C.5–C.8** — расширения, ресурсы и удаление;
- **C.9** — что остаётся на диске;
- **C.10** — состояние после модуля 10.

Команды одинаковы для Ubuntu и Manjaro, потому что стенд работает в Docker.

---

## C.1. Сводка стенда

Стенд — это кластер kind из четырёх узлов, реестр образов и вход через Gateway API. Всё работает в контейнерах Docker на одной машине (00-1 §2).

### Топология

Схема показывает три порта хоста и то, куда они ведут. Все контейнеры стоят в docker-сети `kind`.

```
хост 127.0.0.1
 ├─ :6443x ─► lab-control-plane   apiserver, etcd, scheduler, controller-manager
 ├─ :8088 ──► NodePort 30080 ──► Envoy Gateway ──► HTTPRoute ──► Service orders-api
 │            lab-worker  lab-worker2  lab-worker3   kubelet, containerd, kube-proxy, kindnet
 └─ :5001 ──► kind-registry       registry:2.8.3, том kind-registry-data
```

Схема 1. API-сервер слушает случайный порт 6443x, веб-вход — 8088, реестр — 5001.

### Версии и адреса

- **Kubernetes** — 1.36.1: образ узла `kindest/node:v1.36.1`, kind 0.32.0, containerd 2.3.1.
- **Узлы** — один `lab-control-plane` и три `lab-worker`, `lab-worker2`, `lab-worker3`.
- **Сети** — поды из `10.244.0.0/16`, ClusterIP из `10.96.0.0/16` (03-2 §6).
- **Дополнения** — metrics-server 0.8.0 с флагом `--kubelet-insecure-tls`, local-path-provisioner (StorageClass `standard`), Envoy Gateway 1.9.2.
- **Вход** — Gateway `lab` в namespace `envoy-gateway-system`, NodePort 30080 на `127.0.0.1:8088`, `externalTrafficPolicy: Cluster`.
- **Демо-приложение** — orders-api 2.0 и PostgreSQL 17 в namespace `orders`.
- **Контекст** — `kind-lab` в `~/.kube/config` или в `$KUBECONFIG`.

### Ресурсы

Пустой стенд занимает около 2,5 ГиБ RAM по замеру `docker stats`: control-plane 1,3 ГиБ, каждый worker 0,3–0,4 ГиБ, реестр 18 МиБ. Диска нужно около 3 ГБ, из них около 1 ГБ — образ узла. С расширениями модулей 08–09 память доходит до 5 ГиБ (00-1 §6). Под `/var/lib/docker` держите не меньше 15 ГБ свободно.

---

## C.2. Запуск, выключение, сброс

Стенд не нужно держать запущенным. Включайте его перед работой, выключайте после. Скрипты лежат в `kubernetes/lab/`, и оба безопасно запускать повторно (00-1 §3).

### Включить

Команда запускается из корня репозитория. Она поднимает реестр, кластер, дополнения и Gateway, а при повторном запуске пропускает сделанное.

```bash
bash kubernetes/lab/lab-up.sh
```

Скрипт печатает строку `== готово` и список узлов. Первый запуск на машине автора занял 2 мин 9 с, повторный — 18 с. Скрипт переключает контекст на `kind-lab`, поэтому проверьте его командой `kubectl config current-context`.

```bash
kubectl get nodes
curl -s -o /dev/null -w '%{http_code}\n' http://orders.localhost:8088/api/orders
```

Первая команда должна показать четыре узла `Ready`. Вторая вернёт `200`, если демо-приложение развёрнуто (00-1, работа 3).

### Выключить

Команда останавливает контейнеры узлов и реестра. Данные etcd, тома PVC и образы в узлах остаются.

```bash
bash kubernetes/lab/lab-down.sh
```

Цикл «выключить и включить» занял 51 с. После `docker start` API-сервер отвечает не сразу: `lab-up.sh` ждёт `/readyz`, а при ручном запуске подождите около 30 с.

### Удалить полностью

Флаг `--purge` удаляет кластер, контейнер `kind-registry`, том `kind-registry-data` и весь каталог `~/lab/k8s`.

```bash
bash kubernetes/lab/lab-down.sh --purge
bash kubernetes/lab/lab-up.sh
```

Сначала сохраните правленый код: в `~/lab/k8s` лежат исходники orders-api, чарт из 07-1, каталог 07-3 и файлы других частей (C.9). После `lab-up.sh` реестр пуст. Соберите образы и развёрните `orders` заново по 00-1, работа 3, а `busybox:1.37` положите по подготовке 02-1.

### Сбросить только orders

Если работа оставила следы, но стенд цел, вернуть нужно namespace и манифесты `orders`. Команды только читают состояние, кроме последней.

```bash
kubectl get ns | grep lab-
kubectl -n orders get networkpolicy
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name} {.spec.taints}{"\n"}{end}'
kubectl apply -f ~/lab/k8s/orders-api/k8s/
```

Разбор:

1. Первая команда находит недоудалённые namespace работ `lab-NN-M`.
2. Вторая должна вывести пустой список: политики сети 03-6 в уборке удаляются.
3. Третья показывает taints узлов; посторонних быть не должно.
4. Четвёртая применяет манифесты `orders` из 00-1, работа 3.

### Особенности перезапуска

После перезапуска Docker узлы могут получить другие IP-адреса в сети `kind`. Сертификаты etcd и API-сервера выписаны на старые адреса. Для стенда это редко заметно, но кластер `lab-10-1` после остановки узла не чинят, а пересоздают (10-1, работа 3).

---

## C.3. Общие образы стенда

Три образа лежат в реестре стенда `localhost:5001` и нужны многим частям. Они стоят вне правила `lab-NN-M`, и уборка частей их не удаляет (00-plan §3).

| Образ | Появляется | Кто использует |
|---|---|---|
| orders-api:2.0 | 00-1, работа 3 | модули 02–07 и 11 |
| orders-api:2.1 | 00-1, работа 3 | выкатки в модулях 07 и 08 |
| busybox:1.37 | подготовка 02-1 | модули 02, 04, 06, 09, 11 |

Образ orders-api собирается из одного кода с аргументом `APP_VERSION=2.0` и `2.1`. Образы частей называются `localhost:5001/lab-NN-M/<имя>:<тег>` и удаляются в уборке своей работы.

Проверить содержимое реестра можно запросом списка репозиториев.

```bash
curl -s http://127.0.0.1:5001/v2/_catalog
curl -s http://127.0.0.1:5001/v2/orders-api/tags/list
```

Первая команда печатает репозитории, вторая — теги orders-api. Должны быть `2.0` и `2.1`. Если `orders-api` пуст, образ не отправлен: повторите шаг 2 работы 3 из 00-1.

---

## C.4. Правило имён lab-NN-M и исключения

Каждая часть работает под своим номером, чтобы части не мешали друг другу и стенду (00-plan §3, 00-1 §3).

- **Namespace** — `lab-NN-M`, где NN-M — номер части; удаляется в уборке.
- **Каталог** — `~/lab/k8s/NN-M/`.
- **Метки и taints узлов** — ключи с префиксом `lab-NN-M/`; снимаются в уборке.
- **Образы** — `localhost:5001/lab-NN-M/<имя>:<тег>`.
- **Кластерные объекты** — имя с префиксом `lab-NN-M-`, например `lab-06-3-` и `lab-11-1-`.
- **Namespace `orders`** — работы его не удаляют; если работа его меняет, уборка возвращает манифесты стенда.

Таблица перечисляет случаи, где правило нарушено, и причину. Все они записаны в 00-plan §6.

| Часть | Исключение | Причина |
|---|---|---|
| 03-5 | namespace cert-manager | чарт ставится в своё имя |
| 04-3 | работы 1–2 в orders | копируют БД стенда |
| 05-4 | namespace keda | чарт ставится в своё имя |
| 06-4, 10-1, 10-2 | отдельные кластеры kind | аудит и etcd ломают кластер |
| 07-1 | чарт в ~/lab/k8s/charts/orders-api | его читают 07-2 и 07-3 |
| 08-1 | namespace argocd | манифест установки задаёт имя |
| 09-1 | namespace cnpg-system | манифест оператора задаёт имя |
| 03-6 | работа 5 в orders | закрывает namespace стенда |

---

## C.5. Расширения

Части ставят дополнения командами в начале работы и убирают их в уборке. Стенд при этом остаётся прежним. Таблица показывает, что ставится, где и какой версии.

| Что | Часть | Namespace | Версия |
|---|---|---|---|
| cert-manager | 03-5 | cert-manager | v1.21.2 |
| KEDA | 05-4 | keda | 2.21.0 |
| kube-state-metrics | 11-1 | lab-11-1 | v2.20.0 |
| Argo CD | 08-1 | argocd | v3.5.5 |
| Gitea | 08-1 | lab-08-1 | 1.27.0 |
| CloudNativePG | 09-1 | cnpg-system | 1.30.1 |
| Velero и VersityGW | 04-3 | lab-04-3 | 1.18.4, v1.8.0 |
| cosign | 06-4 | на хосте | v2.5.3 |

Дополнительные детали, которых нет в таблице:

- **Velero.** Плагин `velero-plugin-for-aws` v1.14.4, клиент `aws-cli` 2.37.0, демо-namespace `lab-04-3-demo` (04-3, работа 3).
- **cosign.** Бинарник в `~/lab/k8s/06-4/bin`, подписи в репозитории `lab-06-4/orders-api` реестра стенда (06-4, работа 3).
- **Gitea.** Образ `gitea/gitea:1.27.0-rootless`, том 1 ГиБ, маршрут `git.localhost:8088` на Gateway `lab` (08-1).
- **PostgreSQL в CNPG.** Образ `ghcr.io/cloudnative-pg/postgresql:17.11-standard-trixie`, namespace работы `lab-09-1` (09-1, работа 2).

---

## C.6. Дополнительные кластеры

Три части создают отдельный кластер kind со своим kubeconfig. Стенд и `~/.kube/config` они не меняют.

| Кластер | Часть | Узлы | Kubeconfig |
|---|---|---|---|
| lab-06-4 | 06-4, работа 1 | 1 control-plane | ~/lab/k8s/06-4/kubeconfig |
| lab-10-1 | 10-1, работа 3 | 3 control-plane, 1 worker, балансировщик | ~/lab/k8s/10-1/kubeconfig |
| lab-10-2 | 10-2, работы 2–3 | 1 control-plane | ~/lab/k8s/10-2/kubeconfig |

Образ узла у всех трёх — `kindest/node:v1.36.1`, он уже скачан для стенда. Сеть Docker `kind` общая со стендом, адреса разные.

---

## C.7. Ресурсы расширений

Числа взяты из блоков «Риски» частей. Если числа в части нет, это сказано отдельно: замеров не было.

Дополнения стенда:

- **Argo CD и Gitea.** Стенд с ними занимает до 5 ГиБ RAM по ориентиру плана, замера нет. Том Gitea — 1 ГиБ. Образы идут с quay.io, ghcr.io, public.ecr.aws и Docker Hub (08-1).
- **CloudNativePG.** Три экземпляра PostgreSQL занимают около 1,5 ГиБ памяти и три тома по 1 ГиБ. Скачивание образов — 5–10 минут (09-1, работа 2).
- **Velero.** Сервер запрашивает 500m CPU и 128 МиБ, лимит — 1 CPU и 512 МиБ. Лимитов у агента `node-agent` нет. Диска нужно около 1 ГиБ (04-3, работа 3).
- **KEDA.** Образы с `ghcr.io`; установка занимает до 10 минут, у автора больше 5 (05-4, работа 3). Памяти в части нет.
- **cert-manager, kube-state-metrics, cosign.** Чисел в частях нет. cert-manager тянет четыре образа с `quay.io` (03-5).

Дополнительные кластеры:

- **lab-06-4.** Один узел, создание около двух минут. Память смотрите командой `docker stats --no-stream`, числа в части нет (06-4).
- **lab-10-1.** Добавляет 4–5 ГиБ памяти к стенду. Перед началом нужно не меньше 5 ГиБ свободной памяти, а при менее 8 ГиБ стенд лучше остановить (10-1, работа 3).
- **lab-10-2.** Около 1 ГиБ памяти и около 1 ГБ диска, сетевой загрузки нет (10-2).
- **inotify.** Восемь узлов kind требуют лимитов из 00-1, работа 1, шаг 4 (B.4).

---

## C.8. Как удалить расширения

Команды ниже повторяют блоки «Уборка» частей. Если вы закончили работу штатно, они уже выполнены. Используйте их после прерванной работы и сверяйте с текстом части.

### Расширения через Helm

cert-manager и KEDA ставятся Helm-релизом. Команда `helm uninstall` не удаляет CRD, поэтому их убирают отдельно.

```bash
# cert-manager (03-5, работа 1): сначала вернуть Gateway lab
kubectl -n envoy-gateway-system patch gateway lab --type=json -p '[
  {"op":"remove","path":"/spec/listeners/1"},
  {"op":"remove","path":"/metadata/annotations/cert-manager.io~1cluster-issuer"}]'
kubectl -n envoy-gateway-system delete certificate shop-localhost-tls --ignore-not-found
kubectl -n envoy-gateway-system delete secret shop-localhost-tls --ignore-not-found
kubectl delete clusterissuer selfsigned lab-ca
helm -n cert-manager uninstall cert-manager
kubectl delete ns cert-manager
kubectl get crd -o name | grep cert-manager.io | xargs kubectl delete
```

```bash
# KEDA (05-4, работа 3)
helm -n keda uninstall keda
kubectl delete ns keda
kubectl get crd -o name | grep keda.sh | xargs -r kubectl delete
helm repo remove kedacore
```

Первый блок сначала убирает из Gateway `lab` второй listener и аннотацию, потому что работа 1 из 03-5 меняла общий вход. Без этого шага Gateway останется с listener без сертификата. Удаление CRD cert-manager удаляет все Certificate кластера, поэтому делайте это только на стенде.

### Расширения через манифест

kube-state-metrics, Argo CD, Gitea и CloudNativePG ставятся манифестами, и удаляются тем же манифестом.

```bash
# kube-state-metrics (11-1, работа 3)
kubectl delete -f ~/lab/k8s/11-1/ksm.yaml
rm -rf ~/lab/k8s/11-1/ksm ~/lab/k8s/11-1/ksm.yaml
kubectl get clusterrole,clusterrolebinding | grep lab-11-1 || echo "чисто"
```

```bash
# Argo CD и Gitea (08-2, работа 3: полная уборка стенда GitOps)
kubectl -n argocd delete app root
kubectl -n argocd delete applicationset orders-api
kubectl delete -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.5.5/manifests/install.yaml
kubectl delete ns argocd lab-08-1 lab-08-2-staging lab-08-2-prod
kubectl get crd -o name | grep argoproj.io | xargs -r kubectl delete
[ -f ~/lab/k8s/08-1/pf.pid ] && kill "$(cat ~/lab/k8s/08-1/pf.pid)"
rm -rf ~/lab/k8s/08-1 ~/lab/k8s/08-2
```

```bash
# CloudNativePG (09-1, работа 2): порядок важен, сначала Cluster
kubectl -n lab-09-1 delete pod writer --now
kubectl -n lab-09-1 delete cluster orders-db
kubectl -n lab-09-1 get pods,pvc
kubectl delete ns lab-09-1
kubectl delete -f ~/lab/k8s/09-1/cnpg.yaml
rm -rf ~/lab/k8s/09-1
```

Разбор:

1. Argo CD и Gitea нужны обеим частям 08. Если вы идёте из 08-1 в 08-2, удаляйте их один раз, в конце 08-2. Если остановились в 08-1, используйте необязательный блок уборки работы 4.
2. Оператор CNPG должен жить, пока удаляется Cluster: иначе тома останутся. Поэтому `delete cluster` стоит до удаления манифеста оператора.
3. Часть 09-1 после этого убирает образы `ghcr.io/cloudnative-pg/...` на узлах и на хосте командами `crictl rmi` и `docker rmi`. Если образы были у вас до работы, не удаляйте их.
4. После Argo CD на хосте может остаться образ Redis: `docker rmi public.ecr.aws/docker/library/redis:8.2.3-alpine redis:8.2.3-alpine`.

### Velero и cosign

Velero и VersityGW живут в одном namespace, а cosign — на хосте и в реестре стенда.

```bash
# Velero и VersityGW (04-3, работа 3)
VEL=~/lab/k8s/04-3/bin/velero
kubectl delete ns lab-04-3-demo --ignore-not-found
$VEL uninstall --namespace lab-04-3 --force
kubectl delete ns lab-04-3 --ignore-not-found
rm -f ~/lab/k8s/04-3/credentials-velero ~/lab/k8s/04-3/s3-user ~/lab/k8s/04-3/s3-pass
```

```bash
# cosign (06-4, работа 3)
docker exec kind-registry rm -rf /var/lib/registry/docker/registry/v2/repositories/lab-06-4
docker rmi localhost:5001/lab-06-4/orders-api:2.0
rm -rf ~/lab/k8s/06-4
```

Команда `velero uninstall` удаляет CRD, ClusterRoleBinding и namespace `lab-04-3`. Каталог `~/lab/k8s/04-3/bin` с клиентом можно оставить. Последний блок удаляет и kubeconfig кластера `lab-06-4`, поэтому выполняйте его после удаления того кластера.

### Дополнительные кластеры

Каждый кластер удаляется командой `kind delete cluster` с указанием его kubeconfig. Команда убирает контейнеры узлов и контекст из этого файла.

```bash
kind delete cluster --name lab-06-4 --kubeconfig ~/lab/k8s/06-4/kubeconfig
kind delete cluster --name lab-10-1 --kubeconfig ~/lab/k8s/10-1/kubeconfig
kind delete cluster --name lab-10-2 --kubeconfig ~/lab/k8s/10-2/kubeconfig
kind get clusters
```

Последняя команда должна показать только `lab`. Если кластер уже удалён, соответствующая строка вернёт ошибку, и это нормально. Каталоги `~/lab/k8s/06-4`, `10-1` и `10-2` удаляют командой `rm -rf` после этого.

---

## C.9. Что остаётся после частей

Несколько файлов и объектов часть оставляет нарочно, потому что их читает другая часть.

- **07-1.** Чарт `~/lab/k8s/charts/orders-api`: его берут 07-2 и 07-3. Релиз остаётся на образе 2.0 для работы 3 (07-1).
- **07-3.** Каталог `~/lab/k8s/07-3/orders-api`: его читает Argo CD в 08-1 и 08-2. Namespace `lab-07-3-helm` удаляется, `lab-07-3-staging` и `lab-07-3-prod` — по тексту части.
- **03-6.** Файл `~/lab/k8s/03-6/orders-netpol.yaml`: он нужен сценариям поломок в 11-3 и 12-2. Политики из кластера удаляются.
- **04-3.** Дамп базы в `~/lab/k8s/04-3/backups` и клиент Velero в `~/lab/k8s/04-3/bin`.
- **08-1, 08-2.** Gitea, Argo CD и репозиторий остаются между частями до полной уборки в конце 08-2.
- **10-3.** Загруженные образы 1.36.5 остаются на узлах, потому что их использует обновлённый кластер.

Команда `lab-down.sh --purge` удаляет все эти файлы вместе с `~/lab/k8s`. Если вы собираетесь повторять модули 08 или 12, не делайте `--purge` без копии каталога.

---

## C.10. Стенд после 10-3 и возврат

Модуль 10 меняет сам кластер стенда. Часть 10-3 обновляет его с 1.36.1 до 1.36.5, а 10-4 продлевает сертификаты и перезапускает узел.

Что изменилось. После трёх работ 10-3 стенд остаётся на 1.36.5. Образ узла по-прежнему `kindest/node:v1.36.1`: версия подменена внутри узлов.

- **Версия.** API-сервер, controller-manager, scheduler и kube-proxy — v1.36.5, kubelet на всех четырёх узлах — v1.36.5.
- **Файлы на узлах.** Каталог `/root/lab-10-3` убран, но копии манифестов `/etc/kubernetes/tmp/kubeadm-backup-*` остаются.
- **Сертификаты.** После 10-4 они продлены и остаются новыми (10-4, работа 1).
- **Время.** Патч-обновление control plane заняло 105 с, узел с PostgreSQL — 139 с простоя базы.

Проверка версий: `kubectl get nodes` показывает колонку `VERSION` со значением v1.36.5, а `kubectl version` печатает версию сервера. Для частей после 10-3 разница между 1.36.1 и 1.36.5 не важна: обе версии подходят всем работам.

Как вернуть 1.36.1. Откатить kubeadm нельзя, поэтому стенд пересоздают. Команда `--purge` удаляет всё, включая реестр и `~/lab/k8s`.

```bash
cp -a ~/lab/k8s ~/lab-k8s-backup
bash kubernetes/lab/lab-down.sh --purge
bash kubernetes/lab/lab-up.sh
```

Разбор:

1. Первая команда копирует каталог файлов стенда: исходники orders-api, чарт и файлы частей.
2. Вторая удаляет кластер, реестр и том образов.
3. Третья создаёт стенд на образе узла из строки `NODE_IMAGE` в начале `lab-up.sh`. Там стоит `kindest/node:v1.36.1`.

После этого соберите orders-api 2.0 и 2.1 и разверните `orders` по 00-1, работа 3, положите `busybox:1.37` по 02-1 и верните файлы из копии. Часть 10-3 называет `NODE_IMAGE` переменной, но скрипт задаёт её константой: чтобы взять другой образ, правьте эту строку.

---

## C.11. Что не проверено

Курс написан в режиме «только текст», команды не запускались. Что и где проверено, записано по частям в 00-plan §7.

- **Расширения.** Реальный вывод есть для cert-manager (03-5, работа 1, шаги 3–5), CNPG 1.30.1 и части Argo CD. Velero 1.18.4 с VersityGW, cosign, KEDA на 2.21.0 и kube-state-metrics не запускались (00-plan §7, строки 04-3, 05-4, 06-4, 11-1).
- **Дополнительные кластеры.** Работы на `lab-06-4`, `lab-10-1` и `lab-10-2` вывода не имеют (00-plan §7, строки 06-4, 10-2).
- **Ресурсы.** Числа для Argo CD и Gitea (до 5 ГиБ) не замерены, число для lab-10-1 (4–5 ГиБ) взято из оценки части.
- **Возврат стенда.** Цепочка «copy, purge, up, пересборка» собрана из частей 00-1 и 10-3 и целиком не проходилась.
- **Сети.** Адрес ClusterIP `10.96.0.0/16` взят из 03-2; в `lab-up.sh` он не задан.

---

Связанные приложения: A (шпаргалки по инструментам), B (Manjaro и Ubuntu), D (глоссарий), E (что читать дальше).
