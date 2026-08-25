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
  ```
- **Var-префикс ansible:** `platform_aicd_devops_labs_ru_*` (по имени каталога, та же
  конвенция, что `platform_aicd_*` у первого стенда).
- **Helmwave-окружение:** свой `K8S_CLUSTER=platform-devops-labs-ru`
  (`helm/envs/platform-devops-labs-ru.yaml`, `helm/values/platform-devops-labs-ru/...`) —
  полностью отдельное дерево values, не пересекается с `helm/values/platform/...` первого
  стенда, хотя набор релизов (openbao/gitea/semaphore/flux2/radar) идентичен.
- **Без `flux/`** (GitOps-обвязка `GitRepository`/`Kustomization`, привязанная к CRD
  platform-controller'а и репозиторию `platform/gitops` в Gitea первого стенда) и **без
  `infra-panel-target.tf`** (отдельная VM-пилот для Module platform-controller'а) — это специфика
  dev-стенда platform-controller, не часть общего платформенного стека. При необходимости
  добавляется позже по образцу `platform/aicd/flux/README.md`.

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
