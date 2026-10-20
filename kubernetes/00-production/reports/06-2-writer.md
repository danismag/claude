# Отчёт писателя: 06-2 Изоляция контейнера

Файл: /home/user/claude/kubernetes/06-access-security/06-2-container-isolation.md

## Объём и читаемость
Проза около 2900 слов (252 предложения, среднее 11,3 слова, >25 слов: 0, нарушений 0). Ниже ориентира 3,5 тыс.: механизмы помещены полностью, вода не добавлялась. Лабораторные не резались.

## Сомнительные места (для ревьюера)
1. AppArmor: задание говорит GA 1.30; research и kubernetes.io — поле с 1.30, stable (GA) 1.31. В тексте так и написано.
2. CapEff по умолчанию 00000000a80425fb (14 capabilities Docker/containerd) — по памяти, лаб. 1 шаг 1 и 3.
3. Список 14 capabilities containerd — по памяти.
4. Containerd 2.x включает ip_unprivileged_port_start=0 (enable_unprivileged_ports по умолчанию true) — по памяти, не подтверждено; текст в §2 и лаб. 1 шаг 3 сформулирован как «проверьте».
5. Для не-root процесса CapEff=0 при add (нет ambient capabilities в Kubernetes) — по памяти, лаб. 1 шаг 3.
6. RuntimeDefault seccomp «блокирует около 40 вызовов», ядро «около 450 вызовов» — приблизительно, без источника.
7. Лаб. 1 шаг 4: тексты ошибок (runAsNonRoot, Read-only file system), вывод id/ls -ld (groups=2000,3000, drwxrwsrwx).
8. Лаб. 2: профиль deny-mkdir (имена mkdir/mkdirat, arm64 без mkdir — runc должен пропустить), CreateContainerError для отсутствующего профиля, имя cri-containerd.apparmor.d (enforce), поведение AppArmor в узле kind (контейнер без apparmor_parser); seccompDefault в kind не включён (шаг 1 ожидает Seccomp 0).
9. Лаб. 3: uid_map (значение 2195456000 условное), ps на узле, формулировка ошибки hostNetwork+hostUsers (текст не приводится), containerd 2.3 + ядро хоста.
10. supplementalGroupsPolicy GA 1.35 и procMount GA 1.36 — по research; поле status.containerStatuses[].user.linux заполняется с 1.35 — по документации/research. userNamespaces.idsPerPod с 1.33 — по документации.
11. Метрики started_user_namespaced_pods_total — по странице user-namespaces.
12. SELinuxMount GA 1.37 — по research.
13. Реальный вывод есть только в лаб. 1 шаг 2 (из старой 06-2, прогон 2026-10-14). Остальное ожидаемое; лабы 2 и 3 начинаются фразой «Эту работу вы выполняете сами…»; в лаб. 1 фраза стоит для шагов 1, 3, 4.

## Для 00-plan.md §7 (не проверено)
Лаб. 1 шаги 1, 3, 4; лаб. 2 целиком; лаб. 3 целиком; значения из пунктов 2–9 выше. Лаб. 2 меняет файл в контейнере узла lab-worker — есть блок «Риски».

## Что перенесено/выкинуто из старой 06-2
- PSA, уровни, режимы enforce/warn/audit, dry-run на orders, ValidatingAdmissionPolicy, порядок admission — в 06-3 (пишет другой агент); здесь только ссылки.
- Кейс «включили restricted — релиз прошёл, а подов нет» (enforce не трогает работающие поды, ошибка в событиях ReplicaSet) — в модуль 12.
- Вопросы 1–7 (securityContext, PSS, безопасное включение restricted, запрет latest, VAP против вебхука, мутация и PSA, readOnlyRootFilesystem) — в 12-1 (часть про PSA/VAP — к 06-3).
- Подводные камни: enforce не проверяет работающие поды; события у ReplicaSet; enforce-version latest; readOnlyRootFilesystem без emptyDir; БД под root; порт реестра не тег; мутирующие вебхуки ломают PSA — в 12-1/12-2.
- Задание со звёздочкой (перевод orders на restricted с PostgreSQL uid 70, fsGroup) — к 06-3/12-2.
- RuntimeClass: практики нет (gVisor/Kata — теория), как предписано заданием.
