# СГЕНЕРИРОВАНО Terraform (platform/aicd-devops-labs-ru/terraform/inventory.tf) — не редактировать
# руками, правки будут перезаписаны следующим `terraform apply`. Переменные роли — в
# ../ansible/group_vars/*.yml рядом, не здесь.
all:
  vars:
    ansible_user: ${ansible_user}
    ansible_ssh_common_args: "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
  children:
    platform_hosts:
      hosts:
        aicd-labs:
          ansible_host: ${vm_ip}
