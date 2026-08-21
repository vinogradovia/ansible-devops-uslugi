# Топология и sizing 8 VM стенда «все компоненты сразу» (см. обсуждение в чате, зафиксировавшее
# план — по прецеденту demo/mysql-ha-platform/terraform/vms.tf: топология нового кейса
# документируется здесь инлайн-комментариями, а не правкой docs/adr/0006-demo-stand.md, которая
# описывает только первый кейс). platform — самая тяжёлая VM: reverse_proxy_traefik (владеет
# сетью "proxy") + monitoring_server (docker, VictoriaMetrics+Grafana+VMAlert+Loki+MinIO) +
# infra_panel + backup_server (Bareos director+storage+catalog+webui) — общий ingress/наблюдение/
# бэкап платформы на одном хосте, как это уже делают demo/mysql-ha-platform (первые три роли) и
# demo/backup (три другие роли) по отдельности. mysql/postgresql — однонодовые (role: primary,
# без реплик — по решению пользователя, чтобы минимизировать число VM, репликационный лаг тут
# демонстрировать нечего). mac — локально администрируемые адреса (префикс 52:54:00, конвенция
# QEMU/libvirt), нужны для статической DHCP-резервации в network.tf (ips[].dhcp.hosts).
locals {
  vms = {
    platform = {
      vcpu    = 3
      memory  = 4608
      disk_gb = 35
      ip      = "10.66.13.10"
      mac     = "52:54:00:66:0d:10"
    }
    mysql = {
      vcpu    = 1
      memory  = 1536
      disk_gb = 15
      ip      = "10.66.13.20"
      mac     = "52:54:00:66:0d:20"
    }
    proxysql = {
      vcpu    = 1
      memory  = 512
      disk_gb = 8
      ip      = "10.66.13.21"
      mac     = "52:54:00:66:0d:21"
    }
    postgresql = {
      vcpu    = 1
      memory  = 1536
      disk_gb = 15
      ip      = "10.66.13.30"
      mac     = "52:54:00:66:0d:30"
    }
    odyssey = {
      vcpu    = 1
      memory  = 512
      disk_gb = 8
      ip      = "10.66.13.31"
      mac     = "52:54:00:66:0d:31"
    }
    infra-dns = {
      vcpu    = 1
      memory  = 512
      disk_gb = 8
      ip      = "10.66.13.40"
      mac     = "52:54:00:66:0d:40"
    }
    nginx-multidomain = {
      vcpu    = 1
      memory  = 1024
      disk_gb = 10
      ip      = "10.66.13.50"
      mac     = "52:54:00:66:0d:50"
    }
    npm = {
      vcpu    = 1
      memory  = 2048
      disk_gb = 15
      ip      = "10.66.13.51"
      mac     = "52:54:00:66:0d:51"
    }
    # Единственная VM стенда не на общем debian-образе — freeipa требует Rocky 9 (см.
    # variables.tf, storage.tf). base = "rocky9" выбирает backing-том в base_volumes ниже;
    # у остальных VM поле не задано — lookup(..., "debian") ниже подставляет дефолт.
    # memory/cpus — минимум по README роли (LDAP+Kerberos KDC+httpd+CA одновременно).
    freeipa = {
      vcpu    = 2
      memory  = 4096
      disk_gb = 20
      ip      = "10.66.13.60"
      mac     = "52:54:00:66:0d:60"
      base    = "rocky9"
    }
  }

  # Волюм-бэкенды по ключу base (см. поле local.vms[*].base) — по умолчанию "debian" (общий
  # backing-образ стенда, storage.tf).
  base_volumes = {
    debian = libvirt_volume.base
    rocky9 = libvirt_volume.freeipa_base
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
    path = local.base_volumes[lookup(each.value, "base", "debian")].path
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
    hostname         = each.key
    fqdn             = "${each.key}.${var.network_domain}"
    ansible_user     = var.ansible_user
    ssh_public_key   = trimspace(file(var.ssh_public_key_path))
    manage_etc_hosts = lookup(each.value, "base", "debian") == "rocky9" ? "false" : "true"
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
# без префикса два стенда с одинаковой ролью хоста не могут существовать одновременно (найдено
# реальным прогоном в demo/mysql-ha-platform, "Failed to define domain... already exists").
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
  # свежие образы (minio/minio в roles/monitoring_server) собраны с этим baseline и падают
  # "Fatal glibc error: CPU does not support x86-64-v2" (найдено реальным прогоном
  # demo/mysql-ha-platform). host-passthrough отдаёт гостю реальные флаги CPU хоста — нормально
  # для однохостового демо-стенда без live-миграции между разным железом.
  cpu = {
    mode = "host-passthrough"
  }

  # AppArmor per-domain профиль генерируется пустым на этом хосте — QEMU получает EACCES на
  # backingStore (base-образ, storage.tf) даже когда POSIX-права полностью открыты (0644,
  # проверено эмпирически в demo/mysql-ha-platform). Отключение label'инга — тот же осознанно
  # упрощённый риск-профиль локального изолированного стенда, что и ADR-0006 §9 (без Vault) — не
  # production-паттерн, не переносить на роли коллекции.
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
        # конкретного диска домена и не применяет к нему dynamic_ownership при старте VM — QEMU
        # получает "Permission denied" на base-образе, хотя сам backing_store у тома
        # (storage.tf/libvirt_volume.disk) уже объявлен на уровне пула.
        backing_store = {
          format = {
            type = "qcow2"
          }
          source = {
            volume = {
              pool   = libvirt_pool.demo.name
              volume = local.base_volumes[lookup(each.value, "base", "debian")].name
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

    # Serial-консоль с логом на диск control-хоста — единственный способ увидеть boot-лог
    # long-lived стенда без графики/vnc (тот же паттерн, что demo/mysql-ha-platform).
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
