# Реестр компонентов

Список всех ролей коллекции (`roles/*`) со ссылками на их документацию. Общий обзор целей и
задач проекта — [`docs/overview.md`](overview.md).

Легенда столбцов: **README** — собственная документация роли; **ADR** — архитектурное решение и
его обоснование; **Runbook** — процедура на случай инцидента; **Molecule** — сценарий
воспроизводимой проверки в `extensions/molecule/`.

| Роль | Назначение | README | ADR | Runbook | Molecule | Статус |
|---|---|---|---|---|---|---|
| [`docker`](../roles/docker/README.md) | Docker Engine + compose-plugin — переиспользуемый инфраструктурный примитив | ✅ | [0002](adr/0002-docker-role.md) | — | `docker` (только syntax/create/destroy — см. README, роль проверяется через реальные ВМ зависимых ролей) | готово |
| [`monitoring_server`](../roles/monitoring_server/README.md) | Observability-стек: VictoriaMetrics/Grafana/VMAlert/Loki (`docker` или `k3s`) | ✅ | [0007](adr/0007-monitoring-server-role.md) | — | `monitoring_server`, `monitoring_server_k3s` | готово |
| [`monitoring_agent`](../roles/monitoring_agent/README.md) | Экспортеры на мониторируемых хостах (systemd или docker) | ✅ | — (архитектура задокументирована в `CLAUDE.md`, не в отдельном ADR) | — | `monitoring_agent` (2 платформы: docker + systemd) | готово |
| [`reverse_proxy_traefik`](../roles/reverse_proxy_traefik/README.md) | Traefik reverse proxy в docker, автообнаружение через labels | ✅ | — | — | `reverse_proxy_traefik` | готово |
| [`reverse_proxy_npm`](../roles/reverse_proxy_npm/README.md) | Nginx Proxy Manager — GUI/REST API вместо IaC | ✅ | [0001](adr/0001-reverse-proxy-npm-role.md) | — | `reverse_proxy_npm` | готово |
| [`nginx_multidomain`](../roles/nginx_multidomain/README.md) | nginx для shared hosting (multi-domain YAML-конфиг) | ✅ | [0003](adr/0003-nginx-multidomain-role.md) | — | `nginx_multidomain` | реализована частично (letsencrypt/basic_auth/json-логи — см. ADR §8–9) |
| [`infra_dns`](../roles/infra_dns/README.md) | bind9 — forward/reverse-зоны из inventory | ✅ | — | — | `infra_dns` | готово |
| [`mysql_replication`](../roles/mysql_replication/README.md) | MySQL HA: GTID-репликация "звездой", бэкапы в S3 или Bareos, ручной promote | ✅ | [0004](adr/0004-mysql-ha-replication-role.md), [0010](adr/0010-backup-agent-role.md) | [mysql-failover.md](runbooks/mysql-failover.md) | `mysql_replication` | готово |
| [`proxysql`](../roles/proxysql/README.md) | Единая точка подключения к MySQL (writer/reader hostgroups) | ✅ | [0004 §6](adr/0004-mysql-ha-replication-role.md) | [mysql-failover.md](runbooks/mysql-failover.md) | `proxysql` | готово |
| [`postgresql_replication`](../roles/postgresql_replication/README.md) | PostgreSQL HA: streaming-репликация под repmgr, бэкапы pgBackRest в S3 | ✅ | [0005](adr/0005-postgresql-ha-replication-role.md) | [postgresql-failover.md](runbooks/postgresql-failover.md) | `postgresql_replication` | готово |
| [`odyssey`](../roles/odyssey/README.md) | Единая точка подключения к PostgreSQL (Yandex Odyssey) | ✅ | [0005 §6](adr/0005-postgresql-ha-replication-role.md) | [postgresql-failover.md](runbooks/postgresql-failover.md) | `odyssey` | готово |
| [`backup_server`](../roles/backup_server/README.md) | Bareos director + storage daemon + catalog + web UI | ✅ | [0009](adr/0009-backup-server-role.md) | — | `backup_server` | MVP |
| [`backup_agent`](../roles/backup_agent/README.md) | Bareos file daemon на бэкапируемом хосте | ✅ | [0010](adr/0010-backup-agent-role.md) | — | `backup_agent` | готово |
| [`fail2ban`](../roles/fail2ban/README.md) | Fail2Ban — jail'ы под интеграции коллекции (nginx, NPM и др.) | ✅ | — | — | `fail2ban` | готово |
| [`fail2ban_ui`](../roles/fail2ban_ui/README.md) | Веб-панель Fail2Ban (обёртка над swissmakers/fail2ban-ui) | ✅ | — | — | `fail2ban_ui` | готово |
| [`infra_panel`](../roles/infra_panel/README.md) | homer — дашборд-стартовая страница платформы | ✅ | [0008](adr/0008-infra-panel-role.md) | — | `infra_panel` | готово (docker), частично (k3s — см. ADR §2) |
| [`freeipa`](../roles/freeipa/README.md) | FreeIPA — LDAP + Kerberos KDC + CA, центральный каталог платформы | ✅ | [0011](adr/0011-freeipa-role.md) | [create-platform-user.md](runbooks/create-platform-user.md) | `freeipa` | готово |

## Архитектура решена, роль не реализована

| Компонент | Назначение | ADR | Закрывает |
|---|---|---|---|
| Harbor | Self-hosted OCI registry для Execution Environment | [0012 §1](adr/0012-cicd-platform-architecture.md) | — |
| Gitea | Self-hosted git + CI (Gitea Actions; раннер `molecule` — вне k3s) | [0012 §4](adr/0012-cicd-platform-architecture.md) | ROADMAP №52 |
| Semaphore UI | Веб-панель запуска ansible/terraform | [0012 §5](adr/0012-cicd-platform-architecture.md) | ROADMAP №50 |
| OpenBao | Внешнее хранилище секретов (Vault-совместимый форк — HashiCorp Vault geo-blocked) | [0012 §3](adr/0012-cicd-platform-architecture.md) | — |
| Authelia (имя роли не выбрано) | OIDC-провайдер поверх `freeipa` (LDAP-федерация), `forwardAuth` для admin-панелей | [0013](adr/0013-unified-auth-architecture.md) | ROADMAP №49 |

## Что не является ролью коллекции, но относится к документации

- [`ROADMAP.md`](../ROADMAP.md) — приоритизированный журнал находок код-ревью по всем ролям
  выше.
- [`docs/adr/0006-demo-stand.md`](adr/0006-demo-stand.md) — архитектура демо-стендов
  (`demo/*`), а не отдельной роли.
- `demo/samba-server/` — Terraform+ansible стенд вне ролей коллекции (собственные задачи, не
  оформлен как переиспользуемая роль).
- `ADDONS/exporters/` — самостоятельные реализации экспортеров (freeipa_exporter,
  redis-exporter) со своей документацией, на которые ссылаются роли мониторинга выше.
