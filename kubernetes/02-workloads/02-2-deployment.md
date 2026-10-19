# 02-2. Deployment и стратегии выкатки

> Модуль 02 «Workloads» · часть 2 из 5 · ~1,5 ч чтения + ~1 ч лабы · Нужно: стенд 00-1 (контекст `kind-lab`), kubectl из 00-2, образ `orders-api:2.0` из 00-1 и доступ узлов к образу `python:3.12-slim` · Опирается на: 02-1 (под, условие `Ready`), 01-3 (владельцы объектов, каскадное удаление)

## Где мы на карте

Эта часть разбирает Deployment — контроллер, которым выкатывают почти все сервисы без состояния. Она опирается на 02-1: Deployment создаёт поды и считает под рабочим по условию `Ready`. От 01-3 нужны владельцы объектов, потому что Deployment владеет ReplicaSet, а тот — подами.

Следующие части продолжают тему. Пробы и остановка пода (02-5) решают, будут ли у клиентов ошибки во время выкатки. Service (03-2) отправляет трафик на готовые поды, а веса маршрута Gateway API (03-4) дают canary без лишних подов.

```
 Deployment          02-2: версия, стратегия, история, откат
      │ владеет (ownerReferences, 01-3)
      ▼
 ReplicaSet          02-2: держит N одинаковых подов
      │ владеет
      ▼
 Pod × N             02-1: контейнеры, условие Ready
      ▲
      │ выбирает по меткам, берёт только Ready
 Service             03-2: стабильный адрес для клиентов
```

Схема 1. Цепочка владения сверху вниз и путь трафика снизу: клиент приходит в Service, а Service видит только готовые поды.

---

## 1. Какую задачу решает Deployment

Deployment заменяет версию приложения так, чтобы сервис продолжал отвечать. Разберём, что он берёт на себя и чего не делает.

### Замена версии без остановки сервиса

Новая версия приложения означает новые поды, а старые поды нужно убрать. Сделать это руками значит создавать и удалять поды по одному и следить за готовностью каждого. **Deployment** (развёртывание) — контроллер, который хранит желаемую версию и число копий и сам приводит к ним кластер при каждом изменении (контроллеры — 01-1).

Deployment не создаёт поды напрямую, а работает через **ReplicaSet** — контроллер, который держит заданное число одинаковых подов по шаблону и селектору. ReplicaSet ничего не знает о версиях: его задача — «ровно N штук». Версиями управляет Deployment, который создаёт новый ReplicaSet для новой версии и переносит реплики со старого на новый.

Такая замена называется **выкаткой** (rollout). Пока выкатка идёт, часть подов работает на старой версии, а часть — на новой, поэтому обе версии должны уметь работать одновременно.

### Что запускает выкатку

Выкатку запускает только изменение шаблона пода. **Шаблон пода** (pod template) — раздел `spec.template` Deployment: образ, переменные, ресурсы, метки пода, пробы.

Изменение числа реплик, стратегии, `minReadySeconds` и меток самого Deployment выкатки не вызывает. Чтобы перезапустить поды без смены образа, команда `kubectl rollout restart` меняет в шаблоне аннотацию `kubectl.kubernetes.io/restartedAt`, и шаблон становится новым.

### Чего Deployment не делает

У Deployment три границы, и о них стоит помнить заранее.

- **Откат** — сам Deployment его не делает. Когда выкатка не идёт, он только сообщает об этом в условиях.
- **Ожидание** — `kubectl apply` возвращается, когда API принял объект, а не когда выкатка закончилась.
- **Трафик** — Deployment считает готовые поды, но не делит трафик между версиями по долям.

Первые две границы закрывают команды наблюдения (§4) и CI. Третью закрывают приёмы blue-green и canary (§3).

---

## 2. Как устроен Deployment

Deployment хранит историю версий в виде ReplicaSet и переключает между ними по правилам стратегии. Ниже — устройство цепочки, две стратегии, критерий готовности и поведение при масштабировании.

### Deployment, ReplicaSet и Pod

Каждая версия шаблона получает свой ReplicaSet. **Ревизия** (revision) — номер версии шаблона в истории Deployment, он записан в аннотации `deployment.kubernetes.io/revision`. ReplicaSet отличает свои поды по метке `pod-template-hash`: это хэш шаблона, и он стоит в селекторе ReplicaSet и в метках подов.

```
Deployment orders-api  (replicas: 4, шаблон версии 2.1)
 ├─ ReplicaSet orders-api-c5cffb4fd   4 пода   hash=c5cffb4fd   ← текущая ревизия
 └─ ReplicaSet orders-api-6b8fc9fdf   0 подов  hash=6b8fc9fdf   ← хранится для отката
```

Схема 2. Старый ReplicaSet остаётся с нулём реплик, и по нему работает откат.

Сколько старых ReplicaSet хранить, решает поле `revisionHistoryLimit`: по умолчанию 10. Значение 0 удаляет все старые ReplicaSet сразу, и откат становится невозможен.

### Стратегия RollingUpdate

**Стратегия** (strategy) — правило, по которому Deployment переводит реплики со старого ReplicaSet на новый. **RollingUpdate** (плавное обновление) — стратегия по умолчанию: новые поды поднимаются, а старые гасятся постепенно, поэтому сервис не останавливается.

Скорость и запас задают два параметра.

- **maxSurge** — сколько подов сверх `replicas` можно создать во время выкатки.
- **maxUnavailable** — сколько подов из `replicas` может быть недоступно.

Оба параметра принимают число или процент. По умолчанию это 25 % и 25 %: проценты округляются, `maxSurge` вверх, `maxUnavailable` вниз. Для четырёх реплик получается +1 и −1. Для одной реплики получается +1 и 0, поэтому единственный под заменяется без перерыва. Значение 0 в обоих параметрах API запрещает.

```
старый RS:  4 ─► 3 ─► 2 ─► 1 ─► 0
новый RS:   0 ─► 1 ─► 2 ─► 3 ─► 4
всего подов не больше 5 (replicas + maxSurge), готовых не меньше 3 (replicas − maxUnavailable)
```

Схема 3. Выкатка при четырёх репликах и 25 %/25 %: счётчики старого и нового ReplicaSet меняются шагами, а границы сверху и снизу не нарушаются.

Параметры выбирают под запас ресурсов и важность мощности. Таблица сравнивает четыре типичных сочетания.

| Сочетание | Что происходит | Когда подходит |
|---|---|---|
| 25 % и 25 % | быстро, мощность временно падает на 25 % | по умолчанию |
| surge 1, unavailable 0 | готовых подов не меньше заданного числа, выкатка медленнее | сервис под нагрузкой |
| surge 0, unavailable 1 | лишних подов нет, на время теряется один под | в кластере нет запаса |
| surge 100 % | вторая копия поднимается целиком рядом | нужна скорость и двойной запас |

### Стратегия Recreate

**Recreate** (пересоздание) — стратегия, которая сначала удаляет все старые поды, а новые создаёт только после их завершения. Простой неизбежен: пока старые поды завершаются и новые стартуют, отвечать некому.

Эта стратегия нужна, когда две версии не могут работать одновременно: например, они обе хотят эксклюзивный том `ReadWriteOnce` (04-2) или несовместимо меняют схему базы. Во всех остальных случаях выбирают RollingUpdate с совместимыми версиями API и схемы.

### Готовность и сроки

Выкатка идёт вперёд только тогда, когда новые поды стали доступными. **Доступный под** (available) — под в состоянии `Ready`, который удерживает его не меньше `minReadySeconds`; по умолчанию 0, то есть доступен сразу. Ненулевое значение защищает от версий, которые проходят пробу готовности и падают через несколько секунд: выкатка не пойдёт дальше, пока новый под не «продержался». Цена — время: на четырёх репликах при surge 1 и unavailable 0 выкатка занимает 4 секунды без задержки и 41 секунду с `minReadySeconds: 10` (лабораторная работа 3).

