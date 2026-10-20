# Ревью 01-2 «Узел: kubelet, CRI, CNI, kube-proxy»

## Найденные ошибки (было → стало)
- Пропущена обязательная по плану теория: cgroup v1 / containerd 2.x → добавлен §6 «Требования к узлу: cgroup v2 и containerd 2.x»: failCgroupV1=true с 1.35, ошибка kubeadm SystemVerification, проверка `stat -fc %T /sys/fs/cgroup/` → `cgroup2fs`, обход failCgroupV1:false как анти-рецепт (удаление обхода — план 1.38), ядро 5.8+/5.9+; containerd для 1.36 — 2.2+/2.3+, 1.x — последний 1.35; 2.3 LTS до 2028-04-30; конфиг version 3 (2.0+) / 4 (2.3+), `containerd config migrate`, откат с v4 невозможен.
- §3 драйвер cgroups: «в kubelet cgroupDriver: systemd» как основной способ → с 1.34 (stable) kubelet берёт драйвер у рантайма через CRI RuntimeConfig, cgroupDriver — запасной вариант; поддержка containerd 2.0+, CRI-O 1.28+.
- §3 конфиг kubelet: добавлены drop-in каталог `--config-dir` (stable 1.35, файлы .conf по алфавиту) и сохранение готовности подов после перезапуска kubelet с 1.35 (KEP-4781).
- §3 static pods: добавлено, что в 1.37 kubelet сам отклоняет static pods со ссылками на Secret/ConfigMap.
- §4 configz: добавлено право `nodes/configz` (fine-grained kubelet authz, GA 1.36) вместо `nodes/proxy`.
- §5: «Контроллер сборки мусора удалит поды» → «контроллер сборки подов (PodGC)»; назван admission-плагин DefaultTolerationSeconds.
- §6: добавлено `maxParallelImagePulls` (stable 1.35) при serializeImagePulls=false.
- Работа 2 шаг 2: вывод был без скобок и без cgroupDriver (значение «текстом») → полный pretty-вывод jq с `"cgroupDriver": "systemd"` (в старой части cgroupDriver: systemd отмечен как проверенный; значения — из прогона 2026-10-14).
- Работа 4: шаг 3 и уборка использовали `lab-worker` жёстко → `$NODE` (как в старой версии; работает при другом узле postgres-0).
- Таблица хронологии §5: код в ячейках не первого столбца → обычные слова.
- Строки вывода >100 знаков (симлинк лога, crictl ps) → перенос/сокращение колонок с «…».
- Работа 1 разбор: «маршрутов via столько… три» уточнено: маршруты к подсетям других узлов (строка default via не считается).

## Читаемость
До: средняя 9,6 слова, коротких 53 %, нарушений 12 (код в ячейках 5, абзацы >5 предложений 3, строки кода 3, предложение >25 слов 1).
После: средняя 11,7, коротких 39 %, нарушений 0. Сшиты рубленые предложения об одной мысли, разбиты абзацы 6 предложений (taint/toleration, PLEG, подготовка), «Дальше» переписан как абзац о причине следования, а не перечень тем.

## Подтверждено (источник)
- node-monitor-grace-period 50s, node-monitor-period 5s — kube-controller-manager reference (website).
- failCgroupV1 по умолчанию true с 1.35, обход false, удаление обхода 1.38, ядро 5.8/5.9, containerd 2.0+ для автоопределения драйвера, stat → cgroup2fs, kubeadm SystemVerification ошибка — blog 2026/kubernetes-cgroups-v2-shift.md; docs/concepts/architecture/cgroups.md.
- containerd: 1.36 → 2.3.0+, 2.2.0+; 1.35 → 2.2/2.1.5/1.7.28; 2.3 LTS 2026-04-30…2028-04-30; config v3=2.0, v4=2.3; migrate — containerd RELEASES.md.
- KubeletCgroupDriverFromCRI: alpha 1.28, beta 1.31, stable 1.34; containerd 2.0+, CRI-O 1.28+ — feature-gates/KubeletCgroupDriverFromCRI.md.
- Сокет /run/containerd/containerd.sock, SystemdCgroup = true — setup/production-environment/container-runtimes.md.
- Реальный вывод работ 1–4 сверен со старой версией e755ced: совпадает (кроме оформления, см. выше).

## Не подтверждено (для 00-plan)
- Год/версия перехода node-monitor-grace-period 40 → 50 с (в тексте «в старых версиях»; CHANGELOG-1.32 полностью не просмотрен).
- KEP-4781 (1.35): kubelet после перезапуска не сбрасывает Ready подов — только по research, документ KEP не найден.
- Drop-in `--config-dir` stable 1.35, maxParallelImagePulls stable 1.35, nodes/configz (GA 1.36), запрет static pods со ссылками на Secret/ConfigMap в 1.37 — по research, первоисточники не открывались.
- Расхождение источников: feature gate KubeletCgroupDriverFromCRI пишет «fallback уберут в 1.36», container-runtimes.md — «планируется в 1.38»; в тексте нейтрально «запасной вариант для старых рантаймов».
- PLEG: relist 1 с, порог 3 мин — по памяти (код pleg/generic.go не открывался).
- Ubuntu 21.10+ и Manjaro по умолчанию на cgroup v2 — по памяти.
- Работа 1 шаг 3: вывод `get nodes -o custom-columns` — ожидаемый; работа 2 шаг 1: дерево cgroup снято на узле, вероятно, не lab-worker; работа 4 шаг 1 и `crictl ps --name postgres` — ожидаемые.
- Раздел «Требования к узлу»: команда `stat -fc %T /sys/fs/cgroup/` в лабах не прогонялась, вывод `cgroup2fs` — по документации.
