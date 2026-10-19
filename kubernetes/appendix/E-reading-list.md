# Приложение E. Что читать

> Отобрано под цели курса: работа и собеседование. Читайте после соответствующего модуля, а не вместо него. Версии и издания — на октябрь 2026; для документации проектов читайте версию, совпадающую с вашим кластером.

---

## E.1. Документация (основа)

| Что | Зачем | После модуля |
|---|---|---|
| kubernetes.io/docs — Concepts (Workloads, Services, Storage, Scheduling) | первоисточник по поведению объектов и дефолтам | 02–05 |
| kubernetes.io/docs/reference — API reference, `kubectl` reference, feature gates | точные поля и флаги; совпадает с `kubectl explain` | все |
| Kubernetes Release Notes и блог (kubernetes.io/blog) | что изменилось в версии: удалённые API, новые дефолты (пример — `node-monitor-grace-period` 40 → 50 с) | 10 |
| Version Skew Policy | правила совместимости версий | 10-2 |
| kubeadm: Upgrading, Certificate Management | обновление и сертификаты self-hosted | 10 |
| Gateway API (gateway-api.sigs.k8s.io) + Envoy Gateway docs | маршруты, роли, политики; таймауты и поведение Envoy | 03-4, 11-2 |
| etcd docs: Operations guide (hardware, maintenance, disaster recovery) | кворум, квота, defrag, бэкап и восстановление (часть 10-1 курса не опубликована — читать здесь) | 01-3, 10 |
| Helm docs (helm.sh) — Helm 4 changes | отличия от Helm 3, SSA | 07 |
| Argo CD docs — Sync options, Diffing, ApplicationSet | вечный OutOfSync, волны, генераторы | 08 |
| CloudNativePG docs | архитектура, failover, бэкапы и восстановление PostgreSQL | 09-1 |

## E.2. Книги

| Книга | Зачем |
|---|---|
| Marko Lukša, «Kubernetes in Action», 2-е изд. (Manning) | глубокое объяснение объектов и контроллеров — лучший «учебник» после курса |
| Josh Rosso и др., «Production Kubernetes» (O'Reilly) | платформа для команд: мультитенантность, сеть, хранилище, безопасность — к 12-3 |
| Brendan Burns и др., «Kubernetes: Up and Running», 3-е изд. (O'Reilly) | быстрый обзор для повторения |
| Bilgin Ibryam, Roland Huß, «Kubernetes Patterns», 2-е изд. (O'Reilly) | паттерны приложений: sidecar, init, оператор, конфигурация |
| Liz Rice, «Container Security» (O'Reilly) | что изолирует контейнер и что нет — к 06-2 |
| Betsy Beyer и др., «Site Reliability Engineering» и «The Site Reliability Workbook» (Google, бесплатно онлайн) | SLO, инциденты, постмортемы — для Senior-интервью |

## E.3. Глубже: KEP'ы и исходники

- **KEP'ы** (github.com/kubernetes/enhancements) — почему фича устроена так. Полезные:
  - sidecar containers (KEP-753);
  - in-place resize подов (KEP-1287);
  - API Priority and Fairness (KEP-1040);
  - EndpointSlice (KEP-752).
- **Исходники** контроллеров — `pkg/controller/` в kubernetes/kubernetes: node lifecycle, deployment, endpointslice. Отвечают на вопрос «через сколько и почему».

## E.4. Разборы инцидентов

- **k8s.af** (Kubernetes Failure Stories) — сборник публичных постмортемов: DNS, OOM, etcd, вебхуки, обновления. Читайте как кейсы курса: контекст → разбор → фикс.
- Постмортемы крупных компаний о Kubernetes — ищите по «kubernetes outage postmortem» + год. Типовые темы:
  - перегрузка apiserver;
  - etcd;
  - сертификаты;
  - cgroups;
  - DNS conntrack.
- Блоги проектов (Cilium, Envoy, CNCF) — разбор производительности и поведения под нагрузкой.

## E.5. Практика и подготовка к собеседованию

- **CKA / CKAD / CKS** (Linux Foundation) — программа экзаменов как чеклист тем. Практические задания похожи на тренажёры 12-2. CKA — администрирование (10, 11), CKAD — приложения (02, 04, 05), CKS — безопасность (06).
- **killer.sh** — симулятор экзаменов CKA/CKAD/CKS (входит в покупку экзамена).
- **Kubernetes the Hard Way** (Kelsey Hightower, GitHub) — собрать кластер вручную. Лучший способ понять сертификаты и компоненты (01, 10).
- Свой стенд курса — повторять тренажёры 11-1, 11-2 и 12-2 на время. Это ближе всего к live-собеседованию.

## E.6. Смежные курсы этого репозитория

| Курс | Что взять |
|---|---|
| `networks/` | сеть Linux под Kubernetes: netns, veth, iptables/nftables, conntrack, DNS, TLS (08-x — Kubernetes-сеть) |
| `cicd/` | конвейер до кластера: сборка, подпись, сканирование, push vs pull деплой (05-3) |
| `git-docker/` | образы и контейнеры: слои, multi-stage, безопасность образа |
