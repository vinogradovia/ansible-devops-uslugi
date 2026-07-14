# postgresql_replication

Роль отказоустойчивости PostgreSQL: adopt существующего primary или fresh install на репликах,
физическая streaming-репликация "звездой" (обе реплики напрямую от primary) под управлением
`repmgr`, физические бэкапы (`pgBackRest`) в S3, ручной promote read-/DR-реплики. Проектные решения
и обоснование — см.
[`docs/adr/0005-postgresql-ha-replication-role.md`](../../docs/adr/0005-postgresql-ha-replication-role.md).

**Статус:** реализована, покрытие molecule — см. `extensions/molecule/postgresql_replication/`.

## Назначение

Не разворачивает точку подключения (DNS/Odyssey) — это роль `odyssey` + расширение `infra_dns`
(ADR §6). `postgresql_replication` — только то, что выполняется на самих серверах PostgreSQL.

## Инвентарная модель

Три группы (ADR §3):

- `postgresql_primary` — ровно один хост, `postgresql_replication_role: primary`.
- `postgresql_read_replica` — тот же ДЦ, что и primary, `postgresql_replication_role:
  read_replica`. **Опциональна** — группа может быть пустой.
- `postgresql_dr_replica` — другой ДЦ Selectel, `postgresql_replication_role: dr_replica`.

Задавайте `postgresql_replication_role` в `group_vars` соответствующей группы, а не поштучно в
hostvars.

Готовый пример плейбука-оркестратора (тот же состав плеев, что и ниже в этом разделе) —
`examples/playbooks/postgresql-replicas.yml`.

## Discovery версии (важно для порядка плеев)

На primary роль **не переустанавливает** PostgreSQL (adopt-режим, ADR §2) — вместо этого читает
версию уже установленного кластера в runtime (`detect-existing-instance.yml`, через
`pg_lsclusters`, не через версию бинарника — на одном хосте Debian-пакетирование допускает
несколько параллельных версий). Реплики должны получить ту же версию для fresh install —
физическая репликация работает только между одинаковыми мажорными версиями PostgreSQL.

**Плейбук-оркестратор обязан выполнить play на `postgresql_primary` до play на
`postgresql_read_replica`/`postgresql_dr_replica`** в рамках одного запуска, и передать версию
явно:

```yaml
- hosts: postgresql_primary
  roles:
    - devops.uslugi.postgresql_replication

- hosts: postgresql_read_replica:postgresql_dr_replica
  vars:
    postgresql_replication_target_version: >-
      {{ hostvars[groups['postgresql_primary'][0]].postgresql_replication_discovered_version }}
  roles:
    - devops.uslugi.postgresql_replication
```

## Секреты

Ansible Vault на уровне inventory (ADR §9, тот же паттерн, что и в `mysql_replication`):

```bash
ansible-vault encrypt group_vars/postgresql_primary/vault.yml
```

Переменные без дефолта, роль падает через `assert`, если не заданы (см.
`tasks/assert-required-vars.yml`): `postgresql_replication_node_id` (на каждом хосте, обязан быть
уникальным — требование repmgr), `postgresql_replication_repmgr_password`,
`postgresql_replication_repl_password`, и (если включены бэкапы)
`postgresql_replication_backup_s3_access_key`/`_secret_key`.

## Шифрование трафика репликации между ДЦ

Роль **не поднимает VPN** и не настраивает PostgreSQL-native SSL — трафик идёт через уже
существующий WireGuard/IPsec-туннель между ДЦ (ADR §5).
`postgresql_replication_primary_host`/`postgresql_replication_advertise_host` **обязаны**
указывать на адрес внутри этой приватной сети, не на публичный IP — роль этого не проверяет
автоматически.

## Рестарт на adopt-primary

Правка `wal_level`/`shared_preload_libraries=repmgr`/`listen_addresses` на уже работающем primary
требует рестарта PostgreSQL. Это боевая база — рестарт не выполняется автоматически
(`postgresql_replication_allow_restart: false` по умолчанию, ADR §2). Выставляйте `true` только на
время согласованного окна:

```bash
ansible-playbook -i inventory.yml postgresql-primary.yml -e postgresql_replication_allow_restart=true
```

pg_hba.conf применяется через reload (не требует рестарта, гейт не действует).

## Ручное переключение (promote read-/DR-реплики)

