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
- Если в анкете есть k3s (`k3s_server`), скилл генерирует в целевом репозитории
  самодостаточный каталог `helm/` (копия движка-шаблона/списка репозиториев/generic-чарта из
  этой коллекции + пустой env-файл клиента) — готовый принять первый Helm-релиз через
  `helmwave`, без обращения к `ansible-devops-uslugi` во время исполнения (см. §4a). Какие
  конкретно релизы клиенту нужны — решается отдельно, не этим скиллом.
- Материализация сгенерированного репозитория (`tofu apply`/`ansible-playbook`) идёт через
  `Module` CRD + platform-controller + Semaphore (`docs/adr/0014-platform-controller-architecture.md`)
  — тот же механизм, что уже обслуживает саму платформу, не отдельный ручной путь (уточнено
  `docs/adr/0025-client-onboarding-architecture.md` §5, 2026-09-20). Конкретная регистрация
  (Semaphore Project/Task Template на клиента, владение `inventoryRef`, изоляция OpenBao
  клиента) — ещё не специфицирована. Этот скилл её не выполняет в любом случае — см. §6, он
  только генерирует и валидирует репозиторий, ничего не применяет.

## Процедура

### 1. Интервью → `client-profile.yaml`

Собери ответы в структуру, описанную в `templates/client-profile.example.yaml` (открой этот
файл — там же комментарии по каждому полю). Закрытые поля — через `AskUserQuestion`
(`provider`, нужен ли k3s и какая у него топология, какие из типовых ВМ нужны клиенту), открытые
значения (slug клиента, `domain_internal`, сеть/IP-план, sizing, путь к SSH-ключу, реквизиты
Proxmox/libvirt) — обычными уточняющими вопросами. Не додумывай сеть/провайдера сам — это то,
что реально различается между клиентами и не имеет безопасного дефолта (см. предупреждения в
`terraform-modules/site-proxmox/README.md` и `site-libvirt/README.md` про коллизии bridge/CIDR).

**`name` каждой ВМ — НЕ спрашивай у оператора свободным текстом.** Собери его сам по Host Naming
Policy (`docs/adr/0025-client-onboarding-architecture.md` §6):
`[site_code]-[env]-[сервис][nn]`. `site_code` (2–3 символа, до 6 при необходимости) — спроси
через `AskUserQuestion` вместе с `provider`, один раз на всю анкету. `env` — по умолчанию `p`,
КРОМЕ `dns`/`ipa`/`gitlab` (дефолт `i` — обслуживают инфраструктуру клиента, не прямая
бизнес-нагрузка, ADR-0025 §6); переопределяй в любую сторону только для явно служебных узлов
(например, второй k3s-агент под мониторинг — см. пример в `client-profile.example.yaml`), не
спрашивай отдельно, если оператор не поднял тему окружений сам. Код сервиса — выводится из
`role` той же ВМ по словарю ADR-0025 §6 (`devops.uslugi.infra_dns`→`dns`,
`devops.uslugi.freeipa`→`ipa`, `devops.uslugi.postgresql`→`db`, `stub:redis`→`cache`,
`stub:minio`→`stor`, `stub:gitlab-ce`→`gitlab`, `role: none`→`srv`,
`k3s_server`/`k3s_agent_tainted`→`k8s`, `devops.uslugi.nginx_multidomain`→`prx`) — если роль не
из этого словаря, уточни код у оператора
явно (не изобретай новый код сам, словарь закрытый). Порядковый номер — `01`, увеличивай только
если в анкете уже есть ВМ с тем же `site_code`+`env`+сервисом.

**ОС/шаблон каждой ВМ — явно сверяй с `role`, не бери автоматически общий `proxmox.template_vmid`
клиента.** `devops.uslugi.freeipa` требует RHEL-семейство (`dnf`) — пакета `freeipa-server` для
Debian/Ubuntu не существует (`roles/freeipa/README.md`, «Целевая ОС»). Если среди ВМ анкеты есть
`role: devops.uslugi.freeipa` (или другая роль, у которой README требует конкретную ОС), спроси
оператора явно: подготовлен ли на целевом хосте отдельный cloud-init шаблон под эту ОС
(`docs/proxmox-templates.md` часть 2 — Rocky 9, обычно свободный соседний VMID, например `9001`,
если Ubuntu уже занимает `9000`). Для ВМ с такой ролью запиши **свой** `template_vmid` в её
записи `vms[]` (поле `template_vmid`, переопределяет `proxmox.template_vmid` клиента по
умолчанию для этой конкретной ВМ — см. пример в `client-profile.example.yaml`), не дефолтный
Ubuntu-шаблон остальных ВМ клиента. Если шаблон под нужную ОС ещё не подготовлен — зафиксируй
это как открытое предусловие в README генерируемого репозитория (шаблон §5 ниже), а не молчи и
не бери Ubuntu как временную заглушку: прогон роли `freeipa` на неверной ОС падает не на
`--syntax-check`, а только на реальном `ansible-playbook` (найдено живым прогоном у wave/`sel` —
см. ADR-0025, «Известное ограничение... Найденная на реальном клиенте ошибка»).

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
- v1 **не разворачивает конкретную Helm-нагрузку** на этот кластер (даже на тейнченный узел) —
  какие релизы клиенту нужны, решает оператор отдельно, уже после онбординга. Но сам каталог
  `helm/`, готовый принять первый релиз через helmwave, скилл генерирует сразу — см. §4a ниже.
  Кластер после этого шага — пустой (два узла, один тейнт), но инструментарий для будущих
  релизов уже на месте, не придётся собирать его заново при первом реальном релизе.

