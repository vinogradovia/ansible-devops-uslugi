# CLAUDE.md

Этот файл содержит инструкции для Claude Code (claude.ai/code) при работе с кодом в этом репозитории.

## Обзор проекта

`devops.uslugi` — Ansible collection (`namespace: devops`, `name: uslugi`) с ролями для DevOps-инфраструктуры:
мониторинг (стек VictoriaMetrics/Grafana), DNS, nginx и Traefik reverse proxy. Требует ansible-core
`>=2.20,<2.21` (pyproject, согласовано с `ansible >= 2.19` из meta/runtime.yml) и Python `>=3.12`.
Зависимости управляются через Poetry (`package-mode = false` — pyproject используется только для
управления зависимостями, коллекция не является устанавливаемым Python-пакетом).

## Команды

```bash
poetry install              # установка dev + prod зависимостей
poetry run ansible-lint     # линтинг коллекции (использует .ansible-lint, profile: production)
```

`.ansible-lint` исключает `helm/`, `trial/`, `extentions/` (обратите внимание: реальный каталог
называется `extensions/`, поэтому molecule-контент в `extensions/` сейчас *не* исключён из линтинга —
учитывайте это при добавлении новых molecule-фикстур туда).

### Molecule-тесты

Несколько независимых molecule-наборов (список ниже не исчерпывающий — см. `extensions/molecule/`
целиком, включая `mysql_replication`/`proxysql`, driver `vagrant`, см. соответствующие ADR):

- `extensions/molecule/default/` — сценарий только с `create`/`destroy` (проверка провижининга хоста),
  использует общий inventory из `extensions/molecule/inventory/`.
- `extensions/molecule/nginx_multidomain/` — сценарий для роли `nginx_multidomain`,
  использует `driver: docker` (требует dev-зависимость
  `molecule-plugins[docker]` и Docker на хосте, где запускается molecule): создаёт одноразовый
  systemd-контейнер (`geerlingguy/docker-debian12-ansible`), converge покрывает `type: static`
  и `type: proxy`, verify гоняет реальный `nginx -t` + ansible-based проверки (аналог testinfra).
  Переменные — в `group_vars/all.yml` рядом со сценарием (не в `converge.yml`), чтобы их видели
  и `verify.yml`, и `prepare.yml`. Явно обнуляет унаследованный из `../config.yml`
  `ansible.executor.args.ansible_playbook`, чтобы не подмешивать статический inventory
  `monitoring_servers`/`monitoring_agents` в изолированный docker-прогон.
- `extensions/molecule/reverse_proxy_npm/` — сценарий для роли `reverse_proxy_npm`, тоже
  `driver: docker`, той же структуры, что и `nginx_multidomain` (одноразовый systemd-контейнер,
  `group_vars/all.yml`, обнулённый `ansible_playbook`). Отличие: роль сама разворачивает docker-
  контейнер (NPM), поэтому это docker-in-docker — `prepare.yml` сценария ставит Docker Engine
  внутри тестового контейнера как внешний провижининг хоста (сама роль Docker не устанавливает,
  см. `roles/reverse_proxy_npm/README.md`) и поднимает fixture-бэкенд (`traefik/whoami`) для
  проверки реального проксирования. `verify.yml` намеренно не проверяет
  `reverse_proxy_npm_admin_ui_expose_host: true` — этот путь дёргает настоящий Let's Encrypt
  HTTP-01 через API NPM, а у тестового контейнера нет публичной сети/DNS.
