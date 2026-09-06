# ADR-0013 §1 — persistent freeipa, единый каталог пользователей для Authelia. Тот же принцип,
# что platform/aicd/terraform/freeipa-target.tf — отдельный ресурс (не переиспользует
# aicd_labs-специфичные переменные), клонируется из ОТДЕЛЬНОГО Rocky 9 шаблона (VMID 9001,
# подготовлен пользователем — freeipa-server пакетом для Ubuntu/Debian не существует).
#
# В отличие от platform/aicd (DHCP-резервация через null_resource+virsh, IP узнаётся постфактум)
# — здесь, как и у aicd_labs выше, статический IP (var.freeipa_ip_cidr, плоская физическая LAN,
# не изолированная сеть terraform) — известен заранее, без дополнительных ухищрений.
#
# vendor_data_file_id основной VM (allow-password.yml) сознательно НЕ переиспользуется здесь —
# это cicustom-сниппет, привязанный к шаблону 9000 (Ubuntu), про его применимость к новому,
# отдельно подготовленному шаблону 9001 (Rocky 9) ничего не известно; initialization.user_account
# ниже задаёт доступ обычным для provider способом, без предположений о шаблоне.
resource "proxmox_virtual_environment_vm" "freeipa" {
  name      = var.freeipa_vm_name
  node_name = var.proxmox_node

  clone {
    vm_id = var.proxmox_freeipa_template_vmid
    full  = true
  }

  cpu {
    cores = var.freeipa_vcpu
    # Дефолт provider'а без явного type — "qemu64", в котором нет SSE4.2/x86-64-v2 — ядро Rocky
    # Linux 9 требует эту микроархитектуру как минимум и не грузится вообще (пустой serial0,
    # зависание на "Still creating..." — падение происходит до инициализации консоли).
    #
    # Уточнение (2026-09-06): предположение ниже было неверным — "у aicd_labs (Ubuntu) той же
    # проблемы нет" не потому, что Ubuntu иммунна, а потому что раньше на aicd_labs просто не
    # запускалось ничего со свежим glibc, требующим x86-64-v2. Деплой LiteLLM (свежий glibc в
    # образе) упал с той же "Fatal glibc error" — см. vm.tf, cpu.type там теперь тоже явный.
    type = "x86-64-v2-AES"
  }

  memory {
    dedicated = var.freeipa_memory
  }

  disk {
    datastore_id = var.proxmox_datastore_id
    interface    = "scsi0"
    size         = var.freeipa_disk_gb
  }

  network_device {
    bridge = var.network_bridge
  }

  agent {
    enabled = true
  }

  initialization {
    ip_config {
      ipv4 {
        address = var.freeipa_ip_cidr
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
