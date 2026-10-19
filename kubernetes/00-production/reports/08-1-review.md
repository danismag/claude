# Ревью 08-1 Argo CD

Файл: /home/user/claude/kubernetes/08-gitops/08-1-argocd.md. Режим «только текст»: команды лабораторных не запускались; сверка — WebFetch документации и манифестов argoproj/argo-cd на теге v3.5.5, страницы релизов (19.10.2026), старой версии части (e755ced). Копия до правок: /tmp/claude-0/-home-user-claude/740afa2c-c313-5763-bb73-bdca3fdc2abb/scratchpad/rv081/before.md.

## Найденные ошибки (было → стало)

1. Опрос Git: «раз в 180 с (`timeout.reconciliation`) с небольшим разбросом» → 120 с (`timeout.reconciliation`) плюс до 60 с (`timeout.reconciliation.jitter`), не реже раза в 3 минуты. Исправлено в §3 «Доставка», §6 «Числа», ЛР2 шаг 4 разбор 1, ответ ЛР2 вопрос 1 (argocd-cm.yaml v3.5.5: «Two minutes by default with additional jitter», jitter 60s). Замер 178 с с этим согласуется.
2. Webhook: «Gitea, GitHub и GitLab умеют это» → документация называет GitHub, GitLab, Bitbucket, Azure DevOps и Gogs (webhook.md: Gitea в списке нет).
3. Retry: «по документации интервал стартует с 5 с, удваивается и ограничен 3 минутами» (как значения по умолчанию) → «пример из документации задаёт 5 попыток с паузой от 5 с, удвоение, потолок 3 минуты»; auto_sync.md: retry включается разделом `retry` («To enable, configure the retry field»).
4. `argocd app delete` в карточке: «каскад зависит от finalizer» → «по умолчанию с его объектами» (argocd_app_delete.md: `--cascade` default true). В §5 «Удаление Application» добавлено: правило про finalizer касается `kubectl delete`, CLI удаляет каскадом по умолчанию.
5. Установка CLI: файл `cli_checksums.txt` упоминался, но не проверялся → добавлена сверка `sha256sum --ignore-missing -c`, загрузка в /tmp с удалением после установки (релиз v3.5.5: ассеты `argocd-linux-amd64`, `cli_checksums.txt` есть).
6. CVE: «закрыли критичные уязвимости. Одна… Две другие…» → «четыре критичные»; добавлена четвёртая (чтение файлов через импорт Jsonnet), уточнено, что команды выполнялись в repo-server (GHSA-9v9p-x54c-58gc, GHSA-fw5c-w8rc-j7fx, GHSA-m3vr-7329-44ww, GHSA-fmxq-cgp8-87wp).
7. §3 «Порядок»: «CVE октября 2026 показала, что hooks удаления — место для ошибок политики» (вывод писателя) → факт: через hooks удаления обходили ограничения проекта, версия должна быть не ниже исправленной.
8. Режим `--core`: «Ему нужен текущий namespace argocd» → «документация перед входом ставит в контексте namespace argocd» (core.md показывает это примером, жёсткого требования не формулирует).
9. Решение ведущего — уборка ЛР4: шаг 3 «Убрать всё» → «Убрать приложение»: обязательны logout, остановка порт-форварда, удаление Application и namespace `lab-08-1-staging`, `unset -f k refresh`, проверка. Удаление Argo CD (install.yaml), namespace `argocd` и `lab-08-1`, `~/lab/k8s/08-1`, `gpush` и переменных, образа Redis — необязательный блок «если идёте в 08-2 — пропустите; полная уборка стенда GitOps — в конце 08-2». Согласованы: вводный абзац лабораторных, «Надолго ли» и «Откат» в Рисках ЛР1, «Уборка» ЛР1, «Цель», «Итог» и «Уборка» ЛР4.

## Расхождения с 08-2 (файл 08-2 не трогал; нужно согласовать одну из частей)

08-2 (подготовка лабораторных, строки ~310–345, ЛР1 и уборка) ожидает стенд старой 08-1, а новая 08-1 создаёт другие имена:

| Что | 08-1 (новая) | Ожидает 08-2 |
|---|---|---|
| Локальный репозиторий | `~/lab/k8s/08-1/orders-gitops` | `~/lab/k8s/gitops` |
| Файл пароля Gitea | `~/lab/k8s/08-1/gitea.env` | `~/lab/k8s/gitea.env` |
| Namespace Gitea | `lab-08-1` | `gitea` (repoURL `gitea.gitea.svc:3000`, уборка `delete ns gitea`) |
| Функция `gpush` | на `$R` и `$GIT_URL` | переопределяет на `~/lab/k8s/gitops` — сработает только при совпадении пути |
| Overlays в репозитории | только `staging`, свой (namespace `lab-08-1-staging`, хост `staging.lab081.localhost`); после ЛР4 — без route и HPA | `staging` и `prod` из 07-3, namespace `lab-07-3-staging` и `lab-07-3-prod` |
| Application из 08-1 | удаляется в ЛР4 шаг 3 | 08-2 удаляет `orders-staging --ignore-not-found` — совместимо |
| Порт-форвард 8443, pid-файл | остановлен в ЛР4 | 08-2 CLI `argocd` в лабораторных не использует — совместимо |
| Уборка 08-2 | — | не удаляет `ns lab-08-1` и `~/lab/k8s/08-1`; удаляет `gitea` и `~/lab/k8s/gitea.env` |

