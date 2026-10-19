# 04-1. ConfigMap и Secret

> Модуль 4 «Конфигурация и данные» · часть 1 из 3 · 🟢🟡🔴 · ~1 ч чтения + ~1 ч лабы · Нужно: стенд 00-1. В лабе на время включается шифрование Secret в etcd на control-plane — в конце стенд возвращается в исходное состояние.

---

## Зачем это DevOps-у

«Поменяли конфиг — ничего не произошло», «поменяли — у половины подов старое значение», «пароль от БД виден любому, у кого есть доступ к etcd или к бэкапу», «ConfigMap не создаётся — слишком большой». Конфигурация и секреты — ежедневная работа и любимая тема собеседований: «безопасен ли Secret», «как подхватить новый конфиг без рестарта», «почему subPath не обновляется».

В сквозном сценарии orders-api берёт `DATABASE_URL` из Secret `postgres` (env) и `config.json` из ConfigMap `orders-config` (том `/etc/orders`); ручка `/config` показывает, что приложение видит прямо сейчас.

---

## 1. Способы передать конфигурацию 🟢

| Способ | Как | Видит изменения? |
|---|---|---|
| `env` / `envFrom` из ConfigMap/Secret | переменные при старте контейнера | **нет** — до рестарта контейнера |
| том `configMap` / `secret` | файлы в каталоге, по ключу на файл | **да**, с задержкой (замер ниже) |
| том с `subPath` | один файл в существующий каталог | **нет** — никогда |
| projected volume | несколько источников (ConfigMap, Secret, downward API, токен SA) в одном каталоге | да |
| аргументы команды `$(VAR)` | подстановка env в `args` | нет |

Проверено (под orders-api: `FEATURE_DISCOUNT` из ConfigMap в env, `config.json` томом в `/etc/orders` и тот же ключ через `subPath` в `/etc/orders-subpath/`), после `kubectl patch configmap` с новыми значениями:

```
before: env=off volume=0 subPath=0
+80s:   env=off volume=15 subPath=0
+170s:  env=off volume=15 subPath=0
```

Задержка обновления тома — не мгновенная: замеры **47, 63 и 80 с**. Kubelet (`configMapAndSecretChangeDetectionStrategy: Watch`, `syncFrequency: 1m` — проверено через `/configz`) обновляет тома при очередной синхронизации пода; в документации — «до периода синхронизации плюс TTL кэша».

Как устроен том изнутри (проверено):

```
drwxr-xr-x ..2026_10_14_10_20_14.3300762722
lrwxrwxrwx ..data -> ..2026_10_14_10_20_14.3300762722
lrwxrwxrwx config.json -> ..data/config.json
```

Kubelet пишет новый каталог с меткой времени и **атомарно** переключает симлинк `..data`. Приложение видит либо старую, либо новую версию целиком, никогда — половину файла. `subPath` монтирует сам файл (bind mount по inode), а не симлинк — поэтому обновление его не касается.

Следствия:

- Приложение должно **перечитать** файл: inotify на каталог (а не на файл — симлинк меняется), периодическое чтение, `SIGHUP`. orders-api читает `config.json` на каждом запросе к `/config`, поэтому видит изменение сразу после подмены.
- Env и `subPath` требуют рестарта подов. Стандартный приём — аннотация с хэшем конфига в шаблоне пода (`checksum/config: <sha256>` в Helm, суффикс-хэш в имени у Kustomize `configMapGenerator`) — изменение конфига меняет шаблон и запускает rollout (07-1, 07-3).
- Разные поды обновят том в разное время (47–80 с) — в течение минуты у подов разная конфигурация.

## 2. Ограничения и immutable 🟡

- **Размер** ConfigMap и Secret — не больше **1 МиБ** (проверено: `ConfigMap "big" is invalid: []: Too long: may not be more than 1048576 bytes`). Большие файлы (модели, словари) — в образ, на том или в объектное хранилище.
- **`immutable: true`** — объект нельзя менять (проверено: `data: Forbidden: field is immutable when immutable is set`), и обратно в изменяемый — тоже нельзя. Kubelet перестаёт следить за такими объектами — на кластерах с десятками тысяч ConfigMap это снимает заметную нагрузку с apiserver. Обновление — новый объект с новым именем (`app-config-v42`) и rollout, что заодно даёт откат.
- ConfigMap и Secret — объекты **namespace**: под не может сослаться на ConfigMap другого namespace.
- `optional: true` у ссылки — под стартует без объекта/ключа; без него — `CreateContainerConfigError` (02-1).