Второй срок — `progressDeadlineSeconds`, по умолчанию 600 секунд. Если выкатка не делает ни одного шага дольше этого времени, условие `Progressing` получает значение `False` с причиной `ProgressDeadlineExceeded`. Срок считается от последнего шага, а не от начала всей выкатки, поэтому долгая, но движущаяся выкатка его не нарушает. Значение должно быть больше `minReadySeconds`, иначе API отклонит объект.

Deployment после срока ничего не откатывает. Выкатка остаётся на месте, часть подов работает на старой версии, а часть новых не стартует (§5).

### Масштабирование во время выкатки

Если число реплик меняется посреди выкатки, Deployment делит добавленные реплики между старым и новым ReplicaSet пропорционально их размеру. Этот приём называется **proportional scaling** (пропорциональное масштабирование): доля непроверенной версии не растёт быстрее запланированного.

При уменьшении числа реплик ReplicaSet выбирает, какие поды убрать, по порядку признаков. Сначала уходят поды, не назначенные на узел, затем поды в фазе `Pending` и не готовые. Дальше идут поды с меньшим значением аннотации `controller.kubernetes.io/pod-deletion-cost` и те, что стоят на узлах с большим числом готовых реплик.

Если эти признаки равны, сравниваются возраст и число перезапусков: раньше уходят более молодые поды и поды с большим числом перезапусков. Возраст сравнивается грубо, логарифмическими корзинами (по умолчанию с 1.22, GA в 1.31). Внутри одной корзины порядок задаёт UID пода, поэтому выбор почти случаен.

В статусе Deployment есть поле `terminatingReplicas`: сколько подов уже получили сигнал остановки, но ещё не исчезли. Поле появилось в 1.33 как alpha и с 1.35 включено по умолчанию (beta). Раньше эти поды были невидимы в счётчиках, и казалось, что реплик меньше, чем занято ресурсов.

---

## 3. Как управлять выкаткой

Управление сводится к четырём задачам: запустить выкатку и поставить её на паузу, откатить, зафиксировать образ и, когда плавной замены мало, выкатить через blue-green или canary.

### Запуск, пауза и масштаб

Выкатку запускает любая правка шаблона. Ниже команды, которыми правят Deployment и управляют ходом выкатки.

```bash
kubectl set image deploy/orders-api api=localhost:5001/lab-02-2/orders-api:2.1
kubectl annotate deploy/orders-api kubernetes.io/change-cause="image 2.1" --overwrite
kubectl rollout restart deploy/orders-api
kubectl rollout pause deploy/orders-api
kubectl rollout resume deploy/orders-api
kubectl scale deploy/orders-api --replicas=6
```

| Часть команды | Значение |
|---|---|
| `set image … api=…:2.1` | сменить образ контейнера `api`; шаблон изменился, выкатка началась |
| `annotate … change-cause` | подписать ревизию для `rollout history` |
| `rollout restart` | перезапустить поды без смены образа |
| `rollout pause` | заморозить выкатку: правки шаблона копятся, но не применяются |
| `rollout resume` | снять паузу: все накопленные правки уходят одной выкаткой |
| `scale --replicas=6` | изменить число реплик через подресурс, ревизии нет |

С автомасштабированием (HPA, 05-4) число реплик в манифесте не держат, иначе каждый `apply` будет сбрасывать решение HPA. Прямое масштабирование ReplicaSet бесполезно: Deployment сразу вернёт прежнее число.

### Откат и история

Откат возвращает шаблон предыдущей ревизии. Каждая ревизия живёт в своём ReplicaSet, поэтому откат — это переключение между ними, а не пересборка.

```bash
kubectl rollout history deploy/orders-api
kubectl rollout history deploy/orders-api --revision=3
kubectl rollout undo deploy/orders-api
kubectl rollout undo deploy/orders-api --to-revision=2
```

| Часть команды | Значение |
|---|---|
| `rollout history` | список ревизий и подписей |
| `--revision=3` | показать шаблон одной ревизии |
| `rollout undo` | вернуться к предыдущей ревизии |
| `--to-revision=2` | вернуться к указанной ревизии |

Откат не создаёт новый ReplicaSet, если шаблон совпал со старым: поднимается прежний ReplicaSet, а ревизия получает новый номер. Образ уже лежит на узлах, поэтому откат быстрый.

Столбец `CHANGE-CAUSE` — просто аннотация `kubernetes.io/change-cause` на Deployment, которую контроллер копирует в текущий ReplicaSet. Если сменить шаблон и не обновить аннотацию, новая ревизия получит старую подпись, и две разные ревизии будут подписаны одинаково. Флаг `--record` удалён, поэтому аннотацию ставят в том же `apply`, что и изменение.

Откат командой меняет только объект в кластере. Манифест в Git и аннотация `last-applied-configuration` остаются с плохой версией, и следующий `kubectl apply` из CI вернёт её. Поэтому `undo` годится как экстренная мера, а постоянный откат делают в Git: revert коммита, который запустит нормальную выкатку (08-1).

### Образы: теги и дайджесты

Тег образа можно перезаписать в реестре, а дайджест — нельзя. **Тег** (tag) — читаемое имя версии, например `2.1`. **Дайджест** (digest) — хэш содержимого образа вида `sha256:…`, и под одним дайджестом всегда один и тот же образ.

Поведение kubelet задаёт `imagePullPolicy`. Для тега `latest` или образа без тега по умолчанию `Always`, для любого другого тега и для дайджеста — `IfNotPresent`. При `IfNotPresent` kubelet берёт образ из кэша узла, если там есть образ с таким именем и тегом, и не сверяется с реестром.

Из этого следует ловушка: если тег `2.1` перезаписали, узлы с кэшем запустят старое содержимое, а узлы без кэша скачают новое. Один Deployment с одним `image:` даёт две разные версии, и проявляется это при перепланировании подов, а не сразу (лабораторная работа 4). Лечат это деплоем по дайджесту: `image: registry/app@sha256:…`. Дайджест берут из вывода сборки в CI или командами `crane digest` и `skopeo inspect`. Тег рядом с дайджестом (`app:2.1@sha256:…`) оставляют для людей, но kubelet использует только дайджест.

Политика `Always` тоже решает проблему, но каждый старт пода начинает зависеть от реестра и его лимитов. Слои при этом заново не качаются: kubelet сверяет только манифест.

### Blue-green

**Blue-green** — приём, при котором две полные версии работают рядом, а трафик переключают одним действием. Синяя версия (blue) обслуживает пользователей, зелёная (green) поднята заранее и проверена, а переключение сводится к смене селектора в Service.

```
                  Service orders-api
                  selector: app=orders-api, track=blue
                      │  переключение: track=green
          ┌───────────┴────────────┐
          ▼                        ▼
 Deployment orders-blue      Deployment orders-green
 (версия 2.0, трафик)        (версия 2.1, готова, трафика нет)
```

Схема 4. Два Deployment с разной меткой `track`; Service выбирает один из них по метке, и откат — это возврат метки.

Для схемы нужны два Deployment, у которых в шаблоне и селекторе есть метка `track`. Селекторы не должны пересекаться, иначе ReplicaSet начнут считать чужие поды своими. Переключение выглядит так.

```bash
kubectl patch service orders-api \
  -p '{"spec":{"selector":{"app":"orders-api","track":"green"}}}'
```

Команда меняет селектор Service на зелёную версию. Откат — та же команда с `blue`, и он мгновенный, пока синий Deployment жив.

У приёма три цены. Две версии занимают вдвое больше ресурсов на время проверки. База данных и очереди видят обе версии, поэтому схема остаётся совместимой. Уже открытые соединения продолжают идти к старым подам, пока клиент их не закроет, потому что переключение меняет правила только для новых соединений (03-2). Плавная выкатка с `maxSurge: 100 %` похожа на blue-green, но момента переключения и мгновенного отката у неё нет.

### Canary

**Canary** (канарейка) — приём, при котором новую версию сначала получает малая доля трафика, и только по результатам расширяют долю до 100 %. Цель — поймать ошибку на 1–10 % пользователей, а не на всех.

