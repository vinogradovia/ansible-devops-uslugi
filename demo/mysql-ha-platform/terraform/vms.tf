# ADR-0006 §4/§7: топология и sizing 7 VM стенда ("среднее рабочее место" — 8 vCPU/~9 ГБ RAM
# суммарно). monitoring-server — самая тяжёлая VM (VictoriaMetrics + Grafana + VMAlert + Loki +
# MinIO, §5). mac — локально администрируемые адреса (префикс 52:54:00, конвенция QEMU/libvirt),
# нужны для статической DHCP-резервации в network.tf (ips[].dhcp.hosts) — единственный способ
# зафиксировать IP в этой версии провайдера (нет domain-level "addresses", см. network.tf).
locals {
  vms = {
    monitoring-server = {
      vcpu    = 2
      memory  = 3072
      disk_gb = 20
      ip      = "10.66.6.10"
      mac     = "52:54:00:66:06:10"
    }
    mysql-primary = {
      vcpu    = 1
      memory  = 1536
      disk_gb = 15
      ip      = "10.66.6.21"
      mac     = "52:54:00:66:06:21"
    }
    mysql-read-replica = {
      vcpu    = 1
      memory  = 1536
      disk_gb = 15
      ip      = "10.66.6.22"
      mac     = "52:54:00:66:06:22"
    }
    mysql-dr-replica = {
      vcpu    = 1
      memory  = 1536
      disk_gb = 15
      ip      = "10.66.6.23"
      mac     = "52:54:00:66:06:23"
    }
    proxysql = {
      vcpu    = 1
      memory  = 512
      disk_gb = 8
      ip      = "10.66.6.30"
      mac     = "52:54:00:66:06:30"
    }
    infra-dns = {
      vcpu    = 1
      memory  = 512
      disk_gb = 8
      ip      = "10.66.6.40"
      mac     = "52:54:00:66:06:40"
    }
    load-generator = {
      vcpu    = 1
      memory  = 512
      disk_gb = 8
      ip      = "10.66.6.50"
      mac     = "52:54:00:66:06:50"
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

# libvirt_cloudinit_disk сам по себе только рендерит ISO ЛОКАЛЬНО (path — путь на диске
# control-хоста, см. `tofu providers schema`); чтобы диск был доступен домену, его нужно залить в
# pool отдельным libvirt_volume (create.content.url = path сгенерированного ISO) — паттерн из
# официального примера провайдера.
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
  # объявление "raw" здесь вызывает "Provider produced inconsistent result after apply"
  # (несовпадение с тем, что провайдер реально пишет в state после создания).
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

  # Без явного <cpu> libvirt/QEMU даёт гостю урезанную дефолтную модель без флагов x86-64-v2 —
  # свежие образы (minio/minio RELEASE.2025-09-07 в roles/monitoring_server) собраны с этим
  # baseline и падают "Fatal glibc error: CPU does not support x86-64-v2" (найдено реальным
  # прогоном site.yml — контейнер s3 был в CrashLoop). host-passthrough отдаёт гостю реальные
  # флаги CPU хоста — нормально для однохостового демо-стенда без live-миграции между разным
  # железом.
  cpu = {
    mode = "host-passthrough"
  }

  # AppArmor per-domain профиль генерируется пустым (без сгенерированного .files-include) на
  # этом хосте — QEMU получает EACCES на backingStore (base-образ, storage.tf) даже когда
  # POSIX-права полностью открыты (0644, проверено эмпирически). Отключение label'инга —
  # тот же осознанно упрощённый риск-профиль локального изолированного стенда, что и в
  # ADR-0006 §9 (без Vault) — не production-паттерн, не переносить на роли коллекции.
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
        # Без явного backing_store здесь libvirt не знает про base-образ в цепочке этого
        # конкретного диска домена и не применяет к нему dynamic_ownership при старте VM —
        # QEMU получает "Permission denied" на ubuntu-24.04-server-cloudimg-amd64-base.qcow2, хотя сам
        # backing_store у тома (storage.tf/libvirt_volume.disk) уже объявлен на уровне пула.
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

    # Serial-консоль с логом на диск control-хоста — не часть ADR-0006, добавлено при отладке
    # первого boot (AppArmor EACCES, см. sec_label выше). Оставлено и для дальнейшей
    # эксплуатации: единственный способ увидеть boot-лог long-lived стенда без графики/vnc.
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
