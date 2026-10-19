# Приложение A. Шпаргалки

> Одна страница на инструмент: команды, которые нужны в работе чаще всего, и ошибки, на которых спотыкаются. Версии как на стенде курса: kubectl 1.36, kind 0.32, containerd 2.3, etcd 3.6, Helm 4.2.2, Kustomize 5.8.1, Argo CD 3.5.5, cosign 2.5.3, Velero 1.18.4.

---

## Как пользоваться

Шпаргалка не учит, а напоминает. Механизм, схема и разбор вывода лежат в части, на которую ведёт ссылка в конце каждой страницы. Если команда непонятна, откройте карточку инструмента: там сказано, откуда инструмент берёт данные и что он меняет.

Команды даны в форме Ubuntu. Различия Manjaro названы в строках «Установка» карточек и сведены в приложении B. Значения `orders`, `NAME`, `ID` в командах замените своими. Узлы стенда — контейнеры Docker, поэтому команды для узла запускают как `docker exec lab-worker …`.

Таблица ниже перечисляет страницы и части, где стоит карточка инструмента.

| Страница | Инструмент | Карточка |
|---|---|---|
| A.1 | kubectl | 00-2 §2 |
| A.2 | kind | 00-2 §3 |
| A.3 | crictl | 00-2 §4 |
| A.4 | journalctl для kubelet | 00-2 §4, 11-4 §3 |
| A.5 | etcdctl и etcdutl | 01-1 §4, 10-2 §3 |
| A.6 | kubeadm | 10-1 §3 |
| A.7 | helm 4 и helm-diff | 07-1 §3, 07-2 §3 |
| A.8 | kustomize | 07-3 §3 |
| A.9 | argocd | 08-1 §3 |
| A.10 | cosign | 06-4, работа 3 |
| A.11 | velero | 04-3, работа 3 |
| A.12 | tcpdump и netshoot | 03-1, работа 2 |
| A.13 | ingress2gateway | 03-5, работа 3 |
| A.14 | stern и k9s | 00-2 §4 |

---

## A.1. kubectl

Команды ниже не меняют текущий namespace: namespace задан флагом `-n` или функцией `k`, а контекст переключается отдельно.

```bash
kubectl config get-contexts                        # список контекстов, звёздочка — текущий
kubectl config use-context kind-lab                # сменить контекст, namespace не трогаем
k() { kubectl -n orders "$@"; }                    # функция k: namespace только для неё
k get pods -o wide                                 # поды с узлом и IP пода
kubectl get pods -A -o wide                        # поды всех namespace
k describe pod NAME                                # состояние и события пода (внизу вывода)
k logs deploy/orders-api --tail=20                 # лог одного пода из Deployment
k exec -it pod/NAME -- sh                          # shell в контейнере
k debug -it pod/NAME --image=busybox:1.37 --target=api   # временный контейнер рядом с целью
k get pod NAME -o jsonpath='{.status.podIP}'       # одно поле объекта
k get pods -o custom-columns=NAME:.metadata.name,NODE:.spec.nodeName   # своя таблица
kubectl explain deployment.spec.strategy           # описание поля из схемы кластера
kubectl apply -f app.yaml --dry-run=server         # проверка на сервере без записи
kubectl diff -f app.yaml                           # что изменит apply; код 1 — есть правки
kubectl auth can-i delete pods -n orders           # разрешено ли мне это действие
kubectl auth whoami                                # кем кластер считает меня
k events --for pod/postgres-0                      # события одного объекта
k top pods                                         # CPU и память подов (нужен metrics-server)
k port-forward svc/orders-api 9000:80              # localhost:9000 → один под за Service
k get deploy orders-api -v=8                       # HTTP-запросы и ответы kubectl
KUBERC=off kubectl get pods                        # выполнить без файла kuberc
```

Частые ошибки:

- Не тот контекст: команда сработала, но в другом кластере. Проверяйте `kubectl config current-context`.
- Забыт `-n`: ответ `No resources found in default namespace`. Нужен флаг `-n` или `-A`.
- `--dry-run=client` не проходит admission. Серверные ошибки и политики ловит только `--dry-run=server`.
- `port-forward` к Service выбирает один под при запуске и не балансирует.

Подробно: карточка и разделы 2–4 части 00-2, права и `auth` — 06-1, отладка подов — 11-2.

## A.2. kind

kind поднимает узлы-контейнеры Docker. На стенде кластер создают и гасят скрипты `lab-up.sh` и `lab-down.sh`, а kind нужен для осмотра и сборки логов.

