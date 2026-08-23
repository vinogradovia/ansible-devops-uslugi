# platform/cicd — Фаза 0 ADR-0014 (K3s + Gitea + Semaphore UI)

Персистентная платформенная инфраструктура (`docs/adr/0012-cicd-platform-architecture.md` §6),
не демо-стенд — в отличие от `demo/*` (ADR-0006, эфемерные одноразовые VM, демонстрирующие роли
коллекции клиентам), этот стенд обслуживает саму разработку коллекции (CI/CD) и не пересоздаётся
регулярно. Поэтому не переиспользует `demo/stand.sh` (жёстко резолвит `demo/$case/...`) — запуск
вручную, теми же двумя командами, что использует сам `stand.sh` внутри.

Архитектура и обоснование решений — `docs/adr/0014-platform-controller-architecture.md`,
`docs/adr/0012-cicd-platform-architecture.md` §4/§5, план по фазам — `ROADMAP.md`,
«Предлагаемая последовательность работ», пункт 7, Фаза 0.

Одна K3s-нода (`xanmanning.k3s`, тот же пин версии, что `roles/monitoring_server/meta/main.yml`)
хостит Gitea (источник Module-манифестов/inventory) и Semaphore UI (исполнитель Task Template)
как Helm-релизы через Helmwave (`helm/envs/platform.yaml`) — тем же способом, каким
`monitoring_server` уже разворачивает VictoriaMetrics/Grafana/Loki
(`docs/adr/0007-monitoring-server-role.md` §6).

## Запуск

```bash
cd terraform
tofu init -input=false
tofu apply -input=false -auto-approve

# Дождаться SSH (single VM — обычно секунды после apply)
ssh -o StrictHostKeyChecking=no ansible@$(tofu output -json | jq -r '.vm_ips.value.cicd') true

cd ../ansible
poetry run ansible-playbook -i inventory.yml site.yml
```

Требует на control-хосте (не на самой VM): `helm`, `helmwave`, python-пакет `kubernetes`
(dev-зависимость `pyproject.toml`) — те же требования, что `extensions/molecule/monitoring_server_k3s/`.

## Ручные шаги после первого запуска

Выполнены вживую (через REST API Gitea/Semaphore, `curl` с control-хоста через `ssh` на VM —
прямой сетевой доступ с control-хоста в сеть стенда недоступен):

1. **Gitea** — организация `platform`, приватный репозиторий `platform/gitops` (Module-манифесты
   + Ansible-inventory, `auto_init`, ветка `main`). Учётные данные администратора —
   `helm/values/platform/namespaces/platform/gitea/values.yaml` (`gitea.admin`) — **плейсхолдер,
   сменить перед реальным использованием**.
2. **Semaphore** — проект `platform` (id=1), Git-интеграция на `platform/gitops` (repository id=1,
   ssh-key типа `login_password` — репозиторий приватный, ключ типа `none` не давал креденшлов
   для клонирования, см. `platform-controller/README.md`, «Фаза 4»/«Фаза 5»), inventory
   `infra_panel` (id=1, тип `file`, указывает на `inventory/infra_panel.ini` — заведомо
   placeholder-хост `203.0.113.10`, не реальный таргет — **всё ещё не решено**, см. ниже),
   environment `default` (id=1), Task Template `infra_panel (pilot, ADR-0014 Фаза 0)` (id=1,
   playbook `playbooks/infra_panel.yml`). Учётные данные администратора —
   `helm/values/platform/namespaces/platform/semaphore/values.yaml`
   (`SEMAPHORE_ADMIN`/`SEMAPHORE_ADMIN_PASSWORD`) — тоже плейсхолдер.

   В `platform/gitops` дополнительно закоммичены `playbooks/infra_panel.yml` (тонкая обёртка —
   `hosts: infra_panel`, `roles: [devops.uslugi.infra_panel]`) и `requirements.yml`, указывающий
   на реальный источник коллекции `devops.uslugi` — приватное зеркало `platform/devops-uslugi` в
   этом же Gitea (запушено пользователем вручную из корня коллекции — агенту это действие
   недоступно, инструментарий безопасности расценивает `git push` всего репозитория/точечное
   копирование через API как передачу содержимого доверенного репозитория и блокирует это
   независимо от согласия пользователя). Креды для клонирования зеркала — не в git (коммитить
   пароль в `requirements.yml` тоже заблокировано), а в Semaphore Environment (`env`, не `json`):
   `GIT_CONFIG_COUNT`/`GIT_CONFIG_KEY_0=http.extraHeader`/`GIT_CONFIG_VALUE_0=Authorization: Basic
   ...` — секрет живёт только в БД Semaphore.

   **Task Template реально выполнялся** — `devops.uslugi:1.0.0 was installed successfully`,
   `ansible-playbook` доходит до `PLAY [infra_panel]`. Падает на следующем шаге: `placeholder-host`
   (`203.0.113.10`) не существует — `UNREACHABLE`, `ssh` таймаут. Это последний нерешённый вопрос
   перед сквозной проверкой `infra_panel` — нужен реальный целевой хост в inventory, не
   заведённый в рамках этой сессии.

