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

~~**Фаза 2**~~ — **сделано**: `mysql_replication_backup_tool: bareos` (третье значение
существующей переменной). Реализация разделила прежний единый `tasks/backup.yml` на общий
`install-backup-tool.yml` (repo.percona.com + `percona-xtrabackup-80`/`mariadb-backup` —
переиспользуется обоими путями) и `backup-bareos.yml` (только этот общий шаг, без rclone/S3/
systemd-timer). `backup_agent` подключается условной `meta`-зависимостью, тем же паттерном, что
`docker` (§1 выше) — `backup_agent_install_percona_xtrabackup_plugin: true` прокидывается
безусловно. Molecule (`extensions/molecule/mysql_replication/`, 4-я ВМ `mysql-backup-server`,
реальный `bconsole`-job на `mysql-dr-replica` через `bareos-fd-percona-xtrabackup`-плагин) —
см. «Финальный статус Фазы 2» ниже.

- ~~**Фаза 3**~~ — **сделано**: `postgresql_replication_backup_tool: pgbackrest|bareos` (новая
  переменная, дефолт `pgbackrest` — обратная совместимость). Взаимоисключающий выбор:
  `bareos`-плагин (`bareos-fd-postgresql`) сам архивирует WAL в `wal_archive_dir` через
  `archive_command`, занятый pgBackRest на альтернативном пути — параллельная работа невозможна.
  См. «Финальный статус Фазы 3» ниже.

## Финальный статус Фазы 2

`molecule test -s mysql_replication` — полностью зелёный: `create` → `prepare` → `converge` →
`idempotence` (`changed=0` на всех 4 ВМ) → `verify` (реальный `bconsole run
job=backup-mysql-dr-replica-fd`, `Termination: Backup OK`, непустой том на диске) → `destroy`.
Первый же прогон поймал три реальные регрессии, ни одна не была видна по коду до реального
исполнения:

1. **`repo.percona.com/percona/apt/percona-release.gpg` (404, прежний код ADR-0004 §8)** — сам
   URL прямого GPG-ключа больше не существует: Percona перешла на пакет `percona-release`
   (разворачивает keyring в `/usr/share/keyrings/percona-keyring.gpg`) и репозитории по продуктам
   (`pxb-80` для XtraBackup 8.0, а не единый `.../percona/apt`). Этот код (общий для `xtrabackup`/
   `mariabackup`/`bareos`) не был раньше нигде реально исполнен — `mysql_replication`-molecule
   намеренно отключал бэкапы (требовали внешнего S3), а Фаза 2 стала первым реальным прогоном.
   Исправлено в `roles/mysql_replication/tasks/install-backup-tool.yml`.
2. **Неверный выбор apt-пакета для `bareos`** — тернарник `'percona-xtrabackup-80' if
   backup_tool == 'xtrabackup' else 'mariadb-backup'` не учитывал третье значение: `bareos`
   попадал в `else` и пытался поставить `mariadb-backup`, чей пакет **конфликтует** с уже
   установленным Oracle MySQL (apt пытался снести `mysql-server`/`mysql-client`). Плагин
   `bareos-fd-percona-xtrabackup` всегда про XtraBackup, не про `mariabackup` — исправлено:
   только явное `mariabackup` выбирает `mariadb-backup`, оба других значения (`xtrabackup`,
   `bareos`) — `percona-xtrabackup-80`.
3. **`backup_agent`: `Plugin Directory` не был объявлен в `bareos-fd.d/client/myself.conf`** —
   `Fatal error: Plugin Directory not defined. Cannot use plugin: "python3:module_name=..."`.
   `client.conf.j2` (§2 выше) декларировал только `Name`, поэтому ЛЮБОЙ `Plugin = "python3:..."`
   в `FileSet` падал, даже когда соответствующий `*-plugin` apt-пакет установлен
   (`backup_agent_install_percona_xtrabackup_plugin`/`_install_postgresql_plugin`). Это первый
   реальный прогон, где эти флаги вообще были включены — Фаза 1 (§ выше) проверяла только
   `type: files`, без плагинов. Исправлено: `Plugin Directory = "/usr/lib/bareos/plugins"`
   добавлен в `roles/backup_agent/templates/bareos-fd.d/client/client.conf.j2` безусловно
   (`Plugin Names` намеренно не задаётся — грузятся только реально установленные `.so`).

## Финальный статус Фазы 3