### 4a. Генерация — `helm/` в целевом репозитории (только если в анкете есть `k3s_server`)

**Решение (ADR-0025 §4, пересмотрено 2026-10-04):** если среди ВМ анкеты есть `role:
k3s_server`, скилл создаёт в целевом репозитории полноценный, самодостаточный каталог `helm/` —
со всем, что нужно `helmwave` для работы, без обращения к `ansible-devops-uslugi` во время
исполнения. Вариант реализации — **полная копия** общих частей (движок-шаблон + список
репозиториев чартов + вендоренный generic-чарт) из этой коллекции на зафиксированном
коммите/теге, а не git submodule и не раскладывание их Ansible-задачей в рабочий каталог перед
`helmwave up` — обе альтернативы обсуждались и отклонены (ADR-0025 §4, «Отклонённые варианты»):
submodule добавляет операционную сложность (init/update, доступ раннера к приватному репо) без
выигрыша, т.к. `helmwave` (в отличие от Terraform) не умеет брать чарт прямо по git-ссылке —
вендорить физическим чекаутом всё равно придётся; раскладывание во временный незакоммиченный
каталог перед каждым прогоном воспроизводит ту же «работает не из каталога репозитория
окружения» проблему, просто спрятанную за дополнительным шагом.

Структура (копия из `helm/` этой коллекции на момент генерации, путь и назначение один в один):

```
<client-repo>/helm/
├── helmwave.yml.tpl           # движок шаблона — копия как есть, не меняется под клиента
├── envs/
│   ├── _helm-repos.yaml       # общий список Helm-репозиториев (vm, grafana, gitea-charts, ...) — копия как есть
│   └── <client>.yaml          # НОВЫЙ, специфичный для клиента — releases: [] (пусто в v1, см. ниже)
├── values/
│   ├── releases_common/       # пустая директория-заготовка (стабы заводятся по мере добавления релизов, ADR-0022 §8)
│   └── <client>/
│       └── namespaces/        # пустая директория-заготовка — values конкретных релизов кладутся сюда позже
└── localrepo/
    └── universal-chart/       # вендоренный generic-чарт — копия каталога как есть
```

`<client>` — тот же slug, что `client.client` в анкете (используется и как имя `K8S_CLUSTER`
для `helmwave`, и как имя подкаталога `values/`). `envs/<client>.yaml` генерируется с пустым
`releases: []` и шапкой-комментарием, объясняющей, что это файл клиента, а не референс
коллекции, и что добавление первого релиза — ручная задача оператора по образцу
`helm/envs/platform-devops-labs-ru.yaml` этой коллекции (копировать стиль заголовка/комментариев
релиза, не сам список релизов — он платформенный, не клиентский).

Копируемые файлы фиксируются на git-коммите/теге коллекции, который был активен на момент
генерации (запиши его в комментарии в начале `envs/<client>.yaml`, тот же принцип, что
`ref=<тег>` у Terraform-модулей в §2/§3 этого скилла) — чтобы было видно, с какой версии
`universal-chart`/движка начинался репозиторий клиента, и можно было решить, нужна ли
ресинхронизация при будущем обновлении.

**В `site.yml` целевого репозитория** play `k3s_server` дополняется заключительным,
закомментированным примером-заготовкой (не исполняемым по умолчанию — явный TODO-маркер, тот же
приём, что `stub:`-роли в §4 выше, а не молчаливый пропуск):

