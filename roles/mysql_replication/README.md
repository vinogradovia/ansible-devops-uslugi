# mysql_replication

Роль отказоустойчивости MySQL: adopt существующего primary или fresh install на репликах,
GTID-репликация "звездой" (обе реплики напрямую от primary), `read_only`/`super_read_only` на
репликах, физические бэкапы (xtrabackup/mariabackup) в S3, ручной promote DR-реплики. Проектные
решения и обоснование — см.
[`docs/adr/0004-mysql-ha-replication-role.md`](../../docs/adr/0004-mysql-ha-replication-role.md).

**Статус:** реплика/primary-логика (adopt, fresh install, GTID-репликация, read_only) пройдена
полным `molecule test -s mysql_replication` (create → prepare → converge → idempotence → verify →
destroy, все зелёные) — последовательно на Debian 12 и на Ubuntu 24.04 (см. "Локальное
тестирование" ниже) — включая функциональную проверку, что тестовая запись с primary реально
доезжает до обеих реплик за секунды. Бэкапы (xtrabackup/rclone/S3) и `promote.yml` — вне покрытия
этого сценария (нужен реальный S3-эндпоинт и второй запуск с `--tags mysql_replication_promote`
соответственно), проверялись только `ansible-lint`, не живым прогоном.

## Назначение

Не разворачивает точку подключения (DNS/ProxySQL) — это роль `proxysql` + расширение `infra_dns`
(ADR §6). `mysql_replication` — только то, что выполняется на самих серверах MySQL.

## Инвентарная модель

Три группы (ADR §3):

- `mysql_primary` — ровно один хост, `mysql_replication_role: primary`.
- `mysql_read_replica` — тот же ДЦ, что и primary, `mysql_replication_role: read_replica`.
- `mysql_dr_replica` — другой ДЦ Selectel, `mysql_replication_role: dr_replica`.

Задавайте `mysql_replication_role` в `group_vars` соответствующей группы, а не поштучно в
hostvars.

## Discovery версии (важно для порядка плеев)

На primary роль **не переустанавливает** MySQL (adopt-режим, ADR §2) — вместо этого читает
версию уже установленного сервера в runtime (`detect-existing-instance.yml`,
`mysql_replication_discovered_version`). Реплики должны получить ту же версию для fresh install.

**Плейбук-оркестратор обязан выполнить play на `mysql_primary` до play на
`mysql_read_replica`/`mysql_dr_replica`** в рамках одного запуска, и передать версию явно:

```yaml
- hosts: mysql_primary
  roles:
    - devops.uslugi.mysql_replication

- hosts: mysql_read_replica:mysql_dr_replica
  vars:
    mysql_replication_target_version: >-
      {{ hostvars[groups['mysql_primary'][0]].mysql_replication_discovered_version }}
  roles:
    - devops.uslugi.mysql_replication
```

## Секреты

Ansible Vault на уровне inventory (ADR §9, первый прецедент в коллекции):

```bash
ansible-vault encrypt group_vars/mysql_primary/vault.yml
```

Переменные без дефолта, роль падает через `assert`, если не заданы (см.
`tasks/assert-required-vars.yml`): `mysql_replication_server_id` (на каждом хосте, обязан быть
уникальным), `mysql_replication_repl_password`, и (если включены бэкапы)
`mysql_replication_backup_s3_access_key`/`_secret_key`.

## Шифрование трафика репликации между ДЦ

Роль **не поднимает VPN** и не настраивает MySQL-native SSL — трафик идёт через уже
существующий WireGuard/IPsec-туннель между ДЦ (ADR §5).
`mysql_replication_primary_host` **обязан** указывать на адрес primary внутри этой приватной
сети, не на публичный IP — роль этого не проверяет автоматически.

## Рестарт на adopt-primary

Правка `server_id`/GTID/binlog на уже работающем primary требует рестарта MySQL. Это боевая
база — рестарт не выполняется автоматически (`mysql_replication_allow_restart: false` по
умолчанию, ADR §2). Выставляйте `true` только на время согласованного окна:

```bash
ansible-playbook -i inventory.yml mysql-primary.yml -e mysql_replication_allow_restart=true
```

## Ручное переключение (promote DR-реплики)

Задачи спрятаны за тегами, никогда не выполняются в обычном прогоне (ADR §7):

```bash
ansible-playbook -i inventory.yml mysql-replicas.yml \
    --tags mysql_replication_promote --limit <dr-replica-host>
```

Это только техническая часть — полная письменная инструкция на русском (переключение, обратное
переключение, восстановление из копии) размещается отдельно, в `docs/runbooks/` (ADR §7), и
должна содержать эту команду буквально.

## Бэкапы

`mysql_replication_backup_enabled: true` на хосте с ролью
`mysql_replication_backup_source_role` (по умолчанию `dr_replica`, ADR §8) — физический бэкап
через `xtrabackup`/`mariabackup`, ежедневно через systemd-таймер, выгрузка в S3-совместимое
хранилище через `rclone`, ретеншн:
`mysql_replication_backup_retention_{daily,weekly,monthly}` (по умолчанию 14/4/6).

Метрика успешности пишется в `mysql_replication_backup_metrics_textfile_path` — путь должен
совпадать с textfile-каталогом `node_exporter` из `monitoring_agent` на этом же хосте
(композиция на уровне инвентаря/плейбука, не meta-зависимость — ADR §11).

## Пример

```yaml
- hosts: mysql_primary
  roles:
    - role: devops.uslugi.mysql_replication
      mysql_replication_role: primary
      mysql_replication_server_id: 1
      mysql_replication_repl_password: "{{ vault_mysql_repl_password }}"

- hosts: mysql_dr_replica
  roles:
    - role: devops.uslugi.mysql_replication
      mysql_replication_role: dr_replica
      mysql_replication_server_id: 3
      mysql_replication_primary_host: 10.20.30.10   # адрес primary внутри межДЦ VPN
      mysql_replication_repl_password: "{{ vault_mysql_repl_password }}"
      mysql_replication_backup_enabled: true
      mysql_replication_backup_s3_endpoint: "https://s3.selcdn.ru"
      mysql_replication_backup_s3_bucket: "mysql-backups"
      mysql_replication_backup_s3_access_key: "{{ vault_backup_s3_access_key }}"
      mysql_replication_backup_s3_secret_key: "{{ vault_backup_s3_secret_key }}"
      mysql_replication_rclone_checksum: "sha256:..."
```

## Локальное тестирование (molecule, vagrant/libvirt)

ADR §10: этот сценарий (`extensions/molecule/mysql_replication/`, driver `vagrant`, провайдер
`libvirt`) — единственный в коллекции, не использующий `driver: docker`, т.к. полноценная
проверка репликации между несколькими systemd-инстансами MySQL требует настоящих ВМ, а не
контейнеров (аналогичное обоснование — ADR-0002 §8).

Настройка окружения (один раз на хосте разработчика/CI):

```bash
# Vagrant + провайдер libvirt
sudo apt install -y qemu-kvm libvirt-daemon-system vagrant
vagrant plugin install vagrant-libvirt

# python-зависимости molecule (dev-группа Poetry, molecule-plugins[vagrant] уже в pyproject.toml)
poetry install

# Проверка, что libvirt доступен без sudo (группа libvirt)
virsh list --all
```

**Известная несовместимость molecule 26.x / molecule-plugins[vagrant] 25.8:** без дополнительной
переменной окружения `create`/`destroy` падают с `couldn't resolve module/action 'vagrant'` —
модуль `vagrant` из `molecule_plugins.vagrant.modules` не попадает в путь поиска модулей
Ansible автоматически (в отличие от driver'а `docker`). Обходится явным `ANSIBLE_LIBRARY`:

```bash
export ANSIBLE_LIBRARY="$(poetry run python -c 'import molecule_plugins.vagrant, os; print(os.path.join(os.path.dirname(molecule_plugins.vagrant.__file__), "modules"))')"
```

Сценарий поднимает три ВМ (primary/read_replica/dr_replica) со статическими адресами
192.168.56.10-12 (приватная сеть). `converge.yml` прогоняет обе ветки: primary — adopt
(`prepare.yml` заранее ставит MySQL напрямую через apt и кладёт тестовые "боевые" данные, минуя
роль, чтобы проверить, что роль их не стирает), реплики — fresh install целевой версии,
обнаруженной на primary. `verify.yml` проверяет реальный `SHOW REPLICA STATUS`,
`read_only`/`super_read_only`, отказ записи на реплику и то, что тестовая строка, вставленная на
primary, реально доезжает до обеих реплик:

```bash
molecule test -s mysql_replication
```

**Проверка на нескольких дистрибутивах — последовательно, не параллельно.** `box` в
`molecule.yml` параметризован через `MOLECULE_BOX` (тот же приём, что `MOLECULE_DOCKER_COMMAND`
в `nginx_multidomain`/`reverse_proxy_npm`) — в моменте существует только один набор из трёх ВМ.
Прогнать оба поддерживаемых дистрибутива (ADR-0002 §4) — два отдельных вызова, каждый
самостоятельно проходит полный цикл `create...destroy`:

```bash
molecule test -s mysql_replication                                    # Debian 12 (по умолчанию)
MOLECULE_BOX=cloud-image/ubuntu-24.04 molecule test -s mysql_replication  # Ubuntu 24.04 noble
```

Box — совместимый с libvirt-провайдером (например `generic/debian12`/`cloud-image/ubuntu-24.04`
с Vagrant Cloud), **не** `geerlingguy/docker-debian12-ansible`, который собран только под
docker-провайдер. Ubuntu 26.04 (Resolute Racoon) не поддерживается: `repo.mysql.com` ещё не
публикует под него пакеты (нет каталога `resolute` в
`https://repo.mysql.com/apt/ubuntu/dists/`) — внешнее ограничение, не баг роли.

## Вне скоупа

- RHEL/Rocky (dnf).
- Автоматический failover — исключено ТЗ, см. ADR.
- Шифрование бэкапов at rest в S3.
- Поднятие самого WireGuard/IPsec-туннеля между ДЦ.
