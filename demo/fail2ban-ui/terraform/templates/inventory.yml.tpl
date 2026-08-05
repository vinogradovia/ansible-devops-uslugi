# СГЕНЕРИРОВАНО Terraform (demo/fail2ban-ui/terraform/inventory.tf) из local.vms —
# см. ADR-0006 §6. Не редактировать руками: правки будут перезаписаны следующим `terraform
# apply`. Переменные роли (fail2ban_ui_*) — в ../ansible/group_vars/*.yml рядом, не здесь
# (ADR-0006 §9 — без Vault, но тоже не сюда).
all:
  vars:
    ansible_user: ${ansible_user}
    ansible_ssh_common_args: "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
  children:
    fail2ban_ui_hosts:
      hosts:
        fail2ban-ui:
          ansible_host: ${vms["fail2ban-ui"].ip}