- `extensions/molecule/reverse_proxy_traefik/` — сценарий для роли `reverse_proxy_traefik`, тоже
  `driver: docker`, той же структуры, что `nginx_multidomain`/`reverse_proxy_npm`. Отличие от
  `reverse_proxy_npm`: `reverse_proxy_traefik/meta/main.yml` безусловно зависит от роли `docker`
  (сама ставит Docker Engine пинненой версией из `download.docker.com`), поэтому `prepare.yml`
  сценария Docker Engine вручную не ставит — это делает зависимость роли при `converge`.
  `group_vars/all.yml` передаёт `docker_daemon_json_options: {storage-driver: vfs}` (переменная
  роли `docker`, единственного владельца `/etc/docker/daemon.json`, ADR-0002 §6) — без неё
  свежеустановленный Docker Engine не может смонтировать overlay2 поверх уже overlay2-смонтированной
  файловой системы самого тестового контейнера (классическое ограничение Docker-in-Docker, не
  связанное с тем, стоял ли в образе Docker до этого — см. ADR-0002 §8), как и в
  `reverse_proxy_npm`. Fixture-приложение (`traefik/whoami`) не
  нужно поднимать отдельно — оно уже часть compose-файла самой роли
  (`templates/compose-reverse-proxy-traefik.yml.j2`) в той же docker-сети `proxy`. `verify.yml`
  проверяет HTTP→HTTPS редирект, реальное проксирование на `whoami` и basic-auth дашборда
  (`traefik-dashboard.yml.j2`) — как с валидными credentials, так и без них (401).
- `extensions/molecule/infra_dns/` — сценарий для роли `infra_dns`, тоже `driver: docker`, той же
  структуры, что `nginx_multidomain`/`reverse_proxy_npm`/`reverse_proxy_traefik`. Роль не
  разворачивает вложенный docker (bind9 — обычный systemd-сервис из apt), поэтому, в отличие от
  `reverse_proxy_traefik`/`reverse_proxy_npm`, никакого docker-in-docker/vfs-обхода не нужно.
  Converge покрывает одну forward-зону (`dns.molecule.test`, дефолтный `soa_contact`,
  `include_hosts` по умолчанию `true`) и одну reverse-зону (`10.10.10.in-addr.arpa`, явный
  `soa_contact` — обязателен для reverse-зон, P2-20, — `include_hosts: false`). `verify.yml`
  гоняет реальные `named-checkconf` на полном `/etc/bind/named.conf` и `named-checkzone` на обоих
  зона-файлах (поймал бы P2-19/P2-20), плюс функциональные `dig`-запросы (A, CNAME, `-x`/PTR) —
  named реально резолвит то, что задеплоено, а не просто «конфиг синтаксически верен». `group_vars/
  all.yml` дублирует дефолт роли `infra_dns_zone_dir` явно — `verify.yml` не подключает роль и не
  видит её `defaults/`, а путь к зона-файлам нужен для `stat`/`named-checkzone`.
- `extensions/molecule/monitoring_agent/` — сценарий для роли `monitoring_agent`, `driver: docker`,
  но **две платформы в одном сценарии** (паттерн `mysql_replication`: несколько хостов,
  per-group `group_vars/<group>.yml`), а не отдельные сценарии на каждый оркестратор, как у
  `monitoring_server`/`monitoring_server_k3s` — оба пути `monitoring_agent` достаточно лёгкие для
  контейнера. `monitoring-agent-docker` (`monitoring_agent_orchestrator: docker`): роль тянет
  зависимость на роль `docker` сама (как `reverse_proxy_traefik`), `group_vars` задаёт
  `storage-driver: vfs` — тот же docker-in-docker обход, что и там; `node_exporter` +
  `docker_exporter` (проверка ключа `metrics-addr` в `/etc/docker/daemon.json`); дополнительно
  `verify.yml` изолированно вызывает `exporters-pve-exporter.yml` с `pve_exporter_enabled: true`
  через `block/rescue`, проверяя P0-10 regression (fail-fast, а не молчаливый no-op).
  `monitoring-agent-systemd` (`monitoring_agent_orchestrator: systemd`): `node_exporter` (socket
  activation — `service_facts` не видит `.socket`-юниты, поэтому `node_exporter.socket`
  проверяется напрямую через `systemctl is-active`/`is-enabled`) + `pve_exporter` (позитивный
  путь, `prepare.yml` ставит `python3-venv` внешним провижинингом — роль сама этот пакет не
  ставит). `prepare.yml` докер-хоста дополнительно делает `mount --make-rshared /` — без этого
  вложенный `node_exporter`'у бинд `/:/host:ro,rslave` (официальный паттерн prometheus/node_exporter)
  падает на "path / is mounted on / but it is not a shared or slave mount" (мount-namespace
  тестового контейнера по умолчанию private, а не shared/slave). Первый же прогон поймал реальный
  P0-баг (ROADMAP №36): `pve_exporter`/`mysqld_exporter` крашились сразу после старта под systemd
  (`PermissionError`, читая свой config-файл, который рендерился `root:root`, а сервис работает
  под выделенным `User=`) — исправлено в `roles/monitoring_agent/tasks/{exporters-pve-exporter,
  monitoring-agent,systemd-mysqld-exporter}.yml`.
