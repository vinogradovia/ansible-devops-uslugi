# platform/aicd-devops-labs-ru — второе окружение платформы (Proxmox)

Второе, независимое окружение того же стека, что [`platform/aicd`](../aicd/README.md) —
K3s single-node + OpenBao (секреты/PKI) + Gitea + Semaphore UI + Flux + стандартные аддоны
(`docs/adr/0017-platform-cicd-default-addons.md`) — но на инфраструктуре Proxmox VE вместо
libvirt, под доменом `aicd.devops-labs.ru` вместо `aicd.platform`. Полная архитектура и
обоснование решений первого стенда (`docs/adr/0012-cicd-platform-architecture.md`,
`docs/adr/0014-platform-controller-architecture.md`, `docs/adr/0016-openbao-secrets-pki.md`,
`docs/adr/0017-platform-cicd-default-addons.md`) применимы к этому окружению без изменений —
здесь описаны только различия.

## Отличия от platform/aicd

- **Terraform-провайдер:** `bpg/proxmox` вместо `dmacvicar/libvirt` — VM клонируется из готового
  cloud-init-шаблона Ubuntu 24.04 (VMID 9000) на Proxmox-сервере пользователя, а не создаётся с
  нуля из base-образа. Плоская физическая LAN хоста (статический IP), не изолированная
  NAT-сеть — поэтому нет аналогов `libvirt_network`/`libvirt_pool`.
- **Домен:** `aicd.devops-labs.ru` (Ingress-хосты, PKI CN/role/policy в OpenBao) вместо
  `aicd.platform`. Домен приватный/лабораторный — как и `aicd.platform`, реальных публичных
  DNS-записей нет, резолвится только через `/etc/hosts` на клиентских машинах:
  ```
  10.10.10.249 gitea.aicd.devops-labs.ru
  10.10.10.249 semaphore.aicd.devops-labs.ru
  10.10.10.249 radar.aicd.devops-labs.ru
  10.10.10.249 infra-panel.aicd.devops-labs.ru
  10.10.10.249 openbao.aicd.devops-labs.ru
  10.10.10.249 sso.aicd.devops-labs.ru
  10.10.10.249 grafana.aicd.devops-labs.ru
  10.10.10.249 nexus.aicd.devops-labs.ru
  10.10.10.249 nexus-cache.aicd.devops-labs.ru
  10.10.10.249 docs.aicd.devops-labs.ru
  10.10.10.246 postgresql-infra-1.aicd.devops-labs.ru
  10.10.10.249 litellm.aicd.devops-labs.ru
  ```
  `postgresql-infra-1` — свой IP, не ClusterIP Traefik (docs/adr/0023-postgresql-standalone-role.md,
  standalone Postgres, сырой TCP на 5432, не HTTP/Ingress) — тот же принцип, что уже действует для
  `freeipa` (там своя запись в этом разделе исторически не заводилась, для Postgres заводим явно —
  нужна операторам для ручного `psql -h ...`).
- **Var-префикс ansible:** `platform_aicd_devops_labs_ru_*` (по имени каталога, та же
  конвенция, что `platform_aicd_*` у первого стенда).
- **Helmwave-окружение:** свой `K8S_CLUSTER=platform-devops-labs-ru`
  (`helm/envs/platform-devops-labs-ru.yaml`, `helm/values/platform-devops-labs-ru/...`) —
  полностью отдельное дерево values, не пересекается с `helm/values/platform/...` первого
  стенда, хотя набор релизов (openbao/gitea/semaphore/flux2/radar) идентичен.
- **platform-controller (ADR-0014)** — как и на первом стенде (`flux/`, CRD `Module`,
  `infra-panel-target.tf`, bootstrap Gitea/Semaphore) — теперь тоже развёрнуто и проверено
  реальным прогоном, см. секцию «platform-controller (ADR-0014)» ниже.

## Подготовка Proxmox (перед первым запуском)

**Шаблон VM.** Нужен уже готовый cloud-init-шаблон (Ubuntu 24.04 или совместимый — реально
проверено на Ubuntu 22.04.5, k3s не требователен к минорной версии) с известным VMID
(`var.proxmox_template_vmid`, по умолчанию `9000`). Этот terraform-код шаблон не создаёт, только
клонирует (`clone { vm_id = ..., full = true }` в `vm.tf`) — диск/сетевой интерфейс/scsihw
провайдер наследует у шаблона автоматически (`interface = "scsi0"` в `vm.tf` предполагает
`scsi0`/`virtio-scsi-pci`, как в проверенном шаблоне; для шаблона с другим диск-интерфейсом
поправить `vm.tf` соответственно — узнать реальные значения можно
`GET /api2/json/nodes/<node>/qemu/<vmid>/config` тем же токеном).