`molecule test -s postgresql_replication` (4 ВМ: primary, read_replica, dr_replica,
postgresql-backup-server) — `converge` → `idempotence` (`changed=0` на всех 4 хостах) →
`verify`: bareos-специфичные проверки (реальный `bconsole run
job=backup-postgresql-dr-replica-fd`, `Termination: Backup OK`, непустой том на диске;
`archive_mode` на всех узлах соответствует роли) полностью зелёные. Полный сквозной прогон
`verify` (включая ручную promote/failback-последовательность, ADR §7) упирается в отдельную,
не связанную с bareos находку — ROADMAP №54 (`read_replica` не переподключается к новому primary
после failback) — обнаруженную только этим прогоном (раньше verify не доходил так далеко из-за
находок №1–2 ниже). Фаза 3 считается валидированной в границах собственной функциональности.

Три реальные находки, ни одна не была видна по коду до реального исполнения:

1. **`pg_backup_stop(wait_for_archive=true)` виснет бесконечно на тихой БД.** Плагин
   `bareos-fd-postgresql` вызывает `pg_backup_stop()` в non-exclusive backup mode, которая ждёт
   архивации ПОСЛЕДНЕГО WAL-сегмента бэкапа — если после снятия бэкапа в БД мало/нет записи
   (типичная ситуация в тестовом окружении сразу после verify-проверок), сегмент никогда не
   заполняется естественным трафиком, и job виснет часами (в проверке — больше часа на пустой
   тестовой БД). Исправлено: новая переменная
   `postgresql_replication_bareos_archive_timeout` (по умолчанию 60 секунд) — принудительное
   переключение WAL-сегмента по таймеру, `templates/postgresql-replication.conf.j2`.
2. **`archive_timeout` сам по себе не помогает, если `backup_source_role` — реплика (дефолт,
   ADR §8).** WAL-сегмент физически переключает только primary — реплика лишь архивирует то, что
   уже получила потоковой репликацией, и не может «попросить» primary переключиться сама. С
   `archive_mode=off` на primary (штатное поведение до этой находки, чтобы не плодить
   бесполезный WAL-архив там, где источник бэкапа — не primary) `archive_timeout`, выставленный
   только на реплике, не имеет эффекта вообще — `XLogArchivingActive()` требует активного
   архивирования именно на том узле, где происходит переключение сегмента. Исправлено: primary
   архивирует всегда при `backup_tool: bareos`, независимо от того, primary ли сам
   `backup_source_role` — `archive_mode = always`, `archive_command = 'true'` (в никуда, эту копию
   никто не читает, если `backup_source_role != primary`), `archive_timeout` из той же
   переменной. Цель — не архив primary, а сам факт периодического переключения сегмента,
   распространяющегося на все реплики потоковой репликацией.
3. **Promote/failback-путь неявно подключает `backup_agent` там, где раньше он не требовался.**
   `include_role: postgresql_replication` в `verify.yml` (`tasks_from: promote`/
   `configure-replica`) обрабатывает `meta/main.yml`-зависимости роли независимо от
   `tasks_from` — там, где `postgresql_replication_role` (в т.ч. явно переопределённая в vars
   конкретного `include_role`, как того требует сам ранбук, `docs/runbooks/postgresql-failover.md`
   раздел 3 шаг 5) совпадает с `backup_source_role`, `backup_agent`-зависимость реально
   выполняется, а `gather_facts: false` (обычный режим для узких verify-плеев с одними
   psql-командами) не даёт `ansible_distribution`, нужного `backup_agent/defaults/main.yml` —
   `'ansible_distribution' is undefined`. Дополнительно: при failback старый primary временно
   играет роль `dr_replica` для целей `promote.yml` — а значит должен быть заранее
   зарегистрирован клиентом bareos, как и штатный `dr_replica`, иначе падает на «Fail if
   backup_agent_client_password is not set» посреди failback-теста. Это не искусственный
   тестовый артефакт, а прямое следствие продовой семантики: любой узел, способный временно
   стать `backup_source_role` при failover/failback, должен иметь bareos-credentials
   заранее — то же самое верно и в реальной эксплуатации, не только в molecule. Исправлено:
   `gather_facts: true` на всех plays с `include_role: postgresql_replication`
   (`extensions/molecule/postgresql_replication/verify.yml`), второй bareos-клиент
   (`postgresql-primary-fd`) заведён в `group_vars/backup_servers.yml`/`postgresql_primary.yml`.

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
- `roles/postgresql_replication/` (Фаза 3) — `README.md`, «Бэкапы», описывает bareos-путь и
  пример конфигурации на обеих сторонах (`backup_source_role`/primary).
- `extensions/molecule/postgresql_replication/` — molecule-сценарий (4 ВМ, реальный job через
  `bconsole`, promote/failback-последовательность).
- `ROADMAP.md` №54 — находка про `read_replica`/failback, обнаруженная тем же прогоном, но не
  относящаяся к bareos — вынесена отдельным пунктом, не блокирует статус Фазы 3.
