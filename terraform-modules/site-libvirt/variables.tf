variable "vms" {
  description = <<-EOT
    Карта ВМ этого сайта: имя ВМ (без домена) → параметры. Ключ карты становится libvirt-доменом
    (с префиксом network_name, см. main.tf) и ключом в output vm_ips.
  EOT
  type = map(object({
    vcpu    = number
    memory  = number # MiB
    disk_gb = number
    ip      = string # без маски — статическая DHCP-резервация в сети сайта
    mac     = string
    # Ключ в var.base_images — какой базовый образ клонировать для этой ВМ. По умолчанию
    # "default": один образ на все ВМ сайта — самый частый случай. Отдельный ключ нужен только
    # когда в сайте есть ВМ на другой ОС (пример из platform/aicd — FreeIPA на Rocky 9,
    # остальное на Debian 12).
    base_image_key = optional(string, "default")
  }))
}

variable "base_images" {
  description = <<-EOT
    Карта ключ → источник base-образа (qcow2, cloud-init-совместимый): "https://…" для
    официального cloud image или "file://<путь>" для собственной Packer-сборки (см.
    platform/aicd/terraform/storage.tf — freeipa_base через file://). Минимум один элемент,
    ключ "default", должен существовать, если хотя бы одна ВМ его использует.
  EOT
  type        = map(string)
}

variable "libvirt_uri" {
  description = "libvirt connection URI (хост, где будут созданы ВМ сайта)"
  type        = string
  default     = "qemu:///system"
}

variable "pool_name" {
  description = "Имя выделенного libvirt storage pool для этого сайта — должно быть уникальным на хосте (не пересекаться с demo/*, другими клиентами)"
  type        = string
}

variable "pool_path" {
  description = "Путь на хосте для storage pool сайта"
  type        = string
}

variable "network_name" {
  description = "Имя выделенной libvirt-сети сайта — уникально на хосте (libvirt-домены живут в общем host-wide неймспейсе, см. main.tf)"
  type        = string
}

variable "network_domain" {
  description = "DNS-домен libvirt-сети (dnsmasq), используется и в fqdn ВМ"
  type        = string
}

variable "network_cidr" {
  description = "CIDR плоской сети сайта — отдельный от всех остальных стендов на этом хосте, чтобы не конфликтовать при одновременном запуске (см. реестр занятых CIDR в platform/aicd/terraform/variables.tf)"
  type        = string
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
