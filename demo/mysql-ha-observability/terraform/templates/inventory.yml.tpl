# СГЕНЕРИРОВАНО Terraform (demo/mysql-ha-observability/terraform/inventory.tf) из local.vms —
# см. ADR-0006 §6. Не редактировать руками: правки будут перезаписаны следующим `terraform
# apply`. Переменные ролей (mysql_replication_role, proxysql_*, infra_dns_zones и т.д.) — в
# ../ansible/group_vars/*.yml рядом, не здесь (ADR-0006 §9 — без Vault, но тоже не сюда).
all:
  vars:
    ansible_user: ${ansible_user}
    ansible_ssh_common_args: "-o StrictHostKeyChecking=accept-new"
  children:
    # monitoring_server, docker-оркестратор (ADR-0006 §4 — нужен для Loki+MinIO)
    monitoring_servers:
      hosts:
        monitoring-server:
          ansible_host: ${vms["monitoring-server"].ip}

    # monitoring_agent, systemd-оркестратор на всех хостах с базами/ProxySQL (ADR-0006 §4)
    monitoring_agents:
      hosts:
        mysql-primary:
          ansible_host: ${vms["mysql-primary"].ip}
        mysql-read-replica:
          ansible_host: ${vms["mysql-read-replica"].ip}
        mysql-dr-replica:
          ansible_host: ${vms["mysql-dr-replica"].ip}
        proxysql:
          ansible_host: ${vms["proxysql"].ip}

    # mysql_replication (ADR-0004) — группы совпадают с mysql_replication_role каждого хоста
    mysql_primary:
      hosts:
        mysql-primary: {}
    mysql_read_replica:
      hosts:
        mysql-read-replica: {}
    mysql_dr_replica:
      hosts:
        mysql-dr-replica: {}

    proxysql_hosts:
      hosts:
        proxysql: {}

    infra_dns:
      hosts:
        infra-dns:
          ansible_host: ${vms["infra-dns"].ip}

    # ad hoc, без роли коллекции (ADR-0006 §8)
    load_generator:
      hosts:
        load-generator:
          ansible_host: ${vms["load-generator"].ip}