## 3. Secret: что он даёт и чего нет 🟡🔴

Secret — это ConfigMap с другим типом и чуть более аккуратным обращением:

| Свойство | Есть? |
|---|---|
| значения в base64 | да — это **кодирование**, не шифрование (проверено: `UzNjcjN0LVBAc3M=` → `S3cr3t-P@ss` одной командой `base64 -d`) |
| отдельные права RBAC (`get/list secrets`) | да — главное отличие (часть 06-1 не опубликована, 00-plan §0) |
| том Secret в tmpfs на узле (не на диске) | да |
| шифрование в etcd | **нет по умолчанию** |
| не попадают в логи и `describe` | `describe` не показывает значения; в `-o yaml` — base64 |

Проверено: в etcd стенда пароль лежит открытым текстом:

```
$ etcdctl get /registry/secrets/lab-04-1/db --print-value-only | strings | grep -E 'S3cr3t|password'
password
S3cr3t-P@ss
```

Кто может прочитать Secret, не имея прав в API: любой с доступом к etcd (порт 2379 control-plane, сертификаты из `/etc/kubernetes/pki/etcd/`), к **бэкапам etcd** (10-1), к диску узлов control-plane, к узлу, где смонтирован Secret (root на узле видит tmpfs). Плюс через API: право `get` на secrets, право `create pods` в namespace (под монтирует любой Secret namespace — 06-1), `exec` в под, где Secret в env.

### Шифрование в etcd (encryption at rest) 🔴

kube-apiserver шифрует выбранные ресурсы перед записью в etcd по `EncryptionConfiguration`:

```yaml
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
- resources: [secrets]
  providers:
  - secretbox:                    # первый провайдер — им ШИФРУЮТСЯ новые записи
      keys:
      - name: key1
        secret: <32 случайных байта в base64>
  - identity: {}                  # остальные — для ЧТЕНИЯ старых записей
```

Флаг `--encryption-provider-config` на apiserver. Проверено на стенде (лаба, шаг 4):

```
old secret db:   k 8 s \0 \n \f \n 002 v 1 022 006 S e c r e t ...     contains plaintext: 1
new secret db2:  k 8 s : e n c : s e c r e t b o x : v 1 : k e y 1 : ...   contains plaintext: 0
S3cr3t-P@ss ← API отдаёт расшифрованным
after rewrite, old secret db:  k 8 s : e n c : s e c r e t b o x : v 1 : k e y 1 : ...   contains plaintext: 0
```

- Включение шифрует только **новые** записи. Старые — после перезаписи: `kubectl get secrets -A -o json | kubectl replace -f -`.
- Ключ лежит в файле на control-plane рядом с etcd — защищает от утечки **бэкапов и дисков etcd**, но не от root на control-plane. Следующая ступень — провайдер **KMS v2**: ключ шифрования данных (DEK) зашифрован ключом во внешнем KMS (Vault, облачный KMS), apiserver не хранит мастер-ключ (⚠️ KMS на стенде не проверялся).
- Порядок провайдеров важен: первый шифрует. Ротация ключа: добавить новый ключ вторым → перезапустить apiserver'ы → поставить первым → перезапустить → перезаписать секреты → убрать старый. Перепутанный порядок на одном из нескольких apiserver'ов — часть секретов не читается остальными.
- Метрика `apiserver_storage_transformation_operations_total{transformer_prefix=…}` показывает, какие провайдеры реально используются при чтении (проверено: после включения — и `identity`, и `k8s:enc:secretbox:v1:`).
- Отключение — в обратном порядке: `identity` первым, перезапуск, перезапись всех секретов (проверено: `encrypted secrets left: 0`), затем убрать флаг.

Managed-кластеры (EKS, GKE, AKS, YC) шифруют etcd на своей стороне и дают включить KMS-шифрование Secret ключом из облачного KMS.

### Внешние секреты 🟡

