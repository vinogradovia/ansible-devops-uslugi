# Инструкция: переключение PostgreSQL при аварии, обратное переключение, восстановление из копии

Для кого этот документ: разработчик/дежурный без глубоких знаний PostgreSQL/repmgr, у которого
есть доступ к Ansible-контроллеру (репозиторий + Ansible Vault пароль) и к VPN/сети, где живут
серверы БД. Архитектура и проектные решения, на которых основана эта инструкция, — см.
[`docs/adr/0005-postgresql-ha-replication-role.md`](../adr/0005-postgresql-ha-replication-role.md)
(роли `postgresql_replication`, `odyssey`).

## Топология одним взглядом

- **primary** — основной сервер, принимает запись. Один хост, группа `postgresql_primary`.
- **read-реплика** — тот же ДЦ, что и primary, обслуживает читающий трафик в обычном режиме.
  Группа `postgresql_read_replica`. **Опциональна** — может отсутствовать.
- **DR-реплика** — другой ДЦ Selectel. Обслуживает fallback-чтение, если read-реплики нет (ADR
  §6), и является источником бэкапов. Группа `postgresql_dr_replica`.
- **Odyssey** — отдельные хосты, единственная точка подключения для приложений (`db-write`,
  `db-read` через DNS). В отличие от ProxySQL, маршрут определяется на этапе подключения (у
  каждой БД `db-write`/`db-read` — ровно один backend), не по содержимому запроса.

**Важно про DNS:** `db-write`/`db-read` всегда указывают на хосты Odyssey и **не меняются** ни при
переключении, ни при обратном переключении — меняется только backend, на который Odyssey
проксирует `db-write`/`db-read`. Ни один шаг ниже не трогает DNS.

**Важно про Odyssey:** в отличие от ProxySQL (admin SQL-интерфейс, живое `LOAD ... TO RUNTIME`),
Odyssey перечитывает конфигурацию только при рестарте службы. Переключение backend'а — это
повторный прогон роли `odyssey` с другим значением `odyssey_write_backend_host`/
`odyssey_read_backend_host`, который перерендерит `odyssey.conf` и перезапустит сервис (см.
`roles/odyssey/handlers/main.yml`) — не изменение состояния "на лету".

## ⚠ Главное предостережение перед началом

Пока идёт авария или учебное переключение — **не запускайте обычный (без тегов/лимитов)
Ansible-прогон** на группы `postgresql_primary`/`postgresql_read_replica`/`postgresql_dr_replica`.
Роль `postgresql_replication` идемпотентна и при обычном прогоне попытается вернуть хосты в
«штатное» состояние по inventory (например, попробует подключить DR репликацией обратно к
исходному `postgresql_replication_primary_host` из group_vars) — это оборвёт экстренное
переключение. Используйте только команды, указанные в шагах ниже (с явными `--tags`/`--limit`).

## Предварительные условия

- Доступ к Ansible-контроллеру с этим репозиторием и файлом пароля Ansible Vault
  (`group_vars/*/vault.yml`).
- SSH/VPN-доступ к хостам `postgresql_primary`, `postgresql_read_replica`, `postgresql_dr_replica`,
  Odyssey — тот же межДЦ-туннель, через который идёт репликация.
- Знать актуальные имена ваших плейбуков-оркестраторов (ниже используются условные имена
  `postgresql-replicas.yml` и `odyssey.yml` — замените на реальные).

---

## Раздел 1. Как понять, что нужно переключение

Авария primary — это НЕ то же самое, что временная просадка сети. Прежде чем переключаться,
убедитесь:

1. Сайт действительно не может писать в базу (ошибки записи, а не просто медленные ответы).
2. Primary недоступен не только с одного хоста, а по факту (попробуйте с хоста Odyssey):
   ```bash
   pg_isready -h <ip_primary> -p 5432
   ```
   Если connection refused/timeout (не «no pg_hba.conf entry» — это как раз означает, что сервер
   жив) — переходите к разделу 2.
3. **Если авария затронула весь ДЦ основного сервера** (не только сам сервер), read-реплика (тот
   же ДЦ) тоже, скорее всего, недоступна. Тогда переключаетесь сразу на DR-реплику и для чтения, и
   для записи — это и так штатный fallback-путь Odyssey, когда `postgresql_read_replica` недоступна
   (ADR §6), отдельный шаг не нужен.

---

## Раздел 2. Экстренное переключение на replica (read- или DR-)

ADR §7 допускает promote и read-, и DR-реплики (в отличие от `mysql_replication`, где строго
DR) — ниже используется `<replica-host>` как обобщение, замените на реальный ip/hostname той
реплики, которую промоутите (обычно DR, если авария затронула весь ДЦ primary — см. раздел 1).

### Шаг 1. Если старый primary технически доступен (но недоступен приложению) — защититься от split-brain

В отличие от MySQL (`SET GLOBAL super_read_only=ON`), у PostgreSQL нет надёжного «мягкого»
read-only переключателя на лету — единственный гарантированный способ исключить запись на старом
primary — остановить на нём службу:

