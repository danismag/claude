# 06-2. Изоляция контейнера

> Модуль 06 «Доступ и безопасность» · часть 2 из 4 · ~1,5 ч чтения + ~1 ч лабы · Нужно: стенд 00-1 (контекст `kind-lab`), образы `busybox:1.37` и `orders-api:2.0` в реестре стенда; для работы 3 — ядро хоста 6.3 или новее · Опирается на: 01-2 (namespaces, cgroups, runc), 02-1 (под, user namespaces), 04-2 (SELinux и тома)

## Где мы на карте

Эта часть разбирает механизмы ядра и kubelet, которые отделяют контейнер от узла и от соседних контейнеров. В 06-1 мы решали, кто может обращаться к API. Здесь мы решаем, что может сделать процесс внутри контейнера, если приложение взломали или оно ошиблось. Часть опирается на 01-2, где описаны namespaces, cgroups и runc, и на 02-1, где определены под и его общие ресурсы.

Следующая часть, 06-3, показывает, как кластер заставляет поды применять эти настройки: Pod Security Admission проверяет поля манифеста при создании пода. Сами настройки применяют kubelet и containerd, поэтому сначала нужно понять, что именно они включают.

```
Запрос к API ──► RBAC (06-1) ──► admission (06-3) ──► kubelet ──► containerd + runc
                                     проверяет поля          │         включают изоляцию:
                                                             ▼
                                   uid и группы · capabilities · seccomp · AppArmor
                                   SELinux · user namespace · RuntimeClass (песочница)
```

Схема 1. Поля манифеста проверяет admission (06-3), а изоляцию создают kubelet, containerd и runc на узле; эта часть описывает правую половину схемы.

---

## 1. Какую задачу решает изоляция контейнера

Изоляция ограничивает ущерб: если процесс в контейнере скомпрометирован, он не должен получить узел. Разберём, почему контейнер сам по себе слабая граница и какие слои её усиливают.

### Контейнер — процесс на общем ядре

**Контейнер** (container) в узле Kubernetes — обычный процесс Linux, к которому runc применил namespaces и cgroups (01-2). У всех контейнеров узла общее ядро, поэтому ошибка в ядре или лишнее право у процесса открывают путь к узлу и ко всем подам на нём. Namespaces скрывают чужие ресурсы, а cgroups ограничивают потребление, но ни то ни другое не отнимает у процесса права.

По умолчанию контейнер запускается от пользователя образа (чаще всего root), с набором из 14 capabilities и без фильтра системных вызовов. Это удобно для запуска любого образа и плохо для безопасности. Задача этой части — вычесть из процесса всё, что приложению не нужно.

### Слои изоляции

Каждый слой закрывает свой класс проблем, и ни один не заменяет остальные. Перечислим их от самого внутреннего к самому внешнему.

- **Пользователь** — кем работает процесс: root или обычный uid.
- **Capabilities** — какие привилегированные операции доступны процессу.
- **seccomp** — какие системные вызовы он вправе делать.
- **LSM** (Linux Security Module, модуль безопасности ядра) — AppArmor или SELinux ограничивают доступ к файлам и объектам ядра.
- **User namespace** — чему равен root контейнера на самом узле.
- **Песочница** (sandbox) — отдельное ядро или ВМ между контейнером и узлом.

```
 процесс в контейнере
   │ uid ≠ 0, группы                ← кем он работает
   │ capabilities                   ← что он может как привилегированный
   │ no_new_privs                   ← не вырастет ли он через setuid
   │ seccomp                        ← какие вызовы ядра доступны
   │ AppArmor / SELinux             ← какие файлы и объекты доступны
   │ user namespace                 ← кому на узле соответствует его root
   ▼
 общее ядро узла   (или ядро песочницы: gVisor, Kata)
```

Схема 2. Слои изоляции процесса; чем выше слой в списке, тем чаще его настраивают в обычных приложениях.

### Кто что задаёт

Настройки приложения лежат в поле `securityContext` пода и контейнера, а настройки узла — в конфигурации kubelet и в рантайме. Приложение запрашивает ужесточение, а узел его применяет или отказывает. Pod Security Admission (06-3) только проверяет, что поля заполнены: профиль seccomp или AppArmor он не включает и не загружает.

---

## 2. Как устроена изоляция на узле

Каждый слой изоляции соответствует механизму ядра. Разберём пользователей, capabilities, запрет роста привилегий, seccomp и LSM по очереди.

### Пользователь и группы

Процесс в контейнере работает под **uid** (user id, числовой номер пользователя) и **gid** (group id, числовой номер группы). По умолчанию их берёт образ из инструкции `USER`, а если её нет, процесс идёт от root с uid 0. Ядро не смотрит на имена, только на числа, поэтому kubelet сверяет uid с образом по числу, а не по имени.

В Kubernetes три поля управляют пользователем. Поле `runAsUser` задаёт uid, `runAsGroup` задаёт основную группу (без него это группа 0), а `runAsNonRoot: true` запрещает старт, если итоговый uid равен 0. Последнее поле ничего не меняет в процессе: оно только проверяет и отказывает, когда образ собирались запускать от root.

Тома требуют согласованных владельцев. Поле `fsGroup` делает том читаемым и записываемым для группы с этим gid: kubelet меняет владельца файлов тома, а процессу добавляет эту группу как дополнительную.

Поле `fsGroupChangePolicy` (stable с 1.23) выбирает, как менять права. Значение `OnRootMismatch` меняет их только если владелец корня тома не совпал, а `Always` (по умолчанию) обходит все файлы при каждом монтировании. На томе с миллионами файлов `Always` растягивает старт пода на минуты. Для `secret`, `configMap` и `emptyDir` поле не действует.

Дополнительные группы процесса складываются из `supplementalGroups`, `fsGroup` и групп из файла `/etc/group` образа для этого пользователя. Последний источник нежелателен: группа, которую вы нигде не писали, даёт доступ к файлам тома. Поле `supplementalGroupsPolicy` (GA в 1.35) имеет два значения. `Merge` (по умолчанию) подмешивает группы образа, а `Strict` берёт только перечисленные в манифесте. Итоговый набор виден в `status.containerStatuses[].user.linux`.

### Capabilities

**Capability** (привилегия ядра) — одна привилегированная операция, на которые ядро разбило права root. Например, `CAP_NET_BIND_SERVICE` разрешает слушать порты ниже 1024, а `CAP_SYS_ADMIN` разрешает монтировать файловые системы и многое другое. У процесса есть несколько наборов, но для практики важны два: **effective** (`CapEff`) — действует сейчас, и **bounding** (`CapBnd`) — потолок, который процесс не превысит.

Контейнер получает набор от рантайма. Containerd по умолчанию даёт 14 capabilities: `CHOWN`, `DAC_OVERRIDE`, `FSETID`, `FOWNER`, `MKNOD`, `NET_RAW`, `SETGID`, `SETUID`, `SETFCAP`, `SETPCAP`, `NET_BIND_SERVICE`, `SYS_CHROOT`, `KILL`, `AUDIT_WRITE`. Приложению из них обычно нужна одна или ни одной. Лишние опасны: `NET_RAW` позволяет подделывать пакеты, `DAC_OVERRIDE` обходит проверки прав на файлы.