Хранить секреты в Git нельзя даже в base64. Варианты — подробно в 08-2 и курсе `security`:

| Подход | Где живёт секрет | В кластере |
|---|---|---|
| External Secrets Operator | Vault, AWS SM, YC Lockbox… | синхронизирует в обычный Secret |
| Secrets Store CSI Driver | там же | монтирует томом, опционально синхронизирует в Secret |
| Sealed Secrets / SOPS | зашифрованный файл в Git | контроллер/инструмент расшифровывает в Secret |
| Vault Agent sidecar/injector | Vault | файл в поде, без объекта Secret |

## 4. ConfigMap против переменных образа и флагов 🟢

| Что | Куда |
|---|---|
| значения, разные между окружениями (URL, флаги функций, уровни логов) | ConfigMap |
| пароли, токены, ключи, сертификаты | Secret (или внешний менеджер) |
| то, что меняется вместе с кодом (дефолты, схемы) | в образ |
| большие данные (>1 МиБ) | образ, том, объектное хранилище |

---

## 🔧 Лаба

### Шаг 0. Подготовка

```bash
kubectl config use-context kind-lab
kubectl create ns lab-04-1
kubectl config set-context --current --namespace=lab-04-1
kubectl create configmap app --from-literal=FEATURE_DISCOUNT=off \
  --from-literal=config.json='{"discount_percent": 0, "banner": "welcome"}'
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata: {name: api}
spec:
  containers:
  - name: api
    image: localhost:5001/orders-api:2.0
    env: [{name: FEATURE_DISCOUNT, valueFrom: {configMapKeyRef: {name: app, key: FEATURE_DISCOUNT}}}]
    volumeMounts:
    - {name: cfg, mountPath: /etc/orders}
    - {name: cfg, mountPath: /etc/orders-subpath/config.json, subPath: config.json}
  volumes: [{name: cfg, configMap: {name: app, items: [{key: config.json, path: config.json}]}}]
EOF
kubectl wait --for=condition=Ready pod/api
show() { kubectl exec api -- python -c "
import json,urllib.request
c=json.loads(urllib.request.urlopen('http://127.0.0.1:8000/config').read())
sub=json.load(open('/etc/orders-subpath/config.json'))
print('env='+str(c['env_FEATURE_DISCOUNT']), 'volume='+str(c['file'].get('discount_percent')), 'subPath='+str(sub.get('discount_percent')))"; }
show
kubectl exec api -- ls -la /etc/orders/
```

### Шаг 1. Изменить ConfigMap и засечь

```bash
kubectl patch configmap app -p '{"data":{"FEATURE_DISCOUNT":"on","config.json":"{\"discount_percent\": 15, \"banner\": \"sale\"}"}}'
t0=$(date +%s); until show | grep -q 'volume=15'; do sleep 2; done; echo "+$(( $(date +%s)-t0 ))s: $(show)"
sleep 90; show
for v in 20 25; do
  kubectl patch configmap app -p "{\"data\":{\"config.json\":\"{\\\"discount_percent\\\": $v}\"}}"
  t0=$(date +%s); until kubectl exec api -- cat /etc/orders/config.json | grep -q "$v"; do sleep 1; done
  echo "change to $v: volume updated after $(( $(date +%s)-t0 ))s"
done
kubectl get --raw /api/v1/nodes/$(kubectl get pod api -o jsonpath='{.spec.nodeName}')/proxy/configz | jq -c '.kubeletconfig | {configMapAndSecretChangeDetectionStrategy, syncFrequency}'
```

Проверено: вывод в §1 (80 с; 47 и 63 с при повторах).

### Шаг 2. Ограничения

```bash
kubectl create configmap frozen --from-literal=k=v1
kubectl patch configmap frozen -p '{"immutable":true}'
kubectl patch configmap frozen -p '{"data":{"k":"v2"}}'
kubectl patch configmap frozen -p '{"immutable":false}'
head -c 1100000 /dev/urandom | base64 -w0 | head -c 1100000 > /tmp/big.txt
kubectl create configmap big --from-file=/tmp/big.txt; rm /tmp/big.txt
```

Проверено: два `Forbidden: field is immutable when immutable is set` и `Too long: may not be more than 1048576 bytes`.

### Шаг 3. Secret: base64 и etcd

