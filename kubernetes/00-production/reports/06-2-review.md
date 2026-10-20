# Ревью 06-2 «Изоляция контейнера»

Файл: kubernetes/06-access-security/06-2-container-isolation.md. Режим «только текст». Продолжено после прерванного ревьюера: его правки (пользователь образа, enable_unprivileged_ports, «сотни вызовов», RuntimeDefault по капабилити, kind без apparmor_parser) сверены с исходниками и сохранены.

## Найденные ошибки (было → стало)

1. §2 seccomp: «`mount` и `bpf` только при CAP_SYS_ADMIN» → `bpf` пропускается при CAP_SYS_ADMIN или CAP_BPF (contrib/seccomp/seccomp_default.go).
2. §2 AppArmor в kind: добавлено следствие — под без поля идёт без профиля, под с явным профилем на стенде не запускается.
3. Лаб. 2 шаг 3: ожидался `Running` и `cri-containerd.apparmor.d (enforce)` на kind → на kind под не запускается: CreateContainerError `failed to generate apparmor spec opts: apparmor is not supported` или Failed/AppArmor `Cannot enforce AppArmor: AppArmor is not enabled on the host`; строка `(enforce)` оставлена как результат на обычном узле Ubuntu. Причина: containerd hostSupports() требует /sbin/apparmor_parser и пустую переменную `container`, в образе kind нет apparmor и стоит `ENV container=docker`.
4. Лаб. 2 шаг 3: вариант «No such file» для Manjaro → `N` (модуль собран в ядро, но не включён); отсутствие файла — только для ядра без AppArmor. Разбор п. 3 «узел без прав на ядро» → «в узле kind нет apparmor_parser». Строка «Итог» и схема опыта обновлены.
5. §5: «Pod заблокирован kubelet: профиль не загружен или модуль выключен» → два пункта: Failed с причиной AppArmor (kubelet проверяет только включённость модуля, pkg/security/apparmor/validate.go) и CreateContainerError `apparmor profile not found` (профиль не загружен — ошибка рантайма).
6. §3 procMount: «поле допустимо только с hostUsers: false» → только значение `Unmasked`; добавлен текст ошибки валидации `` `hostUsers` must be false to use `Unmasked` ``.
7. §3 userns: добавлено, что kubelet читает subuid через `getsubids`.
8. §4: «user.linux заполняется, когда kubelet и рантайм поддерживают политику (1.35)» → рантайм containerd 2.0+ или CRI-O 1.31+.
9. §6: в значения по умолчанию добавлен AppArmor (RuntimeDefault, если узел и рантайм поддерживают; иначе без профиля — security-context.md).
10. Лаб. 3 шаг 4: «текст зависит от версии» → точный текст `The Pod "userns-hostnet" is invalid: spec.hostNetwork: Forbidden: when `hostUsers` is false`; добавлено про альфа-флаг UserNamespacesHostNetworkSupport (1.35, выкл.).
11. Лаб. 3 шаг 1: `containerd containerd.io …` (строка пакета Docker) → `containerd github.com/containerd/containerd/v2 v2.3.1 …` (kind ставит containerd из своих сборок).
12. Лаб. 3: «работа не проходила» (читается как «падала») → «не выполнялась».
13. Лаб. 1, ответ 4: добавлено, что containerd 2.x снимает проблему низких портов через ip_unprivileged_port_start=0.
14. Лаб. 2: выравнивание колонок в выводе `k get pod sc-missing`.

## Читаемость

До: 254 предложения, средняя 11,4 слова, короче 10 слов 38 %, нарушений 0. После правок: 262 предложения, средняя 11,4, короче 10 слов 38 %, нарушений 0 (промежуточно появились список из 8 пунктов и предложение 27 слов — исправлены слиянием пунктов `hostUsers`/`procMount` и делением предложения).

## Подтверждено (источник)

- 14 capabilities containerd и маска a80425fb — pkg/oci/spec.go defaultUnixCaps (маска пересчитана по битам).
- Ambient capabilities очищаются (WithoutAmbientCaps) — internal/cri/server/container_create.go; CapEff=0 у не-root следует из execve без ambient.
- enable_unprivileged_ports=true по умолчанию с 2.0, только для подов без hostNetwork — docs/cri/config.md, internal/cri/config/config_unix.go, podsandbox/sandbox_run_linux.go; миграция конфига v2 (kind) значение не переопределяет — plugins/cri/runtime/plugin.go; конфиг kind его не задаёт.
- RuntimeDefault: defaultAction ERRNO, mount/bpf/reboot по капабилити, kexec_load отсутствует — contrib/seccomp/seccomp_default.go. Число заблокированных вызовов в тексте не приводится.
- seccompDefault stable 1.27, флаг --seccomp-default — tutorials/security/seccomp.md; kind по умолчанию его не включает — kind pkg/cluster/internal/kubeadm/config.go; стенд 00-1 тоже.
- AppArmor: поле с 1.30, GA 1.31 (research R31, apparmor.md); kubelet-отказ «Cannot enforce AppArmor: …», reason AppArmor — pkg/kubelet/lifecycle/handlers.go; «apparmor is not supported» — containerd internal/cri/sputil/apparmor_linux.go.
- User namespaces GA 1.36 (kube_features.go), ядро 6.3+, containerd 2.0+/CRI-O 1.25+, runc 1.2+/crun 1.9+, idsPerPod с 1.33 кратно 65536 по умолчанию 65536, subuid-ограничения, overflow 65534, метрики, запрет hostNetwork/hostPID/hostIPC/volumeDevices — concepts/workloads/pods/user-namespaces.md, validation.go validateHostUsers; диапазон по умолчанию 65536…2^32−65536 со случайным выбором слота (kubelet_pods.go, userns_manager.go) — пример 2195456000 допустим.
- supplementalGroupsPolicy GA 1.35, procMount GA 1.36, SELinuxMount GA и включён в 1.37 — kube_features.go.
- Текст runAsNonRoot — pkg/kubelet/kuberuntime/security_context_others.go.
- allowPrivilegeEscalation=false несовместим с privileged/CAP_SYS_ADMIN, fsGroupChangePolicy stable 1.23, не действует на secret/configMap/emptyDir, вывод id/ls для fsGroup — security-context.md, validation.go.

## Не подтверждено (для 00-plan §7)

- Лаб. 1 шаги 1, 3, 4: строки вывода ожидаемые (маска, ip_unprivileged_port_start=0 в kind, формат busybox id/ls).
- Лаб. 2 целиком: текст события для отсутствующего seccomp-профиля; какой из двух отказов AppArmor даст kind на конкретном хосте (зависит от того, видит ли kubelet в узле /sys/kernel/security/apparmor).
- Лаб. 3 целиком: работа userns в узле kind 0.32 на ядре хоста ≥ 6.3; значения uid_map и ps условные.
- Порог «десятки МиБ на под» для песочниц и overhead 64Mi/100m в примере RuntimeClass — иллюстративные.
