# 10-3. Сертификаты и обслуживание узлов

> Модуль 10 «Эксплуатация кластера» · часть 3 из 3 · 🟡🔴 · ~1 ч чтения + ~40 мин лабы · Нужно: стенд 00-1 (после 10-2 — v1.36.5). База по PKI и TLS — networks 05-4.

---

## Зачем это DevOps-у

Самоустановленный кластер (kubeadm) через год после установки «внезапно» перестаёт отвечать: истекли сертификаты компонентов. Это одна из самых частых аварий self-hosted кластеров, и она полностью предсказуема. Вторая регулярная работа — обслуживание узлов: обновление ядра, замена диска, перезагрузка — без простоя сервисов. На собеседовании: «какие сертификаты есть в кластере и сколько живут», «как вывести узел на обслуживание».

Сквозной сценарий: продлеваем сертификаты control plane и перезагружаем узел под нагрузкой на `orders.localhost/api/orders`.

---

## 1. PKI kubeadm 🟡

Kubeadm создаёт три CA и набор сертификатов в `/etc/kubernetes/pki` (и kubeconfig'и в `/etc/kubernetes/*.conf`). Проверено (`kubeadm certs check-expiration` после обновления в 10-2):

```
CERTIFICATE                EXPIRES                  RESIDUAL TIME   CERTIFICATE AUTHORITY
admin.conf                 Oct 14, 2027 15:47 UTC   364d            ca
apiserver                  Oct 14, 2027 15:47 UTC   364d            ca
apiserver-etcd-client      Oct 14, 2027 15:47 UTC   364d            etcd-ca
apiserver-kubelet-client   Oct 14, 2027 15:47 UTC   364d            ca
controller-manager.conf    Oct 14, 2027 15:47 UTC   364d            ca
etcd-healthcheck-client    Oct 14, 2027 15:47 UTC   364d            etcd-ca
etcd-peer                  Oct 14, 2027 15:47 UTC   364d            etcd-ca
etcd-server                Oct 14, 2027 15:47 UTC   364d            etcd-ca
front-proxy-client         Oct 14, 2027 15:47 UTC   364d            front-proxy-ca
scheduler.conf             Oct 14, 2027 15:47 UTC   364d            ca
super-admin.conf           Oct 14, 2027 15:47 UTC   364d            ca
CERTIFICATE AUTHORITY   EXPIRES                  RESIDUAL TIME
ca                      Oct 11, 2036 08:23 UTC   9y
etcd-ca                 Oct 11, 2036 08:23 UTC   9y
front-proxy-ca          Oct 11, 2036 08:23 UTC   9y
```

| Что | Срок по умолчанию | Кто продлевает |
|---|---|---|
| CA (`ca`, `etcd-ca`, `front-proxy-ca`) | 10 лет (`caCertificateValidityPeriod: 87600h`) | вручную, отдельная процедура |
| сертификаты компонентов control plane и kubeconfig'и `*.conf` | **1 год** (`certificateValidityPeriod: 8760h`) | `kubeadm certs renew` или **`kubeadm upgrade apply`** (продлевает автоматически — 10-2) |
| клиентский сертификат kubelet | 1 год | **сам kubelet** (`rotateCertificates: true`) через CSR |
| серверный сертификат kubelet | самоподписанный по умолчанию | при `serverTLSBootstrap: true` — через CSR, которые надо одобрять |

Отсюда правило: кластер, который обновляют хотя бы раз в год, проблемы с годовыми сертификатами не знает. Кластер, «который работает — не трогаем», через год ляжет.

## 2. Продление и перезапуск 🟡

```bash
kubeadm certs check-expiration
kubeadm certs renew all              # или по одному: renew apiserver
# затем перезапустить static pods: etcd, kube-apiserver, kube-controller-manager, kube-scheduler
```

Проверено: `kubeadm certs renew all` завершается текстом `You must restart the kube-apiserver, kube-controller-manager, kube-scheduler and etcd, so that they can use the new certificates.`

Наблюдение на стенде: **apiserver подхватил продлённый серверный сертификат без перезапуска** — после `kubeadm certs renew apiserver` сертификат, который отдаёт `:6443`, сменился сразу (проверено: `notBefore` до продления — 15:42:30, после — 16:00:31, без рестарта). apiserver перечитывает сертификаты с диска (dynamic reload). Но клиентские сертификаты внутри kubeconfig'ов controller-manager и scheduler, а также сертификаты etcd читаются при старте — перезапускайте все четыре, как требует kubeadm.

Перезапуск static pod — перенос манифеста из каталога и обратно (проверено: каждый компонент вернулся, API доступен; etcd — 46 с, apiserver — 36 с, controller-manager и scheduler — по 15 с, включая 15 с паузы). На кластере с несколькими узлами control plane — по одному узлу; клиентам это не видно.

**Админский kubeconfig.** `admin.conf` продлевается тоже, но копия в `~/.kube/config` у людей — нет: её надо забрать заново, когда старый сертификат подходит к концу. На стенде `kind get kubeconfig` читает актуальный `admin.conf` (проверено: срок клиентского сертификата — `Oct 14 15:47:30 2027`).

## 3. Сертификаты kubelet 🟡

Проверено на `lab-worker`:

```
kubelet-client-2026-10-14-08-23-53.pem
kubelet-client-current.pem -> /var/lib/kubelet/pki/kubelet-client-2026-10-14-08-23-53.pem
kubelet.crt  kubelet.key                                  ← серверный, самоподписанный
subject=O=system:nodes, CN=system:node:lab-worker
notAfter=Oct 14 08:18:53 2027 GMT
rotateCertificates: true
```

- Клиентский сертификат (`system:node:<узел>`, группа `system:nodes`) kubelet обновляет сам: около 70–90% срока создаёт CSR, контроллер одобряет автоматически, kubelet переключает симлинк `kubelet-client-current.pem`. Если ротация сломана (неверное время на узле, удалены права на автоодобрение) — через год узел станет `NotReady` с ошибками `certificate has expired` в логах kubelet.
- Серверный сертификат по умолчанию самоподписанный — поэтому metrics-server на стенде запущен с `--kubelet-insecure-tls` (00-1). В проде включают `serverTLSBootstrap: true` и одобрение CSR (контроллером вроде kubelet-csr-approver), иначе `kubectl logs/exec` и метрики ходят к kubelet без проверки сертификата.

## 4. Смена IP узла control plane 🔴

Сертификаты содержат IP узла в SAN. Сменился адрес (перенос VM, DHCP, перезапуск Docker на kind) — компоненты, которые ходят по IP, перестают доверять серверу. Проверено в 10-2: серверный сертификат etcd был выписан на `172.20.0.4`, узел получил `172.20.0.2`, kubeadm упал с `error syncing endpoints with etcd`. Перевыпуск — `kubeadm init phase certs etcd-server/etcd-peer` (и `apiserver`, если его SAN устарел) с конфигурацией, где указан новый адрес, и перезапуск компонентов. Для control plane используйте стабильные адреса и DNS-имя `controlPlaneEndpoint` (на стенде — `lab-control-plane:6443`).

## 5. Плановое обслуживание узла 🟡

Runbook:

1. **Проверить запас**: PDB с ненулевым бюджетом (05-4), ёмкость на остальных узлах, нет ли на узле stateful-подов на local-томах (иначе — их простой или перенос данных).
2. **`kubectl cordon` + `kubectl drain --ignore-daemonsets --delete-emptydir-data --timeout=…`.**
3. Обслуживание: обновление пакетов/ядра, перезагрузка.
4. **Проверить узел**: `Ready`, отсутствие pressure-условий, kubelet и containerd активны, поды DaemonSet (CNI, kube-proxy, агенты) Running — и **только потом** `kubectl uncordon`.
5. Убедиться, что нагрузка вернулась (поды планируются на узел).

Проверено (под нагрузкой на сквозной сценарий, узел `lab-worker2`):

```
drained +37s
node rebooted +38s
node Ready +38s
MemoryPressure=False DiskPressure=False PIDPressure=False Ready=True
uncordoned +39s
orders during maintenance: ok=678 fail=0
kindnet-skhnn Running 2          ← счётчик перезапусков вырос — DaemonSet пережил перезагрузку
kube-proxy-rjvp6 Running 1
```

Ноль ошибок у клиентов. Подвох в строке `node Ready +38s`: статус узла после перезагрузки ещё не успел смениться — он «Ready» по старому отчёту. Проверять готовность надо по свежему heartbeat (`kubectl get lease -n kube-node-lease <узел>` — `renewTime` после перезагрузки) и по подам DaemonSet, а не по одному полю.

Автоматизация обслуживания: kured (перезагрузка узлов после обновлений пакетов по одному, с drain), node-problem-detector (условия узла из логов ядра: дисковые ошибки, зависания), managed node groups с заменой узлов вместо обновления на месте (10-2 §4). ⚠️ На стенде не ставились.

---

## 🔧 Лаба

### Шаг 0. Сроки

```bash
kubectl config use-context kind-lab
CP=lab-control-plane
docker exec $CP kubeadm certs check-expiration
docker exec lab-worker ls -l /var/lib/kubelet/pki/
docker exec lab-worker openssl x509 -in /var/lib/kubelet/pki/kubelet-client-current.pem -noout -subject -dates
docker exec lab-worker grep -E 'rotateCertificates|serverTLSBootstrap' /var/lib/kubelet/config.yaml
kind get kubeconfig --name lab | grep client-certificate-data | awk '{print $2}' | base64 -d | openssl x509 -noout -enddate
```

Проверено: вывод в §1 и §3.

### Шаг 1. Продление apiserver и что видит клиент

```bash
docker exec $CP openssl s_client -connect 127.0.0.1:6443 </dev/null 2>/dev/null | openssl x509 -noout -startdate
docker exec $CP kubeadm certs renew apiserver
docker exec $CP openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -startdate
docker exec $CP openssl s_client -connect 127.0.0.1:6443 </dev/null 2>/dev/null | openssl x509 -noout -startdate
```

Проверено: третья и четвёртая строки совпадают — apiserver отдаёт новый сертификат без перезапуска (§2).

### Шаг 2. Продление всего и перезапуск компонентов

```bash
docker exec $CP kubeadm certs renew all
for f in etcd kube-apiserver kube-controller-manager kube-scheduler; do
  docker exec $CP mv /etc/kubernetes/manifests/$f.yaml /root/$f.yaml; sleep 15
  docker exec $CP mv /root/$f.yaml /etc/kubernetes/manifests/$f.yaml
  until kubectl get --raw /readyz >/dev/null 2>&1; do sleep 2; done; echo "$f restarted"
done
docker exec $CP ls /etc/kubernetes/manifests          # все четыре на месте
kubectl get nodes
curl -s -o /dev/null -w '%{http_code}\n' http://orders.localhost:8088/api/orders
```

Проверено: §2; `orders: 200`.

### Шаг 3. Обслуживание узла

```bash
W=lab-worker2
( end=$(( $(date +%s)+150 )); ok=0; fail=0
  while [ $(date +%s) -lt $end ]; do
    curl -s -m 2 -o /dev/null -w '%{http_code}' http://orders.localhost:8088/api/orders | grep -q 200 && ok=$((ok+1)) || fail=$((fail+1)); sleep 0.2
  done; echo "orders during maintenance: ok=$ok fail=$fail" ) > /tmp/mnt-load.txt &
kubectl drain $W --ignore-daemonsets --delete-emptydir-data --timeout=120s
docker restart $W                                     # «перезагрузка узла»
kubectl -n kube-node-lease get lease $W -o jsonpath='{.spec.renewTime}{"\n"}'; sleep 15
kubectl -n kube-node-lease get lease $W -o jsonpath='{.spec.renewTime}{"\n"}'   # свежее время — kubelet жив
kubectl get node $W -o jsonpath='{range .status.conditions[*]}{.type}={.status} {end}{"\n"}'
kubectl -n kube-system get pods --field-selector spec.nodeName=$W
kubectl uncordon $W
wait; cat /tmp/mnt-load.txt
```

Проверено: вывод в §5.

### Уборка

Ничего не создавалось, кроме `/tmp/mnt-load.txt`: `rm -f /tmp/mnt-load.txt`.

---

## 🔥 Кейс из прода: «через год после установки кластер перестал отвечать»

**Контекст.** Кластер kubeadm для внутренних сервисов установлен год назад и с тех пор не обновлялся. В понедельник `kubectl` отвечает `x509: certificate has expired or is not yet valid`, CI не деплоит. Поды продолжают работать, но через несколько часов начинают «пропадать» endpoints, а HPA и CronJob'ы не работают.

**Разбор.**
1. На узле control plane: `kubeadm certs check-expiration` — у всех сертификатов компонентов `RESIDUAL TIME` — `<invalid>`; CA действительны.
2. apiserver не принимает клиентов со старыми сертификатами, controller-manager и scheduler не могут авторизоваться — отсюда «пропадающие» endpoints и стоящие контроллеры (01-1 §7).
3. Клиентские сертификаты kubelet при этом ротировались сами — узлы были бы в порядке, если бы apiserver работал.

**Фикс.**
- `kubeadm certs renew all` на каждом узле control plane, перезапуск etcd, apiserver, controller-manager, scheduler (шаг 2 лабы), новый `admin.conf` — администраторам.
- Регулярные обновления кластера (минимум раз в квартал — продлевают сертификаты сами, 10-2).
- Мониторинг сроков: экспортер сертификатов (x509-certificate-exporter) или проверка `kubeadm certs check-expiration` по расписанию с алертом за 30 дней.
- Runbook «сертификаты истекли» с точными командами — проверенный на стенде.

**Что запомнить.**
- Сертификаты компонентов kubeadm живут год, CA — 10 лет.
- `kubeadm upgrade apply` продлевает их автоматически; кластер без обновлений — бомба с таймером.
- После продления — перезапуск компонентов и новые kubeconfig'и у людей.

---

## 💼 Вопросы с собеседования

### 🟢 Junior

**1. Какие сертификаты есть в кластере kubeadm и сколько они живут?**
Три CA (кластер, etcd, front-proxy) на 10 лет; сертификаты apiserver, etcd, клиентские сертификаты компонентов и kubeconfig'и — на 1 год; клиентский сертификат kubelet — 1 год с автоматической ротацией.

**2. Как вывести узел на обслуживание?**
`kubectl cordon` → `kubectl drain --ignore-daemonsets --delete-emptydir-data` → работы → проверка узла и DaemonSet-подов → `kubectl uncordon`.

### 🟡 Middle

**3. Как продлить сертификаты control plane?**
`kubeadm certs check-expiration` → `kubeadm certs renew all` на каждом узле control plane → перезапуск etcd, apiserver, controller-manager, scheduler (по одному узлу) → обновить kubeconfig'и администраторов. Либо обновить кластер `kubeadm upgrade apply` — он продлевает их сам.

**4. Что будет, если истечёт клиентский сертификат kubelet?**
Kubelet не сможет авторизоваться в apiserver — узел станет NotReady, поды через 5 минут начнут выселяться (01-2). Обычно kubelet ротирует его сам через CSR; ломается при неверном времени на узле или отключённом автоодобрении.

### 🔴 Senior

**5. Почему metrics-server в kind запускают с `--kubelet-insecure-tls` и что делать в проде?**
Серверный сертификат kubelet по умолчанию самоподписанный — проверить его нечем. В проде: `serverTLSBootstrap: true` в конфиге kubelet, серверные сертификаты через CSR с автоматическим одобрением проверяющим контроллером; тогда metrics-server, `kubectl logs/exec` и мониторинг проверяют kubelet.

**6. Сменился IP узла control plane. Что сломается и как чинить?**
SAN сертификатов etcd (и, возможно, apiserver) содержат старый IP — клиенты, ходящие по IP, получают ошибки TLS; манифесты static pod'ов содержат старые адреса. Перевыпуск сертификатов `kubeadm init phase certs …` с новым `advertiseAddress`, обновление манифестов, перезапуск. Профилактика — стабильные адреса и `controlPlaneEndpoint` по DNS-имени.

**7. Как сделать перезагрузки узлов безопасными и автоматическими?**
PDB с бюджетом, graceful shutdown kubelet (05-4), kured или аналог (перезагрузка по одному узлу с drain и окном), проверка готовности по lease и DaemonSet перед uncordon, мониторинг условий узла (node-problem-detector), в облаке — замена узлов вместо обновления на месте.

---

## ⚠️ Подводные камни

- Кластер без обновлений год — истёкшие сертификаты компонентов.
- После `renew` нужен перезапуск компонентов (apiserver serving-сертификат подхватывает сам, остальные — нет).
- Копии `admin.conf` у людей сами не обновляются.
- Ротация сертификата kubelet ломается при неверном времени на узле.
- Самоподписанный серверный сертификат kubelet — проверка TLS отключена у клиентов.
- IP узла в SAN — смена адреса ломает TLS.
- `Ready` сразу после перезагрузки может быть устаревшим статусом — проверяйте lease и DaemonSet.
- Drain узла с local-томами — простой их подов.

---

## Чеклист

- [ ] Покажу сроки всех сертификатов и объясню, кто и когда их продлевает.
- [ ] Продлю сертификаты и корректно перезапущу компоненты.
- [ ] Объясню ротацию сертификата kubelet и роль `serverTLSBootstrap`.
- [ ] Перевыпущу сертификаты при смене IP.
- [ ] Проведу обслуживание узла по runbook'у без ошибок у клиентов.

---

## Задание со звёздочкой

Настройте мониторинг сроков сертификатов:

1. CronJob в `kube-system` с `hostPath` на `/etc/kubernetes/pki` и nodeSelector на control-plane: раз в сутки `kubeadm certs check-expiration` (или `openssl x509 -enddate` по каждому файлу) и выход с кодом 1, если до окончания любого меньше 30 дней.
2. Проверьте его, временно выпустив сертификат на 20 дней (`openssl` с CA кластера в отдельный файл, не трогая рабочие).
3. Как бы вы отправили алерт: метрика из CronJob (Pushgateway), событие, или x509-certificate-exporter? Сравните.

---

→ Следующая часть: **11-1. Под не работает** — модуль «Диагностика»: методика `get → describe → logs → debug` и десять сломанных подов-тренажёров на стенде: Pending, ImagePullBackOff, CrashLoopBackOff, CreateContainerConfigError, OOMKilled, Running без Ready.
