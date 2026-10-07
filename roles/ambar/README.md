# ambar

Устанавливает и настраивает [SeaweedFS](https://github.com/seaweedfs/seaweedfs) — S3-совместимое
распределённое файловое хранилище. Заменяет MinIO как backend для Loki, pgBackRest, Qdrant и
других компонентов платформы.

## Назначение

- Установка бинарника SeaweedFS из GitHub Releases (статический Go-бинарник)
- Настройка в роли master-сервера (один узел кластера)
- Настройка в роли volume-server (хранение данных, несколько узлов)
- Настройка в роли S3-gateway (S3-совместимый API)
- Настройка fitness-server (автоматическая балансировка)
- Optional: nginx reverse proxy для S3 API с TLS

## Поддержка ОС

Только Debian/Ubuntu (apt) — аналогично другим ролям коллекции.

## Режимы работы

| Переменная | Описание |
|---|---|
| `ambar_master_mode: true` | Один узел — master server |
| `ambar_volume_mode: true` | Узлы-хранилища (multiple) |
| `ambar_s3_gateway_enabled: true` | S3 API на порту 9000 |
| `ambar_fitness_mode: true` | Балансировка между volume nodes |

Все три флага можно установить одновременно на одном хосте, но архитектурно master обычно
на отдельном узле.

## Пример

### Одноразовый кластер (master + volume + S3) на одном узле:

```yaml
- hosts: ambar_hosts
  roles:
    - role: devops.uslugi.ambar
      ambar_enabled: true
      ambar_master_mode: true
      ambar_volume_mode: true
      ambar_s3_gateway_enabled: true
      ambar_s3_gateway_access_key: "{{ vault_ambar_s3_access_key }}"
      ambar_s3_gateway_secret_key: "{{ vault_ambar_s3_secret_key }}"
      ambar_volume_max: 20  # 20GB per volume server
```

### Production-кластер (master на одном, volume на других):

```yaml
# master-нода
- hosts: ambar_master
  roles:
    - role: devops.uslugi.ambar
      ambar_master_mode: true
      ambar_listen_host: "{{ ansible_default_ipv4.address }}"

# volume-ноды
- hosts: ambar_volumes
  roles:
    - role: devops.uslugi.ambar
      ambar_volume_mode: true
      ambar_volume_max: 50
      ambar_volume_size_unit_mb: 4096
```

## Переменные

Все переменные определены в `defaults/main.yml` с префиксом `ambar_`. Ключевые:

| Переменная | По умолчанию | Описание |
|---|---|---|
| `ambar_enabled` | `false` | выключатель роли |
| `ambar_version` | `3.88` | версия без `v`-префикса |
| `ambar_master_mode` | `false` | режим master-сервера |
| `ambar_volume_mode` | `false` | режим volume-сервера |
| `ambar_s3_gateway_enabled` | `false` | S3 API |
| `ambar_s3_gateway_access_key` | `""` | S3 access key |
| `ambar_s3_gateway_secret_key` | `""` | S3 secret key |
| `ambar_volume_max` | `50` | max GB на volume server |
| `ambar_gc_interval_seconds` | `600` | garbage collection interval |
| `ambar_nginx_reverse_proxy_enabled` | `false` | nginx reverse proxy |

## Идемпотентность

Роль полностью идемпотентна. Повторный прогон не изменяет состояние, если ничего не изменилось.
Поддерживает check mode.

## Мolecule-тестирование

См. `extensions/molecule/ambar/`.

## Вне скоупа

- RHEL/Rocky (dnf) — не поддерживается.
- Kubernetes-развёртывание — только systemd.
- SeaweedFS fidstore (Filer) — не реализован в этой роли.
- Автоматическая настройка кластера (master discovery) — узлы настраиваются вручную через inventory.