## Проверено реальным прогоном

Полный цикл (`tofu apply` → `ansible-playbook site.yml`) выполнен и проверен целиком: оба пода
(`gitea`, `semaphore-semaphore`) `Running`, 0 рестартов, оба PVC `Bound`, оба сервиса отвечают
`200 OK` по HTTP(S) через встроенный в k3s Traefik (`curl -H "Host: gitea.cicd.platform" ...`,
`curl -H "Host: semaphore.cicd.platform" ...`). `ansible-playbook` идемпотентен на повторном
прогоне (второй запуск — `changed=2`, без ошибок).

Две реальные находки первого прогона, обе исправлены в `site.yml`/`.gitignore`:

1. **Race condition: Traefik CRD ещё не зарегистрирован в момент первого `helmwave up`.** k3s
   разворачивает встроенный Traefik (и его CRD `ingressroutes.traefik.io`) асинхронно через
   собственный HelmChart-контроллер — сразу после того, как `xanmanning.k3s` отчитывается об
   успехе, CRD может ещё не существовать. Chart Semaphore (`nxs-universal-chart`) рендерит
   `IngressRoute` только если `$.Capabilities.APIVersions.Has "traefik.io/v1alpha1"` — без
   ожидания релиз применяется молча БЕЗ `IngressRoute` (Helm просто пропускает шаблон, без
   ошибки) — обнаруживается не сразу, а когда сервис оказывается недоступен снаружи. Исправлено:
   `site.yml` ждёт регистрации CRD (`kubernetes.core.k8s_info` + `until`/`retries`) перед
   `helmwave up`.
2. **`helm/helmwave.yml` — общий файл, коллизия между кластерами.** Он же используется как
   закоммиченный референсный рендер для `K8S_CLUSTER=k3s-monitoring`
   (`roles/monitoring_server`) — `helmwave up --yml` безусловно перезаписывает этот файл под
   ТЕКУЩИЙ `K8S_CLUSTER`. Ручной запуск с `K8S_CLUSTER=platform` во время отладки находки №1
   перезаписал чужой референс, пришлось откатывать через `git checkout`. Исправлено: `site.yml`
   рендерит в `--file helmwave.platform.yml` (гитигнорится) вместо дефолтного имени.

Не проверено на этом прогоне (не входило в scope Фазы 0, следующие шаги):

- Секреты (admin-пароли Gitea/Semaphore, cookie/access-key Semaphore) — плейсхолдеры прямо в
  values-файлах, не во внешнем хранилище. OpenBao (`docs/adr/0012-cicd-platform-architecture.md`
  §3) для секретов — не блокирует Фазу 0, но следующий обязательный шаг перед реальным
  использованием.
- TLS — самоподписанный (дефолтный сертификат встроенного Traefik)/HTTP, полноценный публичный
  TLS не в scope Фазы 0.
- Официального Helm-чарта Semaphore UI не найдено — развёрнут как голый
  Deployment/PVC/Service/IngressRoute через `nxs-universal-chart` (тот же приём, что уже
  применён для `homer`, `helm/envs/k3s-monitoring.yaml`) — работает, но не «из коробки»
  сопровождается апстримом Semaphore.
