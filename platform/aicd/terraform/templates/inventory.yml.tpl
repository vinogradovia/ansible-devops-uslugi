# СГЕНЕРИРОВАНО Terraform (platform/cicd/terraform/inventory.tf) из local.vms — не редактировать
# руками, правки будут перезаписаны следующим `terraform apply`. Переменные роли — в
# ../ansible/group_vars/*.yml рядом, не здесь.
all:
  vars:
    ansible_user: ${ansible_user}
    ansible_ssh_common_args: "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
  children:
    platform_hosts:
      hosts:
        cicd:
          ansible_host: ${vms["cicd"].ip}
    freeipa_hosts:
      hosts:
        freeipa:
          ansible_host: ${freeipa_ip}
    # docs/adr/0023-postgresql-standalone-role.md — standalone PostgreSQL для нужд платформы.
    # Множественное число в имени группы — заведомо может содержать больше одного хоста в будущем
    # (naming convention, ADR-0023 §6), в отличие от singleton-групп вроде freeipa_hosts.
    postgresql_infra_hosts:
      hosts:
        postgresql-infra-1:
          ansible_host: ${postgresql_infra_ip}
