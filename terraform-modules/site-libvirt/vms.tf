# Обобщённый вариант паттерна, уже проверенного живым прогоном в platform/aicd/terraform/vms.tf
# (там — одна VM карты `local.vms`, стенд рос органически; здесь — весь список ВМ клиента сразу
# из анкеты, интерфейс var.vms публичный, не локальный).
resource "libvirt_volume" "disk" {
  for_each = var.vms

  name     = "${each.key}.qcow2"
  pool     = libvirt_pool.site.name
  capacity = each.value.disk_gb * 1024 * 1024 * 1024

  target = {
    format = {
      type = "qcow2"
    }
  }

  backing_store = {
    path = libvirt_volume.base[each.value.base_image_key].path
    format = {
      type = "qcow2"
    }
  }
}

resource "libvirt_cloudinit_disk" "vm" {
  for_each = var.vms

  name = "${each.key}-cloudinit"

  meta_data = yamlencode({
    "instance-id"    = each.key
    "local-hostname" = each.key
  })

  user_data = templatefile("${path.module}/templates/cloud-init/user-data.yml.tpl", {
    hostname       = each.key
    fqdn           = "${each.key}.${var.network_domain}"
    ansible_user   = var.ansible_user
    ssh_public_key = trimspace(file(var.ssh_public_key_path))
  })
}

resource "libvirt_volume" "cloudinit" {
  for_each = var.vms

  name = "${each.key}-cloudinit.iso"
  pool = libvirt_pool.site.name

  # Провайдер сам детектирует ISO9660-контент cidata-образа и приводит формат к "iso" —
  # объявление "raw" здесь вызывает "Provider produced inconsistent result after apply"
  # (та же находка, что platform/aicd/terraform/vms.tf).
  target = {
    format = {
      type = "iso"
    }
  }

  create = {
    content = {
      url = libvirt_cloudinit_disk.vm[each.key].path
    }
  }
}

resource "libvirt_domain" "vm" {
  for_each = var.vms

  # name = "<network_name>-<vm>" (не голое each.key) — libvirt-домены живут в ОДНОМ общем
  # host-wide неймспейсе (в отличие от volumes/pools, изолированных per-сайт), см.
  # platform/aicd/terraform/vms.tf.
  name        = "${var.network_name}-${each.key}"
  type        = "kvm"
  vcpu        = each.value.vcpu
  memory      = each.value.memory
  memory_unit = "MiB"
  running     = true
  autostart   = true

  cpu = {
    mode = "host-passthrough"
  }

  # AppArmor per-domain профиль может генерироваться пустым на некоторых хостах — QEMU получает
  # EACCES на backingStore даже при открытых POSIX-правах (тот же риск-профиль, что demo/*,
  # ADR-0006 §9, и platform/aicd/terraform/vms.tf).
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
            pool   = libvirt_pool.site.name
            volume = libvirt_volume.disk[each.key].name
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
              pool   = libvirt_pool.site.name
              volume = libvirt_volume.base[each.value.base_image_key].name
            }
          }
        }
      },
      {
        device = "cdrom"
        source = {
          volume = {
            pool   = libvirt_pool.site.name
            volume = libvirt_volume.cloudinit[each.key].name
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
            network = libvirt_network.site.name
          }
        }
        mac = {
          address = each.value.mac
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
          file   = "/tmp/${var.network_name}-${each.key}-console.log"
          append = "off"
        }
      }
    ]
  }
}
