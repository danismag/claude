# Ревью: приложение A «Шпаргалки»

Файл: kubernetes/appendix/A-cheatsheets.md. Режим «только текст»: команды не запускались, сверка по частям курса и исходникам (raw.githubusercontent.com). Git commit не делался.

## Найденные ошибки (было → стало)

1. A.6 kubeadm, порядок обновления: `apt-mark unhold` → `upgrade plan/apply/node` → `apt-mark hold`, без установки пакета → как в 10-3 §3: `unhold`, `apt-get update && apt-get install -y kubeadm='1.36.5-*'`, `hold`, затем `upgrade plan`, `upgrade apply v1.36.5`, `upgrade node`. В старом варианте `upgrade plan` запускался старым kubeadm.
2. A.6, вводная фраза: «команды запускают на узлах control plane» (а `join` идёт на рабочем узле) → «на самих узлах»; добавлено, что строки с `apt` относятся к обычному узлу Ubuntu, а на стенде kubeadm 1.36.5 подменяют скачанным бинарником (10-3, работы 1–3).
3. A.5 etcd: `etcdctl --endpoints=… snapshot save /backup/etcd.db` (без сертификатов, каталога `/backup` в поде etcd нет) → `$X $E snapshot save /var/lib/etcd/snap.db`, `$X etcdutl snapshot status …`, `docker cp lab-control-plane:/var/lib/etcd/snap.db ./snap.db`, как в 10-2, работа 2, шаг 2.
4. A.5: `compact $REV` → `compact $REV --physical`, как в 10-2, работа 3. Комментарий к `defrag` → «перестроить файл члена из --endpoints». Без `--cluster` команда дефрагментирует только адреса из `--endpoints`, здесь это 127.0.0.1:2379 (10-2 §3), так что строка верна. В «Подробно» добавлено, что в 10-2 `restore` запускают в одноразовом поде из образа etcd.
5. A.4: `docker exec $N journalctl -k | grep 'out of memory'` → `docker exec $N dmesg | grep -iE 'out of memory|oom.group'`, как в 05-1, работа 2, шаг 3: на узле kind журнал ядра читают через `dmesg`.
6. A.2: ошибка «образ из `kind load` не удаляют через `crictl rmi --prune`» нигде в курсе не встречается и ничем не подтверждена → заменена пунктом из карточки kind (00-2 §3): `permission denied` на сокете Docker. Комментарий к `kind create cluster --wait 120s` уточнён: это команда для CI.
7. A.8: `kubectl kustomize --enable-helm DIR | kubectl apply -f -` → `… | kubectl apply -n NS -f -`. По 07-3 §5 namespace может не применяться к объектам из `helmCharts`, а лабораторная работа применяет сборку с `-n`.
8. A.11 velero: `velero …` → `VEL=~/lab/k8s/04-3/bin/velero` и `$VEL …`, как в 04-3, работа 3. Здесь `uninstall` → `uninstall --force`, как в уборке 04-3: без флага команда задаёт вопрос.
9. A.10 cosign: `cosign generate-key-pair` спрашивает пароль, а `sign` шёл с `COSIGN_PASSWORD=''` → `COSIGN_PASSWORD='' cosign generate-key-pair`, как в 06-4, шаг 3. Комментарий к `D=sha256:HEX` → «свой дайджест: строка digest: из docker push или 06-4, работа 3, шаг 2»: в 06-4 сказано, что значения совпадают.
10. A.12: `kubectl get pod p-lab-worker2` без namespace (шпаргалка обещает не менять текущий namespace) → `kubectl -n lab-03-1 get pod …`. Добавлена уборка: `docker image rm nicolaka/netshoot:v0.13`, как в 03-1.
11. A.1: комментарий «-A вместо -n — все» к функции `k`, которая уже подставляет `-n` → отдельная строка `kubectl get pods -A -o wide`.
12. A.9: добавлен `kubectl -n argocd port-forward svc/argocd-server 8443:443 &`: без него `argocd login 127.0.0.1:8443` не работает (08-1, работа 1).
13. A.13: добавлен `go install github.com/kubernetes-sigs/ingress2gateway@v1.0.0` (03-5). Блок короткий, потому что в курсе больше команд нет; флаги `print` (`--input-file`, `--providers`, `--emitter`, `--namespace`, `--all-namespaces`) сверены с README v1.0.0.

## Ошибки в частях (части не правились)

- 00-2 §2 и вопрос 5 работы 1: «`KUBECTL_KUBERC=false` выключает механизм kuberc». В kubectl v1.36.0 это верно: `cmdutil.KubeRC FeatureGate = "KUBECTL_KUBERC"` (pkg/cmd/util/helpers.go), а `IsDisabled()` проверяется в pkg/cmd/cmd.go. В master (будущая 1.37) переменная осталась только в тексте справки флага `--kuberc`, код её не читает. Для стенда 1.36 исправлять не нужно. При переходе на 1.37 фразу стоит пересмотреть. `KUBERC=off` работает в обеих версиях (pkg/kuberc/kuberc.go, `os.Getenv("KUBERC") == "off"`).
- 11-1 §3 и документация расходятся. Страница system-logs.md (website main) пишет, что с 1.36 для node log query нужен только `enableSystemLogHandler`. Код kubelet v1.36.0 (pkg/kubelet/kubelet.go) включает режим запроса только при `EnableSystemLogQuery`, а `EnableSystemLogHandler` по умолчанию true (defaults.go). Значит, 11-1 точнее документации; шпаргалка («закрыт настройками kubelet») верна.

## Читаемость

- До: 57 предложений, средняя длина 10,1 слова, 40 % предложений короче 10 слов, 0 нарушений.
- После: 54 предложения, средняя длина 11,3 слова, 35 % коротких, 0 нарушений.
- Сшиты рубленые пары предложений во вводных абзацах «Как пользоваться», A.11, A.12, A.13.
- Строки кода — не длиннее 100 знаков (проверено по символам). Эмодзи и значков нет.

## Подтверждено (источник)

- `KUBERC=off`: kubectl pkg/kuberc/kuberc.go (v1.36.0 и master).
- Node log query, `tailLines`, NodeLogQuery GA в 1.36: website system-logs.md; условие `EnableSystemLogQuery` в kubelet v1.36.0.
- ingress2gateway v1.0.0: флаги `print`, emitter `envoy-gateway`, Go 1.25.5 (README и go.mod v1.0.0).
- Остальные команды сверены с частями курса: 00-2 (карточки kubectl, kind, crictl, k9s, stern), 01-1 §4, 10-1 §3, 10-2, 10-3 §3, 10-4, 07-1 §3, 07-2 §3, 07-3 §3, 08-1 §3, 06-4 работа 3, 04-3 работа 3, 03-1 работа 2, 03-5 работа 3, 11-4 §3. Номера разделов в таблице страниц совпадают с заголовками частей.
- Версии стенда в шапке (containerd 2.3, etcd 3.6, Kustomize 5.8.1, Argo CD 3.5.5, cosign 2.5.3, Velero 1.18.4, metrics-server для `kubectl top`) совпадают с частями.

## Не подтверждено (для 00-plan)

- Шпаргалка A целиком — команды не запускались (режим «только текст»).
- `etcdutl snapshot restore` на хосте — нужен etcdutl на хосте; в курсе restore идёт в поде (10-2).
- `cosign triangulate` в cosign 2.5.3 — по документации не сверялся.
- Пункт A.12 «`-i any` показывает пакет несколько раз» — взят из карточки 03-1, документацией не сверялся.