Итог: без правки 08-2 (пути `~/lab/k8s/08-1/...`, namespace `lab-08-1`, repoURL `gitea.lab-08-1.svc`, добавление overlay prod из 07-3 в репозиторий, уборка `lab-08-1` и `~/lab/k8s/08-1`) работы 08-2 со стенда после новой 08-1 не пойдут. Проще поправить 08-2: имена 08-1 соответствуют правилу `lab-NN-M` и записи в 00-plan (строка «08-1 — Argo CD в namespace argocd, Gitea в lab-08-1»).

## Читаемость

Скрипт до: 250 предложений, средняя 11,8 слов, коротких 34 %, >25 слов 0, нарушений 0. После: 261 предложение, средняя 11,8, коротких 34 %, нарушений 0 (одно длинное предложение из новой правки разделено). Строки кода ≤100 символов. Блоки §3 по порядку, эмодзи и «Проверено» нет, после каждого `##` есть фраза, ссылки (01-1, 01-3, 02-2, 05-4, 07-1, 07-3, 09-1) существуют по плану.

## Подтверждено (источник)

- v3.5.5 — Latest от 12.10.2026, без security-раздела; 3.5.4/3.4.10/3.3.15 (06.10) закрыли CVE; 3.4.11, 3.3.16 актуальны; 3.6.0 — rc3 (страница релизов).
- Установка `kubectl apply -n argocd --server-side --force-conflicts -f …/v3.5.5/manifests/install.yaml`, причина — ApplicationSet CRD > 262144 байт (upgrading/3.2-3.3.md).
- Redis в install.yaml 3.5.5: `redis:8.2.3-alpine` с заменой имени на `public.ecr.aws/docker/library/redis` (manifests/base/redis: deployment + kustomization images newName).
- Семь нагрузок: base включает application-controller, dex, repo-server, server, redis, notification, applicationset-controller.
- Аннотация `argocd.argoproj.io/tracking-id`, формат `app:group/Kind:namespace/name`, annotation — по умолчанию, параметр `application.resourceTrackingMethod` (resource_tracking.md, upgrading/2.14-3.0.md).
- 3.0: здоровье ресурсов не хранится в `status.resources` (`controller.resource.health.persist`, default false), RBAC `logs, get`, update/delete без подресурсов, репозитории только в Secret, default resource.exclusions (upgrading/2.14-3.0.md, argocd-cmd-params-cm.yaml).
- 3.5: Helm 4, `helm.version: v3` игнорируется, impersonation на все операции API-сервера (upgrading/3.4-3.5.md).
- Пауза между волнами 2 с (`ARGOCD_SYNC_WAVE_DELAY`), волна по умолчанию 0, фазы PreSync/Sync/PostSync/SyncFail/PreDelete/PostDelete (sync-waves.md).
- Обработчики 20 статусов / 10 операций (argocd-cmd-params-cm.yaml).
- Rollback при auto-sync невозможен; автосинк не повторяет упавшую ревизию; `allowEmpty` false (auto_sync.md, application.yaml).
- CLI: ассет `argocd-linux-amd64`, `cli_checksums.txt` в релизе; Arch `pacman -S argocd` (cli_installation.md).
- Webhook `/api/webhook` (webhook.md).

## Не подтверждено (для 00-plan)

- Весь вывод `argocd` (login, version, app get, history, rollback) — ожидаемый, CLI в старом прогоне не использовался.
- ЛР1 шаг 3 таблица подов — ожидаемый вид (реальны 54 с, ImagePullBackOff Redis, toomanyrequests).
- ЛР2 шаг 1 порядок и имена ресурсов в списке; шаг 2 значение tracking-id в кластере — по формату документации.
- ЛР3 шаг 3 команда `get events -o custom-columns | grep` — новая, строки из старого прогона.
- ЛР4 шаг 2 текст отказа rollback; шаг 3 обязательная проверка `get ns … || echo clean` и необязательный блок `delete -f install.yaml` — не прогонялись.
- Default resource.exclusions включает EndpointSlice — по исследованию, в upgrading/2.14-3.0.md названы Endpoints и Lease.
- Значения retry (5 с, ×2, 3 мин) — пример из application.yaml, не значения по умолчанию полей.
- Требование namespace `argocd` в контексте для `--core` — пример документации.
- Ресурсы «до 5 ГиБ RAM» — из плана, без замера.
