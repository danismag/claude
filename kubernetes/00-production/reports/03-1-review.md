# 03-1 review (Opus)

Файл: /home/user/claude/kubernetes/03-networking/03-1-pod-network-cni.md (правки на месте, без коммита).

## Найденные ошибки (было -> стало)
1. §4: `status.hostIPs` GA с 1.32 -> GA с 1.30 (feature-gate PodHostIPs: stable 1.30; в research-k8s-changes.md ошибка, стоит поправить там).
2. §1: netkit «ядро 6.7 и новее» -> «для Cilium нужно ядро 6.8 и новее» (cilium system_requirements.rst).
3. §2 таблица: Cilium туннель «UDP 8472» -> «UDP 8472 или UDP 6081» (Geneve); добавлена фраза: 8472 — значение ядра Linux по умолчанию, 4789 — стандартный IANA/RFC 7348.
4. §6: «Адресов в /24 — 254» -> «253 для подов: host-local не выдаёт адрес сети, шлюз .1 и broadcast».
5. Работа 4, ответ 1: «/25 — 126 адресов, запас ~16, после 17 протёкших» -> «125 адресов, запас 17, после 18 протёкших».
6. §5 MTU: добавлено, что у busybox ping нет `-M` — проверка из образа с iputils (netshoot).
7. Работа 2, «Что понадобится»/«Риски»: «около 540 МБ» -> скачивается ~185 МБ (Docker Hub, amd64, тег v0.13 существует, 2024-05-15), на диске ~540 МБ (старая часть). Риски уточнены: netns контейнера-узла kind, а не хоста; контейнер не привилегирован, без монтирований; стандартные capabilities Docker включают NET_RAW (достаточно tcpdump), без NET_ADMIN; захват видит весь трафик узла, включая чужие поды.
8. Работа 3, шаг 2: заголовок «в начале каждой — имя интерфейса» противоречил выводу (во второй строке его нет) -> «у второй строки опущены имя интерфейса и направление»; в разборе — «в полном выводе стоят eth0 и Out».
9. Работа 4: «pause:3.10 уже есть на узлах» (не подтверждено) -> «если нет на узле, containerd скачает из registry.k8s.io».
10. Работа 2, ответ 1: «внутренние адреса видны только с -v или в Wireshark» (неверно: tcpdump декодирует VXLAN/OTV) -> внешний пакет UDP 8472/4789 и пояснение, что фильтр `host $IPB` его не поймал бы.
11. §5 «Поды на разных узлах»: ссылка «схемы 8» после перенумерации -> «схемы 11»; Итог работы 2 «схема 10» -> «схема 13». Схемы перенумерованы 1–15.

## Дополнение теории (по заданию ведущего)
- §2 новый `### Шлюз пода и ARP`: маршруты ptp в поде (подсеть через шлюз, шлюз scope link), адрес шлюза /32 на каждом узловом veth, ARP без proxy-ARP; Calico 169.254.1.1 + proxy ARP; bridge/cni0; NDP в IPv6. Схема 7.
- §2 `### Связь между узлами: путь пакета`: узел как маршрутизатор (ip_forward включает ptp), путь под->под по шагам, схема 8; определение conntrack перенесено сюда (первое употребление).
- §2 `### Выход наружу: SNAT и conntrack`: переход POSTROUTING -> KIND-MASQ-AGENT для не-LOCAL трафика, iptables; запись conntrack в двух направлениях (схема 10, упрощённая, помечена), сохранение порта, nf_conntrack_max и умолчания kube-proxy.
- §3 новый `### IPv6 и dual-stack`: stable 1.23, два cluster-cidr, podCIDRs /24+/64, kind ipFamily: dual, fd00:10:244::/56, podIPs, ipFamilies/ipFamilyPolicy.
- §4: `ip route get <IP пода>`.
- §5: ip_forward и FORWARD DROP от Docker на узле; подраздел выхода переименован «чужой адрес и полная таблица conntrack» (`table full, dropping packet`, nf_conntrack_count/max).
- §6: VXLAN поверх IPv6 70 байт, Geneve UDP 6081, новый `### Таблица conntrack` (32768/ядро, min 131072, 24 ч, 0 — не трогать).
Теория ~3,3 тыс. слов (было ~2,55).

