# 10-1. Сборка кластера: kubeadm, PKI, TLS bootstrap, HA control plane

> Модуль 10 «Эксплуатация кластера» · часть 1 из 4 · ~2 ч чтения + ~1,5 ч лабораторных · Нужно: стенд 00-1 (контекст `kind-lab`); для работы 3 ещё около 5 ГиБ свободной памяти и Docker · Опирается на: 01-1 (control plane и etcd), 01-2 (kubelet и static pods), 06-1 (сертификаты и CSR)

## Где мы на карте

До этой части мы работали с готовым кластером: модули 01–09 объясняли, как он устроен и как им пользоваться. Здесь мы разберём, как кластер получается из пустых машин: какие ключи и файлы создаёт инструмент сборки и как узлы начинают доверять друг другу. Часть опирается на компоненты control plane (01-1), на kubelet со static pods (01-2) и на сертификаты (06-1).

Следующие части модуля работают с уже собранным кластером. Копия данных и члены etcd (10-2), обновление версий (10-3) и продление сертификатов (10-4) используют те же файлы и те же фазы, которые описаны здесь.

```
хост / ВМ ─► ОС, containerd, kubelet, kubeadm         ставит администратор (не эта часть)
                │
                ▼
          kubeadm init / join                         10-1 (эта часть): ключи, конфиги, static pods
                │
                ▼
     работающий кластер ─► etcd (10-2) ─► обновление (10-3) ─► сертификаты (10-4)
```

Схема 1. Что делает kubeadm и где он стоит в курсе: он собирает кластер из подготовленных узлов, а дальше с кластером работают следующие части.

---

## 1. Какую задачу решает kubeadm

Собрать кластер вручную значит выпустить десятки файлов и согласовать их между собой. kubeadm выполняет эту работу по одной команде и делает результат одинаковым на каждом узле.

### Что нужно собрать, чтобы кластер заработал

Компоненты кластера общаются по TLS и проверяют друг друга по сертификатам, поэтому без подготовки они даже не соединятся. Минимальный набор такой.

- **Ключи и сертификаты.** Одиннадцать пар ключей: три центра сертификации, сертификаты API-сервера, etcd и служебных клиентов, пара для токенов ServiceAccount.
- **Kubeconfig-файлы.** По одному у администратора, controller-manager, scheduler и каждого kubelet.
- **Манифесты static pods.** Четыре файла для API-сервера, controller-manager, scheduler и etcd (01-2).
- **Токен для новых узлов.** Узел без сертификата должен как-то доказать, что ему можно войти.
- **Дополнения.** CoreDNS и kube-proxy, без которых не работают имена и Service (03-2, 03-3).

Каждый пункт зависит от остальных: адрес API-сервера записан в сертификаты и в kubeconfig, а срок сертификатов определяет, когда кластер перестанет отвечать (10-4).

### Что делает kubeadm и что остаётся вам

**kubeadm** — консольная утилита проекта Kubernetes, которая создаёт и обновляет кластер на подготовленных узлах. Она выполняет `init` на первом узле control plane и `join` на остальных. Слово «подготовленных» важно: kubeadm не ставит операционную систему, containerd и kubelet, не выбирает CNI-плагин (03-1) и не создаёт балансировщик перед API-сервером.

Поэтому перед `kubeadm init` администратор готовит узел сам. Он ставит containerd, kubelet и kubeadm, выключает swap, включает пересылку пакетов в ядре и открывает порты между узлами. Ещё он выбирает адрес, по которому клиенты будут ходить в кластер. Остальное делает kubeadm.

### Где kubeadm в kind

kind (00-2) не придумывает свой способ сборки: внутри образа `kindest/node` уже лежат kubelet и kubeadm. kind пишет файл конфигурации и запускает на первом узле `kubeadm init`, а на остальных `kubeadm join`. Поэтому всё, что вы увидите в этой части на стенде, совпадает с настоящим кластером kubeadm, кроме подготовки ОС и сети: её заменяет Docker. Следы вызова на узле разобраны в §4.

Кто хочет пройти путь без kubeadm, делает его руками по руководству Kubernetes the Hard Way (приложение E). В курсе мы туда не уходим: цель части — понять, что kubeadm создаёт и где это искать.

---

## 2. Как устроена сборка кластера

kubeadm разбивает сборку на фазы, читает настройки из одного файла и складывает результат в предсказуемые каталоги. Ниже мы пройдём фазы, формат файла, ключи, kubeconfig и вход нового kubelet.

### Фазы kubeadm init

**Фаза** (phase) — самостоятельный шаг сборки, который можно запустить отдельно командой `kubeadm init phase <имя>` или пропустить флагом `--skip-phases`. Всего их четырнадцать, и порядок фиксирован.

Таблица ниже показывает фазы в порядке запуска и то, что каждая оставляет после себя.

| Фаза | Что делает | Результат |
|---|---|---|
| preflight | проверяет узел: порты, swap, cgroup v2, CPU и память | ничего не создаёт |
| certs | выпускает CA и все сертификаты | каталог /etc/kubernetes/pki |
| kubeconfig | пишет kubeconfig-файлы | admin.conf, super-admin.conf и ещё три файла |
| etcd | пишет манифест локального etcd | /etc/kubernetes/manifests/etcd.yaml |
| control-plane | пишет манифесты трёх компонентов | три файла в manifests |
| kubelet-start | пишет конфиг kubelet и запускает его | /var/lib/kubelet/config.yaml |
| wait-control-plane | ждёт, пока static pods ответят | ничего не создаёт |
| upload-config | кладёт настройки в кластер | ConfigMap kubeadm-config и kubelet-config |
| upload-certs | шифрует сертификаты в Secret, только с флагом | Secret kubeadm-certs |
| mark-control-plane | ставит метку и taint на узел | узел становится control plane |
| bootstrap-token | создаёт токен и права для входа узлов | Secret токена, ConfigMap cluster-info |
| kubelet-finalize | включает ротацию клиентского сертификата kubelet | обновлённый kubelet.conf |
| addon | ставит CoreDNS и kube-proxy | Deployment и DaemonSet |
| show-join-command | печатает команду для новых узлов | текст в терминале |

```
preflight ─► certs ─► kubeconfig ─► etcd ─► control-plane ─► kubelet-start ─► wait-control-plane
   ─► upload-config ─► (upload-certs) ─► mark-control-plane ─► bootstrap-token ─► kubelet-finalize
   ─► addon ─► show-join-command
```

Схема 2. Порядок фаз `kubeadm init`: сначала файлы на диске, потом объекты в кластере. Фаза upload-certs стоит в скобках, потому что она работает только с флагом.

Порядок объясняет, откуда kubeadm берёт доступ к API-серверу. До фазы wait-control-plane кластера ещё нет, и kubeadm только пишет файлы. kubelet читает манифесты (01-2), запускает static pods, и только тогда kubeadm получает API и кладёт в него настройки, токен и дополнения. Узел получает статус Ready не сразу: пока нет CNI-плагина, CoreDNS остаётся Pending, и это нормально.

### Конфигурация kubeadm v1beta4

Параметры сборки лежат в одном YAML-файле из нескольких документов, который передают флагом `--config`. Версия формата `kubeadm.k8s.io/v1beta4` введена в kubeadm 1.31. Версия v1beta3 устарела: документация пакета обещает удалить её «в 1.34 или позже», но kubeadm 1.36 её ещё читает. Старый файл переводит команда `kubeadm config migrate`, а новые файлы сразу пишут в v1beta4.

Для `init` и `join` в файле бывают три типа документов kubeadm и два типа компонентов.

- **ClusterConfiguration** — свойства кластера: версия, `controlPlaneEndpoint`, подсети, флаги API-сервера, настройки etcd, срок сертификатов. Он попадает в кластер, в ConfigMap `kubeadm-config`.
- **InitConfiguration** — свойства первого запуска: токены, адрес этого узла, имя узла, пропускаемые фазы. Он нужен только `init` и в кластер не попадает, потому что содержит токены.
- **JoinConfiguration** — свойства присоединения: как узел находит кластер (`discovery`), нужно ли ему стать узлом control plane, адрес этого узла.
- **KubeletConfiguration** и **KubeProxyConfiguration** — настройки kubelet (01-2) и kube-proxy (03-2), которые kubeadm кладёт в ConfigMap и раздаёт узлам.

В версии v1beta4 изменились три вещи. Поле `extraArgs` стало списком пар `name` и `value`, потому что флаг можно повторить. Тайм-ауты собрались в структуру `timeouts` (значения — в §6). Срок сертификатов теперь задают полями `certificateValidityPeriod` (по умолчанию 8760 часов, год) и `caCertificateValidityPeriod` (87600 часов, десять лет). Ещё поле `encryptionAlgorithm` выбирает тип ключей: по умолчанию RSA-2048, также RSA-3072, RSA-4096 и ECDSA-P256.

```
kubeadm.yaml  (--config)
 ├─ InitConfiguration      токены, nodeRegistration, localAPIEndpoint     только для init
 ├─ ClusterConfiguration   controlPlaneEndpoint, networking, apiServer…  ─► ConfigMap kubeadm-config
 ├─ KubeletConfiguration   cgroupDriver, rotateCertificates…             ─► ConfigMap kubelet-config
 └─ KubeProxyConfiguration mode, conntrack…                               ─► ConfigMap kube-proxy
```

Схема 3. Документы файла kubeadm и то, куда они попадают. Смотрите на правый столбец: в кластер уходит всё, кроме InitConfiguration.

Точечные правки без полного файла делают **patches** — файлы-заплатки, которые kubeadm накладывает на манифесты static pods перед записью. У kind есть похожее поле `kubeadmConfigPatches` (06-4), но оно правит сам файл конфигурации kubeadm, а не манифесты.

### PKI кластера

**PKI** (public key infrastructure, инфраструктура открытых ключей) — набор центров сертификации, ключей и сертификатов, на которых держится доверие компонентов. **CA** (certificate authority, центр сертификации) — пара ключей, которой подписывают остальные сертификаты. Проверка устроена просто: компонент доверяет сертификату, если его подписал известный ему CA.

kubeadm создаёт три независимых CA в каталоге `/etc/kubernetes/pki`. Кластерный `ca` подписывает всё, что связано с API-сервером и kubelet. CA `etcd/ca` подписывает сертификаты etcd, а etcd доверяет только ему, поэтому ключ кластерного CA не открывает доступ к данным etcd. CA `front-proxy-ca` подписывает клиент, через который API-сервер передаёт запросы расширениям. Сертификат, который подписал CA и который сам других не подписывает, называют **листовым** (leaf certificate).

```
/etc/kubernetes/pki
 ├─ ca.crt / ca.key                          кластерный CA (10 лет)
 │   ├─ apiserver.crt                        сервер API (SAN: адреса и имена API-сервера)
 │   ├─ apiserver-kubelet-client.crt         API-сервер ходит в kubelet (logs, exec)
 │   └─ (клиентские сертификаты kubelet выдаёт CSR, §2)
 ├─ etcd/ca.crt / ca.key                     CA etcd
 │   ├─ server.crt, peer.crt                 etcd: клиентский порт 2379 и порт членов 2380
 │   ├─ healthcheck-client.crt               проверка здоровья etcd
 │   └─ ../apiserver-etcd-client.crt         API-сервер ходит в etcd
 ├─ front-proxy-ca.crt / .key                CA передачи запросов расширениям
 │   └─ front-proxy-client.crt               клиент API-сервера для расширений
 └─ sa.key / sa.pub                          пара ключей токенов ServiceAccount (не сертификат)
```

Схема 4. Дерево каталога pki: три CA и сертификаты под ними. Смотрите, какой CA подписал какой файл: от этого зависит, кто кому доверяет.

Несколько файлов нуждаются в пояснении.

