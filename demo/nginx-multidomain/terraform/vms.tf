# ADR-0006 §4/§7: единственная VM — демонстрация роли fail2ban_ui (systemd-путь, nginx
# reverse-proxy) с реальным Fail2Ban на том же хосте (apt, ставится в site.yml — роль
# fail2ban_ui сам Fail2Ban не устанавливает, см. roles/fail2ban_ui/README.md).
#
# mac — локально администрируемые адреса (префикс 52:54:00, конвенция QEMU/libvirt), нужны для
# статической DHCP-резервации в network.tf (ips[].dhcp.hosts).
locals {
  vms = {
    nginx-multidomain = {
      vcpu    = 1
      memory  = 1024
      disk_gb = 10
      ip      = "10.66.9.10"
      mac     = "52:54:00:66:09:10"
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
  # объявление "raw" здесь вызывает "Provider produced inconsistent result after apply".
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
  for_each = local.vms

  # name = "<network_name>-<vm>" (не голое each.key) — libvirt-домены живут в ОДНОМ общем
  # host-wide неймспейсе (в отличие от volumes/pools, изолированных per-стенд) — без префикса
  # конфликтует с одноимённой VM другого стенда при параллельном запуске (найдено на
  # demo/monitoring-k3s-platform + demo/postgresql-ha-platform, см. их vms.tf).
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

  # AppArmor per-domain профиль генерируется пустым на этом хосте — QEMU получает EACCES на
  # backingStore (base-образ, storage.tf) даже при полностью открытых POSIX-правах (0644).
  # Тот же осознанно упрощённый риск-профиль демо-стенда, что и в ADR-0006 §9 (без Vault).
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
