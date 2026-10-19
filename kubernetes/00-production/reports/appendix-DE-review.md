# Ревью приложений D и E

Файлы: kubernetes/appendix/D-glossary.md, kubernetes/appendix/E-reading-list.md. Режим «только текст», без commit. Части курса не правились.

## D. Глоссарий: метод

Скрипт сверил все 367 записей с жирными определениями в частях. 238 записей совпали по термину и номеру части. Остальные 129 проверены вручную: найдено, где и в какой форме термин введён (падеж, английское слово жирным, определение без жирного). Так проверено больше 60 записей, в том числе все спорные пары.

## D. Найденные ошибки (было → стало)

- Песочница пода: «пустой контейнер pause, держит network namespace» (так в 02-1) → «набор общих namespaces пода; его держит процесс pause» (01-2 §«Sandbox и контейнер pause»). Исправлено и в блоке «Как пользоваться».
- Под (Pod): (01-1) → (02-1). В 01-1 жирного определения нет, оно в 02-1:31.
- Job: (01-2) → (02-1). В 01-2 Job не упоминается.
- PersistentVolume: (01-1) → (02-3). В 01-1 PV нет; первое определение в 02-3:84, полное в 04-2.
- emptyDir: (02-1) → (04-2). В 02-1 emptyDir не упоминается.
- Плоскость управления: «узлы и компоненты…» (00-1) → «компоненты…» (01-1). В 00-1 control plane назван узлом, определение глоссария взято из 01-1.
- Листовой сертификат: «сертификат компонента» (10-4) → «подписан CA и сам других не подписывает» (10-1:121).
- Компакция: (01-1) → (10-2) с пометкой, что в 01-1 она названа «уплотнением».
- Garbage collector images (раздел G) → «Сборка мусора образов» (image GC) в разделе С: так термин назван в 01-2:195.
- Добавлена запись «Ревизия Deployment» (02-2:64): в частях три разные ревизии (etcd, Deployment, релиз Helm), в глоссарии было две.
- Хук Helm в «Как пользоваться»: «работает при установке релиза» → «в заданный момент жизни релиза: установка, обновление, откат, удаление» (07-1 §Hooks, схема с pre/post-upgrade).
- Хук Argo CD: добавлены фазы PreDelete и PostDelete, как в 08-1:225. Источник: argo-cd docs/user-guide/sync-waves.md (7 типов: PreSync, Sync, Skip, PostSync, SyncFail, PreDelete, PostDelete).
- Hook, Pod sandbox, Runtime sandbox: убран повторный номер части в конце записи («(08-1) (08-1)»).
- Вытеснение в «Как пользоваться»: «Вытеснение kubelet'ом по давлению — это eviction» → прямо сказано, что в 05-5 так назван node-pressure eviction, но это eviction: под удаляет kubelet.

## D. Подтверждено

- Разведение пар: выселение (eviction, 05-5) / вытеснение (preemption, 05-3:278); песочница пода (01-2:79) / песочница рантайма (06-2:42); хук Helm (07-1:128) / хук Argo CD и волны (08-1:223–225).
- Числа совпадают с частями: cpu.weight 1–10000, по умолчанию 100 (05-1:124); очередь отсрочки 1–10 с (05-3:52); heartbeat 100 мс, election timeout 1000 мс (10-2); NodePort 30000–32767 (03-2); около 40 контроллеров (01-1:71); NoSwap по умолчанию (05-2:159); kuberc с 1.34 (00-2:125).

## D. Расхождения в частях (не правились)

- 05-5: заголовок «Прерывания и вытеснение», строка 50 («В курсе „вытеснением“ называют и preemption, и node-pressure eviction»), строки 62 и 118 («вытеснение по давлению», «Вытеснение kubelet»). Это противоречит разведению eviction/preemption в глоссарии и в module-notes.md:38. Нужно заменить на «выселение по давлению» и переписать строку 50.
- 01-1:368 называет compaction «уплотнением», 10-2:118 — «компакцией». Нужен один термин.
- 02-3: нет жирного определения StatefulSet. Оно есть только в 00-1:1074.
- 02-1:60 определяет песочницу иначе, чем 01-2:79 («пустой контейнер pause» против «набора namespaces, который держит pause»). Стоит сослаться на 01-2.
- 00-1:92 определяет control plane как «управляющий узел», 01-1:31 — как компоненты.
- В 01-1 нет жирных определений Pod, watch, Admission. Admission впервые выделен жирным в 00-2:279, watch — в 00-2:450.

## E. Найденные ошибки (было → стало)