```bash
kubectl create secret generic db --from-literal=password='S3cr3t-P@ss'
kubectl get secret db -o jsonpath='{.data.password}'; echo
kubectl get secret db -o jsonpath='{.data.password}' | base64 -d; echo
E='etcdctl --endpoints=https://127.0.0.1:2379 --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt --key=/etc/kubernetes/pki/etcd/server.key'
kubectl -n kube-system exec etcd-lab-control-plane -- $E get /registry/secrets/lab-04-1/db --print-value-only | strings | grep -E 'S3cr3t|password'
```

Проверено: вывод в §3.

### Шаг 4. Включить шифрование Secret в etcd

Резервная копия манифеста — **вне** `/etc/kubernetes/manifests` (kubelet запускает любой `.yaml` из этого каталога):

```bash
CP=lab-control-plane
docker exec $CP sh -c 'cp /etc/kubernetes/manifests/kube-apiserver.yaml /root/kube-apiserver.yaml.bak; mkdir -p /etc/kubernetes/enc'
KEY=$(head -c 32 /dev/urandom | base64)
docker exec -i $CP sh -c 'cat > /etc/kubernetes/enc/enc.yaml; chmod 600 /etc/kubernetes/enc/enc.yaml' <<EOF
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
- resources: [secrets]
  providers:
  - secretbox:
      keys:
      - name: key1
        secret: $KEY
  - identity: {}
EOF
unset KEY
docker exec $CP sh -c "
sed -i 's|^    - --etcd-servers=https://127.0.0.1:2379|&\n    - --encryption-provider-config=/etc/kubernetes/enc/enc.yaml|' /etc/kubernetes/manifests/kube-apiserver.yaml
sed -i 's|^    volumeMounts:|&\n    - {mountPath: /etc/kubernetes/enc, name: enc, readOnly: true}|' /etc/kubernetes/manifests/kube-apiserver.yaml
sed -i 's|^  volumes:|&\n  - {hostPath: {path: /etc/kubernetes/enc, type: DirectoryOrCreate}, name: enc}|' /etc/kubernetes/manifests/kube-apiserver.yaml
grep -n enc /etc/kubernetes/manifests/kube-apiserver.yaml"
sleep 20; until kubectl get --raw /readyz >/dev/null 2>&1; do sleep 2; done      # у автора — ~44 с

ec() { kubectl -n kube-system exec etcd-lab-control-plane -- $E get /registry/secrets/lab-04-1/$1 --print-value-only | head -c 40 | od -c | head -2
       echo "   contains plaintext: $(kubectl -n kube-system exec etcd-lab-control-plane -- $E get /registry/secrets/lab-04-1/$1 --print-value-only | strings | grep -c S3cr3t)"; }
kubectl create secret generic db2 --from-literal=password='S3cr3t-P@ss'
ec db; ec db2
kubectl get secret db2 -o jsonpath='{.data.password}' | base64 -d; echo
kubectl get secrets -A -o json | kubectl replace -f - > /dev/null
ec db
kubectl get --raw /metrics | grep '^apiserver_storage_transformation_operations_total' | head -3
```

Проверено: вывод в §3. Ключ не печатается и не сохраняется нигде, кроме файла на control-plane.

### Шаг 5. Вернуть как было

```bash
# 1) identity — первым: новые записи не шифруются, старые ещё читаются ключом
docker exec $CP sh -c "awk '/providers:/{print; print \"  - identity: {}\"; next} /^  - identity: \{\}/{next} {print}' /etc/kubernetes/enc/enc.yaml > /tmp/enc.new && mv /tmp/enc.new /etc/kubernetes/enc/enc.yaml"
# 2) перезапустить apiserver, чтобы он перечитал конфигурацию
docker exec $CP mv /etc/kubernetes/manifests/kube-apiserver.yaml /root/kas.tmp; sleep 15
docker exec $CP mv /root/kas.tmp /etc/kubernetes/manifests/kube-apiserver.yaml; sleep 10
until kubectl get --raw /readyz >/dev/null 2>&1; do sleep 2; done
# 3) перезаписать — все секреты в открытом виде
kubectl get secrets -A -o json | kubectl replace -f - > /dev/null
echo "encrypted secrets left: $(kubectl -n kube-system exec etcd-lab-control-plane -- $E get /registry/secrets --prefix --print-value-only | grep -ac 'k8s:enc:')"
# 4) исходный манифест и уборка ключа
docker exec $CP sh -c 'cp /root/kube-apiserver.yaml.bak /etc/kubernetes/manifests/kube-apiserver.yaml'
sleep 25; until kubectl get --raw /readyz >/dev/null 2>&1; do sleep 2; done
docker exec $CP sh -c 'grep -c encryption /etc/kubernetes/manifests/kube-apiserver.yaml; rm -rf /etc/kubernetes/enc /root/kube-apiserver.yaml.bak; ls /etc/kubernetes/manifests'
```

