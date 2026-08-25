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

## Запуск

Перед `terraform init`/`apply` — экспортировать доступ к Proxmox API (значения не хранятся в
репозитории):

```bash
export PROXMOX_VE_ENDPOINT='https://<ip-proxmox>:8006/'
export PROXMOX_VE_API_TOKEN='<user>@<realm>!<token-id>=<uuid>'
export PROXMOX_VE_INSECURE=true   # самоподписанный TLS-сертификат Proxmox
```

Токену нужны права на клонирование/настройку VM (`VM.Clone`, `VM.Config.*`, `VM.Audit`,
`Datastore.AllocateSpace` и т.п. на путь, покрывающий шаблон и новые VM) — Proxmox по умолчанию
включает privilege separation для API-токенов, роль нужно выдать отдельно и пользователю, и
самому токену (`pveum aclmod / -user ... -role ...` и `pveum aclmod / -token '...' -role ...`).

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

## Стандартный набор аддонов

Тот же механизм и тот же дефолтный набор, что `platform/aicd`
(`docs/adr/0017-platform-cicd-default-addons.md`) — `platform_aicd_devops_labs_ru_default_addons`
по умолчанию включает [Radar](https://github.com/skyhook-io/radar). Переопределение —
`platform_aicd_devops_labs_ru_extra_addons`/`_disabled_addons` в
`ansible/group_vars/platform_hosts.yml` или `-e`. Та же асимметрия `disabled_addons` (не удаляет
уже установленный релиз, только останавливает его дальнейшее управление) — см. ADR-0017.
