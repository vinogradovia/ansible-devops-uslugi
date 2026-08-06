# ADR-0009: Роль `backup_server` (Bareos director + storage daemon + catalog)

- **Статус:** Принято (MVP: один хост, диск, self-backup)
- **Дата:** 2026-08-06
- **Авторы:** Ivan Vinogradov (решения), Claude Code (оформление по итогам обсуждения и реализации)

## Контекст

ROADMAP.md Backlog №48 фиксирует потребность в централизованном сервисе бекапа для нескольких
клиентских хостов — единый control-plane, а не отдельный агент-на-хост без центра. В обсуждении
рассматривались и отклонены:

- **Proxmox Backup Server** — работает на уровне VM/CT с хоста Proxmox, вне зоны ответственности
  этой Ansible-коллекции; не даёт логической консистентности БД и выборочного восстановления
  (одной таблицы/базы). Годится как отдельный, ортогональный слой DR на уровне целых VM — не
  заменяет эту задачу.
- **restic/borg** — простые однобинарные инструменты, но не дают единого control-plane поверх
  нескольких хостов (требование пользователя явно сформулировано как «единый control-plane
  нужен»).

**Решение — [Bareos](https://www.bareos.com)** (fork Bacula): director + catalog (своя
PostgreSQL-БД заданий) + storage daemon — готовый control-plane, плюс нативные плагины
(`pgsql-fd`/`percona-xtrabackup`) для консистентных бекапов БД без ручных
`pg_dump`/`mysqldump`-обвязок (пригодятся будущей роли `backup_agent`, не в этой роли).

Архитектура по паттерну `_server`/`_agent`, уже принятому в коллекции для
`monitoring_server`/`monitoring_agent`. Все технические факты ниже проверены напрямую по
исходникам апстрима (`github.com/bareos/bareos`, ветка `master`) и реальному листингу
репозитория пакетов, а не только по документации — тот же принцип, что уже применялся в этой
сессии для `fail2ban`/NPM (верить факту, не пересказу).

## Решения

### 1. Scope этой роли — только `backup_server`, без `backup_agent`/DR-экспорта/S3/webui

**Решение:** в этот заход реализован только `backup_server` (director + catalog + storage daemon,
хранилище — локальный диск, с самопроверкой через собственный catalog-бекап). Осознанно вне
scope, следующие шаги ROADMAP №48:

- `backup_agent` — file daemon на клиентских хостах + декларативные источники `postgres`/`mysql`/
  `files`. `backup_server_clients`/`backup_server_filesets` в схеме переменных уже готовят место
  под неё (рендерятся в `bareos-dir.d/client|job|fileset`, если заполнены), но по умолчанию пусты.
- DR-экспорт на внешний носитель (пул `dr` + Copy Job + README-runbook восстановления) —
  расширение `backup_server` вторым заходом, после того как база подтверждена рабочей.
- S3-хранилище — следующий шаг, MVP только на локальный диск.
- `bareos-webui` — не устанавливается (только `bconsole`).

### 2. Репозиторий и пакеты

**Решение:** community-репозиторий `download.bareos.org` (OBS-стиль, плоский, без dist/component),
ветка `current` (стабильная, не `next`). Путь дистрибутива подтверждён напрямую по реальному
листингу (`bareos.list` в самом репозитории: `deb https://download.bareos.org/current/xUbuntu_24.04
/`) — не совпадает с `ansible_distribution` напрямую (в отличие от `download.docker.com`), поэтому
вычисляется явно: `xUbuntu_XX.YY` для Ubuntu, `Debian_XX` для Debian
(`backup_server_bareos_repo_os_path`). Подключение — тот же паттерн, что
`roles/docker/tasks/install-repo.yml` (keyring signed-by, не `apt_key`).

Пакеты подтверждены реальным листингом `Packages` того же репозитория: `bareos-director`,
`bareos-storage`, `bareos-filedaemon` (нужен и на самом `backup_server` — см. §4),
`bareos-database-postgresql`, `bareos-database-common`, `bareos-bconsole`. Плюс дистрибутивный
пакет `postgresql` (не PGDG, в отличие от `roles/postgresql_replication` — каталог Bareos не
участвует ни в какой репликации коллекции, пиннинг версии избыточен для внутренней служебной БД).

