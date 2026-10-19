# Ревью 05-1 «CPU, память и QoS»

Файл: /home/user/claude/kubernetes/05-resources-scheduling/05-1-cpu-memory-qos.md. Режим «только текст»: читались файлы, `git show`, документация (raw.githubusercontent.com); правки скриптом из scratchpad. Коммита нет.

## Найденные ошибки (было → стало)

1. oom_score_adj Burstable: «от 2 до 999» (таблица §2, §6) → «от 3 до 999». В коде kubelet (pkg/kubelet/qos/policy.go) нижняя граница `1000 + guaranteedOOMScoreAdj` = 3; в документации (node-pressure-eviction) написано max(2, …). В §2 добавлена фраза о расхождении.
2. Memory QoS §6: «memory.high чуть ниже limit; множитель по умолчанию 0,9; включённой по умолчанию станет в 1.37» → формула `request + factor × (limit − request)`; 0,9 — умолчание именно 1.36 (kubelet-config.v1beta1, release-1.36). В 1.37 гейт beta и включён, но `memoryThrottlingFactor` по умолчанию nil, `memoryReservationPolicy` по умолчанию None, то есть без настройки файлы не меняются. TieredReservation: Guaranteed → memory.min, Burstable → memory.low.
3. PSI §4: «строка full только в memory и io» → full есть и в `cpu.pressure` cgroup (ядро 5.13+, docs.kernel.org psi.rst). Добавлены требования (ядро 4.20+, CONFIG_PSI=y, `psi=1`), значение `total` (мкс), стадии KubeletPSI (alpha 1.33, beta 1.34, GA 1.36), где метрики (Summary API, `/metrics/cadvisor`, пример `container_pressure_cpu_waiting_seconds_total`).
4. Лаба 3 шаг 4 дублировала 05-2 (лабораторная 1 шаг 2: тот же patch cpu-limited → 500m и та же проверка restarts/spec/status). Проверка restarts/spec/status убрана (вывод `restarts=0 spec=500m status=500m` удалён), осталась одна команда resize со ссылкой «05-2, лабораторная работа 1, шаг 2» и `cat cpu.max`. Строка «Итог» «Лимит можно поднять на месте» заменена на «Квота 500m — 50000 100000».
5. Лаба 1 шаг 4: в выводе не было строк `pod/big created`, `pod/greedy created`, хотя писатель заменил `kubectl run` на `apply`: строки добавлены (детерминированный вывод apply).
6. memory.oom.group: добавлено «с версии 1.32» (KEP singleProcessOOMKill; в старой части то же).
7. Go 1.25: уточнено «лимит, но не request; если GOMAXPROCS не задан вручную» (golang/website doc/go1.25.md).
8. runc в узле kind: добавлено, что образ узла сам собирает runc и кладёт в `/usr/local/sbin/runc` (kind images/base/Dockerfile; в main runc v1.4.3, containerd v2.3.4), поэтому `docker exec lab-worker runc --version` работает.
9. Уборка лабы 3: добавлено удаление локального тега `localhost:5001/lab-05-1/python:3.12-slim`, если читатель клал образ в реестр.

## Читаемость

До: 273 предложения, средняя 12,6 слова, коротких (<10) 31 %, >25 слов — 0, нарушений 0.
После: 281 предложение, средняя 12,7 слова, коротких 30 %, >25 слов — 0, нарушений 0. Два длинных предложения, появившихся после правок (PSI, Memory QoS 1.37), разделены. Строки кода ≤100 знаков (проверено подсчётом символов). Эмодзи, «Проверено», вопросов собеседования, чеклистов нет; блоки §3 по порядку; после каждого `##` есть фраза.

## Подтверждено (источник)

- Формулы cpu.weight: старая `1 + ((shares−2)·9999)/262142`, новая `ceil(10^((L²+125L)/612 − 7/34))`, L = log2(shares) — opencontainers/cgroups utils.go ConvertCPUSharesToCgroupV2Value и блог k8s 2026/new-cgroup-v1-to-v2-conversion-formula (runc 1.3.2+, crun 1.23+). Ручной расчёт: 500m (512) → 20/59, 250m (256) → 10/35, 1 CPU (1024) → 39/≈100 (блог пишет 102), 100m (102) → 4/17, без request (2) → 1/1; 90–109m → 17 (блог).
- shares: MinShares 2, 1024 на ядро — pkg/kubelet/cm/helpers_linux.go.
- Квота CPU и память на cgroup пода ставятся у Burstable, только если лимит задан у всех контейнеров (или задан лимит уровня пода); у Guaranteed всегда — helpers_linux.go ResourceConfigForPod.
- oom_score_adj −997 / 1000, формула Burstable, 999 вместо 1000 — policy.go; 992 и 996 — старая часть (стенд).
- singleProcessOOMKill — kubelet-config.v1beta1 (release-1.36).
- CPU Manager опции: full-pcpus-only GA 1.33, strict-cpu-reservation GA 1.35, prefer-align-cpus-by-uncorecache GA 1.36 — cpu-management-policies.md (release-1.36). Memory Manager GA 1.32 — feature gate MemoryManager. Несовместимость static-политик с resize — resize-container-resources.md.
- MemoryQoS alpha 1.22–1.36, beta 1.37; PodLevelResources beta 1.34 — feature gates; правила QoS для ресурсов уровня пода — pod-qos.md.
- request подставляется равным limit — manage-resources-containers.md.
- Все строки вывода лабораторных совпадают со старой частью (прогон 2026-10-14), кроме добавленных строк apply (п. 5) и перекомпоновки длинных строк.
- Перекрёстные ссылки 01-2 §4/§6, 02-1 §2/§4/§6, 05-2…05-5, 11-4 существуют.

## Не подтверждено (для 00-plan)

- Вывод `runc --version` в узле kind не снимался (версия runc в образе kindest/node v1.36.1 не сверена; по Dockerfile main — v1.4.3).
- Вес одного ядра по новой формуле: блог — 102, расчёт по коду — около 100 (в тексте «около 100»).
- Расхождение нижней границы oom_score_adj Burstable: код 3, документация 2.
- JVM: MaxRAMPercentage по умолчанию 25 %, -XX:ActiveProcessorCount, учёт cgroup с JDK 10 — по общим знаниям, документация OpenJDK не сверялась; Node.js --max-old-space-size — не сверялось.
- Окно kubectl top ~15 с (metric-resolution metrics-server) — по старой части.
- Распределение учёта троттлинга между cgroup пода и контейнера (19 против 2 периодов) — замер на ядре 6.18, механизм в документации ядра не найден.
- Лаба 1 шаг 2 (сборка команды через R) и шаг 4 (apply вместо kubectl run) в новой форме не прогонялись; вывод из старой части.
- Порядок строк ctr (основной контейнер, затем pause) в лабе 3 шаг 3 зависит от ID контейнеров.
