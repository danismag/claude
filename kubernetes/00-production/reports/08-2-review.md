# Ревью 08-2 «GitOps в масштабе»

Файл: /home/user/claude/kubernetes/08-gitops/08-2-gitops-at-scale.md. Режим «только текст»: сверка по документации argo-cd master, коду контроллера ApplicationSet, README и страницам релизов проектов. Команды не запускались.

## Стыковка с 08-1 (по закоммиченному файлу 08-1, по решению ведущего)

- Репозиторий: было `~/lab/k8s/gitops` → стало `$R=~/lab/k8s/08-1/orders-gitops` (во всех командах работ).
- Пароль Gitea: было `~/lab/k8s/gitea.env` → стало `~/lab/k8s/08-1/gitea.env`.
- repoURL: было `gitea.gitea.svc:3000` → стало `gitea.lab-08-1.svc:3000` (как в 08-1).
- `gpush`: теперь определяется точно как в 08-1 (переменные `R`, `GIT_URL`).
- Overlays: 08-1 делает только staging (namespace `lab-08-1-staging`). Подготовка 08-2 копирует overlay prod из `~/lab/k8s/07-3/orders-api/overlays/prod` и переводит оба overlay в `lab-08-2-staging` / `lab-08-2-prod` (sed по строке `namespace:`). Namespace `lab-07-3-*` в работах больше не используются; шаблон ApplicationSet — `lab-08-2-{{ .path.basename }}`. Строка вывода шага 1 работы 3 `resources in lab-07-3-staging: 0` стала `resources in lab-08-2-staging: 0` — это подпись из echo, число из старого прогона.
- Подготовка: удаление Application `orders-staging` и namespace `lab-08-1-staging` с `--ignore-not-found` — на случай пропущенной уборки 08-1; если читатель делал полную уборку 08-1 — повторить шаги 1–4 работы 1.
- Уборка работы 3 — полная уборка стенда GitOps: root → ApplicationSet → `delete -n argocd -f install.yaml` v3.5.5 → `delete ns argocd lab-08-1 lab-08-2-staging lab-08-2-prod` → CRD → `rm -rf ~/lab/k8s/08-1 ~/lab/k8s/08-2` → `unset -f gpush; unset GIT_URL GITEA_USER GITEA_PASS R O D t0` → проверка `clean` и `200`. На неё ссылается необязательный блок уборки 08-1.

## Найденные ошибки (было → стало)

1. Работа 3 шаги 3–4: изменение ApplicationSet коммитилось, но применяет его `root`, который опрашивает Git раз в 180 с; аннотация refresh ставилась только на ApplicationSet, `sleep 20` → finalizer ещё на месте, и «защищённое» удаление было бы каскадным. Стало: `annotate app root argocd.argoproj.io/refresh=normal`, проверка поля в кластере (`.spec.syncPolicy.preserveResourcesOnDeletion` / `.applicationsSync`) до удаления каталога; шаг 3 разделён на шаг 3 (включить, проверить finalizer) и шаг 4 (удалить каталог), старый шаг 4 стал шагом 5. Схема опыта и «Итог» обновлены.
2. «ApplicationSet не забирает чужие Application» (таблица подготовки, ответ 1 работы 1, §5 «Application не создаётся») — неверно. В коде (`createOrUpdateInCluster` → `controllerutil.SetControllerReference`, `utils/createOrUpdate.go` без проверки владельца) одноимённый Application без владельца забирается и переписывается по шаблону. Стало: §2 — абзац об усыновлении; вопрос 1 работы 1 переписан; в §5 — «принадлежит другому ApplicationSet или два набора дают одно имя» и «ручная правка Application откатывается».
3. `argocd appset generate` «рендерит локально» → отправляет ApplicationSet на сервер Argo CD, генераторы работают на сервере; нужен `argocd login` или `--core`.
4. Kargo: «переносы (Freight)» → Warehouse упаковывает версии во Freight (набор ревизий), Stage — цель, Promotion — перенос; применяет Argo CD.
5. Хеш `3c1a9f0` (выдуман) → «короткий хеш коммита, у каждого свой».
6. Шаг 5 (create-update): «ошибочный статус» → ожидаемо `Unknown` и условие `ComparisonError`; добавлена проверка, что политика применена.
7. Ожидаемый вывод finalizer'ов «(пусто или [])» → пустая строка (поле отсутствует), с объяснением механизма замены finalizer'ов.
8. Схемы перенумерованы подряд (1–12) после добавления двух новых.

## Дополнения теории (по заданию)