```bash
bash kubernetes/lab/lab-up.sh                      # поднять или запустить стенд (из корня репо)
bash kubernetes/lab/lab-down.sh                    # остановить узлы и реестр, данные остаются
bash kubernetes/lab/lab-down.sh --purge            # удалить кластер, реестр, том и ~/lab/k8s
kind get clusters                                  # кластеры kind на этой машине
kind get nodes --name lab                          # контейнеры-узлы кластера lab
kind export kubeconfig --name lab                  # вернуть контекст kind-lab в kubeconfig
kind export logs ./kind-logs --name lab            # собрать логи всех узлов в каталог
kind load docker-image IMAGE --name lab            # копировать образ с хоста в containerd узлов
kind create cluster --wait 120s                    # в CI: кластер kind, ждать control plane 120 с
kind delete cluster --name lab                     # удалить кластер (реестр останется без кластера)
docker exec -it lab-worker bash                    # зайти на узел
docker ps --format '{{.Names}} {{.Ports}}'         # контейнеры стенда и их порты
```

Частые ошибки:

- `too many open files` в логах kubelet: мало `fs.inotify.max_user_instances` (00-1 §5).
- `port is already allocated`: порт хоста занят другим контейнером.
- После перезагрузки машины `kubectl` отвечает `connection refused`: узлы остановлены, их запускает `lab-up.sh`.
- `permission denied` на сокете Docker: пользователь не входит в группу `docker`.

Подробно: карточка kind в 00-2 §3, стенд — 00-1 §3–5 и приложение C.

## A.3. crictl

crictl говорит с containerd на узле напрямую, мимо API-сервера, и видит то же, что kubelet. На стенде его запускают через `docker exec`.

```bash
N=lab-worker                                       # узел, на котором работаем
docker exec $N crictl ps                           # запущенные контейнеры
docker exec $N crictl ps -a                        # и остановленные, с числом попыток ATTEMPT
docker exec $N crictl ps --name postgres           # фильтр по имени контейнера
docker exec $N crictl pods --name postgres-0       # песочницы (pause) подов
ID=$(docker exec $N crictl ps -q --name postgres)  # только идентификатор контейнера
docker exec $N crictl logs --tail=20 $ID           # последние 20 строк лога
docker exec $N crictl logs -f $ID                  # то же со слежением
docker exec $N crictl inspect $ID                  # JSON: pid, mounts, cgroup
docker exec -it $N crictl exec -it $ID sh          # команда внутри контейнера
docker exec $N crictl images                       # образы на узле
docker exec $N crictl stats                        # использование CPU и памяти
docker exec lab-control-plane crictl ps --name kube-apiserver   # API-сервер при лежащем API
```

Частые ошибки:

- `permission denied` на сокете: на обычном узле нужен `sudo crictl …`.
- `connect: no such file or directory`: crictl не нашёл runtime, задайте `--runtime-endpoint`.
- `docker ps` на узле с containerd пуст: Docker там нет, контейнеры показывает только crictl.
- `crictl rm` на живом узле: kubelet пересоздаст контейнер, на проде так не делают.

Подробно: карточка crictl в 00-2 §4, устройство узла — 01-2.

## A.4. journalctl для kubelet

Kubelet и containerd пишут в journald, а не в файлы. Журнал читают на самом узле; на стенде команды идут через `docker exec`.

```bash
N=lab-worker                                       # узел, на котором работаем
docker exec $N systemctl is-active kubelet         # active, inactive или failed
docker exec $N journalctl -u kubelet -n 50 --no-pager          # последние 50 строк
docker exec $N journalctl -u kubelet --since -10min --no-pager # журнал за 10 минут
docker exec $N journalctl -u kubelet --since -1min --no-pager | grep PLEG   # поиск по тексту
docker exec $N journalctl -u containerd -p err --no-pager      # только ошибки containerd
docker exec $N dmesg | grep -iE 'out of memory|oom.group'   # журнал ядра узла: OOM
docker exec $N ls /var/log/pods                    # файлы логов контейнеров (не journald)
kubectl get --raw "/api/v1/nodes/$N/proxy/logs/?query=kubelet&tailLines=50"   # через API
```

Частые ошибки:

- Без `--no-pager` вывод открывается в pager и скрипт зависает.
- Логи подов ищут в journald, а они лежат в `/var/log/pods/<namespace>_<под>_<uid>/`.
- Запрос через API закрыт настройками kubelet и требует право `nodes/proxy`. При аварии на него не рассчитывают.

