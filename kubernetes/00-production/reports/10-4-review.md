# Ревью 10-4 «Сертификаты и обслуживание узлов»

Файл: /home/user/claude/kubernetes/10-cluster-ops/10-4-certs-node-maintenance.md. Старая версия: e755ced:kubernetes/10-cluster-ops/10-3-certs-node-maintenance.md. Режим «только текст», ничего не запускалось.

## Найденные ошибки (было → стало)

1. §3 «Продлить сертификаты»: `kubeadm certs renew --csr-only` (такого флага в kubeadm 1.36 нет) → `kubeadm certs generate-csr` (certs.go release-1.36, kubeadm-certs.md).
2. §2 «Ротация»: «одобряет, потому что подписан действующим сертификатом» → запрос пришёл от того же узла с действующим сертификатом, и привязка RBAC даёт `system:nodes` право на selfnodeclient (в kubeadm `kubeadm:node-autoapprove-certificate-rotation`). §5: «у controller-manager нет права одобрять» → «удалена привязка RBAC, которая разрешает автоматическое продление».
3. §5 «Утёк kubeconfig администратора»: логическая ошибка. Было: удалить `kubeadm:cluster-admins`, потом через super-admin «создать привязку заново» — тогда украденный сертификат снова получает права. Стало: привязку не возвращать, пока украденный сертификат не истёк; администраторам выдают новые сертификаты с другой группой.
4. §5 «Узел не вернулся»: уточнено про swap — по умолчанию `failSwapOn: true`, ошибка `running with swap on is not supported` (container_manager_linux.go); swap GA с 1.34, включается явно `failSwapOn: false`. Утверждение «не стартует по умолчанию» верно.
5. §5 «Сменился адрес»: строка ошибки приведена к 10-3: `failed to create etcd client: error syncing endpoints with etcd`; добавлена правка адреса в манифестах static pod (как в 10-3). Эпизод в 10-3 есть (§5 «etcd: сертификат выписан на старый адрес» и ЛР1 шаги 3–4).
6. Перезапуск static pod: документация kubeadm требует ждать 20 с (`fileCheckFrequency`), в лабе было `sleep 15` при подписи схемы 5 «пауза длиннее периода опроса». Стало: `sleep 20` в ЛР2 шаг 4, подпись схемы 5 с 20 с; в разборе — замеры прогона автора с паузой 15 с и пояснение.
7. ЛР1 шаг 1: в выводе нет колонки `EXTERNALLY MANAGED`, которую печатает kubeadm 1.36 (certs.go) → добавлена фраза, что колонка опущена ради ширины. Разбор `9y`: «10 лет минус возраст стенда» → остаток чуть меньше 10 лет, округлён вниз.
8. ЛР1: блок «Риски» в работе, которая только читает, убран (по §3.2 «Риски» — только при изменениях).
9. ЛР2 шаг 5: строки `get nodes` в старой части не было → пометка «строки узлов — ожидаемые».
10. ЛР3 шаг 3: «за секунду после перезапуска» противоречило старому выводу (`node rebooted +38s`, `node Ready +38s`) → «в ту же секунду».
11. §3 «Выдать kubeconfig»: добавлено, что без `--config` `kubeadm kubeconfig user` берёт адрес API-сервера и имя кластера из значений по умолчанию (LoadOrDefaultInitConfiguration).
12. §4 «Метрики»: все метрики ALPHA (отмечено); добавлена `kubelet_certificate_manager_server_ttl_seconds`.

## Читаемость

До: 218 предложений, средняя 10,9 слова, короче 10 слов 39 %, >25 слов 0, нарушений 0. После правок фактов появился абзац из 6 предложений (§5 «Утёк») — разделён. Сшиты 4 пары рубленых предложений (§1, §3 ×2, подготовка лаб). После: 217 предложений, средняя 11,3, короче 10 слов 37 %, >25 — 0, нарушений 0. Строки кода ≤100 знаков.

## Подтверждено (источник)

- check-expiration: столбцы, `<invalid>` (HumanDuration), отсутствие kubelet.conf — kubeadm-certs.md, certs.go release-1.36.
- Строка `Done renewing certificates. You must restart …` и формат `%s renewed` — certs.go; откат на значения по умолчанию при недоступном кластере («Falling back to default configuration») — certs.go.
- `--certificate-renewal=false` для `upgrade apply` и `upgrade node`; 8760h/87600h в v1beta4 — kubeadm-certs.md.
- admin.conf: `O=kubeadm:cluster-admins, CN=kubernetes-admin`; super-admin.conf: `O=system:masters, CN=kubernetes-super-admin` — kubeadm-certs.md.
- serverTLSBootstrap, `kubernetes.io/kubelet-serving` не одобряется встроенным подписантом, `kubectl certificate approve` — kubeadm-certs.md, kubelet-tls-bootstrapping.md.
- `kubeadm kubeconfig user --client-name (обязателен) --org --validity-period` — kubeconfig.go.
- Ротация на 70–90 % срока с джиттером — client-go certificate_manager.go (jitteryDuration).
- `--cluster-signing-duration` 8760h0m0s — справочник kube-controller-manager.
- certificate-key/upload-certs 2 ч, `kubeadm init phase upload-certs --upload-certs` — high-availability.md.
- `kubeadm reset` удаляет локального члена stacked etcd — kubeadm-reset.md.
- `apiserver_client_certificate_expiration_seconds` (ALPHA, не устарела, гистограмма до ~1 года) — x509.go; `kubelet_certificate_manager_client_ttl_seconds` — cmd/kubelet/app/server.go; `kubelet_certificate_manager_client_expiration_renew_errors`, `…_server_ttl_seconds` — pkg/kubelet/certificate/kubelet.go.
- `node-monitor-grace-period` 50 с — 01-2; CSR и system:masters — 06-1.

## Не подтверждено (для 00-plan §7)

- ЛР1 шаг 3 вывод subject целиком (по документации, не снимался).
- ЛР1 шаг 2 команды `ls`/`readlink`/`-subject -enddate` в новой форме; порядок строк `ls`.
- Обрамление дат openssl (день и год восстановлены) в ЛР1 шаг 4 и ЛР2 шаг 2; строки `[renew] …` и `certificate for serving the Kubernetes API renewed`.
- ЛР2 шаг 1 (резервная копия) и откат `cp -a` — новые, не проверены.
- ЛР2 шаг 4 с `sleep 20` (в прогоне 15 с).
- ЛР2 шаг 5 строки `get nodes`; формат `orders: 200`.
- ЛР2 шаг 6 целиком.
- ЛР3 шаг 1 переписанный цикл нагрузки с pid-файлом; шаг 2 служебные строки drain; шаг 3 значения renewTime; шаг 4 формат custom-columns.
- Токен join 24 ч — по памяти (`kubeadm token create --ttl` по умолчанию 24h), страница не сверена.
- Имя ClusterRoleBinding `kubeadm:node-autoapprove-certificate-rotation` и права 0600 у super-admin.conf — по памяти о коде kubeadm.
- Подхват серверного сертификата apiserver без перезапуска — замер старой части, документация говорит только «reload поддерживается не для всех».
- Ссылки на 10-1 (PKI, токен join) — проверить после готовности 10-1.