- **SAN** (subject alternative name, альтернативное имя субъекта) — список адресов и имён внутри сертификата. Клиент сверяет с ним адрес, по которому подключился. В `apiserver.crt` входят `kubernetes`, `kubernetes.default.svc`, ClusterIP Service `kubernetes` (первый адрес сети Service, 10.96.0.1), адрес узла и адрес из `controlPlaneEndpoint`.
- **Aggregation layer** (слой агрегации) — механизм, через который API-сервер передаёт запросы расширениям API, например metrics-server на стенде. API-сервер подключается к расширению с клиентским сертификатом `front-proxy-client` и передаёт имя пользователя в заголовках. Расширение проверяет этот сертификат по `front-proxy-ca`.
- **sa.key и sa.pub** — пара ключей без сертификата. controller-manager подписывает ею токены ServiceAccount (06-1), а API-сервер проверяет подпись публичным ключом. Поэтому у всех узлов control plane эта пара одинакова.

Клиентские сертификаты kubelet в каталоге pki не хранятся: они лежат на самом узле в `/var/lib/kubelet/pki` и выдаются через CSR (следующий раздел).

### Kubeconfig-файлы компонентов

Каждый компонент control plane подключается к API-серверу со своим клиентским сертификатом, который лежит в kubeconfig-файле в `/etc/kubernetes`. Имя пользователя берётся из `CN` сертификата, а группы из `O` (06-1).

- **admin.conf** — администратор, `CN=kubernetes-admin`, группа `kubeadm:cluster-admins`. Права ему даёт ClusterRoleBinding на `cluster-admin`.
- **super-admin.conf** — `CN=kubernetes-super-admin`, группа `system:masters`. Это аварийный ключ в обход RBAC: им чинят кластер, если права администратора сломаны. Его защищают так же строго, как ключ CA.
- **controller-manager.conf** и **scheduler.conf** — `system:kube-controller-manager` и `system:kube-scheduler`, права берутся из встроенных ролей.
- **kubelet.conf** — `system:node:<имя узла>` в группе `system:nodes`; права ограничивает авторизация Node (06-1).

Файлы `admin.conf` и `super-admin.conf` есть только на узлах control plane. На рабочих узлах лежит только `kubelet.conf`.

### TLS bootstrap kubelet

Новый узел не имеет сертификата, и выдать его может только кластер. Эту задачу решает **TLS bootstrap** — процедура, в которой kubelet по временному токену создаёт запрос на собственный сертификат и получает его без участия человека. Токен нужен только для первого шага.

**Bootstrap token** — короткоживущий секрет вида `abcdef.0123456789abcdef`: шесть символов идентификатора, точка и шестнадцать символов секрета. Он хранится как Secret типа `bootstrap.kubernetes.io/token` с именем `bootstrap-token-<id>` в namespace `kube-system`. По умолчанию токен живёт 24 часа, потом его удаляет контроллер очистки в controller-manager. Токен служит двум целям: подписывает ConfigMap для обнаружения (usage `signing`) и пускает в API-сервер как bootstrap-пользователя (usage `authentication`), у которого есть право только создавать CSR.

Процедура идёт в четыре шага (схема 5).

1. **Обнаружение (discovery).** `kubeadm join` скачивает без аутентификации ConfigMap `cluster-info` из namespace `kube-public`. В нём лежит CA кластера и адрес API-сервера, а подпись ConfigMap сделана токеном. Узел проверяет подпись токеном, а CA сверяет с хешем из команды (`--discovery-token-ca-cert-hash`). Хеш защищает от подмены API-сервера.
2. **Запрос.** kubelet подключается к API-серверу с токеном как пользователь группы `system:bootstrappers:kubeadm:default-node-token`. Права у группы узкие: создавать CSR и читать то немногое, что нужно `kubeadm join`, например узлы (привязка `kubeadm:get-nodes`). kubelet генерирует закрытый ключ и отправляет CSR с **signer** `kubernetes.io/kube-apiserver-client-kubelet` (signer — тип запроса, который определяет, кто его подпишет и как одобрят).
3. **Одобрение.** Контроллер одобрения CSR в controller-manager видит запрос и одобряет автоматически: kubeadm заранее создал ClusterRoleBinding `kubeadm:node-autoapprove-bootstrap`, который разрешает это группе токена.
4. **Подпись и запись.** Контроллер подписи подписывает CSR ключом кластерного CA. kubelet забирает сертификат (`CN=system:node:<имя>`, `O=system:nodes`), кладёт его в `/var/lib/kubelet/pki`, пишет `kubelet.conf` и дальше работает уже без токена.

```
узел (kubelet)                                      кластер
   │ 1. GET cluster-info (без входа) ───────────────► kube-public/cluster-info (CA, подпись)
   │ 2. CSR с токеном (группа bootstrappers) ───────► CertificateSigningRequest
   │                                                    │ 3. kubeadm:node-autoapprove-bootstrap
   │                                                    │    csrapproving: Approved
   │                                                    │ 4. csrsigning: подпись CA кластера
   │ ◄────────── сертификат system:node:<имя> ─────────┘
   │ запись в /var/lib/kubelet/pki, kubelet.conf
```

Схема 5. TLS bootstrap: токен нужен только на шагах 1–2, а дальше узел действует по собственному сертификату. Смотрите, кто выполняет каждый шаг: контроллеры в controller-manager, а не kubeadm.

Права и привязки создаёт фаза bootstrap-token; увидеть их можно командой `kubectl get clusterrolebinding | grep kubeadm` (§4).

---

## 3. Как управлять сборкой и узлами

Управление сводится к трём действиям: добавить узел, подготовить кластер к отказам и настроить обновление сертификатов kubelet. Для каждого есть команда kubeadm и пара флагов.

### Присоединение рабочего узла

Рабочий узел присоединяет команда `kubeadm join`. Ей нужны три значения: адрес API-сервера, токен и хеш CA.

```bash
kubeadm join k8s-api.example.com:6443 --token abcdef.0123456789abcdef \
  --discovery-token-ca-cert-hash sha256:<хеш CA>
```

Токен живёт 24 часа, поэтому для нового узла команду собирают заново: `kubeadm token create --print-join-command` создаёт токен и печатает готовую строку вместе с хешем. Список токенов показывает `kubeadm token list`, удаляет лишний `kubeadm token delete`. Токен со сроком 0 никогда не истекает и поэтому опасен: по нему любой, кто его увидел, может добавить в кластер свой узел.

Флаг `--discovery-token-unsafe-skip-ca-verification` отключает проверку хеша. Это допустимо только в среде, где подмена API-сервера невозможна; именно так делает kind внутри собственной сети Docker.

### Топологии HA control plane

**HA** (high availability, высокая доступность) control plane — три или пять узлов с API-сервером: три узла переживают потерю одного, пять — потерю двух. API-сервер не хранит состояние, поэтому все его копии работают одновременно за балансировщиком. Scheduler и controller-manager работают по одному активному (01-1). Сложность только в etcd: он работает как несколько **членов** (member) — процессов, у каждого из которых своя полная копия данных (10-2 §2). У kubeadm для etcd две топологии.

- **Стековый etcd** (stacked etcd) — на каждом узле control plane работает свой член etcd рядом с API-сервером. Это топология по умолчанию: она проще и требует меньше машин. Узел выходит из строя целиком, и кластер теряет и API-сервер, и член etcd.
- **Внешний etcd** (external etcd) — etcd работает на отдельных машинах, а API-сервер подключается к нему по адресам из поля `etcd.external` с тремя файлами: CA, сертификат и ключ клиента. Отказы API-сервера и etcd становятся независимыми, но нужно вдвое больше машин и отдельная работа с etcd (10-2).

```
          клиенты (kubectl, kubelet, controller-manager)
                          │ https://k8s-api.example.com:6443
                          ▼
                  балансировщик  ── проверка /readyz на каждом backend
              ┌───────────┼───────────┐
              ▼           ▼           ▼
        control-plane1 control-plane2 control-plane3
        apiserver      apiserver      apiserver
        etcd ◄───────► etcd ◄───────► etcd         стековая топология: члены связаны портом 2380
```

Схема 6. HA control plane со стековым etcd: клиенты видят один адрес, а балансировщик исключает упавший узел по проверке здоровья.

**Балансировщик** (load balancer) принимает соединения на одном адресе и раздаёт их узлам control plane. Для kubeadm достаточно TCP-пересылки на порт 6443 и проверки здоровья каждого backend. Подходят облачный балансировщик, HAProxy с keepalived или kube-vip на самих узлах. Адрес балансировщика задают в `controlPlaneEndpoint`, и менять его после сборки трудно: он записан в сертификаты и kubeconfig всех узлов. Поэтому адрес выбирают до `kubeadm init` и делают его DNS-именем, а не IP одного узла.

### Присоединение узла control plane

Узел control plane присоединяет та же команда `kubeadm join` с флагом `--control-plane`. Ему нужны ключи CA, и kubeadm передаёт их через кластер. Для этого служит **upload-certs** — фаза и флаг `--upload-certs` у `kubeadm init`. kubeadm шифрует ключи CA и пару `sa.key`, кладёт их в Secret `kubeadm-certs` и печатает **certificate key** — 32-байтный ключ шифрования. 

Новый узел скачивает Secret, расшифровывает его и выпускает собственные сертификаты API-сервера и etcd со своим адресом в SAN. Secret удаляется через 2 часа.

```bash
kubeadm init --config kubeadm.yaml --upload-certs
kubeadm join k8s-api.example.com:6443 --token <токен> --control-plane \
  --discovery-token-ca-cert-hash sha256:<хеш> --certificate-key <ключ>
```

Если два часа прошли, ключ выпускают заново командой `kubeadm init phase upload-certs --upload-certs`. При присоединении kubeadm добавляет нового члена etcd сначала в режиме learner: член без права голоса сперва догоняет данные, и кворум не страдает. Узлы control plane присоединяют по одному, потому что добавлять сразу нескольких членов etcd небезопасно.

kind не использует upload-certs. Он копирует нужные файлы из каталога `pki` первого узла на остальные командой копирования между контейнерами и затем запускает на них `kubeadm join` (§4).

### Ротация сертификатов kubelet

Клиентский сертификат, полученный при TLS bootstrap, kubelet дальше обновляет сам. kubeadm включает это заранее: ставит `rotateCertificates: true` в `KubeletConfiguration` и создаёт ClusterRoleBinding `kubeadm:node-autoapprove-certificate-rotation` для группы `system:nodes`. Как идёт сама ротация и как за ней следить, разобрано в 10-4.

Серверный сертификат kubelet по умолчанию самоподписан, и API-сервер его не проверяет. Флаг `serverTLSBootstrap: true` переводит его на CSR с signer `kubernetes.io/kubelet-serving`. Такие CSR автоматически не одобряются, поэтому без одобряющего контроллера флаг не включают (10-4).

### Карточка инструмента: kubeadm

**Назначение:** kubeadm собирает кластер из подготовленных узлов и обслуживает его жизненный цикл: `init`, `join`, токены, сертификаты, `upgrade` (10-3) и `reset`. В курсе он нужен, чтобы читать то, что создал kind, и разобраться с сертификатами и обновлением.

**Как работает:** kubeadm читает конфигурацию, по фазам пишет файлы на диск и создаёт объекты в кластере через API-сервер.

```
kubeadm init|join  ──► читает --config / значения по умолчанию
        │
        ├─► пишет файлы: /etc/kubernetes/{pki,manifests,*.conf}, /var/lib/kubelet
        └─► ходит в API: ConfigMap, Secret, RBAC, дополнения
```

Схема 7. kubeadm делает два вида изменений: файлы на самом узле и объекты в кластере. Смотрите, что относится к узлу, а что — ко всему кластеру: от этого зависит, на скольких узлах нужно повторять команду.