Подробно: журналы компонентов в 11-4 §3 и 11-1 §3, карточка crictl в 00-2 §4.

## A.5. etcdctl и etcdutl

etcdctl читает живой etcd по mTLS, а etcdutl работает с файлами снимков без сервера. Переменные `E` и `X` собирают сертификаты и вход в под etcd.

```bash
E='etcdctl --endpoints=https://127.0.0.1:2379 --cacert=/etc/kubernetes/pki/etcd/ca.crt'
E+=' --cert=/etc/kubernetes/pki/etcd/server.crt --key=/etc/kubernetes/pki/etcd/server.key'
X='kubectl -n kube-system exec etcd-lab-control-plane --'
$X $E endpoint health                              # отвечает ли etcd на запрос
$X $E endpoint status -w table                     # лидер, версия, размер базы, ревизия
$X $E member list -w table                         # члены кластера etcd
$X $E get /registry/configmaps --prefix --keys-only   # имена ключей с префиксом
$X $E get /registry/pods --prefix --count-only     # только число ключей
$X $E alarm list                                   # активные тревоги, например NOSPACE
REV=$($X $E endpoint status -w json | jq '.[0].Status.header.revision')   # текущая ревизия
$X $E compact $REV --physical                      # удалить историю до ревизии, дождаться диска
$X $E defrag                                       # перестроить файл члена из --endpoints
$X $E alarm disarm                                 # снять тревогу после очистки
$X $E snapshot save /var/lib/etcd/snap.db          # снимок в каталог данных узла
$X etcdutl snapshot status /var/lib/etcd/snap.db -w table   # хеш, ревизия, ключи, размер
docker cp lab-control-plane:/var/lib/etcd/snap.db ./snap.db   # копия снимка на хост
etcdutl snapshot restore snap.db --data-dir /var/lib/etcd-restored \
  --bump-revision=1000000000 --mark-compacted      # восстановить в новый каталог
```

Частые ошибки:

- `context deadline exceeded`: неверный адрес, etcd не запущен или нет кворума.
- `x509: certificate signed by unknown authority`: не заданы или перепутаны `--cacert`, `--cert`, `--key`.
- `snapshot status` и `snapshot restore` есть только в etcdutl: из etcdctl 3.6 их убрали.
- Снимок хранят как пароль: Secret в нём лежат открытым текстом, если нет шифрования.

Подробно: карточка etcdctl в 01-1 §4, снимки, восстановление и тревоги — 10-2 §3–5. Команда `restore` в 10-2 дополняется флагами `--name`, `--initial-cluster` и `--initial-advertise-peer-urls`.

## A.6. kubeadm

kubeadm пишет файлы на узел и объекты в кластер. Команды запускают на узлах control plane, поэтому на стенде они идут через `docker exec`.

```bash
kubeadm init --config kubeadm.yaml --upload-certs  # создать первый узел control plane
kubeadm token create --print-join-command          # новый токен и готовая команда join
kubeadm join ADDR:6443 --token TOKEN \
  --discovery-token-ca-cert-hash sha256:HASH       # добавить рабочий узел
kubeadm config print init-defaults                 # значения по умолчанию, формат v1beta4
kubeadm config migrate --old-config old.yaml --new-config new.yaml   # v1beta3 → v1beta4
kubeadm config images list                         # образы, нужные этой версии
kubeadm certs check-expiration                     # сроки всех сертификатов
sudo kubeadm certs renew all                       # продлить листовые сертификаты и kubeconfig
sudo apt-mark unhold kubeadm                       # снять запрет обновления пакета
sudo apt-get update && sudo apt-get install -y kubeadm='1.36.5-*'   # новая версия kubeadm
sudo apt-mark hold kubeadm                         # снова закрепить версию пакета
sudo kubeadm upgrade plan                          # до каких версий можно обновиться
sudo kubeadm upgrade apply v1.36.5                 # обновить первый узел control plane
sudo kubeadm upgrade node                          # остальные узлы, после пакета kubeadm
kubeadm reset                                      # убрать с узла всё, что создал kubeadm
```

Частые ошибки:

- `could not find a JWS signature in the cluster-info ConfigMap`: токен истёк или в нём опечатка.
- `cluster CA found in cluster-info ConfigMap is invalid`: хеш CA в команде не тот.
- `[ERROR FileAvailable--etc-kubernetes-manifests-…]`: узел уже использовался, сначала `kubeadm reset`.
- После `certs renew` забыли перезапустить static pods и выдать свежий `admin.conf`.