Безопасный шаблон такой: `drop: [ALL]`, а затем `add` с теми, что нужны. Типичный пример — `NET_BIND_SERVICE` для сервера на порту 80 или 443.

```
         рантайм: 14 по умолчанию
              │  drop: [ALL]  ──► остаётся пустой набор
              │  add: [NET_BIND_SERVICE] ──► потолок (bounding) = только эта
              ▼
  процесс root (uid 0):      CapEff = потолок
  процесс не root (uid>0):   CapEff = 0   (права нужно получить от файла с capability)
```

Схема 3. Набор capabilities контейнера. Для не-root процесса effective-набор пуст, даже если capability есть в потолке: Kubernetes не выдаёт ambient capabilities.

Это поведение неочевидно: процессу с uid 10001 добавление `NET_BIND_SERVICE` в манифест не даёт права слушать порт 80. Containerd 2.x обходит проблему иначе. Для каждого пода без `hostNetwork` он ставит sysctl `net.ipv4.ip_unprivileged_port_start=0`, и низкие порты открываются без capability. Это параметр `enable_unprivileged_ports` в конфигурации CRI, который включён по умолчанию с версии 2.0 (проверка — работа 1). На других рантаймах и с `hostNetwork` выбирают порт выше 1024 (8080), а `Service` (03-2) отображает порт 80 на него.

### no_new_privs и корень только для чтения

Флаг ядра **no_new_privs** запрещает процессу и его потомкам получать больше прав при `execve`: setuid-бинарники и файловые capabilities перестают работать. Поле `allowPrivilegeEscalation` управляет им с инверсией: значение `false` включает `no_new_privs`. Значение по умолчанию — `true`, то есть защита выключена. Поле нельзя ставить в `false` вместе с `privileged` или `CAP_SYS_ADMIN`.

Поле `readOnlyRootFilesystem: true` монтирует корневую файловую систему контейнера только для чтения. Вредоносный код не может подменить бинарники и скрипты в образе. Приложению для временных файлов нужны каталоги записи, и для них монтируют `emptyDir` (04-2), чаще всего на `/tmp`.

### seccomp: фильтр системных вызовов

**seccomp** (secure computing mode) — механизм ядра, который проверяет каждый системный вызов процесса по списку правил и разрешает его или возвращает ошибку. Ядро Linux содержит сотни системных вызовов, а типичному серверу нужна небольшая часть. Фильтр отсекает остальные, поэтому эксплойт, который рассчитывает на редкий вызов, не срабатывает.

Есть три режима профиля. Профиль **RuntimeDefault** — встроенный профиль containerd: он разрешает список вызовов, нужных обычным программам, а на остальные возвращает ошибку. Вызовы `mount` и `bpf` он пропускает только при `CAP_SYS_ADMIN`, `reboot` — только при `CAP_SYS_BOOT`, а `kexec_load` не пропускает никогда. Профиль **Localhost** — ваш JSON-файл на узле. Профиль **Unconfined** отключает фильтр; privileged-контейнеры всегда работают так.

```
 процесс ──► syscall (например mkdir) ──► фильтр seccomp ──┬─► разрешён ──► ядро
                                                           └─► ERRNO ──► процесс получает EPERM
```

Схема 4. Фильтр стоит между процессом и ядром; запрещённый вызов даёт процессу ошибку, а не доходит до ядра.

Без настройки профиля под работает без фильтра, то есть как Unconfined. Это изменяет флаг kubelet `seccompDefault` (stable с 1.27): при `true` под без явного профиля получает RuntimeDefault.

### AppArmor и SELinux

**LSM** (Linux Security Module) — подсистема ядра, где модуль безопасности проверяет доступ к файлам, сети и объектам ядра сверх обычных прав. **AppArmor** описывает доступ профилем для пути к программе и входит в Ubuntu. **SELinux** помечает файлы и процессы метками и применяет политику по меткам, как в RHEL и Fedora. На узле обычно работает один модуль.

AppArmor и SELinux защищают, когда процесс уже скомпрометирован: профиль не даст прочитать `/etc/shadow` даже от root. Контейнеру подходит профиль рантайма (в containerd он называется `cri-containerd.apparmor.d`) или ваш собственный. Метки SELinux (`seLinuxOptions` в `securityContext`) нужны в основном на RHEL-подобных узлах. Влияние SELinux на тома разобрано в 04-2, а в этой части мы к нему не вернёмся.

Ubuntu включает AppArmor по умолчанию. Manjaro по умолчанию не включает ни AppArmor, ни SELinux. Узлы kind используют ядро хоста, но containerd внутри узла AppArmor не применяет: в образе узла нет программы `apparmor_parser`, и containerd считает модуль недоступным.

---

## 3. Как управлять изоляцией

Изоляцию задают в манифесте и в настройках узла. Разберём уровни securityContext, профили seccomp и AppArmor, user namespaces, RuntimeClass и то, что стоит запрещать.

### Уровни securityContext

**securityContext** — блок полей, который задаёт параметры безопасности пода или одного контейнера. Поля пода действуют на все контейнеры, включая init, sidecar и ephemeral. Поля контейнера перекрывают поля пода. Часть полей существует только на одном уровне.

- **Только под:** `fsGroup`, `fsGroupChangePolicy`, `supplementalGroups`, `supplementalGroupsPolicy`, `sysctls`.
- **Только контейнер:** `capabilities`, `privileged`, `allowPrivilegeEscalation`, `readOnlyRootFilesystem`, `procMount`.
- **Оба уровня:** `runAsUser`, `runAsGroup`, `runAsNonRoot`, `seccompProfile`, `appArmorProfile`, `seLinuxOptions`.

Манифест ниже собирает все поля в один «ужесточённый» контейнер. Поле `hostUsers` лежит в `spec` пода, а не в `securityContext`.

```yaml
spec:
  securityContext:                 # уровень пода
    runAsNonRoot: true
    runAsUser: 10001
    runAsGroup: 10001
    fsGroup: 10001
    seccompProfile: {type: RuntimeDefault}
  containers:
  - name: api
    securityContext:               # уровень контейнера
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities: {drop: [ALL]}
    volumeMounts: [{name: tmp, mountPath: /tmp}]
  volumes: [{name: tmp, emptyDir: {}}]
```

Фрагмент манифеста: пользователь, группа, seccomp и права тома заданы на уровне пода, а запреты роста привилегий, записи и capabilities — на уровне контейнера. Этот набор проходит уровень restricted (06-3).

### Профили seccomp и AppArmor

Профиль выбирают полем `type`. Для seccomp это `seccompProfile`, для AppArmor — `appArmorProfile`. Поле AppArmor появилось в 1.30 и стало GA в 1.31. Старые аннотации `container.apparmor.security.beta.kubernetes.io/...` устарели, и новые манифесты их не используют. Значения у обоих одинаковы: `RuntimeDefault`, `Localhost` и `Unconfined`.

Для `Localhost` нужно указать имя файла: `localhostProfile`. Профиль seccomp kubelet ищет в каталоге `/var/lib/kubelet/seccomp` на узле, и имя задают относительно него. Профиль AppArmor должен быть загружен в ядро узла заранее; его имя видно в `/sys/kernel/security/apparmor/profiles`. Файлы на узлы кладёт администратор или DaemonSet, а не Kubernetes.

