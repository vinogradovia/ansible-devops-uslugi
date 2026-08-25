output "vm_ips" {
  description = "IP-адреса VM стенда (те же значения, что в сгенерированном ansible/inventory.yml)"
  value       = { for name, vm in local.vms : name => vm.ip }
}
