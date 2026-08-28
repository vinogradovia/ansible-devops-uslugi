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
    freeipa_hosts:
      hosts:
        freeipa:
          ansible_host: ${freeipa_ip}
    # ADR-0015 (Фаза 1) — GPU-нода, второй узел уже существующего k3s aicd-devops-labs-ru, не
    # отдельный кластер (см. ansible/site.yml). ansible_user другой (см. llm1-target.tf) — VM
    # заведена не тем же terraform-циклом, что aicd_labs/freeipa.
    k3s_gpu_agents:
      hosts:
        llm1:
          ansible_host: ${llm1_ip}
          ansible_user: ${llm1_ansible_user}
