# Отдельная persistent VM — freeipa, единый каталог пользователей для Authelia (ADR-0013 §1).
#
# Сознательно НЕ добавлена в local.vms (vms.tf) как ещё один ключ общего for_each — та же причина,
# что уже задокументирована в infra-panel-target.tf: local.vms/шаблон cloud-init/DHCP-хосты общие
# для всех VM стенда, и любое изменение вычисляемого значения (новый ключ карты, новый шаблон)
# заставляет Terraform пересоздать cloudinit-диск и саму libvirt-сеть ДЛЯ УЖЕ РАБОТАЮЩЕЙ "cicd"
# (реальный `tofu plan` на infra-panel-target показал `libvirt_network.platform must be replaced`).
# Полностью отдельные ресурсы ниже гарантируют нулевое пересечение с состоянием "cicd".
#
# В отличие от infra-panel-target (обычный DHCP, IP узнаётся постфактум через
# `virsh net-dhcp-leases` — годится, потому что этой VM управляет Semaphore, а не этот ansible),
# freeipa должна быть в ansible-managed inventory (роль freeipa запускается тем же site.yml) —
# нужен заранее известный IP. Добавить статическую запись через network.tf (dhcp.hosts) означало
# бы то же самое пересоздание сети — вместо этого статическая DHCP-резервация заводится ВНЕ
# Terraform-состояния сети, императивным `virsh net-update ... add ip-dhcp-host` (null_resource,
# выполняется один раз при создании, Terraform не отслеживает и не пересоздаёт это на каждом
# apply — стандартное поведение provisioner без triggers). delete-then-add в одной команде —
# идемпотентность на случай повторного создания null_resource (например, после taint).

locals {
  freeipa_mac = "52:54:00:66:0e:12"
  freeipa_ip  = "10.66.14.12"
}

resource "null_resource" "freeipa_dhcp_reservation" {
  depends_on = [libvirt_network.platform]

  provisioner "local-exec" {
    command = <<-EOT
      virsh -c ${var.libvirt_uri} net-update ${var.network_name} delete ip-dhcp-host \
        "<host mac='${local.freeipa_mac}' ip='${local.freeipa_ip}' name='freeipa'/>" --live --config 2>/dev/null
      virsh -c ${var.libvirt_uri} net-update ${var.network_name} add ip-dhcp-host \
        "<host mac='${local.freeipa_mac}' ip='${local.freeipa_ip}' name='freeipa'/>" --live --config
    EOT
  }
}

resource "libvirt_volume" "freeipa_disk" {
  name     = "freeipa.qcow2"
  pool     = libvirt_pool.platform.name
  capacity = 20 * 1024 * 1024 * 1024

  target = {
    format = {
      type = "qcow2"
    }
  }

  backing_store = {
    path = libvirt_volume.freeipa_base.path
    format = {
      type = "qcow2"
    }
  }
}

resource "libvirt_cloudinit_disk" "freeipa" {
  name = "freeipa-cloudinit"

  meta_data = yamlencode({
    "instance-id"    = "freeipa"
    "local-hostname" = "freeipa"
  })

  user_data = templatefile("${path.module}/templates/cloud-init/user-data-freeipa.yml.tpl", {
    hostname       = "freeipa"
    fqdn           = "freeipa.${var.network_domain}"
    ansible_user   = var.ansible_user
    ssh_public_key = trimspace(file(var.ssh_public_key_path))
  })
}

resource "libvirt_volume" "freeipa_cloudinit" {
  name = "freeipa-cloudinit.iso"
  pool = libvirt_pool.platform.name

  target = {
    format = {
      type = "iso"
    }
  }

  create = {
    content = {
      url = libvirt_cloudinit_disk.freeipa.path
    }
  }
}

resource "libvirt_domain" "freeipa" {
  depends_on = [null_resource.freeipa_dhcp_reservation]

  name        = "${var.network_name}-freeipa"
  type        = "kvm"
  vcpu        = 2
  memory      = 4096
  memory_unit = "MiB"
  running     = true
  autostart   = true

  cpu = {
    mode = "host-passthrough"
  }

  sec_label = [
    {
      type = "none"
    }
  ]

  os = {
    type = "hvm"
  }

  devices = {
    disks = [
      {
        device = "disk"
        source = {
          volume = {
            pool   = libvirt_pool.platform.name
            volume = libvirt_volume.freeipa_disk.name
          }
        }
        target = {
          dev = "vda"
          bus = "virtio"
        }
        driver = {
          name = "qemu"
          type = "qcow2"
        }
        backing_store = {
          format = {
            type = "qcow2"
          }
          source = {
            volume = {
              pool   = libvirt_pool.platform.name
              volume = libvirt_volume.freeipa_base.name
            }
          }
        }
      },
      {
        device = "cdrom"
        source = {
          volume = {
            pool   = libvirt_pool.platform.name
            volume = libvirt_volume.freeipa_cloudinit.name
          }
        }
        target = {
          dev = "sda"
          bus = "sata"
        }
        driver = {
          name = "qemu"
          type = "raw"
        }
      }
    ]

    interfaces = [
      {
        source = {
          network = {
            network = libvirt_network.platform.name
          }
        }
        mac = {
          address = local.freeipa_mac
        }
        model = {
          type = "virtio"
        }
      }
    ]

    consoles = [
      {
        target = {
          type = "serial"
        }
        log = {
          file   = "/tmp/${var.network_name}-freeipa-console.log"
          append = "off"
        }
      }
    ]
  }
}
