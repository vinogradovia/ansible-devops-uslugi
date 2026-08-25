# platform/aicd (переименовано из platform/cicd) — новая персистентная платформенная
# инфраструктура (не demo/*, ADR-0006 — демонстрация ролей коллекции клиентам, эфемерные
# одноразовые стенды; этот стенд обслуживает саму разработку коллекции, ROADMAP.md
# «Предлагаемая последовательность работ», пункт 7, Фаза 0). Тот же провайдерский стек, что
# demo/* (dmacvicar/libvirt), для единообразия — не самостоятельное архитектурное решение,
# просто нет причины отличаться.
#
# ВНИМАНИЕ: local.vms (vms.tf), var.pool_name/network_name/network_domain (variables.tf) ниже
# сознательно НЕ переименованы в "aicd" вместе с директорией — эмпирическая проверка
# (изолированная копия state, `tofu plan` после `terraform state mv`) показала, что `name`/`pool`
# у libvirt_pool/libvirt_network/libvirt_volume(×3)/libvirt_domain — ForceNew атрибуты: план на
# переименование этих идентификаторов даёт `7 to destroy, 7 to add` — уничтожает storage pool,
# сеть, базовый образ, диск и сам домен VM целиком (полная потеря Gitea/Semaphore/OpenBao данных
# на единственной живой ноде). `terraform state mv` этого не предотвращает. Эти имена — внутренние
# libvirt-идентификаторы, никому не видны снаружи, поэтому остаются "cicd"/"platform-cicd"
# намеренно — не путать с "platform/aicd" (путь директории) и "aicd.platform" (прикладной домен
# Ingress-хостов/PKI, см. platform/aicd/ansible/site.yml).
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