**Права API-токена.** Нужна отдельная роль с широким набором привилегий на VM/Datastore/SDN —
дефолтных ролей Proxmox (`PVEVMAdmin` и т.п.) недостаточно для конкретно операции clone+network в
одну проходку. Рабочий, реально проверенный набор (Proxmox VE 9.1 — привилегия `VM.Monitor` из
более старых версий убрана, `pveum` отклоняет её как invalid):

```bash
pveum role add TerraformProv -privs "VM.Allocate VM.Clone VM.Config.CDROM VM.Config.CPU VM.Config.Cloudinit VM.Config.Disk VM.Config.HWType VM.Config.Memory VM.Config.Network VM.Config.Options VM.Audit VM.PowerMgmt Datastore.AllocateSpace Datastore.AllocateTemplate Datastore.Audit Sys.Audit SDN.Use"
pveum aclmod / -user terraform_aicd@pve -role TerraformProv
pveum aclmod / -token 'terraform_aicd@pve!terraform_aicd' -role TerraformProv
```

`SDN.Use` — не очевидная и легко забываемая привилегия: с Proxmox VE 8/9 обычный Linux-бридж
(`vmbr0`) внутри тоже представлен SDN-зоной, и подключение сетевого интерфейса VM к нему требует
`SDN.Use` на `/sdn/zones/<zone>/<bridge>` (или, как здесь, на `/` целиком) отдельно от
`VM.Config.Network` — без неё `tofu apply` падает на этапе `clone` с
`403 Permission check failed (/sdn/zones/localnetwork/vmbr0, SDN.Use)`, при этом
`GET .../qemu/<vmid>/config` (чтение) тем же токеном при этом уже отвечает `200` — легко принять
эту ошибку за "права почти работают, чего-то одного не хватает" и не проверить именно SDN.

**Privilege separation токена.** По умолчанию Proxmox требует, чтобы разрешение было выдано И
пользователю, И отдельно самому токену (команды `aclmod` выше делают оба), а фактическое право —
их пересечение. Если после этого `tofu apply` всё ещё падает на `clone` с generic
`403 Permission check failed` без уточнения пути/привилегии — отключить privilege separation у
конкретного токена:

```bash
pveum user token modify terraform_aicd@pve terraform_aicd --privsep 0
```

`GET /api2/json/access/permissions` (с тем же токеном в `Authorization: PVEAPIToken=...`) полезен
для диагностики — показывает эффективные права по путям, но в проверенном случае показывал
"всё есть" даже когда `clone` реально падал (permissions-эндпоинт не всегда отражает разницу,
которую ловит privsep на state-changing операциях) — если права выглядят полными, а `clone`
всё равно 403 без детали, привсеп — первый кандидат, не более гранулярный поиск привилегии.

Экспортировать доступ к Proxmox API перед `terraform init`/`apply` (значения не хранятся в
репозитории):

```bash
export PROXMOX_VE_ENDPOINT='https://<ip-proxmox>:8006/'
export PROXMOX_VE_API_TOKEN='<user>@<realm>!<token-id>=<uuid>'
export PROXMOX_VE_INSECURE=true   # самоподписанный TLS-сертификат Proxmox
```

## Запуск

```bash
cd terraform
tofu init -input=false
tofu plan -input=false     # проверить план перед apply
tofu apply -input=false -auto-approve

ssh -o StrictHostKeyChecking=no ansible@$(tofu output -raw vm_ip) true

cd ../ansible
poetry run ansible-playbook -i inventory.yml site.yml
```

Требует на control-хосте (не на самой VM): `helm`, `helmwave`, python-пакет `kubernetes`
(dev-зависимость `pyproject.toml`) — те же требования, что `platform/aicd`.

**Реальная VM за пределами локальной сети control-хоста (не как у `platform/aicd`, где VM в
локальной libvirt-сети) — возможна нестабильность SSH.** Реальным прогоном найдена периодическая
обрубка соединения на длинных задачах (`xanmanning.k3s`), проявляющаяся как `Timeout waiting for
privilege escalation prompt` или `Shared connection ... closed`, при том что сам хост при этом
пингуется и порт 22 открыт — похоже на потери пакетов/перегрузку канала между control-хостом и
сетью Proxmox, а не на баг в коде или в правах sudo (`ansible_user` заведён с passwordless sudo
корректно). `ansible/ansible.cfg` этого каталога уже включает keepalive
(`ServerAliveInterval`/`ServerAliveCountMax`) и увеличенный `become_timeout` — снимают симптом
частично, но не первопричину. Playbook идемпотентен: если прогон прервался с `unreachable`,
достаточно проверить `ping`/быстрый `ssh ... true` до VM и повторить `ansible-playbook` — он
продолжит с того места, где реально остановился, не пересоздавая уже применённое.

## Стандартный набор аддонов

