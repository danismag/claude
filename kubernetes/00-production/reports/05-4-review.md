# Ревью 05-4 «Автомасштабирование»

Файл: /home/user/claude/kubernetes/05-resources-scheduling/05-4-autoscaling.md. Старая версия: e755ced:kubernetes/05-resources-scheduling/05-3-autoscaling.md.

## Найденные ошибки (было → стало)

1. Рост HPA по умолчанию. Было: «не больше +4 пода или +100 % за 15 с», и этим объяснялось 1 → 4 (по такому правилу вышло бы 1 → 5). По коду (horizontal.go: при `spec.behavior == nil` работает normalizeDesiredReplicas, предел max(2 × current, 4); defaults.go v2 заполняет behavior только если он задан) без `behavior` рост ограничен max(2 × текущее, 4) реплик за цикл. Стало: это объяснение в §5, §6, разборе ЛР2 шаг 3 (пп. 2, 3), Итоге ЛР2 и ответе 1 ЛР2; правило «+4 пода или +100 % за 15 с» оставлено для HPA с заданным `behavior`.
2. Арифметика ЛР2: 21 = ceil(1 × 1003 / 50) — верно; «≈ 81» → ceil(4 × 1004 / 50) = 81; разрешено max(2 × 4, 4) = 8 — совпадает со старым выводом. 86 с = 239 − 153 — верно. «354 с = 300 с окна и два цикла HPA» → «300 с окна плюс задержка метрик и циклы HPA» (54 с не равны двум циклам).
3. Правило инициализации CPU. Было: «первые 5 минут CPU неготового пода вообще не учитывается». Стало по документации HPA: в первые 5 минут CPU учитывается, только если под готов и замер сделан целиком в готовом состоянии; в §6 добавлен флаг `--horizontal-pod-autoscaler-initial-readiness-delay` (30 с).
4. Задержка метрик: убрано неподтверждённое «kubelet обновляет статистику раз в 15 с»; реакция объяснена разрешением metrics-server 15 с + цикл HPA 15 с, с ссылкой на замер 27 с.
5. HPAScaleToZero: уточнено — гейт существует с 1.16 (alpha, выключен), в 1.37 beta и включён; нужен на kube-apiserver и kube-controller-manager. (Исследование ошибочно называет «alpha 1.36».)
6. Допуск в §6: «на поле tolerance с 1.33 alpha» → «alpha с 1.33, beta и включено с 1.35».
7. KEDA, версии: CVE-2026-77524 СУЩЕСТВУЕТ (GHSA-637c-6jxx-4rwm, Critical, CVSS 9.9, затронуты ≤ 2.20.2, исправлено в 2.21.0: явная аудитория токенов ServiceAccount в TriggerAuthentication) — оставлено, формулировка уточнена. 2.20: «операторам нужны права» → права create/patch на events.k8s.io уже в чарте, добавлять нужно только при своих RBAC. Фраза «KEDA 2.18 вышла из поддержки 1 июня 2026» убрана — не подтверждена (endoflife.date недоступен).
8. VPA: минимум рекомендации уточнён «на под» и названы флаги `--pod-recommendation-min-cpu-millicores` (25) и `--pod-recommendation-min-memory-mb` (250). Updater: «применяет новые» → «вытесняет или меняет на месте».
9. Karpenter: «умеет вытеснять поды ради экономии… NodeOverlay (опциональная функция)» → термин «консолидация» и NodeOverlay — alpha с Karpenter 1.7, выключен по умолчанию.
10. CA: «время нового узла 1–3 минуты — ориентир документации» → без числа (источник не найден); верхняя граница ожидания — `--max-node-provision-time` 15 мин уже есть. «Версия CA совпадает с минорной» → «берут ту же минорную версию».
11. PDB: «с одной репликой блокирует навсегда» → PDB без допустимых прерываний (`maxUnavailable: 0` или `minAvailable: 1` при одной реплике) блокирует, пока его не изменят.
12. ЛР3: убран вводный абзац с меткой «результат шага 2 — реальный, в шагах 1 и 3 ожидаемые» (метка проверки и блок перед «Рисками»); сведения о скачивании с ghcr.io перенесены в «Что понадобится». Из Итога ЛР3 убрана строка про HPA scale-to-zero (опыт её не показывает).
13. Вводный абзац лабораторных: добавлено, что запасной образ меняет локальный Docker хоста.

