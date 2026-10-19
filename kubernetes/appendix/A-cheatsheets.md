# Приложение A. Шпаргалки

> По одной «странице» на инструмент — только то, что нужно в работе и на собеседовании. Версии: kubectl 1.36, Helm 4.2, Kustomize 5.8, kind 0.32, Argo CD 3.5, crictl из kindest/node 1.36.

---

## A.1. kubectl — навигация и чтение

```bash
kubectl config get-contexts; kubectl config use-context kind-lab
kubectl config set-context --current --namespace=orders        # ns по умолчанию
kubectl get pods -o wide --show-labels                         # узел, IP, метки
kubectl get pods -A --field-selector=status.phase!=Running     # всё, что не Running
kubectl get pods -l app=orders-api -w                          # наблюдать
kubectl get deploy orders-api -o yaml | less                   # полный объект
kubectl get pod p -o jsonpath='{.status.containerStatuses[0].lastState}'
kubectl get pods -o custom-columns=NAME:.metadata.name,NODE:.spec.nodeName,RESTARTS:.status.containerStatuses[0].restartCount
kubectl get events --sort-by=.lastTimestamp | tail -20
kubectl get events --field-selector involvedObject.name=p,reason=FailedScheduling
kubectl describe pod p                                         # события внизу
kubectl explain deploy.spec.strategy.rollingUpdate --recursive # документация поля
kubectl api-resources --namespaced=false                       # кластерные типы
kubectl top pods --containers; kubectl top nodes               # нужен metrics-server
```

## A.2. kubectl — изменения

```bash
kubectl apply -f x.yaml --server-side                          # SSA, managedFields
kubectl diff -f x.yaml                                         # что изменится
kubectl apply -f x.yaml --dry-run=server                       # проверка admission без записи
kubectl create deploy d --image=busybox:1.37 --dry-run=client -o yaml -- sleep 3600 > d.yaml
kubectl set image deploy/orders-api api=localhost:5001/orders-api:2.1
kubectl set resources deploy/orders-api --requests=cpu=100m,memory=128Mi
kubectl scale deploy/orders-api --replicas=4
kubectl rollout status|history|undo|restart deploy/orders-api
kubectl patch svc s -p '{"spec":{"selector":{"app":"x"}}}'     # merge patch
kubectl patch svc s --type=json -p '[{"op":"replace","path":"/spec/ports/0/targetPort","value":"http"}]'
kubectl label ns orders pod-security.kubernetes.io/enforce=restricted --dry-run=server
kubectl taint node n key=val:NoSchedule  /  kubectl taint node n key=val:NoSchedule-
kubectl cordon|uncordon n; kubectl drain n --ignore-daemonsets --delete-emptydir-data --timeout=5m
kubectl delete pod p --grace-period=0 --force                  # только если узел точно мёртв
```

## A.3. kubectl — внутрь

```bash
kubectl logs p [-c c] [--previous] [--since=10m] [-f]; kubectl logs -l app=orders-api --prefix --tail=20
kubectl exec -it p -- sh
kubectl debug -it p --image=busybox:1.37 --target=api          # эфемерный контейнер рядом
kubectl debug p --copy-to=p-dbg --container=api -- sleep 3600  # копия с другой командой
kubectl debug node/lab-worker -it --image=busybox:1.37         # узел: /host
kubectl port-forward svc/orders-api 8000:80
kubectl run t --rm -it --image=busybox:1.37 --restart=Never -- wget -qO- -T 3 http://orders-api.orders/api/orders
kubectl get --raw '/readyz?verbose'; kubectl get --raw /metrics | grep apiserver_requested_deprecated_apis
kubectl auth can-i create deploy -n orders                     # мои права
```

## A.4. Диагностика по STATUS

| STATUS | Смотреть |
|---|---|
| Pending (без узла) | `FailedScheduling` целиком; нет событий — scheduler |
| ContainerCreating долго | события пода: `FailedMount`, `FailedCreatePodSandBox` |
| ImagePullBackOff | `state.waiting.message`: not found / 401 / 429 / DNS |
| CreateContainerConfigError | нет ConfigMap/Secret/ключа |
| CrashLoopBackOff / Error | `logs` (`--previous`), `lastState.exitCode` |
| OOMKilled 137 | лимит памяти, событий нет |
| RunContainerError / StartError 128 | бинарника/команды нет |
| Running 0/1 | `Unhealthy` — readiness |
| Terminating долго | grace, finalizers, узел недоступен |
| Evicted | `status.message`: давление узла или ephemeral-storage |

## A.5. Helm 4