Тот же механизм и тот же дефолтный набор, что `platform/aicd`
(`docs/adr/0017-platform-cicd-default-addons.md`) — `platform_aicd_devops_labs_ru_default_addons`
по умолчанию включает [Radar](https://github.com/skyhook-io/radar) и `infra-panel` (дашборд-
стартовая страница со ссылками на все веб-UI платформы — Gitea/Semaphore/Radar/OpenBao). OpenBao
дополнительно получил Ingress (`openbao.aicd.devops-labs.ru`) в дополнение к `NodePort` — см.
ADR-0017 §3 для полного описания (ServersTransport для самоподписанного backend'а, TLS из
внутреннего PKI CA, без basic-auth перед OpenBao — он аутентифицирует сам себя). Переопределение —
`platform_aicd_devops_labs_ru_extra_addons`/`_disabled_addons` в
`ansible/group_vars/platform_hosts.yml` или `-e`. Та же асимметрия `disabled_addons` (не удаляет
уже установленный релиз, только останавливает его дальнейшее управление) — см. ADR-0017.

Проверено реальным прогоном на этом стенде: `401`/`200` для `infra-panel.aicd.devops-labs.ru`,
`200` для `openbao.aicd.devops-labs.ru/ui/`, TLS issuer обоих — внутренний PKI CA
(`CN=aicd.devops-labs.ru`), повторный прогон полностью идемпотентен (`changed=3`, только
ожидаемые always-changed задачи).

## Единая авторизация (docs/adr/0013-unified-auth-architecture.md)

Тот же дизайн, что `platform/aicd` (ADR-0013 §7) — свой, persistent `freeipa`
(`ipa.aicd.devops-labs.ru`, отдельная VM `platform/aicd-devops-labs-ru/terraform/freeipa-target.tf`,
клонирована из Rocky 9 cloud-init шаблона Proxmox, VMID 9001, готовится пользователем заранее — см.
«Подготовка Proxmox» выше) и **Authelia** (`sso.aicd.devops-labs.ru`) поверх него — OIDC-провайдер +
`forwardAuth`-шлюз, Helm-релизом, не отдельной ролью коллекции. `infra-panel`/`radar` защищены
`forwardAuth` (`Middleware authelia-forward-auth`, `/api/authz/forward-auth`), Semaphore и Gitea —
нативным OIDC. Каталог `freeipa` пуст по умолчанию — реальные учётные записи заводятся вручную
(`ipa user-add`, с VM `ipa.aicd.devops-labs.ru`, после `kinit admin`) — пошаговая процедура —
[`docs/runbooks/create-platform-user.md`](../../docs/runbooks/create-platform-user.md).

Перенесено на это окружение механической заменой (Фаза F, ADR-0013 §8) уже после того, как весь
дизайн был проверен и исправлен на `platform/aicd` (§7) — здесь всплыл свой класс находок,
специфичных для Proxmox-шаблона этого стенда: CPU-модель `qemu64` по умолчанию не поддерживает
x86-64-v2, обязательный для ядра Rocky 9 (VM зависала на пустой serial-консоли), sed-перенос
случайно переименовал `Secret aicd-platform-ca` (сознательно одинаковое имя между окружениями) в
`aicd-devops-labs-ru-ca`, из-за чего Gitea/Semaphore часами висели в `Init`/`ContainerCreating` на
несуществующем volume, пакет `firewalld` на этом шаблоне не установлен вовсе (в отличие от
Packer-образа `platform/aicd`), а обрыв SSH-сессии посреди `ipa-server-install` (сильная сетевая
флакость физической LAN этого стенда) оставил `/etc/ipa/default.conf` без реально завершённой
установки — потребовалось ручное `ipa-server-install --uninstall`. Полная хронология и разбор — ADR
§8.

**Проверено реальным прогоном:** `Releases Success 7/7`, `forwardAuth` — `302` на
`sso.aicd.devops-labs.ru` для `infra-panel`/`radar` без сессии, TLS issuer
`sso.aicd.devops-labs.ru` — внутренний CA этого окружения, Gitea/Semaphore показывают OIDC-вход
через Authelia, `freeipa` (`systemctl is-active ipa` → `active`), повторный прогон полностью
идемпотентен (`freeipa: changed=0`, `aicd-labs: changed=3`, только always-changed задачи).

## GPU-нода для агентного стека (docs/adr/0015-ai-agent-platform-architecture.md, Фаза 1)

`llm1` — вторая VM этого окружения, уже существовавшая на Proxmox с GPU passthrough (NVIDIA
RTX 5060 Ti), настроенным вручную на уровне гипервизора — заведена в `tofu` через `terraform
import` (`terraform/llm1-target.tf`), не создана этим terraform. Присоединена как **второй узел
уже существующего k3s-кластера** этого окружения (не отдельный кластер) — изоляция от
Gitea/Semaphore/OpenBao/Authelia/Radar/infra-panel на control-плане `aicd-labs` обеспечивается
taint узла (`dedicated=agents:NoSchedule`) + `RuntimeClass`, а не отдельным control-plane.

