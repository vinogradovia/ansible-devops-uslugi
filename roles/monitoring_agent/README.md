# monitoring_agent

Устанавливает экспортеры на мониторируемые хосты — источники метрик для `monitoring_server`.
В отличие от `monitoring_server`, отдельного ADR у роли нет; архитектурные детали и история
найденных багов — в `CLAUDE.md` (раздел «Molecule-тесты», описание сценария
`monitoring_agent`) и в самом коде задач.

## Оркестратор

`monitoring_agent_orchestrator: docker | systemd` (дефолт `docker`) переключает способ установки
экспортёров:

- **`docker`** — экспортёры разворачиваются как контейнеры. Роль зависит от `docker`
  (`meta/main.yml`, `when: monitoring_agent_orchestrator == 'docker'`) — установку Docker Engine и
  владение `/etc/docker/daemon.json` сама роль не делает; `docker_exporter` передаёт свой ключ
  `metrics-addr` через `monitoring_agent_docker_daemon_json_options` в vars зависимости (единая
  точка владения файлом — см. `docs/adr/0002-docker-role.md`).
- **`systemd`** — каждый экспортёр ставится отдельным systemd-юнитом
  (`tasks/systemd-*-exporter.yml`, по одному файлу на экспортёр).

## Экспортёры

Общий паттерн переменных на экспортёр: `monitoring_agent_<exporter>_enabled` +
`_image_registry`/`_image_repository`/`_image_version`/`_image` (docker-путь) и
`_systemd_name`/`_binary_download_url`/`_binary_checksum`/`_binary_install_path` (systemd-путь).
Полный образец — `monitoring_agent_mysqld_exporter_*` в `defaults/main.yml` (используется как
шаблон при добавлении нового экспортёра, см. корневой `README.md`).

| Экспортёр | docker | systemd | Примечание |
|---|---|---|---|
| `node_exporter` | ✅ | ✅ | Под systemd — socket activation (`node_exporter.socket`), проверяется через `systemctl is-active`/`is-enabled` напрямую (`service_facts` не видит `.socket`-юниты) |
| `docker_exporter` | ✅ | — | Патчит `/etc/docker/daemon.json` через зависимость на роль `docker` |
| `cadvisor` | ✅ | — | Только docker (сам концептуально контейнерный) |
| `redis_exporter` | ✅ | ✅ | |
| `nginx_exporter` | ✅ | ✅ | Требует `nginx_exporter_scrape_uri` (например, `stub_status`-эндпоинт) |
| `nginxlog_exporter` | ✅ | ✅ | Парсит access-логи nginx; группа `adm` для доступа к `/var/log/nginx` без root |
| `php_fpm_exporter` | ✅ | ✅ | Требует `php_fpm_exporter_scrape_uri` (tcp:// или unix://) |
| `ipa_exporter` | ✅ | ✅ | Кастомный бинарь коллекции (`ADDONS/exporters/freeipa_exporter`) |
| `mysqld_exporter` | ✅ | ✅ | |
| `postgres_exporter` | — | ✅ | Только systemd; отдельный exporter-пользователь (роль `pg_monitor`), не repmgr/repl-пользователи `postgresql_replication` |
| `pve_exporter` | — (TODO) | ✅ | Требует `python3-venv` на хосте — роль его не ставит |
| `alloy` (grafana-alloy) | ✅ | ✅ | Только self-мониторинг (`config.alloy` пустой, `alloy_build_info`), embedded exporter (ROADMAP Backlog №34) |
| `promtail` | ✅ | ✅ | Отправка логов в Loki (`monitoring_agent_promtail_loki_addr`) |
| `prom_client` | — | — | Флаг заведён, установки/конфигурации в роли нет — приложение само экспортирует метрики |

## Обязательные шаги перед использованием

- `pve_exporter`: `python3-venv` должен быть установлен на хосте заранее (`prepare.yml`
  molecule-сценария ставит его как внешний провижининг — сама роль этот пакет не ставит).
- `ipa_exporter`: требует `monitoring_agent_ipa_exporter_{hosts,domain,user,password}` — без них
  запуск бинарём завершится ошибкой подключения к FreeIPA.
- `mysqld_exporter`/`postgres_exporter`: конфиг с паролем рендерится с владельцем, соответствующим
  выделенному `User=` unit-файла — исторически (ROADMAP №36) конфиг рендерился `root:root`, а
  сервис работал под непривилегированным пользователем, что роняло сервис `PermissionError` сразу
  после старта; сейчас исправлено, учитывайте при кастомизации `tasks/systemd-*-exporter.yml`.

## Molecule

`extensions/molecule/monitoring_agent/` — **две платформы в одном сценарии** (несколько хостов,
per-group `group_vars/<group>.yml`, паттерн `mysql_replication`), а не отдельные сценарии на
каждый оркестратор:

- `monitoring-agent-docker` — роль тянет зависимость на роль `docker` сама; покрывает
  `node_exporter` + `docker_exporter` (проверка ключа `metrics-addr` в
  `/etc/docker/daemon.json`); дополнительно изолированно вызывает `exporters-pve-exporter.yml` с
  `pve_exporter_enabled: true` через `block/rescue`, проверяя fail-fast (ROADMAP P0-10) вместо
  молчаливого no-op.
- `monitoring-agent-systemd` — `node_exporter` (socket activation) + `pve_exporter` (позитивный
  путь).

Оба хоста дополнительно покрывают `alloy` — единственный экспортёр, поддержанный на обоих
оркестраторах. Подробности первых прогонов (два найденных P0-бага — конфиг exporter'ов с
неверным владельцем и безусловный `notify` на несуществующий под docker юнит) — см. `CLAUDE.md`,
раздел «Molecule-тесты».