- `extensions/molecule/docker/` — сценарий для роли `docker` (`docs/adr/0002-docker-role.md`, §8).
  Намеренно **не** `driver: docker` — образ `geerlingguy/docker-debian12-ansible` Docker Engine
  не содержит (проверено эмпирически, вопреки более ранней версии этого документа/ADR-0002 §8),
  но его собственная файловая система уже смонтирована host-Docker'ом через overlay2, и родной
  overlay2-driver вложенного dockerd поверх неё не монтируется (`failed to mount ...`,
  классическое ограничение Docker-in-Docker) без `storage-driver: vfs` — то есть тестировать саму
  роль `docker` в этом образе упёрлось бы в то же ограничение, что и `reverse_proxy_npm`/
  `reverse_proxy_traefik` (см. их сценарии ниже), не добавляя нового покрытия. `test_sequence` ограничен
  `syntax`/`create`/`destroy` (driver по умолчанию, без реального хоста); реальная установка
  проверяется вручную (`molecule converge -s docker`) против хоста из группы `docker_hosts`,
  которую нужно завести в inventory самостоятельно — вне автоматического тестового контура.
- `extensions/molecule/monitoring_server/` — сценарий для роли `monitoring_server`,
  `monitoring_server_orchestrator: docker` (см. `docs/adr/0007-monitoring-server-role.md`, §11).
  `driver: vagrant`/`libvirt`, box `cloud-image/ubuntu-24.04` — **не** `driver: docker`, в отличие
  от `nginx_multidomain`/`reverse_proxy_npm`: роль сама разворачивает многосервисный docker-compose
  стек (VictoriaMetrics, Grafana, Loki, MinIO), докер-в-докере под этим стеком был бы конфликтом
  overlay2. Одна ВМ мониторит сама себя (`groups: [monitoring_servers, monitoring_agents]`, тот же
  паттерн, что `tests/inventory.yml`) — full-стек (VM + Grafana + Loki + MinIO + одна
  dashboard-группа), `verify.yml` проверяет реальный scrape node-exporter, а не только что
  контейнеры подняты.
- `extensions/molecule/monitoring_server_k3s/` — сценарий для той же роли,
  `monitoring_server_orchestrator: k3s` (см. `docs/adr/0007-monitoring-server-role.md`, §6/§11).
  Тоже `driver: vagrant`/`libvirt`, но крупнее (`memory: 6144`, `cpus: 4` — k3s + VictoriaMetrics
  Operator + grafana-operator + 3x grafana-alloy через реальный `Helmwave up`) и **без
  idempotence** в `test_sequence` (задача `Helmwave up` — `ansible.builtin.command` без
  `changed_when`-анализа stdout `helmwave`, всегда `changed=true` на уровне ansible-задачи).
  Требует на control-хосте (том, где запускается molecule, а не на целевой ВМ): CLI `helm` +
  `helmwave`, python-пакет `kubernetes` (dev-зависимость в `pyproject.toml`), и активацию
  зависимости `xanmanning.k3s` (`meta/main.yml`, `tags: [init, never]`) через
  `provisioner.options.tags: all,init` в `molecule.yml` — только эта комбинация включает и
  never-зависимость, и всё остальное (проверено эмпирически, см. ADR §11).