**Откуда берёт данные:** на `init` из файла `--config`, флагов и значений по умолчанию, на `join` из токена и `cluster-info`. Для работающего кластера он читает ConfigMap `kubeadm-config` и `kubelet-config` в `kube-system` и файлы в `/etc/kubernetes`.

**Основные команды:**

```bash
kubeadm init --config kubeadm.yaml --upload-certs    # создать первый узел control plane
kubeadm join <адрес>:6443 --token <токен> \
  --discovery-token-ca-cert-hash sha256:<хеш>        # добавить рабочий узел
kubeadm join <адрес>:6443 --control-plane \
  --certificate-key <ключ> --token <токен> \
  --discovery-token-ca-cert-hash sha256:<хеш>        # добавить узел control plane
kubeadm token create --print-join-command            # новый токен и готовая команда join
kubeadm init phase upload-certs --upload-certs       # заново загрузить ключи CA (ключ живёт 2 часа)
kubeadm certs check-expiration                       # сроки всех сертификатов
kubeadm config print init-defaults                   # значения по умолчанию в формате v1beta4
kubeadm config migrate --old-config old.yaml \
  --new-config new.yaml                              # перевести файл из v1beta3 в v1beta4
kubeadm config images list                           # образы, которые нужны этой версии
kubeadm reset                                        # убрать с узла всё, что создал kubeadm
```

**Команды для скриптов:** `kubeadm token create --print-join-command` печатает одну строку, которую можно передать по SSH. Команда `kubeadm init --dry-run` показывает, что будет сделано, и ничего не меняет в `/etc/kubernetes`. Флаг `--ignore-preflight-errors=<имя>` пропускает проверку, но постоянно им пользоваться нельзя. Ненулевой код возврата означает, что фаза не завершилась.

**Частые ошибки:**

- `[ERROR FileAvailable--etc-kubernetes-manifests-kube-apiserver.yaml]`: узел уже использовался, его сначала очищают `kubeadm reset`.
- `could not find a JWS signature in the cluster-info ConfigMap for token ID`: токен истёк или опечатка в нём.
- `cluster CA found in cluster-info ConfigMap is invalid`: хеш CA в команде не совпадает с CA кластера.
- `[control-plane-check] kube-apiserver is not healthy after 4m0s`: kubelet не запустил static pods; смотрят `journalctl -u kubelet` и `crictl ps -a` (01-2).
- `[ERROR FileContent--proc-sys-net-ipv4-ip_forward]`: в ядре выключена пересылка пакетов.

**Установка:** на стенде kubeadm уже есть в образе узла, на хосте он не нужен. В Ubuntu пакеты `kubelet`, `kubeadm` и `kubectl` ставят из репозитория `pkgs.k8s.io` ветки 1.36 и фиксируют командой `apt-mark hold`, чтобы обычное обновление не сменило минорную версию. В Manjaro пакет ищут командой `pacman -Ss kubeadm`; если его нет, берут бинарный файл нужной версии с `dl.k8s.io`.

---

## 4. Как увидеть состояние сборки

Состояние сборки видно в трёх местах: в кластере (ConfigMap и привязки), на узле (файлы и сертификаты) и у балансировщика. Каждое место читается своей командой.

### Настройки, которые kubeadm положил в кластер

Фаза upload-config сохраняет конфигурацию в ConfigMap, поэтому любой узел может узнать, как собран кластер.

- **kubeadm-config** в `kube-system` — ClusterConfiguration без токенов; из него берут версию, подсети и `controlPlaneEndpoint`.
- **kubelet-config** в `kube-system` — KubeletConfiguration, общая для узлов; её читает `kubeadm upgrade` (10-3).
- **cluster-info** в `kube-public` — CA и адрес API-сервера для обнаружения, читается без входа.
- **Привязки ролей** с именами `kubeadm:…` — права токена и автоодобрения: `kubectl get clusterrolebinding | grep kubeadm`.

Пример разобран в лабораторной работе 1, шаг 5.

### Сертификаты и kubeconfig

Сроки сертификатов показывает `kubeadm certs check-expiration`: таблица из одиннадцати строк с остатком срока и именем CA, который подписал сертификат. Содержимое одного сертификата читает `openssl x509 -in файл -noout -subject -issuer -dates -ext subjectAltName`. Строка `subject` показывает имя и группы, `issuer` — подписавший CA, `dates` — срок, `subjectAltName` — адреса, на которые выписан сертификат. Для сертификатов в kubeconfig их сначала декодируют: поле `client-certificate-data` хранится в base64.

На рабочем узле сертификаты kubelet лежат в `/var/lib/kubelet/pki`. Имя `kubelet-client-<дата>.pem` — выданный файл, а `kubelet-client-current.pem` — ссылка на актуальный. Работа 2 проходит по всем файлам.

### Члены etcd и балансировщик

В стековом кластере членов etcd показывает `etcdctl member list`, а лидера и состояние каждого — `etcdctl endpoint status --cluster`. Команды запускают внутри пода etcd (карточка etcdctl — в 01-1). Кто сейчас активен в controller-manager и scheduler, видно по объектам Lease в `kube-system` (01-1 §2). Работа 3 использует обе команды.

Состояние балансировщика зависит от его реализации. В kind это контейнер `<кластер>-external-load-balancer`: его конфигурация и список backend лежат в файлах внутри контейнера, а журнал проверок здоровья идёт в `docker logs`.

### Как kind вызывает kubeadm

Чтобы понять кластер kind, достаточно знать четыре факта.

1. kind пишет конфигурацию kubeadm в файл `/kind/kubeadm.conf` на каждом узле. Для Kubernetes 1.36 и новее формат v1beta4; патчи `kubeadmConfigPatches` из конфигурации kind накладываются на него.
2. На первом узле control plane kind запускает `kubeadm init --config=/kind/kubeadm.conf --skip-token-print --v=6`. Фаза preflight пропущена (`skipPhases`): kind заранее кладёт образы в узел, и проверки preflight могут с этим конфликтовать.
3. Для HA kind копирует с первого узла на остальные `admin.conf` и файлы CA из `/etc/kubernetes/pki` (кластерный CA, CA etcd, front-proxy-ca и пару sa), а затем по очереди запускает на них `kubeadm join --config /kind/kubeadm.conf --v=6`. Рабочие узлы присоединяются после узлов control plane и одновременно.
4. Если control plane больше одного, kind создаёт контейнер балансировщика `<кластер>-external-load-balancer` и пишет его адрес в `controlPlaneEndpoint`. До kind 0.32 это был HAProxy, начиная с 0.32 — Envoy. Он слушает порт 6443, находит узлы control plane по именам контейнеров и каждые 2 секунды проверяет `/healthz` каждого API-сервера.

На стенде `lab` один узел control plane, поэтому балансировщика там нет, а `controlPlaneEndpoint` указывает на сам узел. Лабораторная работа 1 читает эти файлы, работа 3 создаёт кластер с балансировщиком.

---

## 5. Что ломается и как найти причину

Сборка и вход узлов ломаются предсказуемо. Причина почти всегда видна в одном из трёх мест: в выводе фазы, в журнале kubelet или в состоянии CSR. Ниже симптомы сгруппированы по тому, где их искать.

### Узел не присоединяется

Симптом виден в выводе `kubeadm join` на фазе обнаружения или TLS bootstrap.

- **Токен недействителен.** Сообщение про отсутствующую JWS-подпись в `cluster-info` значит, что токен просрочен (24 часа) или введён с ошибкой. Проверяют `kubeadm token list` на control plane и создают новый.
- **Хеш CA не совпадает.** Сообщение «cluster CA found in cluster-info ConfigMap is invalid» значит, что хеш из команды не от этого кластера. Нужно взять свежую команду `kubeadm token create --print-join-command`.
- **Нет связи.** Тайм-аут на обнаружении означает, что адрес из `controlPlaneEndpoint` недоступен с нового узла: DNS, firewall или порт 6443. Проверка — `curl -k https://<адрес>:6443/healthz`.
- **Узел ждёт одобрения.** Если `kubeadm join` зависает до пяти минут (тайм-аут `tlsBootstrap`), смотрят `kubectl get csr`: запрос в состоянии Pending значит, что автоодобрение сломано (удалён ClusterRoleBinding `kubeadm:node-autoapprove-bootstrap`) или контроллер одобрения не работает.
- **Неверное время.** Если часы узла расходятся с кластером, сертификат кажется ещё не действующим или уже просроченным. Ошибка `x509: certificate has expired or is not yet valid` при свежих сертификатах указывает на синхронизацию времени.

### Сертификаты не подходят адресу

Сертификат выписан на конкретные адреса, и смена адреса ломает доверие. Если узел control plane получил новый IP (перенос ВМ, DHCP, перезапуск Docker), клиенты, которые ходят по IP, получают `x509: certificate is valid for …, not …`. Проверяют SAN командой `openssl x509 -ext subjectAltName`, а чинят перевыпуском через `kubeadm init phase certs` с новым адресом (10-3 §5, 10-4 §5). Профилактика одна: `controlPlaneEndpoint` задают DNS-именем и закладывают нужные имена в `apiServer.certSANs`.

Вторая причина — срок. Через год после сборки сертификаты компонентов истекают, а CA живут десять лет. Диагностика и продление разобраны в 10-4.

### HA: потеря кворума и балансировщика

В кластере из трёх узлов отказ одного членов etcd не заметен: кворум (2 из 3) сохраняется. Отказ второго останавливает запись: API-сервер отвечает ошибками таймаута, `kubectl get` зависает, `/readyz` не проходит проверку etcd. Поды продолжают работать, но контроллеры не могут менять состояние. Восстановление — вернуть хотя бы один из выпавших узлов, а если данные потеряны — снапшот etcd (10-2).

Балансировщик ломается иначе. Пока он жив, но проверка здоровья настроена неверно, он может направлять запросы на узел, где API-сервер ещё не готов. Если балансировщик погиб, не отвечает кластер целиком, хотя все API-серверы здоровы: kubectl с тем же `server` в kubeconfig получает `connection refused`. Проверка проста: запрос напрямую к одному API-серверу (`curl -k https://<IP узла>:6443/readyz`) отделяет проблему балансировщика от проблемы control plane.

### kubelet и CSR

Если узел остаётся NotReady, а kubelet пишет в журнале про сертификат, смотрят три вещи. Первое — срок файла `kubelet-client-current.pem` (`openssl x509 -noout -dates`). Второе — `kubectl get csr`: накопленные Pending запросы с signer `kubernetes.io/kube-apiserver-client-kubelet` говорят, что автоодобрение не работает. Третье — часы узла: ротация и проверка сроков опираются на время.

Запросы `kubelet-serving` в Pending при включённом `serverTLSBootstrap` — ожидаемое состояние, а не поломка: их одобряет администратор.

---

## 6. Пределы и значения по умолчанию

Числа ниже взяты из документации kubeadm и исходного кода версии 1.36; если значение можно изменить, рядом названо поле.

### Сроки и таймауты

Таблица показывает, сколько живёт каждый объект и что с ним происходит по истечении срока.

| Объект | Срок по умолчанию | Что по истечении |
|---|---|---|
| bootstrap token | 24 часа | удаляет контроллер очистки |
| certificate key (Secret kubeadm-certs) | 2 часа | Secret удаляется |
| сертификаты компонентов, kubeconfig | 1 год (8760 ч) | компонент не подключится, продлевает kubeadm (10-4) |
| CA (ca, etcd/ca, front-proxy-ca) | 10 лет (87600 ч) | замена вручную |
| клиентский сертификат kubelet | 1 год (флаг controller-manager) | kubelet обновляет сам (10-4) |

Тайм-ауты `timeouts` в v1beta4 ограничивают ожидание фаз kubeadm.

