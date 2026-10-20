# Приложение E. Что читать

Назначение: выбрать, что читать после каждого модуля курса, чтобы закрепить практику и подготовиться к собеседованию.

## Как пользоваться

Читайте источник после соответствующего модуля, а не вместо него. Документацию проектов берите для версий стенда, а если страница переехала, ищите её по названию на сайте проекта. На стенде стоят Kubernetes 1.36, kind 0.32, containerd 2.3, Helm 4.2, Envoy Gateway 1.9 и Argo CD 3.5. У книг указаны только название, авторы, издание и год, ссылок на магазины в списке нет. Оглавления книг курс не пересказывает, потому что их не удалось сверить с первоисточником.

## E.1. Официальная документация Kubernetes

Документация kubernetes.io делится на четыре типа страниц, и каждый тип отвечает на свой вопрос.

- **Concepts** (https://kubernetes.io/docs/concepts/) — как устроен объект и какие у него значения по умолчанию. Разделы: workloads, services-networking, storage, scheduling-eviction, configuration, security, cluster-administration, extend-kubernetes.
- **Tasks** (https://kubernetes.io/docs/tasks/) — пошаговые рецепты: настроить пробы, освободить узел командой drain, обновить кластер.
- **Reference** (https://kubernetes.io/docs/reference/) — точные поля API, справочник kubectl, список feature gates. Совпадает с выводом `kubectl explain`.
- **Блог и заметки релизов** (https://kubernetes.io/blog/, https://kubernetes.io/releases/) — что изменилось в версии: удалённые API, новые значения по умолчанию.

Страницы о версиях и обновлениях, к которым возвращаются чаще всего:

- Политика совместимости версий — https://kubernetes.io/releases/version-skew-policy/ (10-3).
- Руководство по устаревшим API — https://kubernetes.io/docs/reference/using-api/deprecation-guide/ (10-3).
- Feature gates — https://kubernetes.io/docs/reference/command-line-tools-reference/feature-gates/ (все модули).
- Релиз 1.36 — https://kubernetes.io/blog/2026/04/22/kubernetes-v1-36-release/ (стенд курса).
- Выход ingress-nginx из поддержки — https://kubernetes.io/blog/2025/11/11/ingress-nginx-retirement/ (03-5).

Страницы о механизмах, на которые часто ссылаются части курса:

- Pod Security Standards — https://kubernetes.io/docs/concepts/security/pod-security-standards/ (06-3).
- Приоритеты и справедливость запросов (APF) — https://kubernetes.io/docs/concepts/cluster-administration/flow-control/ (01-1).
- Безопасная остановка узла — https://kubernetes.io/docs/tasks/administer-cluster/safely-drain-node/ (05-5, 10-4).

## E.2. KEP и CHANGELOG

**KEP** (Kubernetes Enhancement Proposal) — документ, который объясняет, зачем появилась функция и как она устроена. Лежат в https://github.com/kubernetes/enhancements. **CHANGELOG** — список изменений каждой версии в https://github.com/kubernetes/kubernetes/tree/master/CHANGELOG.

KEP, на которые ссылается курс:

- KEP-753 «Sidecar Containers», нативные sidecar-контейнеры, GA в 1.33 (02-1).
- KEP-1287 «In-place Update of Pod Resources», resize пода на месте, GA в 1.35 (05-2).
- KEP-1040 «Priority and Fairness for API Server Requests», APF (01-1).
- KEP-752 «EndpointSlice API», GA в 1.21 (03-2).
- KEP-4020 «Unknown Version Interoperability Proxy», прокси смешанных версий, beta в 1.36 (10-3).

Читайте раздел «Motivation» и «Graduation Criteria». Первый отвечает на вопрос «зачем», второй показывает, в какой версии функция стала beta и GA. Для заметок к версии откройте CHANGELOG и перейдите к разделам Deprecation и Urgent Upgrade Notes.

Исходный код контроллеров лежит в `pkg/controller/` репозитория kubernetes/kubernetes: node lifecycle, deployment, endpointslice. Он отвечает на вопросы «через сколько» и «почему именно так».

## E.3. Книги

Список короткий и отобран по темам курса, а в каждой записи указано, к каким частям книга подходит.

- Marko Lukša, Kevin Conner, «Kubernetes in Action», 2-е изд. (Manning, 2026). Объекты и контроллеры в подробностях: поды, Service, тома, Deployment, StatefulSet, DaemonSet, Job. Примеры к изданию: https://github.com/luksa/kubernetes-in-action-2nd-edition. Подходит к модулям 02–04.
- Josh Rosso, Rich Lander, Alex Brand, John Harris, «Production Kubernetes» (O'Reilly, 2021). Платформа для команд: сеть, хранилище, безопасность, мультитенантность. Подходит к модулям 06, 10 и к system design в 12-3.
- Brendan Burns, Joe Beda, Kelsey Hightower, Lachlan Evenson, «Kubernetes: Up and Running», 3-е изд. (O'Reilly, 2022). Быстрый обзор для повторения всего курса.
- Bilgin Ibryam, Roland Huß, «Kubernetes Patterns», 2-е изд. (O'Reilly, 2023). Паттерны приложений: probes, init и sidecar, Job, оператор, конфигурация. Примеры: https://github.com/k8spatterns/examples. Подходит к модулям 02, 05, 09.
- Nigel Poulton, «The Kubernetes Book» (издаётся ежегодно). Компактное введение для новичка. Подходит как первое чтение перед модулем 01.

Для безопасности и эксплуатации дополнительно:

- Liz Rice, «Container Security», 2-е изд. (O'Reilly, 2025). Что изолирует контейнер и что нет. Подходит к 06-2.
- «Site Reliability Engineering» и «The Site Reliability Workbook» (Google, бесплатно: https://sre.google/books/). SLO, инциденты, постмортемы. Подходит к 12-3.

## E.4. Kubernetes the Hard Way

**Kubernetes the Hard Way** (https://github.com/kelseyhightower/kubernetes-the-hard-way) — пошаговая сборка кластера руками. Лабораторные охватывают jumpbox, центр сертификации и TLS-сертификаты, kubeconfig, шифрование данных, bootstrap etcd, control plane, рабочие узлы и сеть подов.

Что она даёт курсу. Модуль 10 показывает, как kubeadm делает то же самое автоматически (10-1). После Hard Way PKI, статические поды и TLS bootstrap перестают быть магией. Читайте её после 10-1, до 10-4.

## E.5. Программы экзаменов CKA, CKAD, CKS

Программы публикует CNCF: https://github.com/cncf/curriculum. Они служат чеклистом тем и показывают веса доменов.

- **CKA** (Certified Kubernetes Administrator) — администрирование кластера: установка, хранилище, сеть, диагностика. Диагностика занимает самый большой вес. Подходит к модулям 10 и 11.
- **CKAD** (Certified Kubernetes Application Developer) — приложения: workloads, конфигурация, probes, Service, безопасность подов. Подходит к модулям 02, 04, 05.
- **CKS** (Certified Kubernetes Security Specialist) — безопасность: RBAC, Pod Security, audit, цепочка поставки. Подходит к модулю 06.

Веса доменов меняются, поэтому берите текущую редакцию из репозитория. На октябрь 2026 года программы CKA и CKAD описаны для Kubernetes 1.37, а CKS — для 1.34. Формулировки в курсе сверены по зеркалам программы, а не по самим PDF.

## E.6. Документация инструментов курса

Версии документации берите те же, что на стенде, и читайте разделы, которые названы в таблице модулей из E.8.

Стенд и работа с кластером:

- kind — https://kind.sigs.k8s.io/
- kubectl и плагины: krew — https://krew.sigs.k8s.io/; crictl — https://github.com/kubernetes-sigs/cri-tools
- Helm — https://helm.sh/docs/
- Kustomize — https://kubectl.docs.kubernetes.io/references/kustomize/
- Argo CD — https://argo-cd.readthedocs.io/en/stable/

Сеть и сертификаты:

- Gateway API — https://gateway-api.sigs.k8s.io/
- Envoy Gateway — https://gateway.envoyproxy.io/docs/
- ingress2gateway — https://github.com/kubernetes-sigs/ingress2gateway
- cert-manager — https://cert-manager.io/docs/

Данные, рантайм и масштабирование:

- CloudNativePG — https://cloudnative-pg.io/docs/1.30/
- Velero — https://velero.io/docs/
- etcd — https://etcd.io/docs/
- containerd — https://containerd.io/docs/
- metrics-server — https://github.com/kubernetes-sigs/metrics-server
- KEDA — https://keda.sh/docs/
- Karpenter — https://karpenter.sh/docs/

Статьи по темам, где документация проекта особенно полезна:

- Argo CD: Sync Options — https://argo-cd.readthedocs.io/en/stable/user-guide/sync-options/ (вечный OutOfSync, волны, prune).
- Argo CD: Diffing — https://argo-cd.readthedocs.io/en/stable/user-guide/diffing/ (игнорирование полей).
- Argo CD: ApplicationSet — https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/ (генераторы).
- Helm 4: страница «Helm 4 Overview» — https://helm.sh/docs/overview/ (отличия от Helm 3, server-side apply).

## E.7. Разборы инцидентов

**k8s.af** (https://k8s.af, Kubernetes Failure Stories) — собрание публичных постмортемов. Читайте их как кейсы: контекст, цепочка событий, исправление. Типовые темы:

- перегрузка API-сервера и etcd;
- истёкшие сертификаты;
- DNS и conntrack;
- нехватка памяти и вытеснение;
- вебхуки, которые блокируют весь кластер;
- обновления кластеров.

После модуля 11 берите один разбор в неделю. Ищите слой, где всё сломалось: под, сеть, узел или control plane (11-2, 11-3, 11-4). Блоги проектов (Cilium, Envoy, CNCF) разбирают поведение под нагрузкой.

## E.8. Что читать по модулям

Таблицы показывают источник и тему. Документация проектов дана названием раздела, а полные адреса — в E.1 и E.6.

### Модули 00–03

Базовые модули: стенд, архитектура, рабочие нагрузки и сеть.

| Модуль | Что читать | Зачем |
|---|---|---|
| 00 Стенд | kind: Quick Start, Configuration | подъём кластера, порты, реестр |
| 00 Стенд | Reference: kubectl | команды и флаги |
| 01 Архитектура | Concepts: Cluster Architecture | роли компонентов |
| 01 Архитектура | Concepts: API Priority and Fairness | 429 и пределы масштаба |
| 02 Нагрузки | Concepts: Workloads | Pod, Deployment, StatefulSet, Job |
| 02 Нагрузки | Tasks: Configure Liveness, Readiness and Startup Probes | пробы и завершение |
| 03 Сеть | Concepts: Services, Load Balancing, and Networking | Service, DNS, EndpointSlice |
| 03 Сеть | Gateway API: Guides | HTTPRoute, TLS, веса |
| 03 Сеть | cert-manager: Concepts, ACME | выпуск сертификатов |

### Модули 04–07

Конфигурация, ресурсы, безопасность и пакетирование.

| Модуль | Что читать | Зачем |
|---|---|---|
| 04 Данные | Concepts: Storage | PV, PVC, StorageClass, снапшоты |
| 04 Данные | Tasks: Encrypting Confidential Data at Rest | шифрование Secret в etcd |
| 04 Данные | Velero docs | бэкап namespace |
| 05 Ресурсы | Concepts: Scheduling, Preemption and Eviction | scheduler, PDB, выселение |
| 05 Ресурсы | Concepts: Horizontal Pod Autoscaling | HPA и поведение |
| 06 Безопасность | Concepts: Role Based Access Control Good Practices | права и ServiceAccount |
| 06 Безопасность | Tasks: Auditing | audit policy |
| 07 Пакеты | Helm: Chart Template Guide | шаблоны и hooks |
| 07 Пакеты | Kustomize: Reference | base, overlay, patches |

### Модули 08–12

GitOps, расширение API, эксплуатация, диагностика и собеседование.

| Модуль | Что читать | Зачем |
|---|---|---|
| 08 GitOps | Argo CD: Sync Options, ApplicationSet | волны, prune, генераторы |
| 09 Расширение | Concepts: Custom Resources | CRD и валидация |
| 09 Расширение | CloudNativePG docs | оператор PostgreSQL |
| 10 Эксплуатация | kubeadm: Certificate Management, Upgrading | сертификаты и обновление |
| 10 Эксплуатация | etcd docs: Operations | снапшот, квота, defrag |
| 11 Диагностика | Tasks: Troubleshooting Applications, Troubleshooting Clusters | методика поиска причины |
| 12 Собеседование | k8s.af, SRE Workbook | разборы инцидентов |
| 12 Собеседование | Hard Way, программы CKA/CKAD/CKS | самопроверка |

## E.9. Смежные курсы репозитория

Некоторые темы курс только упоминает, а разбирают их соседние курсы.

- `networks/` — сеть Linux под Kubernetes: netns, veth, iptables и nftables, conntrack, DNS, TLS.
- `cicd/` — конвейер до кластера: сборка, подпись, сканирование образов, push против pull.
- `observability/` — Prometheus, Grafana, Loki, алерты и SLO.
- `security/` — Falco и поведенческий анализ.
- `iac/` — Terraform и Cluster API.

---

Связанные приложения: A (шпаргалки), B (Manjaro и Ubuntu), C (стенд и расширения), D (глоссарий RU/EN).
