# Приложение B. Manjaro vs Ubuntu для курса Kubernetes

> Курс даёт команды в форме Ubuntu. Стенд — контейнеры Docker (kind), поэтому от дистрибутива зависят только клиентские инструменты и настройки хоста. Версии Manjaro проверены `LANG=C pacman -Si` на машине автора (репозиторий extra, октябрь 2026). Для Ubuntu 24.04 — способы установки по документации проектов. ⚠️ Установка на Ubuntu в среде агента не проверялась.

---

## B.1. Клиентские инструменты

| Инструмент | 🐧 Ubuntu 24.04 | 🅼 Manjaro (extra) | Комментарий |
|---|---|---|---|
| Docker | `docker.io` или `docker-ce` (репозиторий Docker) | `docker` 29.7.2 | стенд проверен на Docker 29 |
| kind | нет в apt — бинарник `kind.sigs.k8s.io/dl/v0.32.0/kind-linux-amd64` (00-1 §2) | `kind` 0.32.0 | версия kind определяет образ узла по умолчанию; курс фиксирует `kindest/node:v1.36.1` в `lab-up.sh` |
| kubectl | репозиторий `pkgs.k8s.io/core:/stable:/v1.36/deb/` (00-1 §2) | `kubectl` 1.36.4 | skew ±1 минор от кластера (1.35–1.37) |
| helm | бинарник `get.helm.sh/helm-v4.2.2-linux-amd64.tar.gz` или репозиторий Helm | `helm` 4.2.2 | **Helm 4**: `--rollback-on-failure` вместо `--atomic`, SSA по умолчанию (07-1). Рецепты для Helm 3 из интернета сверяйте |
| kustomize | встроен в `kubectl -k`; отдельный бинарник — релиз GitHub | `kustomize` 5.8.1 | в курсе достаточно `kubectl kustomize` |
| k9s | `.deb` с GitHub-релизов | `k9s` 0.51.0 | ⚠️ не запускался в среде агента |
| stern | бинарник с GitHub или `kubectl krew install stern` | `stern` 1.34.0 | ⚠️ не устанавливался |
| kubectx/kubens | бинарник с GitHub или `krew install ctx ns` | `kubectx` 0.11.0 | ⚠️ не устанавливался |
| krew | по инструкции krew.sigs.k8s.io | `krew` 0.5.0 | ⚠️ не устанавливался |
| cilium-cli | релиз GitHub | `cilium-cli` 0.19.4 | в курсе не нужен (CNI — kindnet) |
| argocd CLI | релиз GitHub | `argocd` 3.4.2 | в лабах 08 сервер v3.5.5; CLI на минор старше/младше работает, но лабы шли через `kubectl` |
| etcdctl, crictl | не ставятся на хост | не ставятся на хост | есть внутри узлов kind и пода etcd (A.8, A.9) |

## B.2. Хост и ядро

| Тема | 🐧 Ubuntu | 🅼 Manjaro |
|---|---|---|
| inotify | `fs.inotify.max_user_instances` часто 128 — 4 узла kind падают с `too many open files`, поднять до 512 (00-1 §2) | на машине автора 1024 — ошибок нет |
| cgroup | v2 (с 22.04) | v2 |
| AppArmor | включён; kind работает с профилем Docker по умолчанию | обычно выключен |
| ufw/firewalld | ufw может мешать трафику между контейнерами docker-сети kind только при нестандартных правилах; порты стенда опубликованы на `127.0.0.1` | firewalld/ufw по выбору |
| `*.localhost` | systemd-resolved резолвит `*.localhost` в 127.0.0.1 | на машине автора `getent hosts orders.localhost` → `::1` (через `resolve`/`myhostname` в nsswitch, проверено); curl резолвит `*.localhost` сам. Если Envoy слушает только IPv4 — используйте `curl -4` или `127.0.0.1` с `-H Host:` |
| порт 8088 | свободен на чистой системе | на машине автора 8080 занят (searxng) — поэтому стенд на 8088 |
| место | корневой раздел с `/var/lib/docker` — нужно ≥ 15 ГБ свободно | то же; при < 10 % свободного обычный kubelet ушёл бы в DiskPressure, kind пороги отключает (11-3) |
| `~/.docker/config.json` с `credsStore` | бывает после Docker Desktop | бывает | `error getting credentials` → `DOCKER_CONFIG=$(mktemp -d)` для команд стенда |

## B.3. Пути

| Что | 🐧 Ubuntu | 🅼 Manjaro |
|---|---|---|
| kubeconfig | `~/.kube/config` | то же |
| файлы стенда | `~/lab/k8s` | то же |
| bash completion | `sudo apt install bash-completion`; `kubectl completion bash \| sudo tee /etc/bash_completion.d/kubectl` | `bash-completion` из extra; `/usr/share/bash-completion/completions/` — пакеты kubectl/helm кладут сами |
| zsh | `source <(kubectl completion zsh)` в `~/.zshrc` | то же; Manjaro по умолчанию с zsh |

## B.4. Обновления

- **Manjaro** — rolling: `pacman -Syu` может поднять kubectl/helm на минор вперёд. kubectl 1.37 с кластером 1.36 — в рамках skew. Helm 4.3+ — сверяйте флаги. Зафиксировать: `IgnorePkg = kubectl helm` в `/etc/pacman.conf` на время курса.
- **Ubuntu** — репозиторий `pkgs.k8s.io` привязан к минору (`v1.36`): для перехода на 1.37 поменяйте URL в `/etc/apt/sources.list.d/kubernetes.list`. Helm из бинарника сам не обновляется.