- §2: ownerReference и усыновление; опрос генератора git раз в 3 мин, `requeueAfterSeconds`, `ARGOCD_APPLICATIONSET_CONTROLLER_REQUEUE_AFTER`, аннотация `application-set-refresh`.
- §2 кластерный генератор: параметры `nameNormalized`, `project`; без селектора локальный кластер выбирается.
- §3 секреты: схема трёх путей; ESO — SecretStore/ClusterSecretStore, ExternalSecret, `refreshInterval` (0 = создать один раз); SOPS — ключ данных и мастер-ключи, `.sops.yaml`, версия v3.13.3; Sealed Secrets — режимы strict/namespace-wide/cluster-wide, `--key-renew-period` (0 выключает), старые ключи не удаляются, `kubeseal --re-encrypt`, смена ключа ≠ ротация паролей, v0.40.0.
- §3 Image Updater: объект `ImageUpdater` (README), v1.3.1. Flux: линия 2.9 (2.9.6), ResourceSet — во Flux Operator (ControlPlane), не в самом Flux; строка таблицы дополнена.
- §4: условие `RolloutProgressing` только при RollingSync.
- §5: схема цепочки удаления, поиск причины (событие `Deleted` на ApplicationSet, журнал контроллера, `git log` по `argocd/`).
- §6: генератор git 180 с, webhook ApplicationSet — GitHub и GitLab; версии SOPS, Image Updater, Flux, Sealed Secrets.

## Читаемость

До: 234 предложения, средняя 11,3 слова, коротких 35 %, нарушений 0. После: 269 предложений, средняя 11,8, коротких 31 %, нарушений 0 (три нарушения после дополнений — 2 предложения >25 слов и абзац из 6 — исправлены). Прозы (без кода и таблиц) около 4,7 тыс. слов вместе с лабораторными.

## Подтверждено (источник)

- applicationsSync: значения create-only/create-update/create-delete/sync, по умолчанию sync; `--policy` приоритетнее поля; `--enable-policy-override` по умолчанию false; `--dryrun true`; create-only/create-update не защищают от удаления самого ApplicationSet — finalizer на ApplicationSet и background-каскад — docs/operator-manual/applicationset/Controlling-Resource-Modification.md.
- preserveResourcesOnDeletion: finalizer не ставится — Application-Deletion.md и applicationset/utils/utils.go (`RenderTemplateParams`); у существующих Application finalizer заменяется на шаблонный (`found.Finalizers = generatedApp.Finalizers`, сохраняются только pre/post-delete) — applicationset_controller.go.
- Условия ErrorOccurred, ParametersGenerated, ResourcesUpToDate (+RolloutProgressing при RollingSync) — applicationset_controller.go.
- pullRequest: провайдеры GitHub, GitLab, Gitea, Bitbucket Server/Cloud, Azure DevOps; Gitea owner/repo обязательны, api, tokenRef; requeueAfterSeconds 1800; branch_slug RFC 1123 ≤50; labels только goTemplate; webhook — только GitHub и GitLab — Generators-Pull-Request.md, Generators-Git.md.
- Кластерный генератор: параметры, метка `argocd.argoproj.io/secret-type: cluster`, локальный кластер — Generators-Cluster.md.
- `argocd appset generate` — docs/user-guide/commands/argocd_appset_generate.md (флаги `-o`, `-N`, `--core`).
- Sealed Secrets: 30 дней, `--key-renew-period`, старые ключи не удаляются, `--re-encrypt`, scopes — README; v0.40.0 (10.09.2026) — страница релизов.
- SOPS v3.13.3 (23.07.2026), Image Updater v1.3.1 (08.10), Flux v2.9.6 (01.10.2026) — страницы релизов GitHub. Image Updater CR `ImageUpdater` — README проекта.
- Kargo: Warehouse/Freight/Stage/Promotion — docs/50-user-guide/10-core-concepts.
- ResourceSet — README flux-operator (ControlPlane).
- ESO v2.13.0, API v1, v1beta1 снят в 0.17; Flux 2.7/2.8; Source Hydrator git note 3.3; CVE 3.3.15/3.4.10/3.5.4; Helm 4 в 3.5 — research-k8s-changes.md (не перепроверялось).

## Не подтверждено (для 00-plan §7)

- 08-2 работа 3 шаги 2–5: вывод не снимался (возврат Application, снятие finalizer у существующего Application на живом стенде, число 3 уцелевших объектов, принятие ресурсов без пересоздания подов, `Unknown`/`ComparisonError` при create-update и отсутствующем пути).
- 08-2 подготовка: копирование overlay prod 07-3 в репозиторий 08-1 и смена namespace через sed не прогонялись; состав staging overlay после работ 2–4 08-1 (HPA и т. п.) не сверен.
- 08-2 работа 1 шаг 3: строка `prod replicas=…` печатается новой командой jsonpath (в старой части другой код); работа 2: строка `after 6s` печатается новым echo.
- 08-2 теория: событие `Deleted` на ApplicationSet — по коду контроллера, не проверено вживую; механика SOPS (ключ данных, `.sops.yaml`) — по общей документации, getsops.io не открывался; значение `refreshInterval` по умолчанию ESO не названо (в документации нет).
- 08-2: `sed … a\` с `\n` — GNU sed (Ubuntu и Manjaro — GNU, ок).
