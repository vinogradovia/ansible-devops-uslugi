variable "libvirt_uri" {
  description = "libvirt connection URI (хост, где будут созданы VM стенда)"
  type        = string
  default     = "qemu:///system"
}

variable "pool_name" {
  description = "Имя выделенного libvirt storage pool для стенда (ADR-0006 §3 — не смешивается с default pool хоста)"
  type        = string
  default     = "demo-nginx-multidomain"
}

variable "pool_path" {
  description = "Путь на хосте для storage pool стенда"
  type        = string
  default     = "/var/lib/libvirt/images/demo-nginx-multidomain"
}

variable "network_name" {
  description = "Имя выделенной libvirt-сети стенда"
  type        = string
  default     = "demo-nginx-multidomain"
}

variable "network_cidr" {
  description = "CIDR плоской сети стенда — отдельный от demo/mysql-ha-platform (10.66.6.0/24), demo/postgresql-ha-platform (10.66.7.0/24) и demo/monitoring-k3s-platform (10.66.8.0/24), чтобы не конфликтовать при одновременном запуске"
  type        = string
  default     = "10.66.9.0/24"
}

variable "network_domain" {
  description = "DNS-домен libvirt-сети (dnsmasq), используется и в fqdn VM"
  type        = string
  default     = "nginx-multidomain.demo"
}

# ADR-0006 §7 (см. "Обновление"): Ubuntu 24.04 (noble) server cloud image — стандарт для всех
# demo/*-стендов (тот же дистрибутив, что box cloud-image/ubuntu-24.04 во всех
# extensions/molecule/*-сценариях). Один раз скачивается и переиспользуется как backing-том для
# всех VM (copy-on-write).
variable "base_image_url" {
  description = "URL образа Ubuntu 24.04 (noble) server cloud (qcow2, cloud-init)"
  type        = string
  default     = "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
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