```
 манифест пода                         узел
 seccompProfile:                       /var/lib/kubelet/seccomp/
   type: Localhost                         └── lab-06-2/deny-mkdir.json   ← файл
   localhostProfile: lab-06-2/deny-mkdir.json
```

Схема 5. Путь `localhostProfile` отсчитывается от каталога seccomp в kubelet; если файла нет, контейнер не создаётся.

Чтобы все поды без явного профиля получили RuntimeDefault, включают в конфигурации kubelet `seccompDefault: true` (или флаг `--seccomp-default`) и перезапускают kubelet. Приложения, которым фильтр мешает, получают `Unconfined` явно, и это решение видно в манифесте. Включайте параметр на узле по очереди, потому что он действует на каждый новый под.

### User namespaces

В 02-1 мы определили user namespace как пространство, которое отображает uid и gid процесса на другие uid и gid узла. Поле `hostUsers: false` (в `spec` пода, GA в 1.36) включает его: root контейнера (uid 0) становится на узле обычным пользователем с большим номером. Побег из контейнера тогда даёт права безвестного uid, а не root узла.

```
 внутри пода            на узле
 uid 0     ───────────► uid 2 195 456 000        (пример; у вас другой)
 uid 1     ───────────► uid 2 195 456 001
 …
 uid 65535 ───────────► uid 2 195 521 535
 (uid_map: 0  <начало>  65536)
```

Схема 6. Диапазон из 65 536 uid пода отображается на непрерывный диапазон узла; kubelet выбирает начало сам и не пересекает диапазоны подов.

Capabilities в таком поде действуют только внутри namespace: `CAP_SYS_ADMIN` не даёт управлять узлом, а `CAP_SYS_MODULE` не работает. Поэтому процесс может быть root внутри пода и всё равно безопасен для узла. Это отличается от `runAsNonRoot`: userns оставляет приложению привычный root и урезает его снаружи.

Требования у механики жёсткие.

- **Ядро узла** — 6.3 или новее: с этой версии tmpfs поддерживает id-mapped mounts. **Id-mapped mount** — монтирование, при котором ядро на лету пересчитывает владельцев файлов, поэтому не нужен рекурсивный chown тома.
- **Файловые системы** — каталог `/var/lib/kubelet/pods` и все тома пода должны поддерживать id-mapped mounts (ext4, xfs, btrfs, tmpfs, overlayfs). NFS не поддерживает.
- **Рантайм** — containerd 2.0 или новее либо CRI-O 1.25+, и runc 1.2+ либо crun 1.9+.
- **Ограничения пода** — нельзя вместе с `hostNetwork`, `hostIPC` и `hostPID`; нельзя `volumeDevices`.

Размер диапазона на под задаёт поле kubelet `userNamespaces.idsPerPod` (с 1.33, кратно 65 536, по умолчанию 65 536). Свой диапазон узла описывают в `/etc/subuid` и `/etc/subgid` для пользователя `kubelet`. Старт и размер кратны 65 536, а размер не меньше 65 536 × maxPods. Меняют диапазон только на опустошённом узле.

### RuntimeClass и песочницы

Обычный контейнер защищают политики, но ядро у него общее. Если нагрузка не доверена (код клиентов, сборки чужих репозиториев), между контейнером и узлом ставят **песочницу** (sandbox). Это рантайм со своим ядром или ВМ. **gVisor** (обработчик `runsc`) перехватывает системные вызовы и исполняет их в собственном ядре в пользовательском пространстве. **Kata Containers** запускает каждый под в лёгкой ВМ.

Платой служат память (десятки МиБ на под), время старта и несовместимость части вызовов и устройств.

**RuntimeClass** — объект API, который связывает имя класса с обработчиком containerd. Под выбирает песочницу полем `runtimeClassName`.

```yaml
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata: {name: gvisor}
handler: runsc                    # имя обработчика в конфигурации containerd на узле
scheduling:
  nodeSelector: {sandbox: gvisor} # под попадёт только на узлы с этой меткой
overhead:
  podFixed: {memory: 64Mi, cpu: 100m}   # добавляется к запросам пода (05-2)
```

Фрагмент: RuntimeClass `gvisor` указывает на обработчик `runsc`, ограничивает узлы меткой и сообщает планировщику накладные расходы песочницы. Под включает класс строкой `runtimeClassName: gvisor`. Обработчик должен быть установлен на узлах, иначе под не запустится; на стенде kind мы его не ставим, потому что установка меняет конфигурацию containerd на узле. Тот же механизм подключает и другие рантаймы, например Wasm.

### Что запрещать в прикладных подах

Некоторые поля снимают изоляцию целиком, и в прикладных подах им нечего делать. Их запрещают политиками (06-3), а здесь важно понимать причину.

- **privileged: true** — контейнер получает все capabilities, доступ ко всем устройствам узла, и seccomp с AppArmor отключаются. Root в таком контейнере почти равен root узла. Нужен только системным компонентам: драйверам CSI, сетевым агентам. Узлы kind сами запущены как privileged-контейнеры Docker, поэтому стенд годится для опытов, а не для образца настроек.
- **hostPath** — монтирует каталог узла в контейнер. Запись в `/etc`, `/var/lib/kubelet` или чтение сокета runtime даёт управление узлом. Вместо него используют `emptyDir`, PVC и local PV (04-2).
- **hostNetwork** — под использует сеть узла: видит службы на `localhost` узла и выходит из-под NetworkPolicy (03-6).
- **hostPID** и **hostIPC** — под видит процессы узла и других подов, а значит их переменные окружения и память.

Отдельно стоит поле `procMount`. Значение `Default` оставляет маскировку чувствительных путей в `/proc` и `/sys`, а `Unmasked` снимает её. Начиная с 1.36 поле стабильно и допустимо только вместе с `hostUsers: false`: userns ограничивает последствия. В остальных случаях оставляйте значение по умолчанию.

---

## 4. Как увидеть состояние изоляции

Проверять изоляцию надо изнутри контейнера и с узла, а не по манифесту: манифест показывает пожелание, а процесс — результат. Разберём три источника.

### Файл /proc/self/status

Команда `cat /proc/self/status` внутри контейнера показывает права процесса. Нужны такие поля.

- **Uid, Gid** — по четыре числа: real, effective, saved и filesystem.
- **CapEff, CapBnd** — наборы capabilities в виде шестнадцатеричной маски; бит 10 равен `NET_BIND_SERVICE`, значение `0000000000000400`.
- **NoNewPrivs** — 1, если `allowPrivilegeEscalation: false`.
- **Seccomp** — 0 без фильтра, 1 строгий режим, 2 фильтр.
- **Groups** — дополнительные группы (`fsGroup` и другие).

Маску раскодирует `capsh --decode=<маска>` на хосте или узле, где установлен пакет libcap. В образах утилиты обычно нет, поэтому декодируют снаружи.

### Узел: crictl и uid_map

Что запрошено у рантайма, видно на узле. Команда `crictl inspect <контейнер>` (00-2) выводит `info.runtimeSpec` с полями `linux.seccomp`, `linux.uidMappings`, `process.capabilities` и `process.noNewPrivileges`. В `/proc/<pid>/uid_map` узла видно отображение пользователей, а `ps -eo uid,pid,args` показывает uid процесса на узле, не внутри пода.