Host bootstrap (NVIDIA driver + `nvidia-container-toolkit` + gVisor) — новая роль
[`roles/k3s_gpu_node`](../../roles/k3s_gpu_node/README.md). Join к кластеру — официальный
install-скрипт `get.k3s.io` в agent-режиме, не роль `xanmanning.k3s` (её auto-clustering логика не
рассчитана на присоединение к control-plane, установленному отдельным прогоном — разбор в
ADR-0015 §10). Кластерные объекты (`RuntimeClass nvidia`/`runsc`, `nvidia-device-plugin`
DaemonSet, каркас namespace `llm`/`gateway`/`agents`/`data`/`obs`/`egress`, Pod Security
`restricted` + default-deny `NetworkPolicy` в `agents`) — задачи `site.yml`, не Helm-релиз.

**Известное ограничение окружения:** `nvcr.io` (официальный реестр NVIDIA) полностью недоступен с
этого стенда (`403 Forbidden` на любом пути) — тот же класс проблем, что уже задокументирован для
`github.com` release-assets и `vagrantcloud.com`. Образ `nvidia-device-plugin` собран локально и
зазеркалирован в собственный OCI-реестр Gitea этого стенда
(`gitea.aicd.devops-labs.ru/nvcr.io/nvidia/k8s-device-plugin:v0.17.1`, организация `nvcr.io` —
сохраняет оригинальный путь как имя пакета, публичный доступ). Подробности и полный список
находок (CPU-тип VM, кэш CA у containerd, `runtimeClassName` device-plugin'а и т.д.) — ADR-0015
§10.

**Проверено реальным прогоном:** `nvidia-smi` на `llm1` видит GPU, `kubectl get nodes` — оба узла
`Ready`, `nvidia.com/gpu: 1` в Allocatable `llm1`, под `nvidia-device-plugin` `Running 1/1`, taint
изолирует `llm1` от остальных подов платформы, Pod Security `restricted` и default-deny
`NetworkPolicy` в `agents` подтверждены живыми тестовыми подами (DNS резолвится, доступ к
API-серверу кластера блокируется), повторный прогон `site.yml` полностью идемпотентен
(`llm1: changed=0`).

## Мониторинг (docs/adr/0017-platform-cicd-default-addons.md §4)

Третий стандартный аддон, тот же приём, что `platform/aicd` (`vm` + `grafana-operator`, native
OIDC через Authelia, `https://grafana.aicd.devops-labs.ru`) — см. README `platform/aicd` за общим
описанием и полное обоснование в ADR-0017 §4 (почему не `roles/monitoring_server` напрямую, почему
без Loki/`grafana-alloy`/VMAlert). RAM `aicd-labs` поднята 6000→8192 MiB.

**Дополнительно только здесь — GPU-метрики llm1.** DaemonSet `dcgm-exporter` (по образцу
`nvidia-device-plugin` выше), сознательно **без** `resources.limits.nvidia.com/gpu` — иначе
единственная карта llm1 (`Allocatable nvidia.com/gpu: 1`) оказалась бы занята мониторингом и
недоступна для реальных AI/agent workload'ов. Вместо этого — `NVIDIA_VISIBLE_DEVICES=all` в обход
device-plugin allocation. Образ `nvidia/dcgm-exporter` — в отличие от `k8s-device-plugin`, есть
актуально на Docker Hub напрямую, сборка из исходников не понадобилась — просто ретег/push в тот же
Gitea-реестр (`gitea.aicd.devops-labs.ru/nvcr.io/...`).

**Живой resize RAM (2026-08-28) — найдена и устранена старая проблема с hostname.** После resize
control-plane нода перерегистрировалась в кластере под именем `aicd-devops-labs-ru` (реальный
hostname гостя) вместо `aicd-labs`, под которым она была изначально видна `kubectl` — `var.vm_name`
в Terraform уже был `"aicd-devops-labs-ru"` (переименование VM в Proxmox — update in place, не
трогает hostname гостя, тот выставляется cloud-init только при первом запуске), то есть это старая,
никем ранее не замеченная рассинхронизация, а не новый баг. Старый объект Node `aicd-labs` (kubelet
перестал слать статус) удалён. В коде коллекции control-plane нода нигде не адресуется по имени
(`kind: Node`/`k8s_taint` ссылаются только на `llm1`), только через ansible-инвентарь
(`hostvars['aicd-labs']`) — переименование гостя ansible-логику не затрагивает.

**Живьём развёрнуто и проверено** (2026-09-11, ROADMAP.md п.62 — статус выше был устаревшим,
относился к моменту написания кода, а не к текущему состоянию стенда): под `dcgm-exporter-g6j4w`
`Running` на `llm1` (аптайм с 2026-08-29), `VMPodScrape dcgm-exporter` — таргет `health: up` в
vmagent (`10.42.1.32:9400`). Прямой запрос `DCGM_FI_DEV_GPU_UTIL` к `vmsingle` возвращает реальную
серию с корректными метками (`modelName: NVIDIA GeForce RTX 5060 Ti`, `UUID`, `Hostname`). Дашборда
Grafana для этих метрик не было — добавлен (см. ROADMAP.md п.62).

## Кеширующий прокси (docs/adr/0018-internal-caching-proxy.md)

Тот же приём, что `platform/aicd` (Nexus Repository OSS, `https://nexus.aicd.devops-labs.ru` UI
через LDAP-логин, `https://nexus-cache.aicd.devops-labs.ru` — анонимные proxy-эндпоинты). RAM
`aicd-labs` поднята второй раз (8192→12288 MiB).

**Дополнительно только здесь — apt-кеш на llm1.** `k3s_gpu_node_apt_cache_url` перенаправляет
apt-источники `nvidia-container-toolkit`/gVisor через `nexus-cache.aicd.devops-labs.ru` ещё ДО
join `llm1` в кластер (та же `/etc/hosts`-запись на control-plane IP, что уже используется для
`gitea.aicd.devops-labs.ru`). `registries.yaml` (Docker/OCI-зеркало) пишется на `llm1` до первого
старта `k3s-agent` — рестарт не нужен.

**Не проверено реальным прогоном** — та же сетевая оговорка, что выше. Код провалидирован
`ansible-lint --profile production` + `--syntax-check`. Операторам — добавить в свой `/etc/hosts`
(см. полный список выше, добавлены `nexus`/`nexus-cache`).

## Standalone PostgreSQL (docs/adr/0023-postgresql-standalone-role.md)

Persistent VM `postgresql-infra-1` (`10.10.10.246`, обычный Ubuntu-образ, тот же шаблон, что
`aicd-labs`) — отдельно стоящий (не HA) сервер БД для нужд платформы (litellm/grafana/и т.п.), не
клиентский HA-хостинг (для того — `roles/postgresql_replication`, ADR-0005). **VM реально поднята**
(`tofu apply`, 2026-09-11, побочный эффект захода по `platform-controller`, см. секцию выше) и
**Semaphore Project `postgresql-infra` реально забутстрапен** (ADR-0023 §7: отдельный от
`platform` проект, id=2, Task Template `postgresql-infra-1 (ADR-0023)` id=3 с
`--limit postgresql-infra-1`, репозиторий `platform/gitops`, wrapper-playbook
`playbooks/postgresql-infra.yml` + `inventory/postgresql-infra.ini`, пароль `postgres_exporter` —
из уже существующего `secret/postgresql` OpenBao, передан как extra-var через Semaphore
Environment).

**Живьём развёрнуто и проверено** (2026-09-11, ROADMAP.md п.60): Task Template запущен через
Semaphore API (Task id=50) — `status: success`, `ok=55 changed=33 failed=0`. PostgreSQL 17
реально работает (`active`, `listen_addresses=*`, TLS `on`), `pg_hba.conf` без Debian-дефолтного
catch-all (только точечный грант `postgres-exporter`/`127.0.0.1`), `node_exporter`/
`postgres_exporter` (systemd, имена юнитов через `_`, не `-`) оба `active` с реальными метриками.
Повторный прогон (Task id=51) — `changed=0`, идемпотентность подтверждена.

**LiteLLM переключён на эту БД и живо проверен (2026-09-12).** `site.yml`: play "Standalone
PostgreSQL" переставлен ПЕРЕД play "LiteLLM-гейтвей" (иначе Helm поднимал Deployment раньше
готовности БД/пользователя) — создаёт пользователя `litellm` + БД `litellm` (owner `litellm`) +
`pg_hba.conf` hostssl-грант с IP ноды `aicd-labs` (не pod-сети `10.42.0.0/16` — LiteLLM-под
планируется только на неё, `llm1` затейнчена, а egress пода наружу кластера SNAT'ится flannel в
адрес ноды). `secret/litellm` в OpenBao расширен полем `db_password` аддитивно (KV v2 POST
заменяет данные версии целиком — существующий `master_key` явно сохранён, не потерян).
`general_settings.database_url: os.environ/DATABASE_URL` в `config.yaml`, DSN
(`sslmode=require`) — вторым ключом того же k8s Secret `litellm-master-key`. Prisma создал 75
таблиц схемы `LiteLLM_*`; `GET /health/readiness` → `{"status": "healthy", "db": "connected"}`;
`POST /key/generate` создал реальный virtual key в БД. **Найден и исправлен баг**: первый прогон
с `database_url` — под уходил в `OOMKilled` (exit 137) на старом лимите
`resources.limits.memory: 1Gi` (Prisma-миграция поднимает отдельный node-процесс query-engine
поверх python-процесса litellm) — поднято до `2Gi`
(`helm/values/platform-devops-labs-ru/namespaces/gateway/litellm/values.yaml`), повторный прогон
— под `Running`/`ready`, `restart_count: 0`. Повторный `site.yml` — `changed=0` на всех новых
задачах (кроме `helmwave up`, который репортит `changed` безусловно). Grafana остаётся на
sqlite — миграция по-прежнему вне скоупа (не запрошена).