## Читаемость
До: предложений 257, средняя 10,8, короче 10 слов 40 %, >25 слов 0, нарушений 3 (строки кода 128/138/132 — реальный вывод iptables-save и события scheduler).
После: предложений 309, средняя 11,2, короче 10 слов 38 %, >25 слов 0 (одно 30-словное в новом тексте разбито), нарушений 3 (те же строки реального вывода, оставлены целиком по прецеденту 03-2).

## Подтверждено (источник)
- kindnetd стенда (kind images/kindnetd): CNI ptp + host-local (dataDir /run/cni-ipam-state) + portmap, ipMasq false; masq-агент через iptables, цепочка KIND-MASQ-AGENT, переход из POSTROUTING для не-LOCAL, комментарии правил совпадают с выводом — cni.go, masq.go.
- ptp: адрес шлюза /32 на host veth, host route к поду, в поде маршрут к шлюзу scope link и подсеть через шлюз, proxy ARP не используется, EnableForward — containernetworking/plugins ptp.go.
- netshoot:v0.13 существует, amd64 ~184 МБ сжатый — Docker Hub API.
- Flannel VXLAN порт 8472 (ядро по умолчанию) — flannel backends.md. Cilium VXLAN 8472, Geneve 6081, netkit ядро 6.8+ — cilium system_requirements.rst. Calico накладные: IPIP 20, VXLAN 50 (IPv6 70), WireGuard 60/80 — tigera/docs mtu.mdx.
- maxPods 110, podsPerCore 0 — kubelet config v1beta1 types.go. --node-cidr-mask-size 24/64 — kube-controller-manager reference. kube-proxy conntrack 32768/131072/24h — kube-proxy reference. dual-stack stable 1.23, /24 и /64 — dual-stack.md. kind podSubnet 10.244.0.0/16 и fd00:10:244::/56, ipFamily dual, disableDefaultCNI — kind configuration.md. PodHostIPs GA 1.30 — feature-gates PodHostIPs.md. AWS m5.large 29, формула ENI*(IP-1)+2 — amazon-vpc-cni-k8s eni-max-pods.txt.
- Реальный вывод (подсети, адреса, traceroute, tcpdump id 26, KIND-MASQ-AGENT, SNAT, 106/115, 110, событие, 108) — старая версия e755ced; `scope host` маршрута к поду — 01-2.

## Неподтверждено (для 00-plan)
- Calico порты TCP 179, UDP 4789, IP-протокол 4 и шлюз 169.254.1.1 + proxy ARP — страница требований Calico не открылась (общеизвестно, не сверено).
- Docker ставит политику FORWARD DROP — по документации Docker по памяти, не открыто.
- Размер netshoot на диске ~540 МБ — из старой части (не измерено повторно).
- Вывод custom-columns в подготовке и шаге 1 работы 1 — данные реальные, формат собран.
- Работа 1 шаг 4: три строки `via 172.20.0.x` на lab-worker2 выведены из подсетей, не снимались.
- Работа 2: строки `listening on …`, вывод на veth (шаг 3) и вторая пара пакетов — ожидаемые; `Status: Downloaded newer image` — ожидаемое.
- Работа 2 шаг 3: awk `/^$IPB /` — не прогонялся (в старой части был `/$IPB/`).
- Работа 3 шаг 1: `grep -- '-A KIND-MASQ-AGENT'` вместо `grep -E KIND-MASQ` — не прогонялся.
- Работа 4: allocatable.pods = 110 ожидаемое; имена kindnet-…/kube-proxy-… и сообщения уборки — ожидаемые; Deployment с replicas=0 + scale вместо create+patch — не прогонялся.
- Схема 10 (запись conntrack) — упрощённая схема, не вывод `conntrack -L`.
- Отличие от плана: работ четыре (SNAT и потолок подов разделены) — записать в 00-plan §4/§6.
