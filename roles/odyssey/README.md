# odyssey

Единая точка подключения к PostgreSQL (`db-write`/`db-read`) — DNS-записи указывают на хосты этой
роли, [Yandex Odyssey](https://github.com/yandex/odyssey) маршрутизирует подключение на нужный
backend. Проектные решения — см.
[`docs/adr/0005-postgresql-ha-replication-role.md`](../../docs/adr/0005-postgresql-ha-replication-role.md),
§6.

**Статус:** реализована, покрытие molecule — см. `extensions/molecule/odyssey/`.

## Назначение и место среди других ролей

Разворачивается на **отдельных выделенных хостах**, не на серверах PostgreSQL
(`roles/postgresql_replication`) и не через `docker` (тот же принцип, что и `roles/proxysql` в
ADR-0004 §6 — не создаём лишнюю зависимость от роли `docker` ради критичного компонента
маршрутизации).

## Ключевое отличие от `proxysql` (ADR §6)

ProxySQL разбирает SQL и умеет per-query маршрутизацию (`SELECT` → reader hostgroup, всё
остальное → writer). **Odyssey так не умеет** — маршрут определяется на этапе подключения
(`database "<name>"`, у каждого одна `storage`). Поэтому чтение/запись разведены на уровне двух
разных точек подключения, а не одного адреса с умной маршрутизацией внутри:

- `db-write` (`odyssey_write_database_name`) → `storage` на **primary**.
- `db-read` (`odyssey_read_database_name`) → `storage` на **read-источник для чтения**.

Роль остаётся полностью декларативной (как `proxysql`) — сама в inventory не лезет, backend-хосты
приходят готовыми переменными от плейбука-оркестратора.

## Read-источник — fallback на DR-реплику (ADR §6)

**Определяется составом инвентаря на момент прогона роли, не рантайм-переключением внутри
Odyssey.** Если группа `postgresql_read_replica` непустая — `db-read` указывает на неё; если
пустая — на `postgresql_dr_replica` (несмотря на межДЦ-задержку — лучше читать оттуда, чем не
разгружать primary вовсе). Это НЕ живое автоматическое переключение при отказе read-реплики во
время работы — смена read-источника требует повторного прогона роли с другим составом инвентаря.

Playbook-оркестратор считает `odyssey_read_backend_host` сам, роль его не вычисляет:

```yaml
odyssey_read_backend_host: >-
  {{ hostvars[groups['postgresql_read_replica'][0]].ansible_host
     if groups['postgresql_read_replica'] | length > 0
     else hostvars[groups['postgresql_dr_replica'][0]].ansible_host }}
```

## Установка — PGDG, без пиннинга версии

Пакет `odyssey` — из `apt.postgresql.org` (PGDG), тем же `signed-by`-keyring, что и
`postgresql_replication`, **не** из GitHub Releases проекта `yandex/odyssey` (там нет вложений ни
у одного тега — проверено через GitHub API, см. ADR, «Контекст»). Версия **не пиннится**
(осознанный компромисс, единственное место в коллекции без строгого пиннинга версии пакета) —
ставится то, что актуально в PGDG на момент прогона.

## Секреты

`odyssey_backend_user`/`odyssey_backend_password` — без дефолта, роль падает через `assert` (см.
`tasks/assert-required-vars.yml`), значения — из Ansible Vault на уровне inventory (тот же
паттерн, что и в `roles/postgresql_replication`, ADR §9).

## Учётная запись на backend'ах — забота оператора, не этой роли

Odyssey одновременно (а) аутентифицирует клиентские подключения `db-write`/`db-read` и (б)
подключается к backend-серверам PostgreSQL той же учётной записью
(`odyssey_backend_user`/`odyssey_backend_password`). Эта роль **не создаёт** такого пользователя
на серверах PostgreSQL — так же, как `proxysql_monitor_user` не создаётся ролью `proxysql` (ADR
§11, "композиция на уровне инвентаря/плейбука, не meta-зависимость"). Пример SQL, который нужно
выполнить на primary (реплицируется на все реплики):

```sql
CREATE USER app WITH LOGIN PASSWORD '...';
GRANT ALL PRIVILEGES ON DATABASE myapp TO app;
```

## Пример

```yaml
- hosts: odyssey_hosts
  vars:
    odyssey_write_backend_host: "{{ hostvars[groups['postgresql_primary'][0]].ansible_host }}"
    odyssey_read_backend_host: >-
      {{ hostvars[groups['postgresql_read_replica'][0]].ansible_host
         if groups['postgresql_read_replica'] | length > 0
         else hostvars[groups['postgresql_dr_replica'][0]].ansible_host }}
  roles:
    - role: devops.uslugi.odyssey
      odyssey_backend_user: app
      odyssey_backend_password: "{{ vault_app_postgresql_password }}"
```

## Локальное тестирование (molecule, docker)

`extensions/molecule/odyssey/` — `driver: docker` (в отличие от `postgresql_replication`, это
одиночный stateless-сервис без требований к устойчивому диску/нескольким узлам, тот же принцип,
что и `nginx_multidomain`/`reverse_proxy_npm`):

```bash
molecule test -s odyssey
```

## Вне скоупа

- Балансировка между несколькими read-репликами — инвентарная модель (`postgresql_replication`,
  ADR §3) допускает расширение, но эта роль всегда берёт ровно один read-хост.
- RHEL/Rocky (dnf).
- Живое автоматическое переключение read-источника при отказе — исключено явно (ADR §6).