Проверено: `encrypted secrets left: 0`, в манифесте `0` упоминаний encryption, в каталоге манифестов — 4 файла, `curl …/api/orders` — 200. Если удалить ключ до перезаписи — зашифрованные секреты станут нечитаемыми навсегда (кластер не стартует контроллеры, которым нужны токены): порядок шагов обязателен.

### Шаг 6 (по желанию). Сквозной сценарий

```bash
kubectl -n orders patch configmap orders-config -p '{"data":{"config.json":"{\"discount_percent\": 10, \"banner\": \"autumn\"}"}}'
sleep 90; curl -s -H 'Host: orders.localhost' http://127.0.0.1:8088/config      # file.discount_percent = 10
kubectl apply -f ~/lab/k8s/orders-api/k8s/orders-api.yaml                      # вернуть исходный ConfigMap
```

### Уборка

```bash
kubectl config set-context --current --namespace=default
kubectl delete ns lab-04-1
```

---

## 🔥 Кейс из прода: «поменяли конфиг — ничего не произошло; поменяли ещё раз — половина подов со старым»

**Контекст.** Сервис читает `application.yaml` из ConfigMap, смонтированного через `subPath` в `/app/config/application.yaml` (в каталоге уже лежали другие файлы из образа). Изменили лимит запросов к партнёру — эффекта нет. Сделали `kubectl rollout restart` части подов «для проверки» — у перезапущенных новое значение, у остальных старое; партнёр начал отбивать запросы от «старых» подов.

**Разбор.**
1. `subPath` — снимок файла на момент старта контейнера; обновления ConfigMap до него не доходят никогда (шаг 1 лабы: `subPath=0` через 170 с).
2. Частичный рестарт создал смешанную конфигурацию — то, чего не бывает при нормальном rollout.
3. Даже без `subPath` поды обновили бы файл в разное время (47–80 с), и приложение должно было бы уметь перечитывать конфиг.

**Фикс.**
- Конфиг монтируется каталогом (`/app/config-override/`), приложение читает его поверх встроенного; без `subPath`.
- Изменение конфигурации = rollout: в Helm-шаблоне `checksum/config: {{ include (print $.Template.BasePath "/configmap.yaml") . | sha256sum }}` в аннотациях пода. Конфиг меняется → шаблон пода меняется → управляемый rolling update с readiness, а не ручные рестарты.
- Для действительно «горячих» параметров — перечитывание каталога по inotify с атомарной подменой `..data`.

**Что запомнить.**
- `subPath` и env не обновляются; том — обновляется, но с задержкой до минуты и в разное время на разных подах.
- Изменение конфигурации должно идти тем же процессом, что и изменение кода: rollout.
- Приложение, которое «перечитывает конфиг», должно следить за каталогом, а не за файлом.

---

## 💼 Вопросы с собеседования

### 🟢 Junior

**1. Чем ConfigMap отличается от Secret?**
По сути — ничем, кроме типа и прав: Secret хранит значения в base64, имеет отдельные права RBAC, монтируется в tmpfs; по умолчанию не шифруется. Для паролей и ключей — Secret (лучше внешний менеджер), для обычной конфигурации — ConfigMap.

**2. Как передать ConfigMap в под?**
Переменными (`env`/`envFrom`) или томом (файл на ключ). Переменные фиксируются при старте, том обновляется.

### 🟡 Middle

**3. Поменяли ConfigMap, приложение не видит изменений. Почему?**
Если через env или `subPath` — не увидит до рестарта. Если томом — kubelet обновит файл через ~1 минуту (на стенде 47–80 с), но приложение должно его перечитать. Решение для env — rollout по хэшу конфига (Helm checksum, Kustomize generator).