Долю задают двумя способами. Первый — доля реплик: второй Deployment с новой версией получает ту же метку `app`, что и стабильный, и Service делит трафик между всеми подами. При 9 стабильных и 1 новом поде на новую версию приходится около 10 % соединений. Способ работает без дополнительных компонентов, но грубый: доля равна числу подов, поэтому для 1 % нужно 100 подов. Кроме того, kube-proxy распределяет соединения, а не запросы, и долгие keep-alive-соединения искажают долю (03-2).

Второй способ — веса маршрута. Gateway API делит запросы между двумя Service по весам, например 90/10, независимо от числа подов, и умеет выбирать версию по заголовку запроса. Веса меняют правкой одного объекта: `HTTPRoute` (03-4, лабораторная работа 2).

Canary без наблюдения бесполезен: решение о расширении доли принимают по метрикам ошибок и задержки, а не по тому, что поды стартовали. Автоматический анализ и откат делают отдельные контроллеры, например Argo Rollouts и Flagger; в курсе их нет, а метрики — тема курса observability.

---

## 4. Как увидеть состояние выкатки

Состояние выкатки видно в трёх местах: в выводе `rollout status`, в полях и условиях Deployment и в списке ReplicaSet с событиями. Отдельный вопрос — какой образ на самом деле работает.

### Ожидание выкатки: rollout status

Команда `kubectl rollout status deploy/orders-api` блокируется, пока выкатка не закончится, и печатает прогресс. Она завершается с кодом 0, когда все реплики обновлены и доступны, и с кодом 1, если истёк `progressDeadlineSeconds`. Ключ `--timeout=120s` ограничивает ожидание самой команды.

Именно этот код нужен CI. `kubectl apply` сообщает лишь, что объект принят, поэтому шаг деплоя должен быть парой: `apply`, затем `rollout status` с таймаутом чуть больше `progressDeadlineSeconds`. Ненулевой код делает задание красным, а дальше запускается откат или revert в Git.

### Поля и условия Deployment

Поле `status` собирает счётчики и условия. Счётчики отвечают на вопрос «сколько», а условия — на вопрос «почему».

- **replicas** — сколько подов существует во всех ReplicaSet, без завершающихся.
- **updatedReplicas** — сколько из них на новом шаблоне.
- **readyReplicas** и **availableReplicas** — сколько готовых и сколько доступных (с учётом `minReadySeconds`).
- **unavailableReplicas** — сколько не хватает до нужного числа.
- **terminatingReplicas** — сколько подов завершаются (с 1.35).

Условий три. Условие `Available` показывает, что мощности хватает: причина `MinimumReplicasAvailable`. Условие `Progressing` показывает ход выкатки: `ReplicaSetUpdated` пока она идёт, `NewReplicaSetAvailable` когда закончилась, `ProgressDeadlineExceeded` когда застряла. Условие `ReplicaFailure` с причиной `FailedCreate` появляется, когда ReplicaSet не может создать поды, например из-за квоты.

В обычном списке `kubectl get deploy` эти поля видны как колонки `READY`, `UP-TO-DATE` и `AVAILABLE`. Сообщения условий читают через `-o jsonpath` или `describe`.

### ReplicaSet и события

Какая ревизия сейчас живая, видно по ReplicaSet: у текущей `DESIRED` равен числу реплик, у старых — 0. Команда `kubectl get rs -o wide` показывает образ каждого ReplicaSet, а `kubectl get events` с фильтром по Deployment — последовательность событий вида «Scaled up replica set … from 1 to 2». Именно события восстанавливают порядок шагов выкатки. API-сервер хранит события 1 час (02-1 §4), поэтому смотреть их нужно сразу.

### Какой образ работает на самом деле

Образ в шаблоне Deployment описывает желаемое, а фактически запущенный образ лежит в `status.containerStatuses[].imageID` каждого пода. Это дайджест, и по нему сравнивают поды между собой и с реестром.

Команда ниже выводит для каждого пода узел и фактический дайджест.

```bash
kubectl get pods -l app=orders-api \
  -o custom-columns=POD:.metadata.name,NODE:.spec.nodeName,\
IMAGEID:.status.containerStatuses[0].imageID
```

В выводе смотрят на одинаковость столбца `IMAGEID` у всех подов. Если значения различаются, у Deployment два разных образа под одним тегом (§5). Образец вывода — в лабораторной работе 4.

---

## 5. Что ломается и как найти причину

Поломки выкатки делятся на пять классов: она зависла, CI не заметил проблему, клиенты видят ошибки, версии расходятся и откат вернул не всё. Для каждого класса свой порядок поиска.

### Выкатка зависла

Признаки такие: `rollout status` долго молчит и затем выходит с кодом 1, в списке есть поды `ErrImagePull`, `Pending` или `CrashLoopBackOff`, а условие `Progressing` равно `False`. Сервис при этом работает: новые поды не прошли `Ready` и в Service не попали, а ответы дают старые поды.

Порядок поиска такой:

1. Условия Deployment — причина `ProgressDeadlineExceeded` подтверждает застрявшую выкатку.
2. `kubectl get rs` — какой ReplicaSet новый и сколько у него готовых подов.
3. `kubectl describe pod` у нового пода — события `ErrImagePull`, `FailedScheduling`, `Unhealthy`.
4. `kubectl logs --previous` — лог упавшего запуска.
5. Условие `ReplicaFailure` или событие `exceeded quota` — упёрлись в квоту (05-2).

Опасность застрявшей выкатки в потере мощности. При 25 % и 25 % Deployment уже убил один старый под, а новые не стартуют. Сервис работает на 75 % мощности, пока кто-то не откатит выкатку (лабораторная работа 2). С `maxUnavailable: 0` мощность не упала бы. Общая методика поиска — 11-2.

### CI зелёный, а версия старая

Задание деплоя закончилось за секунды, но в кластере остались старые поды, а новые падают. Причина в том, что `kubectl apply` не ждёт выкатки, а плохая версия не попала в Service и не вызвала видимых ошибок. Лечение двойное: `rollout status` с таймаутом в CI и оповещение на условие `Progressing=False` дольше нескольких минут (метрики kube-state-metrics, 11-1). Заодно сокращают `progressDeadlineSeconds` до реального времени старта и ставят `maxUnavailable: 0`.

### Ошибки клиентов во время выкатки

Ошибки при плавной выкатке значат, что под получает запросы после сигнала остановки или до готовности. Ошибки идут, пока под ещё стоит в списке адресов Service, а процесс уже не принимает соединения. В стенде у orders-api переменная `SHUTDOWN_DELAY=5`: после SIGTERM под ещё 5 секунд отвечает на запросы, и плавная выкатка идёт без ошибок. Без этой задержки ошибки появляются и в RollingUpdate. Порядок остановки и `preStop` — 02-5.

Для Recreate ошибки неизбежны: пока новые поды стартуют, отвечать некому. В лабораторной работе 1 окно составило 9,7 секунды.

### Разные версии при одном теге

Один Deployment отдаёт две версии, если образ определён изменяемым тегом. Причина описана в §3: узлы с кэшем и без него. Ищут её по `imageID` подов (§4), лечат деплоем по дайджесту и неизменяемыми тегами в реестре.

### Откат вернул не всё

Откат возвращает шаблон пода, но не содержимое объектов, на которые шаблон ссылается. ConfigMap и Secret (04-1) не версионируются вместе с ревизиями, схему базы откат не меняет, а образ, удалённый из реестра, не скачается. Поэтому перед откатом проверяют, что старый шаблон совместим с текущими конфигурацией и данными.

---

## 6. Пределы и значения по умолчанию

Ниже собраны числа и ограничения части. Значения взяты из документации Kubernetes для версии стенда 1.36.

### Параметры выкатки

- Стратегия по умолчанию — `RollingUpdate`.
- `maxSurge` — 25 %, округление вверх; `maxUnavailable` — 25 %, округление вниз.
- Оба параметра нулевые одновременно — API отклоняет (ошибка ``may not be 0 when `maxSurge` is 0``).
- `Recreate` параметров не имеет.
- `replicas` — 1, если не указано.

