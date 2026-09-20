output "vm_ips" {
  description = "Карта имя ВМ → IP — источник для генерации ansible/inventory.yml в корневом модуле клиентского репозитория"
  value = {
    for name, vm in var.vms : name => vm.ip
  }
}
