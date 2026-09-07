# Terraform генерирует Ansible-inventory с реальным IP после `terraform apply` — тот же приём,
# что demo/*/terraform/inventory.tf; запуск `ansible-playbook` — ручной, без автотриггера.
resource "local_file" "ansible_inventory" {
  filename = "${path.module}/../ansible/inventory.yml"

  content = templatefile("${path.module}/templates/inventory.yml.tpl", {
    vms                 = local.vms
    ansible_user        = var.ansible_user
    freeipa_ip          = local.freeipa_ip
    postgresql_infra_ip = local.postgresql_infra_ip
  })

  file_permission = "0644"

  depends_on = [libvirt_domain.vm, libvirt_domain.freeipa, libvirt_domain.postgresql_infra]
}
