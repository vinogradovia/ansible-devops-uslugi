# Terraform генерирует Ansible-inventory со статическим IP после `terraform apply` — тот же
# приём, что platform/aicd/terraform/inventory.tf; запуск `ansible-playbook` — ручной, без
# автотриггера. В отличие от platform/aicd (DHCP-hosts на libvirt-сети, IP известен только после
# apply), здесь IP статический и известен заранее (var.vm_ip_cidr) — генерация всё равно через
# terraform, чтобы не дублировать значение вручную в двух местах.
resource "local_file" "ansible_inventory" {
  filename = "${path.module}/../ansible/inventory.yml"

  content = templatefile("${path.module}/templates/inventory.yml.tpl", {
    vm_ip               = split("/", var.vm_ip_cidr)[0]
    freeipa_ip          = split("/", var.freeipa_ip_cidr)[0]
    ansible_user        = var.ansible_user
    llm1_ip             = split("/", var.llm1_ip_cidr)[0]
    llm1_ansible_user   = var.llm1_ansible_user
    postgresql_infra_ip = split("/", var.postgresql_infra_ip_cidr)[0]
  })

  file_permission = "0644"

  depends_on = [
    proxmox_virtual_environment_vm.aicd_labs,
    proxmox_virtual_environment_vm.freeipa,
    proxmox_virtual_environment_vm.llm1,
    proxmox_virtual_environment_vm.postgresql_infra,
  ]
}