## Читаемость

До: 241 предложение, средняя 11,2 слова, коротких 39 %, нарушений 0. После: 234 предложения, средняя 11,7, коротких 38 %, нарушений 0. Сшиты рубленые предложения (§1 «Обратная связь», §5 «Узлы не добавляются», §3 «Допустимы две пары», подпись схемы 6); разделено одно длинное (Karpenter). Эмодзи, «Проверено», вопросов собеседования, чеклистов нет; блоки §3 по порядку; лабораторные по §3.2; «Риски» в ЛР3; строки кода ≤ 100.

## Подтверждено (источник)

- HPAConfigurableTolerance: alpha 1.33 (off), beta 1.35 (on), GA 1.37 — kube_features.go (master).
- HPAScaleToZero: alpha 1.16 (off), beta 1.37 (on) — kube_features.go; minReplicas: 0 только при Object/External — api autoscaling/v2 types.go.
- Период 15 с, допуск 10 % и флаг, 0 %/100 % для подов без метрик, cpu-initialization-period 5 мин, initial-readiness-delay 30 с, окно scaleDown 300 с, падение 100 %/15 с, behavior-политики 4 пода/100 %/15 с — docs horizontal-pod-autoscale.md.
- Предел без behavior max(2 × current, 4) — horizontal.go (scaleUpLimitFactor 2.0, scaleUpLimitMinimum 4.0); defaults.go v2.
- Условия AbleToScale/ScalingActive/ScalingLimited, tolerance «по умолчанию 10 %», minReplicas по умолчанию 1 — types.go.
- CA: threshold 0.5, unneeded-time 10m, scan-interval 10s, max-node-provision-time 15m, ConfigMap cluster-autoscaler-status в kube-system, события TriggeredScaleUp/ScaleDown, блокирующие поды, safe-to-evict, утилизация по requests — cluster-autoscaler/FAQ.md.
- Karpenter: karpenter.sh/do-not-disrupt (под и узел), консолидация, consolidateAfter, PDB — docs disruption.md (karpenter-provider-aws); NodeOverlay alpha 1.7, off — settings.md.
- VPA 1.6.0 (12 февраля): InPlaceOrRecreate GA и включён (#9082), Auto устарел с 1.5 (#9073) — страница релиза; минимумы 25 / 250 — vertical-pod-autoscaler/docs/flags.md.
- KEDA: pollingInterval 30, cooldownPeriod 300 (только для перехода в 0), minReplicaCount 0, maxReplicaCount 100 — keda-docs 2.21 scaledobject-spec.md; 2.20 events.k8s.io — релиз v2.20.0; CVE-2026-77524 — GHSA-637c-6jxx-4rwm и релиз v2.21.0.
- Реальный вывод ЛР1 ш1–2, ЛР2 ш3–4, ЛР3 ш2 совпадает со старой частью.

## Не подтверждено (для 00-plan)

- metrics.k8s.io v1 GA в 1.37 (KEP-5207) — только по исследованию.
- Год релиза VPA 1.6.0 (2026) — по исследованию; страница релиза года не показывает.
- Минимум памяти VPA в МиБ (флаг называется «mb»).
- ЛР1 шаг 3 — ожидаемый результат (TARGETS с числом).
- ЛР2 шаг 1 — стандартное сообщение rollout status; шаг 2 — функции переписаны с переносами, не запускались.
- ЛР3 шаги 1 и 3 — ожидаемый вывод (wait condition met, custom-columns с OWNER ScaledObject).
- Поле tolerance в behavior на стенде 1.36 не проверялось.
- Kubernetes-гейт HPAScaleToZero и сравнение с KEDA — без опыта на стенде.
- CA и Karpenter — только теория, на стенде не проверялись.
