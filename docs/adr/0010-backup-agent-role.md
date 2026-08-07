# ADR-0010: Роль `backup_agent` (Bareos file daemon — клиентский агент `backup_server`)

- **Статус:** Принято (Фаза 1 — генерик-роль + `type: files`, проверено)
- **Дата:** 2026-08-07
- **Авторы:** Ivan Vinogradov (решения), Claude Code (оформление по итогам обсуждения и реализации)

## Контекст

`backup_server` (ADR-0009) реализован и проверен, но функционален только для self-backup — без
клиентского агента бекапить с других хостов нечем. ROADMAP Backlog №48 предполагал следующим шагом
именно `backup_agent`.

В процессе планирования всплыло важное пересечение: `postgresql_replication`/`mysql_replication`
уже реализуют **собственные независимые** механизмы физического бэкапа —
`postgresql_replication_backup_enabled` (pgBackRest → S3) и
`mysql_replication_backup_tool: xtrabackup|mariabackup` (→ rclone → S3), каждый со своим systemd-
таймером и ретеншном (см. `docs/adr/0004-mysql-ha-replication-role.md` §8, `docs/adr/
0005-postgresql-ha-replication-role.md`). Это прямо противоречит идее единого control-plane, ради
которой выбирался Bareos (см. ROADMAP №48, обсуждение выбора Bareos vs Proxmox Backup Server vs
restic/borg).

**Решение пользователя**: не заменять и не дублировать эти механизмы отдельной ролью — добавить
Bareos как **третий вариант** `_backup_tool` внутри самих `mysql_replication`/`postgresql_replication`
(следующие фазы, см. «Дальнейшие шаги» ниже), наравне с уже существующими. `backup_agent` в этой
модели — переиспользуемый инфраструктурный примитив, не самостоятельная доменная роль.

## Решения

### 1. `backup_agent` — условная `meta`-зависимость, как `docker`, а не композиция, как `monitoring_agent`

**Решение:** роли-потребители (`mysql_replication`/`postgresql_replication` в будущих фазах) должны
подключать `backup_agent` условной зависимостью в `meta/main.yml`
(`when: ..._backup_tool == 'bareos'`), тем же паттерном, что `docker` в `monitoring_server`/
`monitoring_agent`/`reverse_proxy_traefik` (ADR-0002 §2) — а не оставлять композицию оператору
плейбука, как `monitoring_agent`/`infra_dns` в `mysql_replication` (ADR-0004 §11).

**Обоснование:** ADR-0004 §11 разводит эти два паттерна по критерию «обязательный примитив, без
которого путь не работает вообще» (→ `meta`-зависимость) vs «независимо конфигурируемый аспект
хоста» (→ композиция на уровне плейбука). `backup_tool: bareos` без установленного и
настроенного file daemon не работает в принципе — то же самое основание, что у `docker` для
`orchestrator: docker`, а не как у мониторинга/DNS, которые можно осознанно не подключать к
конкретному хосту.

### 2. Архитектурная граница: `backup_agent` не решает, ЧТО бекапить

**Найдено** при подготовке к реализации (не предположение, а факт, проверенный по дереву
`core/src/defaultconfigs/bareos-fd.d/` апстрима): у file daemon вообще нет ресурса `FileSet` —
только `client`/`director`/`messages`. `FileSet` (включая `Plugin = "python3:module_name=...:..."`
для БД-плагинов) целиком принадлежит `bareos-dir.d`, то есть конфигурируется на стороне
`backup_server` (`backup_server_filesets`, уже реализовано в ADR-0009).

Первоначальный план предполагал у `backup_agent` собственный декларативный список
`backup_agent_filesets` (по аналогии с `fail2ban_jails`) — это было архитектурно неверно и
исправлено до реализации: роль устанавливает только САМ file daemon + опциональные python-плагины
(`backup_agent_install_postgresql_plugin`/`backup_agent_install_percona_xtrabackup_plugin`,
булевы флаги — ставить пакет или нет), давая ему **возможность** выполнить то, что пришлёт
director, но не декларируя содержимое FileSet.

### 3. Интеграция `backup_agent` ↔ `backup_server` — вручную, без кросс-ролевого автообнаружения

**Решение:** `backup_agent` не имеет `meta`-зависимости на `backup_server` и наоборот — обе роли
независимы, интеграция через совпадающие значения переменных (`backup_agent_client_name`/
`backup_agent_client_password` на клиенте должны буквально совпадать с полем `name`/`password`
соответствующего элемента `backup_server_clients` на сервере). Тот же принцип, что уже
зафиксирован в `docs/adr/0008-infra-panel-role.md` §3 — роли коллекции сознательно не имеют
архитектурной связности друг с другом сверх явно решённого; README документирует готовый пример
блока для копирования на обе стороны.