Состояние самого процесса в поде видно и через API: `status.containerStatuses[].user.linux` содержит uid, gid и дополнительные группы первого процесса. Поле заполняется, когда kubelet и рантайм поддерживают политику групп (1.35).

### События, метрики и AppArmor

Отказы до старта процесса приходят событиями пода (`kubectl describe pod`): не найден профиль seccomp, профиль AppArmor не загружен, `runAsNonRoot` нарушен. У kubelet есть счётчики `started_user_namespaced_pods_total` и `started_user_namespaced_pods_errors_total`; они показывают попытки и ошибки создания подов с userns (11-1).

AppArmor проверяют отдельно. Файл `/sys/module/apparmor/parameters/enabled` на узле содержит `Y`, если модуль включён. Внутри контейнера `cat /proc/1/attr/current` печатает имя профиля и режим, например `... (enforce)`; значение `unconfined` значит, что профиль не применён.

---

## 5. Что ломается и как найти причину

Ужесточение ломает приложения двумя способами: контейнер не стартует или падает уже в работе. Начинать поиск надо с вопроса, дошёл ли процесс до запуска.

### Контейнер не создаётся

Если процесса нет, логов тоже нет, и причину ищут в `describe` пода.

- **CreateContainerConfigError** с текстом `container has runAsNonRoot and image will run as root` — образ работает от root, а `runAsUser` не задан. Задайте числовой `runAsUser`: kubelet не может проверить имя пользователя из `USER app`.
- **CreateContainerError** с упоминанием seccomp — профиль `Localhost` не найден на этом узле. Файл лежит не на каждом узле или путь указан неверно; под назначается на узел раньше, чем проверяется профиль.
- **Pod заблокирован kubelet** с сообщением про AppArmor — профиль не загружен или модуль выключен на узле.
- **Под не запускается с hostUsers: false** — ядро, рантайм или файловая система тома не поддерживают userns. Проверьте требования из §3.

### Приложение падает после ужесточения

Запрет проявляется ошибкой в логах приложения. Каждый механизм даёт свою ошибку.

1. `Read-only file system` — приложение пишет в корень; смонтируйте `emptyDir` в этот каталог (`/tmp`, кэш, каталог pid).
2. `Permission denied` на порту ниже 1024 — перейдите на порт выше 1024 и отобразите его через Service.
3. `Operation not permitted` на обычной операции (`chown`, `mknod`, смена uid) — не хватает capability; сначала убедитесь, что она действительно нужна, и добавьте одну.
4. `Operation not permitted` на системный вызов при включённом seccomp — профиль блокирует вызов. Сравните поведение с `Unconfined`, затем ищите вызов в аудите ядра или трассировкой (`strace`) в отладочном контейнере (00-2).
5. `Permission denied` на файлах тома — владелец не совпал с `runAsUser` и `fsGroup`.

Правило поиска простое: меняйте по одному слою и возвращайте, пока ошибка не исчезнет. Так виден виновник, и вы добавите ровно одно право.

### Права на тома

Самая частая причина после включения `runAsNonRoot` — тома. Файлы базы данных принадлежат root, а новый uid их не читает. Решают это тремя способами: задать `fsGroup`, один раз сменить владельца в init-контейнере или собрать образ с нужным uid. Для больших томов выберите `fsGroupChangePolicy: OnRootMismatch`, иначе каждый запуск пода обходит все файлы. В userns-подах числа `runAsUser`, `runAsGroup` и `fsGroup` обозначают uid внутри пода, поэтому владельцы файлов тома остаются теми же.

---

## 6. Пределы и значения по умолчанию

Ниже собраны числа и версии, которые встречались в части. Значения взяты из документации Kubernetes и containerd для версии стенда 1.36.

### Значения по умолчанию

- Пользователь — из образа; без `USER` процесс идёт от root, uid 0.
- Capabilities — 14 штук (список в §2); `NoNewPrivs` равен 0, `allowPrivilegeEscalation` равен `true`.
- seccomp — без фильтра (`Unconfined`), пока на узле не включён `seccompDefault`.
- Корневая файловая система — доступна для записи.
- `fsGroupChangePolicy` — `Always`; `supplementalGroupsPolicy` — `Merge`.
- `hostUsers` — `true`: user namespace узла.
- `procMount` — `Default`.

### Версии

Таблица показывает, когда механизм стал стабильным, и что от него зависит.

| Возможность | Стабильна с | Что нужно |
|---|---|---|
| fsGroupChangePolicy | 1.23 | kubelet |
| seccompDefault | 1.27 | флаг kubelet |
| Поле appArmorProfile | 1.31 (поле с 1.30) | AppArmor на узле |
| supplementalGroupsPolicy | 1.35 | kubelet и рантайм с поддержкой |
| User namespaces, procMount | 1.36 | ядро 6.3+, containerd 2.0+, runc 1.2+ |

В 1.37 меняется SELinux (SELinuxMount становится stable и включён по умолчанию, 04-2); остальные механизмы части остаются прежними.

### Пределы user namespaces

- Диапазон пода — 65 536 uid; файлы с владельцем вне диапазона выглядят как uid 65534 (overflow) и не изменяются.
- Диапазон узла — не меньше 65 536 × maxPods; при maxPods 110 это 7 208 960 uid.
- Старт диапазона в `/etc/subuid` — кратен 65 536 и не меньше 65 536.
- Поддерживаются только Linux-узлы.

---

## Лабораторные работы

Работы идут на стенде 00-1 в namespace `lab-06-2`. Хост они не меняют: поды живут внутри kind, а работа 2 копирует один файл в контейнер узла `lab-worker`. Образы узлы тянут из реестра стенда: `localhost:5001/busybox:1.37` и `localhost:5001/orders-api:2.0`.

Подготовка создаёт namespace и функцию `k`, которая подставляет его в каждую команду kubectl. Контекст kubectl не меняется.

```bash
kubectl config use-context kind-lab
kubectl create ns lab-06-2
k() { kubectl -n lab-06-2 "$@"; }
mkdir -p ~/lab/k8s/06-2
```

Первая команда выбирает кластер стенда. Вторая создаёт namespace части. Функция `k` действует только в текущем шелле. Каталог `~/lab/k8s/06-2` нужен для файлов работы 2.

Результат:

```
Switched to context "kind-lab".
namespace/lab-06-2 created
```

Namespace и функцию `k` убирает уборка работы 3. Если вы проходите работы по отдельности, создайте функцию заново.

### Лабораторная работа 1. securityContext и capabilities

**Цель.** Увидеть, что получает контейнер по умолчанию, и убедиться, что поля securityContext меняют `Uid`, `CapEff` и `NoNewPrivs` внутри процесса.

**Что понадобится.**

- Стенд 00-1, namespace `lab-06-2` и функция `k` из подготовки.
- Образы `busybox:1.37` и `orders-api:2.0` в реестре стенда.
- Около 15 минут.

**Схема опыта.**

```
Шаг 1  plain      без securityContext             ─► root, 14 capabilities, без фильтра
Шаг 2  hardened   полный набор из §3 (orders-api) ─► uid 10001, CapEff=0, NoNewPrivs=1
Шаг 3  caps-root  drop ALL + NET_BIND_SERVICE      ─► CapEff=0x400 у root, 0 у не-root
Шаг 4  nonroot    runAsNonRoot без uid ─► отказ; с uid + fsGroup + readOnly ─► Running
```

