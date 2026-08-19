# monitoring_server

Разворачивает observability-стек: [VictoriaMetrics](https://victoriametrics.com/) (метрики),
[Grafana](https://grafana.com/) (визуализация), VMAlert (алерты), опционально
[Grafana Loki](https://grafana.com/oss/loki/) (логи) + [MinIO](https://min.io/) (локальный S3 для
Loki). Полная архитектура и обоснование решений — см.
[`docs/adr/0007-monitoring-server-role.md`](../../docs/adr/0007-monitoring-server-role.md). Этот
README — краткая выжимка для повседневного использования, за деталями — в ADR.

## Оркестратор

`monitoring_server_orchestrator: docker | k3s` (дефолт `docker`) переключает реализацию
целиком — `tasks/main.yml` разветвляется на `check-and-install-requirements.{docker,k3s}.yml` +
`monitoring-server.{docker,k3s}.yml`.

- **`docker`** — роль сама разворачивает многосервисный docker-compose стек. Зависит от роли
  `docker` (`meta/main.yml`, безусловно).
- **`k3s`** — scrape-таргеты и алерты управляются как нативные Kubernetes CRD
  (`VMScrapeConfig`/`ConfigMap`, `VMRule`), применяемые напрямую через ansible; сами операторы
  (VictoriaMetrics Operator, grafana-operator) ставит `Helmwave up` поверх примера конфигурации в
  `helm/` (ADR §6). Зависит от standalone-роли `xanmanning.k3s` (не коллекция — ставится отдельно
  через `requirements.yml` в корне коллекции, см. корневой `README.md`), подключаемой тегами
  `init`/`never` — требует явного `--tags all,init` при запуске.

**Важное отличие docker/k3s**: alert-правила (VMAlert/VMRule) реализованы **только для k3s**
(ADR §7, ROADMAP P0-1/P5-33) — в docker-режиме нет `vmalert`-сервиса. Все
`monitoring_server_victoria_metrics_alerts_rules_*_default` гейтятся на
`monitoring_server_orchestrator == 'k3s'`; явное включение алертов под docker падает понятным
`fail` на этапе `check-and-install-requirements.docker.yml`, а не молча игнорируется.

## Обязательные шаги перед использованием

- `monitoring_server_grafana_security_admin_password` — если `monitoring_server_grafana_enabled:
  true`, не оставляйте дефолтный `monitoring_server_default_password`
  (`"PleAse_Change_ME!"`) — используется и Grafana admin-паролем, и (см. другие роли платформы)
  общим паттерном дефолтного пароля коллекции.
- `monitoring_server_grafana_loki_enabled: true` требует
  `monitoring_server_local_storage_s3_enabled: true` — `loki-config.yaml.j2` хардкодит
  `object_store: s3` (локальной файловой альтернативы не реализовано), роль явно падает `fail`,
  если условие не выполнено.
- Для k3s: `monitoring_server_helmwave_dir`/`monitoring_server_helmwave_k8s_cluster` должны
  указывать на реальный `helm/envs/<cluster>.yaml` — дефолт `k3s-monitoring` соответствует
  единственному env-файлу, поставляемому с коллекцией; при своём наборе Helm-релизов
  переопределите под своё имя.

## Экспортеры и scrape-конфигурация

11 экспортёров + `blackbox`/`nodejs_exporter` управляются парой переменных на экспортёр:
`monitoring_server_victoria_metrics_scrape_<exporter>` (включить scrape) и
`..._alerts_rules_<exporter>_default` (алерты, только k3s). Список экспортёров и сопоставление
scrape/alert-файлов — `vars/main.yml` (`monitoring_server_victoria_metrics_exporters`). Как
добавить новый экспортёр — см. корневой `README.md`, раздел «Добавление нового экспортёра», и
`CLAUDE.md`.

Включение `monitoring_server_victoria_metrics_scrape_blackbox` или `..._nodejs_exporter` (оба
`false` по умолчанию) в docker-режиме падает понятным `fail` — это k3s-only экспортёры без
`dest`-пути для docker-рендеринга.

## Grafana

- `monitoring_server_grafana_dashboards_group_defaults_<group>` — предустановленные группы
  дашбордов (mysql, node_exporter, postgres_exporter, pve1, nginx, blackbox, php_fpm, prom_client,
  freeipa, redis) из `ADDONS/grafana_dashboards/`, каждая с `enable: false` по умолчанию.
  Включаются через `monitoring_server_grafana_dashboards_group_install`.
- Provisioning дашбордов работает одинаково в обоих оркестраторах
  (`monitoring_server_grafana_dashboard_provisioning`, безусловно `true` для k3s, для docker —
  равен `monitoring_server_grafana_enabled`).

## Локальный S3 (MinIO) и Loki

`monitoring_server_local_storage_s3_enabled: true` поднимает MinIO как локальный
S3-совместимый бэкенд (используется Loki для хранения чанков/индекса, `object_store: s3`
захардкожен — см. выше). Ключи доступа — `monitoring_server_local_storage_s3.{access_key,secret_key}`,
без дефолта, отличного от plaintext-примера в `defaults/main.yml` — обязательно переопределяйте
в проде.

## Molecule

- `extensions/molecule/monitoring_server/` — `monitoring_server_orchestrator: docker`, полноразмерная
  ВМ (vagrant/libvirt), full-стек (VM + Grafana + Loki + MinIO), ВМ мониторит сама себя.
- `extensions/molecule/monitoring_server_k3s/` — `monitoring_server_orchestrator: k3s`, крупнее
  (`memory: 6144`, `cpus: 4`), без idempotence в `test_sequence` (`Helmwave up` — не
  changed-анализируемая команда). Требует на control-хосте CLI `helm`+`helmwave` и python-пакет
  `kubernetes` (dev-зависимость в `pyproject.toml`).

Подробности запуска (обходной путь `ANSIBLE_LIBRARY` для vagrant-driver, флаги
`--tags all,init` для k3s) — см. `CLAUDE.md`, раздел «Molecule-тесты».
