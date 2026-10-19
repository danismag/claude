Сомнительные места 01-3:
- Ожидаемые строки: `deployment.apps/api2 serverside-applied`, вывод create deployment/rollout status, status.replicas=4, `No resources found in lab-01-3 namespace.`; ownerReferences пода (другой jsonpath).
- AGE=1s в выводе orphan (скопировано).
- 24 группы API и `kubectl get --raw /apis | jq '.groups | length'` (jq у читателя может не быть).
- managedFields сокращены.
- Нужен ли --force-conflicts при переходе с CSA на SSA.
- Deprecation policy (beta 9 мес/3 релиза; GA не удаляется) — kubernetes.io недоступен, писатель не сверил.
- Лимиты меток 63/253/63, аннотации 256 КиБ, etcd 1,5 МиБ — по памяти.
- Финализатор kubernetes у namespace в spec.finalizers; status.conditions.
- Учесть исследование: KYAML в kubectl, Pod observedGeneration GA 1.35, удалённые/устаревшие API в 1.33–1.36 (v1 Endpoints устарел).
