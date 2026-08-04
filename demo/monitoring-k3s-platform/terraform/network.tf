# ADR-0006 §2: одна плоская сеть на весь стенд.
#
# provider dmacvicar/libvirt >= 0.9 почти 1:1 зеркалирует libvirt network XML через
# nested_type-атрибуты (не блоки, как в более старых версиях < 0.8) — см. `tofu providers schema
# -json`. IP-адреса VM (locals.vms в vms.tf) — статические DHCP-резервации (ips[].dhcp.hosts,
# ключ по MAC), а не cloud-init network-config: гостю не нужен нестандартный сетевой конфиг
# поверх generic cloud image, провайдер прописывает mac↔ip прямо в dnsmasq-конфиге сети.
resource "libvirt_network" "demo" {
  name      = var.network_name
  autostart = true

  forward = {
    mode = "nat"
  }

  domain = {
    name = var.network_domain
  }

  dns = {
    enable = "yes"
  }

  ips = [
    {
      address = cidrhost(var.network_cidr, 1)
      netmask = cidrnetmask(var.network_cidr)

      dhcp = {
        ranges = [
          {
            start = cidrhost(var.network_cidr, 100)
            end   = cidrhost(var.network_cidr, 200)
          }
        ]

        hosts = [for name, vm in local.vms : {
          mac  = vm.mac
          ip   = vm.ip
          name = name
        }]
      }
    }
  ]
}
