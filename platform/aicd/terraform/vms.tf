# Одна VM — K3s single-node, хостит Gitea + Semaphore UI + OpenBao + Authelia + Radar +
# infra-panel + мониторинг (vm/grafana-operator, docs/adr/0017-platform-cicd-default-addons.md) +
# Nexus (кеширующий прокси, docs/adr/0018-internal-caching-proxy.md) Helm-релизами через
# Helmwave. memory: 4096 (изначально) → 6144 (ADR-0017 §4, монитринг) → 10240 (ADR-0018, второй
# раунд — Nexus OSS официально требует 4GB RAM минимум, JVM). Оба раунда — по одной и той же
# причине: нода уже была на 43% реального потребления памяти (metrics-server) без нового
# компонента.
locals {
  vms = {
    cicd = {
      vcpu    = 2
      memory  = 10240
      disk_gb = 40
      ip      = "10.66.14.10"
      mac     = "52:54:00:66:0e:10"
    }
  }
}

resource "libvirt_volume" "disk" {
  for_each = local.vms

  name     = "${each.key}.qcow2"
  pool     = libvirt_pool.platform.name
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
  pool = libvirt_pool.platform.name

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
  # host-wide неймспейсе (в отличие от volumes/pools, изолированных per-стенд), см. demo/*.
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
  # backingStore (base-образ, storage.tf) даже при полностью открытых POSIX-правах (0644). Тот же
  # риск-профиль, что demo/* (ADR-0006 §9).
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
              pool   = libvirt_pool.platform.name
              volume = libvirt_volume.base.name
            }
          }
        }
      },
      {
        device = "cdrom"
        source = {
          volume = {
            pool   = libvirt_pool.platform.name
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
            network = libvirt_network.platform.name
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
