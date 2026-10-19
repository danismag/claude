# 03-1. Сеть подов и CNI

> Модуль 3 «Сеть» · часть 1 из 5 · 🟡🔴 · ~1 ч чтения + ~40 мин лабы · Нужно: стенд 00-1. База — курс `networks`: модель сети Kubernetes, Flannel VXLAN/Calico BGP/Cilium с разбором пути пакета (networks 08-2), netns и veth (networks 06-3), NAT (networks 03-4). Здесь — то, что нужно эксплуатации поверх этой базы.

---

## Зачем это DevOps-у

Сетью подов занимается CNI, и в работе вы сталкиваетесь с ней в трёх ситуациях: под висит в `ContainerCreating` с `FailedCreatePodSandBox` (CNI не выдал IP), «поды на одном узле видят друг друга, а на разных — нет» (маршруты, оверлей, MTU) и «внешний сервис видит не тот IP» (SNAT на выходе). Плюс планирование ёмкости: сколько подов влезет на узел и сколько адресов нужно кластеру. На собеседовании — «как под на одном узле попадает в под на другом» и «чем Calico отличается от Flannel» (разбор — networks 08-2).

В сквозном сценарии: путь orders-api → postgres, когда они на разных узлах, и путь orders-api → внешний API.

---

## 1. Модель и что делает CNI 🟡

Требования Kubernetes (подробно — networks 08-2 §1): у каждого пода свой IP; поды видят друг друга без NAT; агенты узла видят все поды. Как это обеспечить — выбор CNI.

На каждом узле при создании sandbox'а пода containerd вызывает CNI-плагины по конфигу из `/etc/cni/net.d/` (01-2 §4). Типичная цепочка:

| Шаг | Кто | Что |
|---|---|---|
| интерфейс | основной плагин (`ptp`, `bridge`, `calico`, `cilium-cni`) | veth-пара: `eth0` в netns пода, `veth…` на узле |
| адрес | IPAM (`host-local`, `calico-ipam`, облачный IPAM) | IP из подсети узла (или из VPC) |
| маршруты | основной плагин | в поде — default через шлюз; на узле — `/32` на veth |
| доп. функции | chained-плагины (`portmap`, `bandwidth`, `tuning`) | hostPort, ограничения скорости |
| между узлами | агент CNI (DaemonSet) | маршруты/BGP/туннели/eBPF |

## 2. CNI стенда: kindnet, маршрутизация без оверлея 🟡

Подсети узлов (проверено):

```
lab-control-plane   10.244.0.0/24   172.20.0.2
lab-worker          10.244.2.0/24   172.20.0.3
lab-worker2         10.244.3.0/24   172.20.0.5
lab-worker3         10.244.1.0/24   172.20.0.4
```

`spec.podCIDR` раздаёт controller-manager из `--cluster-cidr` (у kind — `10.244.0.0/16`, по /24 на узел). Подсеть привязана к узлу на всю его жизнь.

Изнутри пода (проверено, под на `lab-worker` → под на `lab-worker2`):

```
inet 10.244.2.84/24 brd 10.244.2.255 scope global eth0
default via 10.244.2.1 dev eth0
1500                                                  ← MTU
3 packets transmitted, 3 packets received, 0% packet loss
round-trip min/avg/max = 0.095/0.101/0.110 ms
traceroute to 10.244.3.69
 1  10.244.2.1  0.007 ms                              ← узел-источник
 2  172.20.0.5  0.003 ms                              ← узел-назначение (его IP — следующий хоп)
 3  10.244.3.69  0.003 ms
```

На проводе между узлами — **IP подов, без NAT и без инкапсуляции** (проверено, `tcpdump -i eth0` на `lab-worker2`):

```
IP 10.244.2.84 > 10.244.3.69: ICMP echo request, id 26, seq 0, length 64
IP 10.244.3.69 > 10.244.2.84: ICMP echo reply, id 26, seq 0, length 64
```

И тот же пакет на veth целевого пода (`10.244.3.69 dev vethe045ab2f` в таблице узла).

