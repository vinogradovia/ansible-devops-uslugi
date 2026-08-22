# platform/cicd — новая персистентная платформенная инфраструктура (не demo/*, ADR-0006 —
# демонстрация ролей коллекции клиентам, эфемерные одноразовые стенды; этот стенд обслуживает
# саму разработку коллекции, ROADMAP.md «Предлагаемая последовательность работ», пункт 7, Фаза 0).
# Тот же провайдерский стек, что demo/* (dmacvicar/libvirt), для единообразия — не самостоятельное
# архитектурное решение, просто нет причины отличаться.
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
