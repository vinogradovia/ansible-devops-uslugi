# demo/full-platform — ADR-0006 §1: provisioning через Terraform + libvirt-провайдер
# (dmacvicar/terraform-provider-libvirt), не Vagrant и не голый virt-install. Версия провайдера —
# та же, что во всех остальных стендах demo/* — при апгрейде сверяйтесь с CHANGELOG провайдера,
# `~>` держит только минорную ветку.
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
