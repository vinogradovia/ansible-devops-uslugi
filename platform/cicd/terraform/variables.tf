variable "libvirt_uri" {
  description = "libvirt connection URI (хост, где будет создана VM)"
  type        = string
  default     = "qemu:///system"
}

variable "pool_name" {
  description = "Имя выделенного libvirt storage pool для этого стенда"
  type        = string
  default     = "platform-cicd"
}

variable "pool_path" {
  description = "Путь на хосте для storage pool стенда"
  type        = string
  default     = "/var/lib/libvirt/images/platform-cicd"
}

variable "network_name" {
  description = "Имя выделенной libvirt-сети стенда"
  type        = string
  default     = "platform-cicd"
}

# Реестр занятых CIDR (demo/*/terraform/variables.tf): mysql-ha-platform 10.66.6.0/24,
# postgresql-ha-platform 10.66.7.0/24, monitoring-k3s-platform 10.66.8.0/24,
# nginx-multidomain 10.66.9.0/24, npm 10.66.10.0/24, backup 10.66.11.0/24,
# samba-server 10.66.12.0/24 (VM/сеть остаются подняты на хосте, хотя terraform-файлы стенда
# отдельно не хранятся здесь), full-platform 10.66.13.0/24 — следующий свободный: .14.
variable "network_cidr" {
  description = "CIDR плоской сети стенда — отдельный от всех demo/* (см. комментарий выше), чтобы не конфликтовать при одновременном запуске"
  type        = string
  default     = "10.66.14.0/24"
}

variable "network_domain" {
  description = "DNS-домен libvirt-сети (dnsmasq), используется и в fqdn VM"
  type        = string
  default     = "cicd.platform"
}

# Тот же официальный Debian 12 (bookworm) generic cloud image, что demo/* — k3s не требует
# конкретного дистрибутива, нет причины отличаться от уже используемого в коллекции образа.
variable "base_image_url" {
  description = "URL образа Debian 12 generic cloud (qcow2, cloud-init)"
  type        = string
  default     = "https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2"
}

variable "ssh_public_key_path" {
  description = "Путь к публичному SSH-ключу, который получит ansible_user на VM стенда"
  type        = string
  default     = "../../../tests/.ssh-pub-keys/id_ed25519_vinogradov_desktop-u24.pub"
}

variable "ansible_user" {
  description = "Пользователь, заводимый cloud-init на VM (passwordless sudo, для Ansible)"
  type        = string
  default     = "ansible"
}