### Сроки и история

- `minReadySeconds` — 0 секунд.
- `progressDeadlineSeconds` — 600 секунд, значение должно быть больше `minReadySeconds`.
- `revisionHistoryLimit` — 10; значение 0 отключает откат.
- Время на остановку пода — 30 секунд (`terminationGracePeriodSeconds`, 02-5).

### Ограничения объекта

- Выкатку запускает только изменение шаблона пода.
- `spec.selector` у Deployment неизменяем (ошибка `field is immutable`). Сменить селектор можно только пересозданием; без остановки подов помогает `--cascade=orphan` (01-3 §3).
- Команда `rollout undo` возвращает только шаблон: аннотацию `last-applied-configuration`, манифест в Git и связанные объекты она не меняет.
- Прямое масштабирование ReplicaSet отменяется Deployment.

---

## Лабораторные работы

Работы идут на стенде 00-1 в namespace `lab-02-2`. Хост они не меняют: кластер работает в kind, а на хосте добавляются только образы Docker и файлы в `~/lab/k8s/02-2`. Работы 1–3 идут подряд на одном Deployment, а работа 4 начинает с чистого.

Образцы вывода получены с образами без префикса `lab-02-2/`, и в них имя образа приведено к этому префиксу. Хэши ReplicaSet, имена подов, дайджесты и счётчики запросов у вас будут свои.

Образ клиента `python:3.12-slim` узлы тянут из Docker Hub. Если он недоступен, положите образ в реестр стенда так же, как `busybox` в 02-1, и замените имя в команде `kubectl run`.

Подготовка создаёт namespace, каталог для файлов и два образа в реестре стенда. Образ версии 2.0 — это тот же образ из 00-1 под новым именем, а 2.1 собирается из тех же исходников с другим номером версии.

```bash
kubectl config use-context kind-lab
kubectl create ns lab-02-2
kubectl config set-context --current --namespace=lab-02-2
mkdir -p ~/lab/k8s/02-2

cd ~/lab/k8s/orders-api
docker tag localhost:5001/orders-api:2.0 localhost:5001/lab-02-2/orders-api:2.0
docker build -t localhost:5001/lab-02-2/orders-api:2.1 --build-arg APP_VERSION=2.1 .
docker push localhost:5001/lab-02-2/orders-api:2.0
docker push localhost:5001/lab-02-2/orders-api:2.1
```

| Часть команды | Значение |
|---|---|
| `config set-context --current --namespace=…` | сделать `lab-02-2` текущим namespace |
| `docker tag … lab-02-2/orders-api:2.0` | дать образу 2.0 имя в префиксе работы |
| `docker build … --build-arg APP_VERSION=2.1` | собрать версию 2.1 из исходников orders-api |
| `docker push` | отправить оба образа в реестр стенда |

Теперь создаём манифест Deployment и Service, клиент нагрузки и скрипт, который считает ответы. Манифест лежит в файле, потому что его применяют в нескольких работах. Приложение работает без `DATABASE_URL` и держит данные в памяти: база в этой части не нужна.

```bash
cat > ~/lab/k8s/02-2/orders.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata: {name: orders-api}
spec:
  replicas: 4
  selector: {matchLabels: {app: orders-api}}
  template:
    metadata: {labels: {app: orders-api}}
    spec:
      containers:
      - name: api
        image: localhost:5001/lab-02-2/orders-api:2.0
        ports: [{name: http, containerPort: 8000}]
        env: [{name: SHUTDOWN_DELAY, value: "5"}]
        readinessProbe: {httpGet: {path: /ready, port: http}, periodSeconds: 2}
        resources: {requests: {cpu: 50m, memory: 32Mi}, limits: {memory: 128Mi}}
---
apiVersion: v1
kind: Service
metadata: {name: orders-api}
spec:
  selector: {app: orders-api}
  ports: [{name: http, port: 80, targetPort: http}]
EOF
```

В манифесте три важных места. Переменная `SHUTDOWN_DELAY=5` заставляет приложение отвечать ещё 5 секунд после SIGTERM (02-5). Проба `/ready` с периодом 2 секунды определяет момент, когда под попадает в Service. Запрос 50m CPU и 32 МиБ памяти держат четыре пода лёгкими для стенда.

Скрипт нагрузки запускает 4 потока, которые обращаются к `/version`, считают коды ответов и версии, и вычисляет окно ошибок от первой до последней.

```bash
cat > ~/lab/k8s/02-2/load.py <<'EOF'
import collections, sys, threading, time, urllib.error, urllib.request

duration = float(sys.argv[1])
url = sys.argv[2] if len(sys.argv) > 2 else "http://orders-api/version"
codes, versions, error_times = collections.Counter(), collections.Counter(), []
end = time.time() + duration

def worker():
    while time.time() < end:
        try:
            with urllib.request.urlopen(url, timeout=2) as r:
                codes[r.status] += 1
                body = r.read().decode()
                versions[body.split('"version": "')[1].split('"')[0]] += 1
        except urllib.error.HTTPError as e:
            codes[e.code] += 1
            error_times.append(time.time())
        except Exception as e:
            codes[type(e).__name__] += 1
            error_times.append(time.time())
        time.sleep(0.02)

threads = [threading.Thread(target=worker) for _ in range(4)]
for t in threads: t.start()
for t in threads: t.join()
total = sum(codes.values())
errors = total - codes[200]
window = f"{max(error_times) - min(error_times):.1f}s" if error_times else "0s"
print(f"requests={total} ok={codes[200]} errors={errors} error_window={window} "
      f"detail={dict(codes)} versions={dict(versions)}")
EOF
kubectl run client --image=python:3.12-slim --command -- sleep infinity
kubectl wait --for=condition=Ready pod/client
kubectl cp ~/lab/k8s/02-2/load.py client:/tmp/load.py
```

Команда `kubectl run` запускает под-клиент, который ничего не делает, а `kubectl cp` копирует в него скрипт. Каждый запуск `kubectl exec client -- python /tmp/load.py <секунды>` нагружает Service в течение указанного времени и печатает одну итоговую строку.

### Лабораторная работа 1. Плавное обновление и Recreate

**Цель.** Измерить ошибки клиентов при двух стратегиях и увидеть шаги плавной выкатки по событиям и ReplicaSet.

**Что понадобится.** Стенд 00-1, namespace `lab-02-2` с подготовкой выше, образы 2.0 и 2.1 в реестре стенда.

**Схема опыта.**

```
клиент (4 потока, /version) ──► Service orders-api ──► 4 пода

Шаг 2: образ 2.0 ► 2.1, RollingUpdate 25 %/25 %   ─► ошибок нет, выкатка 3 с
Шаг 3: образ 2.1 ► 2.0, Recreate                  ─► ошибки, окно около 10 с
```

Схема 5. Одна и та же нагрузка идёт под двумя стратегиями, и клиент считает ошибки.

#### Шаг 1. Развернуть Deployment и проверить нагрузку

Команда создаёт Deployment и Service, ждёт готовности подов и запускает пятисекундную нагрузку без выкатки.

```bash
kubectl apply -f ~/lab/k8s/02-2/orders.yaml
kubectl rollout status deploy/orders-api
kubectl exec client -- python /tmp/load.py 5
```

| Часть команды | Значение |
|---|---|
| `apply -f …/orders.yaml` | создать Deployment и Service из манифеста |
| `rollout status` | ждать, пока все 4 пода станут доступными |
| `load.py 5` | нагрузка 5 секунд, одна итоговая строка |

Результат:

```
deployment.apps/orders-api created
service/orders-api created
deployment "orders-api" successfully rolled out
requests=940 ok=940 errors=0 … versions={'2.0': 940}
```

Разбор:

1. `successfully rolled out` — все 4 пода обновлены и доступны.
2. `requests=940 ok=940` — все запросы за 5 секунд успешны, поэтому нагрузка без выкатки даёт эталон: ошибок нет.
3. `versions={'2.0': 940}` — отвечает только версия 2.0.

#### Шаг 2. Плавное обновление под нагрузкой

