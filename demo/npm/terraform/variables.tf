variable "libvirt_uri" {
  description = "libvirt connection URI (хост, где будут созданы VM стенда)"
  type        = string
  default     = "qemu:///system"
}

variable "pool_name" {
  description = "Имя выделенного libvirt storage pool для стенда (ADR-0006 §3 — не смешивается с default pool хоста)"
  type        = string
  default     = "demo-npm"
}

variable "pool_path" {
  description = "Путь на хосте для storage pool стенда"
  type        = string
  default     = "/var/lib/libvirt/images/demo-npm"
}

variable "network_name" {
  description = "Имя выделенной libvirt-сети стенда"
  type        = string
  default     = "demo-npm"
}

variable "network_cidr" {
  description = "CIDR плоской сети стенда — отдельный от demo/mysql-ha-platform (10.66.6.0/24), demo/postgresql-ha-platform (10.66.7.0/24), demo/monitoring-k3s-platform (10.66.8.0/24) и demo/nginx-multidomain (10.66.9.0/24), чтобы не конфликтовать при одновременном запуске"
  type        = string
  default     = "10.66.10.0/24"
}

variable "network_domain" {
  description = "DNS-домен libvirt-сети (dnsmasq), используется и в fqdn VM"
  type        = string
  default     = "npm.demo"
}

# ADR-0006 §7: официальный Debian 12 (bookworm) generic cloud image, один раз скачивается и
# переиспользуется как backing-том для всех VM (copy-on-write).
variable "base_image_url" {
  description = "URL образа Debian 12 generic cloud (qcow2, cloud-init)"
  type        = string
  default     = "https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2"
}

# По умолчанию — уже существующий в репозитории публичный ключ (tests/.ssh-pub-keys/), см.
# ADR-0006 §9 (упрощённая схема без Vault, стенд в изолированной локальной сети).
variable "ssh_public_key_path" {
  description = "Путь к публичному SSH-ключу, который получит ansible_user на всех VM стенда"
  type        = string
  default     = "../../../tests/.ssh-pub-keys/id_ed25519_vinogradov_desktop-u24.pub"
}

variable "ansible_user" {
  description = "Пользователь, заводимый cloud-init на всех VM (passwordless sudo, для Ansible)"
  type        = string
  default     = "ansible"
}
