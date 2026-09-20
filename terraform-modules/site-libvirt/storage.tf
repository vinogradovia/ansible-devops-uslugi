resource "libvirt_pool" "site" {
  name = var.pool_name
  type = "dir"

  target = {
    path = var.pool_path
  }
}

# По одному base-образу на ключ var.base_images — обычно один ("default"), больше одного нужно
# только при разных ОС в одном сайте (см. variables.tf, base_image_key).
resource "libvirt_volume" "base" {
  for_each = var.base_images

  name = "${each.key}-base.qcow2"
  pool = libvirt_pool.site.name

  target = {
    format = {
      type = "qcow2"
    }
    # world-readable: base — backing-файл для дисков ВМ (vms.tf) — без этого QEMU падает
    # "Permission denied" (dynamic_ownership libvirt не применяется к backingStore с
    # type='volume'), тот же приём, что platform/aicd/terraform/storage.tf.
    permissions = {
      mode = "0644"
    }
  }

  create = {
    content = {
      url = each.value
    }
  }
}
