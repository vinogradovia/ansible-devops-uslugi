# СГЕНЕРИРОВАНО Terraform (demo/samba-server/terraform/inventory.tf) из local.vms — см. ADR-0006
# §6. Не редактировать руками: правки будут перезаписаны следующим `terraform apply`. Переменные
# роли (samba_server_*) — в ../ansible/group_vars/*.yml рядом, не здесь (ADR-0006 §9 — без Vault,
# но тоже не сюда).
all:
  vars:
    ansible_user: ${ansible_user}
    ansible_ssh_common_args: "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
  children:
    samba_hosts:
      hosts:
        samba:
          ansible_host: ${vms["samba"].ip}
