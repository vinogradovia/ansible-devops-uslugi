# demo/postgresql-ha-platform — ADR-0006 §1 (общий подход демо-стенда) + ADR-0005 (кейс:
# postgresql_replication + odyssey). Тот же провайдер и версия, что и в demo/mysql-ha-platform —
# см. её versions.tf за деталями по dmacvicar/terraform-provider-libvirt 0.9.x (nested-атрибуты,
# не блоки).
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