kindnet просто прописывает на каждом узле маршрут «подсеть соседнего узла → через его IP» (01-2 §4). Это работает, только когда все узлы в одном L2-сегменте или маршрутизатор между ними знает эти подсети. Для узлов в разных подсетях без управления маршрутизацией нужен оверлей (VXLAN, Geneve) или BGP — сравнение и разбор пути пакета Flannel VXLAN, Calico BGP и Cilium — networks 08-2 §2, туннели — networks 10-1.

## 3. Выход наружу: SNAT 🟡

Поды в «серых» адресах `10.244.x.x`; трафик за пределы pod-CIDR узел маскирует своим IP. В kind — правило kind-masq-agent (проверено, `iptables-save -t nat` на узле):

```
-A KIND-MASQ-AGENT -d 10.244.0.0/16 -m comment --comment "kind-masq-agent: local traffic is not subject to MASQUERADE" -j RETURN
-A KIND-MASQ-AGENT -m comment --comment "kind-masq-agent: outbound traffic is subject to MASQUERADE (must be last in chain)" -j MASQUERADE
```

Проверено (`wget http://1.1.1.1` из пода): на veth пакет от `10.244.2.84`, на eth0 узла — уже от `172.20.0.3`:

```
vethfcf7cbd3 In  IP 10.244.2.84.39456 > 1.1.1.1.80: Flags [S] ...
                 IP 172.20.0.3.39456 > 1.1.1.1.80: Flags [S] ...
```

Следствия для эксплуатации:

- Внешняя система (БД вне кластера, API партнёра, firewall) видит **IP узла**, а не пода. Разрешать доступ «для сервиса» по IP приходится на все узлы — или через egress-gateway (Cilium, Calico Enterprise, Istio) с фиксированным IP.
- Под переехал на другой узел — у внешней системы сменился IP источника.
- conntrack-таблица узла общая на все поды: тысячи исходящих соединений из подов съедают `nf_conntrack_max` узла (networks 06-5).
- Облачные CNI (AWS VPC CNI, Azure CNI) дают подам адреса из VPC — SNAT нет (или настраивается), зато адреса VPC кончаются.

## 4. Ёмкость: maxPods и подсеть узла 🟡🔴

Два независимых лимита:

| Лимит | На стенде | Что будет при превышении |
|---|---|---|
| `maxPods` kubelet | 110 (дефолт) | scheduler: `Too many pods`, под Pending |
| размер подсети узла | /24 = 254 адреса | CNI не выдаёт IP: `FailedCreatePodSandBox … no IP addresses available in range set`, под в `ContainerCreating` |

Проверено (Deployment на 115 подов `pause`, прибитый к `lab-worker3`, на котором уже было 4 пода):

```
NAME   READY     UP-TO-DATE   AVAILABLE   AGE
many   106/115   115          106         60s
110                                   ← подов на узле
0/4 nodes are available: 1 Too many pods, 1 node(s) had untolerated taint(s), 2 node(s) didn't match Pod's node affinity/selector. ...
108                                   ← занятых IP в /run/cni-ipam-state/kindnet
```

110 подов на узле, но 108 адресов: поды с `hostNetwork: true` (kube-proxy, kindnet) IP из подсети подов не берут. Файлы IPAM `host-local` — по файлу на выданный адрес; если они «протекли» (CNI не вызвал DEL при сбое), адреса кончаются раньше `maxPods` — диагностика: сравнить число файлов с числом подов узла.

Планирование: `cluster-cidr` /16 = 256 узлов по /24; больше узлов — шире `cluster-cidr` или меньше маска на узел (`--node-cidr-mask-size`). У облачных CNI с адресами из VPC лимит — ENI/IP на тип инстанса (AWS: m5.large — 29 подов) — ⚠️ не проверено на стенде, данные из документации AWS VPC CNI.

## 5. hostNetwork, hostPort, NodePort — когда под живёт в сети узла 🟡

| | Что | Когда | Цена |
|---|---|---|---|
| `hostNetwork: true` | под в netns узла: его IP = IP узла | CNI, kube-proxy, node-exporter, ingress на bare metal | порты конфликтуют между подами узла; NetworkPolicy обычно не действует; доступ к сервисам узла |
| `hostPort` | порт узла → порт пода (DNAT, плагин `portmap`) | редкие случаи «один под на узел слушает порт» | один под на порт на узел; обходит Service |
| `NodePort` | порт на **всех** узлах → Service (03-2) | вход в кластер без LB (как Gateway стенда) | диапазон 30000–32767 |

