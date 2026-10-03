# site-proxmox

Дочерний Terraform-модуль: набор ВМ клиентского сайта на Proxmox VE, из карты `var.vms`.
Обобщение паттерна `platform/aicd-devops-labs-ru/terraform/vm.tf` (там — одна явная VM на
resource-блок; здесь — весь список ВМ клиента сразу, `for_each`).

## Предусловия (не создаются этим модулем)

- **Cloud-init шаблон на каждый `node`/`template_vmid`** уже склонирован на самом Proxmox-хосте
  вручную (`full clone` из подготовленного образа) — модуль только клонирует его дальше, не
  создаёт с нуля. Без этого `template_vmid` первый `terraform apply` упадёт на клонировании
  несуществующего VMID.
- **API-токен Proxmox** (`PROXMOX_VE_ENDPOINT`/`PROXMOX_VE_API_TOKEN`/`PROXMOX_VE_INSECURE`) —
  переменные окружения корневого модуля (`.env`, gitignored), не аргументы этого модуля и не
  `provider`-блок здесь (наследуется из корня, см. `versions.tf`).
- **Сетевой бридж** (`network_bridge`) и **datastore** (`datastore_id`) существуют на хосте.
  За пределами модуля — если у сайта есть отдельный внешний роутер/фаервол (виртуальный или
  физический, перед публичным IP хоста), проверьте у оператора площадки, на какой bridge
  заводить новые ВМ и какой gateway использовать: подключение к публичному bridge вместо
  внутреннего может выставить сервис наружу без NAT/фаервола перед ним.

## Переменные

См. `variables.tf` — `vms` (карта, один элемент на ВМ), `ansible_user`, `ssh_public_key_paths`
(список — один и более ключей попадают на все ВМ сайта через `user_account.keys`).

`vms[*].vendor_data_file_id` — оставьте `null` для НОВОГО, ещё не настроенного шаблона. Задавайте
только если у конкретного `template_vmid` уже есть свой cicustom cloud-init snippet, который
нужно сохранить (иначе `initialization`-блок Terraform молча его перезапишет).

## Пример

```hcl
module "site" {
  source = "git::<url-репозитория-devops.uslugi>//terraform-modules/site-proxmox?ref=v2.0.0-rc2"

  ssh_public_key_paths = ["~/.ssh/id_ed25519.pub"]

  vms = {
    dns = {
      node           = "pve1"
      template_vmid  = 9000
      # Имя датастора — всегда host-specific, подтвердите фактическое на конкретной площадке
      # (`pvesh get /storage`), не копируйте это значение бездумно: "local-lvm" (LVM-thin) —
      # частый дефолт после стандартной ISO-установки, но не универсальный — на одном из
      # клиентских хостов (wave/proxnode1) LVM не было вовсе, реальный датастор — "local" (dir).
      datastore_id   = "local"
      network_bridge = "vmbr1"
      cores          = 1
      memory         = 1024
      disk_gb        = 10
      ip_cidr        = "10.0.0.10/24"
      gateway        = "10.0.0.1"
    }
  }
}

output "vm_ips" {
  value = module.site.vm_ips
}
```

## Известные ограничения

- Один образ ОС на все ВМ карты не предполагается — каждая ВМ ссылается на свой
  `template_vmid`, поэтому разные ОС (например, Rocky 9 под FreeIPA, Ubuntu под остальное)
  поддерживаются без изменений в модуле — достаточно разных `template_vmid`.
- Модуль не создаёт и не проверяет DNS-записи — генерация `ansible/inventory.yml` из
  `vm_ips` (корневой модуль клиентского репозитория) не подразумевает резолвинг имён, только
  статические IP.
