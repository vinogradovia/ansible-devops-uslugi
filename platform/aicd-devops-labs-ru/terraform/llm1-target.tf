# ADR-0015 (Фаза 1) — GPU-нода `llm1`, второй узел уже существующего k3s-кластера
# platform/aicd-devops-labs-ru (не отдельный кластер, см. docs/adr/0015-ai-agent-platform-architecture.md
# §10 и docs/Requirements Specification/agent-stack-k3s.md). Изоляция агентной нагрузки от уже
# работающих там Gitea/Semaphore/OpenBao/Authelia — через taint узла + RuntimeClass, а не через
# отдельный control-plane (см. ansible/site.yml, секция k3s_gpu_agents).
#
# В отличие от aicd_labs/freeipa выше — этот ресурс НЕ создаёт новую VM, он ПОДКЛЮЧАЕТ уже
# существующую (GPU passthrough настроен пользователем вручную на Proxmox, ОС внутри — чистая, без
# NVIDIA driver/toolkit/k3s):
#
#   terraform import proxmox_virtual_environment_vm.llm1 pve/105
#
# Все атрибуты, отражающие реальное железо/passthrough (cpu/memory/disk/network_device/hostpci/
# vga/serial_device/bios/machine/agent/initialization/scsi_hardware/boot_order/startup) — под
# lifecycle.ignore_changes. Это НАМЕРЕННО: единственная цель этого ресурса — чтобы tofu знал о
# существовании VM (id для будущих ссылок, IP для ansible inventory), а не управлял её
# конфигурацией. GPU passthrough (hostpci0) настроен вручную под конкретный физический слот этого
# Proxmox-хоста — malformed diff здесь (например, из-за неточно списанного значения) на реальном
# apply рискует отцепить GPU у VM. Значения переменных ниже — дословно с живого
# `GET /nodes/pve/qemu/105/config` на момент реализации (не изменяем, не "улучшаем" при импорте:
# например, bios=ovmf без efi_disk0 в реальном конфиге — не наша забота на этом этапе).
resource "proxmox_virtual_environment_vm" "llm1" {
  name      = var.llm1_vm_name
  node_name = var.proxmox_node
  vm_id     = var.llm1_vm_id

  cpu {
    cores   = var.llm1_cores
    sockets = 1
  }

  memory {
    dedicated = var.llm1_memory
  }

  bios          = "ovmf"
  machine       = "q35"
  scsi_hardware = "virtio-scsi-pci"
  boot_order    = ["scsi0"]

  disk {
    datastore_id = var.llm1_disk_datastore_id
    interface    = "scsi0"
    size         = var.llm1_disk_gb
    ssd          = true
    discard      = "on"
  }

  network_device {
    bridge      = var.llm1_network_bridge
    mac_address = var.llm1_mac_address
  }

  # GPU passthrough — x-vga=1 в реальном конфиге означает, что карта используется и как основной
  # видеовывод, поэтому отдельного vga ниже нет виртуального дисплея (type = "none").
  hostpci {
    device = "hostpci0"
    id     = var.llm1_hostpci_id
    xvga   = true
  }

  vga {
    type = "none"
  }

  serial_device {
    device = "socket"
  }

  # Реальный конфиг не содержит ключа "agent" — гостевой агент не включён (в отличие от
  # aicd_labs/freeipa выше, где agent.enabled = true).
  agent {
    enabled = false
  }

  startup {
    up_delay = 120
  }

  initialization {
    datastore_id        = var.llm1_disk_datastore_id
    interface           = "ide2"
    vendor_data_file_id = "local:snippets/allow-password.yml"

    dns {
      domain  = "devops-labs.ru"
      servers = ["10.10.10.104"]
    }

    ip_config {
      ipv4 {
        address = var.llm1_ip_cidr
        gateway = var.vm_gateway
      }
    }

    # Реальная VM авторизует ещё два сторонних ключа (ноутбуки), заведённых не через этот
    # terraform — не переносим их сюда буквально (initialization целиком под ignore_changes ниже,
    # так что это не приведёт к их удалению при apply), достаточно ключа, которым управляет весь
    # остальной репозиторий.
    user_account {
      username = var.llm1_ansible_user
      keys     = [trimspace(file(var.ssh_public_key_path))]
    }
  }

  operating_system {
    type = "l26"
  }

  lifecycle {
    ignore_changes = [
      cpu,
      memory,
      bios,
      machine,
      scsi_hardware,
      boot_order,
      disk,
      network_device,
      hostpci,
      vga,
      serial_device,
      agent,
      startup,
      initialization,
      operating_system,
    ]
  }
}