Схема 7. Четыре пода показывают четыре слоя: пользователь, capabilities, запись в корень и права тома.

Шаги 1, 3 и 4 вы выполняете сами, результаты в них — ожидаемые. Шаг 2 дан с реальным выводом стенда.

#### Шаг 1. Посмотреть значения по умолчанию

Команда создаёт под без securityContext и читает его права из `/proc/self/status`.

```bash
k run plain --image=localhost:5001/busybox:1.37 -- sleep 3600
k wait --for=condition=Ready pod/plain --timeout=60s
k exec plain -- grep -E '^(Uid|CapEff|CapBnd|NoNewPrivs|Seccomp):' /proc/self/status
```

| Часть команды | Значение |
|---|---|
| `k run plain … -- sleep 3600` | запустить под, который живёт час |
| `wait --for=condition=Ready` | дождаться готовности пода |
| `exec plain -- grep …` | выполнить команду внутри контейнера |
| `/proc/self/status` | права процесса `grep` (они совпадают с правами контейнера) |

Ожидаемый результат:

```
Uid:	0	0	0	0
CapEff:	00000000a80425fb
CapBnd:	00000000a80425fb
NoNewPrivs:	0
Seccomp:	0
```

Разбор:

1. `Uid: 0` — процесс идёт от root, потому что образ не задаёт `USER`.
2. `CapEff` и `CapBnd` равны `a80425fb` — маска 14 capabilities по умолчанию.
3. `NoNewPrivs: 0` — рост привилегий через setuid разрешён.
4. `Seccomp: 0` — фильтра нет. Если на узлах включён `seccompDefault`, здесь будет 2: это зависит от конфигурации kubelet стенда.

#### Шаг 2. Применить полный набор

Команда создаёт под orders-api с набором из §3 и проверяет пользователя, запись в файловую систему и права процесса.

```bash
k apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata: {name: hardened}
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 10001
    seccompProfile: {type: RuntimeDefault}
  containers:
  - name: api
    image: localhost:5001/orders-api:2.0
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities: {drop: [ALL]}
    volumeMounts: [{name: tmp, mountPath: /tmp}]
  volumes: [{name: tmp, emptyDir: {}}]
EOF
k wait --for=condition=Ready pod/hardened --timeout=60s
k exec hardened -- python -c "
import os,urllib.request
print('uid', os.getuid(), urllib.request.urlopen('http://127.0.0.1:8000/version').read().decode())
try: open('/srv/x','w')
except Exception as e: print('write to /srv:', type(e).__name__)
open('/tmp/x','w').write('ok'); print('write to /tmp: ok')"
k exec hardened -- grep -E 'CapEff|NoNewPrivs|Seccomp:' /proc/1/status
```

| Часть команды | Значение |
|---|---|
| `runAsNonRoot`, `runAsUser: 10001` | процесс не root, uid 10001 |
| `seccompProfile: RuntimeDefault` | включить фильтр рантайма |
| `allowPrivilegeEscalation: false` | включить `no_new_privs` |
| `readOnlyRootFilesystem: true` | корень только для чтения |
| `capabilities: {drop: [ALL]}` | убрать все capabilities |
| `emptyDir` на `/tmp` | единственное место для записи |
| `/proc/1/status` | права главного процесса контейнера (приложения) |

Результат:

```
uid 10001 {"version": "2.0", "pod": "hardened"}
write to /srv: OSError
write to /tmp: ok
CapEff:	0000000000000000
NoNewPrivs:	1
Seccomp:	2
```

Разбор:

1. `uid 10001` — процесс работает от заданного пользователя, и приложение отвечает на `/version`.
2. `write to /srv: OSError` — корень только для чтения не даёт писать в образ.
3. `write to /tmp: ok` — запись разрешена там, куда смонтирован `emptyDir`.
4. `CapEff` из нулей — у процесса нет ни одной capability.
5. `NoNewPrivs: 1` — флаг ядра включён.
6. `Seccomp: 2` — фильтр seccomp активен.

#### Шаг 3. Оставить одну capability

Команда создаёт два пода с `drop: [ALL]` и `add: [NET_BIND_SERVICE]`: один от root, другой от uid 1000, и сравнивает наборы.

```bash
k apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata: {name: caps-root}
spec:
  containers:
  - name: app
    image: localhost:5001/busybox:1.37
    command: ["sleep", "3600"]
    securityContext:
      capabilities: {drop: [ALL], add: [NET_BIND_SERVICE]}
---
apiVersion: v1
kind: Pod
metadata: {name: caps-user}
spec:
  containers:
  - name: app
    image: localhost:5001/busybox:1.37
    command: ["sleep", "3600"]
    securityContext:
      runAsUser: 1000
      capabilities: {drop: [ALL], add: [NET_BIND_SERVICE]}
EOF
k wait --for=condition=Ready pod/caps-root pod/caps-user --timeout=60s
for p in caps-root caps-user; do
  echo "== $p"; k exec $p -- grep -E '^(Uid|CapEff|CapBnd):' /proc/self/status
done
k exec caps-root -- cat /proc/sys/net/ipv4/ip_unprivileged_port_start
```

| Часть команды | Значение |
|---|---|
| `drop: [ALL], add: [NET_BIND_SERVICE]` | оставить только привилегию привязки к низким портам |
| `runAsUser: 1000` | второй под работает не от root |
| `for p in …` | выполнить проверку в обоих подах |
| `ip_unprivileged_port_start` | первый порт, который доступен без capability |

Ожидаемый результат:

```
== caps-root
Uid:	0	0	0	0
CapEff:	0000000000000400
CapBnd:	0000000000000400
== caps-user
Uid:	1000	1000	1000	1000
CapEff:	0000000000000000
CapBnd:	0000000000000400
0
```

Разбор:

1. `0000000000000400` — установлен бит 10, это `NET_BIND_SERVICE`; остальные 13 capabilities убраны.
2. У root эта capability действует (`CapEff`), у uid 1000 она есть только в потолке (`CapBnd`), а `CapEff` пуст.
3. Последняя строка — значение sysctl. Ноль значит, что в этом поде любой процесс может слушать порты от 0. Если у вас там 1024, низкие порты требуют capability.

#### Шаг 4. Отказ runAsNonRoot и права тома

Команда создаёт под с `runAsNonRoot: true`, но без uid, и читает причину отказа.

```bash
k apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata: {name: nonroot}
spec:
  securityContext: {runAsNonRoot: true}
  containers:
  - name: app
    image: localhost:5001/busybox:1.37
    command: ["sleep", "3600"]
EOF
sleep 5
k get pod nonroot
k get pod nonroot -o jsonpath='{.status.containerStatuses[0].state.waiting.message}{"\n"}'
```

| Часть команды | Значение |
|---|---|
| `runAsNonRoot: true` без `runAsUser` | образ busybox работает от root |
| `state.waiting.message` | текст отказа kubelet |

Ожидаемый результат (сообщение сокращено):

```
NAME      READY   STATUS                       RESTARTS   AGE
nonroot   0/1     CreateContainerConfigError   0          5s

container has runAsNonRoot and image will run as root (pod: "nonroot_lab-06-2(…)", container: app)
```

Разбор:

