# ADR-0006 §4/§7 (общий подход) + ADR-0005 (кейс: postgresql_replication + odyssey). Sizing —
# тот же профиль "среднее рабочее место", что и в demo/mysql-ha-platform. IP — статические DHCP-
# резервации в libvirt-сети (см. network.tf). mac-адреса используют префикс ...:07:xx (у
# mysql-ha-platform — ...:06:xx), чтобы оба демо-стенда можно было держать поднятыми одновременно
# без конфликта MAC в отдельных libvirt-сетях.
locals {
  vms = {
    monitoring-server = {
      vcpu    = 2
      memory  = 3072
      disk_gb = 20
      ip      = "10.66.7.10"
      mac     = "52:54:00:66:07:10"
    }
    postgres-primary = {
      vcpu    = 1
      memory  = 1536
      disk_gb = 15
      ip      = "10.66.7.21"
      mac     = "52:54:00:66:07:21"
    }
    postgres-read-replica = {
      vcpu    = 1
      memory  = 1536
      disk_gb = 15
      ip      = "10.66.7.22"
      mac     = "52:54:00:66:07:22"
    }
    postgres-dr-replica = {
      vcpu    = 1
      memory  = 1536
      disk_gb = 15
      ip      = "10.66.7.23"
      mac     = "52:54:00:66:07:23"
    }
    odyssey = {
      vcpu    = 1
      memory  = 512
      disk_gb = 8
      ip      = "10.66.7.30"
      mac     = "52:54:00:66:07:30"
    }
    infra-dns = {
      vcpu    = 1
      memory  = 512
      disk_gb = 8
      ip      = "10.66.7.40"
      mac     = "52:54:00:66:07:40"
    }
    load-generator = {
      vcpu    = 1
      memory  = 512
      disk_gb = 8
      ip      = "10.66.7.50"
      mac     = "52:54:00:66:07:50"
    }
  }
}

resource "libvirt_volume" "disk" {
  for_each = local.vms

  name     = "${each.key}.qcow2"
  pool     = libvirt_pool.demo.name
  capacity = each.value.disk_gb * 1024 * 1024 * 1024

  target = {
    format = {
      type = "qcow2"
    }
  }

  backing_store = {
    path = libvirt_volume.base.path
    format = {
      type = "qcow2"
    }
  }
}

resource "libvirt_cloudinit_disk" "vm" {
  for_each = local.vms

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
  for_each = local.vms

  name = "${each.key}-cloudinit.iso"
  pool = libvirt_pool.demo.name

  # Провайдер сам детектирует ISO9660-контент cidata-образа и приводит формат к "iso" —
  # объявление "raw" вызывает "Provider produced inconsistent result after apply".
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

# name = "<network_name>-<vm>" (не голое each.key) — libvirt-домены живут в ОДНОМ общем
# host-wide неймспейсе (в отличие от volumes/pools, у которых своя пер-стендовая изоляция) —
# без префикса два стенда с одинаковой ролью хоста (у всех кейсов есть "monitoring-server")
# не могут существовать одновременно, "Failed to define domain... already exists" (найдено
# реальным прогоном, когда demo/monitoring-k3s-platform и demo/postgresql-ha-platform оказались
# подняты одновременно).
resource "libvirt_domain" "vm" {
  for_each = local.vms

  name        = "${var.network_name}-${each.key}"
  type        = "kvm"
  vcpu        = each.value.vcpu
  memory      = each.value.memory
  memory_unit = "MiB"
  running     = true
  autostart   = true

  # Без явного <cpu> гость не видит x86-64-v2 — свежие образы (minio/minio в roles/
  # monitoring_server) падают "Fatal glibc error: CPU does not support x86-64-v2". См.
  # demo/mysql-ha-platform/terraform/vms.tf, тот же фикс.
  cpu = {
    mode = "host-passthrough"
  }

  # AppArmor per-domain профиль не покрывает backingStore для volume-type источников на этом
  # хосте — QEMU получает EACCES на backing-образе даже при полностью открытых POSIX-правах.
  # Тот же осознанно упрощённый риск-профиль локального демо-стенда, что и в
  # demo/mysql-ha-platform (ADR-0006 §9).
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
            pool   = libvirt_pool.demo.name
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
        # Без явного backing_store здесь libvirt не chown'ит backing-файл в цепочке ДЛЯ ЭТОГО
        # диска домена при dynamic_ownership (только для type='file', не для type='volume'
        # top-level source) — см. demo/mysql-ha-platform/terraform/vms.tf, тот же фикс.
        backing_store = {
          format = {
            type = "qcow2"
          }
          source = {
            volume = {
              pool   = libvirt_pool.demo.name
              volume = libvirt_volume.base.name
            }
          }
        }
      },
      {
        device = "cdrom"
        source = {
          volume = {
            pool   = libvirt_pool.demo.name
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
            network = libvirt_network.demo.name
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

    # Serial-консоль с логом на диск control-хоста — не часть ADR, полезна для отладки boot без
    # графики/vnc. См. demo/mysql-ha-platform/terraform/vms.tf.
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