Подробно: карточка kubeadm в 10-1 §3, обновление — 10-3 §3, сертификаты — 10-4.

## A.7. helm 4 и helm-diff

Helm рендерит чарт на вашей машине и хранит историю релиза в Secret. Плагин helm-diff показывает разницу до `upgrade`.

```bash
helm lint ./demo --strict                          # проверить чарт, предупреждения как ошибки
helm template r ./demo -n ns                       # отрендерить манифесты без кластера
helm install r ./demo -n ns --wait                 # поставить релиз и дождаться готовности
helm upgrade --install r ./demo -n ns \
  -f prod.yaml --set image.tag=2.1                 # установить или обновить одной командой
helm upgrade r ./demo -n ns --rollback-on-failure --timeout 5m   # при ошибке откатить сам
helm list -n ns                                    # релизы в namespace
helm status r -n ns                                # статус и NOTES релиза
helm history r -n ns                               # все ревизии с описанием
helm get values r -n ns                            # значения, которые передали вы
helm get manifest r -n ns                          # манифест, ушедший в кластер
helm rollback r 1 -n ns                            # вернуться к ревизии 1 (новая ревизия)
helm uninstall r -n ns                             # удалить релиз и его объекты
helm show values CHART --version X                 # значения чужого чарта по умолчанию
helm pull CHART --version X --untar                # скачать чарт и распаковать шаблоны
helm diff upgrade r CHART -n ns -f prod.yaml --detailed-exitcode   # разница; код 2 — есть
helm diff revision r 1 2 -n ns                     # сравнить две ревизии релиза
helm plugin list                                   # установленные плагины
```

Частые ошибки:

- `another operation (install/upgrade/rollback) is in progress`: релиз завис в `pending-*`, смотрите `helm history`.
- `--reuse-values` не подхватывает новые значения по умолчанию из обновлённого чарта. В CI передавайте полный набор `-f`.
- `helm template oci://…` в Helm 4 печатает строки `Pulled:` и `Digest:` перед манифестами. Для OCI сначала `helm pull`.
- helm-diff без `--three-way-merge` не видит ручных правок кластера.

Подробно: карточка helm в 07-1 §3, карточка helm-diff и установка плагина с проверкой подписи — 07-2 §3.

## A.8. kustomize

Kustomize встроен в kubectl и печатает обычный YAML. Отдельный бинарник нужен для `kustomize edit`.

```bash
kubectl kustomize overlays/prod                    # собрать и вывести YAML, кластер не нужен
kubectl kustomize overlays/prod > /tmp/prod.yaml   # сохранить сборку как артефакт
kubectl apply -k overlays/prod                     # собрать и применить в кластер
kubectl apply -k overlays/prod --dry-run=server    # проверить на сервере, не применяя
kubectl diff -k overlays/prod                      # разница с кластером; код 1 — есть правки
kubectl get -k overlays/prod                       # состояние объектов сборки
kubectl delete -k overlays/prod                    # удалить все объекты сборки
kubectl kustomize --enable-helm DIR                # разрешить helmCharts (нужен helm в PATH)
kubectl kustomize --enable-helm DIR | kubectl apply -n NS -f -   # сборка с Helm, namespace явно
kustomize edit set image localhost:5001/orders-api:2.1     # сменить тег в images
kustomize edit fix                                 # перевести устаревшие поля на новые
kubectl version --client                           # строка Kustomize Version встроенной сборки
```

Частые ошибки:

- `kubectl apply -k` не принимает `--enable-helm`: сборку с Helm пускают через конвейер.
- Файл вне каталога kustomization не читается: сработал ограничитель загрузки.
- Метки попали в селектор Deployment, и обновление отклонено.
- Kustomize старше 5.8.1 с Helm 4 в PATH: сборка с `helmCharts` падает.

Подробно: карточка Kustomize в 07-3 §3, поломки — 07-3 §5.

## A.9. argocd

CLI не читает Git и кластер сам: он вызывает API сервера Argo CD. Версия CLI должна совпадать с версией сервера (3.5.5).