Под с `hostNetwork` в выводе `kubectl get pods -o wide` имеет IP узла — на стенде это kindnet и kube-proxy (`172.20.0.x`).

## 6. Когда CNI ломается 🟡

| Симптом | Где смотреть | Типовая причина |
|---|---|---|
| под в `ContainerCreating`, событие `FailedCreatePodSandBox … failed to setup network` | `kubectl describe pod`, логи DaemonSet CNI на узле, `journalctl -u containerd` | агент CNI не запущен на узле (новый узел, taint без toleration), нет конфига в `/etc/cni/net.d`, кончились IP |
| узел `NotReady`, `container runtime network not ready: cni plugin not initialized` | `kubectl describe node` | CNI не установлен или не стартовал |
| поды на одном узле видят друг друга, на разных — нет | `ip route` на узлах, `tcpdump` на eth0 обоих узлов | нет маршрутов/BGP-сессий, firewall между узлами режет VXLAN (UDP 8472/4789) или IP-in-IP (протокол 4) |
| маленькие запросы проходят, большие висят | MTU пода vs MTU пути | оверлей без уменьшения MTU, PMTUD заблокирован (networks 02-1) |
| внешний сервис отвергает подключения подов | `tcpdump` на eth0 узла | SNAT в IP узла, у партнёра whitelist по IP подов/egress-IP |

---

## 🔧 Лаба

### Шаг 0. Подготовка

```bash
kubectl config use-context kind-lab
kubectl create ns lab-03-1
kubectl config set-context --current --namespace=lab-03-1
for w in lab-worker lab-worker2; do
  kubectl run p-$w --image=busybox:1.37 --overrides="{\"spec\":{\"nodeName\":\"$w\"}}" -- sleep infinity
done
kubectl wait --for=condition=Ready pod --all
kubectl get pods -o wide
kubectl get nodes -o custom-columns=NODE:.metadata.name,PODCIDR:.spec.podCIDR,IP:.status.addresses[0].address
```

`nodeName` прибивает под к узлу в обход scheduler'а — удобно для опытов, в проде — affinity (05-2).

### Шаг 1. Изнутри пода

```bash
IPB=$(kubectl get pod p-lab-worker2 -o jsonpath='{.status.podIP}')
kubectl exec p-lab-worker -- sh -c "ip -4 addr show eth0 | grep inet; ip route; cat /sys/class/net/eth0/mtu; ping -c 3 -q $IPB | tail -2; traceroute -n -q 1 -w 1 $IPB"
```

Проверено: вывод в §2.

### Шаг 2. На проводе — tcpdump на узле

На узлах kind нет `tcpdump` — запускаем контейнер с инструментами в сетевом namespace узла:

```bash
docker pull nicolaka/netshoot:v0.13          # ~540 МБ
docker run --rm --net=container:lab-worker2 nicolaka/netshoot:v0.13 timeout 8 tcpdump -n -i eth0 icmp -c 4 &
sleep 2; kubectl exec p-lab-worker -- ping -c 2 -q $IPB; wait

VETH=$(docker exec lab-worker2 sh -c "ip route | awk '/$IPB/{print \$3}'"); echo $VETH
docker run --rm --net=container:lab-worker2 nicolaka/netshoot:v0.13 timeout 6 tcpdump -n -i $VETH icmp -c 2 &
sleep 2; kubectl exec p-lab-worker -- ping -c 1 -q $IPB; wait
```

Проверено: на eth0 и на veth — адреса подов (§2). На реальном узле: `sudo tcpdump -ni eth0 host <IP пода>` или `kubectl debug node/<узел> --image=nicolaka/netshoot:v0.13` (00-2 §6).

### Шаг 3. SNAT на выходе

