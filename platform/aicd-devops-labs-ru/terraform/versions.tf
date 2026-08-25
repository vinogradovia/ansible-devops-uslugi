# platform/aicd-devops-labs-ru — второе, независимое окружение того же стека, что platform/aicd
# (см. этот же комментарий в platform/aicd/terraform/versions.tf), но на Proxmox VE вместо
# libvirt (пользователь предоставил доступ к своему Proxmox-серверу, у первого стенда его не
# было) — поэтому провайдерский стек здесь другой: bpg/proxmox вместо dmacvicar/libvirt, без
# аналогов libvirt_pool/libvirt_network (плоская физическая LAN хоста, не изолированная NAT-сеть,
# которую создавал сам terraform для libvirt-стенда) и без infra-panel-target.tf (специфика
# dev-стенда platform-controller, не часть общего стека).
#
# Аутентификация Proxmox API — ТОЛЬКО через переменные окружения (PROXMOX_VE_ENDPOINT,
# PROXMOX_VE_API_TOKEN, PROXMOX_VE_INSECURE=true — самоподписанный сертификат хоста), см. README.md
# рядом. Токен не должен появляться ни в одном .tf/.tfvars-файле — они коммитятся в git.
terraform {
  required_version = ">= 1.5"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.66"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}

# endpoint/api_token/insecure сознательно не заданы здесь — провайдер сам читает их из
# PROXMOX_VE_ENDPOINT/PROXMOX_VE_API_TOKEN/PROXMOX_VE_INSECURE (см. README.md).
provider "proxmox" {}