**Admin UI (`/ui`) выставлен наружу и живо проверен (2026-09-13, ROADMAP.md №59).** Два
независимых слоя: (1) сетевой периметр — `IngressRoute litellm.aicd.devops-labs.ru` + Middleware
`authelia-forward-auth` + `access_control` в Authelia, доступ только `platform-admins`+
`platform-engineers` (без `platform-viewers` — UI создаёт/удаляет virtual keys, не read-only);
(2) собственный логин `/ui` — LiteLLM заведён ещё одним OIDC-клиентом Authelia (generic OIDC),
тем же классом решения, что Gitea/Semaphore/Grafana; `secret/authelia` расширен полем
`litellm_client_secret`(+`_hash`). **Два реальных бага найдены и исправлены:** встроенный в k3s
Traefik не поддерживает cross-namespace ссылку на Middleware без явного флага контроллера
(`--providers.kubernetescrd.allowCrossNamespace`) — понадобилась вторая копия Middleware в
`ns: gateway` (не глобальный флаг на весь Traefik); забытое правило `access_control` для домена
(без него `default_policy: deny` заблокировала бы даже показ логина). После фиксов:
неаутентифицированный запрос → `302 → sso.aicd.devops-labs.ru` с реальной формой логина, логи
Authelia показывают решение `forward-auth` по домену без ошибок конфигурации.