**4. Безопасен ли Secret?**
Base64 — не шифрование. В etcd по умолчанию открытый текст; доступ к etcd или его бэкапу = доступ к секретам. Через API их читают те, у кого есть `get secrets` или право создавать поды в namespace. Защита: RBAC, шифрование в etcd (EncryptionConfiguration, лучше KMS v2), внешние менеджеры секретов, аудит.

**5. Что даёт `immutable: true`?**
Объект нельзя изменить, kubelet перестаёт за ним следить (меньше нагрузки на apiserver), исключены случайные правки. Обновление — новый объект с новым именем и rollout, что даёт простой откат.

### 🔴 Senior

**6. Как включить шифрование Secret в существующем кластере и не потерять данные?**
EncryptionConfiguration с новым провайдером первым и `identity` следом → флаг на всех apiserver'ах и перезапуск → перезапись всех Secret (`get -o json | replace`) → проверка через etcdctl и метрики трансформаций. Ротация ключа — добавить новый вторым, перезапустить, поднять первым, перезапустить, перезаписать, убрать старый. Ключ в файле защищает бэкапы и диски etcd; от root на control-plane — только KMS v2.

**7. Почему обновление тома ConfigMap атомарно и как это использовать?**
Kubelet пишет новую версию в каталог с меткой времени и переключает симлинк `..data` одной операцией rename. Приложение видит старую или новую версию целиком. Следить надо за каталогом (событие на `..data`), а не за файлом.

**8. Где хранить конфигурацию 300 микросервисов?**
В Git рядом с манифестами (Helm values/Kustomize overlays), без секретов; секреты — во внешнем менеджере с синхронизацией (ESO) или CSI; изменения через GitOps и rollout по хэшу. Неизменяемые ConfigMap с версией в имени — для откатов и снижения нагрузки на kubelet/apiserver. Большие данные — не в ConfigMap (лимит 1 МиБ, нагрузка на etcd).

---

## ⚠️ Подводные камни

- `subPath` никогда не обновляется.
- Env из ConfigMap/Secret фиксируются при старте.
- Обновление тома — до ~1 минуты и в разное время на разных подах.
- Приложение следит за файлом, а не каталогом, — пропускает подмену симлинка.
- Лимит 1 МиБ на объект.
- `immutable: true` необратим.
- Base64 ≠ шифрование; etcd и его бэкапы хранят Secret открытым текстом без EncryptionConfiguration.
- Включение шифрования не трогает старые записи — нужна перезапись.
- Удалить ключ до перезаписи секретов — потерять их.
- Резервную копию static pod манифеста нельзя класть в `/etc/kubernetes/manifests`.

---

## Чеклист

- [ ] Выберу между env, томом и subPath и объясню, что увижу при изменении.
- [ ] Измерю задержку обновления тома и объясню механизм `..data`.
- [ ] Настрою rollout по хэшу конфигурации.
- [ ] Покажу, что Secret в etcd хранится открытым текстом, и включу шифрование.
- [ ] Безопасно отключу или ротирую ключ шифрования.
- [ ] Перечислю способы держать секреты вне Git и вне etcd.

---

## Задание со звёздочкой

Научите orders-api подхватывать конфиг без рестарта:

1. Добавьте в `app/main.py` поток, который раз в секунду проверяет `os.stat('/etc/orders/..data').st_ino` и при изменении перечитывает `config.json` в память (а `/config` отдаёт кэш).
2. Соберите `orders-api:2.2`, задеплойте, поменяйте `orders-config` и засеките, через сколько `/config` покажет новое значение. Сравните с 47–80 с.
3. Объясните, почему проверка `st_mtime` файла `config.json` могла бы не сработать.
4. Как бы вы сделали то же для Secret с паролем БД (пул соединений уже открыт)?

---

→ Следующая часть: **04-2. Хранилище: PV, PVC, StorageClass, CSI** — local-path стенда изнутри, `WaitForFirstConsumer`, access modes, reclaimPolicy Delete и Retain, расширение тома, почему PVC «привязан» к узлу и под с ним не переезжает.
