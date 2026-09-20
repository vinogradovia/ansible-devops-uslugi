---
name: client-onboarding
description: Generate a new client infrastructure GitOps repository (Terraform + Ansible) for the devops.uslugi platform via a structured questionnaire. Use when onboarding a new client environment onto VM-based infrastructure (DNS, FreeIPA, Postgres, k3s, cache/storage placeholders) on Proxmox or libvirt — not for the internal platform/aicd* environments and not for demo/* stands.
---

# client-onboarding

Генерирует для нового клиента отдельный GitOps-репозиторий (Terraform + Ansible), переиспользуя
роли и Terraform-модули коллекции `devops.uslugi`, по данным структурированного интервью.

## Жёсткое правило

**Ни одного имени клиента, домена, IP, MAC-адреса или секрета не должно появиться внутри
`.claude/skills/client-onboarding/`.** Реальные данные — только в сгенерированном целевом
репозитории. `templates/client-profile.example.yaml` рядом с этим файлом — schema-документация
с заглушками, не пример реального клиента.

## Область применения

- Онбординг ВНЕШНЕГО клиента (собственная инфраструктура заказчика — VM/дедик/облако), не
  `platform/aicd*` (внутренняя платформа коллекции) и не `demo/*` (одноразовые демо-стенды для
  показа ролей).
- v1 поддерживает два backend: **Proxmox** (`terraform-modules/site-proxmox/`) и **libvirt**
  (`terraform-modules/site-libvirt/`). Другие облака — по мере появления реальных клиентов на
  них, тем же паттерном (см. `docs/adr/0025-client-onboarding-architecture.md`).
- Роли коллекции переиспользуются как есть: `freeipa`, `postgresql`, `infra_dns`, `fail2ban`.
  Redis/MinIO/GitLab (софт) — ролей ещё нет, v1 только поднимает ВМ и заводит базовый hardening,
  установка помечается TODO (см. §4).
- Интеграция с существующей GitOps-платформой (`platform-controller`/Semaphore/Flux на
  `aicd-devops-labs-ru`) сознательно **не решена** — генерируемый репозиторий самодостаточен,
  подключение к контуру платформы — отдельная, ещё не начатая задача.

## Процедура

### 1. Интервью → `client-profile.yaml`

Собери ответы в структуру, описанную в `templates/client-profile.example.yaml` (открой этот
файл — там же комментарии по каждому полю). Закрытые поля — через `AskUserQuestion`
(`provider`, нужен ли k3s и какая у него топология, какие из типовых ВМ нужны клиенту), открытые
значения (slug клиента, `domain_internal`, сеть/IP-план, sizing, путь к SSH-ключу, реквизиты
Proxmox/libvirt) — обычными уточняющими вопросами. Не додумывай сеть/провайдера сам — это то,
что реально различается между клиентами и не имеет безопасного дефолта (см. предупреждения в
`terraform-modules/site-proxmox/README.md` и `site-libvirt/README.md` про коллизии bridge/CIDR).

Результат интервью сохрани как `client-profile.yaml` в корне целевого репозитория (шаг 2) —
единственный источник истины для генерации, не проговаривай данные клиента в этом скилле.

### 2. Куда генерировать

По умолчанию — **новый отдельный git-репозиторий**, не каталог внутри `ansible-devops-uslugi`.
Та же граница, что между этой коллекцией (библиотека ролей/модулей) и `platform/gitops`
(декларация конкретного окружения) — см. `docs/adr/0025-client-onboarding-architecture.md`.
Уточни у оператора путь/имя нового репозитория явно, не выбирай сам. Внутрь `ansible-devops-uslugi`
(включая этот скилл) ничего не пишется.

### 3. Генерация — `terraform/`

- `versions.tf` — `required_providers` под выбранный `provider` (см. `versions.tf` в
  соответствующем `terraform-modules/site-*`).
- `main.tf` — один `module "site" { source = "git::<url-репозитория-devops.uslugi>//terraform-modules/site-<provider>?ref=<тег>" ... }`,
  вызванный с картой `vms` из `client-profile.yaml`. Закрепляй `ref` на теге/коммите, не на
  ветке — та же дисциплина точной версии, что уже принята для `xanmanning.k3s` в
  `requirements.yml` этой коллекции.
- `inventory.tf` + `templates/inventory.yml.tpl` — генерируют `../ansible/inventory.yml` из
  `module.site.vm_ips` через `local_file`/`templatefile`. Копируй паттерн один в один из
  `platform/aicd-devops-labs-ru/terraform/inventory.tf` + `templates/inventory.yml.tpl` (уже
  проверенный живым прогоном приём) — группа хостов на каждую ВМ по её `role` из анкеты.
- `.env.example` — плейсхолдеры `PROXMOX_VE_ENDPOINT`/`PROXMOX_VE_API_TOKEN`/`PROXMOX_VE_INSECURE`
  (или `LIBVIRT_URI` для libvirt), НИКОГДА не реальные значения. Реальный `.env` — в
  `.gitignore` целевого репозитория, тем же правилом, что `platform/*/.env` в этой коллекции.

### 4. Генерация — `ansible/`

`site.yml` целевого репозитория вызывает роли **по полному имени коллекции**
(`devops.uslugi.freeipa`, `devops.uslugi.postgresql`, `devops.uslugi.infra_dns`,
`devops.uslugi.fail2ban`) — `requirements.yml` целевого репозитория ставит саму коллекцию
закреплённым тегом (`ansible-galaxy collection install -r requirements.yml`), не копирует роли.

Маппинг `role` из анкеты → что делает Ansible:

| `role` в анкете | Play в `site.yml` |
|---|---|
| `devops.uslugi.<name>` | Обычный вызов роли как есть, с переменными из `group_vars/<vm>.yml` |
| `stub:<name>` | Только `devops.uslugi.fail2ban` (базовый hardening) + `# TODO: роль <name> не реализована, ROADMAP.md devops.uslugi` — комментарий-маркер прямо над host-группой, не молчаливый пропуск |
| `none` | Ничего прикладного — ВМ существует, инвентарь заведён, задач нет |
| `k3s_server` | Play «k3s server», см. ниже |
| `k3s_agent_tainted` | Play «k3s agent, taint `dedicated=<taint>:NoSchedule`», см. ниже |