Запускать нужно из корня коллекции (molecule ищет `galaxy.yml` строго в текущей директории —
`Path.cwd()`, без обхода родителей — поэтому `cd` в сам каталог сценария не работает с новыми
версиями molecule) с флагом `-s <имя_сценария>`:

```bash
molecule test -s reverse_proxy_traefik   # либо отдельно: create / converge / verify / destroy
molecule test -s nginx_multidomain
```

**`driver: vagrant` (`mysql_replication`, `proxysql`, `monitoring_server`) — известная проблема
окружения:** установленная связка `molecule` (>=26.3.0) + `molecule-plugins[vagrant]` (>=25.8.0,
см. `pyproject.toml`) не прокидывает автоматически модуль `vagrant`, который поставляется вместе с
`molecule-plugins`, в `ANSIBLE_LIBRARY` — новые версии `molecule` больше не используют
`driver.modules_dir()` для этого (актуально на момент написания: molecule 26.3.0). Без этого любой
vagrant-сценарий падает на первом же шаге (`destroy`/`create`) с
`couldn't resolve module/action 'vagrant'`. Обход — экспортировать `ANSIBLE_LIBRARY` на каталог
`modules/` внутри `molecule_plugins.vagrant` перед запуском:

```bash
export ANSIBLE_LIBRARY="$(dirname "$(poetry run python3 -c 'import molecule_plugins.vagrant as m; print(m.__file__)')")/modules"
poetry run molecule test -s monitoring_server
```

Если апстрим почини́т эту интеграцию (или пины версий в `pyproject.toml` изменятся), проверьте,
не стал ли обходной путь лишним.

`extensions/molecule/config.yml` — общий базовый конфиг (test_sequence:
prepare → converge → verify → idempotence → verify → cleanup, `shared_state: true`), но отдельные
`molecule.yml` сценариев могут переопределять `test_sequence` (например, `default/molecule.yml`
переопределяет его на просто `create, destroy`, а `nginx_multidomain/molecule.yml` — на полный
docker-цикл `destroy → syntax → create → prepare → converge → idempotence → verify → destroy`).

### Запуск playbook'ов на тестовом inventory

```bash
ansible-playbook -i tests/inventory.yml tests/test-monitoring-server.yml
ansible-playbook -i tests/inventory.yml tests/test-monitoring-agent.yml
```

`tests/ansible.cfg` задаёт `roles_path = ../roles:~/.ansible/roles` и `host_key_checking = False`.
`tests/inventory.yml` — основной inventory для ручного тестирования: определяет хост `test-host` для
групп `infra_dns`, `monitoring_agents` и `monitoring_servers` с реалистичными примерами значений
(пароли, тестовые записи зон) — воспринимайте его как локальный test scaffolding, а не production-конфиг.

Запуск только настройки алертов monitoring-server ограничивается тегом:

```bash
ansible-playbook -i inventory.yml monitoring-server.yml \
    --tags monitoring_server_victoria_metrics_exporter_alerts
```

## Архитектура

### Роли (`roles/*`)

- **docker** — переиспользуемый инфраструктурный примитив: устанавливает и настраивает Docker Engine
  + `docker-compose-plugin` из официального репозитория `download.docker.com` (только Debian/Ubuntu,
  apt). Решения и обоснование — см. `docs/adr/0002-docker-role.md`. Не вызывается напрямую из
  плейбуков — подключается зависимостью через `meta/main.yml` у `monitoring_server`,
  `monitoring_agent` (условно, `when: ..._orchestrator == 'docker'`) и `reverse_proxy_traefik`
  (безусловно). Единственный владелец `/etc/docker/daemon.json` — рендерит файл целиком из
  `docker_daemon_json_options` (dict), роли-потребители передают свои ключи через vars зависимости,
  а не пишут в файл сами (см. пример в `roles/monitoring_agent/meta/main.yml` —
  `monitoring_agent_docker_daemon_json_options`).
