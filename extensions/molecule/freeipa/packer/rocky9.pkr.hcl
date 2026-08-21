# Packer-шаблон для сборки собственного vagrant/libvirt box Rocky Linux 9 — обход блокеров
# готовых боксов, см. extensions/molecule/freeipa/molecule.yml, «История подбора бокса»:
#   - rockylinux/9 5.0.0 (официальный box) — dracut не успевает смонтировать root (rd.timeout),
#     подозреваемая причина — активация LVM внутри initramfs.
#   - openlogic/rockylinux-9 — грузится нормально, но это cloud-marketplace-образ: vagrant
#     insecure keypair не подсаживается (рассчитан на реальный cloud metadata-сервис).
#   - Готовые боксы с vagrantcloud.com/hashicorp-archivist сейчас недоступны с этого хоста —
#     гео-блокировка на стороне HashiCorp (не наша конфигурация, не решается прокси).
#
# Собственная сборка снимает обе проблемы разом: партиционирование без LVM (http/ks.cfg,
# autopart --type=plain) и vagrant insecure keypair прописан прямо в kickstart (sshkey).
#
# Запуск (из этого каталога, extensions/molecule/freeipa/packer/):
#   packer init .
#   packer build rocky9.pkr.hcl
#
# Результат — rockylinux9-freeipa-libvirt.box рядом с шаблоном (не коммитится, см. .gitignore).
# Добавить в локальный стор vagrant и указать в extensions/molecule/freeipa/molecule.yml:
#   vagrant box add --name local/rockylinux9-freeipa --provider libvirt rockylinux9-freeipa-libvirt.box
#   # molecule.yml: platforms[].box: local/rockylinux9-freeipa (без box_version — локальный box)
#
# Второй потребитель того же box'а (тот же ks.cfg — теперь с cloud-init, не только vagrant insecure
# keypair) — demo/full-platform/terraform: сырой output-rockylinux9-freeipa/rockylinux9-freeipa.qcow2
# (остаётся на диске благодаря keep_input_artifact у post-processor'а ниже, не удаляется после
# упаковки в .box) используется напрямую как backing-образ VM freeipa, тем же NoCloud/cloud-init
# механизмом, что и debian-based VM стенда — без vagrant-обёртки. См.
# demo/full-platform/terraform/variables.tf (freeipa_base_image_url).

packer {
  required_plugins {
    qemu = {
      version = ">= 1.1.0"
      source  = "github.com/hashicorp/qemu"
    }
    vagrant = {
      version = ">= 1.1.0"
      source  = "github.com/hashicorp/vagrant"
    }
  }
}

variable "vm_name" {
  type    = string
  default = "rockylinux9-freeipa"
}

variable "disk_size" {
  type    = string
  default = "20000M"
}

variable "memory" {
  type    = number
  default = 2048
}

variable "cpus" {
  type    = number
  default = 2
}

# ISO скачан вручную заранее (dl.rockylinux.org не под гео-блокировкой hashicorp, но был
# медленным с этого хоста — реально использовалось зеркало ftp.sh.cvut.cz, см. cache/README
# если появится). iso_checksum — официальный SHA256 из CHECKSUM-файла Rocky 9.8.
source "qemu" "rockylinux9" {
  iso_url      = "cache/rocky9-minimal.iso"
  iso_checksum = "sha256:d338032cd1cdd41c67139f2f71b4c832c8e4a21943106519db9c7137df7a63d4"

  output_directory = "output-${var.vm_name}"
  vm_name          = "${var.vm_name}.qcow2"
  format           = "qcow2"
  disk_size        = var.disk_size
  disk_interface   = "virtio"
  net_device       = "virtio-net"
  memory           = var.memory
  cpus             = var.cpus
  accelerator      = "kvm"
  headless         = true

  # ВАЖНО: accelerator=kvm включает только ускорение исполнения, но НЕ модель CPU — без явного
  # -cpu Packer/QEMU по умолчанию эмулируют "qemu64", а не host passthrough. qemu64 не даёт
  # набор инструкций x86-64-v2 (SSE4.2 и т.п.), обязательный для RHEL9/Rocky9 — без host
  # passthrough ловится kernel panic "Attempted to kill init!" сразу на первых секундах загрузки
  # (тот же сбой, что раньше воспроизводился на официальном rockylinux/9 box с
  # provider_options: {cpu_mode: custom, cpu_model: qemu64}, см. molecule.yml — там это было
  # намеренным экспериментом, здесь — незамеченным дефолтом, поймано реальным прогоном
  # 2026-08-21 через VNC-скриншот зависшей ВМ).
  qemuargs = [
    ["-cpu", "host"]
  ]

  # BIOS-загрузка (SeaBIOS, дефолт — efi_boot не выставлен): ISO Rocky 9 при legacy-загрузке
  # использует isolinux (не grub2), поэтому редактирование параметров ядра — простой <tab>, а не
  # grub'овский 'e'/Ctrl-X. Первая загрузка идёт с CD (Packer сам выставляет boot once=d), после
  # kickstart-установки и reboot — уже с диска (GRUB2 в MBR, поставлен bootloader-командой ks.cfg).
  http_directory = "http"
  boot_wait      = "5s"
  boot_command = [
    "<tab> inst.ks=http://{{ .HTTPIP }}:{{ .HTTPPort }}/ks.cfg<enter>"
  ]

  communicator          = "ssh"
  ssh_username           = "vagrant"
  ssh_private_key_file   = "~/.vagrant.d/insecure_private_key"
  ssh_timeout            = "40m"

  shutdown_command = "sudo shutdown -P now"
  shutdown_timeout = "15m"
}

build {
  sources = ["source.qemu.rockylinux9"]

  # keep_input_artifact: сырой output-rockylinux9-freeipa/rockylinux9-freeipa.qcow2 иначе удаляется
  # post-processor'ом после упаковки в .box (стандартное поведение) — но этот же qcow2 нужен и
  # demo/full-platform/terraform (второй потребитель box'а, напрямую как backing-образ, без
  # vagrant-обёртки — см. terraform/variables.tf, freeipa_base_image_url).
  post-processor "vagrant" {
    output              = "rockylinux9-freeipa-libvirt.box"
    provider_override   = "libvirt"
    compression_level   = 6
    keep_input_artifact = true
  }
}
