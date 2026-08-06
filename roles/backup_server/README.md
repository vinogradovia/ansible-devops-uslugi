# backup_server

Устанавливает и настраивает [Bareos](https://www.bareos.com) director + storage daemon + catalog —
централизованный сервис бекапа (ROADMAP.md Backlog №48). Архитектурное решение (Bareos vs Proxmox
Backup Server vs restic/borg) и полный план — см. пункт №48 в ROADMAP.md.

**Статус**: MVP. Реализован единый хост (director + storage daemon + catalog + локальный file
daemon для self-backup), хранилище — локальный диск. Вне scope этой роли (следующие шаги ROADMAP
№48): роль `backup_agent` (file daemon на удалённых клиентских хостах, декларативные источники
`postgres`/`mysql`/`files`), DR-экспорт на внешний носитель (пул `dr` + Copy Job), S3-хранилище,
`bareos-webui`.

## Как устроено

- **Репозиторий/пакеты** — `download.bareos.org` (community-репозиторий Bareos, ветка `current`),
  подключается тем же паттерном, что `roles/docker/tasks/install-repo.yml` (keyring signed-by, не
  `apt_key`). Путь дистрибутива (`xUbuntu_XX.YY`/`Debian_XX`) вычисляется явно — не совпадает с
  `ansible_distribution`, как у docker/postgresql. Устанавливаются `bareos-director`,
  `bareos-storage`, `bareos-filedaemon` (нужен и на самом `backup_server` — см. self-backup ниже),
  `bareos-database-postgresql`, `bareos-database-common`, `bareos-bconsole` + дистрибутивный пакет
  `postgresql` (не PGDG — каталог не участвует ни в какой репликации коллекции, пиннинг версии
  избыточен, в отличие от `roles/postgresql_replication`).
- **Catalog (каталог заданий)** — Debian-пакеты Bareos по умолчанию используют интерактивный
  `dbconfig-common`, не подходящий для Ansible. Вместо этого: роль и БД PostgreSQL создаются
  нативными идемпотентными модулями `community.postgresql.postgresql_user`/`postgresql_db`
  (`encoding: SQL_ASCII`, `lc_collate`/`lc_ctype: C`, `template: template0`, `owner` = роль) — это
  ровно то же самое, что делает штатный скрипт Bareos `create_bareos_database` (см. исходники
  `core/src/cats/*.in` апстрима), но без шелл-скрипта. Саму схему (таблицы) эти модули не создают —
  она накатывается штатным `/usr/lib/bareos/scripts/make_bareos_tables`, который не идемпотентен
  сам по себе (падает на уже существующей схеме) — гейтится ansible-стороной (`catalog-bootstrap.yml`:
  проверка наличия таблицы `job` перед запуском). Права на созданные таблицы отдельно выдаёт
  `grant_bareos_privileges` (тем же гейтом) — без него `bareos-dir` не может читать/писать catalog
  (таблицы создаются с `owner = postgres`, роль каталога получает права только через явный GRANT).
  Аутентификация к PostgreSQL — unix-сокет с peer-auth от системного пользователя `bareos` (тот же
  принцип, что `roles/postgresql_replication`, `become_user: postgres` для bootstrap-задач;
  `bareos-dir -t`/сервис тоже должны выполняться как ОС-пользователь `bareos`, иначе peer-auth
  отклонит подключение).
- **Валидация конфигов** — director/storage daemon/file daemon хранят конфиг как множество файлов
  в `bareos-*.d/<тип-ресурса>/*.conf` (структура подтверждена деревом
  `core/src/defaultconfigs/` апстрима). `-t -c` каждого демона валидирует целый конфиг-каталог, не
  один файл-кандидат — `validate:` у отдельного `ansible.builtin.template` здесь не сработал бы
  (тот же класс проблемы, что уже решён для `fail2ban`/`jail.local`). Вместо этого: рендерим все
  ресурсы, затем отдельным command-таском `bareos-dir -t` / `bareos-sd -t` / `bareos-fd -t`.
- **Self-backup (`BackupCatalog`)** — единственный функциональный job в этой роли на данный
  момент: бекапит дамп самого каталога (`make_catalog_backup`/`delete_catalog_backup`,
  RunBeforeJob/RunAfterJob) + `/etc/bareos` на локальный disk-пул через локальный же
  `bareos-filedaemon` (`backup_server_self_backup_client_name`, дефолт `bareos-fd`, `Address =
  localhost`). Доказывает всю цепочку целиком (director → storage daemon → catalog) без
  необходимости в ещё не реализованной роли `backup_agent`. Можно отключить
  (`backup_server_self_backup_enabled: false`), но тогда до появления `backup_agent` бекапить
  вообще нечего — роль поднимет пустой, нерабочий с практической точки зрения control-plane.
- **Хранилище** — MVP: один `Device` (`FileStorage`) на локальный каталог
  (`backup_server_storage_archive_device`, по умолчанию `/var/lib/bareos/storage`). S3 — следующий
  шаг ROADMAP №48, не реализовано.
- **Messages** — упрощены относительно апстрима: только консоль + лог-файл (+ catalog для job-
  сообщений), без `operator`/`mail` (`bsmtp`) — не тащим в MVP настройку почтового релея. Если
  нужен алертинг почтой — расширяйте `templates/bareos-dir.d/messages/messages.conf.j2` вручную.

## Обязательные переменные (fail-fast, `check-and-install-requirements.yml`)

- `backup_server_director_password` — пароль director<->bconsole/storage daemon.
- `backup_server_storage_password` — пароль director<->storage daemon.
- `backup_server_catalog_db_password` — пароль роли PostgreSQL каталога.
- `backup_server_self_backup_client_password` — пароль director<->локальный file daemon (только
  при `backup_server_self_backup_enabled: true`, включено по умолчанию).

## Место под будущую роль `backup_agent`

`backup_server_clients` (пусто по умолчанию) и `backup_server_filesets` — декларативные списки,
уже рендерящиеся в `bareos-dir.d/client|job|fileset`, если заполнены (схема — комментарий в
`defaults/main.yml`), но не используются в MVP. Когда появится `backup_agent` (file daemon на
удалённых хостах), она должна будет только заполнить эти списки — расширять `backup_server` не
потребуется.

## Пример

```yaml
backup_server_director_password: "{{ vault_backup_server_director_password }}"
backup_server_storage_password: "{{ vault_backup_server_storage_password }}"
backup_server_catalog_db_password: "{{ vault_backup_server_catalog_db_password }}"
backup_server_self_backup_client_password: "{{ vault_backup_server_self_backup_client_password }}"
```
