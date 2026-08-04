# СГЕНЕРИРОВАНО Terraform (demo/monitoring-k3s-platform/terraform/inventory.tf) из local.vms —
# см. ADR-0006 §6. Не редактировать руками: правки будут перезаписаны следующим `terraform
# apply`. Переменные ролей (monitoring_server_*, monitoring_agent_*) — в
# ../ansible/group_vars/*.yml рядом, не здесь (ADR-0006 §9 — без Vault, но тоже не сюда).
all:
  vars:
    ansible_user: ${ansible_user}
    ansible_ssh_common_args: "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
  children:
    # monitoring_server, k3s-оркестратор (ADR-0007 §6/§11)
    monitoring_servers:
      hosts:
        monitoring-server:
          ansible_host: ${vms["monitoring-server"].ip}

    # monitoring_agent, systemd-оркестратор — единственный экспортёр: node_exporter
    # (group_vars/monitoring_agents.yml), без docker/promtail/специфических сервисов.
    monitoring_agents:
      hosts:
        agent:
          ansible_host: ${vms["agent"].ip}
