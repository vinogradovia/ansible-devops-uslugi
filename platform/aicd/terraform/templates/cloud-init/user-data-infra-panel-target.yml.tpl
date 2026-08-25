#cloud-config
hostname: ${hostname}
fqdn: ${fqdn}
manage_etc_hosts: true

users:
  - name: ${ansible_user}
    groups: [sudo]
    shell: /bin/bash
    sudo: 'ALL=(ALL) NOPASSWD:ALL'
    lock_passwd: true
    ssh_authorized_keys:
%{ for key in ssh_public_keys ~}
      - ${key}
%{ endfor ~}

package_update: true
packages:
  - qemu-guest-agent

runcmd:
  - [systemctl, enable, --now, qemu-guest-agent]
