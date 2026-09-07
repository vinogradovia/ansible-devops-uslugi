output "vm_ips" {
  description = "IP-адреса VM стенда (те же значения, что в сгенерированном ansible/inventory.yml)"
  value       = { for name, vm in local.vms : name => vm.ip }
}

output "freeipa_ip" {
  description = "IP VM freeipa (статическая DHCP-резервация, freeipa-target.tf)"
  value       = local.freeipa_ip
}

output "postgresql_infra_ip" {
  description = "IP VM postgresql-infra-1 (статическая DHCP-резервация, postgresql-infra-target.tf, ADR-0023)"
  value       = local.postgresql_infra_ip
}
