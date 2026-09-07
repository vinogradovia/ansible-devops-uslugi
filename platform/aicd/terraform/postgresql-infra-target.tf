# docs/adr/0023-postgresql-standalone-role.md — standalone (не HA) PostgreSQL для нужд платформы
# (litellm/grafana/и т.п.). Отдельный ресурс, НЕ добавлен в local.vms (vms.tf) — та же причина,
# что уже задокументирована в freeipa-target.tf: local.vms/шаблон cloud-init/DHCP-хосты общие для
# всех VM стенда, и любое изменение вычисляемого значения (новый ключ карты) заставляет Terraform
# пересоздать cloudinit-диск и саму libvirt-сеть ДЛЯ УЖЕ РАБОТАЮЩЕЙ "cicd". Полностью отдельные
# ресурсы ниже гарантируют нулевое пересечение с состоянием "cicd".
#
# Обычный Debian-образ (base, storage.tf) — тот же, что "cicd", НЕ Rocky9-образ freeipa. Роль
# postgresql — Debian/Ubuntu-only (PGDG apt), см. roles/postgresql/README.md.
#
# Статический IP через ту же DHCP-резервацию, что freeipa (ansible-managed inventory нужен
# заранее известный IP, см. обоснование в freeipa-target.tf) — не обычный DHCP, как
# infra-panel-target.tf (та VM управляется Semaphore, не этим ansible).

locals {
  postgresql_infra_mac = "52:54:00:66:0e:13"
  postgresql_infra_ip  = "10.66.14.13"
}

resource "null_resource" "postgresql_infra_dhcp_reservation" {
  depends_on = [libvirt_network.platform]

  provisioner "local-exec" {
    command = <<-EOT
      virsh -c ${var.libvirt_uri} net-update ${var.network_name} delete ip-dhcp-host \
        "<host mac='${local.postgresql_infra_mac}' ip='${local.postgresql_infra_ip}' name='postgresql-infra-1'/>" --live --config 2>/dev/null
      virsh -c ${var.libvirt_uri} net-update ${var.network_name} add ip-dhcp-host \
        "<host mac='${local.postgresql_infra_mac}' ip='${local.postgresql_infra_ip}' name='postgresql-infra-1'/>" --live --config
    EOT
  }
}

resource "libvirt_volume" "postgresql_infra_disk" {
  name     = "postgresql-infra-1.qcow2"
  pool     = libvirt_pool.platform.name
  capacity = 30 * 1024 * 1024 * 1024

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

resource "libvirt_cloudinit_disk" "postgresql_infra" {
  name = "postgresql-infra-1-cloudinit"

  meta_data = yamlencode({
    "instance-id"    = "postgresql-infra-1"
    "local-hostname" = "postgresql-infra-1"
  })

  user_data = templatefile("${path.module}/templates/cloud-init/user-data.yml.tpl", {
    hostname       = "postgresql-infra-1"
    fqdn           = "postgresql-infra-1.${var.network_domain}"
    ansible_user   = var.ansible_user
    ssh_public_key = trimspace(file(var.ssh_public_key_path))
  })
}

resource "libvirt_volume" "postgresql_infra_cloudinit" {
  name = "postgresql-infra-1-cloudinit.iso"
  pool = libvirt_pool.platform.name

  target = {
    format = {
      type = "iso"
    }
  }

  create = {
    content = {
      url = libvirt_cloudinit_disk.postgresql_infra.path
    }
  }
}

resource "libvirt_domain" "postgresql_infra" {
  depends_on = [null_resource.postgresql_infra_dhcp_reservation]

  name        = "${var.network_name}-postgresql-infra-1"
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
            volume = libvirt_volume.postgresql_infra_disk.name
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
            volume = libvirt_volume.postgresql_infra_cloudinit.name
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
          address = local.postgresql_infra_mac
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
          file   = "/tmp/${var.network_name}-postgresql-infra-1-console.log"
          append = "off"
        }
      }
    ]
  }
}