- Kubernetes in Action, 2-е изд.: «Marko Lukša (Manning)» → «Marko Lukša, Kevin Conner (Manning, 2026)». Источник: страница Manning (по результатам поиска).
- Production Kubernetes: «Josh Rosso и соавторы» → «Josh Rosso, Rich Lander, Alex Brand, John Harris» (O'Reilly, 2021).
- Kubernetes Patterns, 2-е изд.: добавлен год 2023.
- Container Security: добавлено «2-е изд. (O'Reilly, 2025)». Источник: O'Reilly, октябрь 2025.
- KEP: добавлены официальные названия и стадии из kep.yaml. 753 Sidecar Containers, GA 1.33. 1287 In-place Update of Pod Resources, GA 1.35. 1040 Priority and Fairness for API Server Requests. 752 EndpointSlice API, GA (v1 в 1.21). 4020 Unknown Version Interoperability Proxy, beta 1.36. Номера у писателя были верными.
- CloudNativePG: https://cloudnative-pg.io/documentation/current/ → https://cloudnative-pg.io/docs/1.30/. Сайт перешёл на схему /docs/<версия>/, а на стенде CNPG 1.30.1 (C-lab-stand).
- Helm 4: «найдите на helm.sh по названию» → страница «Helm 4 Overview», https://helm.sh/docs/overview/ (helm/helm-www docs/overview.md, sidebar_label «Helm 4 Overview»).
- E.8: «Tasks: Horizontal Pod Autoscale» → «Concepts: Horizontal Pod Autoscaling» (страница переехала в concepts/workloads/autoscaling). «Concepts: Security, RBAC Good Practices» → «Role Based Access Control Good Practices». «Tasks: Debug Applications, Debug Clusters» → «Troubleshooting Applications, Troubleshooting Clusters».
- E.5: добавлены текущие версии программ: CKA и CKAD v1.37, CKS v1.34 (github.com/cncf/curriculum).
- E.1: «выселить узел» → «освободить узел командой drain».

## E. Подтверждено (источник)

- kubernetes.io не резолвится, поэтому страницы проверены по raw.githubusercontent.com/kubernetes/website. Version Skew Policy, Deprecated API Migration Guide, feature-gates (feature-gates/index.md), Pod Security Standards, API Priority and Fairness, Safely Drain a Node существуют. Блог 1.36 датирован 2026-04-22 со slug kubernetes-v1-36-release. Блог ingress-nginx-retirement датирован 2025-11-11.
- Названия в E.8 совпадают с front matter: Scheduling, Preemption and Eviction; Configure Liveness, Readiness and Startup Probes; Encrypting Confidential Data at Rest; Auditing.
- Argo CD: страницы sync-options, diffing, operator-manual/applicationset есть в argoproj/argo-cd docs.
- Kubernetes the Hard Way: состав лабораторных в README совпадает с описанием в E.4.
- Репозиторий cncf/curriculum, примеры KiA 2e (luksa/kubernetes-in-action-2nd-edition) открываются.
- Up and Running, 3-е изд.: Burns, Beda, Hightower, Evenson, O'Reilly, 2022.
- Ссылки на части (01-1, 02-1, 03-2, 03-5, 05-2, 05-5, 06-2, 06-3, 10-1, 10-3, 10-4, 11-2…11-4, 12-3) совпадают с картой курса и темами частей.

## Читаемость

- D до и после: 7 предложений прозы, средняя длина 11,9 слова, коротких 29 %, 22 нарушения. Все нарушения — длинные списки по буквам и списки из одного пункта, это допустимо для глоссария. Жирный занимает 10,5 % текста, потому что каждая запись начинается с жирного термина.
- E до правок: средняя длина 9,7, коротких 57 %, 3 нарушения (предложение в 30 слов, списки из 8 и 16 пунктов). После: средняя длина 10,8, коротких 46 %, 0 нарушений. Список E.1 разбит на две группы, E.6 — на три группы с вводными фразами, рубленые предложения сшиты.

## Осталось неподтверждённым (для 00-plan)

- Адреса kind, krew, Helm, Kustomize, Argo CD, Gateway API, Envoy Gateway, cert-manager, Velero, etcd, containerd, KEDA, Karpenter, k8s.af, sre.google: DNS из среды агента не резолвится, адреса не открывались.
- https://helm.sh/docs/overview/: адрес выведен из пути docs/overview.md в helm-www, сам сайт не открывался.
- https://cloudnative-pg.io/docs/1.30/: адрес взят из поисковой выдачи, сам сайт не открывался.
- Год выхода Kubernetes in Action 2e (2026) и Container Security 2e (2025): взяты из поисковой выдачи (Manning, O'Reilly), страницы не открывались.
- Издание The Kubernetes Book (ежегодное) не уточнялось.
