# СГЕНЕРИРОВАНО Terraform (demo/postgresql-ha-platform/terraform/inventory.tf) из local.vms —
# см. ADR-0006 §6/ADR-0005. Не редактировать руками: правки будут перезаписаны следующим
# `terraform apply`. Переменные ролей — в ../ansible/group_vars/*.yml рядом, не здесь.
all:
  vars:
    ansible_user: ${ansible_user}
    ansible_ssh_common_args: "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
  children:
    # monitoring_server, docker-оркестратор
    monitoring_servers:
      hosts:
        monitoring-server:
          ansible_host: ${vms["monitoring-server"].ip}

    # monitoring_agent, systemd-оркестратор на всех хостах с PostgreSQL/Odyssey (ADR-0006 §4)
    monitoring_agents:
      hosts:
        postgres-primary:
          ansible_host: ${vms["postgres-primary"].ip}
        postgres-read-replica:
          ansible_host: ${vms["postgres-read-replica"].ip}
        postgres-dr-replica:
          ansible_host: ${vms["postgres-dr-replica"].ip}
        odyssey:
          ansible_host: ${vms["odyssey"].ip}

    # postgresql_replication (ADR-0005 §3) — группы совпадают с postgresql_replication_role
    postgresql_primary:
      hosts:
        postgres-primary: {}
    postgresql_read_replica:
      hosts:
        postgres-read-replica: {}
    postgresql_dr_replica:
      hosts:
        postgres-dr-replica: {}

    odyssey_hosts:
      hosts:
        odyssey: {}

    infra_dns:
      hosts:
        infra-dns:
          ansible_host: ${vms["infra-dns"].ip}

    # ad hoc, без роли коллекции (ADR-0006 §8)
    load_generator:
      hosts:
        load-generator:
          ansible_host: ${vms["load-generator"].ip}