### 3. Catalog (PostgreSQL) — без `dbconfig-common`

**Решение:** Debian-пакеты Bareos по умолчанию используют интерактивный `dbconfig-common`, не
подходящий для Ansible. Вместо этого — прямой путь, подтверждённый исходниками `core/src/cats/`:

1. `community.postgresql.postgresql_user`/`postgresql_db` создают роль и БД
   (`encoding: SQL_ASCII`, `lc_collate`/`lc_ctype: C`, `template: template0`, `owner` = роль) —
   это ровно то, что делает штатный скрипт Bareos `create_bareos_database` (см. исходники), но
   нативным идемпотентным модулем коллекции вместо шелл-скрипта.
2. Схему (таблицы) эти модули не создают — нужен сам Bareos:
   `/usr/lib/bareos/scripts/make_bareos_tables`, не идемпотентный сам по себе (падает при
   повторном запуске на существующей схеме) — гейтится ansible-стороной (проверка наличия таблицы
   `job` перед запуском). Тот же принцип постфактум-проверки, что уже применён для
   `fail2ban-client -t` (инструмент не умеет сообщить о своём состоянии сам, оборачиваем
   ansible-задачами).
3. **`grant_bareos_privileges` — реально нужен, не заменяется `owner` БД.** Изначальное
   предположение («`owner` у `postgresql_db` достаточно») оказалось неверным — найдено реальным
   прогоном molecule: `make_bareos_tables` выполняется от `become_user: postgres`, поэтому таблицы
   создаются с `owner = postgres`, а не с owner БД; `bareos-dir` подключается ролью каталога
   (`backup_server_catalog_db_user`) и падал `permission denied for table version`. Штатный
   `grant_bareos_privileges` запускается тем же гейтом, что и `make_bareos_tables` (один раз, сразу
   после создания схемы) — без него часть плана («нативные модули вместо скриптов Bareos») была
   неполной.
4. Аутентификация — unix-сокет с peer-auth от системного пользователя `bareos` (тот же паттерн,
   что `roles/postgresql_replication`, `become_user: postgres` для bootstrap-задач). Peer-auth
   сверяет реального ОС-пользователя, выполняющего команду, а не просто "локальное подключение" —
   см. §7 про `become_user: bareos`, обязательный для `bareos-dir -t`.

### 4. Self-backup вместо отдельного demo/тестового клиента

**Решение:** роль ставит `bareos-filedaemon` и на самом `backup_server` (не только будущий
`backup_agent` на удалённых хостах) и настраивает единственный функциональный job —
`BackupCatalog` (дамп каталога + `/etc/bareos`, `RunBeforeJob`/`RunAfterJob` =
`make_catalog_backup`/`delete_catalog_backup`, как в апстримном дефолте). Это доказывает всю
цепочку целиком (director → storage daemon → catalog) без необходимости в ещё не реализованной
роли `backup_agent` — molecule-верификация реально запускает этот job через `bconsole` и проверяет
появление тома на диске, а не только валидность конфига.

### 5. Валидация — постфактум-команда, не `validate:` у `template`

**Решение:** ресурсы Bareos (director/storage daemon/file daemon) — множество файлов в
`bareos-*.d/<тип>/*.conf` (структура подтверждена деревом `core/src/defaultconfigs/` апстрима:
`catalog/client/console/director/fileset/job/jobdefs/messages/pool/schedule/storage` у director,
`device/director/messages/storage` у storage daemon, `client/director/messages` у file daemon).
`-t -c` каждого демона валидирует целый конфиг-каталог, не один файл-кандидат — `validate:` у
отдельного `ansible.builtin.template` здесь не сработал бы (тот же класс проблемы, что уже решён
для `fail2ban`/`jail.local`, ADR-0007-соседних ролей). Решение: рендерим все ресурсы, затем
отдельным command-таском `bareos-dir -t` / `bareos-sd -t` / `bareos-fd -t`.

### 6. Messages — упрощены, без почтового релея

**Решение:** `Messages`-ресурсы ограничены `console`/`append`-в-лог(+`catalog` для job-сообщений),
без апстримных `operator`/`mail` (`bsmtp`) — не тащим в MVP настройку SMTP-релея. Задокументировано
в README как осознанное упрощение, расширяемо руками при необходимости алертинга почтой.