```bash
helm repo add bitnami https://charts.bitnami.com/bitnami && helm repo update
helm search repo postgresql --versions | head
helm pull oci://registry-1.docker.io/bitnamicharts/postgresql --version X   # OCI
helm show values chart > values.yaml
helm template rel ./chart -f values.yaml | kubeconform -strict              # рендер + проверка
helm lint ./chart
helm upgrade --install rel ./chart -n ns --create-namespace -f values.yaml --wait --timeout 5m --rollback-on-failure
helm list -A; helm history rel; helm get values rel; helm get manifest rel
helm rollback rel 3
helm uninstall rel                                              # PVC StatefulSet остаются
```

`another operation is in progress` → `helm history` → `helm rollback rel <последняя deployed>`.

## A.6. Kustomize

```yaml
# overlays/prod/kustomization.yaml
resources: [../../base]
namespace: orders
images: [{name: orders-api, newName: localhost:5001/orders-api, newTag: "2.1"}]
replicas: [{name: orders-api, count: 4}]
patches: [{path: resources.yaml}]
configMapGenerator: [{name: orders-config, literals: [MODE=prod]}]   # хэш в имени → rollout
```

```bash
kubectl kustomize overlays/prod | less
kubectl apply -k overlays/prod --server-side
kubectl diff -k overlays/prod
```

## A.7. Argo CD

```bash
argocd login <host> --sso|--username admin
argocd app list; argocd app get orders --refresh
argocd app diff orders; argocd app sync orders [--prune]
argocd app history orders; argocd app rollback orders <id>     # при auto-sync перезапишется — откат через git revert
kubectl -n argocd get applications -o wide
```

Аннотации: `argocd.argoproj.io/sync-wave: "1"`, `argocd.argoproj.io/hook: PreSync`, `argocd.argoproj.io/sync-options: Prune=false`.

## A.8. Узел: crictl, journalctl, systemctl (в kind — `docker exec <узел> …`)

```bash
crictl ps -a [--name api]; crictl pods; crictl images
crictl logs [--tail=50] <id>; crictl inspect <id> | less
crictl rmi --prune                      # образы kind load удаляются только по имени
journalctl -u kubelet --since -10min --no-pager | grep -iE 'error|fail'
journalctl -u containerd --since -10min --no-pager
systemctl status kubelet containerd
cat /var/lib/kubelet/config.yaml        # evictionHard, cgroupDriver, …
ls /etc/kubernetes/manifests            # static pods control plane
df -h /var/lib/containerd /var/lib/kubelet; du -sh /var/log/pods/* | sort -h | tail
```

## A.9. Control plane и etcd

```bash
kubectl get --raw '/livez?verbose'; kubectl get --raw /livez/etcd
kubectl -n kube-system get lease kube-scheduler kube-controller-manager
E="kubectl -n kube-system exec etcd-lab-control-plane -- etcdctl --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/healthcheck-client.crt \
  --key=/etc/kubernetes/pki/etcd/healthcheck-client.key"
$E endpoint status -w table; $E endpoint health; $E alarm list
kubeadm certs check-expiration; kubeadm certs renew all        # затем перезапустить static pods
kubeadm upgrade plan; kubeadm upgrade apply v1.36.5            # на первом control-plane
```

## A.10. kind

```bash
kind get clusters; kind get nodes --name lab
kind load docker-image localhost:5001/orders-api:2.1 --name lab
kind export kubeconfig --name lab
docker exec -it lab-worker bash                                # «зайти на узел»
bash kubernetes/lab/lab-up.sh | lab-down.sh [--purge]          # стенд курса (приложение C)
```

## A.11. Числа, которые спрашивают

| Что | Значение |
|---|---|
| NotReady узла | 50 с (`node-monitor-grace-period`, с 1.32; раньше 40 с) |
| Эвикция с недоступного узла | 300 с (`tolerationSeconds`) |
| Back-off рестартов | 10 с → … → 5 мин, сброс после 10 мин работы |
| `terminationGracePeriodSeconds` | 30 с |
| `maxSurge`/`maxUnavailable` | 25 %/25 % |
| `progressDeadlineSeconds` | 600 с |
| `revisionHistoryLimit` | 10 |
| Job `backoffLimit` | 6 |
| HPA: цикл / окно уменьшения | 15 с / 300 с |
| NodePort | 30000–32767 |
| Подов на узел | 110 |
| ConfigMap/Secret | ≤ 1 МиБ |
| Квота etcd | 2 ГиБ |
| Таймаут вебхука | 10 с по умолчанию, ≤ 30 с |
| Сертификаты kubeadm / CA | 1 год / 10 лет |
| Skew kubelet / kubectl | до −3 минора / ±1 |
| DNS | `ndots:5`, таймаут резолвера 5 с |
| Envoy Gateway | connect timeout 10 с, таймаут маршрута 15 с (наблюдалось на стенде, 11-2) |
