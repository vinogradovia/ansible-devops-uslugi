variable "libvirt_uri" {
  description = "libvirt connection URI (хост, где будут созданы VM стенда)"
  type        = string
  default     = "qemu:///system"
}

variable "pool_name" {
  description = "Имя выделенного libvirt storage pool для стенда"
  type        = string
  default     = "demo-postgresql-ha-platform"
}

variable "pool_path" {
  description = "Путь на хосте для storage pool стенда"
  type        = string
  default     = "/var/lib/libvirt/images/demo-postgresql-ha-platform"
}

# ADR-0006 §2: одна плоская libvirt-сеть (NAT), два ДЦ не имитируются.
variable "network_name" {
  description = "Имя выделенной libvirt-сети стенда"
  type        = string
  default     = "demo-postgresql-ha-platform"
}

variable "network_cidr" {
  description = "CIDR плоской сети стенда — отдельный от demo/mysql-ha-platform (10.66.6.0/24) и extensions/molecule/{mysql_replication,proxysql,postgresql_replication,odyssey}, чтобы можно было поднять оба демо-стенда одновременно"
  type        = string
  default     = "10.66.7.0/24"
}

variable "network_domain" {
  description = "DNS-домен libvirt-сети (dnsmasq), используется и в fqdn VM"
  type        = string
  default     = "postgresql-ha-platform.demo"
}

# ADR-0006 §7: официальный Debian 12 (bookworm) generic cloud image, один раз скачивается и
# переиспользуется как backing-том для всех VM (copy-on-write).
variable "base_image_url" {
  description = "URL образа Debian 12 generic cloud (qcow2, cloud-init)"
  type        = string
  default     = "https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2"
}

# По умолчанию — уже существующий в репозитории публичный ключ (tests/.ssh-pub-keys/), см.
# demo/mysql-ha-platform/terraform/variables.tf — тот же паттерн, тот же кэвит (приватного ключа
# от него может не быть на машине оператора, тогда override через -var).
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