```yaml
  # TODO (ADR-0025 §4a): первый реальный Helm-релиз клиента — раскомментировать и адаптировать,
  # когда он появится. Пока helm/envs/<client>.yaml пуст (releases: []).
  # - name: "Helmwave up (<client>, helm/envs/<client>.yaml)"
  #   ansible.builtin.command: helmwave up --build --yes --file helmwave.<client>.yml
  #   environment:
  #     K8S_CLUSTER: "<client>"
  #     KUBECONFIG: "{{ ansible_env.HOME }}/.kube/config-<client>"
  #   args:
  #     chdir: "{{ playbook_dir }}/../helm"
  #   changed_when: true
```

(`chdir` — относительно `ansible/site.yml`, т.е. `<client-repo>/helm`, не три уровня вверх, как
в `platform/aicd-devops-labs-ru/ansible/site.yml` — там `helm/` в корне коллекции, здесь в
корне самого клиентского репозитория, это и есть исправление архитектуры, см. контекст задачи).

`.gitignore` целевого репозитория — добавить те же исключения, что в `.gitignore` этой
коллекции (`helm/.claude/`, `helm/.helmwave/`, `helm/tmp/`, рендеры `helmwave.<client>.yml`),
копировать построчно.

### 5. Генерация — `README.md` целевого репозитория

По образцу `platform/aicd-devops-labs-ru/README.md`. Обязательно явно перечисли предусловия,
которые Terraform НЕ создаёт сам (они реальны и легко забываются — см. находки в
`terraform-modules/*/README.md`):
- Proxmox: API-токен уже выпущен, cloud-init шаблон (`template_vmid`) уже склонирован на
  указанном `node` — **для каждого `template_vmid`, встречающегося в анкете**, не только
  дефолтного: если среди ВМ есть `devops.uslugi.freeipa` с отдельным `template_vmid` (RHEL/Rocky
  9, см. §1 выше), явно перечисли оба шаблона как отдельные предусловия, со ссылкой на
  `docs/proxmox-templates.md` (часть 1 — Ubuntu, часть 2 — Rocky 9).
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
Если сгенерирован `helm/` (§4a) — дополнительно проверь сам каталог, не применяя:
```
cd helm && K8S_CLUSTER=<client> helmwave yml --file helmwave.<client>.yml
```
— должен успешно отрендерить `helmwave.<client>.yml` из `envs/<client>.yaml` (даже с пустым
`releases: []`); ошибка здесь означает, что скопированные файлы (`helmwave.yml.tpl`,
`envs/_helm-repos.yaml`) не согласованы с версией `helmwave`, указанной в `pyproject.toml` этой
коллекции на момент генерации. **Не** `helmwave build` на этом шаге — с пустым `releases: []`
он детерминированно падает (`no graph roots found`, подтверждено живой проверкой 2026-10-04,
граф зависимостей требует хотя бы одного релиза) — это не признак поломанной копии, а
ограничение самого helmwave на пустом плане; `build`/`up` проверяются оператором позже, когда в
`envs/<client>.yaml` появится первый реальный релиз.

**Не выполняй** `tofu apply`, реальные (non-`--syntax-check`/non-`--check`) прогоны
`ansible-playbook`, `helmwave up`, SSH на целевые хосты или `git push` в новый репозиторий —
это требует отдельного явного запроса пользователя после того, как он проверил сгенерированное.

## Ссылки для расширения скилла

- `docs/adr/0025-client-onboarding-architecture.md` — архитектурное решение целиком, включая
  открытые вопросы (интеграция с platform-controller, что делать при появлении третьего облака);
  §6 — Host Naming Policy, обязательна к применению при сборке `name` каждой ВМ (см. §1 выше).
- `terraform-modules/site-proxmox/`, `terraform-modules/site-libvirt/` — сами модули + README с
  предусловиями/ограничениями.
- `platform/aicd-devops-labs-ru/terraform/`, `platform/aicd-devops-labs-ru/ansible/site.yml` —
  референсные, живо проверенные реализации всех паттернов выше (inventory-генерация, k3s
  server/agent join, taint).
- `platform/aicd/terraform/` — референс для libvirt-паттерна (network/storage/vms).
- `roles/freeipa`, `roles/postgresql`, `roles/infra_dns`, `roles/fail2ban` — переиспользуемые
  роли, у каждой свой README с обязательными шагами перед использованием.
- `helm/helmwave.yml.tpl`, `helm/envs/_helm-repos.yaml`, `helm/localrepo/universal-chart/` —
  общие файлы, копируемые в `<client-repo>/helm/` по §4a; `helm/envs/platform-devops-labs-ru.yaml`
  — референс стиля заголовка/комментариев для `envs/<client>.yaml` (не копировать сам список
  релизов, он платформенный).
- `ROADMAP.md` №61 — naming convention `client-<slug>`, которую этот скилл — первый реальный
  потребитель.