```bash
docker exec lab-worker sh -c 'iptables-save -t nat | grep -E "KIND-MASQ"'
docker run --rm --net=container:lab-worker nicolaka/netshoot:v0.13 timeout 8 tcpdump -n -i any 'tcp port 80 and host 1.1.1.1' -c 3 &
sleep 3; kubectl exec p-lab-worker -- wget -q -T 5 -O /dev/null http://1.1.1.1; wait
```

Проверено: на veth источник `10.244.2.84`, на eth0 — `172.20.0.3` (§3).

### Шаг 4. Потолок подов на узле

```bash
kubectl get pods -A --field-selector spec.nodeName=lab-worker3 --no-headers | wc -l
kubectl create deploy many --image=registry.k8s.io/pause:3.10 --replicas=115
kubectl patch deploy many -p '{"spec":{"template":{"spec":{"nodeSelector":{"kubernetes.io/hostname":"lab-worker3"}}}}}'
sleep 60
kubectl get deploy many
kubectl get pods -A --field-selector spec.nodeName=lab-worker3 --no-headers | wc -l
P=$(kubectl get pods -l app=many --field-selector=status.phase=Pending -o name | head -1)
kubectl get events --field-selector involvedObject.name=${P#pod/},reason=FailedScheduling -o jsonpath='{.items[-1:].message}{"\n"}'
docker exec lab-worker3 sh -c 'ls /run/cni-ipam-state/kindnet | grep -c "^10\."'
kubectl delete deploy many
```

Проверено: вывод в §4. Образ `pause` уже есть на каждом узле — 115 подов не тянут ничего из сети.

### Уборка

```bash
kubectl config set-context --current --namespace=default
kubectl delete ns lab-03-1
docker image rm nicolaka/netshoot:v0.13      # если не нужен для 03-2…03-5 (там он используется)
```

---

## 🔥 Кейс из прода: «новые поды не получают IP, хотя на узле 60 подов»

**Контекст.** Кластер на self-hosted узлах, CNI с `host-local` IPAM, подсеть узла /25 (126 адресов), `maxPods: 110`. На одном узле поды начали висеть в `ContainerCreating`: `FailedCreatePodSandBox … failed to allocate for range 0: no IP addresses available in range set: 10.20.7.1-10.20.7.126`. На узле при этом 60 подов.