Команда запускает нагрузку на 40 секунд в фоне, через 3 секунды меняет образ на 2.1 и замеряет время выкатки.

```bash
kubectl exec client -- python /tmp/load.py 40 > ~/lab/k8s/02-2/r1.txt &
sleep 3; t0=$(date +%s)
kubectl set image deploy/orders-api api=localhost:5001/lab-02-2/orders-api:2.1
kubectl annotate deploy/orders-api kubernetes.io/change-cause="image 2.1" --overwrite
kubectl rollout status deploy/orders-api
echo "rollout took $(( $(date +%s) - t0 ))s"
```

| Часть команды | Значение |
|---|---|
| `… > r1.txt &` | нагрузка в фоне, вывод в файл |
| `sleep 3` | дать нагрузке начаться до выкатки |
| `t0=$(date +%s)` | запомнить время начала в секундах |
| `set image … :2.1` | сменить образ; шаблон изменился, выкатка началась |
| `annotate … change-cause` | подписать ревизию для истории |
| `rollout status` | ждать конца выкатки |

Результат:

```
rollout took 3s
```

Теперь дожидаемся конца нагрузки и читаем её итог, события Deployment и список ReplicaSet.

```bash
wait; cat ~/lab/k8s/02-2/r1.txt
kubectl get events --field-selector involvedObject.kind=Deployment \
  --sort-by=.lastTimestamp -o custom-columns=MSG:.message | tail -8
kubectl get rs -o wide
```

| Часть команды | Значение |
|---|---|
| `wait` | дождаться фонового задания с нагрузкой |
| `--field-selector involvedObject.kind=Deployment` | события только от Deployment |
| `--sort-by=.lastTimestamp` | упорядочить события по времени |
| `tail -8` | последние 8 строк |
| `get rs -o wide` | ReplicaSet с образами и селекторами |

Результат (имена ReplicaSet у вас другие: хэш зависит от шаблона; столбец `SELECTOR` опущен):

```
requests=7573 ok=7573 errors=0 … versions={'2.0': 1077, '2.1': 6496}

Scaled up replica set orders-api-c5cffb4fd from 0 to 1
Scaled down replica set orders-api-6b8fc9fdf from 4 to 3
Scaled up replica set orders-api-c5cffb4fd from 1 to 2
Scaled down replica set orders-api-6b8fc9fdf from 3 to 2
…
Scaled down replica set orders-api-6b8fc9fdf from 1 to 0

NAME                   DESIRED   CURRENT   READY   …   IMAGES
orders-api-6b8fc9fdf   0         0         0       …   localhost:5001/lab-02-2/orders-api:2.0
orders-api-c5cffb4fd   4         4         4       …   localhost:5001/lab-02-2/orders-api:2.1
```

Разбор:

1. `errors=0` из 7573 запросов — плавная выкатка не потеряла ни одного ответа, потому что у приложения есть `SHUTDOWN_DELAY`.
2. `versions` — за время нагрузки ответили обе версии: сначала 2.0, затем 2.1, как на схеме 3.
3. Пары «Scaled up» и «Scaled down» чередуются: новый ReplicaSet растёт на один под, старый уменьшается на один, и границы `+1` и `−1` соблюдены.
4. Старый ReplicaSet остался с `DESIRED 0`: он хранится для отката.

#### Шаг 3. Recreate под нагрузкой

Команда переключает стратегию на Recreate, запускает нагрузку на 25 секунд и возвращает образ 2.0.

```bash
kubectl patch deploy orders-api \
  -p '{"spec":{"strategy":{"type":"Recreate","rollingUpdate":null}}}'
kubectl exec client -- python /tmp/load.py 25 > ~/lab/k8s/02-2/r2.txt &
sleep 3; t0=$(date +%s)
kubectl set image deploy/orders-api api=localhost:5001/lab-02-2/orders-api:2.0
kubectl annotate deploy/orders-api --overwrite \
  kubernetes.io/change-cause="image 2.0, Recreate"
kubectl rollout status deploy/orders-api
echo "rollout took $(( $(date +%s) - t0 ))s"
wait; cat ~/lab/k8s/02-2/r2.txt
```

| Часть команды | Значение |
|---|---|
| `"type":"Recreate"` | сменить стратегию на пересоздание |
| `"rollingUpdate":null` | убрать параметры плавной стратегии, с Recreate они запрещены |
| `load.py 25` | нагрузка 25 секунд, вывод в файл |
| `set image … :2.0` | сменить образ обратно на 2.0 |
| `cat r2.txt` | итог нагрузки |

Результат:

```
rollout took 7s
requests=3960 ok=3930 errors=30 error_window=9.7s
  detail={200: 3930, 'ConnectionResetError': 3, 'URLError': 27}
```

Разбор:

1. `errors=30` из 3960 — пользователи получили ошибки, хотя при плавной выкатке их не было.
2. `error_window=9.7s` — клиент получал ошибки почти 10 секунд подряд. Это 5 секунд `SHUTDOWN_DELAY` старых подов плюс запуск и проба готовности новых.
3. `URLError` (27) и `ConnectionResetError` (3) — отказ в соединении, когда подов нет, и обрыв соединения при остановке.
4. `rollout took 7s` — Recreate закончился быстро, но быстрее не значит лучше: цена — простой.

#### Шаг 4. Завершающиеся поды

Этот шаг вы выполняете сами, результат в нём ожидаемый. Команда уменьшает число реплик до двух и семь секунд подряд печатает счётчики Deployment, а затем возвращает четыре реплики.

```bash
kubectl scale deploy/orders-api --replicas=2
for i in 1 2 3 4 5 6 7; do
  kubectl get deploy orders-api \
    -o jsonpath='replicas={.status.replicas} terminating={.status.terminatingReplicas}{"\n"}'
  sleep 1
done
kubectl scale deploy/orders-api --replicas=4
kubectl rollout status deploy/orders-api
```

| Часть команды | Значение |
|---|---|
| `scale --replicas=2` | убрать два пода, шаблон не меняется |
| `status.replicas` | сколько подов Deployment считает своими |
| `status.terminatingReplicas` | сколько подов уже получили сигнал остановки (поле с 1.35) |
| `sleep 1` | пауза между замерами |

Ожидаемый результат: в первых строках `terminating=2`, а после 5 секунд (`SHUTDOWN_DELAY`) поле становится 0.

Разбор:

1. `replicas=2` сразу после `scale` — Deployment уже считает только два пода своими.
2. `terminating=2` — два остановленных пода ещё существуют, потому что отвечают на запросы 5 секунд после SIGTERM.
3. Без этого поля о таких подах говорит только `kubectl get pods` со статусом `Terminating`.

**Итог.**

| Что узнали | Где видно |
|---|---|
| Плавная выкатка с `SHUTDOWN_DELAY` идёт без ошибок | шаг 2, `errors=0` из 7573 |
| События Deployment показывают границы `+1` и `−1` | шаг 2, пары «Scaled up/down» |
| Recreate даёт окно ошибок около 10 секунд | шаг 3, `error_window=9.7s` |
| Завершающиеся поды учитываются отдельным счётчиком | шаг 4, `terminating` |

**Уборка.** Deployment и клиент нужны следующей работе, поэтому здесь ничего не удаляйте. Если вы остановились, выполните уборку работы 4: она удаляет всё, что создала подготовка.

**Вопросы для самопроверки.**

1. Почему плавная выкатка не дала ошибок, а Recreate дала, хотя образ тот же?
2. Из чего складывается окно ошибок 9,7 с у Recreate?
3. Почему `rollingUpdate: null` в патче обязателен?

<details>
<summary>Ответ</summary>

1. Плавная выкатка всегда держит готовые поды, и Service отправляет запросы только на них. Recreate сначала убирает все старые поды, поэтому на время запуска новых отвечать некому.
2. Пять секунд — `SHUTDOWN_DELAY` старых подов, остальное — запуск новых подов и первая успешная проба готовности.
3. Для `Recreate` API запрещает параметры `rollingUpdate`. Патч без `null` оставил бы старые параметры в объекте, и объект был бы отклонён.