**Третий баг найден пользователем в браузере (клик на логин Authelia падал с `Internal server
error`) и исправлен тем же днём:** под LiteLLM не доверял внутреннему PKI CA (тот же класс
проблемы, что уже решён для Gitea/Grafana, но забыт при первой раскатке LiteLLM) —
`httpx`/`fastapi_sso` падал на обмене кода на токен с `CERTIFICATE_VERIFY_FAILED: self-signed
certificate in certificate chain`. Исправлено тем же приёмом: `Secret aicd-platform-ca` в
`ns: gateway` + `SSL_CERT_FILE` в env контейнера. Живо проверено: TLS-запрос к
`sso.aicd.devops-labs.ru` из пода litellm тем же `ssl.create_default_context()`, что использует
`httpx`, теперь `200`; `/health/readiness`/`/key/generate` по-прежнему работают.

**Четвёртый баг тем же клик-тестом**: после фикса TLS — `invalid_client`, LiteLLM
(`fastapi_sso`/`oauthlib`) шлёт `client_secret` через HTTP Basic Auth безусловно, а клиент был
зарегистрирован на `client_secret_post` (обратный случай уже известного Semaphore-инцидента) —
исправлено на `token_endpoint_auth_method: 'client_secret_basic'`. Логи Authelia после рестарта
чистые.

**Подтверждено пользователем: логин через браузер проходит до конца** (запись `ivinogradov` в
`LiteLLM_UserTable`, не только редирект).

**Маппинг ролей настроен**: `platform-admins`→`proxy_admin`, `platform-engineers`→`internal_user`
через `role_mappings` (`SSOConfig`, `PATCH /update/sso_settings`, БД-backed — механизм найден
через `openapi.json` живого инстанса, не `GENERIC_USER_ROLE_ATTRIBUTE`, тот ждёт скаляр, а
`groups` — список). По пути найдены и исправлены ещё четыре бага: не хватало scope `groups` у
клиента; `STORE_MODEL_IN_DB=True` — отдельный флаг для записи конфигурации в БД через admin-API;
`kubernetes.core.k8s_exec` требует `command` строкой, не списком; Jinja `.values.role_mappings`
коллизировал с `dict.values()`. Живо подтверждено (`GET /get/sso_settings`, идемпотентность
повторным `site.yml`).

**Пятый баг — кнопка SSO пропала с логин-страницы сразу после первого PATCH**, найден
пользователем в браузере: PATCH только с `role_mappings` переключает источник правды для ВСЕГО
`SSOConfig` на БД целиком — поля, не попавшие в тот PATCH (`generic_client_id` и т.д.), стали
`null`, несмотря на нетронутые env-переменные. Исправлено — PATCH несёт весь `SSOConfig` разом.
**Живо подтверждено пользователем через реальный браузер: кнопка SSO видна и работает.**

**Открыто**: обновляется ли роль уже существующих пользователей при повторном логине, или только
при создании записи — не проверено.