**Разбор.**
1. `ls /var/lib/cni/networks/<сеть>/ | wc -l` на узле — 126 файлов: все адреса «заняты».
2. Сверка: файлы содержат ID контейнеров; 66 из них — контейнеров, которых уже нет (`crictl pods -q` не знает таких sandbox'ов).
3. Причина: после серии OOM на узле containerd несколько раз падал во время удаления подов, CNI DEL не вызывался — адреса не освобождались. Утечка накапливалась месяцами.

**Фикс.**
- Немедленно: drain узла, перезагрузка (`host-local` в `/run` — tmpfs, очищается; у этого CNI каталог был на диске) или удаление «осиротевших» файлов с ID несуществующих контейнеров.
- Подсеть узла расширили до /24 (`--node-cidr-mask-size=24`) — запас больше `maxPods`.
- Алерт: доля занятых IP в подсети узла (у Calico/Cilium есть метрики IPAM) и событие `FailedCreatePodSandBox` в мониторинге событий.
- Выяснили и устранили причину OOM, которая валила containerd (05-4).

**Что запомнить.**
- `ContainerCreating` + `FailedCreatePodSandBox` — проблема CNI, а не приложения.
- Подсеть узла должна быть с запасом больше `maxPods`.
- IPAM может «течь»; число выданных адресов ≠ число подов.

---

## 💼 Вопросы с собеседования

### 🟢 Junior

**1. Что такое CNI?**
Спецификация и плагины, которые подключают под к сети: создают интерфейс в netns пода, выдают IP, прописывают маршруты. Вызываются рантаймом (containerd) при создании и удалении sandbox'а пода. Примеры: Calico, Cilium, Flannel, kindnet, облачные CNI.

**2. Каким адресом под ходит во внешний интернет?**
Обычно адресом узла: узел делает SNAT (MASQUERADE) трафика за пределы pod-CIDR. Исключения — облачные CNI с адресами из VPC и egress-gateway с фиксированным IP.

### 🟡 Middle

**3. Как под на одном узле достучится до пода на другом?**
Из пода — через veth на узел; на узле маршрут на подсеть соседнего узла: напрямую через его IP (L2-соседство, kindnet, Calico без инкапсуляции), через BGP-маршрут или через туннель (VXLAN/IP-in-IP: пакет пода внутри пакета между IP узлов). NAT между подами нет (разбор путей — networks 08-2).

**4. Под висит в ContainerCreating с FailedCreatePodSandBox. Что проверяете?**
Сообщение события; запущен ли агент CNI на узле (DaemonSet, tolerations); есть ли конфиг в `/etc/cni/net.d`; хватает ли IP в подсети узла (`no IP addresses available`); логи containerd и CNI-агента на узле.

**5. Сколько подов можно запустить на узле?**
Минимум из `maxPods` kubelet (дефолт 110), свободных адресов в подсети узла (для /24 — 254) и ресурсов (requests, 05-1). В облачных CNI с адресами из VPC — лимит ENI/IP типа инстанса.

### 🔴 Senior

**6. Внешняя БД пускает только с разрешённых IP. Как дать доступ сервису из кластера?**
Варианты: разрешить IP всех узлов (широко, ломается при автоскейлинге); выделенный пул узлов с фиксированными IP и taint для этого сервиса; egress-gateway CNI или mesh с закреплённым IP; NAT-шлюз VPC с фиксированным адресом (если весь кластер ходит через него). Плюс сетевые политики внутри кластера, чтобы этим путём пользовался только нужный сервис.

**7. Поды на разных узлах перестали видеть друг друга после добавления узлов. Ваши действия?**
Сравнить маршруты на старом и новом узле, подсети узлов; `tcpdump` на eth0 обоих: доходит ли пакет; если оверлей — проходит ли VXLAN/IP-in-IP между подсетями узлов (firewall/security group), MTU; если BGP — сессии и анонсы. Типовая причина — новые узлы в другой подсети при CNI в режиме «маршруты без инкапсуляции» (кейс networks 08-2).

---

## ⚠️ Подводные камни

- `ContainerCreating` дольше минуты — смотрите события пода, а не логи приложения.
- Подсеть узла меньше `maxPods` → поды упираются в IP раньше лимита.
- IPAM `host-local` хранит выданные адреса в файлах; при сбоях они «текут».
- SNAT в IP узла: внешние whitelist'ы и логи видят узел, а не под; IP меняется при переезде пода.
- `hostNetwork: true` — под получает сеть узла: конфликты портов и обход NetworkPolicy.
- MTU оверлея должен быть меньше MTU узла на размер заголовка (VXLAN — 50 байт).
- На узлах kind нет `tcpdump` — используйте netshoot в netns узла.

---

## Чеклист

- [ ] Найду подсеть узла, IP пода, veth на узле и маршрут к подсети соседа.
- [ ] Покажу tcpdump'ом, что между узлами идут IP подов (или туннель — в своём CNI).
- [ ] Покажу SNAT на выходе и объясню последствия для внешних систем.
- [ ] Рассчитаю ёмкость: `maxPods`, подсеть узла, `cluster-cidr`.
- [ ] Разберу `FailedCreatePodSandBox` и «поды на разных узлах не видят друг друга».

---

## Задание со звёздочкой

Посмотрите, как выглядит оверлей, на втором кластере:

1. Создайте рядом второй kind-кластер `lab2` с `networking.disableDefaultCNI: true` и установите Flannel (VXLAN).
2. Повторите шаг 2 лабы: что видно на eth0 узла? Найдите внешний заголовок UDP 8472 и внутренний ICMP между IP подов (`tcpdump -ni eth0 udp port 8472 -v`).
3. Посмотрите MTU `eth0` пода и интерфейса `flannel.1`. Отправьте `ping -s 1472 -M do` между подами — пройдёт? Почему?
4. Удалите кластер: `kind delete cluster --name lab2`.

---

→ Следующая часть: **03-2. Service и kube-proxy** — EndpointSlice и readiness, Service без endpoints и неверный `targetPort`, `externalTrafficPolicy: Local` на NodePort (находка стенда с Envoy), sessionAffinity, режимы kube-proxy; цепочки iptables — в networks 08-3.
