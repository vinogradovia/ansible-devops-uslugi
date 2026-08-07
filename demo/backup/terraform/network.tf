# ADR-0006 §2: одна плоская сеть на весь стенд.
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
