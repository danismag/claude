# Ревью 04-1 ConfigMap и Secret

Файл: /home/user/claude/kubernetes/04-config-storage/04-1-configmap-secret.md
Старая версия: e755ced. Режим: только текст. Источники берутся из ветки release-1.36 кода kubernetes/kubernetes и из kubernetes/website main.

## Найденные ошибки (было → стало)

1. Задержка обновления тома. Было: «до минуты», «в пределах минута плюс кэш», «максимум — период плюс небольшая задержка». Это противоречит замерам 63 и 80 с. Стало: период `syncFrequency` 1 мин, kubelet добавляет случайный разброс до 50 %, то есть 60–90 с, поэтому задержка доходит до 1,5 мин. Источник: pod_workers.go, `workerResyncIntervalJitterFactor = 0.5`, `wait.Jitter(p.resyncInterval, …)`. Исправлено в таблице §1, в §2, §5, §6, в разборах шагов 3, 4 и 5 работы 1.
2. Тексты отказов immutable. Было: `field is immutable when immutable is set`, у второго отказа нет пути поля. Стало: ``field is immutable when `immutable` is set`` с обратными кавычками, второй отказ идёт с путём `immutable:`. Источник: validation.go, ValidateConfigMapUpdate, `field.Forbidden(field.NewPath("immutable"|"data"), "field is immutable when `immutable` is set")`. Исправлено в шаге 1 работы 2 и в §5.
3. KEP-3926. Было: «в 1.37 добавлено … на стенде 1.36 его нет». Стало: в 1.36 alpha и выключено (alpha с 1.32), в 1.37 beta и включено. Источник: feature-gates/AllowUnsafeMalformedObjectDeletion.md.
4. Риски работы 3, откат. Было: «если API-сервер не стартует — верните .bak». Это опасно после шага 4: исходный манифест без флага не расшифрует уже зашифрованные Secret. Стало: возврат .bak допустим только при сбое на шаге 3, когда зашифрованных записей ещё нет; после шага 4 откат идёт только шагами 5 и 6; enc.yaml не удалять, пока есть зашифрованные записи.
5. Риски работы 3, крайний случай. Было: «пересоздайте стенд скриптами lab-down.sh и lab-up.sh». Простой `lab-down.sh` только останавливает контейнеры, а манифест и etcd остаются (00-1). Стало: `lab-down.sh --purge`, затем `lab-up.sh`, с предупреждением о пересборке образов.
6. Шаг 3 работы 3: добавлено предупреждение, что `sed` выполняют один раз, потому что повтор дублирует строки.
7. Шаг 4 работы 1: «порядок значений может быть другим» → «результат прогона автора (у вас числа будут другими)»: в старой части порядок 47/63 не зафиксирован.
8. §6: KubeletEnsureSecretPulledImages уточнён — образы, загруженные в обход kubelet, по умолчанию не проверяются (политика `NeverVerifyPreloadedImages`). Добавлена фраза из исследования: с 1.34 (beta) kubelet передаёт плагину учётных данных токен ServiceAccount пода (KubeletServiceAccountTokenForCredentialProviders).
9. §3: «серверов API-сервера» → «экземпляров API-сервера».

## Проверено без замечаний

- sed по `^    - --etcd-servers=.*` с заменой `&\n$FLAG`. `&` воспроизводит строку целиком, `\n` в замене понимает GNU sed узла kind. В FLAG, MNT и VOL нет `|`, `&` и `\`. Отступы (4 пробела у элементов command и volumeMounts, 2 у volumes) совпадают с манифестом kubeadm. Элемент в flow-стиле `- {…}` сразу после `volumeMounts:` и `volumes:` — корректный YAML. Каждый из шаблонов встречается в манифесте один раз. `grep -n -E 'encryption|/enc|name: enc'` даст три строки.
- Копия манифеста лежит в /root узла, временный файл шага 5 — тоже в /root, вне каталога manifests.
- Метрика `apiserver_storage_transformation_operations_total`: метки resource, transformation_type, transformer_prefix, status. Для from_storage с пустым префиксом пишется `"identity"`, иначе строка префикса, без совпадения — `"unknown"`. Источник: value/metrics.go и transformer.go. Вывод шага 5 (`identity` и `k8s:enc:secretbox:v1:`) совпадает со старым замечанием и кодом.
- Лимит 1 МиБ: `field.TooLong(..., core.MaxSecretSize)` одинаков для ConfigMap и Secret; тип Secret неизменяем (ValidateImmutableField).
- Хранение на узле: том Secret — emptyDir с `Medium: Memory` (tmpfs), том ConfigMap — emptyDir без medium, то есть диск (secret.go, configmap.go). Права 0644 по умолчанию задаёт defaulting (`DefaultMode`).
- Документация configmap.md: задержка — «kubelet sync period + cache propagation delay», по умолчанию watch; subPath не обновляется; immutable закрывает watch.
- kms-provider.md: KMS v1 deprecated с 1.28 и выключен с 1.29 (`KMSv1=true`); v2 stable с 1.29; timeout 3 с; опрос Status раз в минуту, при сбое раз в 10 с, около 3 мин на последнем верном состоянии; DEK из seed; `key_id`; KEK — не реже раза в 90 дней; имя нельзя менять.
- encrypt-data.md: таблица провайдеров (aescbc — padding oracle, aesgcm — 200 000 записей, secretbox — 32 байта), автоперезагрузка с опросом раз в минуту и метрикой `…automatic_reload_last_timestamp_seconds`, префикс `k8s:enc:<provider>:v1:<key>:`, шаги ротации, удаление нечитаемой записи из etcd как единственный выход.
- KubeletEnsureSecretPulledImages: alpha 1.33–1.34, beta и включён с 1.35.
- Стенд: 127.0.0.1:8088, Host orders.localhost, путь /api/orders существует (00-1 §183). Четыре манифеста kubeadm.
- Формат: блоки §3 по порядку, эмодзи и «Проверено» нет, лабораторные по §3.2, «Риски» стоят первыми в работе 3, уборка полная, `pkill` и `apt autoremove` нет.

## Читаемость

До правок: 245 предложений, средняя длина 11,0 слова, 40 % коротких, нарушений 0.
После правок: 247 предложений, средняя длина 11,1 слова, 40 % коротких, нарушений 0. По ходу правок появлялись предложение в 27 слов и абзац из 6 предложений, оба исправлены.

## Исследование

Учтены: KMS v2 GA и KMS v1 выключен (1.29), KEP-3926, KubeletEnsureSecretPulledImages, токен SA для pull. Не добавлен размер memory-backed emptyDir по лимитам (GA 1.32): он относится к emptyDir, место ему в 04-2 или 02-x. Запрет ссылок static pod на Secret и ConfigMap (1.37) план отдаёт в 01-2.

## Не подтверждено (для 00-plan)

- KMS v2 на стенде не проверялся, только теория.
- Автоперезагрузка шифрования (флаг и метрика) — только по документации.
- Вывод шага 5 работы 3 (две строки transformer_prefix) восстановлен по старому замечанию и коду, живым выводом с `grep -o | sort -u` не подтверждён.
- Текст отказов immutable в шаге 1 работы 2 взят по validation.go: в живом выводе стоят обратные кавычки, путь `immutable:` во втором отказе живым выводом не подтверждён.
- Вывод `od -c` в шаге 4 работы 3 сжат вручную.
- Вывод grep в шаге 3 и список манифестов в шаге 6 работы 3 описаны словами.
- Вставка через sed по шаблону `--etcd-servers=.*` с переменными в новой форме не прогонялась.
