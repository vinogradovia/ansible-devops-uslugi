# postgresql

Устанавливает и настраивает **standalone** (не HA) PostgreSQL из официального репозитория PGDG:
движок + TLS (самоподписанный сертификат) + базовый `postgresql.conf` (`listen_addresses`, `port`).
Не разворачивает ничего в docker (обычный systemd-сервис из apt), зависимостей от других ролей
коллекции нет (`meta/main.yml`: `dependencies: []`).

Для отказоустойчивых (HA) развёртываний с репликацией — `roles/postgresql_replication`
(`docs/adr/0005-postgresql-ha-replication-role.md`). Эта роль — для одиночного сервера общего
назначения (например, БД для платформенных компонентов вроде LiteLLM/Grafana). Решения и
обоснование того, почему это отдельная роль, а не режим `postgresql_replication` — см.
`docs/adr/0023-postgresql-standalone-role.md`.

## Границы ответственности

Роль **не создаёт** БД/пользователей-потребителей. `pg_hba.conf` роль трогает только один раз —
убирает Debian-дефолтные строки `host all all 127.0.0.1/32`/`::1/128 scram-sha-256` (найдено
реальным прогоном molecule: эти строки матчатся ЛЮБЫМ пользователем с паролем к ЛЮБОЙ базе с
loopback-адреса, в обход точечных грантов, которые потребители добавляют под себя — оставлять их
значило бы, что per-database/per-user гранты ниже не дают заявленной изоляции). После применения
роли сервер слушает сеть (`listen_addresses`), но аутентифицироваться не может никто, кроме
local/unix-сокет (`peer`) — вообще никакого сетевого доступа по умолчанию, пока для конкретной
БД/пользователя явно не добавлена своя запись `pg_hba.conf`.

Заведение БД/пользователя под конкретного потребителя — на уровне playbook'а, тем же способом, что
уже устоялся в коллекции (см. `demo/postgresql-ha-platform/ansible/site.yml` —
`postgres_exporter`/`odyssey`):

```yaml
- name: Создать БД и пользователя для потребителя X
  community.postgresql.postgresql_db:
    name: x
  become: true
  become_user: postgres

- name: Создать пользователя X
  community.postgresql.postgresql_user:
    db: x
    name: x
    password: "{{ x_db_password }}"
  become: true
  become_user: postgres

- name: Разрешить X подключаться по сети
  community.postgresql.postgresql_pg_hba:
    dest: "{{ postgresql_config_dir }}/pg_hba.conf"
    contype: hostssl
    databases: x
    users: x
    source: 10.20.30.0/24
    method: scram-sha-256
  notify: Reload PostgreSQL
```

## Переменные

- `postgresql_version` (`"17"`), `postgresql_cluster_name` (`main`) — версия и имя
  Debian-пакетированного кластера.
- `postgresql_listen_addresses` (`"*"`) — Debian-дефолт (`localhost`) не пускает удалённые
  подключения вообще; кто именно может подключиться — решает не это, а `pg_hba.conf` (см. выше).
- `postgresql_port` (`5432`).
- `postgresql_tls_enabled` (`true`), `postgresql_tls_common_name`, `postgresql_tls_days` (`3650`) —
  самоподписанный сертификат (`community.crypto`), тот же паттерн, что `roles/fail2ban_ui`.

## Molecule

`extensions/molecule/postgresql/` — одноразовая ВМ (`driver: vagrant`/`libvirt`,
`cloud-image/ubuntu-24.04`). Converge: роль + ad hoc `community.postgresql.*`-задачи заводят
тестовую БД/пользователя (по образцу блока "Заведение БД/пользователя" выше). Verify: `psql`
с `sslmode=require` под тестовым пользователем к своей БД (позитивный кейс) и проверка, что чужая
БД/суперпользователь недоступны удалённо (негативный кейс).