1. Статус `CreateContainerConfigError` — контейнер не создан, kubelet отказал до запуска процесса.
2. В сообщении названа причина: образ идёт от root, а `runAsNonRoot` это запрещает.

Теперь исправляем: задаём uid и группы, добавляем `emptyDir` с `fsGroup` и корень только для чтения.

```bash
k delete pod nonroot --wait=false
k apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata: {name: fixed}
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    runAsGroup: 3000
    fsGroup: 2000
  containers:
  - name: app
    image: localhost:5001/busybox:1.37
    command: ["sleep", "3600"]
    securityContext: {readOnlyRootFilesystem: true}
    volumeMounts: [{name: data, mountPath: /data}]
  volumes: [{name: data, emptyDir: {}}]
EOF
k wait --for=condition=Ready pod/fixed --timeout=60s
k exec fixed -- sh -c 'id; ls -ld /data; touch /data/ok && echo data-ok; touch /x'
```

| Часть команды | Значение |
|---|---|
| `runAsGroup: 3000` | основная группа процесса |
| `fsGroup: 2000` | группа владельца тома `/data` |
| `readOnlyRootFilesystem: true` | запись только в `/data` |
| `touch /data/ok`, `touch /x` | запись в том и в корень |

Ожидаемый результат:

```
uid=1000 gid=3000 groups=2000,3000
drwxrwsrwx    2 root     2000          4096 … /data
data-ok
touch: /x: Read-only file system
```

Разбор:

1. `uid=1000 gid=3000` — заданы `runAsUser` и `runAsGroup`; группа 2000 добавлена из `fsGroup`.
2. У `/data` группа 2000 и бит setgid (`s`): новые файлы наследуют группу.
3. `data-ok` — запись в том работает, потому что группа 2000 разрешена.
4. `Read-only file system` — корень закрыт для записи.

**Итог.**

| Что узнали | Где видно |
|---|---|
| По умолчанию контейнер — root с 14 capabilities и без seccomp | шаг 1 |
| Набор полей даёт uid 10001, CapEff=0, NoNewPrivs=1, Seccomp=2 | шаг 2 |
| У не-root процесса effective-набор пуст, даже при добавленной capability | шаг 3, `caps-user` |
| `runAsNonRoot` отказывает до старта, а `fsGroup` даёт доступ к тому | шаг 4 |

**Уборка.**

```bash
k delete pod plain hardened caps-root caps-user nonroot fixed --ignore-not-found
```

**Вопросы для самопроверки.**

1. Почему `runAsNonRoot: true` без `runAsUser` не запустил busybox?
2. Что означает `CapEff` из нулей и почему оно не мешает приложению отвечать на запросы?
3. Зачем нужен `emptyDir` при `readOnlyRootFilesystem: true`?
4. Почему `add: [NET_BIND_SERVICE]` не помогает процессу с uid 1000?

<details>
<summary>Ответ</summary>

1. Поле только проверяет. Образ busybox работает от root, а kubelet видит uid 0 и не создаёт контейнер.
2. Процесс не имеет привилегированных операций. Обычная работа — чтение файлов приложения, сетевые запросы на порты выше 1023 — привилегий не требует.
3. Приложению нужно писать временные файлы. Каталог для записи монтируют отдельно, а корень остаётся неизменяемым.
4. Для не-root процесса effective-набор обнуляется при запуске программы, а Kubernetes не выдаёт ambient capabilities. Практичный выход — порт выше 1023.

</details>

### Лабораторная работа 2. seccomp и AppArmor

**Риски.** Работа копирует один файл в контейнер узла `lab-worker` и читает состояние ядра.

- **Что меняется:** файл `/var/lib/kubelet/seccomp/lab-06-2/deny-mkdir.json` внутри контейнера узла `lab-worker`; на хосте — файл `~/lab/k8s/06-2/deny-mkdir.json`.
- **Надолго ли:** до уборки; файл лежит в файловой системе контейнера узла и пропадает вместе с ним.
- **Безопасность:** профиль только запрещает один вызов и применяется к одному поду; привилегированных контейнеров нет.
- **Влияние на систему:** другие поды и узлы не затрагиваются; `docker exec` на узле только читает и копирует файл.
- **Откат:** блок «Уборка» в конце работы.

Эту работу вы выполняете сами, результаты в ней — ожидаемые. Только `Seccomp: 2` для профиля RuntimeDefault взято из реального вывода стенда (работа 1, шаг 2). Шаги с AppArmor зависят от ядра вашего хоста: узлы kind используют ядро машины, и на многих системах AppArmor выключен (по умолчанию он выключен в Manjaro).

**Цель.** Сравнить режимы seccomp по значению `Seccomp` в `/proc/self/status`, запретить один вызов своим профилем и проверить, поддерживает ли узел AppArmor.

**Что понадобится.**

- Namespace `lab-06-2`, функция `k` и каталог `~/lab/k8s/06-2` из подготовки.
- Узел `lab-worker` (имя из 00-1) и доступ к Docker на хосте.
- Образ `busybox:1.37` в реестре стенда.
- Около 20 минут.

**Схема опыта.**

```
Шаг 1  три пода: без профиля, Unconfined, RuntimeDefault ─► Seccomp: 0 / 0 / 2
Шаг 2  профиль Localhost deny-mkdir на lab-worker         ─► mkdir: Operation not permitted
       тот же профиль на lab-worker2 без файла            ─► контейнер не создаётся
Шаг 3  AppArmor: /sys/module/apparmor на узле             ─► Y: профиль; иначе: отказ kubelet
```

Схема 8. Три сравнения: режимы seccomp, свой профиль и поддержка AppArmor на узле.

#### Шаг 1. Сравнить три режима seccomp

Команда создаёт три пода и читает поле `Seccomp` каждого.

```bash
for t in none Unconfined RuntimeDefault; do
  if [ $t = none ]; then SC='{}'; else SC="{seccompProfile: {type: $t}}"; fi
  k apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata: {name: sc-$(echo $t | tr A-Z a-z)}
spec:
  securityContext: $SC
  containers:
  - {name: app, image: "localhost:5001/busybox:1.37", command: ["sleep", "3600"]}
EOF
done
k wait --for=condition=Ready pod --all --timeout=60s
for p in sc-none sc-unconfined sc-runtimedefault; do
  echo -n "$p: "; k exec $p -- grep '^Seccomp:' /proc/self/status
done
```

| Часть команды | Значение |
|---|---|
| `for t in none …` | создать по поду на каждый режим |
| `SC='{}'` | под без профиля |
| `seccompProfile: {type: $t}` | явный профиль режима |
| `wait --all` | дождаться готовности всех подов namespace |
| `grep '^Seccomp:'` | строка режима seccomp процесса |

Ожидаемый результат:

```
sc-none: Seccomp:	0
sc-unconfined: Seccomp:	0
sc-runtimedefault: Seccomp:	2
```

Разбор:

1. `sc-none` — 0: профиль не задан, и если на узле не включён `seccompDefault`, фильтра нет.
2. `sc-unconfined` — 0: фильтр отключён явно.
3. `sc-runtimedefault` — 2: действует профиль containerd.
4. Если у `sc-none` вы получили 2, на узлах kind включён `seccompDefault`.

#### Шаг 2. Свой профиль Localhost

