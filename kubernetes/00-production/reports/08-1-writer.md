# Отчёт писателя: 08-1 Argo CD
Файл: /home/user/claude/kubernetes/08-gitops/08-1-argocd.md (переписан поверх старой версии). Команд на машине не запускалось.

## Заголовки
Где мы на карте; 1 Какую задачу решает Argo CD (GitOps: желаемое состояние в Git; Push и pull; Чего Argo CD не делает); 2 Как устроен (Компоненты; Application; Цикл сверки; Два статуса; Отслеживание объектов); 3 Как управлять (Карточка инструмента: argocd; Политика синхронизации; Порядок применения: волны и hooks; Доставка изменений из Git; Проекты и доступ); 4 Как увидеть состояние (Статус Application; Вывод CLI; Логи и интерфейс); 5 Что ломается (ComparisonError; Изменение из Git не доехало; Вечный OutOfSync; Ручные правки не держатся; Удаление Application); 6 Пределы (Версии и безопасность; Что менялось в 3.x; Числа по умолчанию; Масштаб); Лабораторные работы: ЛР1 Gitea и Argo CD (5 шагов, Риски), ЛР2 Application, self-heal и опрос Git (4 шага), ЛР3 Prune и вечный OutOfSync (4 шага, Риски), ЛР4 Откат через Git и уборка (3 шага); → Дальше.

## Объём
Скрипт читаемости: 250 предложений в абзацах, средняя длина 11,8 слов, >25 слов нет, нарушений 0. Проза абзацев около 3000 слов, со списками около 3600. Лабораторные не резались.

## Решения
- Версия Argo CD закреплена v3.5.5 (сверено WebFetch по странице релизов 19.10.2026: 3.5.5 от 12 окт — без новых advisories; 3.5.4/3.4.10/3.3.15 закрыли CVE; 3.6.0 пока только rc3).
- Gitea в namespace `lab-08-1`, приложение в `lab-08-1-staging`, Argo CD в `argocd` (отступление от lab-NN-M: install.yaml жёстко ссылается на namespace argocd; оговорено в тексте). Файлы в ~/lab/k8s/08-1/ (пароль Gitea ~/lab/k8s/08-1/gitea.env). Base копируется из ~/lab/k8s/07-3/orders-api/base; overlay staging написан заново (хост маршрута staging.lab081.localhost).
- Уборка удаляет всё (Argo CD, Gitea) в конце ЛР4; ЛР1–3 оставляют установку. 08-2 после этого должна ставить Argo CD/Gitea заново (сослаться на ЛР1 08-1) — согласовать при написании 08-2.
- Контекст kubectl не меняется; функция `k` для lab-08-1, `unset -f` в уборке.
- CLI `argocd` входит через port-forward с pid-файлом; режим `--core` описан и не используется (требует смены namespace контекста).

## Сомнительные места
- Весь вывод и все команды `argocd` (login, version, app get, history, rollback) — ожидаемые; в старой части CLI не использовался. Формат строк `'admin:login' logged in successfully`, `Context ... updated`, `Sync Status: Synced to main (...)`; текст отказа rollback при auto-sync дан словами.
- Аннотация tracking-id и формат значения `app:group/Kind:ns/name` (ЛР2 шаг 2) — по памяти документации; в тексте старой части не проверялось.
- ЛР1 шаг 3: таблица подов — ожидаемый вид; реальны только «54 с», Redis в ImagePullBackOff и ошибка toomanyrequests. Утверждение, что Dex «не поднялся» в старом прогоне, перенесено как «кроме Redis и Dex».
- Redis 8.2.3-alpine для v3.5.5 — из старой части; в install.yaml 3.5.5 тег не сверялся.
- ЛР3 шаг 3: команда `get events -o custom-columns ... | grep` новая; строки вывода из старой части (в старой не было команды); в ЛР3 шаг 1 текст «No resources found in ... namespace.» — стандартное сообщение kubectl.
- ЛР2 шаг 1: порядок/имя ConfigMap в списке ресурсов (orders-env-…) и порядок строк — ожидаемые; в старой было «четыре ресурса Synced».
- ЛР4 шаг 3: удаление через `kubectl delete -n argocd -f install.yaml` и проверка `grep ... || echo clean` — не прогонялось; предполагается, что у Application нет finalizer.
- Числа «по документации», не сверены: jitter опроса (в тексте названо «небольшой разброс»), пауза между волнами 2 с, обработчики контроллера 20/10, retry 5 с ×2 до 3 мин, `allowEmpty`, поведение «автосинк не повторяет упавшую ревизию».
- 3.0: здоровье ресурсов не пишется в status.resources по умолчанию — по research, не сверено с upgrading/2.14-3.0.md.
- Установка CLI: имя файла `argocd-linux-amd64`, файл `cli_checksums.txt` в релизе, пакет `argocd` в Manjaro — по памяти.
- CVE: названия уязвимостей из WebFetch страницы релизов (GHSA, CVE-2026-77459 в текст не вынесены); утверждение «hooks удаления — место ошибок политики» — вывод из advisory.
- 3.5.5+… в `argocd version` — формат условный.
- Время/ресурсы: «до 5 ГиБ RAM» взято из плана; собственных замеров нет.

## Что выкинуто или перенесено (в модуль 12)
Кейс: «OutOfSync каждые 3 минуты, реплики пилит» (HPA+selfHeal; фикс: убрать replicas из Git, ignoreDifferences + RespectIgnoreDifferences, точечно по managedFieldsManagers).
Вопросы: push vs pull; Synced/OutOfSync и Healthy/Degraded; selfHeal и prune; почему изменение доезжает через минуты (180 с, webhook, refresh); откат в GitOps (revert, UI/rollout undo не держатся); вечный OutOfSync как разбираться; права для 30 команд (AppProject на команду, запрет default, SSO-группы); что ломается при росте числа приложений (шардирование, repo-server, Redis, webhook).
Подводные камни: общие поля с HPA/webhook + selfHeal; ignoreDifferences без RespectIgnoreDifferences; задержка до 3 мин; ручные правки и rollout undo откатываются; удаление Application без finalizer; проект default разрешает всё; секреты в Git и в diff; образы Argo CD с ECR/ghcr — зеркалить; CRD большие — server-side.
Задание со звёздочкой: orders-prod целиком, Application без prune для БД, sync-wave для PostgreSQL, webhook Gitea → argocd-server и замер, опасность prune для StatefulSet/PVC.
Чеклист — выкинут. Из старой версии убраны эмодзи, сюжет staging→Gitea как сценарий, «Зачем это DevOps-у».
