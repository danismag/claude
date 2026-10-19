# Kubernetes для DevOps: план курса

Статус: **переработка в новый формат (AGENTS.md), производство.** Утверждены план, формат (02-1, 03-2) и способ проверки «только текст» (2026-10-19); план обновлён по итогам исследования (§4а, утверждено 2026-10-19). Черновики в новом формате: 00-1, 00-2, 01-1, 01-2, 01-3 (до ревью); 02-1 и лабораторная 03-2 (после ревью, ждут правки читаемости).

Зависимости: курс Linux (процессы, cgroups, systemd), `networks/` (iptables/nftables, DNS, TLS, балансировка), курс по Docker (namespaces, образы, реестры).

---

## 1. Что меняется при переработке

Старая версия курса написана 2026-10-14 по прежним правилам. Переработка сохраняет механику, опыты и реальный вывод, но меняет подачу:

- **Убирается:** уровни-значки, «Зачем это DevOps-у», сквозной сценарий как сюжет частей, «Кейс из прода», вопросы с собеседования в частях, «Подводные камни», чеклисты, «Задание со звёздочкой», метки «Проверено» в тексте.
- **Теория** перестраивается по шести вопросам §3 AGENTS.md: задача механизма → устройство → управление → наблюдение → поломки и поиск причины → пределы и значения по умолчанию.
- **Лабораторные:** одна большая «Лаба» части делится на 2–4 работы формата §3.2 (Цель → Что понадобится → Схема опыта → Шаги → Итог → Уборка → Вопросы). Каждый шаг получает разбор команды и разбор вывода.
- **Кейсы, вопросы и подводные камни** старых частей переезжают в модуль 12: в банк вопросов, ловушки и тренажёры.
- **Возвращаются темы «Аутентификация и RBAC» (06-1) и «etcd» (10-2)**, в старой версии не опубликованные. Темы защитные: настройка прав своего кластера, бэкап и восстановление своего etcd.
- **Охват обновлён по исследованию** изменений Kubernetes 1.31–1.37 и внешних эталонов (CKA, CKAD, CKS, книги, темы собеседований) — §4а.
- **orders-api** остаётся в стенде как демо-приложение: удобная нагрузка с путями `/ready`, `/work`, `/config`. Сюжетом частей он больше не служит.
- **Карточки инструментов** (kubectl, crictl, helm, etcdctl, kubeadm, argocd) ставятся при первом появлении инструмента.

---

## 2. Охват и цели

Курс ведёт от первого `kubectl get pods` до устройства control plane, планировщика, сети узла и эксплуатации кластера. Две цели равноправны:

- **практика** — собрать, настроить и починить свой кластер и приложения в нём;
- **собеседование** — модуль 12: ~150 вопросов с эталонами, тренажёры, system design.

Версии: Kubernetes 1.36, kind 0.32, containerd 2.3, Helm 4.2, Envoy Gateway 1.9. Kubernetes 1.37 (2026-08-26, kind 0.33) на стенд не берётся: под 1.36 есть реальный вывод. Отличия 1.37 называются в тексте там, где они важны. Команды — в форме Ubuntu 24.04; отличия Manjaro названы словами и сведены в приложение B.

---

## 3. Стенд

Один стенд на весь курс, описание — `00-lab/00-1-stand.md`. Всё работает в Docker на одной машине.

```
хост 127.0.0.1
 ├─ :<порт> ─► lab-control-plane   apiserver, etcd, scheduler, controller-manager
 ├─ :8088 ──►   NodePort 30080 ──► Envoy Gateway (Gateway lab)
 │            lab-worker  lab-worker2  lab-worker3   kubelet, containerd, kube-proxy, kindnet
 └─ :5001 ──► kind-registry        registry:2.8.3 — образы стенда
```

- **Кластер** — kind 0.32, Kubernetes 1.36.1: один control-plane и три worker.
- **Реестр** — `registry:2.8.3` на `127.0.0.1:5001`, подключён к узлам.
- **Вход** — Gateway API и Envoy Gateway 1.9.2, NodePort 30080 → `127.0.0.1:8088`.
- **Дополнения** — metrics-server 0.8.0, local-path-provisioner (встроен в kind).
- **Демо-приложение** — orders-api 2.0 и PostgreSQL 17 в namespace `orders`.
- **Общие образы стенда** — `localhost:5001/orders-api:2.0` и `localhost:5001/busybox:1.37` (кладётся в 02-1); их используют многие части, поэтому они вне правила `lab-NN-M` и в уборке частей не удаляются.
- **Ресурсы** — около 2,5 ГиБ RAM на пустом стенде, до 5 ГиБ с Argo CD и CloudNativePG; около 3 ГБ диска.

Подъём не сводится к одной команде, поэтому есть `lab/lab-up.sh` и `lab/lab-down.sh` (§2 AGENTS.md). Расширения (cert-manager, Argo CD, Gitea, KEDA, CloudNativePG) ставятся командами в начале своей лабораторной и удаляются в её уборке.