Команда создаёт профиль, запрещающий `mkdir`, копирует его в узел и запускает под на этом узле.

```bash
cat > ~/lab/k8s/06-2/deny-mkdir.json <<'EOF'
{"defaultAction": "SCMP_ACT_ALLOW",
 "syscalls": [{"names": ["mkdir", "mkdirat"], "action": "SCMP_ACT_ERRNO"}]}
EOF
docker exec lab-worker mkdir -p /var/lib/kubelet/seccomp/lab-06-2
docker cp ~/lab/k8s/06-2/deny-mkdir.json lab-worker:/var/lib/kubelet/seccomp/lab-06-2/
k apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata: {name: sc-local}
spec:
  nodeName: lab-worker
  securityContext:
    seccompProfile: {type: Localhost, localhostProfile: lab-06-2/deny-mkdir.json}
  containers:
  - {name: app, image: "localhost:5001/busybox:1.37", command: ["sleep", "3600"]}
EOF
k wait --for=condition=Ready pod/sc-local --timeout=60s
k exec sc-local -- sh -c 'mkdir /tmp/x; echo exit=$?; touch /tmp/y && echo touch-ok'
```

| Часть команды | Значение |
|---|---|
| `defaultAction: SCMP_ACT_ALLOW` | разрешить всё, что не перечислено |
| `names: [mkdir, mkdirat]` | запретить создание каталогов |
| `SCMP_ACT_ERRNO` | вернуть процессу ошибку (EPERM по умолчанию) |
| `docker cp … lab-worker:…` | положить файл в каталог профилей kubelet |
| `nodeName: lab-worker` | назначить под на узел с профилем |
| `localhostProfile` | путь относительно `/var/lib/kubelet/seccomp` |

Ожидаемый результат:

```
mkdir: can't create directory '/tmp/x': Operation not permitted
exit=1
touch-ok
```

Разбор:

1. `Operation not permitted` — вызов создания каталога заблокирован фильтром, хотя процесс работает от root.
2. `touch-ok` — остальные вызовы разрешены: профиль запрещает только перечисленное.
3. Под с `nodeName: lab-worker` обходит планировщик, поэтому он точно попадает на узел с файлом.

Теперь проверим отказ: тот же профиль на узле, где файла нет.

```bash
k apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata: {name: sc-missing}
spec:
  nodeName: lab-worker2
  securityContext:
    seccompProfile: {type: Localhost, localhostProfile: lab-06-2/deny-mkdir.json}
  containers:
  - {name: app, image: "localhost:5001/busybox:1.37", command: ["sleep", "3600"]}
EOF
sleep 10
k get pod sc-missing
k describe pod sc-missing | grep -iE 'seccomp|Error' | head -3
```

| Часть команды | Значение |
|---|---|
| `nodeName: lab-worker2` | узел, на который файл не копировали |
| `describe … grep` | найти в событиях упоминание профиля |

Ожидаемый результат (текст события зависит от версии containerd, здесь сокращён):

```
NAME         READY   STATUS               RESTARTS   AGE
sc-missing   0/1     CreateContainerError   0          10s
… seccomp profile … lab-06-2/deny-mkdir.json … no such file or directory
```

Разбор: контейнер не создан, потому что рантайм не нашёл файл профиля. Профили надо разложить на все узлы, где может оказаться под.

#### Шаг 3. Проверить поддержку AppArmor

Команда читает признак AppArmor из ядра узла.

```bash
docker exec lab-worker cat /sys/module/apparmor/parameters/enabled
```

| Часть команды | Значение |
|---|---|
| `docker exec lab-worker` | выполнить команду в контейнере узла |
| `/sys/module/apparmor/parameters/enabled` | признак включённого модуля ядра |

Ожидаемый результат — один из двух:

```
Y
```

или

```
cat: /sys/module/apparmor/parameters/enabled: No such file or directory
```

Разбор: `Y` значит, что ядро хоста поддерживает AppArmor (типично для Ubuntu). Ошибка значит, что модуля нет (типично для Manjaro), и поды с AppArmor на узлах kind не запустятся.

Если получили `Y`, запустите под с профилем рантайма и прочитайте профиль.

```bash
k apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata: {name: aa-default}
spec:
  securityContext:
    appArmorProfile: {type: RuntimeDefault}
  containers:
  - {name: app, image: "localhost:5001/busybox:1.37", command: ["sleep", "3600"]}
EOF
sleep 10
k get pod aa-default
k exec aa-default -- cat /proc/1/attr/current
```

| Часть команды | Значение |
|---|---|
| `appArmorProfile: {type: RuntimeDefault}` | применить профиль рантайма |
| `/proc/1/attr/current` | профиль главного процесса контейнера |

Ожидаемый результат при рабочем AppArmor, где профиль загружен:

```
NAME         READY   STATUS    RESTARTS   AGE
aa-default   1/1     Running   0          10s
cri-containerd.apparmor.d (enforce)
```

Если под не стартует, в событиях будет отказ kubelet с упоминанием AppArmor; если профиль на узле kind не загружен, вы увидите `unconfined`. Это ожидаемое поведение стенда в контейнерах, а не ошибка манифеста.

Разбор:

1. `Running` и имя профиля с `(enforce)` — AppArmor применён.
2. Отказ с текстом про AppArmor — узел не поддерживает модуль: при поле `appArmorProfile` kubelet не запускает под молча без защиты.
3. Для профиля `Localhost` файл нужно загрузить в ядро узла командой `apparmor_parser`; на стенде kind мы этого не делаем, потому что узел — контейнер без прав на ядро хоста.

**Итог.**

| Что узнали | Где видно |
|---|---|
| Без профиля и с Unconfined фильтра нет, с RuntimeDefault значение 2 | шаг 1 |
| Профиль Localhost запрещает выбранный вызов | шаг 2, `mkdir` |
| Без файла профиля контейнер не создаётся | шаг 2, `sc-missing` |
| AppArmor зависит от ядра хоста | шаг 3 |

**Уборка.**

```bash
k delete pod sc-none sc-unconfined sc-runtimedefault sc-local sc-missing aa-default \
  --ignore-not-found
docker exec lab-worker rm -r /var/lib/kubelet/seccomp/lab-06-2
rm ~/lab/k8s/06-2/deny-mkdir.json
```

**Вопросы для самопроверки.**

1. Почему под без `seccompProfile` может иметь `Seccomp: 0`, хотя RuntimeDefault существует?
2. Что произойдёт с подом `Localhost`, если файла профиля нет на узле?
3. Кто загружает профиль AppArmor `Localhost` на узел?
4. Заменяет ли Pod Security Admission профиль seccomp?

<details>
<summary>Ответ</summary>

1. Профиль нужно выбрать явно или включить `seccompDefault` в kubelet. Иначе под работает без фильтра.
2. Контейнер не создаётся (`CreateContainerError`), потому что рантайм не находит файл.
3. Администратор узла или DaemonSet; Kubernetes профиль не распространяет.
4. Нет. Admission только проверяет поля манифеста (06-3), а фильтр включает runc на узле.

</details>

### Лабораторная работа 3. User namespaces

Эту работу вы выполняете сами, результаты в ней — ожидаемые. Они выведены по документации Kubernetes 1.36: на стенде автора (kind 0.32 с containerd 2.3 и ядро хоста 6.x) работа не проходила. Числа uid на вашем узле будут другими.