### 7. `-c` указывает на базовый `/etc/bareos`, а не на конкретный файл/каталог ресурсов; пакетные дефолты явно вычищаются

**Найдено** первым же прогоном molecule, потребовало двух итераций: `bareos-dir -t -c
/etc/bareos/bareos-dir.conf` падает — `ValidationError: Path does not exist` (такого файла нет
вообще). Промежуточная гипотеза — передать сам каталог ресурсов (`-c /etc/bareos/bareos-dir.d`) —
тоже оказалась неверной: `Failed to find configuration files... Did look for
".../bareos-dir.d/bareos-dir.conf" and ".../bareos-dir.d/bareos-dir.d"` — сам `-c` уже
интерпретируется как BASEDIR, и Bareos сам достраивает к нему суффикс компонента
(`<BASEDIR>/bareos-dir.conf` → фоллбэк `<BASEDIR>/bareos-dir.d`), повторно указывать
`bareos-dir.d` не нужно. Правильное значение — родительский `/etc/bareos`. Подтверждено исходником
`core/scripts/bareos-config-lib.sh.in` (`get_config_path2(BASEDIR, COMPONENT)`) и тем, что
пакетный `ExecStart=.../bareos-dir -f` в systemd-юните вовсе не передаёт `-c` — бинарник неявно
использует тот же BASEDIR по умолчанию. **Исправлено**: `backup_server_{director,storage,
filedaemon}_conf_path` = `/etc/bareos` (общий BASEDIR для всех трёх компонентов), отдельно от
`..._config_dir` (конкретный `bareos-*.d/`, используется для рендера ресурсов).

**Третье, той же природы**: рендер `Director`-ресурса изначально шёл в файл `director/director.conf`
— не совпадает с пакетным `director/bareos-dir.conf`, поэтому оба файла остались на диске
одновременно, каждый со своим `Director { Name = bareos-dir }` → `bareos-dir -t` упал с "Attempt
to define second Director resource named "bareos-dir" is not permitted". Все остальные dest-пути
(`catalog/MyCatalog.conf`, `storage/File.conf`, `client/bareos-fd.conf`, `messages/{Daemon,
Standard}.conf`, `pool/*.conf`, `job/BackupCatalog.conf`, а на стороне SD/FD — `director/
bareos-dir.conf`, `device/FileStorage.conf`, `storage/bareos-sd.conf`, `client/myself.conf`,
`messages/Standard.conf`) уже совпадали с пакетными именами с первого раза — целенаправленно
сверено с реальным листингом `debian/bareos-{director,storage,filedaemon}.install.in`
апстрима после этой находки, а не оставлено на волю случая.

**Четвёртое**: после того как конфиг стал парситься без ошибок, `bareos-dir -t` упал на попытке
реально открыть Catalog — `Peer authentication failed for user "bareos"`. Причина — `-t` реально
подключается к PostgreSQL (не просто парсит YAML/ресурсы), а peer-auth сверяет ОС-пользователя,
от имени которого выполняется `bareos-dir`, с запрошенной ролью PostgreSQL (`bareos`, см. §3).
Ansible-задача валидации выполнялась от `root` (общий `become: true` плейбука) — идентичность не
совпадала с ролью `bareos`, отсюда отказ. Настоящий systemd-сервис этой проблемой не страдает
(юнит сам стартует с `User=bareos`, см. `debian/bareos-director.service.in`) — баг был только в
самой ansible-валидации. **Исправлено**: `become_user: bareos` на задаче `bareos-dir -t` (и в
`extensions/molecule/backup_server/verify.yml` — независимая перепроверка той же командой).

