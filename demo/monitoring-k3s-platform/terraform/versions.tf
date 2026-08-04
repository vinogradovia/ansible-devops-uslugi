# demo/monitoring-k3s-platform — ADR-0006 §1: provisioning через Terraform + libvirt-провайдер
# (dmacvicar/terraform-provider-libvirt), не Vagrant и не голый virt-install. Версия провайдера —
# последний релиз на момент написания (v0.9.8, github.com/dmacvicar/terraform-provider-libvirt/
# releases) — при апгрейде сверяйтесь с CHANGELOG провайдера, `~>` держит только минорную ветку.
terraform {
  required_version = ">= 1.5"

  required_providers {
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = "~> 0.9"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}

provider "libvirt" {
  uri = var.libvirt_uri
}
