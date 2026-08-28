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
  description = "RAM, MiB — поднята с 6000 до 8192 (мониторинг, docs/adr/0017-platform-cicd-default-addons.md): на 6000 нода уже была на 43% реального потребления памяти без единого мониторингового пода (metrics-server, замер 2026-08-28)"
  type        = number
  default     = 8192
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

# ADR-0015 (Фаза 1) — узел с GPU для агентного стека, второй узел уже существующего k3s
# aicd-devops-labs-ru (не отдельный кластер — см. docs/adr/0015-ai-agent-platform-architecture.md,
# §10). В отличие от aicd_labs/freeipa выше — эта VM НЕ создаётся этим terraform, она уже
# существует на Proxmox (GPU passthrough настроен вручную на уровне гипервизора) и заводится сюда
# через `terraform import` (см. llm1-target.tf) — значения переменных ниже списаны с реального
# `GET /nodes/<node>/qemu/<vmid>/config`, а не выбраны нами.
variable "llm1_vm_id" {
  description = "VMID существующей VM llm1 на Proxmox (найден по имени диска vm-105-disk-0)"
  type        = number
  default     = 105
}

variable "llm1_vm_name" {
  description = "Имя VM llm1 в Proxmox UI и hostname гостя (уже так называется, не переименовываем)"
  type        = string
  default     = "llm1"
}

# node_name у llm1 отдельно не читался тем же GET (эндпоинт уже требует известный node в пути) —
# подтверждено пользователем: та же единственная нода Proxmox, что у aicd_labs/freeipa
# (var.proxmox_node, "pve"), отдельной переменной не заводим.

variable "llm1_cores" {
  description = "vCPU llm1 (реальное значение с GET .../config: cores=4, sockets=1)"
  type        = number
  default     = 4
}

variable "llm1_memory" {
  description = "RAM, MiB (реальное значение с GET .../config: memory=10240)"
  type        = number
  default     = 10240
}

variable "llm1_disk_datastore_id" {
  description = "Datastore диска/cloud-init llm1 — НЕ local-lvm, как у остальных VM: реальный scsi0/ide2 на этой VM живут на датасторе \"nvme\" (отдельный NVMe-накопитель под GPU-хостом)"
  type        = string
  default     = "nvme"
}

variable "llm1_disk_gb" {
  description = "Размер системного диска, GB (реальное значение scsi0: size=60G)"
  type        = number
  default     = 60
}

variable "llm1_network_bridge" {
  description = "Linux-бридж llm1 (реальное значение net0: bridge=vmbr0, тот же, что у остальных VM)"
  type        = string
  default     = "vmbr0"
}

variable "llm1_mac_address" {
  description = "MAC-адрес существующего net0 llm1 — фиксируем явно, чтобы import не считал сетевой интерфейс изменившимся"
  type        = string
  default     = "BC:24:11:10:9B:69"
}

# hostpci0 — GPU passthrough, настроен вручную на Proxmox (PCI-адрес карты в этом конкретном
# хосте) — сюда переносится один в один, управлять им через tofu (менять) не планируется, см.
# lifecycle.ignore_changes в llm1-target.tf.
variable "llm1_hostpci_id" {
  description = "PCI-адрес GPU для passthrough (реальное значение hostpci0: 0000:84:00)"
  type        = string
  default     = "0000:84:00"
}

# ipconfig0 у llm1 — статический (в отличие от исходного предположения DHCP), но с необычной
# маской /32 (уточнено с пользователем по факту, а не выбрано нами) — cloud-init на этой VM уже
# так настроен и работает, менять не будем (initialization целиком под ignore_changes).
variable "llm1_ip_cidr" {
  description = "IPv4-адрес llm1 с маской (та же плоская LAN, но /32 — реальное значение ipconfig0)"
  type        = string
  default     = "10.10.10.247/32"
}

variable "llm1_ansible_user" {
  description = "Cloud-init пользователь llm1 — \"ubuntu\" (ciuser в реальном конфиге), НЕ \"ansible\", как у aicd_labs/freeipa — эта VM создавалась не тем же terraform-циклом"
  type        = string
  default     = "ubuntu"
}
