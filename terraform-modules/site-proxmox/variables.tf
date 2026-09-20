variable "vms" {
  description = <<-EOT
    Карта ВМ этого сайта: имя ВМ (без домена) → параметры. Ключ карты становится именем VM
    в Proxmox и ключом в output vm_ips — используйте короткие технические имена
    (`dns`, `freeipa`, `postgres`, …), не FQDN.
  EOT
  type = map(object({
    node           = string
    template_vmid  = number
    datastore_id   = string
    network_bridge = string
    cores          = number
    memory         = number
    disk_gb        = number
    ip_cidr        = string
    gateway        = string
    # Дефолт provider'а без явного type — "qemu64"/"kvm64", без SSE4.2/x86-64-v2: свежий glibc
    # (в частности, cloud-init-образы Ubuntu 24.04+) падает "CPU does not support x86-64-v2".
    # Находка platform/aicd-devops-labs-ru/terraform/vm.tf (деплой LiteLLM, 2026-09-06).
    cpu_type = optional(string, "x86-64-v2-AES")
    # cicustom-сниппет, УЖЕ настроенный на конкретном шаблоне (template_vmid) этого Proxmox-хоста
    # — если он есть. initialization-блок Terraform полностью перезаписывает cloud-init диск (ide2)
    # тем, что описано в нём: без явного указания сниппет шаблона молча теряется (см. README).
    # Для нового, ещё не настроенного шаблона оставьте null.
    vendor_data_file_id = optional(string)
  }))
}

variable "ansible_user" {
  description = "Пользователь, заводимый cloud-init на каждой ВМ сайта (passwordless sudo, для Ansible)"
  type        = string
  default     = "ansible"
}

variable "ssh_public_key_path" {
  description = "Путь к публичному SSH-ключу, который получит ansible_user на всех ВМ сайта"
  type        = string
}
