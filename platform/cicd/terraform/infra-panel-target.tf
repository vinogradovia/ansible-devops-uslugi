# Отдельная VM — реальный целевой хост для Module infra-panel-pilot (ADR-0014, ROADMAP.md
# пункт 7, «Фаза 5»/platform-controller/README.md, «Не проработано»: раньше
# inventory/infra_panel.ini в platform/gitops указывал на заведомый placeholder 203.0.113.10).
#
# Сознательно НЕ добавлена в local.vms (vms.tf) как ещё один ключ общего for_each — найдено
# реальным прогоном: local.vms/шаблон/DHCP-хосты общие для всех VM стенда, и любое изменение,
# затрагивающее вычисляемое значение (например, список SSH-ключей), заставляет Terraform
# пересоздать cloudinit-диск и саму libvirt-сеть ДЛЯ УЖЕ РАБОТАЮЩЕЙ "cicd" (реальный `tofu plan`
# показал `libvirt_network.platform must be replaced` + `libvirt_cloudinit_disk.vm["cicd"] must
# be replaced`) — риск для живого Gitea/Semaphore/Flux ради добавления второй, независимой VM.
# Полностью отдельные ресурсы ниже гарантируют нулевое пересечение с состоянием "cicd".
#
# IP — обычный DHCP (не через libvirt_network.platform.dhcp.hosts, network.tf, — та же причина
# изоляции от "cicd": не трогать состав списка, из-за которого меняется вычисляемое значение
# самого сетевого ресурса). Статический IP через cloud-init network-config пробовали первым —
# сеть гостя не поднялась вообще (см. комментарий у network_config ниже) — узнаётся постфактум
# через `virsh net-dhcp-leases platform-cicd` по MAC ниже.
#
# Выделенный SSH-ключ (tests/.ssh-pub-keys/id_ed25519_semaphore_infra_panel_target.pub) — для
# Semaphore (приватная часть — в Semaphore Key, не в git), плюс общий admin-ключ control-хоста
# (var.ssh_public_key_path) для ручной диагностики тем же способом, что и "cicd".

locals {
  infra_panel_target_mac = "52:54:00:66:0e:11"
}

resource "libvirt_volume" "infra_panel_target_disk" {
  name     = "infra-panel-target.qcow2"
  pool     = libvirt_pool.platform.name
  capacity = 15 * 1024 * 1024 * 1024

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

resource "libvirt_cloudinit_disk" "infra_panel_target" {
  name = "infra-panel-target-cloudinit"

  meta_data = yamlencode({
    "instance-id"    = "infra-panel-target"
    "local-hostname" = "infra-panel-target"
  })

  user_data = templatefile("${path.module}/templates/cloud-init/user-data-infra-panel-target.yml.tpl", {
    hostname     = "infra-panel-target"
    fqdn         = "infra-panel-target.${var.network_domain}"
    ansible_user = var.ansible_user
    ssh_public_keys = [
      trimspace(file(var.ssh_public_key_path)),
      trimspace(file("${path.module}/../../../tests/.ssh-pub-keys/id_ed25519_semaphore_infra_panel_target.pub")),
    ]
  })

  # Изначально пробовали статический IP через network-config (network-config-static.yml.tpl,
  # см. git-историю) — реальным прогоном обнаружено, что сеть гостя вообще не поднималась (0
  # принятых пакетов на хостовом vnet-интерфейсе спустя несколько минут, тогда как "cicd" с той
  # же базовой картинкой поднимается за секунды на дефолтном DHCP). Без консоли гостя
  # (интерактивный `virsh console`/sudo недоступны в этом окружении) диагностировать точную
  # причину не удалось — откачено на проверенный DHCP-путь, тот же, что у "cicd". IP определяется
  # постфактум через `virsh net-dhcp-leases platform-cicd` по MAC (local.infra_panel_target_mac
  # ниже), не фиксирован заранее.
}

resource "libvirt_volume" "infra_panel_target_cloudinit" {
  name = "infra-panel-target-cloudinit.iso"
  pool = libvirt_pool.platform.name

  target = {
    format = {
      type = "iso"
    }
  }

  create = {
    content = {
      url = libvirt_cloudinit_disk.infra_panel_target.path
    }
  }
}

resource "libvirt_domain" "infra_panel_target" {
  name        = "${var.network_name}-infra-panel-target"
  type        = "kvm"
  vcpu        = 1
  memory      = 1024
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
            volume = libvirt_volume.infra_panel_target_disk.name
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
            volume = libvirt_volume.infra_panel_target_cloudinit.name
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
          address = local.infra_panel_target_mac
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
          file   = "/tmp/${var.network_name}-infra-panel-target-console.log"
          append = "off"
        }
      }
    ]
  }
}
