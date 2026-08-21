#cloud-config
hostname: ${hostname}
fqdn: ${fqdn}
# false у VM freeipa (vms.tf) намеренно: дефолтный RHEL-шаблон cloud-init (/etc/cloud/templates/
# hosts.redhat.tmpl) маппит hostname на 127.0.0.1/::1 В ДОПОЛНЕНИЕ к любой записи, которую позже
# добавляет сама роль freeipa (freeipa_manage_hosts_entry, self-entry с реальным IP) — три адреса
# на одно имя ломают резолвинг hostname внутри ipa-server-install (get_server_ip_address видит
# несколько кандидатов и падает ScriptError, поймано реальным прогоном на этом стенде). У
# остальных VM (debian, без такой роли) конфликта нет — оставлено true, поведение не меняется.
manage_etc_hosts: ${manage_etc_hosts}

users:
  - name: ${ansible_user}
    # Без groups: [sudo] намеренно — этой группы нет на Rocky/RHEL (там wheel), а sudo: ниже даёт
    # passwordless-доступ напрямую через /etc/sudoers.d независимо от групп — работает
    # одинаково что на debian-based VM стенда, что на VM freeipa (Rocky 9, vms.tf).
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