### Правило имён и адресов

Чтобы части не мешали друг другу и стенду:

- **namespace** — `lab-NN-M` (например, `lab-03-2`); удаляется в уборке работы;
- **каталог файлов** — `~/lab/k8s/NN-M/`;
- **метки и taints узлов** — ключи с префиксом `lab-NN-M/`; снимаются в уборке;
- **образы** — `localhost:5001/lab-NN-M/<имя>:<тег>`;
- **namespace `orders`** работы не удаляют; если работа его меняет, уборка возвращает манифесты стенда.

---

## 4. Модули, части и лабораторные работы

Время части — ориентир: 1–2 часа чтения и около часа лабораторных. Список работ — черновой, при написании части он может уточниться; отличия записываются в §6. Значок «новое» в таблицах не ставится: что добавлено по исследованию — в §4а.

### Модуль 00. Стенд и инструменты

| Часть | Лабораторные работы |
|---|---|
| 00-1 Стенд | 1. Установка инструментов и лимиты inotify. 2. Подъём и проверка. 3. Демо-приложение. 4. Выключить и включить |
| 00-2 Инструменты | карточки kind, kubectl, crictl, k9s, stern, kubectx, krew. 1. kubectl по-взрослому. 2. На узле. 3. Внутрь пода |

### Модуль 01. Архитектура

| Часть | Лабораторные работы |
|---|---|
| 01-1 Control plane и путь запроса | 1. Объект в etcd, resourceVersion, 409. 2. Watch. 3. Остановка scheduler, controller-manager, apiserver. Теория: APF и 429, пределы масштаба |
| 01-2 Узел: kubelet, CRI, CNI | 1. Sandbox и pause. 2. cgroups и kubelet. 3. Static pod. 4. Узел без kubelet. Теория: cgroup v1 отключён с 1.35, containerd 2.x |
| 01-3 API-объекты и kubectl | 1. Client-side и server-side apply. 2. Каскадное удаление. 3. Finalizer, подресурсы, устаревшие API |

### Модуль 02. Рабочие нагрузки

| Часть | Лабораторные работы |
|---|---|
| 02-1 Pod | 1. Init-контейнер. 2. Коды выхода и сообщения. 3. Sidecar. 4. Downward API. Теория: image volume, user namespaces — ссылка на 06-2 |
| 02-2 Deployment и стратегии выкатки | 1. Rolling update и Recreate. 2. Зависший rollout и откат. 3. minReadySeconds. Теория: blue-green и canary (веса — 03-4) |
| 02-3 StatefulSet | 1. Порядок, PVC, DNS. 2. Scale и PVC. 3. Partition и сломанная ревизия |
| 02-4 DaemonSet, Job, CronJob | 1. Job: backoffLimitPerIndex, podFailurePolicy, successPolicy. 2. CronJob. 3. DaemonSet и taints |
| 02-5 Probes и завершение пода | 1. Ошибки при выкатке без preStop. 2. Grace period, preStop sleep. 3. startupProbe. 4. Liveness на БД |

### Модуль 03. Сеть

| Часть | Лабораторные работы |
|---|---|
| 03-1 Сеть подов и CNI | 1. Сеть изнутри пода. 2. tcpdump на узле. 3. SNAT и потолок подов |
| 03-2 Service и kube-proxy | 1. Service без эндпоинтов. 2. externalTrafficPolicy. 3. Завершающийся под в EndpointSlice. 4. kube-proxy nftables. Теория: ipvs устарел, v1 Endpoints и `externalIPs` устарели, trafficDistribution, LoadBalancer через cloud-provider-kind |
| 03-3 DNS в кластере | 1. ndots. 2. CoreDNS выключен. 3. Логи и своя запись |
| 03-4 Gateway API | 1. HTTPRoute и приоритет. 2. Canary весами. 3. ReferenceGrant. Теория: Gateway API 1.4–1.6, ListenerSet, TCPRoute и UDPRoute; service mesh — одна фраза |
| 03-5 TLS и миграция с Ingress | 1. TLS через cert-manager. 2. BackendTLSPolicy. 3. Ingress → Gateway API (ingress2gateway). ingress-nginx — анти-рецепт |
| 03-6 NetworkPolicy | 1. Default deny. 2. AND против OR. 3. Egress и DNS. 4. Установленное соединение. Теория: ClusterNetworkPolicy вместо ANP |

### Модуль 04. Конфигурация и данные

| Часть | Лабораторные работы |
|---|---|
| 04-1 ConfigMap и Secret | 1. Обновление: env, том, subPath. 2. Secret в etcd. 3. Шифрование в etcd (KMS v2 — теория) |
| 04-2 Хранилище: PV, PVC, CSI | 1. WaitForFirstConsumer. 2. RWO, RWOP. 3. Delete, Retain, расширение. Теория: VolumeAttributesClass, том из образа (image volume) |
| 04-3 Бэкап и восстановление | 1. Бэкап CronJob'ом. 2. Авария и восстановление. 3. Velero: бэкап namespace, сравнение со снапшотом etcd |