| Поле | По умолчанию | Что ждёт |
|---|---|---|
| controlPlaneComponentHealthCheck | 4 минуты | ответа static pods control plane |
| kubeletHealthCheck | 4 минуты | ответа kubelet |
| kubernetesAPICall | 1 минута | ответа API-сервера на запрос kubeadm |
| etcdAPICall | 2 минуты | ответа etcd |
| tlsBootstrap | 5 минут | выдачи клиентского сертификата kubelet |
| discovery | 5 минут | чтения cluster-info при join |
| upgradeManifests | 5 минут | замены манифестов при обновлении |

### Размер и порты

kubeadm требует от узла минимум 2 ядер CPU и 1700 МБ памяти; на меньшем узле фаза preflight остановит сборку. Control plane собирают из одного узла (учебный вариант), трёх или пяти. Чётное число не добавляет надёжности (01-1). Для каждого узла нужны открытые порты.

| Порт | Компонент | Кто подключается |
|---|---|---|
| 6443 | API-сервер | все клиенты и узлы |
| 2379–2380 | etcd | API-сервер; члены etcd между собой |
| 10250 | kubelet | API-сервер и control plane |
| 10257 | controller-manager | локальные проверки |
| 10259 | scheduler | локальные проверки |

### Версии

kubeadm 1.36 создаёт кластер версии не новее своей. Образы по умолчанию: etcd 3.6.8-0, CoreDNS v1.14.2, pause 3.10.2. В kubeadm 1.37 etcd обновляется до 3.7.0-0, а CoreDNS до v1.14.6. kubelet может отставать от API-сервера до трёх минорных версий (10-3 §2). С версии 1.35 фаза preflight считает ошибкой узел с cgroup v1, поэтому узлы 1.36 работают на cgroup v2 (01-2).

---

## Лабораторные работы

Работы 1 и 2 идут на стенде 00-1 и только читают: файлы на узлах, объекты в `kube-system` и `kube-public`, сертификаты. Работа 3 создаёт отдельный кластер kind `lab-10-1` из трёх узлов control plane и одного рабочего. Остановка узла control plane и потеря кворума не должны задевать стенд. Namespace `lab-10-1` существует только в этом новом кластере.

Подготовка задаёт две функции и каталог. Функция `ks` обращается к стенду по имени контекста и не меняет текущий контекст в `~/.kube/config`. Функция `kh` обращается к кластеру `lab-10-1` по отдельному kubeconfig и подставляет его namespace; для объектов `kube-system` в ней задают `-n kube-system`. Обе функции снимает уборка работы 3.

```bash
mkdir -p ~/lab/k8s/10-1
ks() { kubectl --context kind-lab "$@"; }
kh() { kubectl --kubeconfig ~/lab/k8s/10-1/kubeconfig -n lab-10-1 "$@"; }
```

Первая команда создаёт каталог файлов части. Вторая и третья задают функции, которые существуют только в текущем шелле и не меняют `~/.kube/config`.

### Лабораторная работа 1. Как kind вызывает kubeadm

Эту работу вы выполняете сами, результаты в ней — ожидаемые.

**Цель.** Найти на узле стенда файл, из которого kind запустил `kubeadm init`, и сравнить его со значениями по умолчанию. Затем увидеть в кластере и на узле следы каждой фазы.

**Что понадобится.**

- Стенд из 00-1: кластер kind `lab`, контекст `kind-lab`, узел `lab-control-plane`.
- Функции `ks` и `kh` из подготовки.
- Около 30 минут.

**Схема опыта.** Все шаги только читают. Сначала смотрим входные данные kubeadm, затем его фазы, затем результат на узле и в кластере.

```
конфигурация kind ──► /kind/kubeadm.conf (узел) ──► kubeadm init, фазы ──► результат
      шаги 1–3 (вход)            шаг 4 (фазы)             шаг 5: файлы узла и объекты кластера
                                                           шаг 6: перевод v1beta3 → v1beta4
```

Схема 8. Работа идёт слева направо: вход kubeadm, список фаз, их следы. Смотрите на файл `/kind/kubeadm.conf`: из него kind запустил сборку.

#### Шаг 1. Найти файл конфигурации и его документы

Проверим, что kubeadm лежит внутри узла и что kind оставил на нём файл конфигурации. Затем выведем типы документов в этом файле.

```bash
docker exec lab-control-plane kubeadm version -o short
docker exec lab-control-plane grep -E '^(apiVersion|kind):' /kind/kubeadm.conf
```

Разбор команды:

| Часть команды | Значение |
|---|---|
| `docker exec lab-control-plane` | выполнить команду внутри контейнера узла |
| `kubeadm version -o short` | печатать только номер версии |
| `grep -E '^(apiVersion\|kind):'` | оставить строки `apiVersion` и `kind` с начала строки |
| `/kind/kubeadm.conf` | файл, который kind пишет на узел при создании кластера |

Ожидаемый результат:

```
v1.36.1
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
apiVersion: kubeadm.k8s.io/v1beta4
kind: JoinConfiguration
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
apiVersion: kubeproxy.config.k8s.io/v1alpha1
kind: KubeProxyConfiguration
```

Разбор вывода:

1. Версия kubeadm совпадает с версией образа узла, `v1.36.1`.
2. Файл содержит пять документов. Первые три принадлежат kubeadm и имеют формат `v1beta4`, как и должно быть для Kubernetes 1.36 и новее.
3. KubeletConfiguration и KubeProxyConfiguration kubeadm не читает как свои: он кладёт их в ConfigMap и раздаёт узлам (схема 3).
4. В файле есть и InitConfiguration, и JoinConfiguration: kind пишет на каждый узел файл из одного шаблона, а kubeadm берёт нужные ему документы.

#### Шаг 2. Прочитать ключевые поля

Выведем из файла поля, которые определяют адрес кластера, подсети, список адресов в сертификате API-сервера и способ присоединения узлов.

```bash
docker exec lab-control-plane grep -E \
  -e '^(kubernetesVersion|clusterName|controlPlaneEndpoint):' \
  -e podSubnet -e serviceSubnet -e criSocket -e unsafeSkip \
  /kind/kubeadm.conf
docker exec lab-control-plane grep -A4 certSANs /kind/kubeadm.conf
```

Разбор команды:

| Часть команды | Значение |
|---|---|
| `-E -e '…'` | расширенное регулярное выражение; каждый `-e` добавляет шаблон |
| `controlPlaneEndpoint` | адрес, по которому клиенты ходят в кластер |
| `podSubnet`, `serviceSubnet` | подсети подов и Service |
| `criSocket` | сокет containerd на узле |
| `unsafeSkip` | поле `unsafeSkipCAVerification` обнаружения при join |
| `-A4 certSANs` | поле и четыре строки после него |

Ожидаемый результат:

```
clusterName: lab
controlPlaneEndpoint: lab-control-plane:6443
kubernetesVersion: v1.36.1
  podSubnet: 10.244.0.0/16
  serviceSubnet: 10.96.0.0/16
  criSocket: unix:///run/containerd/containerd.sock
    unsafeSkipCAVerification: true
  criSocket: unix:///run/containerd/containerd.sock
  certSANs:
  - localhost
  - 127.0.0.1
  extraArgs:
  …
```

Разбор вывода:

1. Ключи идут по алфавиту, а кавычек и комментариев нет: kind пропускает шаблон через свой механизм патчей, и тот заново сериализует YAML. `criSocket` встречается дважды: в InitConfiguration и в JoinConfiguration.
2. `controlPlaneEndpoint` указывает на имя узла и порт 6443: на стенде один узел control plane, поэтому балансировщика нет, а внутри сети Docker имя узла разрешается само.
3. Подсети подов и Service — значения kind по умолчанию; в `kubeadm-config` они потом сохранятся (шаг 5).
4. Поле `unsafeSkipCAVerification: true` отключает проверку хеша CA при `join`. Для сети Docker это безопасно, для рабочего кластера нет (§3).
5. В `certSANs` перечислены `localhost` и `127.0.0.1`. Через них сертификат API-сервера подходит адресу `127.0.0.1:<порт>`, под которым kubectl с хоста ходит в кластер kind.

#### Шаг 3. Сравнить с значениями kubeadm по умолчанию

Команда `kubeadm config print init-defaults` печатает конфигурацию по умолчанию и ничего не меняет. Отфильтруем из неё сроки, тип ключей и тайм-ауты: это настройки, которые kind не переопределяет.

```bash
docker exec lab-control-plane kubeadm config print init-defaults | \
  grep -E 'ttl|ComponentHealth|tlsBootstrap|ValidityPeriod|encryptionAlg|certificatesDir'
```

Разбор команды:

| Часть команды | Значение |
|---|---|
| `config print init-defaults` | напечатать значения по умолчанию для `init` в формате v1beta4 |
| `\|` | передать вывод фильтру |
| `grep -E 'ttl\|…'` | оставить строки со сроками, тайм-аутами и типом ключей |

Ожидаемый результат:

```
  ttl: 24h0m0s
  controlPlaneComponentHealthCheck: 4m0s
  tlsBootstrap: 5m0s
caCertificateValidityPeriod: 87600h0m0s
certificateValidityPeriod: 8760h0m0s
certificatesDir: /etc/kubernetes/pki
encryptionAlgorithm: RSA-2048
```

Разбор вывода:

1. Токен живёт 24 часа (`ttl`), и это значение определяет окно для `kubeadm join` (§2).
2. Тайм-ауты `controlPlaneComponentHealthCheck` (4 минуты) и `tlsBootstrap` (5 минут) ограничивают ожидание фаз.
3. Сертификаты компонентов живут 8760 часов, то есть год, CA — 87600 часов, десять лет. kind эти значения не меняет, поэтому на стенде они такие же.
4. Тип ключей RSA-2048 и каталог `/etc/kubernetes/pki` — стандартные.

#### Шаг 4. Получить список фаз

Справка команды `kubeadm init` содержит список фаз в порядке запуска. Оставим только имена верхнего уровня, без подфаз.

```bash
docker exec lab-control-plane sh -c \
  "kubeadm init --help | sed -n '/following phases/,/^Usage/p' | awk '/^[a-z]/ {print \$1}'"
```

Разбор команды:

| Часть команды | Значение |
|---|---|
| `sh -c "…"` | выполнить конвейер целиком внутри узла |
| `kubeadm init --help` | справка, в которой перечислены фазы |
| `sed -n '/…/,/^Usage/p'` | вывести блок от строки про фазы до раздела `Usage` |
| `awk '/^[a-z]/ {print $1}'` | взять первое слово строк, начинающихся со строчной буквы |

Ожидаемый результат:

```
preflight
certs
kubeconfig
etcd
control-plane
kubelet-start
wait-control-plane
upload-config
upload-certs
mark-control-plane
bootstrap-token
kubelet-finalize
addon
show-join-command
```

Разбор вывода:

1. Список из четырнадцати имён совпадает с таблицей §2 и с исходным кодом kubeadm.
2. Подфазы (`certs/ca`, `control-plane/apiserver` и другие) в справке стоят с отступом, поэтому фильтр их отбросил. Любую фазу запускают отдельно: `kubeadm init phase certs ca`.
3. Фаза `upload-certs` в списке есть, но работает только с флагом `--upload-certs`.

#### Шаг 5. Найти следы фаз на узле и в кластере

Фазы оставили файлы на узле и объекты в кластере. Проверим по три-четыре следа: файлы в `/etc/kubernetes`, ConfigMap, привязки ролей, дополнения и taint узла.

```bash
docker exec lab-control-plane ls /etc/kubernetes /etc/kubernetes/manifests
ks -n kube-system get cm -o name | grep -E 'kubeadm|kubelet|kube-proxy'
ks -n kube-public get cm -o name
ks get clusterrolebinding -o name | grep kubeadm
ks -n kube-system get deploy,ds -o name
ks get node lab-control-plane -o jsonpath='{.spec.taints}{"\n"}'
```

Разбор команды:

| Часть команды | Значение |
|---|---|
| `ls /etc/kubernetes /etc/kubernetes/manifests` | файлы фаз kubeconfig, certs, etcd и control-plane |
| `get cm -o name` | имена ConfigMap без таблицы |
| `grep -E 'kubeadm\|kubelet\|kube-proxy'` | оставить ConfigMap фазы upload-config и addon |
| `-n kube-public get cm` | ConfigMap `cluster-info` фазы bootstrap-token |
| `get clusterrolebinding … \| grep kubeadm` | привязки ролей фаз kubeconfig, bootstrap-token и addon |
| `get deploy,ds -o name` | дополнения фазы addon |
| `jsonpath='{.spec.taints}'` | taint, который поставила фаза mark-control-plane |

Ожидаемый результат:

```
/etc/kubernetes:
admin.conf
controller-manager.conf
kubelet.conf
manifests
pki
scheduler.conf
super-admin.conf

/etc/kubernetes/manifests:
etcd.yaml
kube-apiserver.yaml
kube-controller-manager.yaml
kube-scheduler.yaml
configmap/kube-proxy
configmap/kubeadm-config
configmap/kubelet-config
configmap/cluster-info
configmap/kube-root-ca.crt
configmap/local-registry-hosting
clusterrolebinding.rbac.authorization.k8s.io/kubeadm:apiserver-kubelet-client
clusterrolebinding.rbac.authorization.k8s.io/kubeadm:cluster-admins
clusterrolebinding.rbac.authorization.k8s.io/kubeadm:get-nodes
clusterrolebinding.rbac.authorization.k8s.io/kubeadm:kubelet-bootstrap
clusterrolebinding.rbac.authorization.k8s.io/kubeadm:node-autoapprove-bootstrap
clusterrolebinding.rbac.authorization.k8s.io/kubeadm:node-autoapprove-certificate-rotation
clusterrolebinding.rbac.authorization.k8s.io/kubeadm:node-proxier
deployment.apps/coredns
daemonset.apps/kindnet
daemonset.apps/kube-proxy
[{"effect":"NoSchedule","key":"node-role.kubernetes.io/control-plane"}]
```

Разбор вывода:

1. В `/etc/kubernetes` лежат пять kubeconfig-файлов, каталог `pki` (фаза certs) и каталог `manifests` с четырьмя static pods (фазы etcd и control-plane).
2. ConfigMap `kubeadm-config` и `kubelet-config` — результат upload-config, а `kube-proxy` — результат addon.
3. ConfigMap `cluster-info` в `kube-public` создала фаза bootstrap-token. `kube-root-ca.crt` создаёт controller-manager, а `local-registry-hosting` — скрипт стенда (00-1).
4. Привязки `kubeadm:kubelet-bootstrap`, `kubeadm:node-autoapprove-bootstrap` и `kubeadm:node-autoapprove-certificate-rotation` — те самые права TLS bootstrap и ротации (схема 5). Привязка `kubeadm:cluster-admins` даёт права `admin.conf`, `kubeadm:apiserver-kubelet-client` пускает API-сервер в kubelet (logs, exec), `kubeadm:get-nodes` нужна `kubeadm join`, а `kubeadm:node-proxier` создала фаза addon для kube-proxy.
5. CoreDNS и kube-proxy — результат addon. DaemonSet `kindnet` kubeadm не создаёт: это CNI-плагин, который ставит kind после `init`.
6. Taint `node-role.kubernetes.io/control-plane` с эффектом `NoSchedule` поставила фаза mark-control-plane. В кластере с рабочими узлами он остаётся.

#### Шаг 6. Перевести конфигурацию из v1beta3 в v1beta4

Команда `kubeadm config migrate` читает файл старой версии и печатает его в новой. Передадим старый файл через стандартный ввод, поэтому на узле ничего не создаётся.

```bash
docker exec -i lab-control-plane kubeadm config migrate --old-config /dev/stdin <<'EOF'
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
kubernetesVersion: v1.36.1
apiServer:
  extraArgs:
    audit-log-maxage: "7"
  timeoutForControlPlane: 6m0s
EOF
```

Разбор команды:

| Часть команды | Значение |
|---|---|
| `docker exec -i` | передать стандартный ввод внутрь узла |
| `config migrate` | перевести файл конфигурации в текущую версию |
| `--old-config /dev/stdin` | прочитать старый файл со стандартного ввода |
| `extraArgs: {audit-log-maxage: "7"}` | в v1beta3 флаги заданы словарём |
| `timeoutForControlPlane` | в v1beta3 тайм-аут задан в ClusterConfiguration |

Ожидаемый результат, сокращённо:

```
apiVersion: kubeadm.k8s.io/v1beta4
…
kind: InitConfiguration
…
timeouts:
  controlPlaneComponentHealthCheck: 6m0s
…
---
apiServer:
  extraArgs:
  - name: audit-log-maxage
    value: "7"
apiVersion: kubeadm.k8s.io/v1beta4
…
kind: ClusterConfiguration
kubernetesVersion: v1.36.1
…
```

Разбор вывода:

1. Оба документа получили `apiVersion: kubeadm.k8s.io/v1beta4`. Первым kubeadm добавил InitConfiguration со значениями по умолчанию, хотя на входе её не было.
2. Словарь `extraArgs` превратился в список пар `name` и `value`. Так формат допускает повторяющиеся флаги.
3. Поле `timeoutForControlPlane` исчезло из ClusterConfiguration, а его значение перешло в `timeouts.controlPlaneComponentHealthCheck` документа InitConfiguration (§2).
4. Остальные поля, которых нет в исходном файле, приняли значения по умолчанию.

**Итог.** Что вы узнали:

| Что узнали | Где видно |
|---|---|
| kind пишет конфигурацию kubeadm v1beta4 в файл на узле | `/kind/kubeadm.conf`, шаги 1–2 |
| значения по умолчанию: токен 24 ч, сертификаты 1 год, CA 10 лет | `kubeadm config print init-defaults`, шаг 3 |
| у `init` четырнадцать фаз в фиксированном порядке | `kubeadm init --help`, шаг 4 |
| каждая фаза оставляет файл на узле или объект в кластере | `ls`, ConfigMap, привязки, шаг 5 |
| v1beta3 переводится командой `config migrate` | шаг 6 |

**Уборка.** Работа ничего не создавала ни на узлах, ни в кластере. Если вы останавливаетесь здесь, снимите функции командой `unset -f ks kh`; иначе они понадобятся в работах 2 и 3.

**Вопросы для самопроверки.**

1. Какой файл на узле kind доказывает, что кластер собрал kubeadm?

<details><summary>Ответ</summary>

Файл `/kind/kubeadm.conf`. В нём пять документов: три документа kubeadm формата `v1beta4` (ClusterConfiguration, InitConfiguration, JoinConfiguration) и две конфигурации компонентов (kubelet и kube-proxy).

</details>

2. Почему в кластере нет ConfigMap с InitConfiguration?

<details><summary>Ответ</summary>

InitConfiguration содержит токены и параметры только первого запуска. kubeadm кладёт в `kubeadm-config` один ClusterConfiguration.

</details>

3. Какая фаза создаёт ConfigMap `cluster-info` и какие привязки ролей нужны для входа узлов?

<details><summary>Ответ</summary>

ConfigMap и привязки (`kubeadm:kubelet-bootstrap`, `kubeadm:node-autoapprove-bootstrap`) создаёт фаза bootstrap-token. Привязка `kubeadm:node-autoapprove-certificate-rotation` относится к ротации сертификатов.

</details>

4. Чем отличается формат `extraArgs` в v1beta4 от v1beta3?

<details><summary>Ответ</summary>

В v1beta3 это словарь, где флаг встречается один раз. В v1beta4 это список пар `name` и `value`, поэтому флаг можно повторить.

</details>

### Лабораторная работа 2. PKI и TLS bootstrap kubelet

Эту работу вы выполняете сами, результаты в ней — ожидаемые.

**Цель.** Прочитать сертификаты кластера, сопоставить файлы с CA, которые их подписали, и найти на узлах следы TLS bootstrap и ротации сертификатов kubelet.

**Что понадобится.**

- Стенд из 00-1 и функции `ks` и `kh` из подготовки.
- Узлы `lab-control-plane` и `lab-worker`.
- Около 30 минут.

**Схема опыта.** Идём от общего к частному: файлы pki и их CA, затем сертификат API-сервера и kubeconfig-файлы control plane, затем сертификаты kubelet и следы входа узла.

```
lab-control-plane:  /etc/kubernetes/pki/*  (шаги 1–2)     *.conf (шаг 3)
lab-worker:         /var/lib/kubelet/pki/* (шаги 4–5)     config.yaml, kubelet.conf
кластер:            CSR, токены, привязки  (шаг 6)
```

Схема 9. Где искать сертификаты: pki и kubeconfig-файлы на control plane, pki kubelet на каждом узле, запросы и токены в кластере.

#### Шаг 1. Найти файлы pki и их CA

Выведем содержимое каталога `pki`, а затем для каждого листового сертификата — CA, который его подписал. Сроки этих сертификатов разобраны в 10-4, здесь важна только связь «сертификат → CA».

```bash
docker exec lab-control-plane ls /etc/kubernetes/pki /etc/kubernetes/pki/etcd
docker exec lab-control-plane sh -c 'cd /etc/kubernetes/pki &&
  for c in apiserver apiserver-kubelet-client apiserver-etcd-client front-proxy-client \
    etcd/server etcd/peer etcd/healthcheck-client; do
    printf "%-26s %s\n" "$c" "$(openssl x509 -in $c.crt -noout -issuer)"
  done'
```

Разбор команды:

| Часть команды | Значение |
|---|---|
| `ls /etc/kubernetes/pki …/etcd` | перечислить файлы ключей и сертификатов |
| `sh -c 'cd … && for c in …'` | пройти по семи листовым сертификатам внутри узла |
| `openssl x509 -noout -issuer` | напечатать только издателя, то есть подписавший CA |
| `printf "%-26s %s\n"` | выровнять имя файла и издателя в две колонки |

Ожидаемый результат:

```
/etc/kubernetes/pki:
apiserver-etcd-client.crt
apiserver-etcd-client.key
apiserver-kubelet-client.crt
apiserver-kubelet-client.key
apiserver.crt
apiserver.key
ca.crt
ca.key
etcd
front-proxy-ca.crt
front-proxy-ca.key
front-proxy-client.crt
front-proxy-client.key
sa.key
sa.pub

/etc/kubernetes/pki/etcd:
ca.crt
ca.key
healthcheck-client.crt
healthcheck-client.key
peer.crt
peer.key
server.crt
server.key
apiserver                  issuer=CN=kubernetes
apiserver-kubelet-client   issuer=CN=kubernetes
apiserver-etcd-client      issuer=CN=etcd-ca
front-proxy-client         issuer=CN=front-proxy-ca
etcd/server                issuer=CN=etcd-ca
etcd/peer                  issuer=CN=etcd-ca
etcd/healthcheck-client    issuer=CN=etcd-ca
```

Разбор вывода:

1. Файлы соответствуют схеме 4: три CA (`ca`, `etcd/ca`, `front-proxy-ca`), сертификаты под ними и пара `sa.key` и `sa.pub` без сертификата. Пар ключей одиннадцать: `ca`, `apiserver`, `apiserver-kubelet-client`, `apiserver-etcd-client`, `front-proxy-ca`, `front-proxy-client`, `etcd/ca`, `etcd/server`, `etcd/peer`, `etcd/healthcheck-client` и `sa`.
2. Издатель `CN=kubernetes` — кластерный CA: так называется его сертификат `ca.crt`. Он подписал сертификаты API-сервера и его клиента к kubelet.
3. `apiserver-etcd-client` лежит рядом с файлами API-сервера, но подписан `etcd-ca`: иначе etcd его не примет.
4. Пробелы вокруг знака равенства в `issuer` зависят от версии openssl.

