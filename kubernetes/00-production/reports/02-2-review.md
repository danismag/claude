# Ревью 02-2 «Deployment и стратегии выкатки»

Файл: /home/user/claude/kubernetes/02-workloads/02-2-deployment.md. Старая версия: e755ced. Исходники Kubernetes release-1.36 — /tmp/claude-0/-home-user-claude/740afa2c-c313-5763-bb73-bdca3fdc2abb/scratchpad/rv022/.

## Найденные ошибки (было → стало)

- §2 порядок удаления подов при scale down: «не назначенные, не готовые, deletion-cost, узлы с большим числом реплик; с 1.31 почти случайно» → полный порядок по controller_utils.go (ActivePodsWithRanks.Less): не назначенные → Pending → не готовые → pod-deletion-cost → больше готовых реплик на узле → моложе по времени готовности и созданию (логарифмические корзины, по умолчанию с 1.22, GA 1.31) → больше перезапусков → UID. Абзац разделён на два.
- §2 terminatingReplicas: «с 1.35 (beta)» → «beta, включено по умолчанию; alpha в 1.33» (kube_features.go: DeploymentReplicaSetTerminatingReplicas).
- §3 CHANGE-CAUSE: «если поставить после set image, может прилипнуть» (механизм неверен) → контроллер копирует аннотацию Deployment в текущий ReplicaSet при каждой синхронизации; одинаковые подписи бывают, когда шаблон сменили без новой аннотации (deployment_util.go: SetNewReplicaSetAnnotations, copyDeploymentAnnotationsToReplicaSet). Работа 2 шаг 3, разбор п. 3 переписан так же: в образце ревизию 5 создали без annotate; при прохождении работ подряд одинаковых подписей не будет. Добавлено: undo переносит на Deployment подпись ревизии, к которой вернулись (rollback.go).
- §5 «Окно ошибок равно времени между удалением пода из списка адресов и остановкой процесса» (наоборот) → ошибки идут, пока под ещё в списке адресов Service, а процесс уже не принимает соединения.
- Работа 3 шаг 3 и §6: текст ошибки → `… spec.strategy.rollingUpdate.maxUnavailable: Invalid value: 0: may not be 0 when \`maxSurge\` is 0` (validation.go:600, обратные кавычки — часть сообщения).
- Работа 1 шаг 4: «поле становится 0 или исчезает» → «становится 0» (сумма по синхронизированным RS — указатель на 0, сериализуется).
- §4: replicas — «без завершающихся»; ReplicaFailure — с причиной `FailedCreate`.
- Ссылки: (01-3 §4) и (01-3 §2) для orphan/каскада → (01-3 §3) по новой 01-3; (03-4 §3, лаб. 2 там же) → (03-4, лабораторная работа 2): 03-4 ещё не переписана.
- Уборка в работах 1 и 2 отсылала к уборке работы 3 (она не удаляет клиент, namespace, образы) → к уборке работы 4.
- Уборка работы 4: образ `lab-02-2/orders-api:2.0` в кэше узлов оставался «как нужный стенду» (это образ работы) → `crictl rmi` убирает 2.0 и 2.1; добавлено про безымянную первую сборку 2.1 на хосте (удалять по ID, без prune).
- Работа 4 шаг 4: запасной путь для дайджеста, если `RepoDigests` пуст/ошибка — строка `digest:` из `docker push` или `IMAGEID` пода на lab-worker2.
- Подмена имён образов: во введении к лабораторным добавлено, что образцы вывода получены без префикса `lab-02-2/` и имя образа в них приведено к префиксу; хэши, имена подов, дайджесты, счётчики будут свои. «Образец с прогона автора» (метка) → нейтральная формулировка о числе предыдущих правок.

## Читаемость

До: 283 предложения, средняя 11,8, 34 % короче 10 слов, 0 нарушений. После правок: 292 предложения, средняя 11,9, 33 %, 0 нарушений (появлявшиеся предложение 27 слов и абзац из 6 предложений исправлены). Строки кода ≤100.

## Подтверждено (источник)

- maxSurge/maxUnavailable 0/0 запрещено, rollingUpdate запрещён при Recreate, progressDeadlineSeconds > minReadySeconds — pkg/apis/apps/validation/validation.go.
- Причины условий: ReplicaSetUpdated, NewReplicaSetCreated, FoundNewReplicaSet, NewReplicaSetAvailable, ProgressDeadlineExceeded, MinimumReplicasAvailable/Unavailable — deployment_util.go; ReplicaFailure переносится с RS — progress.go.
- Сообщения rollout status (`exceeded its progress deadline`, `N out of M new replicas`, `successfully rolled out`) — kubectl rollout_status.go; предупреждение last-applied при undo — rollout_undo.go.
- Откат без нового RS при совпадении шаблона, копирование change-cause — rollback.go, deployment_util.go.
- terminatingReplicas: alpha 1.33, beta on 1.35 — kube_features.go; статус — sync.go.
- LogarithmicScaleDown: beta on 1.22, GA 1.31 — kube_features.go.
- Путь хранения registry 2.8.3: /var/lib/registry/docker/registry/v2/repositories/<имя> (rootdirectory по умолчанию в образе registry:2; стенд 00-1 — registry:2.8.3).
- Реальный вывод работ 1–4 сверен со старой версией e755ced (940; 7573/1077/6496; события; 3960/30/9.7s; 32s; 3/4, условия, 945; история 4,5,6 → 4,6,7; 41s/4s; 053e…/02d5…, 655/654/1; 759).
- События хранятся 1 ч — согласовано с 02-1 §4.

## Не подтверждено (для 00-plan §7)

- 02-2 работа 1 шаг 4: terminatingReplicas при scale 4→2 — ожидаемый результат, не прогонялся.
- 02-2 работа 1 шаг 3: команда замера `rollout took` для Recreate новая; 7 с — из таблицы старой части.
- 02-2 работа 2 шаг 3: номера ревизий 2,3,4 → 2,4,5 для прохождения подряд — вывод из кода, не прогонялся.
- 02-2 работа 4 шаг 4: `docker inspect RepoDigests` при containerd image store не проверялся (дан запасной путь).
- 02-2 работа 4 шаг 2: вывод `crictl rmi` не сохранён; повтор `rollout restart`, если на lab-worker2 нет пода, — допущение.
- 02-2 уборка работы 4: `rm -rf` репозитория в kind-registry — путь по умолчанию registry 2.8.3, не прогонялся.
- 02-2 имена образов в реальном выводе заменены на `localhost:5001/lab-02-2/...` механически (оговорено в тексте).
- 02-2 работа 3 шаг 3: префикс `spec.strategy.rollingUpdate.` и обратные кавычки в тексте ошибки — по исходникам 1.36, в старом выводе их не было.
