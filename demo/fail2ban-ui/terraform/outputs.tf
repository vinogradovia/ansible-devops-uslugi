output "vm_ips" {
  description = "IP-адреса VM стенда (те же значения, что попадают в сгенерированный ansible/inventory.yml)"
  value       = { for name, vm in local.vms : name => vm.ip }
}