#### Шаг 2. Прочитать сертификат API-сервера

Из сертификата API-сервера выведем имя, издателя, срок и список адресов (SAN).

```bash
docker exec lab-control-plane openssl x509 -in /etc/kubernetes/pki/apiserver.crt \
  -noout -subject -issuer -enddate -ext subjectAltName
```

Разбор команды:

| Часть команды | Значение |
|---|---|
| `openssl x509 -in apiserver.crt` | прочитать сертификат |
| `-noout` | не печатать сам сертификат |
| `-subject -issuer -enddate` | имя, подписавший CA, дата окончания |
| `-ext subjectAltName` | список адресов и имён в сертификате |

Ожидаемый результат:

```
subject=CN=kube-apiserver
issuer=CN=kubernetes
notAfter=<дата создания стенда плюс год> GMT
X509v3 Subject Alternative Name:
    DNS:kubernetes, DNS:kubernetes.default, DNS:kubernetes.default.svc, …, IP Address:10.96.0.1, …
```

Разбор вывода:

1. Владелец `CN=kube-apiserver`, издатель — кластерный CA.
2. Срок — год от создания стенда (8760 часов, §2).
3. В SAN есть `kubernetes.default.svc` и `10.96.0.1`: по этим адресам поды обращаются к API-серверу через Service `kubernetes`.
4. Остальные записи SAN — имя узла, его IP-адрес, `localhost` и `127.0.0.1` из `certSANs` (работа 1, шаг 2).

#### Шаг 3. Прочитать kubeconfig-файлы control plane

В kubeconfig каждого компонента сертификат хранится в поле `client-certificate-data` в base64. Достанем его из четырёх файлов и посмотрим имя и группу владельца.

```bash
for f in admin super-admin controller-manager scheduler; do
  echo "== $f"
  docker exec lab-control-plane sh -c \
    'grep client-certificate-data /etc/kubernetes/$0.conf | awk "{print \$2}" |
     base64 -d | openssl x509 -noout -subject' "$f"
done
```

Разбор команды:

| Часть команды | Значение |
|---|---|
| `for f in …` | повторить для четырёх файлов |
| `sh -c '…' "$f"` | передать имя файла в команду как `$0` |
| `grep client-certificate-data` | найти строку с сертификатом |
| `awk "{print \$2}"` | взять второе поле, то есть сам base64 |
| `base64 -d` | декодировать в сертификат |
| `openssl x509 -noout -subject` | показать имя владельца |

Ожидаемый результат:

```
== admin
subject=O=kubeadm:cluster-admins, CN=kubernetes-admin
== super-admin
subject=O=system:masters, CN=kubernetes-super-admin
== controller-manager
subject=CN=system:kube-controller-manager
== scheduler
subject=CN=system:kube-scheduler
```

Разбор вывода:

1. `CN` задаёт имя пользователя, а `O` — группу (06-1). Администратор входит в группу `kubeadm:cluster-admins`, права которой дают привязка роли, а не встроенная группа.
2. Сертификат `super-admin.conf` принадлежит группе `system:masters`: она обходит проверку RBAC. Поэтому этот файл хранят как аварийный и не раздают.
3. У controller-manager и scheduler групп нет: их права следуют из ролей `system:kube-controller-manager` и `system:kube-scheduler`.

#### Шаг 4. Прочитать сертификаты kubelet на рабочем узле

Клиентский сертификат, полученный при TLS bootstrap, лежит не в `/etc/kubernetes`, а в `/var/lib/kubelet/pki`. Выведем файлы, имя и срок текущего сертификата, а также ссылки на него в `kubelet.conf`.

```bash
docker exec lab-worker ls -l /var/lib/kubelet/pki/
docker exec lab-worker openssl x509 -in /var/lib/kubelet/pki/kubelet-client-current.pem \
  -noout -subject -enddate
docker exec lab-worker grep -E 'client-(certificate|key):' /etc/kubernetes/kubelet.conf
```

Разбор команды:

| Часть команды | Значение |
|---|---|
| `ls -l /var/lib/kubelet/pki/` | файлы сертификатов kubelet с символическими ссылками |
| `kubelet-client-current.pem` | ссылка на актуальный клиентский сертификат |
| `-subject -enddate` | имя владельца и дата окончания |
| `client-(certificate\|key):` | какие файлы указаны в kubelet.conf |

Результат, сокращённо (у `ls -l` оставлены только имена и цель ссылки):

```
kubelet-client-2026-10-14-08-23-53.pem
kubelet-client-current.pem -> /var/lib/kubelet/pki/kubelet-client-2026-10-14-08-23-53.pem
kubelet.crt  kubelet.key
subject=O=system:nodes, CN=system:node:lab-worker
notAfter=Oct 14 08:18:53 2027 GMT
```

Ожидаемый результат последней команды:

```
    client-certificate: /var/lib/kubelet/pki/kubelet-client-current.pem
    client-key: /var/lib/kubelet/pki/kubelet-client-current.pem
```

Разбор вывода:

1. Файл `kubelet-client-<дата>.pem` — сертификат, который выдал CSR при TLS bootstrap. Дата в имени — момент выдачи. Ссылка `kubelet-client-current.pem` указывает на него; при ротации ссылка перейдёт на новый файл.
2. Файлы `kubelet.crt` и `kubelet.key` — серверный сертификат kubelet, самоподписанный (шаг 5).
3. Владелец `CN=system:node:lab-worker` в группе `O=system:nodes`: этим именем kubelet входит в кластер, и авторизация Node ограничивает его права (06-1).
4. Срок окончания равен году от выдачи без пяти минут. Подписывающий контроллер ставит начало срока на 5 минут раньше текущего времени, запас на расхождение часов. Для долгих сертификатов он настолько же укорачивает и конец срока.
5. В `kubelet.conf` вместо данных стоят пути к ссылке `kubelet-client-current.pem`. Сам `kubelet.conf` kubelet записал в конце TLS bootstrap, поэтому после ротации он подхватит новый сертификат без правки kubeconfig. На первом узле control plane тот же переход делает фаза kubelet-finalize.

#### Шаг 5. Проверить серверный сертификат kubelet и список CSR

Серверный сертификат kubelet выпускает сам kubelet. Проверим, кто его подписал, и посмотрим, есть ли в кластере запросы на подпись.

```bash
docker exec lab-worker openssl x509 -in /var/lib/kubelet/pki/kubelet.crt \
  -noout -subject -issuer
ks get csr
```

Разбор команды:

| Часть команды | Значение |
|---|---|
| `openssl x509 -in kubelet.crt` | прочитать серверный сертификат kubelet |
| `-subject -issuer` | владелец и подписавший |
| `ks get csr` | список CertificateSigningRequest в кластере |

Ожидаемый результат:

```
subject=CN=lab-worker@1760430245
issuer=CN=lab-worker-ca@1760430245
No resources found
```

Разбор вывода:

1. Владелец и издатель различаются именами, но обе записи созданы самим kubelet: он сам сделал и временный CA, и сертификат. Число после `@` — время создания.
2. Такой сертификат не подписан CA кластера, поэтому API-сервер, metrics-server и другие клиенты не могут проверить его по CA. Поэтому metrics-server на стенде запущен с `--kubelet-insecure-tls` (00-1).
3. CSR в кластере нет, потому что контроллер очистки удаляет одобренные запросы через час. Запросы TLS bootstrap, которые создали узлы при присоединении, уже удалены.
4. Если включить `serverTLSBootstrap: true`, в списке появятся запросы `kubernetes.io/kubelet-serving` в состоянии Pending, и их придётся одобрять (§3, 10-4). Здесь мы только читаем и этого не делаем.

#### Шаг 6. Найти токены присоединения

Токен нужен только при присоединении узла. Проверим, остался ли он в кластере.

```bash
docker exec lab-control-plane kubeadm token list
ks -n kube-system get secret -o name | grep bootstrap-token
```

Разбор команды:

| Часть команды | Значение |
|---|---|
| `kubeadm token list` | перечислить токены присоединения |
| `get secret -o name` | имена всех Secret в `kube-system` |
| `grep bootstrap-token` | оставить Secret токенов, `bootstrap-token-<id>` |

Ожидаемый результат для кластера старше суток:

```
(пусто)
```

Разбор вывода:

1. Оба вывода пусты: токен прожил 24 часа и контроллер очистки его удалил. Узлы к тому времени уже присоединились и работают по сертификатам.
2. Если выводы не пусты, кластер моложе суток. В списке `kubeadm token list` будут колонки `TTL` и `USAGES` (`authentication,signing`).
3. Чтобы добавить узел позже, создают новый токен: `kubeadm token create --print-join-command` (§3). На стенде вы этого не делаете, потому что команда создаёт Secret.

**Итог.** Что вы узнали:

| Что узнали | Где видно |
|---|---|
| три CA подписывают разные сертификаты, пар ключей одиннадцать | `/etc/kubernetes/pki`, шаг 1 |
| сертификат API-сервера выписан на имена и адреса из SAN | `openssl x509 -ext`, шаг 2 |
| имя и группа компонента записаны в сертификате его kubeconfig | `subject`, шаг 3 |
| узел получил клиентский сертификат через CSR, срок короче года на 5 минут | `/var/lib/kubelet/pki`, шаг 4 |
| серверный сертификат kubelet самоподписан без `serverTLSBootstrap` | шаг 5 |
| токен присоединения живёт 24 часа | `kubeadm token list`, шаг 6 |

**Уборка.** Работа ничего не создавала. Функции `ks` и `kh` понадобятся в работе 3; если вы останавливаетесь здесь, выполните `unset -f ks kh`.

**Вопросы для самопроверки.**

1. Какой CA подписал сертификат `apiserver-etcd-client` и почему не кластерный?

<details><summary>Ответ</summary>

Его подписал `etcd-ca`. etcd доверяет только своему CA, поэтому ключ кластерного CA не открывает доступ к данным etcd.

</details>

2. Почему клиентский сертификат kubelet истекает на пять минут раньше, чем через год после выдачи?

<details><summary>Ответ</summary>

Подписывающий контроллер в controller-manager сдвигает начало срока на 5 минут назад, чтобы пережить расхождение часов. Для сертификатов длиннее 8 часов конец срока сдвигается на те же 5 минут.

</details>

3. Почему на стенде нет CSR, хотя узлы присоединялись через TLS bootstrap?

<details><summary>Ответ</summary>

Одобренные и выданные CSR удаляет контроллер очистки примерно через час, а стенд старше.

</details>

4. Зачем нужна пара `sa.key` и `sa.pub`, если это не сертификат?

<details><summary>Ответ</summary>

controller-manager подписывает ею токены ServiceAccount, а API-сервер проверяет подпись публичным ключом. Поэтому пара одинакова на всех узлах control plane.

</details>

### Лабораторная работа 3. HA control plane из трёх узлов

Эту работу вы выполняете сами, результаты в ней — ожидаемые.

**Риски.**

- **Что меняется:** создаётся второй кластер kind `lab-10-1`: четыре контейнера узлов (три control plane и один рабочий) и пятый контейнер с балансировщиком. На хосте появляются файлы в `~/lab/k8s/10-1/` и один порт на `127.0.0.1`. Стенд и `~/.kube/config` не меняются. В ходе работы вы останавливаете и запускаете контейнеры узлов нового кластера.
- **Надолго ли:** до уборки. Кластер создаётся дольше стенда, потому что узлы control plane присоединяются по очереди.
- **Безопасность:** узлы kind — привилегированные контейнеры, как на стенде. API-сервер слушает только `127.0.0.1`. Ключи CA лежат внутри контейнеров.
- **Влияние на систему:** кластер добавляет около 4–5 ГиБ памяти к стенду (около 2,5 ГиБ). Перед началом проверьте `free -h`: если свободно меньше 8 ГиБ, остановите стенд командой `bash kubernetes/lab/lab-down.sh` (данные сохраняются), а после работы запустите `lab-up.sh`. Восемь узлов kind (четыре стенда и четыре нового кластера) требуют лимитов inotify из 00-1 (работа 1). Сеть Docker `kind` общая со стендом, адреса разные.
- **Откат:** `kind delete cluster --name lab-10-1` и блок «Уборка». Если после остановки узел при запуске получил другой IP-адрес и член etcd не вернулся, не чините его: удалите кластер и создайте заново.

