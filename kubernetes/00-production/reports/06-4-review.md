# Ревью 06-4 «Аудит и политика образов»

Файл: kubernetes/06-access-security/06-4-audit-image-policy.md. Часть новая, старой версии нет; все три работы помечены «выполняете сами». Режим «только текст»: ничего не запускалось, сверка по документации (WebFetch raw).

## Найденные ошибки (было → стало)

- §3 «Что писать и что нет», §6: умолчания ротации не названы, отсылка к `--help` → названы: `--audit-log-maxsize` 100 МБ, `--audit-log-maxbackup` 100, `--audit-log-maxage` 366 дней (до ~10 ГБ), поэтому флаги задают явно.
- §3 «Политика образов через admission»: аннотация Audit без ключа → `validation.policy.admission.k8s.io/validation_failure`; добавлено, что `Deny` и `Warn` вместе не задают.
- Лаба 1, шаг 4, ожидаемый вывод `grep audit`: имена томов по одному разу → по два раза (`volumeMounts` контейнера, отступ 6, и `volumes` пода, отступ 4); разбор поправлен, добавлено «kubeadm пишет флаги по алфавиту».
- Лаба 1, шаг 2: «если kind ругнётся, сверьтесь с документацией» → объяснено: kind 0.32 сам генерирует v1beta4 для узлов 1.36+, патч со словарём `extraArgs` не применится; список `extraArgs` патча может заменить список kind (там только `runtime-config` с пустым значением) — для работы безвредно. В таблице: hostPath относительный — «запускайте kind из этого каталога».
- Лаба 2, шаг 1: политика не проверяла эфемерные контейнеры, хотя теория этого требует → добавлены `pods/ephemeralcontainers` в `resourceRules` и `ephemeralContainers` в переменную `images` (та же форма `has() ? map : []`); строка в таблице разбора.
- Лаба 2, шаг 3, вывод: «created (dry run)» → «created (server dry run)» (как печатает kubectl и как в шаге 2); выровнена первая строка под `printf "%-45s"`.
- Лабы 2 и 3, «Что понадобится»: образ `localhost:5001/busybox:1.37` есть в реестре только после необязательных команд 02-1 → ссылка на вступление к лабораторным 02-1 (путь `localhost:5001/busybox:1.37` совпадает с 02-1).
- §3 imagePullPolicy: KubeletEnsureSecretPulledImages — добавлено «включена по умолчанию» (research: beta on 1.35).
- §1 «Что остаётся за пределами части»: по research-coverage (Falco — «в 06-4 абзац») добавлена фраза о runtime-детекте, отнесённом к курсу `security`.

## Читаемость

До: 292 предложения, средняя длина 11,8 слова, 37% коротких, 1 нарушение (26 слов в «Дальше»).
После: 301 предложение, средняя 11,7, 38% коротких, 0 нарушений. «Дальше» разбит на три предложения; два новых длинных предложения (KubeletEnsureSecretPulledImages, v1beta4) разделены. Строки кода ≤ 100 символов. Эмодзи нет (символы ✓ в выводе kind оставлены как вывод программы).

## Подтверждено (источник)

- kind: `kubeadm/config.go` (main) — v1beta4 для k8s ≥ 1.36, `extraArgs` списком name/value, по умолчанию только `runtime-config` (+`feature-gates`); `patch/resource.go` — патч совпадает по kind, apiVersion сверяется, если указан; применяется JSON merge patch. kind auditing.md — extraMounts `./audit-policy.yaml`, extraVolumes audit-policies/audit-logs с теми же полями. research: kind 0.32 — k8s 1.36.1, патчи v1beta4.
- kube-apiserver reference и `apiserver/pkg/server/options/audit.go`: maxage 366, maxbackup 100, maxsize 100; log mode blocking; webhook mode batch, буфер 10000, пачка 400, 30 с, QPS 10, burst 15, initial backoff 10s; формат JSON.
- images.md: значения imagePullCredentialsVerificationPolicy, умолчание NeverVerifyPreloadedImages, allowlist; правила умолчания imagePullPolicy (дайджест → IfNotPresent, latest/без тега → Always).
- VAP docs: Deny/Warn/Audit, запрет Deny+Warn.
- cosign: релиз v2.5.3 существует (17 июл 2025); ассеты `cosign-linux-amd64`, `cosign_checksums.txt`; `--tlog-upload` (default true), `--insecure-ignore-tlog` (bool), `--yes`, `--key`, `--allow-insecure-registry` — по doc/cosign_sign.md и cosign_verify.md v2.5.3.
- Стенд: реестр `kind-registry` (registry:2.8.3), путь хранения `/var/lib/registry/docker/registry/v2/repositories`; образ узла `kindest/node:v1.36.1`.
- Политика аудита: стадии, уровни, `omitStages`, `omitManagedFields`, первое совпавшее правило, подресурсы `pods/exec` отдельно, Request/RequestResponse не для нерессурсных URL, политика без правил недопустима, `blocking-strict` — по audit.md (по знанию, совпадает с кодом).

## Не подтверждено (для 00-plan §7)

- Патч kind v1beta4 с `extraArgs` списком и замена списка kind — по коду kind, живым созданием кластера не проверено.
- Порядок и отступы строк `grep audit` в манифесте kube-apiserver — по устройству генератора kubeadm.
- Вывод `kind create cluster` (без эмодзи) — ожидаемый.
- Вывод jq лабы 1 (`as:null`, 403, `kubernetes-admin`, уровни событий Secret/Pod) — ожидаемый.
- CEL: тернарный `has(...) ? list.map(...) : []` и сложение трёх списков — проверка типов в 1.36 не выполнена.
- Текст Warning VAP («Validation failed for ValidatingAdmissionPolicy '…' with binding '…'») и отказа Forbidden — по памяти о коде, не по документации.
- Задержка вступления политики в силу (~3 с) — оценка.
- Kyverno ClusterPolicy (spec.validationFailureAction, attestors.entries.keys.publicKeys) — kyverno.io недоступен; оставлено как принцип с оговоркой о версиях; возможно, поле устарело в пользу failureAction в правиле и ресурса ImageValidatingPolicy.
- `COSIGN_PASSWORD=''` как пустой пароль и права 0600/0644 ключей — по знанию кода cosign.
- Вывод `cosign verify` (тексты проверок, `docker-reference`), `no signatures found` после подмены тега, тег `sha256-<hex>.sig` в registry:2.8.3 — ожидаемые для v2 (в cosign v3 по умолчанию другой формат хранения подписей; закреплён v2.5.3).
- Доступность GitHub Releases из РФ.