```bash
kubectl -n argocd port-forward svc/argocd-server 8443:443 &   # доступ к серверу с хоста
argocd login 127.0.0.1:8443 --insecure --username admin   # войти, токен сохранится
argocd version --client                            # версия CLI
argocd app list                                    # все Application: sync, health, источник
argocd app get orders-staging --refresh            # состояние; refresh перечитывает Git
argocd app diff orders-staging                     # разница Git и кластера; код 1 — есть
argocd app sync orders-staging                     # применить Git сейчас
argocd app sync orders-staging --dry-run           # показать, что бы применилось
argocd app wait orders-staging --sync --health --timeout 300   # ждать Synced и Healthy
argocd app history orders-staging                  # применённые ревизии с номерами
argocd app set orders-staging --sync-policy none   # выключить автоматическую синхронизацию
argocd app rollback orders-staging 3               # вернуть ревизию 3 (auto-sync выключен)
argocd app delete orders-staging                   # удалить Application, по умолчанию с объектами
argocd app get orders-staging -o json | jq -r '.status.sync.status'   # статус для скрипта
argocd repo list                                   # подключённые репозитории
argocd account generate-token --account ci         # токен для CI вместо пароля
```

Частые ошибки:

- Без `--insecure` вход не проходит, если сервер отдаёт самоподписанный сертификат.
- `rollback` отказывает при включённом auto-sync: сначала `app set --sync-policy none`.
- После свежего коммита `diff` пуст: контроллер ещё не сравнил, выполните refresh.
- `login` ждёт до тайм-аута: порт-форвард к серверу упал или не запущен.

Подробно: карточка argocd в 08-1 §3, диагностика — 08-1 §4–5.

## A.10. cosign

cosign подписывает дайджест образа и кладёт подпись в тот же реестр. Образ всегда задают по дайджесту, а не по тегу.

```bash
cosign version                                     # версия (на стенде v2.5.3)
COSIGN_PASSWORD='' cosign generate-key-pair        # учебная пара cosign.key и cosign.pub
D=sha256:HEX     # свой дайджест: строка digest: из docker push или 06-4, работа 3, шаг 2
COSIGN_PASSWORD='' cosign sign --key cosign.key --yes --tlog-upload=false \
  localhost:5001/lab-06-4/orders-api@$D              # подписать дайджест, без записи в Rekor
cosign verify --key cosign.pub --insecure-ignore-tlog=true \
  localhost:5001/lab-06-4/orders-api@$D            # проверить подпись открытым ключом
cosign triangulate localhost:5001/lab-06-4/orders-api@$D   # где лежит подпись в реестре
curl -s http://localhost:5001/v2/lab-06-4/orders-api/tags/list     # теги и тег .sig в реестре
```

Частые ошибки:

- `no signatures found` или `no matching signatures`: подписали другой дайджест или ключ не тот.
- `http: server gave HTTP response to HTTPS client`: реестр без TLS, добавьте `--allow-insecure-registry`.
- Подпись по тегу: тег переместили, и проверка проверяет не тот образ. Работайте с дайджестом.
- Флаги `--tlog-upload=false` и `--insecure-ignore-tlog=true` годятся только для учебного стенда.

Подробно: карточка cosign и работа 3 в 06-4, политика образов — 06-4 §3.

## A.11. velero

Velero копирует объекты namespace и файлы томов в бакет S3 и возвращает их на живой кластер. Снимок etcd он не заменяет. Флаг `--namespace` указывает namespace установки.

```bash
VEL=~/lab/k8s/04-3/bin/velero                      # бинарник из шага 1 работы 3
$VEL backup-location get --namespace lab-04-3      # доступен ли бакет: Available или Unavailable
$VEL backup create demo --include-namespaces lab-04-3-demo --wait --namespace lab-04-3
$VEL backup get --namespace lab-04-3               # список бэкапов и их фаз
$VEL backup describe demo --details --namespace lab-04-3   # состав и скопированные тома
$VEL restore create --from-backup demo --namespace lab-04-3   # восстановить из бэкапа
kubectl -n lab-04-3 logs deploy/velero             # лог сервера при Unavailable
$VEL uninstall --namespace lab-04-3 --force        # удалить Velero, CRD и namespace без вопроса
```

Частые ошибки:

- Том не скопирован: нет аннотации `backup.velero.io/backup-volumes` (режим opt-in). Восстановленный PVC пуст.
- Фаза `Unavailable`: неверный `s3Url`, ключи или нет `s3ForcePathStyle=true`.
- Фаза `PartiallyFailed` считается ошибкой: часть объектов или томов не сохранена.
- Клиент и сервер из разных релизов.

