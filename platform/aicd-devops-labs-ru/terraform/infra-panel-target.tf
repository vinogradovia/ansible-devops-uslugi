# docs/adr/0014-platform-controller-architecture.md — отдельная VM, реальный целевой хост для
# первого пилотного Module этого окружения (infra-panel-pilot), тот же выбор роли, что
# platform/aicd/terraform/infra-panel-target.tf. Сознательно НЕ добавлена в общий for_each (такого
# здесь и нет — каждая дополнительная VM этого окружения уже отдельный ресурс, см.
# freeipa-target.tf/llm1-target.tf/postgresql-infra-target.tf) — тот же принцип изоляции
# состояния: правки под pilot target не должны задевать уже работающие VM.
#
# Клонируется из того же Ubuntu-шаблона, что aicd_labs/postgresql_infra (var.proxmox_template_vmid,
# VMID 9000) — НЕ Rocky9-шаблон freeipa (VMID 9001). Статический IP (var.infra_panel_target_ip_cidr)
# — та же плоская LAN, что остальные VM этого окружения, в отличие от первого стенда (libvirt DHCP
# + постфактум virsh net-dhcp-leases) здесь IP известен заранее, как у freeipa/llm1/postgresql_infra.
#
# Два SSH-ключа в initialization.user_account: общий admin-ключ control-хоста (для ручной
# диагностики, тот же приём, что остальные VM) + выделенный ключ для Semaphore
# (tests/.ssh-pub-keys/id_ed25519_semaphore_infra_panel_target_devops_labs_ru.pub, приватная часть
# — отдельный Semaphore Key этого стенда, не в git) — не переиспользует ключ первого стенда
# (platform/aicd), разные Semaphore-инстансы.
resource "proxmox_virtual_environment_vm" "infra_panel_target" {
  name      = var.infra_panel_target_vm_name
  node_name = var.proxmox_node

  clone {
    vm_id = var.proxmox_template_vmid
    full  = true
  }

  cpu {
    cores = var.infra_panel_target_vcpu
    # Тот же обязательный явный тип, что у остальных VM этого окружения (см. vm.tf) — дефолт
    # provider'а ("qemu64") не поддерживает x86-64-v2, современные пакеты (Docker Engine, glibc)
    # падают без него.
    type = "x86-64-v2-AES"
  }

  memory {
    dedicated = var.infra_panel_target_memory
  }

  disk {
    datastore_id = var.proxmox_datastore_id
    interface    = "scsi0"
    size         = var.infra_panel_target_disk_gb
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
        address = var.infra_panel_target_ip_cidr
        gateway = var.vm_gateway
      }
    }

    user_account {
      username = var.ansible_user
      keys = [
        trimspace(file(var.ssh_public_key_path)),
        trimspace(file("${path.module}/../../../tests/.ssh-pub-keys/id_ed25519_semaphore_infra_panel_target_devops_labs_ru.pub")),
      ]
    }
  }

  operating_system {
    type = "l26"
  }
}