**Второе, более серьёзное, найдено тем же прогоном**: пакеты `bareos-director`/`bareos-storage`/
`bareos-filedaemon` сами разворачивают **весь** дефолтный шаблонный каталог ресурсов при первой
установке (`postinst`: `bareos-config deploy_config --init "bareos-dir"`, копирует директорию
целиком) — не только "рыбу" для тех ресурсов, что переопределяет эта роль, а полный набор:
generic-клиент, лишние fileset (`LinuxAll`/`SelfTest`/`Windows All Drives`), job
(`backup-bareos-fd`, `RestoreFiles`), jobdefs (`DefaultJob`), schedule (`WeeklyCycle`,
`WeeklyCycleAfterBackup`), pool (`Scratch`), console/profile (webui-only) ресурсы. Часть из них
рендерится этой ролью под тем же именем файла и корректно перезаписывается `template`
(`director/bareos-dir.conf`, `catalog/MyCatalog.conf`, `storage/File.conf`, `client/bareos-fd.conf`,
`pool/{Full,Differential,Incremental}.conf`, `fileset/Catalog.conf`, `job/BackupCatalog.conf`,
`messages/{Daemon,Standard}.conf` — раздельные файлы, а не один, как было изначально: два
Messages-ресурса с одинаковым `Name` в разных файлах — фатальная ошибка парсера Bareos, тоже
найдено этим прогоном). Остальное — реальные ресурсы, ссылающиеся друг на друга (`backup-bareos-fd`
job работал бы по расписанию `WeeklyCycle` против настоящих `Client`/`Storage` этой роли) —
нарушало бы принцип "конфиг = source of truth", тот же, что `jail.local` в `fail2ban`. **Решение:**
`director-config.yml`/`storage-config.yml`/`filedaemon-config.yml` явно удаляют весь список
недекларируемых пакетных файлов (`ansible.builtin.file: state: absent`) до рендера собственных
ресурсов.

### 8. `bconsole wait` не печатает отчёт о терминации сам по себе

**Найдено** в molecule verify: после `run job=BackupCatalog level=Full yes` + `wait` вывод
обрывался на `You have messages.` — джоб реально отработал (подтверждено отдельно: файл тома на
диске, дамп каталога появлялся и удалялся), но текст `Termination: ... Backup OK` не попадал в
stdout. `wait` блокируется до завершения всех джобов, но не выводит их отчёт — для этого нужна
отдельная команда `messages` тем же сеансом. **Исправлено**: скрипт `bconsole` в
`extensions/molecule/backup_server/verify.yml` — `run ... yes` → `wait` → `messages` → `quit`.

## Финальный статус

`molecule test -s backup_server` — полностью зелёный: `converge` → `idempotence` (`changed=0`,
без изменений на повторном прогоне) → `verify` (реальный запуск `BackupCatalog` через `bconsole`,
подтверждённое `Termination: Backup OK`, непустой том на диске, дамп каталога появляется и
удаляется по `RunAfterJob`) → `destroy`. Все восемь находок выше (§§2–8 плюс исходная ошибка пути)
обнаружены и закрыты реальными прогонами, а не предположениями — тот же принцип, что уже применялся
в этой сессии для `fail2ban`/NPM.

## Открытые вопросы / вне скоупа

- `backup_agent`, DR-экспорт, S3-хранилище, `bareos-webui` — см. §1.
- Peer-auth каталога (§3.3) полагается на совпадение системного пользователя `bareos` (от которого
  работает `bareos-dir`) и роли PostgreSQL с тем же именем — если на практике это не сработает
  (нестандартный `pg_hba.conf`), потребуется явный `DB Address`/`host`-правило вместо peer.
- Точный неинтерактивный синтаксис `bconsole`, использованный в molecule verify (stdin-пайп команд
  `run job=... yes` / `wait` / `quit`) — рабочий, но не официально документированный API, при
  апгрейде Bareos может потребовать корректировки.

## Ссылки

- `roles/backup_server/` — реализация (README.md роли — подробное описание переменных).
- `extensions/molecule/backup_server/` — molecule-сценарий (реальный запуск `BackupCatalog` через
  `bconsole`, проверка появления тома на диске, а не только `-t`).
- `ROADMAP.md`, Backlog №48 — полный план (все пять частей, включая ещё не реализованные
  `backup_agent`/DR-экспорт).
- `roles/postgresql_replication/tasks/replication-user.yml` — прецедент `become_user: postgres` +
  `community.postgresql.*` с unix-сокетом (§3).
- `roles/docker/tasks/install-repo.yml` — прецедент подключения стороннего apt-репозитория
  (keyring signed-by, §2).
- `roles/fail2ban/` — прецедент декларативного списка (`fail2ban_jails` ↔ `backup_server_pools`/
  `backup_server_clients`) и постфактум-валидации многофайлового конфига (§5).
