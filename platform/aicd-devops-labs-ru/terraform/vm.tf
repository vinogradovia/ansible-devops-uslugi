# Одна VM — K3s single-node, тот же состав (OpenBao + Gitea + Semaphore UI + Flux + Radar), что
# platform/aicd, клонированная из готового cloud-init-шаблона Ubuntu 24.04 (VMID 9000, уже
# подготовлен пользователем на этом Proxmox-сервере — не создаётся этим terraform).
resource "proxmox_virtual_environment_vm" "aicd_labs" {
  name      = var.vm_name
  node_name = var.proxmox_node

  clone {
    vm_id = var.proxmox_template_vmid
    full  = true
  }

  cpu {
    cores = var.vcpu
  }

  memory {
    dedicated = var.memory
  }

  # scsi0/local-lvm/virtio-scsi-pci — те же, что у шаблона (проверено GET
  # .../qemu/9000/config), size переопределяет унаследованный от шаблона маленький базовый диск
  # (2252M) полноценным диском стенда.
  disk {
    datastore_id = var.proxmox_datastore_id
    interface    = "scsi0"
    size         = var.disk_gb
  }

  network_device {
    bridge = var.network_bridge
  }

  # qemu-guest-agent, скорее всего, уже есть в образе (современный cloud image Ubuntu) —
  # безвредно включить даже если его нет, provider не блокирует apply на нём при статическом IP
  # ниже (в отличие от DHCP-сценариев, где agent нужен, чтобы узнать реальный IP).
  agent {
    enabled = true
  }

  initialization {
    # vendor_data_file_id сохраняет существующий cicustom-сниппет шаблона
    # (local:snippets/allow-password.yml, найден в GET .../qemu/9000/config) — без явного
    # указания provider перезаписал бы cloud-init диск (ide2) только тем, что описано в этом
    # блоке, потеряв то, что настраивал этот сниппет на самом шаблоне.
    vendor_data_file_id = "local:snippets/allow-password.yml"

    ip_config {
      ipv4 {
        address = var.vm_ip_cidr
        gateway = var.vm_gateway
      }
    }

    user_account {
      username = var.ansible_user
      keys     = [trimspace(file(var.ssh_public_key_path))]
    }
  }

  operating_system {
    type = "l26"
  }
}
