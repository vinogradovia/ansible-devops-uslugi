# Дочерний модуль не задаёт provider-блок (`provider "libvirt" {}`) — uri подключения
# наследуется от корневого модуля клиентского репозитория, тот же приём, что
# platform/aicd/terraform/versions.tf.
terraform {
  required_providers {
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = "~> 0.9"
    }
  }
}
