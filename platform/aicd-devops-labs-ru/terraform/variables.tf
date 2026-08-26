variable "proxmox_node" {
  description = "Имя ноды Proxmox VE, на которой создаётся VM (проверено GET /api2/json/nodes — реальное имя ноды \"pve\", а не FQDN хоста)"
  type        = string
  default     = "pve"
}

variable "proxmox_template_vmid" {
  description = "VMID шаблона Ubuntu 24.04 (cloud-init-ready), с которого клонируется VM стенда"
  type        = number
  default     = 9000
}

variable "proxmox_datastore_id" {
  description = "Datastore Proxmox для диска VM — то же хранилище, где лежит диск шаблона (проверено GET .../qemu/9000/config: scsi0 на local-lvm)"
  type        = string
  default     = "local-lvm"
}

variable "vm_name" {
  # Имя включает идентификатор окружения (совпадает с именем каталога platform/aicd-devops-labs-ru)
  # — на одном Proxmox-хосте потенциально несколько сред/стендов, голое "aicd-labs" неотличимо от
  # VM другого окружения в общем списке VM Proxmox UI. Смена этого атрибута у уже существующей VM —
  # update in place (provider не считает "name" ForceNew), пересоздания VM не вызывает.
  description = "Отображаемое имя VM в Proxmox UI и hostname гостя (короткое, не FQDN — домен ниже отдельно)"
  type        = string
  default     = "aicd-devops-labs-ru"
}

variable "vcpu" {
  description = "Число vCPU — как у platform/aicd (тот же профиль нагрузки: k3s + OpenBao + Gitea + Semaphore + Radar)"
  type        = number
  default     = 2
}

variable "memory" {
  description = "RAM, MiB — как у platform/aicd"
  type        = number
  default     = 6000
}

variable "disk_gb" {
  description = "Размер диска, GB — как у platform/aicd (диск шаблона в разы меньше, provider делает resize поверх клона)"
  type        = number
  default     = 40
}

variable "network_bridge" {
  description = "Имя Linux-бриджа Proxmox, к которому подключается сетевой интерфейс VM"
  type        = string
  default     = "vmbr0"
}

variable "vm_ip_cidr" {
  description = "Статический IPv4-адрес VM с маской (плоская физическая LAN хоста, не изолированная сеть)"
  type        = string
  default     = "10.10.10.249/24"
}

variable "vm_gateway" {
  description = "Шлюз сети, в которую подключена VM"
  type        = string
  default     = "10.10.10.1"
}

variable "ssh_public_key_path" {
  description = "Путь к публичному SSH-ключу, который cloud-init положит в ansible_user на VM стенда"
  type        = string
  default     = "/home/vinogradov/.ssh/id_rsa.pub"
}

variable "ansible_user" {
  description = "Пользователь, заводимый cloud-init на VM (passwordless sudo, для Ansible) — заменяет ciuser=ubuntu самого шаблона"
  type        = string
  default     = "ansible"
}

# ADR-0013 §1 — persistent freeipa, единый каталог для Authelia (тот же принцип, что
# platform/aicd/terraform/freeipa-target.tf). Отдельный Rocky 9 cloud-init шаблон (VMID 9001,
# подготовлен пользователем на этом Proxmox-сервере — не создаётся этим terraform, freeipa-server
# для Ubuntu/Debian не существует, см. roles/freeipa/README.md).
variable "proxmox_freeipa_template_vmid" {
  description = "VMID шаблона Rocky 9 (cloud-init-ready), с которого клонируется VM freeipa"
  type        = number
  default     = 9001
}

variable "freeipa_vm_name" {
  description = "Отображаемое имя VM freeipa в Proxmox UI и hostname гостя — с префиксом окружения, см. var.vm_name"
  type        = string
  default     = "aicd-devops-labs-ru-freeipa"
}

# vcpu/memory/disk_gb — тот же профиль, что platform/aicd/terraform/freeipa-target.tf (минимум по
# README роли freeipa — LDAP+Kerberos KDC+httpd+CA одновременно).
variable "freeipa_vcpu" {
  description = "Число vCPU для VM freeipa"
  type        = number
  default     = 2
}

variable "freeipa_memory" {
  description = "RAM, MiB для VM freeipa"
  type        = number
  default     = 4096
}

variable "freeipa_disk_gb" {
  description = "Размер диска, GB для VM freeipa"
  type        = number
  default     = 20
}

# Свободный IP той же плоской LAN, что основная VM (var.vm_ip_cidr, .249) — подтверждено
# пользователем как свободный на момент реализации (ADR-0013).
variable "freeipa_ip_cidr" {
  description = "Статический IPv4-адрес VM freeipa с маской (та же плоская LAN, что основная VM)"
  type        = string
  default     = "10.10.10.248/24"
}