</details>

### Лабораторная работа 2. Зависший rollout и откат

**Цель.** Воспроизвести выкатку, которая застряла из-за несуществующего образа, прочитать её состояние и откатить.

**Что понадобится.** Deployment `orders-api` и клиент из работы 1, образ 2.0 в реестре стенда.

**Схема опыта.**

```
Deployment (RollingUpdate 25 %/25 %, progressDeadlineSeconds 30)
 ├─ ReplicaSet с образом 2.0  ─ 3 пода работают
 └─ ReplicaSet с образом 2.9  ─ 2 пода: ErrImagePull  ◄ такого тега нет
```

Схема 6. Образ 2.9 не существует: новые поды не стартуют, старые остаются, а Deployment ждёт срока и сообщает о проблеме.

#### Шаг 1. Выкатить несуществующий образ

Команда возвращает плавную стратегию с дедлайном 30 секунд, запоминает время и меняет образ на несуществующий тег.

```bash
kubectl patch deploy orders-api -p '{"spec":{"progressDeadlineSeconds":30,
  "strategy":{"type":"RollingUpdate","rollingUpdate":{"maxSurge":"25%","maxUnavailable":"25%"}}}}'
kubectl rollout status deploy/orders-api
t0=$(date +%s)
kubectl set image deploy/orders-api api=localhost:5001/lab-02-2/orders-api:2.9
kubectl annotate deploy/orders-api --overwrite \
  kubernetes.io/change-cause="image 2.9 (нет такого тега)"
kubectl rollout status deploy/orders-api --timeout=120s
echo "rollout status exit=$? after $(( $(date +%s) - t0 ))s"
```

| Часть команды | Значение |
|---|---|
| `progressDeadlineSeconds: 30` | считать выкатку застрявшей через 30 секунд без шагов |
| `"type":"RollingUpdate"` | вернуть плавную стратегию после Recreate |
| `maxSurge`, `maxUnavailable` | 25 % и 25 %: один под сверху и один недоступный |
| `…orders-api:2.9` | образ, которого нет в реестре |
| `--timeout=120s` | ждать самой команде не дольше 120 секунд |
| `exit=$?` | код завершения `rollout status` |

Результат:

```
Waiting for deployment "orders-api" rollout to finish: 2 out of 4 new replicas have been updated...
error: deployment "orders-api" exceeded its progress deadline
rollout status exit=1 after 32s
```

Разбор:

1. `2 out of 4 new replicas have been updated` — Deployment создал два новых пода и дальше не пошёл.
2. `exceeded its progress deadline` — сработал дедлайн 30 секунд, и `rollout status` вышел.
3. `exit=1` — ненулевой код, на который опирается CI.
4. `after 32s` — 30 секунд дедлайна плюс опрос.

#### Шаг 2. Прочитать состояние

Команды показывают Deployment, поды и условия, а затем проверяют, отвечает ли сервис.

```bash
kubectl get deploy orders-api
kubectl get pods -L pod-template-hash
kubectl get deploy orders-api \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}: {.message}{"\n"}{end}'
kubectl exec client -- python /tmp/load.py 5
```

| Часть команды | Значение |
|---|---|
| `get deploy` | счётчики READY, UP-TO-DATE, AVAILABLE |
| `get pods -L pod-template-hash` | поды с хэшем шаблона, чтобы отличить ReplicaSet |
| `range .status.conditions[*]` | перебрать все условия |
| `.reason`, `.message` | причина и сообщение условия |
| `load.py 5` | проверить, отвечает ли сервис |

Результат (столбцы пода `RESTARTS`, `AGE` и хэш опущены):

```
NAME         READY   UP-TO-DATE   AVAILABLE   AGE
orders-api   3/4     2            3           6m33s

orders-api-5fbc95fb6-px7fq 0/1 ErrImagePull
orders-api-5fbc95fb6-r75sh 0/1 ErrImagePull
orders-api-6b8fc9fdf-hqdhz 1/1 Running
orders-api-6b8fc9fdf-qcqqs 1/1 Running
orders-api-6b8fc9fdf-sb74t 1/1 Running

Available=True MinimumReplicasAvailable: Deployment has minimum availability.
Progressing=False ProgressDeadlineExceeded: ReplicaSet "orders-api-5fbc95fb6" has timed out …
```

Нагрузка вернула `945 из 945` успешных запросов.

Разбор:

1. `3/4` и `AVAILABLE 3` — мощность упала до 75 %: `maxUnavailable: 25 %` позволил убить один старый под.
2. `UP-TO-DATE 2` — два новых пода создано (`maxSurge: 25 %` и ещё один взамен убитого), оба в `ErrImagePull`.
3. `Available=True` — минимум мощности есть, поэтому сервис жив.
4. `Progressing=False ProgressDeadlineExceeded` — выкатка застряла, и Deployment сам её не отменит.
5. Все запросы успешны: сломанные поды не готовы и в Service не попали. Опасность скрыта — потеря мощности и застрявшая выкатка без ошибок у клиентов.

#### Шаг 3. Откатить

Команды показывают историю, откатывают на предыдущую ревизию и проверяют образ.

```bash
kubectl rollout history deploy/orders-api
kubectl rollout undo deploy/orders-api
kubectl rollout status deploy/orders-api
kubectl rollout history deploy/orders-api
kubectl get deploy orders-api -o jsonpath='image={.spec.template.spec.containers[0].image}{"\n"}'
```

| Часть команды | Значение |
|---|---|
| `rollout history` | ревизии и подписи `CHANGE-CAUSE` |
| `rollout undo` | вернуть шаблон предыдущей ревизии |
| `rollout status` | дождаться конца отката |
| `jsonpath='image=…'` | показать образ в шаблоне после отката |

Результат (в образце до этой работы было больше правок, поэтому номера ревизий у вас меньше; предупреждение сокращено):

```
REVISION  CHANGE-CAUSE
4         image 2.0, Recreate
5         image 2.0, Recreate
6         image 2.9 (нет такого тега)

Warning: resource deployments/orders-api was previously managed with 'kubectl apply'. …
deployment.apps/orders-api rolled back

REVISION  CHANGE-CAUSE
4         image 2.0, Recreate
6         image 2.9 (нет такого тега)
7         image 2.0, Recreate
```

Последняя команда печатает `image=localhost:5001/lab-02-2/orders-api:2.0`. Если вы прошли работы подряд, у вас до отката будут ревизии 2, 3, 4, а после отката 2, 4, 5: важна структура, а не номера. Откат возвращает Deployment и подпись `CHANGE-CAUSE` той ревизии, к которой вернулись.

Разбор:

1. Ревизия плохой версии (6) остаётся в истории после отката: по ней видно, что было выкачено.
2. Ревизия, к которой откатились (5), исчезла и вернулась как 7: шаблон совпал со старым ReplicaSet, и новый не создан.
3. Строки 4 и 5 в образце подписаны одинаково: ревизию 5 создали сменой образа без новой аннотации, и она получила подпись ревизии 4. Если каждую смену образа сопровождает `annotate`, как в работах 1–2, одинаковых подписей не будет.
4. `Warning: … last-applied-configuration` — откат не изменил манифест и аннотацию: в Git остаётся то, что вы применили последним.

**Итог.**

| Что узнали | Где видно |
|---|---|
| `rollout status` выходит с кодом 1 при истёкшем сроке | шаг 1, `exit=1` |
| Застрявшая выкатка снижает мощность, но не даёт ошибок | шаг 2, `3/4` и 945 из 945 |
| Откат переиспользует старый ReplicaSet и даёт новый номер | шаг 3, ревизия 7 |
| Откат расходится с `last-applied` | предупреждение kubectl |

**Уборка.** Deployment нужен работе 3, поэтому не удаляйте. Если вы остановились, выполните уборку работы 4.

**Вопросы для самопроверки.**

1. Что сделает Deployment по истечении `progressDeadlineSeconds` и что должен сделать CI?
2. Как сохранить мощность при плохом релизе?
3. Почему после `rollout undo` нельзя считать вопрос закрытым?

