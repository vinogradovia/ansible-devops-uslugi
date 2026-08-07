# СГЕНЕРИРОВАНО Terraform (demo/backup/terraform/inventory.tf) из local.vms — см. ADR-0006 §6. Не
# редактировать руками: правки будут перезаписаны следующим `terraform apply`. Переменные ролей
# (backup_server_*/backup_agent_*) — в ../ansible/group_vars/*.yml рядом, не здесь (ADR-0006 §9 —
# без Vault, но тоже не сюда).
#
# client_a/client_b — дочерние группы backup_agent_clients (не отдельные top-level группы) —
# дают каждому клиенту свой backup_agent_client_name/password (group_vars/client_a.yml,
# group_vars/client_b.yml) с гарантированным приоритетом над общими group_vars/
# backup_agent_clients.yml (если появятся) — тот же принцип вложенности групп, что per-host
# group_vars/mysql_read_replica.yml и т.п. в demo/mysql-ha-platform.
all:
  vars:
    ansible_user: ${ansible_user}
    ansible_ssh_common_args: "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
  children:
    backup_servers:
      hosts:
        backup-server:
          ansible_host: ${vms["backup-server"].ip}

    backup_agent_clients:
      children:
        client_a:
          hosts:
            client-a:
              ansible_host: ${vms["client-a"].ip}
        client_b:
          hosts:
            client-b:
              ansible_host: ${vms["client-b"].ip}
