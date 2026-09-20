output "vm_ips" {
  description = "Карта имя ВМ → IP (без маски) — источник для генерации ansible/inventory.yml в корневом модуле клиентского репозитория"
  value = {
    for name, vm in var.vms : name => split("/", vm.ip_cidr)[0]
  }
}
