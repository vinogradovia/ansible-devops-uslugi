output "vm_ip" {
  description = "IP-адрес VM стенда (то же значение, что в сгенерированном ansible/inventory.yml) — статический, задан переменной var.vm_ip_cidr, не определяется постфактум"
  value       = split("/", var.vm_ip_cidr)[0]
}

output "freeipa_ip" {
  description = "IP-адрес VM freeipa (статический, var.freeipa_ip_cidr)"
  value       = split("/", var.freeipa_ip_cidr)[0]
}