**Цель.** Включить user namespace в поде, прочитать `uid_map` и убедиться, что root контейнера на узле — обычный пользователь с большим номером.

**Что понадобится.**

- Namespace `lab-06-2` и функция `k` из подготовки.
- Ядро хоста 6.3 или новее (узлы kind используют его); проверка — в шаге 1.
- Containerd 2.0+ и runc 1.2+ на узле (в kind 0.32 это containerd 2.3).
- Образ `busybox:1.37` в реестре стенда и около 20 минут.

**Схема опыта.**

```
под host-users   (по умолчанию)  uid 0 в поде ─► uid 0 на узле
под userns       hostUsers:false uid 0 в поде ─► uid ≥ 65536 на узле
шаг 1: проверка ядра и рантайма   шаги 2–3: uid_map в поде и ps на узле
шаг 4: hostNetwork вместе с userns отклоняется
```

Схема 9. Два пода с одним процессом `sleep` на одном узле; отличие только в `hostUsers`.

#### Шаг 1. Проверить требования

Команда показывает версию ядра хоста и версии рантайма в узле.

```bash
uname -r
docker exec lab-worker containerd --version
docker exec lab-worker runc --version
```

| Часть команды | Значение |
|---|---|
| `uname -r` | версия ядра хоста (общая для узлов kind) |
| `containerd --version` | версия CRI-рантайма узла |
| `runc --version` | версия OCI-рантайма узла |

Ожидаемый результат (версии условные, проверьте по порогам):

```
6.8.0-… (ядро 6.3 или новее)
containerd containerd.io … v2.3.1 …   (2.0 или новее)
runc version 1.3.… (1.2 или новее)
```

Разбор: все три числа должны быть не ниже порогов из §3. Если ядро старее 6.3, поды с `hostUsers: false` не запустятся, и остальные шаги выполнить нельзя.

#### Шаг 2. Сравнить uid_map двух подов

Команда создаёт два пода на одном узле и читает отображение пользователей в каждом.

```bash
k apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata: {name: host-users}
spec:
  nodeName: lab-worker
  containers:
  - {name: app, image: "localhost:5001/busybox:1.37", command: ["sleep", "3601"]}
---
apiVersion: v1
kind: Pod
metadata: {name: userns}
spec:
  hostUsers: false
  nodeName: lab-worker
  containers:
  - {name: app, image: "localhost:5001/busybox:1.37", command: ["sleep", "3602"]}
EOF
k wait --for=condition=Ready pod/host-users pod/userns --timeout=90s
for p in host-users userns; do
  echo "== $p"; k exec $p -- sh -c 'id -u; cat /proc/self/uid_map; grep CapEff /proc/self/status'
done
```

| Часть команды | Значение |
|---|---|
| `hostUsers: false` | включить user namespace пода |
| `nodeName: lab-worker` | оба пода на одном узле |
| `sleep 3601`, `sleep 3602` | разные аргументы, чтобы найти процессы на узле |
| `/proc/self/uid_map` | отображение uid: внутри, на узле, длина |

Ожидаемый результат:

```
== host-users
0
         0          0 4294967295
CapEff:	00000000a80425fb
== userns
0
         0  2195456000      65536
CapEff:	00000000a80425fb
```

Разбор:

1. Оба пода показывают `id -u` равным 0: внутри пода процесс остаётся root.
2. `0 0 4294967295` — тождественное отображение: uid пода равен uid узла на всём диапазоне.
3. `0 2195456000 65536` — uid 0..65535 пода соответствуют диапазону узла от 2195456000 (у вас другое число, кратное 65536).
4. `CapEff` одинаков, но во втором поде эти capabilities действуют только в своём namespace.

#### Шаг 3. Найти процессы на узле

Команда показывает, под какими uid эти же процессы видны на узле.

```bash
docker exec lab-worker sh -c 'ps -eo uid,pid,args | grep "[s]leep 360"'
```

| Часть команды | Значение |
|---|---|
| `ps -eo uid,pid,args` | uid, pid и команда всех процессов узла |
| `grep "[s]leep 360"` | найти два наших `sleep`, не находя сам `grep` |

Ожидаемый результат:

```
        0   41231 sleep 3601
2195456000   41307 sleep 3602
```

Разбор:

1. Процесс первого пода на узле работает от root (uid 0), то есть побег из него даёт права root узла.
2. Процесс второго пода работает от uid 2195456000 — пользователя без прав на узле, хотя внутри пода он root.

#### Шаг 4. Проверить запрет вместе с hostNetwork

Команда пытается создать userns-под с сетью узла.

```bash
k apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata: {name: userns-hostnet}
spec:
  hostUsers: false
  hostNetwork: true
  containers:
  - {name: app, image: "localhost:5001/busybox:1.37", command: ["sleep", "3600"]}
EOF
```

| Часть команды | Значение |
|---|---|
| `hostUsers: false` вместе с `hostNetwork: true` | сочетание, которое API не допускает |

Ожидаемый результат: ответ вида `The Pod "userns-hostnet" is invalid` с причиной про `hostUsers` и `hostNetwork` (точный текст зависит от версии).

Разбор: API-сервер проверяет сочетание при создании, поэтому пода нет. User namespace и общие пространства имён узла несовместимы: либо под изолирован, либо делит ресурсы узла.

**Итог.**

| Что узнали | Где видно |
|---|---|
| Требования: ядро 6.3+, containerd 2.0+, runc 1.2+ | шаг 1 |
| В userns-поде uid_map сдвинут на большой диапазон | шаг 2 |
| Root пода на узле — обычный uid с большим номером | шаг 3 |
| userns не сочетается с общими пространствами узла | шаг 4 |

**Уборка.** Удаляем поды, функцию `k` и namespace части.

```bash
k delete pod host-users userns userns-hostnet --ignore-not-found
unset -f k
kubectl delete ns lab-06-2
rmdir ~/lab/k8s/06-2
```

**Вопросы для самопроверки.**

1. Чем `hostUsers: false` отличается от `runAsNonRoot: true`?
2. Почему для user namespaces нужны id-mapped mounts?
3. Что случится с подом `hostUsers: false` на узле с ядром 6.1?
4. Почему uid в поде 0 не делает процесс root на узле?

<details>
<summary>Ответ</summary>

1. `runAsNonRoot` запрещает root внутри пода. `hostUsers: false` оставляет root внутри, но на узле это обычный uid.
2. Тома должны выглядеть для процесса с правильными владельцами без рекурсивного chown. Ядро пересчитывает uid при монтировании.
3. Под не запустится: ядро не поддерживает отображение для нужных файловых систем.
4. Ядро применяет `uid_map`: root пода соответствует uid из диапазона узла, у которого нет прав на файлы и процессы узла.

</details>

---

## → Дальше

Мы разобрали, что включают kubelet и containerd внутри контейнера: пользователя, capabilities, seccomp, AppArmor, user namespace и песочницу. Но все эти поля заполняет автор манифеста, и недосмотр оставляет под без защиты. Следующая часть, 06-3, показывает, как кластер проверяет поля при создании пода. Pod Security Admission применяет уровни baseline и restricted по меткам namespace, а политики admission добавляют свои правила. Она идёт следующей, потому что проверять можно только то, что уже понимаешь.