```bash
ssh <ip_primary> 'sudo systemctl stop postgresql@<version>-main'
```

Если primary полностью недоступен (сервер/ДЦ не отвечает вообще) — этот шаг просто невыполним,
пропустите его и идите дальше.

### Шаг 2. Проверить, что реплика готова принять роль writer'а

```bash
sudo -u postgres repmgr -f /etc/repmgr.conf cluster show
```

На выбранной реплике посмотрите отставание:

```bash
sudo -u postgres psql -c "SELECT now() - pg_last_xact_replay_timestamp() AS replication_lag;"
```

Чем меньше `replication_lag`, тем меньше потенциальная потеря данных (записи за эти секунды, не
успевшие реплицироваться, будут потеряны — ожидаемое следствие асинхронной репликации, ADR §4).
Если `repmgr cluster show` показывает узел как `? unreachable`/`failed` или репликация давно
остановлена — прежде чем переключаться, оцените: реплика может быть неактуальна. В большинстве
случаев всё равно переключаемся (это лучше, чем полная недоступность сайта), но сообщите об этом в
отчёте по инциденту отдельно.

### Шаг 3. Перевести реплику в writable-режим

```bash
ansible-playbook -i inventory.yml postgresql-replicas.yml \
    --tags postgresql_replication_promote --limit <replica-host>
```

Эта команда (задачи роли `postgresql_replication`, `tasks/promote.yml`) выполнит `repmgr -f
/etc/repmgr.conf standby promote` на указанной реплике. После этого узел технически может
принимать запись.

### Шаг 4. Переключить Odyssey на новый primary

```bash
ansible-playbook -i inventory.yml odyssey.yml \
  -e "odyssey_write_backend_host=<ip_replica>" \
  -e "odyssey_read_backend_host=<ip_replica>"
```

Роль `odyssey` перерендерит `odyssey.conf` (оба маршрута — `db-write` и `db-read` — временно на
один и тот же хост, т.к. до восстановления полноценной топологии читать больше не с кого) и
перезапустит службу (см. `roles/odyssey/handlers/main.yml`, Odyssey не умеет переключать backend
на лету).

### Шаг 5. Проверить, что сайт работает

- Открыть публичный фронт — страницы загружаются.
- Оформить **тестовую запись** через приложение и убедиться, что она корректно сохранилась.
- Проверить в логах Odyssey/приложения, что запросы реально идут на новый writer, а не падают.

### Шаг 6. Зафиксировать

- Время начала (недоступность primary) и время, когда сайт снова заработал на новой реплике — это
  метрика для отчёта.
- Кратко записать причину аварии (если известна) и состояние остальных узлов кластера.

---

## Раздел 3. Обратное переключение (failback) — без потери данных

Выполняется **после** того, как исходный ДЦ/сервер primary полностью восстановлен и проверен.
Старый primary присоединяется к новому primary как standby через `repmgr node rejoin`
(использует `pg_rewind`, чтобы не пересоздавать datadir с нуля, если временные линии разошлись
несильно) — не симметричная операция шагу 2. Выполнять в согласованное окно.

### Шаг 1. Убедиться, что старый primary снова здоров

PostgreSQL запущен, сеть/VPN до него работает, диск не переполнен:

```bash
ssh <ip_old_primary> 'sudo systemctl start postgresql@<version>-main'
```

### Шаг 2. Присоединить старый primary как standby к новому primary

```bash
ssh <ip_old_primary> 'sudo -u postgres repmgr -f /etc/repmgr.conf node rejoin -d "host=<ip_new_primary> user=repmgr dbname=repmgr" --force-rewind --verbose'
```

Это делается вручную (не через `ansible-playbook`), т.к. задачи роли `postgresql_replication`
рассчитаны на штатную топологию (роль хоста в inventory статически либо `primary`, либо реплика —
см. ADR §7) — тот же принцип, что и в `mysql_replication`.

### Шаг 3. Дождаться полной синхронизации

```bash
sudo -u postgres repmgr -f /etc/repmgr.conf cluster show
```

Ждите, пока старый primary отобразится как `standby` в состоянии `running`, без отставания
(`SELECT now() - pg_last_xact_replay_timestamp();` на нём же, как в разделе 2, шаг 2). **Не
переходите к шагу 4, пока отставание не станет пренебрежимо малым.**

### Шаг 4. Короткая пауза записи и собственно переключение

В согласованное окно:

1. Промоутить старый primary обратно (используя тот же тегированный механизм, что и в разделе 2 —
   на этот раз против бывшего primary, временно ставшего standby):
   ```bash
   ansible-playbook -i inventory.yml postgresql-replicas.yml \
       --tags postgresql_replication_promote --limit <ip_old_primary>
   ```