**Аудит LiteLLM против ADR-0022 (2026-09-13) нашёл и закрыл ещё два пробела.** Образ
`ghcr.io/berriai/litellm` тянулся напрямую из интернета (зеркалировался только `docker.io`) —
Nexus `docker-hub-proxy` обёрнут в docker-группу с новым `ghcr-proxy` на том же порту 8083 (одна
точка входа `nexus-cache.aicd.devops-labs.ru`, Nexus сам резолвит upstream); живо подтверждено
`GET /v2/berriai/litellm/manifests/...` → `200`, `docker.io`-регрессии нет. `/metrics` не был
включён — добавлен `litellm_settings.callbacks: ["prometheus"]` + `VMServiceScrape` +
официальный дашборд BerriAI; найден и исправлен ещё один баг — `/metrics` требует
`Authorization`, как и любой другой эндпоинт LiteLLM (`Secret litellm-metrics-token` в
`namespace: monitoring`, не `gateway` — `bearerTokenSecret` обязан лежать в namespace самого
`VMServiceScrape`). Два пункта аудита сознательно отложены (ROADMAP.md №64) — NetworkPolicy для
`ns: gateway` и оценка кандидата-Operator `litellm-operator`.

**Grafana-дашборд тоже проверен реальными данными.** `VMScrapeConfig monitoring-agent-hosts`
(`helm/values/platform-devops-labs-ru/namespaces/monitoring/vm/extra-objects.yaml`) уже содержал
статические таргеты для `postgresql-infra-1` — оба (`node-exporter`/`postgres-exporter`) `health:
up` в vmagent. `GrafanaDashboard` CR `postgres-exporter` — `DashboardSynchronized: True`. Прямой
запрос `pg_up{instance="postgresql-infra-1"}` к `vmsingle` вернул `1` — та же связка меток
(`job=postgres-exporter`, `instance=postgresql-infra-1`), что использует дашборд.

Найдена и исправлена одна реальная проблема при подготовке: **`qemu-guest-agent` не был
установлен на этой VM вообще** (в отличие от остальных VM окружения) — Terraform-провайдер
(`agent.enabled = true`) бесконечно висел на `refresh`/`apply` в ожидании ответа агента, которого
не существовало (`timeout`/`Plugin did not respond` на нескольких попытках подряд, до 550с).
Исправлено установкой `apt install qemu-guest-agent` через SSH напрямую на VM (не через Ansible —
роль `postgresql` ещё не применялась). Второй, отдельный SSH-ключ для Semaphore
(`tests/.ssh-pub-keys/id_ed25519_semaphore_postgresql_infra_devops_labs_ru.pub`, приватная часть
— Semaphore Key id=6, не в git) добавлен в `authorized_keys` вручную (VM уже жила, ключ из
`postgresql-infra-target.tf` при первом создании не подхватывается заново) и зафиксирован в
Terraform для воспроизводимости — `tofu apply` (in-place update, без пересоздания VM) подтверждён.

## docs-site (docs/adr/0024-platform-docs-site.md)

Статический сайт документации платформы (MkDocs Material) — за Traefik/`docs.aicd.devops-labs.ru`,
тот же `forwardAuth`-периметр Authelia, что Radar/infra-panel. Собирается CI-джобой
`.gitea/workflows/docs-site.yml` (не этим плейбуком) и публикуется в собственный raw-hosted
репозиторий Nexus `docs-site`; под лишь скачивает готовый артефакт при старте.

**Ручной шаг, обязателен перед первым `helmwave up --tags docs-site`:** в Gitea (репозиторий
коллекции) → Settings → Actions → Secrets вписать `NEXUS_DOCS_PUBLISHER_USER`
(`svc-docs-site-publisher`) и `NEXUS_DOCS_PUBLISHER_PASSWORD` (значение —
`docs_site_publisher_password` из `secret/nexus`, OpenBao) — REST-автоматизации создания Gitea
Actions secrets в коллекции нет (ADR §2). Без этого шага CI-джоба не сможет опубликовать артефакт
в Nexus, а первый деплой пода уйдёт в `CrashLoopBackOff` (init-container не найдёт
`docs-site/latest.tar.gz`) — тот же класс chicken-and-egg, что `gitea-actions-runner`/
`actions_runner_token`.

**Живьём развёрнуто и проверено** (2026-09-10, ROADMAP №51) — CI, публикация в Nexus, деплой,
TLS, `forwardAuth`, корневая страница (`/`) отдаёт `200`; четыре бага, найденных и исправленных
по пути (общих с `aicd`) — детали в ROADMAP №51. Отличие этого окружения: на его Gitea ранее не
существовало ни организации `platform`, ни зеркала коллекции — организация+репозиторий заведены
через REST (агентом, с разрешения оператора), сам `git push` и секреты Nexus в
Settings → Actions → Secrets — оператором вручную. `/etc/hosts` — см. полный список выше
(`docs.aicd.devops-labs.ru` добавлен).

## platform-controller (docs/adr/0014-platform-controller-architecture.md)

