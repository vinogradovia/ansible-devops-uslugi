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
  description = "Отображаемое имя VM в Proxmox UI и hostname гостя (короткое, не FQDN — домен ниже отдельно)"
  type        = string
  default     = "aicd-labs"
}

variable "vcpu" {
  description = "Число vCPU — как у platform/aicd (тот же профиль нагрузки: k3s + OpenBao + Gitea + Semaphore + Radar)"
  type        = number
  default     = 2
}

variable "memory" {
  description = "RAM, MiB — как у platform/aicd"
  type        = number
  default     = 4096
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
