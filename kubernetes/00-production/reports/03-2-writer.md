# Отчёт писателя: 03-2 Service и kube-proxy

Файл: /home/user/claude/kubernetes/03-networking/03-2-service-kube-proxy.md (03-2-sample-lab.md не тронут).

## Заголовки
## Где мы на карте; ## 1 Какую задачу решает Service (Постоянный адрес..., Типы Service, Как клиент находит Service);
## 2 Как устроен (EndpointSlice, kube-proxy, Путь пакета в iptables, Режимы kube-proxy);
## 3 Как управлять (Манифест и порты, eTP/iTP, sessionAffinity, trafficDistribution, LoadBalancer);
## 4 Как увидеть состояние (Цепочка проверок, Правила и состояние kube-proxy, Условия эндпоинтов);
## 5 Что ломается (Отказ или таймаут, Пустой срез, Неверный порт, Трафик снаружи, Прилипание/UDP/обновления);
## 6 Пределы (Числа, ServiceCIDR, Что устарело); ## Лабораторные работы (1-5); ## → Дальше.

## Объём
Проза (без кода и таблиц, включая лабы): ~6,7 тыс. слов; теория ~3,3 тыс., остальное - лабы (лаба 1 перенесена дословно). Читаемость: средняя 11,2 слова, >25 слов: 0, нарушение одно - строка iptables-save 162 знака (оставлена целиком, как в эталоне и 00-plan).

## Отступления от задания/плана (внести в 00-plan §6)
- Лаб пять, не четыре: добавлена 5 «sessionAffinity и trafficDistribution» (реальный вывод старой части; иначе пропадал). Нумерация 1-4 по плану сохранена.
- Лаба 1: шаг «Создать namespace» вынесен во вводный раздел, шаги 2-8 -> 1-7; Итог/Уборка/Вопросы стали жирными заголовками как в 02-1; Риски и Уборка скорректированы (namespace не удаляется, его удаляет лаба 5); результат уборки (строки deleted) - ожидаемый.
- Работы 3-5 разделяют Deployment/Service echo из работы 3 (зависимость между лабами). Лаба 4 сама создаёт echo-np (NodePort 30081).
- Время лаб ~2 ч (5 работ).
- Метка topology.kubernetes.io/zone в лабе 5 без префикса lab-03-2/ (стандартный ключ); оговорено в Рисках.

## СОМНИТЕЛЬНЫЕ места
Ожидаемый (не реальный) вывод:
- Лаба 2: шаг 1 (created/rolled out); шаг 3 - строка DROP в KUBE-EXTERNAL-SERVICES (форма по памяти о коде kube-proxy; в старой части был только пересказ); шаг 5 - пустой healthCheckNodePort (старая часть: «пуст»); строки `service/echo-np patched` добавлены в вывод цикла.
- Лаба 3: шаг 1 и шаг 3 (три эндпоинта после завершения).
- Лаба 4: строки warning/configured/restarted/rolled out/pod created; число 19 до переключения взято из «после возврата» старой части; шаг 3 - строки echo-np (ClusterIP 10.96.126.27) в старой части были при echo-np из шага 2; теперь echo-np создаётся в шаге 1 - порядок строк grep -m3 мог измениться; команда echo в sh -c приведена к тексту вывода («iptables rules for echo»).
- Лаба 5: шаг 1 (get pods -o wide); уборка. Имена подов (xcktj/fl22g/sxwfr/qmt9p) в старой части взяты из разных прогонов (набор в «no affinity» и «default» разный) - оставлены как есть с оговоркой «имена у вас другие». В hints сокращено `forNodes:[…]`.
- Уборка лабы 1 (deleted-строки).
Факты из памяти/документации, не сверены:
- Endpoints v1: лимит 1000 адресов; --max-endpoints-per-slice до 1000; healthCheckNodePort отвечает 200/503; internalTrafficPolicy Local отбрасывает без локальных эндпоинтов.
- ServiceCIDR/IPAddress GA 1.33, объект `kubernetes`, запрет удаления с выданными адресами, `kubectl get servicecidr/ipaddress`; пример на 10.97.0.0/16.
- Порты kube-proxy 10249 (метрики, 127.0.0.1) и 10256 (health); метрика kubeproxy_sync_proxy_rules_duration_seconds; имя порта до 15 знаков; переменные окружения *_SERVICE_HOST.
- nftables: «route_localnet не включается» как причина недоступности localhost:NodePort (в задании - только факт); ядро 5.13; beta 1.31/GA 1.33; kube-proxy 1.37 предупреждает без явного mode (по CL37).
- ipvs: сроки удаления 1.40-1.43 (источники расходятся, так и написано); в 1.35 устарел.
- trafficDistribution: PreferSameZone/PreferSameNode GA 1.35; PreferClose «устарел, замена PreferSameZone» (подтверждено предупреждением в выводе).
- externalIPs: CVE-2020-8554, DenyServiceExternalIPs; сроки 1.36/1.40/1.43.
- cloud-provider-kind: описание по памяти (Envoy-контейнеры в сети kind, доступ к docker.sock); без лабы. Cilium - одна фраза.
- Имя Service с цифры - с 1.37 (RelaxedServiceNameValidation, трактовка по памяти).
- UDP conntrack: kube-proxy чистит устаревшие записи (по памяти).
- `mode: iptables` в config.conf kind (из старой части); `nft`/`conntrack` есть в образе узла kind.

## Выброшено / перенесено (в модуль 12 и др.)
- Кейс из прода: Local на Service Ingress-контроллера -> потеря 2/3 запросов за HAProxy; фикс healthCheckNodePort + MetalLB или PROXY protocol, DaemonSet на выделенных узлах.
- Вопросы собеседования (9): как Service находит поды; ClusterIP/NodePort/LB; мгновенный Connection refused; IP клиента за NodePort и Local; gRPC на один под; терминирующий под в срезе; nftables против iptables; межзонный трафик и риск; Service работает с одних узлов.
- Подводные камни: пустой срез = refused; targetPort числом; Local без healthcheck; Envoy Gateway по умолчанию Local; ClientIP за SNAT; соединения, не запросы; PreferClose устарел; port-forward svc выбирает один под; ClusterIP не пингуется.
- Ловушка topologySpreadConstraints maxSkew 1 при 3 репликах на 3 узлах: rollout зависает (surge-под не помещается; лечится maxSurge 0 / ScheduleAnyway) - не включена, место в 05-3.
- Чеклист и «Задание со звёздочкой» (LoadBalancer через cloud-provider-kind/MetalLB, healthCheckNodePort на узлах) - заменены теорией §3.
- Не включены ServiceCIDR-лаба (только теория), Cilium, mesh.
