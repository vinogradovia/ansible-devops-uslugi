# proxysql

Единая точка подключения к MySQL (writer/reader hostgroups) — DNS-записи `db-write`/`db-read`
указывают на хосты этой роли, ProxySQL сам решает, на какой backend-сервер MySQL маршрутизировать
запрос. Проектные решения — см.
[`docs/adr/0004-mysql-ha-replication-role.md`](../../docs/adr/0004-mysql-ha-replication-role.md),
§6.

**Статус:** пройдена полным `molecule test -s proxysql` (`extensions/molecule/proxysql/`) —
установка, bootstrap admin-интерфейса, синхронизация backend-серверов/query rules/пользователей,
и, главное, реальная маршрутизация трафика через живые backend'ы (`mysql_replication` в роли
primary/read-реплика): `SELECT` уходит на read-реплику, запись — на primary и не падает с
read-only. `idempotence`-шаг сознательно исключён из этого сценария — см. комментарий в
`extensions/molecule/proxysql/molecule.yml` (DELETE+INSERT-синхронизация идемпотентна по
конечному состоянию, но не по `changed`-флагу Ansible).

## Назначение и место среди других ролей

Разворачивается на **отдельных выделенных хостах**, не на серверах MySQL (`roles/mysql_replication`)
и не через `docker` (ADR §6 — не создаём лишнюю зависимость от роли `docker` ради критичного
компонента маршрутизации).

## Hostgroups

- `proxysql_writer_hostgroup` (10, по умолчанию) — primary. Весь трафик, кроме `SELECT`.
- `proxysql_reader_hostgroup` (20, по умолчанию) — read-реплика. `SELECT`-трафик, через
  `proxysql_query_rules`.

**DR-реплика намеренно не входит** в `proxysql_backend_servers` в обычном режиме — ТЗ прямо
запрещает грузить её боевым чтением. Появляется в writer-hostgroup только вручную, в рамках
promote (см. `roles/mysql_replication`, `tasks/promote.yml` и письменную инструкцию
`docs/runbooks/mysql-failover.md`).

## Конфигурация — bootstrap-файл + admin-интерфейс

`/etc/proxysql.cnf` (шаблон `templates/proxysql.cnf.j2`) читается ProxySQL только при первом
старте (пустая admin-БД, credentials, порты). Дальнейшее управление backend-серверами,
query rules и пользователями — декларативно через admin-интерфейс (порт
`proxysql_admin_listen_port`, mysql-протокол, модуль `ansible.mysql.mysql_query`):
`tasks/sync-backend-servers.yml`, `tasks/query-rules.yml`, `tasks/sync-mysql-users.yml`.
Идемпотентность — через полную замену управляемых строк (`DELETE` + `INSERT`), а не точечный
merge, затем `LOAD ... TO RUNTIME` + `SAVE ... TO DISK`.

## Секреты

`proxysql_admin_password`/`proxysql_monitor_password` — без дефолта, роль падает через `assert`
(см. `tasks/assert-required-vars.yml`), значения — из Ansible Vault на уровне inventory (тот же
паттерн, что и в `roles/mysql_replication`, ADR §9).

## Health-check пользователь на backend'ах — забота оператора, не этой роли

`proxysql_monitor_user`/`proxysql_monitor_password` настраивают, каким пользователем ProxySQL
подключается к backend-серверам для мониторинга (`runtime_mysql_servers.status`), но эта роль
**не создаёт** такого пользователя на самих серверах MySQL — так же, как `mysql_replication` не
создаёт приложенческих пользователей (ADR §11, тот же принцип "композиция на уровне
инвентаря/плейбука"). Без него ProxySQL не сможет считать backend ONLINE. Пример SQL, который
нужно выполнить на primary (реплицируется на все реплики):

```sql
CREATE USER 'proxysql_monitor'@'%' IDENTIFIED BY '...';
GRANT REPLICATION CLIENT ON *.* TO 'proxysql_monitor'@'%';
```

(Ровно так это и сделано в `extensions/molecule/proxysql/converge.yml` — как фикстура сценария,
не как часть роли.)

## Пример

Backend-серверы обычно собираются из hostvars групп `mysql_primary`/`mysql_read_replica`
плейбуком-оркестратором (точный способ сборки списка — деталь реализации плейбука, не роли),
а не пишутся руками. Упрощённый пример с уже собранным списком:

```yaml
- hosts: proxysql_hosts
  vars:
    proxysql_backend_servers:
      - hostgroup: "{{ proxysql_writer_hostgroup }}"
        address: "{{ hostvars[groups['mysql_primary'][0]].ansible_host }}"
        port: 3306
      - hostgroup: "{{ proxysql_reader_hostgroup }}"
        address: "{{ hostvars[groups['mysql_read_replica'][0]].ansible_host }}"
        port: 3306
  roles:
    - role: devops.uslugi.proxysql
      proxysql_admin_password: "{{ vault_proxysql_admin_password }}"
      proxysql_monitor_password: "{{ vault_proxysql_monitor_password }}"
      proxysql_mysql_users:
        - username: app
          password: "{{ vault_app_mysql_password }}"
          default_hostgroup: "{{ proxysql_writer_hostgroup }}"
```

## Локальное тестирование (molecule, vagrant/libvirt)

`extensions/molecule/proxysql/` — окружение и общий приём (`ANSIBLE_LIBRARY`, `MOLECULE_BOX`)
идентичны `roles/mysql_replication/README.md`, "Локальное тестирование" — см. её сначала.
Сценарий поднимает три ВМ: `mysql-writer`/`mysql-reader` (роль `mysql_replication` в реальной
GTID-репликации, статические адреса 192.168.57.10-11) + `proxysql-host` (192.168.57.12).
`converge.yml` заводит на writer приложенческого и monitor-пользователя (реплицируются на
reader), `verify.yml` проверяет реальную маршрутизацию через клиентский порт (6033) и статусы
backend'ов через admin-интерфейс (6032):

```bash
molecule test -s proxysql
```

## Вне скоупа

- Балансировка между несколькими read-репликами (сейчас — ровно одна) — hostgroup это уже
  позволяет технически, но политика балансировки не проектировалась.
- RHEL/Rocky (dnf).