**k3s bootstrap — копируй паттерн `platform/aicd-devops-labs-ru/ansible/site.yml`, не
изобретай заново:**
- Первый (`k3s_server`) узел — роль `xanmanning.k3s` (`k3s_state: installed`,
  `k3s_build_cluster: false`, `k3s_become: true`), тот же приём, что play «Platform CI/CD
  infra» в референсе. Не забудь `requirements.yml` целевого репозитория —
  `xanmanning.k3s`, версия закреплена (см. `requirements.yml` этой коллекции).
- Второй (`k3s_agent_tainted`) узел — **не через `xanmanning.k3s`**, а сырой install-скрипт
  `get.k3s.io` с `INSTALL_K3S_EXEC=agent`, `K3S_TOKEN` из `hostvars` первого узла
  (delegate_to + slurp + set_fact — паттерн уже есть в референсе, play «GPU-нода llm1», только
  без задач `k3s_gpu_node`/gVisor/NVIDIA — тейнт/toleration достаточно для изоляции монитроинга,
  GPU-специфика туда не относится). Тейнт — `kubectl taint node <name> dedicated=<taint из
  анкеты>:NoSchedule` через `k3s_server_manifests_urls`/`kubectl` delegate_to первого узла ПОСЛЕ
  join, не значение самой роли (у второго узла роли нет).
- v1 **не разворачивает Helm-нагрузку** на этот кластер (даже на тейнченный узел) — вопрос
  helmwave/OpenBao-интеграции для клиентского k3s не решён (см. §«Область применения» выше и
  ADR-0025). Кластер после этого шага — пустой, с двумя узлами и одним тейнтом.

### 5. Генерация — `README.md` целевого репозитория

По образцу `platform/aicd-devops-labs-ru/README.md`. Обязательно явно перечисли предусловия,
которые Terraform НЕ создаёт сам (они реальны и легко забываются — см. находки в
`terraform-modules/*/README.md`):
- Proxmox: API-токен уже выпущен, cloud-init шаблон (`template_vmid`) уже склонирован на
  указанном `node`.
- libvirt: `pool_name`/`network_name`/`network_cidr` проверены на отсутствие коллизии с другими
  стендами на этом же хосте.
- Оба: SSH-ключ по `ssh_public_key_path` существует локально.

### 6. Проверка — не применение

Прогони и покажи результат, ничего не применяя:
```
tofu -chdir=terraform init -backend=false && tofu -chdir=terraform validate
ansible-lint ansible/site.yml
ansible-playbook ansible/site.yml --syntax-check -i ansible/inventory.yml
```
**Не выполняй** `tofu apply`, реальные (non-`--syntax-check`/non-`--check`) прогоны
`ansible-playbook`, SSH на целевые хосты или `git push` в новый репозиторий — это требует
отдельного явного запроса пользователя после того, как он проверил сгенерированное.

## Ссылки для расширения скилла

- `docs/adr/0025-client-onboarding-architecture.md` — архитектурное решение целиком, включая
  открытые вопросы (интеграция с platform-controller, что делать при появлении третьего облака).
- `terraform-modules/site-proxmox/`, `terraform-modules/site-libvirt/` — сами модули + README с
  предусловиями/ограничениями.
- `platform/aicd-devops-labs-ru/terraform/`, `platform/aicd-devops-labs-ru/ansible/site.yml` —
  референсные, живо проверенные реализации всех паттернов выше (inventory-генерация, k3s
  server/agent join, taint).
- `platform/aicd/terraform/` — референс для libvirt-паттерна (network/storage/vms).
- `roles/freeipa`, `roles/postgresql`, `roles/infra_dns`, `roles/fail2ban` — переиспользуемые
  роли, у каждой свой README с обязательными шагами перед использованием.
- `ROADMAP.md` №61 — naming convention `client-<slug>`, которую этот скилл — первый реальный
  потребитель.