Весь цикл Фаз 0–6, ранее пройденный только на `platform/aicd` (см. его README и
`platform-controller/README.md`), повторён и на этом окружении — **сделано и проверено реальным
прогоном** (2026-09-11, ROADMAP №7 пункт 8). Общая архитектура и код контроллера — без
изменений, различия только в bootstrap-специфике этого Proxmox-стенда.

**Pilot target VM.** `terraform/infra-panel-target.tf` — тот же принцип изоляции состояния, что
`freeipa-target.tf`/`postgresql-infra-target.tf` (отдельный ресурс, не в общем `vm.tf`-цикле):
клон Ubuntu-шаблона (`var.proxmox_template_vmid`), статический IP `10.10.10.245`, выделенный
SSH-ключ (`tests/.ssh-pub-keys/id_ed25519_semaphore_infra_panel_target_devops_labs_ru.pub`,
приватная часть — Semaphore Key, не в git).

**`flux/`.** В отличие от первого стенда, сам релиз `flux2` и синк Secret `gitops-git-auth` уже
были в `site.yml`/`helm/envs/platform-devops-labs-ru.yaml` до этого захода (механически
перенесены при копировании кода первого стенда) — донастроен только сам GitOps-source
(`gitrepository.yaml`/`kustomization.yaml`, `kubectl apply` вручную, как на первом стенде).

**Bootstrap Gitea/Semaphore.** Организация `platform` и зеркало `platform/devops-uslugi` в Gitea
уже существовали (заведены при bootstrap'е docs-site, см. выше) — создан только репозиторий
`platform/gitops` (`playbooks/{infra_panel,noop}.yml`, `requirements.yml`,
`inventory/{infra_panel,noop}.ini`) через REST API. Semaphore — Project `platform`, ключи
(`login_password` для клона `gitops`, `ssh` для доступа к pilot-VM), два `Inventory` (`type:
file`), `Environment` с `GIT_CONFIG_*` (авторизация внутреннего клона `devops-uslugi`), два Task
Template (`infra_panel`, `noop`) — всё через REST API. Два `Module` CR (`noop-pilot`,
`infra-panel-pilot`) закоммичены в `platform/gitops` и подхвачены Flux **без единого `kubectl
apply`** — та же проверка Фазы 2, что на первом стенде.

**Контроллер — без TLS-хаков первого стенда.** На первом стенде (`platform/aicd`) у Semaphore
нет ни DNS, ни валидного TLS — контроллер обращается по IP с `Host`-заголовком и
`InsecureSkipTLSVerify: true`. На этом стенде `semaphore.aicd.devops-labs.ru` резолвится (через
`/etc/hosts` control-хоста) и имеет TLS-сертификат от внутреннего PKI CA — но `docker run` не
разделяет `/etc/hosts` хоста с контейнером, поэтому вместо хака: `--add-host
semaphore.aicd.devops-labs.ru:<IP>` (резолвинг) + `SSL_CERT_FILE=/certs/aicd-platform-ca.pem`,
смонтированный внутрь контейнера (Go на Linux сам читает эту переменную для системного пула
сертификатов, `crypto/x509`) — TLS проверяется по-настоящему, `InsecureSkipTLSVerify` не
использован вообще.

**Проверено реальным прогоном:** `infra-panel-pilot` — `status: success`
(`kubectl get module` → `READY: True`), реальные контейнеры `traefik`/`infra-panel` `Up ...
(healthy)` на pilot-VM (`docker ps`), 5 drift-циклов подряд без единого дублирующего job'а на
generation, последний — `changed=0` (полная идемпотентность). `noop-pilot` — десятки успешных
циклов за тот же прогон. Три реальные находки этого захода, все исправлены:

1. **`tofu apply` для клона VM, убитый по таймауту 2 минуты (foreground), оставил сироту.**
   Proxmox уже начал/завершил клонирование к моменту SIGTERM, а `tofu` не успел записать
   ресурс в state — следующий `apply` создал ВТОРОЙ клон с тем же именем, не зная о первом.
   Пользователь заметил дубликаты (VMID 106/112) в Proxmox UI раньше, чем это всплыло в выводе
   инструментов. Впредь — `run_in_background` с самого первого прогона для любых VM-клонов
   (см. память `feedback_terraform_apply_timeout_orphans.md`).
2. **Semaphore `Inventory.become_key_id`, указанный на SSH-ключ (тип `ssh`).** Semaphore
   ожидает для become либо пусто, либо ключ типа `login_password` (пароль sudo) — у целевого
   хоста passwordless sudo, поле become_key вообще не нужно. Ошибочное значение ронял job ещё
   до `ansible-playbook`: `"access key type not supported for ansible become user"`.
3. **`requirements.yml` в `platform/gitops` ссылался на `version: main`.** Реальная (и
   единственная) ветка зеркала `platform/devops-uslugi` — `feat/new-cloud-platform-development`
   (та, что была реально запушена пользователем) — `ansible-galaxy` падал на
   `git checkout main: pathspec 'main' did not match any file(s) known to git`.