- **monitoring_server** — разворачивает observability-стек (VictoriaMetrics, Grafana, VMAlert). Два
  параллельных orchestrator-бэкенда, управляемых переменной `monitoring_server_orchestrator`: `docker`
  или `k3s`. `tasks/main.yml` разветвляется на `check-and-install-requirements.{docker,k3s}.yml` и
  `monitoring-server.{docker,k3s}.yml` соответственно. Путь k3s зависит от роли `xanmanning.k3s`
  (объявлена в `roles/monitoring_server/meta/main.yml`, включена через
  `when: monitoring_server_orchestrator == 'k3s'`, теги `init`/`never`, то есть опциональна). Это
  standalone-роль, а не коллекция, поэтому её нельзя объявить зависимостью в `galaxy.yml` (поле
  `dependencies` принимает только `namespace.name` коллекций) — она зафиксирована в
  `requirements.yml` в корне коллекции, ставится через `ansible-galaxy install -r requirements.yml`.
  Путь
  docker зависит от роли `docker` (та же `meta/main.yml`, `when: monitoring_server_orchestrator ==
  'docker'`, без тегов `init`/`never` — это дефолтный путь, а не опциональный). Для k3s scrape-
  таргеты и алерты управляются как нативные Kubernetes CRD (`VMScrapeConfig`/`ConfigMap`, `VMRule`),
  применяемые напрямую через ansible; сами операторы (VictoriaMetrics Operator, grafana-operator),
  которые эти CRD обслуживают, ставит `Helmwave up` — обёртка над Helm поверх примера
  `helmwave`-конфигурации в `helm/` (`docs/adr/0007-monitoring-server-role.md`, §6). Активация
  зависимости `xanmanning.k3s` требует `--tags all,init` при запуске (см. «Molecule-тесты» выше,
  `monitoring_server_k3s`).
- **monitoring_agent** — устанавливает экспортеры на мониторируемые хосты, либо как systemd-сервисы
  (`tasks/systemd-*-exporter.yml`, по одному на экспортер: node, mysqld, redis, nginx, nginxlog,
  php-fpm, ipa, pve), либо как docker-контейнеры — в зависимости от `monitoring_agent_orchestrator`.
  Docker-путь зависит от роли `docker` (`meta/main.yml`); установку Docker Engine и владение
  `/etc/docker/daemon.json` роль сама больше не делает — `docker_exporter` передаёт свой ключ
  `metrics-addr` через `monitoring_agent_docker_daemon_json_options` в vars зависимости.