2. Переключить Odyssey обратно на исходную топологию:
   ```bash
   ansible-playbook -i inventory.yml odyssey.yml \
     -e "odyssey_write_backend_host=<ip_old_primary>" \
     -e "odyssey_read_backend_host=<ip_read_replica_or_dr>"
   ```

### Шаг 5. Вернуть аварийную реплику в режим ожидания

Реплика, которая временно была writer'ом (из раздела 2), должна снова стать обычной репликой
исходного primary (её `postgresql_replication_role` в inventory и так осталась `read_replica`/
`dr_replica` — не менялась). Это можно сделать штатным прогоном роли — `configure-replica.yml`
обнаружит отсутствие `standby.signal` (узел сейчас primary, не standby) и выполнит `repmgr standby
clone` заново от нового primary:

```bash
ansible-playbook -i inventory.yml postgresql-replicas.yml --limit <replica-host-that-was-promoted>
```

### Шаг 6. Проверить и зафиксировать

- Тестовая запись снова проходит.
- Чтение идёт на read-реплику (или DR, если read-реплики нет), запись — на primary (по логам
  Odyssey, как и в разделе 2, шаг 5).
- Записать время окончания обратного переключения.

---

## Раздел 4. Восстановление из архивной копии на тестовый сервер

Бэкапы (`pgBackRest`) лежат в S3 (Selectel object storage) — см. `roles/postgresql_replication`,
`tasks/backup.yml`. В отличие от `mysql_replication`/`xtrabackup`, восстановление и применение WAL
до нужной точки делает сам `pgbackrest restore` — отдельного `--prepare`-шага не требуется.

### Шаг 1. Установить `pgBackRest` на тестовом сервере

Тот же пакет и репозиторий, что использует роль `postgresql_replication` (PGDG,
`roles/postgresql_replication/tasks/install-repmgr-pgbackrest.yml`).

### Шаг 2. Скопировать конфигурацию доступа к репозиторию

Скопируйте `/etc/pgbackrest.conf` с хоста-источника бэкапа (`postgresql_replication_backup_source_role`,
по умолчанию DR-реплика) на тестовый сервер, поправив `pg1-path` под датадир тестового сервера, если
он отличается.

### Шаг 3. Посмотреть список доступных копий

```bash
sudo -u postgres pgbackrest --stanza=main info
```

### Шаг 4. Восстановить

```bash
systemctl stop postgresql@<version>-main
rm -rf /var/lib/postgresql/<version>/main/*
sudo -u postgres pgbackrest --stanza=main --delta restore
chown -R postgres:postgres /var/lib/postgresql/<version>/main
systemctl start postgresql@<version>-main
```

По умолчанию `pgbackrest restore` восстанавливает на последнюю доступную точку (PITR к более
ранней точке — флаг `--type=time --target="..."`, если нужно откатиться к конкретному моменту, а
не на самую свежую копию).

**Тестовый сервер не должен быть подключен к боевой репликации и не должен участвовать в
Odyssey** — это изолированная проверка, а не ещё одна реплика.

### Шаг 5. Проверить целостность данных

Подключиться и проверить, что ключевые таблицы на месте и выглядят разумно (количество строк,
последние записи по времени — не путать «восстановилось» с «пустая база без ошибок»):

```bash
sudo -u postgres psql -c "SELECT COUNT(*) FROM <table>; SELECT MAX(created_at) FROM <table>;"
```

---

## Раздел 5. Список оповещений

| Алерт | Что означает | Что делать |
|---|---|---|
| `PostgresDown` | primary или реплика недоступны >1 мин | Если это **primary** — начинайте раздел 2 |
| `PostgresReplicationLagTooHigh` (> 300 сек) | read- или DR-реплика отстаёт от primary | Если это read-реплика — сайт продолжает работать, но проверьте нагрузку/сеть. Если DR — не паниковать (не под боевым трафиком, если есть read-реплика), но не затягивать: во время реальной аварии именно её отставание определит потерю данных |
| `PostgresReplicationBroken` (`pg_stat_replication` пуст) | реплика не защищает от аварии, пока не почините | Разобраться в причине (сеть, `pg_hba.conf`, место на диске под WAL); при необходимости — пересоздать реплику (штатный прогон роли переклонирует, см. раздел 3, шаг 5) |
| Суточный бэкап не создался (метрика `postgresql_backup_last_success_timestamp_seconds`) | `postgresql-backup.service` упал или таймер не сработал | `systemctl status postgresql-backup.service`, `journalctl -u postgresql-backup.service`, запустить вручную: `systemctl start postgresql-backup.service` |

**Известное ограничение (см. ROADMAP P0 №1):** доставка алертов (Alertmanager) в коллекции сейчас
не работает ни в docker-, ни в k3s-режиме `monitoring_server`. Правила алертов из этой таблицы
будут срабатывать в VMAlert, но **не дойдут** до дежурного, пока этот баг не закрыт отдельно. До
этого момента отставание/разрыв репликации и пропущенный бэкап нужно проверять руками (команды из
разделов 2–4 выше), не полагаясь на автоматическое оповещение.
