# Ревью 07-3 «Kustomize»

Файл: /home/user/claude/kubernetes/07-packaging/07-3-kustomize.md. Старая версия: `git show e755ced:kubernetes/07-packaging/07-3-kustomize.md`. Отчёта писателя нет (контейнер перезапустился), поэтому сомнительными считались весь вывод, которого нет в старой версии, и все версии. Режим «только текст»: читались файлы, `git show`, документация через WebFetch (raw.githubusercontent.com, github.com/kubernetes-sigs/kustomize). Правки скриптом из scratchpad. Коммита нет.

Файл завершён целиком: есть все блоки до `## → Дальше` (строка 1036 до правок), три лабораторные с Итогом, Уборкой и Вопросами, `<details>` закрыты.

## Найденные ошибки (было → стало)

1. Порядок трансформеров (§2, схема 3): «patches → namespace → labels → images → replicas → replacements», «Патчи идут раньше `images` и `replicas`» → «… labels → replicas → images → replacements», «`replicas` — раньше `images`». Источник: kustomize v5.8.1 api/internal/target/kusttarget_configplugin.go (PatchStrategicMerge, Patch, Namespace, Prefix, Suffix, Label, Annotations, PatchJson6902, ReplicaCount, ImageTag, Replacement).
2. Устаревшие поля (§6): упоминались только `commonLabels` и `vars` → список `bases`→`resources`, `patchesStrategicMerge`/`patchesJson6902`→`patches`, `commonLabels`→`labels`, `vars`→`replacements` (будет удалено), `imageTags`→`images`; предупреждение и `kustomize edit fix`. Источник: api/types/kustomization.go (комментарии Deprecated, строки Warning, FixKustomization).
3. Карточка Kustomize, неполнота: не было `kustomize edit` → добавлены `kustomize edit set image` и `kustomize edit fix` в «Команды для скриптов» с пояснением, что подкоманда есть только в отдельном бинарнике. В «Частые ошибки» добавлен случай Helm 4 при Kustomize старше 5.8.1.
4. Установка: не было строки вывода `Kustomize Version` и актуальной версии отдельного бинарника → «`kubectl version --client` строкой `Kustomize Version`… v5.8.1»; «последняя версия — 5.8.3 (октябрь 2026)»; 5.8.1 исправила namespace и добавила поддержку Helm 4. Строка URL 119 знаков → переменная `V` и перенос внутри кавычек.
5. helmCharts и версии Helm: не было требований к Helm → «Kustomize принимает Helm 3 и Helm 4, проверяет `helm version --short`; Helm 4 — с Kustomize 5.8.1; флаг `--helm-command`». Источник: api/internal/builtins/HelmChartInflationGenerator.go v5.8.1 (checkHelmVersion: «requires helm V3 or V4»), release notes v5.8.1 («addressed the breaking changes introduced in helm v4»). В «Что понадобится» лабы 3 — пометка, что встроенный Kustomize поддерживает Helm 4.2.
6. generatorOptions: было только `disableNameSuffixHash` → добавлены `labels`, `annotations`, `immutable` и как считается хэш (имя + `data`, у Secret ещё `type`; первые 10 знаков SHA-256 с заменой символов). Источник: api/types/generatoroptions.go, api/hasher/hasher.go.
7. replacements: добавлено, что без существующего поля сборка падает с `unable to find field … in replacement target`, а `options: {create: true}` разрешает создать поле. Источник: api/filters/replacement/replacement.go.
8. Prune и Endpoints (§5, лаба 1 шаг 5): «prune перебирает все типы» → «перебирает типы из встроенного списка, Endpoints в нём есть»; добавлено, что prune по списку типов в альфе, ApplySet включается `KUBECTL_APPLYSET=true`. Источник: website declarative-config.md.
9. Лаба 2 шаг 2: порядок строк вывода `image` перед `SHUTDOWN_DELAY` → `SHUTDOWN_DELAY` перед `image` (kustomize выводит поля по алфавиту: env < envFrom < image < resources; старая часть давала строки без порядка).
10. Лаба 2 шаг 3: команда с jsonpath 161 знак → разбита на склеиваемые строки в одинарных кавычках; вторая команда (101 знак) перенесена. В вывод добавлена ожидаемая строка `imageID` (`localhost:5001/orders-api@sha256:ad4f8fd2…`), о которой говорит разбор.

