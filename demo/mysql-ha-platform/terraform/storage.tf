resource "libvirt_pool" "demo" {
  name = var.pool_name
  type = "dir"

  target = {
    path = var.pool_path
  }
}

# ADR-0006 §7: базовый образ скачивается один раз и переиспользуется как backing-том для всех VM
# (libvirt_volume.disk[*].backing_store в vms.tf — copy-on-write, не полная копия на каждую VM).
# create.content.url — провайдер сам скачивает и заливает образ в pool (аналог libvirt_volume
# source в версиях провайдера < 0.8, но теперь это nested-атрибут, не отдельный аргумент).
resource "libvirt_volume" "base" {
  name = "debian-12-generic-amd64-base.qcow2"
  pool = libvirt_pool.demo.name

  target = {
    format = {
      type = "qcow2"
    }
    # world-readable: base — backing-файл для всех per-VM дисков (vms.tf), а dynamic_ownership
    # libvirt при старте домена chown'ит только top-level source тома домена, backingStore с
    # type='volume' (в отличие от type='file') в цепочку не попадает — без этого QEMU падает
    # "Permission denied" на файле, реально принадлежащем libvirt-qemu:kvm 0600 (найдено при
    # первом terraform apply).
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
