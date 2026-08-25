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
