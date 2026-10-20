Сомнительные места 00-1 (писатель, до исследования):
- Работа 1 целиком ожидаемая: версии kind/kubectl/helm, hello-world; sysctl max_user_watches 65536 «по памяти» (на новых ядрах значение динамическое); URL установки kind v0.32.0, pkgs.k8s.io v1.36, helm v4.2.2.
- Работа 2: `error: current-context is not set`; вывод docker ps/crictl ps; `{"repositories":[]}`; вывод top nodes / get gateway / get storageclass; provisioner `rancher.io/local-path`; формат custom-columns (cpu 12, memory 16315248Ki — реальные).
- Работа 3: вывод `crictl pull`; rollout status sts/postgres; ответ curl сокращён.
- Работа 4: INSERT/DELETE через psql — новые команды и вывод.
- Оценки «около 600 МиБ памяти подов», «около 200 МБ диска» — не замеры.
- Узлы kind privileged — из знаний о kind.
- Код orders-api изменён (переносы, stop_later вынесен из лямбды, переменная pod) — проверить корректность Python и неизменность поведения.
- Таблица §2 «Где разбирается» — ссылки на части сверить с картой 00-plan §4 (нумерация обновлена).
- Учесть исследование: containerd 2.3 (config v4), kind 0.32 и kubeadm v1beta4, cgroup v2 обязателен с 1.35, Kubernetes 1.37 существует.
