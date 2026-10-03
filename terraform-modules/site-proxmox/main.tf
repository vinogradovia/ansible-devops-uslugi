# Обобщённый вариант паттерна, уже проверенного живым прогоном в
# platform/aicd-devops-labs-ru/terraform/vm.tf — там на каждую VM свой явный resource-блок
# (стенд рос органически, по одной VM за раз), здесь VM объявляются все сразу списком из анкеты
# клиента, поэтому for_each по карте уместен: это один и тот же тип ресурса на одном и том же
# провайдере, не смешение разных облаков (для этого — выбор модуля site-proxmox/site-libvirt
# целиком, см. корневой README клиентского репозитория).
resource "proxmox_virtual_environment_vm" "this" {
  for_each = var.vms

  name      = each.key
  node_name = each.value.node

  clone {
    vm_id = each.value.template_vmid
    full  = true
  }

  cpu {
    cores = each.value.cores
    type  = each.value.cpu_type
  }

  memory {
    dedicated = each.value.memory
  }

  disk {
    datastore_id = each.value.datastore_id
    interface    = "scsi0"
    size         = each.value.disk_gb
  }

  network_device {
    bridge = each.value.network_bridge
  }

  agent {
    enabled = true
  }

  initialization {
    # Без явного datastore_id провайдер дефолтит cloud-init диск на "local-lvm" независимо от
    # того, где лежит основной disk{} блока выше — на хостах без LVM (например, wave/proxnode1,
    # см. terraform-modules/site-proxmox/README.md) apply падает: такого стораджа не существует.
    datastore_id        = each.value.datastore_id
    vendor_data_file_id = each.value.vendor_data_file_id

    ip_config {
      ipv4 {
        address = each.value.ip_cidr
        gateway = each.value.gateway
      }
    }

    user_account {
      username = var.ansible_user
      keys     = [for p in var.ssh_public_key_paths : trimspace(file(p))]
    }
  }

  operating_system {
    type = "l26"
  }
}