### Модуль 05. Ресурсы и планирование

| Часть | Лабораторные работы |
|---|---|
| 05-1 CPU, память и QoS | 1. QoS-классы и cgroup. 2. OOMKilled. 3. Троттлинг CPU. Теория: формула cpu.weight в runc 1.3.2+, PSI |
| 05-2 Ресурсы пода и квоты | 1. In-place resize. 2. Pod-level resources. 3. Квота, LimitRange, ephemeral storage. Теория: swap |
| 05-3 Планировщик | 1. Anti-affinity и spread. 2. Taints. 3. Приоритеты и вытеснение. Теория: DRA и устройства |
| 05-4 Автомасштабирование | 1. HPA без requests. 2. HPA под нагрузкой. 3. KEDA. Теория: VPA InPlaceOrRecreate, Karpenter, Cluster Autoscaler |
| 05-5 Прерывания и вытеснение | 1. Drain и PDB. 2. PDB и нездоровые поды. 3. Вытеснение kubelet по памяти |

### Модуль 06. Доступ и безопасность

| Часть | Лабораторные работы |
|---|---|
| 06-1 Аутентификация и RBAC | 1. Пользователь по сертификату. 2. Role и `auth can-i`. 3. ServiceAccount и токен. 4. Кто может читать Secret. Теория: мультитенантность |
| 06-2 Изоляция контейнера | 1. securityContext и capabilities. 2. seccomp и AppArmor. 3. User namespaces |
| 06-3 Pod Security и admission-политики | 1. Уровень restricted. 2. warn и audit. 3. ValidatingAdmissionPolicy. 4. MutatingAdmissionPolicy |
| 06-4 Аудит и политика образов | 1. Audit policy на отдельном кластере kind. 2. Разрешённые реестры. 3. Проверка подписи образа |

### Модуль 07. Пакетирование

| Часть | Лабораторные работы |
|---|---|
| 07-1 Helm: чарты и релизы | 1. Свой чарт. 2. Ожидание и откат (`--rollback-on-failure`). 3. SSA и pending-upgrade. 4. Hook |
| 07-2 Чужие чарты | 1. Установка как есть. 2. Правильная установка. 3. Источник поля, diff, upgrade. Чарт с поддерживаемыми образами вместо Bitnami |
| 07-3 Kustomize | 1. Base, overlay, генератор. 2. Helm-чарт внутри Kustomize |

### Модуль 08. GitOps

| Часть | Лабораторные работы |
|---|---|
| 08-1 Argo CD | 1. Gitea и Argo CD 3.x. 2. Application, self-heal. 3. Prune и вечный OutOfSync. 4. Откат через Git |
| 08-2 GitOps в масштабе | 1. ApplicationSet. 2. Промоушен дайджеста. 3. Удаление окружения |

### Модуль 09. Расширение API

| Часть | Лабораторные работы |
|---|---|
| 09-1 CRD и операторы | 1. Свой CRD. 2. CloudNativePG и failover |
| 09-2 Admission webhooks и finalizers | 1. Сломанный вебхук. 2. Namespace в Terminating |

### Модуль 10. Эксплуатация кластера

| Часть | Лабораторные работы |
|---|---|
| 10-1 Сборка кластера | 1. Как kind вызывает kubeadm. 2. PKI и TLS bootstrap kubelet. 3. HA control plane из трёх узлов |
| 10-2 etcd | 1. Состояние и члены. 2. Снапшот и восстановление. 3. Квота 2 ГиБ, компакция, дефрагментация. Теория: etcd 3.6 |
| 10-3 Обновление кластера | 1. Подготовка. 2. Control plane под нагрузкой. 3. Узлы. Теория: managed-кластеры EKS, GKE, AKS, Yandex |
| 10-4 Сертификаты и обслуживание узлов | 1. Продление сертификатов. 2. Обслуживание узла (drain — ссылка на 05-5) |

### Модуль 11. Наблюдаемость и диагностика

| Часть | Лабораторные работы |
|---|---|
| 11-1 Наблюдаемость кластера | 1. События и их срок жизни. 2. metrics-server и `/metrics` компонентов. 3. kube-state-metrics. 4. Логи узла и ротация |
| 11-2 Под не работает | 1. Методика на четырёх опорных поломках |
| 11-3 Сеть и DNS по слоям | 1. Методика на четырёх опорных поломках |
| 11-4 Узел и control plane | 1. kubelet и containerd. 2. apiserver и scheduler. 3. etcd |

### Модуль 12. Собеседование

