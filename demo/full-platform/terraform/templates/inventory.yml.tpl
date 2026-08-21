# СГЕНЕРИРОВАНО Terraform (demo/full-platform/terraform/inventory.tf) из local.vms — см.
# ADR-0006 §6. Не редактировать руками: правки будут перезаписаны следующим `terraform apply`.
# Переменные ролей — в ../ansible/group_vars/*.yml рядом, не здесь (ADR-0006 §9 — без Vault, но
# тоже не сюда).
all:
  vars:
    ansible_user: ${ansible_user}
    ansible_ssh_common_args: "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
  children:
    # reverse_proxy_traefik + monitoring_server(docker) + infra_panel + backup_server — общий
    # ingress/наблюдение/бэкап платформы на одном хосте (см. vms.tf).
    platform_hosts:
      hosts:
        platform:
          ansible_host: ${vms["platform"].ip}

    # monitoring_agent, systemd-оркестратор — на всех VM, кроме platform (сам источник метрик,
    # не цель).
    monitoring_agents:
      hosts:
        mysql:
          ansible_host: ${vms["mysql"].ip}
        proxysql:
          ansible_host: ${vms["proxysql"].ip}
        postgresql:
          ansible_host: ${vms["postgresql"].ip}
        odyssey:
          ansible_host: ${vms["odyssey"].ip}
        infra-dns:
          ansible_host: ${vms["infra-dns"].ip}
        nginx-multidomain:
          ansible_host: ${vms["nginx-multidomain"].ip}
        npm:
          ansible_host: ${vms["npm"].ip}

    # mysql_replication (ADR-0004), однонодовый — без read_replica/dr_replica.
    mysql_primary:
      hosts:
        mysql: {}

    proxysql_hosts:
      hosts:
        proxysql:
          ansible_host: ${vms["proxysql"].ip}

    # postgresql_replication (ADR-0005), однонодовый — без read_replica/dr_replica.
    postgresql_primary:
      hosts:
        postgresql: {}

    odyssey_hosts:
      hosts:
        odyssey:
          ansible_host: ${vms["odyssey"].ip}

    infra_dns:
      hosts:
        infra-dns:
          ansible_host: ${vms["infra-dns"].ip}

    nginx_multidomain_hosts:
      hosts:
        nginx-multidomain:
          ansible_host: ${vms["nginx-multidomain"].ip}

    npm_hosts:
      hosts:
        npm:
          ansible_host: ${vms["npm"].ip}

    # freeipa (ADR-0011) — единственная VM стенда на Rocky 9, не входит в monitoring_agents (роль
    # monitoring_agent в этой коллекции ориентирована на apt/Debian, не проверена на RHEL — не
    # тянем непроверенную комбинацию в демо).
    freeipa_hosts:
      hosts:
        freeipa:
          ansible_host: ${vms["freeipa"].ip}