<details>
<summary>Ответ</summary>

1. Deployment выставит `Progressing=False` с причиной `ProgressDeadlineExceeded` и больше ничего не изменит. CI опирается на код 1 от `rollout status`: помечает задание красным и запускает откат или revert в Git.
2. Поставить `maxUnavailable: 0`: старый под не убивают, пока новый не стал доступным.
3. Манифест в Git и `last-applied-configuration` по-прежнему содержат плохую версию. Следующий `apply` вернёт её, поэтому откат нужно повторить в источнике истины.

</details>

### Лабораторная работа 3. Цена minReadySeconds

**Цель.** Измерить, сколько времени добавляет `minReadySeconds`, и увидеть запрет на нулевые параметры выкатки.

**Что понадобится.** Deployment `orders-api` из работ 1–2, образы 2.0 и 2.1.

**Схема опыта.**

```
surge 1, unavailable 0, 4 реплики

minReadySeconds = 10:  4 пода по очереди ждут по 10 с   ─► около 41 с
minReadySeconds = 0:   поды заменяются по готовности    ─► около 4 с
surge 0 + unavailable 0                                  ─► ошибка валидации
```

Схема 7. Одна и та же выкатка с задержкой доступности и без неё.

#### Шаг 1. Замерить выкатку с задержкой

Команда задаёт `minReadySeconds: 10` и строгие параметры surge 1 и unavailable 0, затем меняет образ и замеряет время.

```bash
kubectl patch deploy orders-api -p '{"spec":{"progressDeadlineSeconds":30,"minReadySeconds":10,
  "strategy":{"rollingUpdate":{"maxSurge":1,"maxUnavailable":0}}}}'
kubectl rollout status deploy/orders-api
t0=$(date +%s)
kubectl set image deploy/orders-api api=localhost:5001/lab-02-2/orders-api:2.1
kubectl rollout status deploy/orders-api
echo "$(( $(date +%s) - t0 ))s"
```

| Часть команды | Значение |
|---|---|
| `minReadySeconds: 10` | под доступен, только если был `Ready` 10 секунд |
| `maxSurge: 1` | сверху можно создать один под |
| `maxUnavailable: 0` | готовых подов никогда не меньше 4 |
| `progressDeadlineSeconds: 30` | срок остаётся 30 секунд, он больше 10 |
| `$(( … ))` | разница времени в секундах |

Результат:

```
41s
```

Разбор:

1. 41 секунда на четыре реплики — каждый новый под ждёт 10 секунд до статуса доступного, а старые не гасятся раньше.
2. Выкатка длиннее срока 30 секунд и всё равно успешна: срок считается без шагов, а не от начала.

#### Шаг 2. Замерить выкатку без задержки

Команда убирает `minReadySeconds`, возвращает образ 2.0 и замеряет время.

```bash
kubectl patch deploy orders-api -p '{"spec":{"minReadySeconds":0}}'
kubectl rollout status deploy/orders-api
t0=$(date +%s)
kubectl set image deploy/orders-api api=localhost:5001/lab-02-2/orders-api:2.0
kubectl rollout status deploy/orders-api
echo "$(( $(date +%s) - t0 ))s"
```

| Часть команды | Значение |
|---|---|
| `minReadySeconds: 0` | под доступен сразу после `Ready` |
| `set image … :2.0` | вернуть образ 2.0, шаблон изменился |

Результат:

```
4s
```

Разбор: те же параметры дали 4 секунды вместо 41. Разница в 37 секунд — цена защиты от подов, которые падают после проверки готовности.

#### Шаг 3. Запрещённое сочетание

Команда пытается обнулить оба параметра.

```bash
kubectl patch deploy orders-api \
  -p '{"spec":{"strategy":{"rollingUpdate":{"maxSurge":0,"maxUnavailable":0}}}}'
```

| Часть команды | Значение |
|---|---|
| `maxSurge: 0` и `maxUnavailable: 0` | выкатка не могла бы ни создать, ни убрать под |

Результат:

```
… spec.strategy.rollingUpdate.maxUnavailable: Invalid value: 0: may not be 0 when `maxSurge` is 0
```

Разбор: API отклоняет сочетание, потому что выкатка не смогла бы сделать ни одного шага. Для плавной выкатки хотя бы один параметр должен быть положительным.

**Итог.**

| Что узнали | Где видно |
|---|---|
| `minReadySeconds` растягивает выкатку | шаг 1: 41 с, шаг 2: 4 с |
| Срок `progressDeadlineSeconds` считается от последнего шага | шаг 1, выкатка длиннее 30 с |
| Нули в обоих параметрах запрещены | шаг 3, ошибка валидации |

**Уборка.** Удаляем Deployment и Service, клиент оставляем для работы 4.

```bash
kubectl delete -f ~/lab/k8s/02-2/orders.yaml
```

Команда удаляет Deployment, его ReplicaSet и поды вместе с Service (01-3 §3).

**Вопросы для самопроверки.**

1. Зачем нужен `minReadySeconds`, если есть проба готовности?
2. Почему выкатка в 41 секунду не нарушила `progressDeadlineSeconds: 30`?
3. Что даёт сочетание surge 1 и unavailable 0 и чем оно платит?

<details>
<summary>Ответ</summary>

1. Проба проверяет готовность в момент опроса, а `minReadySeconds` требует удерживать её несколько секунд. Версия, которая стартует и падает через 5 секунд, пройдёт пробу и не пройдёт 10 секунд.
2. Срок считается от последнего шага выкатки. Каждые 10 секунд появлялся новый доступный под, то есть шаг, и таймер сбрасывался.
3. Готовых подов никогда не меньше `replicas`, и плохая версия не снижает мощность. Цена — запас ресурсов на один лишний под и более медленная выкатка.

</details>

### Лабораторная работа 4. Один тег — две версии

**Цель.** Получить два разных образа под одним тегом в одном Deployment и закрепить версию по дайджесту.

**Что понадобится.** Namespace `lab-02-2` и клиент из работы 1, Deployment после уборки работы 3, доступ к контейнерам узлов `lab-worker*`.

**Риски.** Работа меняет кэш образов на одном узле кластера и перезаписывает тег `2.1` в префиксе `lab-02-2` реестра стенда.

- **Что меняется.** Тег `localhost:5001/lab-02-2/orders-api:2.1` в реестре получает другое содержимое, а на узле `lab-worker2` удаляется один образ из кэша. Хост и чужие образы не затрагиваются: меняется только префикс `lab-02-2`.
- **Надолго ли.** До уборки в конце работы.
- **Безопасность.** Привилегированных контейнеров нет; `docker exec` в контейнер узла выполняет только `crictl rmi` для одного образа.
- **Влияние.** Другие работы и namespace не затронуты, `orders-api:2.0` остаётся прежним.
- **Откат.** Уборка удаляет образы, Deployment и префикс в реестре.

**Схема опыта.**

```
реестр: тег 2.1 перезаписан новой сборкой (2.1-hotfix)
 узлы:  lab-worker, lab-worker3 — старая 2.1 в кэше ─┐ берут кэш
        lab-worker2             — кэш удалён        ─┘ качает новую
  rollout restart ─► часть подов на 2.1, часть на 2.1-hotfix
```

Схема 8. Тег один, а образов два: версию определяет кэш узла, на котором оказался под.

#### Шаг 1. Развернуть версию 2.1 на всех узлах

Команда создаёт Deployment заново, переводит его на 2.1 и ждёт готовности. Теперь старая 2.1 лежит в кэше узлов, где есть поды.

```bash
kubectl apply -f ~/lab/k8s/02-2/orders.yaml
kubectl set image deploy/orders-api api=localhost:5001/lab-02-2/orders-api:2.1
kubectl rollout status deploy/orders-api
```

| Часть команды | Значение |
|---|---|
| `apply -f …` | создать Deployment с образом 2.0 |
| `set image … :2.1` | перейти на 2.1; узлы скачивают и кэшируют её |
| `rollout status` | дождаться готовности |