- **infra_dns** — настраивает bind9 (зоны, forwarders, ACL) на основе списка зон из inventory.
- **nginx_multidomain** — единственная nginx-роль в коллекции (роль `nginx` была экспериментом и
  удалена — `nginx_multidomain` её замена). Роль для мульти-доменных конфигураций в стиле shared
  hosting (per-domain vhost'ы static/proxy, агрегация rate-limit и proxy-cache зон, stub_status,
  custom-сертификаты). **Реализована частично** — см.
  `docs/adr/0003-ginx-multidomain-role.md`, который описывает
  фактическую реализацию (не задуманную архитектуру) и явно фиксирует, что ещё не сделано
  (`validate_domains.yml`, `certificates_letsencrypt.yml`, генерация htpasswd для `basic_auth`,
  `logrotate.yml`, шаблон php-fpm vhost'а, `meta/main.yml`), а также известные баги в уже
  существующем коде (включение `basic_auth`/`logs.format: json` ломает `nginx -t`, утечка
  `set_fact` между итерациями цикла доменов). Molecule-покрытие теперь есть —
  `extensions/molecule/nginx_multidomain/` (см. раздел «Molecule-тесты» выше). Перед доработкой роли сверяйтесь с этим
  документом, чтобы новый код соответствовал фактической схеме переменных (список `nginx_domains`,
  логика дедупликации `rate_limit.zone_name`, семантика override в `custom_locations`, работающая
  только для `location /`).
- **reverse_proxy_traefik** — настраивает Traefik в Docker. Зависит от роли `docker`
  (безусловно, `meta/main.yml`) — раньше сама не устанавливала Docker Engine и падала на чистом
  хосте (закрытый баг, см. `ROADMAP.md` P2 №17).
- **reverse_proxy_npm** — разворачивает [Nginx Proxy Manager](https://nginxproxymanager.com/) в
  docker и управляет его proxy-хостами декларативно через REST API (кастомный модуль
  `devops.uslugi.npm_proxy` в `plugins/modules/`, порт которого — из
  https://github.com/DenAV/nginx-proxy-manager-ansible, MIT). Узкоспециализированная альтернатива
  для операторов/клиентов, которым нужен GUI, а не IaC через YAML — **взаимоисключающая** с
  `nginx_multidomain`/`reverse_proxy_traefik` на одном хосте (конфликт портов 80/443). Решения и их
  обоснование — см. `docs/adr/0001-reverse-proxy-npm-role.md`: только `docker`-оркестратор,
  fail-fast на дефолтном admin-пароле NPM (API-вызов при первом converge, а не просто assert),
  SQLite по умолчанию/MySQL опционально, admin UI (порт 81) по умолчанию только на loopback,
  внешний доступ — через self-managed proxy-host `npm-ui-<host>.<domain>` внутри самого NPM, а не
  прямой проброс порта. Molecule-покрытие — `extensions/molecule/reverse_proxy_npm/` (docker
  driver, docker-in-docker: сама роль Docker не ставит, prepare.yml сценария устанавливает его как
  внешний провижининг хоста).

### Добавление нового экспортера мониторинга

Чтобы полностью подключить новый экспортер (см. также `AGENTS.md` — канонический walkthrough):

1. Добавить шаблон(ы) alert-правил в `roles/monitoring_server/templates/alert-rules/<exporter>.yml`.
2. Добавить серверные переменные по умолчанию в `roles/monitoring_server/defaults/main.yml`:
   `monitoring_server_victoria_metrics_scrape_<exporter>`,
   `..._scrape_<exporter>_port_default`, `..._alerts_rules_<exporter>_default`.
3. Добавить переменные по умолчанию на стороне агента в `roles/monitoring_agent/defaults/main.yml`:
   `monitoring_agent_<exporter>_enabled`, `_image_registry`, `_image_repository`, `_image_version`,
   `_image`, `_port`, `_systemd_name`, `_binary_download_url`, `_binary_install_path`.
4. Зарегистрировать экспортер новым элементом массива `monitoring_server_victoria_metrics_exporters`
   в `roles/monitoring_server/vars/main.yml` (поля: `name`, `scrape_src`, `scrape_dest`,
   `scrape_state`, `alert_rules_default_enabled`, `alert_rules_src`).

### ADDONS

`ADDONS/exporters/` содержит самостоятельные реализации экспортеров (freeipa_exporter, redis-exporter)
с собственной документацией по установке/systemd/деплою в k3s, на которые ссылаются роли мониторинга выше.
`ADDONS/grafana_dashboards/` содержит JSON дашбордов, используемых через
`monitoring_server_grafana_dashboards_group_install`.

### Прочие директории

- `trial/swissmakers/fail2ban-ui/` — сторонний вендоренный проект (со своим `.git`, Go + Tailwind),
  не является Ansible-контентом этой коллекции; исключён из ansible-lint.
- `helm/` — сейчас пустой каталог-заготовка (исключён из ansible-lint); k3s-стек мониторинга Helm
  charts *не* использует (см. заметки про monitoring_server выше).
- `uslugi/` — оставшаяся локальная директория с артефактами `.ansible`/`.vscode`, не является исходным кодом.
