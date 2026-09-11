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
      # Выделенный ключ для Semaphore (docs/adr/0023-postgresql-standalone-role.md §7,
      # tests/.ssh-pub-keys/id_ed25519_semaphore_postgresql_infra_devops_labs_ru.pub, приватная
      # часть — Semaphore Key, не в git) — тот же приём, что infra-panel-target.tf. Добавлен уже
      # на живую VM вручную (append в authorized_keys, без пересоздания) — этот блок фиксирует
      # желаемое состояние на будущее (пересоздание/повторный tofu apply).
      keys = [
        trimspace(file(var.ssh_public_key_path)),
        trimspace(file("${path.module}/../../../tests/.ssh-pub-keys/id_ed25519_semaphore_postgresql_infra_devops_labs_ru.pub")),
      ]
    }
  }

  operating_system {
    type = "l26"
  }
}
