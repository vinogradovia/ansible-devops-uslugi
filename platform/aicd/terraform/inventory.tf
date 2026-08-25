# Terraform генерирует Ansible-inventory с реальным IP после `terraform apply` — тот же приём,
# что demo/*/terraform/inventory.tf; запуск `ansible-playbook` — ручной, без автотриггера.
resource "local_file" "ansible_inventory" {
  filename = "${path.module}/../ansible/inventory.yml"

  content = templatefile("${path.module}/templates/inventory.yml.tpl", {
    vms          = local.vms
    ansible_user = var.ansible_user
  })

  file_permission = "0644"

  depends_on = [libvirt_domain.vm]
}