## Читаемость

До: 226 предложений, средняя 11,5 слова, коротких (<10) 35 %, >25 слов — 6, нарушений 13 (6 длинных предложений, 4 абзаца по 6 предложений, 3 строки кода >100).
После: 242 предложения, средняя 11,4 слова, коротких 34 %, >25 слов — 0, нарушений 0. Длинные предложения разделены (строки 7, 66, 176, 212, 308, 1036), абзацы из 6 предложений разбиты по смыслу (32, 292, 304, 308), строки кода ≤100 знаков (проверено подсчётом символов). Эмодзи, «Проверено», вопросов собеседования, чеклистов нет; блоки §3 по порядку; после каждого `##` есть фраза.

## Подтверждено (источник)

- kubectl 1.36 встраивает kustomize v5.8.1 (api v0.21.1) — kubernetes release-1.36 staging/src/k8s.io/kubectl/go.mod.
- 5.8.0 — регрессия распространения namespace, 5.8.1 её завершила; 5.8.2 (30 сент.) добавила `edit add configuration`, `edit remove component`; 5.8.3 (8 окт.) — последняя — releases kubernetes-sigs/kustomize.
- `must specify --enable-helm` — HelmChartInflationGenerator.go; совпадает со старой частью.
- Версии API `kustomize.config.k8s.io/v1beta1` и компонентов `v1alpha1` — kustomization.go.
- Суффикс хэша 10 знаков — hasher.go.
- Порядок генераторов ConfigMap → Secret → HelmChartInflation — kusttarget_configplugin.go.
- Коды выхода `kubectl diff` 0/1/>1, `-l` с `--prune`, ApplySet alpha с 1.27 — website.
- Все строки вывода лабораторных совпадают со старой частью (хэши `hcdt7bmb5c`, `65k4tf7cd9`, `pruned`, `diff exit: 1`, `replicas=3 grace=40 cpu=250m`, ошибки helmCharts, пустой `helm list`), кроме перекомпоновки и строк, перечисленных ниже.
- Версия Helm стенда 4.2.2 — 07-1; Gateway `lab` в `envoy-gateway-system`, порт 8088 — 00-1.
- Пункты research-k8s-changes.md для 07-3 (kustomize 5.8.1, Argo CD 3.5.4 и `helmGlobals.configHome`) учтены; строка о CVE Argo CD (3.3.15/3.4.10/3.5.4) соответствует исследованию.

## Замечания без правки

- План 00-plan §4 для 07-3 называет две работы (base/overlay/генератор; Helm внутри Kustomize), в части три: добавлена «Prod: патчи, образ по дайджесту, diff». Отклонение оправдано (патчи — ядро части), записать в 00-plan как отличие от плана.
- 08-1 (ещё старого формата) берёт каталог `~/lab/k8s/kustomize/orders-api`, а новая 07-3 кладёт его в `~/lab/k8s/07-3/orders-api`. При переработке 08-1 путь нужно согласовать.

## Не подтверждено (для 00-plan)

- Лаба 1 шаг 2: точный порядок строк `grep` по сборке staging выведен из алфавитного порядка полей kustomize, в старой части был вывод `sort | uniq -c`.
- Лаба 1 шаг 3: строка `configmap/orders-env-hcdt7bmb5c created` выведена из хэша старой части, отдельно не снималась.
- Лаба 2 шаг 2: порядок строк (SHUTDOWN_DELAY перед image) — по алфавитной сортировке полей, не снят на стенде.
- Лаба 2 шаг 3: строка `imageID` — ожидаемая, в старой части только «нужный дайджест».
- Лаба 3 шаг 4: команды `grep -A1` и `grep -c` новые; результат `0` выведен из факта старой части «нет metadata.namespace».
- Отсутствие namespace у объектов helmCharts при Kustomize 5.8.1 — замер автора; в документации и release notes причина не найдена (5.8.1 заявляет исправление распространения namespace).
- Argo CD 3.5.4+ не учитывает `helmGlobals.configHome` и CVE remote ref — только по research-k8s-changes.md, релизные заметки Argo CD не открывались.
- `sudo pacman -S kustomize` в Manjaro (пакет в extra) — не сверялось.
- Вывод `kubectl version --client` со строкой `Kustomize Version: v5.8.1` — по go.mod, на стенде не снимался в новой части.
