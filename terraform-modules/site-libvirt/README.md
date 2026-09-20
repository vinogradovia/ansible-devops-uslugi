# site-libvirt

Дочерний Terraform-модуль: изолированная libvirt-сеть + storage pool + набор ВМ клиентского
сайта, из карты `var.vms`. Обобщение паттерна `platform/aicd/terraform`
(`network.tf`/`storage.tf`/`vms.tf`) — там карта `local.vms` внутренняя и на сегодня содержит
одну ВМ; здесь интерфейс публичный (`var.vms`) и рассчитан на весь список ВМ клиента сразу.

## Предусловия

- **libvirt-хост доступен** по `var.libvirt_uri` (обычно `qemu:///system` при локальном control-
  хосте = гипервизору, `qemu+ssh://…` при удалённом — тот же выбор, что у `demo/*`).
- **`pool_name`/`network_name`/`network_cidr` не пересекаются** с другими стендами/клиентами на
  этом же libvirt-хосте — `libvirt_domain` живёт в общем host-wide неймспейсе, столкновение
  имени домена или CIDR ломает чужой уже работающий стенд, не только новый. Ведите реестр
  занятых значений в README клиентского репозитория (по образцу комментария в
  `platform/aicd/terraform/variables.tf`).

## Переменные

См. `variables.tf` — `vms` (карта, один элемент на ВМ), `base_images` (карта образов, ключ
`"default"` обязателен, если на него ссылается хотя бы одна ВМ), `pool_name`/`pool_path`,
`network_name`/`network_domain`/`network_cidr`, `ansible_user`, `ssh_public_key_path`.

## Пример

```hcl
module "site" {
  source = "git::<url-репозитория-devops.uslugi>//terraform-modules/site-libvirt?ref=v1.0.0"

  pool_name            = "client-example"
  pool_path            = "/var/lib/libvirt/images/client-example"
  network_name         = "client-example"
  network_domain       = "infra.example.com"
  network_cidr         = "10.66.20.0/24"
  ssh_public_key_path  = "~/.ssh/id_ed25519.pub"

  base_images = {
    default = "https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2"
  }

  vms = {
    dns = {
      vcpu    = 1
      memory  = 1024
      disk_gb = 10
      ip      = "10.66.20.10"
      mac     = "52:54:00:66:20:10"
    }
  }
}

output "vm_ips" {
  value = module.site.vm_ips
}
```

## Известные ограничения

- IP/MAC статические, задаются анкетой — не DHCP-автоназначение: тот же выбор, что уже принят в
  `platform/aicd`, ради предсказуемого `ansible/inventory.yml`.
- Несколько разных ОС в одном сайте поддержаны через `base_images`/`base_image_key`
  (прецедент — Rocky 9 под FreeIPA в `platform/aicd`), но каждый новый образ — это ещё один
  элемент карты `base_images`, не автоматический подбор по роли ВМ.
