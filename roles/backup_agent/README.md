# backup_agent

Клиентский агент для `backup_server` (ROADMAP.md Backlog №48) — устанавливает и настраивает
Bareos file daemon на хосте, который нужно бекапить. Простая, генерик-роль: не решает, ЧТО именно
бекапить — это ресурс `FileSet` на стороне `backup_server`, а не `backup_agent` (см. «Архитектура»
ниже). Роль независима от `backup_server` (нет `meta`-зависимости в любую сторону) — применяется
отдельным плейбуком/группой инвентаря, интеграция происходит через совпадающие значения переменных
на обеих сторонах.

## Архитектура: почему в этой роли нет декларативного списка «что бекапить»

`bareos-fd.d` (конфиг file daemon) имеет только три типа ресурсов — `client`/`director`/`messages`
(подтверждено деревом `core/src/defaultconfigs/bareos-fd.d/` апстрима). Ресурса `FileSet` в нём
**нет вообще** — `FileSet` (включая `Plugin = "python3:module_name=...:..."` для БД-плагинов)
целиком принадлежит `bareos-dir.d`, то есть конфигурируется на стороне `backup_server`
(`backup_server_filesets`, уже реализовано в этой роли). `backup_agent` только даёт file daemon'у
**возможность** выполнить то, что пришлёт director — устанавливает сам демон и, опционально, нужные
python-плагины (`backup_agent_install_postgresql_plugin`/`backup_agent_install_percona_xtrabackup_plugin`).
Какие конкретно файлы/БД бекапить, с каким расписанием и в какой пул — решается на `backup_server`
(`backup_server_clients`+`backup_server_filesets`+`backup_server_pools`), не здесь.

## Обязательные переменные

- `backup_agent_client_password` — пароль director<->file daemon, должен **совпадать** с полем
  `password` соответствующего элемента `backup_server_clients` на стороне `backup_server`.

## Переменные интеграции с `backup_server`

- `backup_agent_director_name` (дефолт `bareos-dir`) — должен совпадать с
  `backup_server_director_name`.
- `backup_agent_client_name` (дефолт `{{ inventory_hostname }}-fd`) — должен совпадать с полем
  `name` элемента `backup_server_clients`.
- `backup_agent_install_postgresql_plugin`/`backup_agent_install_percona_xtrabackup_plugin`
  (дефолт `false` оба) — ставить ли `bareos-filedaemon-postgresql-python-plugin`/
  `bareos-filedaemon-percona-xtrabackup-python-plugin`. Нужны, только если на этом хосте
  `backup_server_filesets` (на стороне `backup_server`) будет использовать соответствующий
  `Plugin = "python3:module_name=bareos-fd-postgresql:..."`/`...percona-xtrabackup...`.

## Пример: подключить новый клиентский хост

На хосте-клиенте:

```yaml
backup_agent_client_name: app01-fd
backup_agent_client_password: "{{ vault_backup_agent_app01_password }}"
```

На `backup_server` (тот же пароль, тот же `name`):

```yaml
backup_server_clients:
  - name: app01-fd
    address: app01.internal
    password: "{{ vault_backup_agent_app01_password }}"
    fileset: app01-files

backup_server_filesets:
  - name: app01-files
    content: |
      Include {
        Options { Signature = XXH128 }
        File = /etc
        File = /var/www
      }
```

Интеграция — вручную, без кросс-ролевого автообнаружения (тот же принцип, что
`docs/adr/0008-infra-panel-role.md` §3 — роли коллекции сознательно не имеют архитектурной
связности друг с другом сверх того, что явно решено).

## Статус

Реализована и проверена только связка `backup_server`+`backup_agent` с `type: files`
(`extensions/molecule/backup_agent/`). `postgres`/`mysql`-плагины (опции
`backup_agent_install_*_plugin`) устанавливают пакеты, но конкретная интеграция с
`postgresql_replication`/`mysql_replication` (WAL-архивирование, XtraBackup-креды) — следующие шаги
ROADMAP №48, ещё не реализованы.
