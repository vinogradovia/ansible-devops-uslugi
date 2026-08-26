#cloud-config
hostname: ${hostname}
fqdn: ${fqdn}
# false намеренно (тот же приём, что demo/full-platform/terraform/templates/cloud-init/user-data.yml.tpl):
# дефолтный RHEL-шаблон cloud-init маппит hostname на 127.0.0.1/::1 в ДОПОЛНЕНИЕ к записи, которую
# позже добавляет сама роль freeipa (freeipa_manage_hosts_entry) — несколько адресов на одно имя
# ломают резолвинг hostname внутри ipa-server-install.
manage_etc_hosts: false

users:
  - name: ${ansible_user}
    # Без groups: [sudo] намеренно — этой группы нет на Rocky/RHEL (там wheel); sudo: ниже даёт
    # passwordless-доступ напрямую через /etc/sudoers.d независимо от групп.
    shell: /bin/bash
    sudo: 'ALL=(ALL) NOPASSWD:ALL'
    lock_passwd: true
    ssh_authorized_keys:
      - ${ssh_public_key}

package_update: true
packages:
  - qemu-guest-agent

runcmd:
  - [systemctl, enable, --now, qemu-guest-agent]