- **12-1 Банк вопросов** — ~150 вопросов по разделам и уровням Junior / Middle / Senior с эталонами и ссылками на части; ловушки; «зависит, уточню». Сюда переезжают вопросы, кейсы и подводные камни старых частей и около 25 новых вопросов из исследования.
- **12-2 Тренажёры «сломай и почини»** — не меньше 30 сценариев: массовые поломки из модуля 11, RBAC, etcd, 8 новых.
- **12-3 System design** — платформа для 30 команд с мультитенантностью; поставка без простоя с откатом через GitOps; кластер в двух зонах с DR; цепочка поставки от коммита до пода; обновление флота кластеров; снижение стоимости на 30 %; GPU-платформа; миграция с ingress-nginx без простоя.
- **12-4 Матрица самопроверки**, план повторения, контрольная без подсказок.

### Приложения

A шпаргалки (kubectl, Helm, Kustomize, argocd, crictl, etcdctl, kubeadm) · B Manjaro и Ubuntu · C стенд и расширения · D глоссарий RU/EN · E что читать.

### 4а. Что изменено по исследованию (2026-10-19)

Источники — отчёты исследования: изменения Kubernetes 1.31–1.37 (release-посты, файлы feature gates, CHANGELOG) и охват (программы CKA, CKAD, CKS, книги, темы собеседований; сайты LF, O'Reilly, habr из среды агента недоступны, часть выводов не подтверждена).

- **Новые части:** 03-5 (деление 03-4), 05-2 (деление 05-1), 06-2 и 06-4, 10-1, 11-1.
- **Перенумерация:** 03-5 → 03-6; 05-2…05-4 → 05-3…05-5; 06-2 → 06-3; 10-1…10-3 → 10-2…10-4; 11-1…11-3 → 11-2…11-4.
- **Модуль 11** оставляет методику и опорные поломки; массовые сценарии переезжают в 12-2.
- **Вне курса:** Prometheus, Grafana, Loki — курс observability; Falco — security; подпись образов в пайплайне — cicd; Terraform и Cluster API — iac; service mesh — одна фраза в 03-4 и вопрос в 12-1; FinOps — задача в 12-3.

---

## 5. Способ размещения и проверки практики

**Согласован вариант А (2026-10-19).** Агент ничего не разворачивает и не запускает на машине. Варианты Б и В оставлены для справки; переход на них — только новым согласованием.

- **Вариант А, «только текст» (согласован).** Агент не запускает команд лабораторных. Реальный вывод берётся из прогона старой версии курса (2026-10-14, машина автора, Manjaro, kind 0.32.0, Kubernetes 1.36.1, containerd 2.3.1). Новые и изменённые шаги без такого вывода записываются в §7 как непроверенные; работа целиком без вывода начинается фразой «Эту работу вы выполняете сами, результаты в ней — ожидаемые».
- **Вариант Б, облачный контейнер сессии.** Docker и kind 1+3 внутри одноразового контейнера агента (Ubuntu 24.04, 4 CPU, 15 ГиБ RAM, 31 ГБ свободно; демон Docker сейчас не запущен). Узлы kind — привилегированные контейнеры, а §4 AGENTS.md запрещает их в среде агента. Вариант возможен только как явное исключение заказчика.
- **Вариант В, проверяет читатель.** Заказчик проходит лабораторные на своей машине и присылает вывод; агент вставляет его точечно (§7 п. 6 AGENTS.md).

---

## 6. Отличия от плана

- Ветка работы — `claude/youthful-babbage-p3ufp4`, а не `kubernetes`: так задано средой сессии.
- 02-1: учтены изменения 1.35 — `restartPolicy` на уровне контейнера (`ContainerRestartRules`, beta), настраиваемый потолок back-off (`KubeletCrashLoopBackOffMax`, beta), resize ресурсов через подресурс (stable).
- Строка вывода `iptables-save` в 03-2 (162 знака) оставлена целиком: разбор опирается на все её части.
- Части одного модуля пишутся параллельно, а не строго по очереди. Согласованность ссылок, терминов и уборки внутри модуля проверяет ревью модуля (§7 п. 4а AGENTS.md).
- Показ частей HTML-страницей (§7 п. 9) отменён заказчиком: части показываются в Markdown.
- План обновлён по исследованию (§4а); файлы старых частей переименованы под новую нумерацию, ссылки в черновиках нового формата переведены автоматически, смысловая проверка — на ревью.
- Правила читаемости вынесены в `00-readability-rules.md` в корне; читаемость проверяется числами (средняя длина предложения, абзацы, стоп-слова, таблицы, списки) и правится отдельным проходом ревью.
- Карточки kind и kubectl — в 00-2, Helm — в 07-1, etcdctl — в 01-1, kubeadm — в 10-1, tcpdump — в 03-1, ingress2gateway — в 03-5: в 00-1 инструменты только устанавливаются, карточка стоит там, где читатель впервые работает с инструментом. jq — без карточки, установка в 00-2.
- В прозе — «API-сервер»; `apiserver` — в коде, схемах и флагах.
- Лабораторные сверх плана: 03-1 — четыре работы (SNAT и потолок подов разделены); 03-2 — работа 5 «sessionAffinity и trafficDistribution»; 03-6 — работа 5 «Закрыть namespace orders» (в namespace `orders`, файл политик остаётся для 11-3 и 12-2); 02-2 — работа 4 «Один тег — две версии»; 02-4 — работа 2 «Indexed Job» без реального вывода; 04-2 — четыре работы.
- Модуль 05: 05-3 — пять работ (работа 5 без реального вывода); 05-2 — работа 3 в namespace `lab-05-2` и `lab-05-2q`; 05-4 — KEDA в namespace `keda` (вне правила `lab-NN-M`), уборка удаляет; 05-5 — работа 1 останавливает PostgreSQL стенда на время cordon, работа 3 правит kubelet на `lab-worker3`; подресурс `resize` требует kubectl 1.32+.
- Работы 1–2 части 04-3 идут в namespace `orders` (бэкап демо-БД стенда); уборка возвращает стенд в исходное состояние.
- Части 02-x, 03-1…03-5, 04-1, 04-2, 05-1, 05-2, 05-4, 05-5 пока меняют namespace контекста kubectl; на финальном проходе — переход на `-n lab-NN-M`.
- Служебная папка `00-production/` хранит статус производства, задания агентам, инструменты, исследования и отчёты — чтобы продолжить вне облачной сессии; в учебник не входит.
- Пробная лабораторная 03-2 вошла в часть 03-2 как работа 1, отдельный файл удалён.

---

## 7. Где и что проверено

Таблица заполняется по ходу переработки.

| Часть | Источник вывода | Версии | Что не проверено |
|---|---|---|---|
| 00-1 | прогон 2026-10-14 (lab-up 2 мин 9 с, повтор 18 с, down+up 51 с; путь через NodePort проверен из сети kind, не с хоста); ревью по документации kind и исследованию | kind 0.32.0, k8s 1.36.1 | работа 1 целиком (установка на Ubuntu, URL, вывод версий); stat -fc %T; current-context is not set; вывод docker ps, crictl ps, пустого реестра, top nodes, get gateway, get storageclass, rollout status sts; INSERT/DELETE через psql; «до 1 ГБ диска»; docker ps после lab-down; путь плагина io.containerd.cri.v1.images при containerd 2.3 с конфигом v4 |
| 00-2 | прогон 2026-10-14; ревью по исходникам kubectl 1.36, релизам на GitHub, исследованию | kind 0.32.0, k8s 1.36.1 | пакеты Manjaro krew, kubectx, stern, k9s, crictl; установка kubectx, krew, stern, k9s в Ubuntu; работа 1 шаг 11 (kuberc), -o kyaml, config view --minify, строка HTTPRoute (шаг 8); вывод kubectl tree, kubens; чтение журнала узла через API в kind; работа 2 шаги 2–6; работа 3 шаги 1, 2, 5, 6, 8, 9; «command terminated with exit code 1»; версия перехода debug на профиль general; WebSocket stable 1.35 — по исследованию |
| 01-1 | прогон 2026-10-14; ревью по kubernetes/website, коду kubernetes и исследованию | kind 0.32.0, k8s 1.36.1 | формат строк Response при -v=6 (лаба 1 шаг 1); вывод jq (лаба 2 шаг 1); «прошло 21 с» (лаба 3 шаг 4); всплеск CPU в «Рисках» лабы 3; время, за которое kubelet замечает манифест; состав /readyz?verbose |
| 01-2 | прогон 2026-10-14; ревью по документации и исследованию | kind 0.32.0, k8s 1.36.1 | переход node-monitor-grace-period 40→50 с; готовность подов после перезапуска kubelet (1.35), --config-dir, maxParallelImagePulls, nodes/configz, запрет static pods со ссылками на Secret (1.37) — по исследованию; срок отказа от запасного cgroupDriver; PLEG 1 с и 3 мин; get nodes (работа 1 шаг 3), crictl ps (работа 4 шаги 1, 3); узел дерева cgroup в работе 2 |
| 01-3 | прогон 2026-10-14; ревью по документации, metrics.go и исследованию | kind 0.32.0, k8s 1.36.1 | serverside-applied (л1 ш2); No resources found (л2 ш3); строки create/rollout status и status.replicas=4 (л3 ш2); вывод в форме jq ., fold, sed; --subresource=scale, generateName, selectableFields, порядок удаления namespace — по исследованию; предел etcd 1,5 МиБ; селекторы -l/-L без вывода |
| 02-1 | прогон 2026-10-14; ревью по kubernetes/website и коду kubernetes | kind 0.32.0, k8s 1.36.1 | порядок строк `status.conditions` (работа 1, шаг 3); хвостовой `\n` в `message` (работа 2, шаг 2); коды 137/143 для PID 1 без обработчика; команды переноса busybox в реестр стенда; поле kubelet `crashLoopBackOff.maxContainerRestartPeriod` |
| 02-2 | прогон 2026-10-14 (имена образов в выводе заменены на localhost:5001/lab-02-2/...); ревью по исходникам release-1.36 | kind 0.32.0, k8s 1.36.1 | terminatingReplicas при scale 4→2 (р1 ш4); команда замера Recreate (р1 ш3); нумерация ревизий 2,3,4→2,4,5 (р2 ш3); docker inspect RepoDigests при containerd image store; вывод crictl rmi (р4 ш2); rm -rf репозитория в kind-registry; текст ошибки maxSurge — по исходникам |
| 02-3 | прогон 2026-10-14; ревью по kube_features.go и validation.go ветки release-1.36, CHANGELOG 1.36/1.37 | kind 0.32.0, k8s 1.36.1 | rollout undo sts/web и set env (л3 ш1, ш3; в прогоне — патч), хеши ревизий заменены обозначениями; л3 ш5 maxUnavailable целиком (гейт выключен в 1.36); формат get pvc -o custom-columns; вывод getent ahostsv4; времена born в лабе 2; get controllerrevisions описан словами |
| 02-4 | прогон 2026-10-14 (работы 1, 3); ревью по job_controller.go, коду CronJob v2 | kind 0.32.0, k8s 1.36.1 | работа 2 целиком (Indexed Job, FailIndex, successPolicy, podReplacementPolicy — время замены ~10/~30 с выведено из кода); лаба 4: taint control-plane, JSON updateStrategy, cordon/uncordon; лаба 1 шаг 4 custom-columns; поведение CronJob при >100 пропусках — по коду master; jsonpath с T+= (л3 ш3) |
| 02-5 | прогон 2026-10-14; ревью по kube_features.go и prober/worker.go release-1.36 | kind 0.32.0, k8s 1.36.1 | сообщения kubectl (р1 ш1–2, р4 ш1–2); хвост error_window=0s; формат «deleted in N s» (р2 ш3); работа 2 шаг 4 целиком (pause:3.10, FailedPreStopHook); работа 4 целиком (get pods, PostgreSQL на emptyDir); объяснение TimeoutError в варианте A; переписанный load.py |
| 03-1 | прогон 2026-10-14; ревью по kindnet и плагину ptp, kube-proxy conntrack, документации Flannel и Cilium | kind 0.32.0, k8s 1.36.1 | порты Calico и шлюз 169.254.1.1 (страница Calico не открылась); FORWARD DROP от Docker; размер netshoot на диске; custom-columns в подготовке и работе 1 шаг 1; строки via 172.20.0.x (работа 1 шаг 4); работа 2: listening, захват на veth, вторая пара пакетов, awk /^$IPB /; grep KIND-MASQ-AGENT (работа 3 шаг 1); работа 4: allocatable 110, поды с hostNetwork, порядок replicas=0+scale |
| 03-2 | прогон 2026-10-14; ревью по kube-proxy release-1.36 и kubernetes/website | kind 0.32.0, k8s 1.36.1 | лаба 2: вывод шага 1, строка DROP шага 3; лаба 3: шаги 1 и 3; лаба 4: число 19 до переключения, порядок grep -m3, строки warning/configured/restarted; лаба 5: шаг 1 и уборка, имена подов из разных прогонов; уборка лабы 1; предупреждение kube-proxy 1.37 без mode; очистка UDP conntrack |
| 03-3 | прогон 2026-10-14; ревью по исходникам CoreDNS, glibc resolv, reconciler.go и printers.go | kind 0.32.0, k8s 1.36.1 | новая форма функции count и порядок A/AAAA; таблицы шагов 4–5 работы 1 сведены из таблиц старой части; resolv.conf пода dns1; сообщения kubectl run/wait; работа 2: ok after 0.0 s, строки scale/rollout; причина 0,0 с против 5,0 с; коды в журнале работы 3, head -n 3; NodeLocal DNSCache целиком; гонки conntrack в ядрах 5.x; профиль netadmin; версии CoreDNS и kube-dns после 1.40 — по исследованию; autoscaler 256/16 |
| 03-4 | прогон 2026-10-14 (ЛР1, ЛР2 ш1, ЛР3 ш1); ревью по CRD v1.6.1 и матрице совместимости Envoy Gateway | kind 0.32.0, k8s 1.36.1 | ЛР1 ш2 строка ResolvedRefs; ЛР2 ш2–3 (50/50, 0/100, 100/0), вес 0 в Envoy Gateway; ЛР3 ш2–3; коды 503 и 504; сборка образа 2.1 и вывод rollout в подготовке; канал experimental CRD 1.6.1; применение xDS без разрыва соединений |
| 03-5 | прогон 2026-10-14 (ЛР1 шаги 3–5, ЛР3 шаги 1–2); ревью по спецификации Gateway API, cert-manager 1.21, ingress2gateway 1.0 | kind 0.32.0, k8s 1.36.1 | ЛР1 шаг 1 вывод apply/rollout; ЛР1 шаг 2 helm list и gatewayAPI.enabled (прогон был с enableGatewayAPI); порядок условий https-shop; ЛР1 шаг 6 восстановление секрета; ЛР2 целиком (BackendTLSPolicy в Envoy Gateway 1.9.2); ЛР3 таблица get ingress, шаги 3–5 (ingress2gateway); слияние listener в один слушатель Envoy; подхват Secret без перезапуска; сроки CA/B Forum; ARI в cert-manager 1.21 |
| 03-6 | прогон 2026-10-14; ревью по kind main.go, kube-network-policies, network-policy-api v0.2.0 | kind 0.32.0, k8s 1.36.1 | р1 ш4 nft list table; время в выводе р2 и р3; р4 сообщения kubectl и метка role=echo; р5 команда проверки выхода наружу; запрос через 127.0.0.1:8088; CNP в Cilium 1.19–1.20 — по исследованию; ordered namespace deletion GA 1.34 |
| 04-1 | прогон 2026-10-14; ревью по validation.go, pod_workers.go, metrics.go, документации шифрования и KMS | kind 0.32.0, k8s 1.36.1 | KMS v2 (теория); автоперезагрузка шифрования; вывод шага 5 работы 3 (transformer_prefix); путь immutable: во втором отказе (работа 2); od -c в шаге 4 работы 3 сжат; grep (шаг 3) и список манифестов (шаг 6) работы 3 описаны словами; sed по шаблону --etcd-servers=.* с FLAG/MNT/VOL |
| 04-2 | прогон 2026-10-14; ревью по kubernetes/website и коду release-1.36 | kind 0.32.0, k8s 1.36.1 | работа 3 целиком (узел тома остановлен); работа 1 шаг 2 custom-columns и jsonpath; отступы get sc; работа 2 шаг 2 строки awk; работа 4 шаг 2 Available; строки NotFound; отказ kubelet второму поду RWOP с nodeName на local-path — из кода; image volume и containerd 2.1+, VolumeGroupSnapshot GA 1.36, flex-volume в kubeadm 1.36 — по исследованию; dd 1,9 ГБ/с |
| 04-3 | прогон 2026-10-14 (работы 1–2: бэкап, авария, RTO 18 с); ревью по документации и исходникам Velero 1.18 | kind 0.32.0, k8s 1.36.1 | работа 3 целиком (Velero 1.18.4 + VersityGW v1.8.0, совместимость с k8s 1.36 ожидаемая, Kopia и CRC32, xattr под emptyDir, архив velero, etcdutl в образе etcd 3.6); сообщения kubectl delete в работе 2; уборка с DELETE; jsonpath узла PV (работа 1 шаг 4) |
| 05-1 | прогон 2026-10-14; ревью по opencontainers/cgroups, kubelet policy.go и helpers_linux.go, документации | kind 0.32.0, k8s 1.36.1 | runc --version в узле kind; вес 1 CPU по новой формуле (блог 102, расчёт ~100); нижняя граница oom_score_adj Burstable (код 3, документация 2); JVM MaxRAMPercentage, ActiveProcessorCount, Node --max-old-space-size; окно kubectl top ~15 с; учёт троттлинга под/контейнер; лаба 1 шаги 2 и 4 в новой форме; порядок строк ctr (лаба 3 шаг 3) |
| 05-2 | прогон 2026-10-14 (старая 05-1: resize, квота, LimitRange, ephemeral); ревью по kube_features.go release-1.36, KEP-2837 | kind 0.32.0, k8s 1.36.1 | лаба 1 шаг 1 cpu.max из контейнера; лаба 2 целиком (pod-level resources: QoS, memory.max, OOMKilled у b, resize пода); жертва OOM по лимиту пода — по KEP-2837; правило Guaranteed для spec.resources; задержка освобождения квоты; порядок LimitRanger и ResourceQuota; выселение по ephemeral-storage за 20–25 с — замер старой части |
| 05-3 | прогон 2026-10-14; ревью по исходникам scheduler release-1.36 (PodTopologySpread, очередь, kube_features.go) | kind 0.32.0, k8s 1.36.1 | работа 5 целиком (SchedulingGated, снятие шлюза, расклады Ignore/Honor, DRA без устройств); объяснение зависшего rollout пустым доменом control-plane выведено из алгоритма; работа 3 шаг 4 untainted и колонка TAINTS; работа 4 PRIO 100 и сокращённые колонки; заголовок ZONE (работа 1); порт метрик 10259 |
| 05-4 | прогон 2026-10-14 (ЛР2 шаги 3–4, ЛР3 шаг 2); ревью по horizontal.go, defaults.go, kube_features.go, документации VPA, CA, Karpenter, KEDA | kind 0.32.0, k8s 1.36.1 | metrics.k8s.io v1 GA в 1.37; год релиза VPA 1.6.0; единицы минимума памяти VPA; ЛР1 шаг 3; ЛР2 шаг 1 сообщение и переписанные функции шага 2; ЛР3 шаги 1 и 3; поле tolerance на 1.36; HPAScaleToZero; CA и Karpenter — теория |
| 05-5 | прогон 2026-10-14; ревью по документации и исходникам kubelet, Eviction API, kubectl drain | kind 0.32.0, k8s 1.36.1 | PSI stable 1.36 — по исследованию; влияние swap на memory.available; метрики kubelet_evictions и kube_poddisruptionbudget_status_pod_disruptions_allowed; аннотации safe-to-evict и do-not-disrupt; terminated-pod-gc-threshold 12 500; лаба 1 служебные строки drain и «200 after 2s»; лаба 2 get pdb sick; лаба 3 YAML mkp, configz, condition met |
| 06-2 | прогон 2026-10-14 (работа 1 шаг 2); ревью по коду containerd 2.x, kubelet, документации user namespaces и AppArmor | kind 0.32.0, k8s 1.36.1 | лаб. 1 шаги 1, 3, 4 (маска, ip_unprivileged_port_start=0 в kind, вывод id/ls); лаб. 2 целиком (событие при отсутствующем seccomp-профиле, отказ AppArmor в kind); лаб. 3 целиком (userns в kind 0.32 на ядре ≥ 6.3, uid_map и ps); overhead RuntimeClass — иллюстративный |
| 06-3 | прогон 2026-10-14 (лабы 1–3); ревью по admissionregistration v1 types.go, validation.go, defaults.go, коду pod-security-admission | kind 0.32.0, k8s 1.36.1 | лаба 4 (MutatingAdmissionPolicy) целиком; строки created/labeled/condition met (лаба 1 шаг 2, лаба 2 шаг 1, лаба 3 шаг 1); достаточность sleep 3 для MAP; exemptions PSA в kind через extraMounts и kubeadmConfigPatches; таблица Kyverno/Gatekeeper |
| 06-4 | реального вывода нет (новая часть); ревью по документации kube-apiserver, audit.go, kind 0.32, sigstore/cosign releases | kind 0.32.0, k8s 1.36.1 | все три работы целиком: патч kind v1beta4 с extraArgs, grep audit в манифесте, вывод kind create cluster, jq лабы 1; CEL has() ? map : [] и сложение списков в 1.36; тексты Warning и Forbidden от VAP; задержка вступления политики ~3 с; поля Kyverno ClusterPolicy; COSIGN_PASSWORD='', вывод cosign verify, тег sha256-<hex>.sig в registry:2.8.3; доступность GitHub Releases из РФ |
| 07-1 | прогон 2026-10-14; ревью по исходникам и release notes Helm 4.0–4.3 | kind 0.32.0, k8s 1.36.1 | право watch для --wait в Helm 4; ЛР1 шаг 4 порядок kind в template; ЛР2 шаги 2 и 4 вывод rollback/history; ЛР3 шаги 1–4 (число конфликтов, повтор без флага, единственный владелец, get secret -L status); ЛР4 шаг 4 get hooks; values.schema.json, helm package/push --plain-http, установка из OCI, helm test; установка helm на Ubuntu |
| 07-3 | прогон 2026-10-14; ревью по исходникам kustomize v5.8.1 (kusttarget_configplugin.go), go.mod kubectl 1.36 | kind 0.32.0, k8s 1.36.1 | порядок строк grep сборки staging (лаба 1 шаг 2); configmap created (лаба 1 шаг 3); порядок строк prod (лаба 2 шаг 2); строка imageID (лаба 2 шаг 3); grep -A1/-c и счётчик 0 (лаба 3 шаг 4); отсутствие namespace у объектов helmCharts на 5.8.1 — замер автора; pacman -S kustomize; вывод Kustomize Version v5.8.1 |

Новые части и разделы §4а реального вывода не имеют: их работы начинаются фразой «Эту работу вы выполняете сами…». Непроверенное в старой версии: установка на Ubuntu; kubectx, kubens, stern, k9s, krew; CronJob «too many missed start times»; LoadBalancer в kind; NodeLocal DNSCache; `ingress2gateway`; KMS v2; снапшоты CSI; Prometheus Adapter, Cluster Autoscaler, Karpenter; graceful node shutdown; MutatingAdmissionPolicy; `helm push` в OCI и `helm diff`; UI Argo CD, генератор `pullRequest`, ESO, SOPS, Sealed Secrets; pluto и kubent; managed-кластеры.

---

## 8. Статус согласования

- [x] План курса (2026-10-19)
- [x] Правки плана по исследованию: стенд на 1.36, новые части и разделы, вынос тем в другие курсы (2026-10-19)
- [x] Формат пробной части 02-1 и пробной лабораторной 03-2 (2026-10-19)
- [x] Способ размещения и проверки практики — вариант А «только текст» (2026-10-19)
- [ ] Производство всех частей — идёт
- [ ] Согласование готового курса → слияние в `main`
