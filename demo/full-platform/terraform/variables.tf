variable "libvirt_uri" {
  description = "libvirt connection URI (хост, где будут созданы VM стенда)"
  type        = string
  default     = "qemu:///system"
}

variable "pool_name" {
  description = "Имя выделенного libvirt storage pool для стенда (ADR-0006 §3 — не смешивается с default pool хоста)"
  type        = string
  default     = "demo-full-platform"
}

variable "pool_path" {
  description = "Путь на хосте для storage pool стенда"
  type        = string
  default     = "/var/lib/libvirt/images/demo-full-platform"
}

# ADR-0006 §2: одна плоская libvirt-сеть (NAT), два ДЦ не имитируются.
variable "network_name" {
  description = "Имя выделенной libvirt-сети стенда"
  type        = string
  default     = "demo-full-platform"
}

variable "network_cidr" {
  description = "CIDR плоской сети стенда — отдельный от остальных 6 стендов demo/* (10.66.6.0/24 .. 10.66.11.0/24), чтобы не конфликтовать при одновременном запуске. .12 занят демо-стендом demo-samba-server (его terraform-файлы удалены из репозитория, но сама сеть/VM остаётся поднятой на хосте — обнаружено первым же apply, см. `virsh net-list --all`), поэтому взят следующий свободный — .13."
  type        = string
  default     = "10.66.13.0/24"
}

variable "network_domain" {
  description = "DNS-домен libvirt-сети (dnsmasq), используется и в fqdn VM"
  type        = string
  default     = "full-platform.demo"
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
# id_ed25519_vinogradov_desktop-u24.pub (дефолт у остальных demo/*-стендов) — приватной пары к
# нему на этой машине нет (она физически на другом хосте, desktop-u24), из-за чего ansible не мог
# подключиться к VM после пересоздания. Здесь используется id_ed25519_vinogradov_ivan-fmi-721.pub
# — приватный ключ есть локально (~/.ssh/id_ed25519, тот же, что уже в ssh-agent).
variable "ssh_public_key_path" {
  description = "Путь к публичному SSH-ключу, который получит ansible_user на всех VM стенда"
  type        = string
  default     = "../../../tests/.ssh-pub-keys/id_ed25519_vinogradov_ivan-fmi-721.pub"
}

variable "ansible_user" {
  description = "Пользователь, заводимый cloud-init на всех VM (passwordless sudo, для Ansible)"
  type        = string
  default     = "ansible"
}

# freeipa требует Rocky/AlmaLinux 9 (roles/freeipa/README.md, «Целевая ОС») — второй, отдельный
# base-образ только для VM freeipa (остальной стенд — debian-12-generic-amd64-base.qcow2 выше).
# Готовых Rocky9-боксов с рабочим cloud-init/NoCloud под этот хост нет (см.
# extensions/molecule/freeipa/molecule.yml, «История подбора бокса») — вместо загрузки готового
# образа используется собственная сборка через Packer
# (extensions/molecule/freeipa/packer/rocky9.pkr.hcl), тот же box, что и у molecule-сценария
# freeipa, но с добавленным cloud-init (см. http/ks.cfg). Обязательный предварительный шаг:
#   cd ../../../extensions/molecule/freeipa/packer && packer init . && packer build rocky9.pkr.hcl
# (keep_input_artifact в шаблоне сохраняет сырой qcow2 рядом с .box — именно его использует
# terraform ниже напрямую, без vagrant-обёртки).
# Функции (abspath) недоступны в default variable — путь относительно каталога модуля,
# приводится к абсолютному file:// в locals (storage.tf).
variable "freeipa_base_image_path" {
  description = "Путь к собственному Rocky 9 qcow2-образу (extensions/molecule/freeipa/packer), см. комментарий выше"
  type        = string
  default     = "../../../extensions/molecule/freeipa/packer/output-rockylinux9-freeipa/rockylinux9-freeipa.qcow2"
}