**Цель.** Собрать кластер с тремя узлами control plane и балансировщиком и найти, как узлы присоединились. Затем остановить один узел и убедиться, что API отвечает, а потеря второго узла останавливает запись.

**Что понадобится.**

- Docker, kind 0.32, образ `kindest/node:v1.36.1` (уже скачан для стенда).
- Функция `kh` и каталог `~/lab/k8s/10-1` из подготовки.
- Около 5 ГиБ свободной памяти и лимиты inotify из 00-1.
- Около 45 минут.

**Схема опыта.**

```
хост 127.0.0.1:<порт> ──► lab-10-1-external-load-balancer  (Envoy, проверка /healthz)
                              │  :6443 на каждом backend
        ┌─────────────────────┼─────────────────────┐
        ▼                     ▼                     ▼
 lab-10-1-control-plane  …-control-plane2    …-control-plane3     lab-10-1-worker
 apiserver + etcd        apiserver + etcd    apiserver + etcd     kubelet
```

Схема 10. Кластер `lab-10-1`: kubeconfig на хосте указывает на балансировщик, а не на конкретный узел. Опыт состоит в том, чтобы убрать один backend и затем второй.

#### Шаг 1. Написать конфигурацию кластера

Конфигурация kind описывает три узла control plane и один рабочий. Балансировщик kind добавит сам, потому что узлов control plane больше одного.

```bash
cat > ~/lab/k8s/10-1/kind-ha.yaml <<'EOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: lab-10-1
nodes:
- role: control-plane
- role: control-plane
- role: control-plane
- role: worker
EOF
```

Разбор команды:

| Часть команды | Значение |
|---|---|
| `name: lab-10-1` | имя кластера; от него зависят имена контейнеров |
| `role: control-plane` (три раза) | три узла control plane, каждый со своим etcd |
| `role: worker` | один рабочий узел |
| `<<'EOF'` | записать текст до строки `EOF` без подстановок |

Шаг молчит. Файл лежит в `~/lab/k8s/10-1/kind-ha.yaml`, и на этом этапе ничего не создано.

#### Шаг 2. Создать кластер и сохранить журнал сборки

Команда создаёт кластер, пишет доступ в отдельный kubeconfig и сохраняет подробный журнал. Уровень `--verbosity 3` заставляет kind печатать вывод kubeadm.

```bash
kind create cluster --config ~/lab/k8s/10-1/kind-ha.yaml --image kindest/node:v1.36.1 \
  --kubeconfig ~/lab/k8s/10-1/kubeconfig --wait 180s --verbosity 3 \
  2>&1 | tee ~/lab/k8s/10-1/create.log | tail -n 8
kh create namespace lab-10-1
```

Разбор команды:

| Часть команды | Значение |
|---|---|
| `--image kindest/node:v1.36.1` | образ узла с Kubernetes 1.36.1 |
| `--kubeconfig …/kubeconfig` | писать доступ в отдельный файл |
| `--wait 180s` | ждать готовности до трёх минут |
| `--verbosity 3` | печатать вывод kubeadm |
| `2>&1 \| tee …/create.log` | сохранить весь вывод в файл |
| `\| tail -n 8` | показать только последние 8 строк |
| `kh create namespace lab-10-1` | создать namespace работы в новом кластере |

Ожидаемый результат, последние строки:

```
 ✓ Joining more control-plane nodes
 ✓ Joining worker nodes
 ✓ Waiting ≤ 3m0s for control-plane = Ready
 • Ready after 1s
Set kubectl context to "kind-lab-10-1"
…
namespace/lab-10-1 created
```

Разбор вывода:

1. Шаг «Joining more control-plane nodes» выполнен раньше шага «Joining worker nodes»: kind присоединяет узлы control plane по очереди, а рабочие после них.
2. Последняя строка относится к файлу `~/lab/k8s/10-1/kubeconfig`; текущий контекст в `~/.kube/config` не менялся.
3. Namespace `lab-10-1` создан в новом кластере. Стенд его не видит.

#### Шаг 3. Найти фазы init и join в журнале

Журнал содержит вывод kubeadm. Найдём в нём метки фаз в порядке первого появления, а затем строки, по которым видно, как присоединялись остальные узлы control plane.

```bash
L='certs|kubeconfig|etcd|control-plane|kubelet-start|wait-control-plane|upload-config'
L+='|mark-control-plane|bootstrap-token|kubelet-finalize|addons'
grep -oE "\[($L)\]" \
  ~/lab/k8s/10-1/create.log | awk '!seen[$0]++'
grep -E 'Announced new etcd member|Marking the node' ~/lab/k8s/10-1/create.log | cut -c1-96
```

Разбор команды:

| Часть команды | Значение |
|---|---|
| `grep -oE '\[(…)\]'` | вывести только метки фаз в квадратных скобках |
| `awk '!seen[$0]++'` | оставить первое появление каждой метки |
| `Announced new etcd member` | строка, когда новый узел стал членом etcd |
| `Marking the node` | строка фазы mark-control-plane |
| `cut -c1-96` | обрезать длинные строки до 96 знаков |

Ожидаемый результат:

```
[certs]
[kubeconfig]
[etcd]
[control-plane]
[kubelet-start]
[wait-control-plane]
[upload-config]
[mark-control-plane]
[bootstrap-token]
[kubelet-finalize]
[addons]
[etcd] Announced new etcd member joining to the existing etcd cluster
[etcd] Announced new etcd member joining to the existing etcd cluster
[mark-control-plane] Marking the node lab-10-1-control-plane as control-plane by adding the labe
[mark-control-plane] Marking the node lab-10-1-control-plane as control-plane by adding the tain
… (по две строки для control-plane2 и control-plane3)
```

Разбор вывода:

1. Первые одиннадцать меток идут в порядке фаз `kubeadm init` (схема 2). Метка фазы `addon` в журнале выглядит как `[addons]`. Фаза preflight пропущена: kind отключает её в конфигурации.
2. Две строки `Announced new etcd member` — это присоединение второго и третьего узла control plane: каждый стал новым членом etcd, а не отдельным кластером.
3. Строки `mark-control-plane` напечатали все три узла, по две на узел (метки и taint): первый на `init`, остальные на `join`.
4. Строк `[download-certs]` нет: ключи CA kind передал копированием файлов, а не через Secret `kubeadm-certs` (§3).

#### Шаг 4. Увидеть топологию: узлы, контейнеры и балансировщик

Проверим узлы кластера, контейнеры Docker, адрес API в kubeconfig и список backend в конфигурации балансировщика.

```bash
kh get nodes --no-headers | awk '{print $1, $2, $3, $5}'
docker ps --filter label=io.x-k8s.kind.cluster=lab-10-1 --format '{{.Names}}  {{.Image}}'
kubectl --kubeconfig ~/lab/k8s/10-1/kubeconfig config view \
  -o jsonpath='{.clusters[0].cluster.server}{"\n"}'
docker exec lab-10-1-external-load-balancer cat /home/envoy/cds.yaml | \
  grep -E ' (address|port_value|path): '
```

Разбор команды:

| Часть команды | Значение |
|---|---|
| `awk '{print $1, $2, $3, $5}'` | имя, статус, роль и версию узла |
| `docker ps --filter label=…` | контейнеры этого кластера |
| `config view -o jsonpath` | адрес сервера из kubeconfig |
| `/home/envoy/cds.yaml` | файл Envoy со списком backend |
| `grep -E ' (address\|port_value\|path): '` | адреса, порты и путь проверки здоровья |

Ожидаемый результат:

```
lab-10-1-control-plane Ready control-plane v1.36.1
lab-10-1-control-plane2 Ready control-plane v1.36.1
lab-10-1-control-plane3 Ready control-plane v1.36.1
lab-10-1-worker Ready <none> v1.36.1
lab-10-1-control-plane  kindest/node:v1.36.1
lab-10-1-control-plane2  kindest/node:v1.36.1
lab-10-1-control-plane3  kindest/node:v1.36.1
lab-10-1-external-load-balancer  envoyproxy/envoy:v1.36.2
lab-10-1-worker  kindest/node:v1.36.1
https://127.0.0.1:<порт>
      path: /healthz
              address: lab-10-1-control-plane
              port_value: 6443
              address: lab-10-1-control-plane2
              port_value: 6443
              address: lab-10-1-control-plane3
              port_value: 6443
```

Разбор вывода:

1. Три узла имеют роль `control-plane`, а рабочий узел — `<none>`. Все узлы Ready.
2. Контейнеров пять: четыре узла и `lab-10-1-external-load-balancer` на образе Envoy. До kind 0.32 здесь был HAProxy.
3. Адрес в kubeconfig — `127.0.0.1` и порт, который Docker привязал к контейнеру балансировщика. Клиент хоста не знает адресов узлов.
4. В конфигурации Envoy три backend на порту 6443 и проверка здоровья по пути `/healthz`. Backend заданы именами контейнеров, а не IP: Envoy разрешает их через DNS сети Docker. Параметры проверки: интервал 2 секунды, тайм-аут 3 секунды, узел исключается после двух неудач подряд.

#### Шаг 5. Проверить членов etcd и держателей аренды

Перед отказом запишем исходное состояние: членов etcd с лидером и узлы, на которых работают активные controller-manager и scheduler. Переменная `E` собирает адрес и сертификаты etcdctl (карточка — в 01-1).

```bash
E='etcdctl --endpoints=https://127.0.0.1:2379 --cacert=/etc/kubernetes/pki/etcd/ca.crt'
E+=' --cert=/etc/kubernetes/pki/etcd/server.crt --key=/etc/kubernetes/pki/etcd/server.key'
kh -n kube-system exec etcd-lab-10-1-control-plane -- $E member list -w table
kh -n kube-system exec etcd-lab-10-1-control-plane -- $E endpoint status --cluster -w table
kh -n kube-system get lease kube-controller-manager kube-scheduler \
  -o custom-columns=NAME:.metadata.name,HOLDER:.spec.holderIdentity
```

Разбор команды:

| Часть команды | Значение |
|---|---|
| `E='etcdctl …'` | адрес и сертификаты etcdctl в одной переменной |
| `exec etcd-lab-10-1-control-plane --` | выполнить команду в поде etcd первого узла |
| `member list -w table` | члены кластера etcd таблицей |
| `endpoint status --cluster` | состояние каждого члена, включая лидера |
| `get lease … -o custom-columns` | держатель аренды каждого компонента |

Ожидаемый результат, колонки сокращены:

```
| ID | STATUS  | NAME                    | PEER ADDRS               | IS LEARNER |
| …  | started | lab-10-1-control-plane  | https://<IP узла 1>:2380 | false      |
| …  | started | lab-10-1-control-plane2 | https://<IP узла 2>:2380 | false      |
| …  | started | lab-10-1-control-plane3 | https://<IP узла 3>:2380 | false      |

| ENDPOINT                 | VERSION | IS LEADER | IS LEARNER |
| https://<IP узла 1>:2379 | 3.6.x   | false     | false      |
| https://<IP узла 2>:2379 | 3.6.x   | true      | false      |
| https://<IP узла 3>:2379 | 3.6.x   | false     | false      |

NAME                      HOLDER
kube-controller-manager   lab-10-1-control-plane2_<UUID>
kube-scheduler            lab-10-1-control-plane_<UUID>
```

Разбор вывода:

1. Три члена в состоянии `started`, ни один не learner: все полноправные. Кворум — 2 из 3 (01-1).
2. Лидер etcd один (`IS LEADER true`). Какой именно узел стал лидером, зависит от запуска.
3. Аренды controller-manager и scheduler принадлежат экземплярам на узлах, имена которых стоят до знака подчёркивания. Это активные экземпляры, остальные ждут (01-1). Держатели у вас могут быть другими.

#### Шаг 6. Остановить узел с активным controller-manager

Остановим узел, где работает активный controller-manager. Тогда видно сразу два эффекта: API через балансировщик и переход аренды. Цикл проверяет `/readyz` десять раз с паузой в секунду.

```bash
HOLDER=$(kh -n kube-system get lease kube-controller-manager -o jsonpath='{.spec.holderIdentity}')
HOLDER=${HOLDER%%_*}
echo "останавливаем $HOLDER"
docker stop "$HOLDER"
for i in $(seq 1 10); do
  if kh get --raw /readyz >/dev/null 2>&1; then echo "$i ok"; else echo "$i fail"; fi
  sleep 1
done
```

Разбор команды:

| Часть команды | Значение |
|---|---|
| `jsonpath='{.spec.holderIdentity}'` | узел и идентификатор держателя аренды |
| `${HOLDER%%_*}` | оставить имя узла, отрезав всё после `_` |
| `docker stop "$HOLDER"` | остановить контейнер узла: отказ всего узла |
| `kh get --raw /readyz` | запрос готовности API через балансировщик |
| `seq 1 10`, `sleep 1` | десять проверок с паузой в секунду |

Ожидаемый результат:

```
останавливаем lab-10-1-control-plane2
lab-10-1-control-plane2
1 ok
2 ok
…
10 ok
```

Разбор вывода:

1. Команда `docker stop` печатает имя остановленного контейнера.
2. API отвечает через балансировщик, потому что два других API-сервера живы. В первые секунды после остановки возможны единичные `fail`: Envoy проверяет здоровье каждые 2 секунды и исключает backend после двух неудач, то есть не мгновенно.
3. Клиент не знает, что узел остановлен: адрес в kubeconfig остался прежним.

#### Шаг 7. Проверить состояние после отказа

Подождём минуту, пока узел получит статус NotReady и аренда перейдёт на другой экземпляр. Затем проверим узлы, членов etcd (через под на живом узле) и запись в кластер.

```bash
sleep 60
kh get nodes --no-headers | awk '{print $1, $2}'
kh -n kube-system get lease kube-controller-manager -o jsonpath='{.spec.holderIdentity}{"\n"}'
SURV=$(kh -n kube-system get pods -l component=etcd -o name | grep -v "etcd-${HOLDER}\$" | head -1)
kh -n kube-system exec "${SURV#pod/}" -- $E endpoint status --cluster -w table
kh create configmap ha-demo --from-literal=step=7
```

Разбор команды:

| Часть команды | Значение |
|---|---|
| `sleep 60` | дать время узлу стать NotReady, а аренде перейти |
| `get nodes … awk` | имена и статусы узлов |
| `get lease kube-controller-manager` | новый держатель аренды |
| `get pods -l component=etcd` | поды etcd; label `component` ставит kubeadm |
| `grep -v "etcd-${HOLDER}\$"` | отбросить под остановленного узла |
| `endpoint status --cluster` | состояние членов etcd из живого пода |
| `create configmap ha-demo` | запись в кластер при потере одного члена |

Ожидаемый результат:

```
lab-10-1-control-plane Ready
lab-10-1-control-plane2 NotReady
lab-10-1-control-plane3 Ready
lab-10-1-worker Ready
lab-10-1-control-plane3_<UUID>
{"level":"warn",…"Failed to get the status of endpoint https://<IP узла 2>:2379…"}
| ENDPOINT                 | VERSION | IS LEADER | IS LEARNER |
| https://<IP узла 1>:2379 | 3.6.x   | false     | false      |
| https://<IP узла 3>:2379 | 3.6.x   | true      | false      |
configmap/ha-demo created
```

Разбор вывода:

1. Остановленный узел стал NotReady примерно через 50 секунд после остановки (01-2). Рабочий узел и два других узла control plane Ready.
2. Аренда перешла на экземпляр другого узла: прежний держатель перестал её продлевать, и через срок аренды (15 с, 01-1) её занял другой.
3. etcd вернул состояние двух членов, а третий не ответил: об этом сообщает предупреждение. Если остановленным был лидер, в оставшихся двух выбран новый.
4. ConfigMap создан: кворум 2 из 3 сохранился, запись возможна. Кластер потерял узел, но не потерял функциональность.

#### Шаг 8. Остановить второй узел control plane и потерять кворум

Остановим ещё один узел control plane. Остался один член etcd из трёх, это меньше кворума. Попробуем прочитать готовность и записать объект с ограниченным временем ожидания.

```bash
SECOND=$(docker ps --filter name=lab-10-1-control-plane --format '{{.Names}}' | head -1)
echo "останавливаем $SECOND"
docker stop "$SECOND"
sleep 15
kh get --raw /readyz --request-timeout=10s; echo "код=$?"
kh create configmap ha-lost --from-literal=step=8 --request-timeout=15s; echo "код=$?"
```

Разбор команды:

| Часть команды | Значение |
|---|---|
| `docker ps --filter name=… \| head -1` | выбрать один из оставшихся работающих узлов control plane |
| `docker stop "$SECOND"` | остановить его |
| `--request-timeout=10s` | не ждать ответа дольше 10 секунд |
| `get --raw /readyz` | проверить готовность API |
| `create configmap ha-lost` | попытаться записать объект |
| `echo "код=$?"` | напечатать код завершения последней команды |

Ожидаемый результат (текст ошибок зависит от момента):

```
останавливаем lab-10-1-control-plane3
lab-10-1-control-plane3
Error from server …   (или The connection to the server … / EOF)
код=1
Error from server …   (текст другой, чем выше)
код=1
```

Разбор вывода:

1. Запись не проходит. Для записи API-серверу нужно согласие большинства членов etcd, а живой член один из трёх.
2. Готовность тоже не проходит: проверка etcd внутри `/readyz` и `/healthz` не выполняется. Последний backend не проходит проверку здоровья, но Envoy по умолчанию всё равно шлёт на него соединения (panic mode: здоровых backend меньше половины). Поэтому чаще ошибку возвращает сам API-сервер, а не балансировщик.
3. Поды на рабочем узле продолжают работать: kubelet и контейнеры не зависят от API. Но Deployment не заменит упавший под, а новые объекты нельзя создать.
4. Вывод для практики: в кластере из трёх узлов нельзя останавливать два узла control plane одновременно.

#### Шаг 9. Вернуть узлы и проверить, что данные на месте

Запустим оба остановленных узла и дождёмся готовности. После этого проверим членов etcd и объект, созданный на шаге 7.

```bash
docker start "$HOLDER" "$SECOND"
until kh get --raw /readyz >/dev/null 2>&1; do sleep 3; done
kh wait --for=condition=Ready node --all --timeout=180s
kh -n kube-system exec etcd-lab-10-1-control-plane -- $E member list -w table
kh get configmap ha-demo ha-lost
```

Разбор команды:

| Часть команды | Значение |
|---|---|
| `docker start "$HOLDER" "$SECOND"` | запустить оба остановленных узла |
| `until … /readyz` | ждать, пока API снова ответит |
| `wait --for=condition=Ready node --all` | ждать готовности всех узлов до трёх минут |
| `member list -w table` | убедиться, что три члена на месте |
| `get configmap ha-demo ha-lost` | проверить объекты шагов 7 и 8 |

Ожидаемый результат:

```
node/lab-10-1-control-plane condition met
node/lab-10-1-control-plane2 condition met
node/lab-10-1-control-plane3 condition met
node/lab-10-1-worker condition met
| …  | started | lab-10-1-control-plane  | … | false |
| …  | started | lab-10-1-control-plane2 | … | false |
| …  | started | lab-10-1-control-plane3 | … | false |
NAME      DATA   AGE
ha-demo   1      …
Error from server (NotFound): configmaps "ha-lost" not found
```

Разбор вывода:

1. Все три члена etcd вернулись и снова `started`: данные членов сохранились на дисках контейнеров, и они догнали друг друга.
2. Объект `ha-demo` на месте: он был записан при кворуме.
3. Объекта `ha-lost` нет: запись на шаге 8 отклонена, и после восстановления кластер не создал его сам.
4. Если член etcd не вернулся (в логе `docker logs <узел>` видны ошибки соединения с пирами), причина обычно в смене IP-адреса узла. Удалите кластер и создайте заново (раздел «Риски»).

**Итог.** Что вы узнали:

| Что узнали | Где видно |
|---|---|
| kubeadm сначала собирает первый узел, затем присоединяет остальные по очереди | журнал создания, шаг 3 |
| клиенты ходят через балансировщик, а не к узлам | kubeconfig и контейнер Envoy, шаг 4 |
| в стековой топологии на каждом узле свой член etcd | `member list`, шаг 5 |
| отказ одного узла из трёх не останавливает ни чтение, ни запись | шаги 6–7 |
| отказ двух узлов останавливает запись, поды продолжают работать | шаг 8 |
| после возврата узлов данные на месте | шаг 9 |

**Уборка.** Удалите кластер, каталог работы, функции и переменные. Если вы останавливали стенд, запустите его снова.

```bash
kind delete cluster --name lab-10-1 --kubeconfig ~/lab/k8s/10-1/kubeconfig
rm -rf ~/lab/k8s/10-1
unset -f ks kh
unset HOLDER SECOND SURV E L
docker ps -a --filter label=io.x-k8s.kind.cluster=lab-10-1 --format '{{.Names}}'
```

Команда `kind delete cluster` удаляет все пять контейнеров, включая балансировщик, и убирает контекст из указанного kubeconfig. Последняя команда должна напечатать пустой вывод. Если вы останавливали стенд командой `lab-down.sh`, запустите его командой `bash kubernetes/lab/lab-up.sh`.

**Вопросы для самопроверки.**

1. Почему kubeconfig кластера `lab-10-1` указывает на `127.0.0.1`, а не на узел control plane?

<details><summary>Ответ</summary>

Адрес принадлежит порту, который Docker привязал к контейнеру балансировщика. Балансировщик раздаёт запросы на живые API-серверы, поэтому клиент не зависит от конкретного узла.

</details>

2. Сколько узлов control plane можно потерять одновременно в кластере из трёх узлов со стековым etcd и почему?

<details><summary>Ответ</summary>

Один. Кворум etcd из трёх членов равен двум; при потере второго узла запись останавливается, хотя поды на рабочих узлах продолжают работать.

</details>

3. Как kind передаёт ключи CA на второй и третий узлы control plane и чем это отличается от `upload-certs`?

<details><summary>Ответ</summary>

kind копирует файлы CA из `/etc/kubernetes/pki` первого узла на остальные. `upload-certs` шифрует их в Secret `kubeadm-certs` на 2 часа, и узел скачивает его по `--certificate-key`.

</details>

4. Что нужно изменить в схеме, чтобы отказы API-сервера и etcd не зависели друг от друга?

<details><summary>Ответ</summary>

Перейти на внешний etcd: отдельные машины для etcd, а API-серверы подключаются к нему по адресам `etcd.external` с сертификатами клиента. Цена — вдвое больше машин и отдельное обслуживание etcd.

</details>

---

## → Дальше

В этой части мы собрали кластер и увидели стековую топологию: каждый узел control plane несёт собственный член etcd. Пишет ли кластер, решает кворум этих членов. Часть 10-2 открывает этот член: как посмотреть его состояние, снять снапшот, восстановить базу и что делать, когда она разрастается до квоты. Она идёт следующей: отказ из работы 3 вылечился возвратом узлов, а при потере данных спасает только снапшот etcd.