Подробно: карточка Velero и работа 3 в 04-3, поломки — 04-3 §5.

## A.12. tcpdump и netshoot

В узлах kind tcpdump нет. Контейнер netshoot делит network namespace узла и показывает его интерфейсы. Контейнер не привилегированный, ничего не монтирует с хоста.

```bash
docker pull nicolaka/netshoot:v0.13                # образ с tcpdump (около 540 МБ на диске)
IPB=$(kubectl -n lab-03-1 get pod p-lab-worker2 -o jsonpath='{.status.podIP}')   # адрес пода
docker run --rm --net=container:lab-worker2 nicolaka/netshoot:v0.13 \
  timeout 10 tcpdump -n -t -p -i eth0 -c 4 "icmp and host $IPB"   # захват на eth0 узла
tcpdump -n -i eth0 host 10.244.3.69                # без DNS-запросов, один интерфейс, адрес
tcpdump -n -t -i any -c 5 tcp port 80              # без времени, все интерфейсы, 5 пакетов
tcpdump -n -e -i eth0 arp                          # печатать MAC-адреса
tcpdump -n -i eth0 -w /tmp/a.pcap                  # записать в файл для Wireshark
docker image rm nicolaka/netshoot:v0.13            # уборка: удалить образ
```

Частые ошибки:

- Нет `-n`: утилита ждёт DNS-ответов и вывод тормозит.
- Захват на хосте, а не в namespace узла: интерфейсов пода не видно.
- `-i any` показывает один пакет несколько раз, по разу на каждом интерфейсе.
- Нет фильтра: вывод тонет в чужом трафике.

Подробно: карточка tcpdump и работа 2 в 03-1, поломки сети — 11-3.

## A.13. ingress2gateway

ingress2gateway читает Ingress и печатает Gateway и HTTPRoute. Манифесты идут в stdout, предупреждения в stderr. Результат проверяет человек.

```bash
go install github.com/kubernetes-sigs/ingress2gateway@v1.0.0   # бинарник в ~/go/bin
ingress2gateway print --input-file ingress.yaml --providers=ingress-nginx \
  --emitter envoy-gateway > gateway.yaml           # из файла, кластер не нужен
ingress2gateway print --providers=ingress-nginx --namespace lab-03-5      # из одного namespace
ingress2gateway print --providers=ingress-nginx --all-namespaces          # инвентаризация всех
kubectl apply -f gateway.yaml --dry-run=server     # проверить результат на сервере
kubectl diff -f gateway.yaml                       # что изменится в кластере
```

Частые ошибки:

- Вывод принят за готовый: предупреждения нужно читать, `gatewayClassName` и имена listener'ов править.
- Regex и таймауты переводятся приблизительно.
- Нужен Go 1.25.5 или новее для `go install`; в Ubuntu 24.04 проще взять готовый файл релиза.

Подробно: карточка ingress2gateway и работа 3 в 03-5, Gateway API — 03-4.

## A.14. stern и k9s

stern склеивает логи многих подов в один поток, k9s показывает объекты в терминале в реальном времени. Оба ходят в API-сервер с вашими правами.

```bash
stern -n orders orders-api                         # хвост логов подов, чьё имя подходит
stern -n orders -l app=orders-api                  # то же, но по метке
stern -n orders orders-api --tail 5                # начать с пяти последних строк
stern -n orders orders-api -c api --since 10m      # один контейнер, логи за 10 минут
stern -A 'orders|postgres' --no-follow             # все namespace, без слежения
k9s --readonly -n orders                           # запуск без права менять и удалять
:pods                                              # внутри k9s: список подов (также :deploy, :ns)
/текст                                             # внутри k9s: фильтр по подстроке, Esc сбрасывает
d                                                  # внутри k9s: describe выбранного объекта
l                                                  # внутри k9s: логи выбранного пода
0                                                  # внутри k9s: все namespace
:q                                                 # выйти из k9s
```

Частые ошибки:

- Слишком широкий шаблон имени: поток забит чужими логами.
- Забыт `-n`: stern ищет только в текущем namespace.
- k9s без `--readonly` на чужом кластере: одно подтверждение удаляет объект.
- k9s не запускается без терминала, например в CI.

Подробно: карточки stern и k9s в 00-2 §4, работа 3 в 00-2.

---

Связанные приложения: B (Manjaro и Ubuntu), C (запуск и сброс стенда), D (глоссарий RU и EN), E (что читать дальше).
