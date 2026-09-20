# Дочерний модуль не задаёт provider-блок (`provider "proxmox" {}`) — конфигурация
# (PROXMOX_VE_ENDPOINT/API_TOKEN/INSECURE) наследуется от корневого модуля клиентского
# репозитория, тот же приём, что platform/aicd-devops-labs-ru/terraform/versions.tf.
terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.66"
    }
  }
}