Результат: выкатка закончилась сообщением `successfully rolled out`.

#### Шаг 2. Перезаписать тег и очистить кэш одного узла

Команды собирают другую сборку под тем же тегом, отправляют её в реестр и удаляют старый образ из кэша узла `lab-worker2`.

```bash
cd ~/lab/k8s/orders-api
docker build -t localhost:5001/lab-02-2/orders-api:2.1 --build-arg APP_VERSION=2.1-hotfix .
docker push localhost:5001/lab-02-2/orders-api:2.1
docker exec lab-worker2 crictl rmi localhost:5001/lab-02-2/orders-api:2.1
```

| Часть команды | Значение |
|---|---|
| `build -t …:2.1 --build-arg APP_VERSION=2.1-hotfix` | собрать другое содержимое под прежним тегом |
| `docker push` | перезаписать тег в реестре |
| `docker exec lab-worker2 crictl rmi …` | удалить образ из кэша узла `lab-worker2` |

Результат: `docker push` печатает новый дайджест, а `crictl rmi` — строку `Deleted: …` (вывод зависит от версий и не сохранён).

Разбор: тег 2.1 теперь указывает на новую сборку, но два узла помнят старую. Узел `lab-worker2` образ забыл, как будто под попал на него впервые.

#### Шаг 3. Перезапустить поды и сравнить образы

Команды перезапускают Deployment без смены образа, выводят фактический дайджест каждого пода и запускают нагрузку.

```bash
kubectl rollout restart deploy/orders-api
kubectl rollout status deploy/orders-api
kubectl get pods -l app=orders-api --field-selector=status.phase=Running \
  -o custom-columns=POD:.metadata.name,NODE:.spec.nodeName,\
IMAGEID:.status.containerStatuses[0].imageID
kubectl exec client -- python /tmp/load.py 4
```

| Часть команды | Значение |
|---|---|
| `rollout restart` | пересоздать поды; шаблон тот же, образ по тегу |
| `--field-selector=status.phase=Running` | только работающие поды (без завершающихся) |
| `custom-columns=…IMAGEID:…` | таблица с узлом и фактическим дайджестом |
| `load.py 4` | нагрузка 4 секунды с подсчётом версий |

Результат (дайджесты сокращены):

```
orders-api-dd6b8699c-5jg27   lab-worker    053e1ef2…   ← старая 2.1 из кэша
orders-api-dd6b8699c-7x4rz   lab-worker3   053e1ef2…
orders-api-dd6b8699c-d2q52   lab-worker    053e1ef2…
orders-api-dd6b8699c-dm6cf   lab-worker2   02d5d91c…   ← новая 2.1 из реестра

requests=655 ok=654 errors=1 … versions={'2.1-hotfix': 178, '2.1': 476}
```

Если после перезапуска на `lab-worker2` не оказалось ни одного пода, выполните `rollout restart` ещё раз. Стрелки подписей добавлены для разбора и в выводе отсутствуют.

Разбор:

1. Один Deployment и один `image:` — три пода с дайджестом `053e1ef2…` и один с `02d5d91c…`.
2. Поды на `lab-worker` и `lab-worker3` взяли образ из кэша, не заглянув в реестр, а под на `lab-worker2` скачал новый.
3. `versions` содержит `2.1` и `2.1-hotfix`: клиент получает ответы от обеих версий.
4. `errors=1` — одиночная ошибка клиента, не связанная с различием версий.

#### Шаг 4. Закрепить дайджест

Команды берут дайджест новой сборки, меняют образ на ссылку по дайджесту и снова проверяют поды и нагрузку.

```bash
DIG=$(docker inspect -f '{{index .RepoDigests 0}}' localhost:5001/lab-02-2/orders-api:2.1)
echo "$DIG"
kubectl set image deploy/orders-api api="$DIG"
kubectl rollout status deploy/orders-api
kubectl exec client -- python /tmp/load.py 4
```

| Часть команды | Значение |
|---|---|
| `docker inspect -f '{{index .RepoDigests 0}}'` | взять из локального образа ссылку вида `имя@sha256:…` |
| `set image … api="$DIG"` | деплоить по дайджесту, а не по тегу |
| `load.py 4` | проверить версии в ответах |

Результат (последняя команда; дайджест у вас свой):

```
requests=759 ok=759 errors=0 … versions={'2.1-hotfix': 759}
```

Если `RepoDigests` пуст или команда вернула ошибку, возьмите дайджест из строки `digest: sha256:…` в выводе `docker push` шага 2. Подойдёт и значение `IMAGEID` пода на `lab-worker2` из шага 3: это тот же образ.

Разбор: все 759 ответов дала версия `2.1-hotfix`. Под любым узлом образ определяется дайджестом, а не кэшем по тегу. Повторите команду `get pods` из шага 3: в столбце `IMAGEID` у всех четырёх подов будет один дайджест.

**Итог.**

| Что узнали | Где видно |
|---|---|
| Перезаписанный тег и `IfNotPresent` дают разные версии на узлах | шаг 3, `IMAGEID` и `versions` |
| Фактический образ читается из `imageID` пода | шаг 3, столбец `IMAGEID` |
| Дайджест исключает расхождение | шаг 4, 759 из 759 |

**Уборка.** Удаляем Deployment и клиент вместе с namespace, образы из кэша узлов и хоста, тег из реестра и файлы работы.

```bash
kubectl config set-context --current --namespace=default
kubectl delete ns lab-02-2
for n in lab-worker lab-worker2 lab-worker3; do
  docker exec $n crictl rmi localhost:5001/lab-02-2/orders-api:2.0 \
    localhost:5001/lab-02-2/orders-api:2.1 2>/dev/null
done
docker image rm localhost:5001/lab-02-2/orders-api:2.0 localhost:5001/lab-02-2/orders-api:2.1
docker exec kind-registry rm -rf /var/lib/registry/docker/registry/v2/repositories/lab-02-2
rm -rf ~/lab/k8s/02-2
```

| Часть команды | Значение |
|---|---|
| `delete ns lab-02-2` | удалить namespace со всем содержимым |
| `crictl rmi …:2.0 …:2.1` | убрать образы работы из кэша каждого узла |
| `docker image rm` | убрать локальные образы с хоста |
| `rm -rf …/repositories/lab-02-2` | удалить репозиторий `lab-02-2` из реестра стенда |
| `rm -rf ~/lab/k8s/02-2` | удалить файлы работы |

Образ `localhost:5001/orders-api:2.0` из 00-1 остаётся: команда `docker image rm` сняла только второе имя. Первая сборка 2.1 после перезаписи тега осталась на хосте без имени; её видно в `docker images --filter dangling=true`, а удаляют по ID командой `docker image rm`. Слои в реестре освободятся только сборщиком мусора реестра; мы его не запускаем.

**Вопросы для самопроверки.**

1. Почему расхождение версий не проявилось сразу после перезаписи тега?
2. Чем `imagePullPolicy: Always` хуже деплоя по дайджесту?
3. Где посмотреть, какая версия действительно работает в поде?

<details>
<summary>Ответ</summary>

1. Работающие поды не перезапускались и продолжали держать старый образ. Расхождение появляется при создании подов: перепланирование, drain или масштабирование.
2. Каждый старт пода начинает зависеть от реестра и его лимитов, а тег остаётся изменяемым. Дайджест неизменяем и проверяется без запроса к реестру, если образ в кэше.
3. В `status.containerStatuses[].imageID` пода. Там лежит дайджест, который можно сравнить с реестром и с другими подами.

</details>

---

## → Дальше

Deployment хорошо подходит подам без состояния, потому что поды в нём взаимозаменяемы: у них случайные имена, общий том и порядок запуска не важен. Когда каждый под должен иметь стабильное имя, собственный диск и порядок старта, как у PostgreSQL, нужен другой контроллер. Он называется StatefulSet и разобран в следующей части, 02-3. Выкатка там идёт по порядковым номерам подов, поэтому всё, что вы увидели здесь про шаблон, ревизии и `Ready`, пригодится и там.
