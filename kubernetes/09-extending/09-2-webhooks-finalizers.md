# 09-2. Admission webhooks и finalizers

> Модуль 9 «Расширение API» · часть 2 из 2 · 🟡🔴 · ~1 ч чтения + ~40 мин лабы · Нужно: стенд 00-1. В лабе на минуту выключается metrics-server.

---

## Зачем это DevOps-у

Webhook'и и finalizer'ы — два механизма, которыми операторы и политики «встраиваются» в жизненный цикл объектов. И два классических способа сломать кластер так, что на первый взгляд непонятно, что происходит: «никто не может задеплоить — `failed calling webhook`», «namespace неделю висит в Terminating». На собеседовании: «чем опасен `failurePolicy: Fail`», «почему namespace не удаляется», «что такое finalizer» (01-3 §5).

Сквозной сценарий: в кластере уже есть webhook'и — Envoy Gateway, cert-manager (03-4), CNPG (09-1), Kyverno/Gatekeeper в проде. Разберём, как один из них может остановить деплой orders-api.

---

## 1. Admission webhooks 🟡

Webhook — внешний HTTPS-сервис, который apiserver вызывает на этапе admission (06-2 §4): **mutating** (может изменить объект — инжекция sidecar'ов, дефолты) и **validating** (может только разрешить или запретить — политики). Описание — `MutatingWebhookConfiguration` / `ValidatingWebhookConfiguration`:

```yaml
webhooks:
- name: pods.policy.lab.local
  admissionReviewVersions: [v1]
  sideEffects: None
  failurePolicy: Fail                     # если вебхук недоступен: Fail — отказать, Ignore — пропустить
  timeoutSeconds: 5                       # дефолт 10, максимум 30
  namespaceSelector: {matchLabels: {webhook.lab/policy: "on"}}   # где действует
  rules: [{apiGroups: [""], apiVersions: [v1], operations: [CREATE], resources: [pods]}]
  clientConfig:
    service: {name: policy-webhook, namespace: lab-09-2, path: /validate, port: 443}
    # caBundle: … — CA, которым подписан сертификат вебхука (обычно ставит cert-manager)
```

### Вебхук недоступен 🔴

Проверено (сервиса `policy-webhook` нет, `failurePolicy: Fail`):

```
Error from server (InternalError): Internal error occurred: failed calling webhook "pods.policy.lab.local": failed to call webhook: Post "https://policy-webhook.lab-09-2.svc:443/validate?timeout=5s": service "policy-webh…
  took 226 ms
pod/p-default created                                ← в namespace без метки — работает
deploy d1 ready: 0/1
Error creating: Internal error occurred: failed calling webhook …   ← у ReplicaSet, не у Deployment
```

Без `namespaceSelector` то же самое было бы **во всех namespace**, включая `kube-system`: не создадутся поды CoreDNS, CNI, самого вебхука (если его под упал — он не сможет подняться, потому что его создание тоже проходит через сломанный вебхук). Классическая взаимная блокировка.

Сервис есть, но не отвечает (проверено, сервер принимает TCP и молчит):

```
failurePolicy=Fail:   … context deadline exceeded (5232 ms)
failurePolicy=Ignore: pod/q-ignore-20753 created (235 ms)
```

С `Fail` каждый запрос к API, попадающий под правило, ждёт полный `timeoutSeconds` и падает: деплой, масштабирование, rollout'ы — всё в 5–30 раз медленнее и с ошибками. Метрики apiserver это видят (проверено):

```
apiserver_admission_webhook_rejection_count{error_type="calling_webhook_error",name="pods.policy.lab.local",...,rejection_code="503"} 15
apiserver_admission_webhook_fail_open_count{name="pods.policy.lab.local",type="validating"} 2      ← пропущено при Ignore
```

### Как не убить кластер вебхуком

| Мера | Зачем |
|---|---|
| `namespaceSelector`/`objectSelector`, исключающие `kube-system`, namespace самого вебхука | вебхук не блокирует свой же подъём и систему |
| `failurePolicy: Fail` только для политик безопасности, `Ignore` — для «желательных» | недоступность не останавливает всё |
| `timeoutSeconds` 2–5 с | быстрый отказ вместо ожидания 10–30 с |
| 2+ реплики вебхука, PDB, PriorityClass, anti-affinity | вебхук сам по себе — критичный компонент |
| `matchConditions` (CEL) | не вызывать вебхук для запросов, которые ему не нужны |
| алерты на `apiserver_admission_webhook_rejection_count{error_type="calling_webhook_error"}` и латентность вебхуков | узнать раньше пользователей |
| простые правила — ValidatingAdmissionPolicy (06-2) | в apiserver, без сетевого вызова |

Аварийно: удалить или поправить `…WebhookConfiguration` (`kubectl delete validatingwebhookconfiguration <имя>`) — объект конфигурации cluster-scoped и сам через вебхуки не проходит. После — вернуть, починив причину. Это должно быть в runbook'е, потому что вспоминают об этом в 3 часа ночи.

## 2. Finalizers и namespace в Terminating 🟡

Finalizer — обещание «перед удалением этого объекта кто-то выполнит очистку» (01-3 §5). Namespace удаляется, только когда в нём не осталось объектов; объект с finalizer'ом, который никто не снимет, держит весь namespace.

Проверено (ConfigMap с finalizer'ом `example.com/external-cleanup`, которого никто не обрабатывает):

```
lab-09-2-term   Terminating   9s
NamespaceContentRemaining=True: Some resources are remaining: configmaps. has 1 resource instances
NamespaceFinalizersRemaining=True: Some content in the namespace has finalizers remaining: example.com/external-cleanup in 1 resource instances
```

**Conditions namespace** — первое, что смотреть: они называют и тип объекта, и сам finalizer. Найти объекты — перебрать все listable-типы:

```bash
kubectl api-resources --verbs=list --namespaced -o name | xargs -n 30 | tr ' ' ',' \
  | while read t; do kubectl -n <ns> get $t --ignore-not-found -o name; done
```

Проверено: `configmap/stuck`. Снятие finalizer'а — namespace исчез за секунды.

Откуда такие finalizer'ы в жизни и что делать **до** снятия руками:

| Finalizer | Чей | Почему висит | Правильное действие |
|---|---|---|---|
| `kubernetes.io/pvc-protection` | kube-controller-manager | PVC использует под | удалить под |
| `foregroundDeletion` | GC | ждёт удаления зависимых | смотреть зависимые |
| `resources-finalizer.argocd.argoproj.io` | Argo CD | Argo CD удаляет ресурсы или его нет | вернуть Argo CD или снять осознанно (08-2) |
| `*.cnpg.io/*`, `postgresql.cnpg.io/…` | оператор БД | оператор удалён раньше своих CR | вернуть оператор, удалить CR, затем оператор (09-1) |
| `service.kubernetes.io/load-balancer-cleanup` | cloud-controller-manager | не может удалить облачный LB | права/квоты облака; иначе LB останется висеть и оплачиваться |
| `kubernetes` у самого namespace | namespace-controller | контент не удаляется | разбирать контент (выше) |

Порядок удаления «оператор + его объекты»: сначала CR (оператор выполнит очистку и снимет finalizer'ы), потом оператор и CRD. Обратный порядок — и все CR повиснут.

### Недоступный APIService 🔴

Классическая причина «namespace не удаляется, контента нет» — aggregated API (APIService), который не отвечает: namespace-controller не может перечислить ресурсы этой группы и не уверен, что namespace пуст. Проверено на стенде (metrics-server выключен, `APIService Available=False MissingEndpoints`): в Kubernetes 1.36 namespace **удалился** без ожидания — ресурсы `metrics.k8s.io` только для чтения, удалять в них нечего, и контроллер их пропускает. Зависание возникает с aggregated API, у которых есть удаляемые namespaced-ресурсы (кастомные API-серверы, сервисы каталогов). Симптом в conditions — `NamespaceDeletionDiscoveryFailure`; лечение — поднять APIService или удалить его объект (`kubectl get apiservice | grep False`). ⚠️ Зависание по этой причине на стенде не воспроизведено.

Убирать finalizer у самого namespace через `/finalize` (известный «рецепт» с `kubectl replace --raw …/finalize`) — значит бросить объекты в etcd без очистки: они останутся «сиротами» и всплывут, если namespace с тем же именем создадут снова. Только когда понятно, что именно бросаете.

---

## 🔧 Лаба

### Шаг 0. Подготовка

```bash
kubectl config use-context kind-lab
kubectl create ns lab-09-2
kubectl label ns lab-09-2 webhook.lab/policy=on
```

### Шаг 1. Вебхук без сервиса

```bash
kubectl apply -f - <<'EOF'
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingWebhookConfiguration
metadata: {name: lab-policy}
webhooks:
- name: pods.policy.lab.local
  admissionReviewVersions: [v1]
  sideEffects: None
  failurePolicy: Fail
  timeoutSeconds: 5
  namespaceSelector: {matchLabels: {webhook.lab/policy: "on"}}
  rules: [{apiGroups: [""], apiVersions: [v1], operations: [CREATE], resources: [pods]}]
  clientConfig:
    service: {name: policy-webhook, namespace: lab-09-2, path: /validate, port: 443}
EOF
kubectl -n lab-09-2 run p1 --image=busybox:1.37 -- sleep 60
kubectl -n default run p-default --image=busybox:1.37 --restart=Never -- sleep 5
kubectl -n lab-09-2 create deploy d1 --image=busybox:1.37 -- sleep 3600; sleep 5
kubectl -n lab-09-2 get deploy d1; kubectl -n lab-09-2 describe rs | grep -m1 'Error creating'
```

Проверено: вывод в §1.

### Шаг 2. Вебхук, который молчит

```bash
kubectl create ns lab-09-2-hook
kubectl -n lab-09-2-hook run hang --image=busybox:1.37 --labels=app=hang -- sh -c 'while true; do sleep 3600 | nc -l -p 443 >/dev/null; done'
kubectl -n lab-09-2-hook expose pod hang --name=policy-webhook --port=443
kubectl -n lab-09-2-hook wait --for=condition=Ready pod/hang
kubectl patch validatingwebhookconfiguration lab-policy --type=json -p '[{"op":"replace","path":"/webhooks/0/clientConfig/service/namespace","value":"lab-09-2-hook"}]'
for fp in Fail Ignore; do
  kubectl patch validatingwebhookconfiguration lab-policy --type=json -p "[{\"op\":\"replace\",\"path\":\"/webhooks/0/failurePolicy\",\"value\":\"$fp\"}]"; sleep 2
  s=$(date +%s%N); kubectl -n lab-09-2 run q-$(echo $fp | tr A-Z a-z)-$RANDOM --image=busybox:1.37 -- sleep 60
  echo "$fp: $(( ($(date +%s%N)-s)/1000000 )) ms"
done
kubectl get --raw /metrics | grep -E '^apiserver_admission_webhook_(rejection_count|fail_open_count)' | grep lab
kubectl delete validatingwebhookconfiguration lab-policy          # аварийное «выключение» вебхука
```

`sleep 3600 |` держит stdin `nc` открытым — без этого busybox-nc закрывает соединение сразу, и apiserver получает мгновенный `EOF` вместо таймаута (проверено). Проверено: вывод в §1.

### Шаг 3. Namespace в Terminating

```bash
kubectl create ns lab-09-2-term
kubectl -n lab-09-2-term create cm stuck --from-literal=a=1
kubectl -n lab-09-2-term patch cm stuck -p '{"metadata":{"finalizers":["example.com/external-cleanup"]}}'
kubectl delete ns lab-09-2-term --wait=false; sleep 8
kubectl get ns lab-09-2-term
kubectl get ns lab-09-2-term -o jsonpath='{range .status.conditions[*]}{.type}={.status}: {.message}{"\n"}{end}' | grep -v '=False'
kubectl api-resources --verbs=list --namespaced -o name | xargs -n 30 | tr ' ' ',' \
  | while read t; do kubectl -n lab-09-2-term get $t --ignore-not-found -o name; done
kubectl -n lab-09-2-term patch cm stuck --type=json -p '[{"op":"remove","path":"/metadata/finalizers"}]'
sleep 6; kubectl get ns lab-09-2-term
```

Проверено: вывод в §2.

### Шаг 4. Namespace при недоступном APIService

```bash
kubectl create ns lab-09-2-disc && kubectl -n lab-09-2-disc create cm plain --from-literal=a=1
kubectl -n kube-system scale deploy metrics-server --replicas=0; sleep 20
kubectl get apiservice v1beta1.metrics.k8s.io -o jsonpath='{.status.conditions[0].status} {.status.conditions[0].reason}{"\n"}'
kubectl delete ns lab-09-2-disc --wait=false; sleep 15
kubectl get ns lab-09-2-disc
kubectl -n kube-system scale deploy metrics-server --replicas=1
kubectl -n kube-system rollout status deploy/metrics-server; sleep 20; kubectl top nodes
```

Проверено: `False MissingEndpoints`, namespace удалён без ожидания (§2), после возврата metrics-server `kubectl top` работает.

### Уборка

```bash
kubectl delete ns lab-09-2 lab-09-2-hook
kubectl get validatingwebhookconfiguration lab-policy 2>&1 | tail -1      # NotFound
```

---

## 🔥 Кейс из прода: «упал сервис вебхука — никто не может задеплоить»

**Контекст.** В кластере стоял policy-engine (вебхук, одна реплика, `failurePolicy: Fail`, правила на все поды во всех namespace, `timeoutSeconds: 30`). Узел с его подом перезагрузился. Через минуту: CI получает `failed calling webhook` на каждом деплое, HPA не может создать поды, а сам под policy-engine не может подняться — его создание тоже идёт через собственный вебхук.

**Разбор.**
1. События ReplicaSet'ов по всему кластеру: `Error creating: Internal error occurred: failed calling webhook …` (шаг 1 лабы — то же сообщение).
2. Вебхук охватывал и свой namespace, и `kube-system` — взаимная блокировка.
3. Каждый запрос ждал 30 с таймаута — apiserver под нагрузкой ретраев от контроллеров, `kubectl` «висит».

**Фикс.**
- Немедленно: `kubectl delete validatingwebhookconfiguration <policy>` → поды поднялись, затем конфигурацию вернули.
- `namespaceSelector`, исключающий `kube-system` и namespace самого вебхука; `timeoutSeconds: 5`; 3 реплики, PDB, PriorityClass.
- `failurePolicy: Fail` — только для правил безопасности; остальные правила — `Ignore` или перенос в ValidatingAdmissionPolicy (06-2).
- Алерт на `calling_webhook_error` и runbook «вебхук блокирует кластер» в два шага.

**Что запомнить.**
- Вебхук с `Fail` на все поды — единая точка отказа всего кластера.
- Вебхук не должен действовать на собственный namespace и системные.
- Аварийный выход — удалить конфигурацию вебхука (cluster-scoped, через вебхуки не проходит).

---

## 💼 Вопросы с собеседования

### 🟢 Junior

**1. Что такое admission webhook?**
HTTPS-сервис, который apiserver вызывает при создании/изменении объектов: mutating может изменить объект, validating — разрешить или запретить. Так работают инжекторы sidecar'ов и движки политик.

**2. Что такое finalizer?**
Строка в `metadata.finalizers`: объект не удалится, пока её не снимет контроллер после очистки (01-3).

### 🟡 Middle

**3. Чем опасен `failurePolicy: Fail`?**
Если вебхук недоступен или тормозит, все попадающие под правило запросы к API отказываются (или ждут таймаут до 30 с). Без исключений для системных namespace и своего — взаимная блокировка кластера.

**4. Namespace висит в Terminating. Ваши действия?**
`kubectl get ns <ns> -o yaml` → `status.conditions`: какие объекты остались и какие finalizer'ы их держат (или ошибка discovery). Найти объекты перебором listable-типов, понять, чей finalizer, вернуть контроллер или выполнить очистку, и только потом снимать finalizer руками.

**5. Как временно выключить сломанный вебхук?**
Удалить или исправить `ValidatingWebhookConfiguration`/`MutatingWebhookConfiguration` — они cluster-scoped и не проходят через вебхуки. Затем вернуть с исправлением.

### 🔴 Senior

**6. Как спроектировать надёжный admission webhook?**
2+ реплики с PDB и PriorityClass, anti-affinity; селекторы, исключающие системные namespace и свой; `matchConditions` для отсечения лишних вызовов; `timeoutSeconds` 2–5; `failurePolicy` по критичности правила; TLS и `caBundle` через cert-manager; метрики латентности и ошибок вызовов; для простых проверок — ValidatingAdmissionPolicy без сетевого вызова.

**7. Почему нельзя «просто» снять finalizer с namespace через `/finalize`?**
Namespace исчезнет из API, но объекты в нём останутся в etcd без очистки (внешние ресурсы — LB, диски — тоже). При повторном создании namespace с тем же именем они «оживут». Корректно — устранить причину: вернуть контроллер finalizer'а или APIService.

---

## ⚠️ Подводные камни

- Вебхук на все поды без исключений блокирует собственный подъём и системные компоненты.
- `timeoutSeconds` по умолчанию 10 с — каждый запрос ждёт столько при недоступном вебхуке.
- Ошибки вебхуков у подов контроллеров — в событиях ReplicaSet/Job.
- Удаление оператора раньше его CR оставляет finalizer'ы, которые некому снять.
- Снятие finalizer'а оставляет внешние ресурсы (диски, LB), за которые платят.
- `/finalize` для namespace бросает объекты в etcd.
- busybox-`nc` для имитации зависшего сервиса закрывает соединение без открытого stdin.
- Mutating webhook может сделать объект несовместимым с последующими validating-проверками (06-2 §4).

---

## Чеклист

- [ ] Опишу вебхук с селекторами, таймаутом и политикой отказа и объясню выбор.
- [ ] Найду, какой вебхук блокирует запросы, по ошибке и метрикам.
- [ ] Аварийно отключу вебхук и верну его.
- [ ] Разберу namespace в Terminating по его conditions.
- [ ] Объясню правильный порядок удаления оператора и его объектов.

---

## Задание со звёздочкой

Напишите работающий validating webhook без кода на компилируемом языке:

1. Сервер на Python (`http.server` + `ssl`) в поде: принимает `AdmissionReview`, запрещает поды без метки `team`, отвечает `allowed: false` с понятным `status.message`.
2. Сертификат для `policy-webhook.<ns>.svc` выпустите cert-manager'ом (03-4) и подставьте `caBundle` аннотацией `cert-manager.io/inject-ca-from`.
3. Включите вебхук с `failurePolicy: Fail` для namespace с меткой, проверьте отказ и пропуск.
4. Перепишите то же правило как ValidatingAdmissionPolicy (06-2) и сравните: строки кода, задержка, что будет при падении пода.

---

→ Следующая часть: **10-2. Обновление кластера** — модуль «Эксплуатация кластера»: version skew, `kubeadm upgrade plan/apply` под нагрузкой, удалённые API, обновление kubelet по узлам. Часть 10-1 в этой версии курса не опубликована (00-plan §0).
