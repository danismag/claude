Сомнительные места 01-2:
- Работа 2 шаг 1: узел вывода дерева cgroup принят lab-worker. Шаг 2: в jq добавлено cgroupDriver, значение текстом, формат jq изменён.
- Работа 1 шаг 3: вывод custom-columns ожидаемый; «три маршрута via». Шаг 2: ps pause описан словами.
- Работа 3: пустой каталог manifests; «около 2 минут».
- Работа 4: размещение web «ожидаемо»; скрипт-наблюдатель переписан (NJ/PJ) — проверить bash и jsonpath; crictl ps --name postgres — комментарий вместо вывода; FailedScheduling сокращено.
- Факты: сокет /run/containerd/containerd.sock; shim; /var/lib/kubelet/config.yaml; PLEG relist 1 с, порог 3 мин; kindnet и spec.podCIDR; node-monitor-grace-period 50 с (раньше 40 с) — с какой версии; продление Lease ~10 с; удаление Node → поды удаляет pod GC; taint out-of-service — справочно.
- Учесть исследование: cgroup v1 — kubelet не стартует по умолчанию с 1.35 (failCgroupV1); containerd 1.x не поддерживается с 1.36, containerd 2.3 LTS, config v4; swap GA 1.34 (ссылка на 05-2); fine-grained kubelet authz GA 1.36.
