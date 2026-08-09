resource "libvirt_pool" "demo" {
  name = var.pool_name
  type = "dir"

  target = {
    path = var.pool_path
  }
}

# Базовый образ скачивается один раз и переиспользуется как backing-том для всех VM
# (libvirt_volume.disk[*].backing_store в vms.tf — copy-on-write, не полная копия на каждую VM).
# Ubuntu 24.04, не Debian 12 — см. variables.tf, base_image_url.
resource "libvirt_volume" "base" {
  name = "ubuntu-24.04-server-cloudimg-amd64-base.qcow2"
  pool = libvirt_pool.demo.name

  target = {
    format = {
      type = "qcow2"
    }
    # world-readable: base — backing-файл для всех per-VM дисков (vms.tf) — без этого QEMU падает
    # "Permission denied" (dynamic_ownership libvirt не применяется к backingStore с type='volume').
    permissions = {
      mode = "0644"
    }
  }

  create = {
    content = {
      url = var.base_image_url
    }
  }
}
