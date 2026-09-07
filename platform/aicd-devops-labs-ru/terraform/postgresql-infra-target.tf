# docs/adr/0023-postgresql-standalone-role.md — standalone (не HA) PostgreSQL для нужд платформы
# (litellm/grafana/и т.п.). Отдельный ресурс (не добавлена в общий for_each, если бы такой был у
# этого окружения) — тот же принцип, что freeipa-target.tf/llm1-target.tf: полностью независимые
# ресурсы, чтобы правки под postgresql-infra-1 не задевали состояние уже работающих VM.
#
# Клонируется из того же Ubuntu-шаблона, что aicd_labs (var.proxmox_template_vmid, VMID 9000) —
# НЕ Rocky9-шаблон freeipa (VMID 9001), НЕ import существующей VM, как llm1.
resource "proxmox_virtual_environment_vm" "postgresql_infra" {
  name      = var.postgresql_infra_vm_name
  node_name = var.proxmox_node

  clone {
    vm_id = var.proxmox_template_vmid
    full  = true
  }

  cpu {
    cores = var.postgresql_infra_vcpu
    # Обязательно явный тип — дефолт provider'а ("qemu64"/"kvm64") не поддерживает x86-64-v2,
    # свежий glibc в современных пакетах падает с "Fatal glibc error" (тот же баг, что уже нашли
    # для llm1/aicd_labs при деплое LiteLLM, см. vm.tf).
    type = "x86-64-v2-AES"
  }

  memory {
    dedicated = var.postgresql_infra_memory
  }

  disk {
    datastore_id = var.proxmox_datastore_id
    interface    = "scsi0"
    size         = var.postgresql_infra_disk_gb
  }

  network_device {
    bridge = var.network_bridge
  }

  agent {
    enabled = true
  }

  initialization {
    vendor_data_file_id = "local:snippets/allow-password.yml"

    ip_config {
      ipv4 {
        address = var.postgresql_infra_ip_cidr
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