Задачи спрятаны за тегами, никогда не выполняются в обычном прогоне (ADR §7). В отличие от
`mysql_replication`, где promote ограничен строго DR-репликой, здесь допустима и read-реплика:

```bash
ansible-playbook -i inventory.yml postgresql-replicas.yml \
    --tags postgresql_replication_promote --limit <replica-host>
```

Это только техническая часть — полная письменная инструкция на русском (переключение, обратное
переключение, восстановление из копии) — `docs/runbooks/postgresql-failover.md` (ADR §7).

Molecule-сценарий (см. ниже) покрывает эту логику последним шагом `verify.yml`: убеждается, что
promote на primary отклоняется assert'ом, и реально промоутит DR-реплику (`repmgr standby
promote` напрямую через `tasks_from: promote`, в обход тегов), проверяя выход из recovery-режима
и запись после promote.

## Бэкапы

`postgresql_replication_backup_enabled: true` на хосте с ролью
`postgresql_replication_backup_source_role` (по умолчанию `dr_replica`, ADR §8) — физический бэкап
через `pgBackRest`, ежедневно через systemd-таймер, выгрузка в S3-совместимое хранилище встроенным
S3-driver'ом pgBackRest (не `rclone`, в отличие от `mysql_replication` — у `pgBackRest` уже есть
нативная интеграция), ретеншн через нативные политики `repo1-retention-full`/`repo1-retention-diff`
(по умолчанию 2/6).

Если источник бэкапа — реплика (значение по умолчанию), роль включает
`archive_mode=always` именно на этом хосте (не `on` — standby в recovery-режиме с `archive_mode=on`
не архивирует WAL вообще, тонкость PostgreSQL). На остальных узлах `archive_mode` выключен, чтобы
не копить недоставленные WAL-сегменты там, где `pgBackRest`-стanza не инициализирована.

Метрика успешности пишется в `postgresql_replication_backup_metrics_textfile_path` — путь должен
совпадать с textfile-каталогом `node_exporter` из `monitoring_agent` на этом же хосте (композиция
на уровне инвентаря/плейбука, не meta-зависимость — ADR §11).

## Пример

```yaml
- hosts: postgresql_primary
  roles:
    - role: devops.uslugi.postgresql_replication
      postgresql_replication_role: primary
      postgresql_replication_node_id: 1
      postgresql_replication_repl_password: "{{ vault_postgresql_repl_password }}"
      postgresql_replication_repmgr_password: "{{ vault_postgresql_repmgr_password }}"

- hosts: postgresql_dr_replica
  roles:
    - role: devops.uslugi.postgresql_replication
      postgresql_replication_role: dr_replica
      postgresql_replication_node_id: 3
      postgresql_replication_primary_host: 10.20.30.10   # адрес primary внутри межДЦ VPN
      postgresql_replication_repl_password: "{{ vault_postgresql_repl_password }}"
      postgresql_replication_repmgr_password: "{{ vault_postgresql_repmgr_password }}"
      postgresql_replication_backup_enabled: true
      postgresql_replication_backup_s3_endpoint: "https://s3.selcdn.ru"
      postgresql_replication_backup_s3_bucket: "postgresql-backups"
      postgresql_replication_backup_s3_access_key: "{{ vault_backup_s3_access_key }}"
      postgresql_replication_backup_s3_secret_key: "{{ vault_backup_s3_secret_key }}"
```

## Локальное тестирование (molecule, vagrant/libvirt)

По аналогии с `mysql_replication` (ADR §10) — `extensions/molecule/postgresql_replication/`,
driver `vagrant`, провайдер `libvirt`. Настройка окружения и обход известной проблемы
`ANSIBLE_LIBRARY` — см. `CLAUDE.md`, раздел «Molecule-тесты», и `roles/mysql_replication/README.md`
(идентично для этой роли).

```bash
export ANSIBLE_LIBRARY="$(dirname "$(poetry run python3 -c 'import molecule_plugins.vagrant as m; print(m.__file__)')")/modules"
poetry run molecule test -s postgresql_replication
```

## Вне скоупа

- RHEL/Rocky (dnf).
- Автоматический failover — исключено (repmgrd не поднимается, ADR §4).
- Шифрование бэкапов at rest в S3.
- Поднятие самого WireGuard/IPsec-туннеля между ДЦ.