### 4. Реальная находка: `Schedule "SelfBackupCycle"` не должен гейтиться `self_backup_enabled`

**Найдено** первым же прогоном molecule этого сценария (`backup_server_self_backup_enabled: false`,
`backup_server_clients` непустой): job для внешнего клиента по умолчанию ссылается на
`Schedule = "SelfBackupCycle"` (`bareos-dir.d/job/client-job.conf.j2`,
`item.schedule | default('SelfBackupCycle')`), но рендер этого расписания был гейтнут тем же
`when: backup_server_self_backup_enabled` — без self-backup ресурс не создавался вообще, и
`bareos-dir -t` падал на dangling-ссылке из клиентского job'а. **Исправлено**: рендер
`schedule/SelfBackupCycle.conf` больше не гейтится — это общий дефолт для ЛЮБых job'ов, не только
self-backup (`roles/backup_server/tasks/director-config.yml`).

### 5. Реальная находка: пакетный `job/BackupCatalog.conf` не удаляется, когда self-backup выключен

**Найдено** тем же прогоном, второй итерацией: рендер `client/bareos-fd.conf`,
`fileset/Catalog.conf`, `job/BackupCatalog.conf` тоже гейтится `self_backup_enabled` — при
`false` эти три файла НЕ перезаписываются, но их пакетные дефолтные версии остаются на диске
(`deploy_config --init`, см. ADR-0009 §7). Пакетный `job/BackupCatalog.conf` ссылается на
`JobDefs = "DefaultJob"`, который безусловно удаляется как недекларируемый пакетный дефолт (тоже
ADR-0009 §7) → `bareos-dir -t` падал `Could not find config resource "DefaultJob"`. **Исправлено**:
добавлен отдельный блок очистки — при `not backup_server_self_backup_enabled` эти три файла тоже
удаляются явно (`roles/backup_server/tasks/director-config.yml`), а не остаются как несогласованный
остаток пакета.

## Финальный статус

`molecule test -s backup_agent` — полностью зелёный: `converge` (обе ВМ) → `idempotence`
(`changed=0` на обеих) → `verify` (реальный job через `bconsole` с ВМ `backup-server` против
**удалённого** file daemon на ВМ `backup-agent-client` — не self-backup, а настоящая сетевая
связка director↔клиент; подтверждённое `Termination: Backup OK`, непустой том на диске) →
`destroy`. Обе находки §4–5 — регрессии в уже существующем `backup_server` (не в новом
`backup_agent`), пойманные только благодаря тому, что этот сценарий впервые использует
`backup_server_clients`/`self_backup_enabled: false` вместе — сама роль `backup_server` их не
покрывала.

## Дальнейшие шаги (вне scope Фазы 1, ROADMAP №48)

- **Фаза 2** — `mysql_replication_backup_tool: bareos` (третье значение существующей переменной,
  переиспользует уже существующую установку `percona-xtrabackup-80`/`mariadb-backup` из
  `tasks/backup.yml:6-43`, без rclone/S3/systemd-timer-части).
- **Фаза 3** — `postgresql_replication_backup_tool: pgbackrest|bareos` (новая переменная, дефолт
  `pgbackrest` — обратная совместимость). Взаимоисключающий выбор: `bareos`-плагин
  (`bareos-fd-postgresql`) сам архивирует WAL в `wal_archive_dir` через `archive_command`,
  занятый сейчас pgBackRest — параллельная работа невозможна.

## Ссылки

- `roles/backup_agent/` — реализация (README.md — подробное описание переменных, пример
  интеграции с `backup_server_clients`/`backup_server_filesets`).
- `extensions/molecule/backup_agent/` — molecule-сценарий (две ВМ, реальный job через `bconsole`
  против удалённого клиента, не self-backup).
- `docs/adr/0009-backup-server-role.md` — `backup_server`, `backup_server_clients`/
  `backup_server_filesets` (реализовано заранее, впервые задействовано здесь).
- `docs/adr/0004-mysql-ha-replication-role.md` §8, §11 — существующий backup-механизм
  `mysql_replication` и принцип «meta-зависимость vs композиция», применённый в §1 выше.
- `docs/adr/0002-docker-role.md` §2 — прецедент условной `meta`-зависимости.
