resource "libvirt_pool" "platform" {
  name = var.pool_name
  type = "dir"

  target = {
    path = var.pool_path
  }
}

resource "libvirt_volume" "base" {
  name = "debian-12-generic-amd64-base.qcow2"
  pool = libvirt_pool.platform.name

  target = {
    format = {
      type = "qcow2"
    }
    # world-readable: base — backing-файл для диска VM (vms.tf) — без этого QEMU падает
    # "Permission denied" (dynamic_ownership libvirt не применяется к backingStore с type='volume'),
    # тот же приём, что demo/*/terraform/storage.tf.
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

# Второй base-образ — только для VM freeipa (ADR-0013 §1). file:// вместо https:// у debian-образа
# выше — источник локальный (собственная сборка Packer), тот же приём, что
# demo/full-platform/terraform/storage.tf.
resource "libvirt_volume" "freeipa_base" {
  name = "rockylinux9-freeipa-base.qcow2"
  pool = libvirt_pool.platform.name

  target = {
    format = {
      type = "qcow2"
    }
    permissions = {
      mode = "0644"
    }
  }

  create = {
    content = {
      url = "file://${abspath("${path.module}/${var.freeipa_base_image_path}")}"
    }
  }
}
