# ADR-0002: Роль `docker` (установка и настройка Docker Engine)

- **Статус:** Принято
- **Дата:** 2026-07-05
- **Авторы:** Ivan Vinogradov (решения), Claude Code (оформление по итогам обсуждения)

## Контекст

Три роли коллекции полагаются на Docker как оркестратор, но ни одна не устанавливает сам Docker
Engine — предполагается, что он уже стоит на хосте:

- `monitoring_server` (`monitoring_server_orchestrator: docker`, дефолт) —
  `tasks/monitoring-server.docker.yml` вызывает `community.docker.docker_compose_v2` напрямую.
- `monitoring_agent` (`monitoring_agent_orchestrator: docker`, дефолт) — аналогично в
  `tasks/monitoring-agent.yml`.
- `reverse_proxy_traefik` — `check-and-install-requirements.yml` ставит только `python3-passlib`;
  Docker не устанавливается вовсе, при этом `dependencies: []` в `meta/main.yml`.

Это уже задокументированный баг (`ROADMAP.md`, P2 №17): на чистом хосте `reverse_proxy_traefik`
падает на шаге создания compose-сервисов из-за отсутствия Docker. У `monitoring_server`/
`monitoring_agent` та же дыра маскируется тем, что тестовые хосты обычно уже содержат Docker.

Дополнительная сложность: `monitoring_agent` уже управляет `/etc/docker/daemon.json` —
`tasks/monitoring-agent.yml:95-127` делает read-merge-write (touch → slurp → `combine()` →
`copy`) конкретно ключа `metrics-addr` для `docker_exporter`
(`monitoring_agent_docker_exporter_docker_daemon_json`, `defaults/main.yml:34-40`). Если новая
роль тоже начнёт писать в этот файл, получится два независимых источника правды на один файл —
это нужно было явно развести.

Обсуждение (см. вопросы/ответы в диалоге) закрыло восемь развилок; фиксирую решения ниже.

## Решения

### 1. Назначение и место среди существующих ролей

**Решение:** `docker` — переиспользуемый инфраструктурный примитив (в отличие от остальных
доменных ролей коллекции — `monitoring_server`, `monitoring_agent`, `infra_dns`,
`nginx_multidomain`, `reverse_proxy_traefik`). Устанавливает и настраивает только сам Docker
Engine + compose-плагин; не разворачивает никаких прикладных контейнеров.

### 2. Подключение потребителями

**Решение:** зависимость через `meta/main.yml`, по аналогии с уже существующим паттерном
`xanmanning.k3s` в `monitoring_server/meta/main.yml`.

- `monitoring_server`, `monitoring_agent`: условно —
  `when: monitoring_server_orchestrator == 'docker'` /
  `when: monitoring_agent_orchestrator == 'docker'`. **Без** тегов `init`/`never` — в отличие от
  `xanmanning.k3s`, docker-ветка не опциональна, а дефолтный путь обеих ролей
  (`orchestrator: docker` — текущее значение по умолчанию в обеих `defaults/main.yml`), так что
  зависимость должна выполняться в обычном прогоне, а не только по явному тегу.
- `reverse_proxy_traefik`: безусловно (там нет альтернативного оркестратора вообще) — заодно
  закрывает ROADMAP P2 №17.

### 3. Способ установки Docker Engine

**Решение:** официальный репозиторий `download.docker.com` (apt), пакеты `docker-ce`,
`docker-ce-cli`, `containerd.io`, `docker-compose-plugin`. GPG-ключ — через современный
`signed-by`-keyring (`/etc/apt/keyrings/docker.gpg` + `deb [signed-by=...]`), **не** через
`ansible.builtin.apt_key` (устаревший модуль; в `nginx_multidomain/tasks/install_repo.yml` он
используется, но там это осознанно оставлено как техдолг «для простоты первого среза» — в новой
роли эту ошибку не повторяем).

**Отклонено:** convenience-скрипт `get.docker.com` (сам Docker не рекомендует его для prod;
`curl | sh` без проверки подписи — тот же класс риска, что уже отмечен в ROADMAP P1 №13 для
скачивания бинарников экспортеров без checksum) и пакет из репозитория дистрибутива (версия
жёстко привязана к версии ОС, не даёт контроля над версией compose v2).

### 4. Поддержка ОС

**Решение:** только Debian/Ubuntu (apt) — совпадает с текущим scope всей коллекции (единственный
прецедент подключения стороннего репозитория, `nginx_multidomain/tasks/install_repo.yml`, тоже
apt-only; molecule-хосты коллекции — `geerlingguy/docker-debian12-ansible`). RHEL/dnf — вне
scope, не начинать вторую ветку логики без реального запроса.

### 5. Версионирование

**Решение:** обязательный пин через переменные (`docker_version`, `docker_compose_plugin_version`
и т.п.) с конкретным значением по умолчанию в `defaults/main.yml` — **не** `state: latest`.
Соответствует паттерну версионирования образов экспортеров в `monitoring_agent/defaults/main.yml`
(`*_image_version` на каждый экспортер). Требует ручного бампа при обновлениях, но исключает
неожиданный major-апгрейд Docker на проде при повторном `converge`/прогоне плейбука.

### 6. Владение `/etc/docker/daemon.json`

**Решение:** роль `docker` — единственный владелец файла, рендерит его целиком из переменной
(словарь `docker_daemon_json_options`, объединяющий дефолт роли с тем, что передадут
роли-потребители), а не через read-merge-write чужого файла.

**Действие при реализации (миграция `monitoring_agent`):** убрать блок
`tasks/monitoring-agent.yml:95-127` (touch/slurp/combine/copy). Вместо этого
`monitoring_agent` передаёт свой ключ `metrics-addr` через vars зависимости в своём
`meta/main.yml`:

```yaml
dependencies:
  - role: docker
    when: monitoring_agent_orchestrator == 'docker'
    vars:
      docker_daemon_json_options: "{{ monitoring_agent_docker_daemon_json_options }}"
```

где `monitoring_agent_docker_daemon_json_options` в `defaults/main.yml` вычисляется из уже
существующих `monitoring_agent_docker_exporter_enabled` /
`monitoring_agent_docker_exporter_patch_docker` /
`monitoring_agent_docker_exporter_docker_daemon_metrics_addr` (те же переменные, просто без
собственной задачи записи файла). Переменная `monitoring_agent_docker_exporter_docker_daemon_json`
(путь к файлу) в этой модели больше не нужна — путь теперь целиком внутри роли `docker`.

### 7. Доступ без root (группа `docker`)

**Решение:** переменная-список `docker_users: []` в `defaults/main.yml` — роль добавляет
перечисленных пользователей в группу `docker` (`ansible.builtin.user: groups: docker,
append: true`). Пусто по умолчанию — остальные роли коллекции и так работают через `become`/root,
это опция для операторов/CI-юзеров, а не обязательная часть роли.

### 8. Molecule-тестирование

**Решение:** сценарий только `create`/`destroy` (или синтаксис/idempotence через `--check`), по
образцу `extensions/molecule/default/`. Реальную установку Docker Engine в CI не проверяем:
роли, которые сами разворачивают вложенные docker-контейнеры (`reverse_proxy_npm`,
`reverse_proxy_traefik` — через зависимость от роли `docker`), тестируются `driver: docker` с
образом `geerlingguy/docker-debian12-ansible` и требуют `docker_daemon_json_options:
{storage-driver: vfs}` — **не** потому, что в образе уже есть предустановленный Docker (проверено
эмпирически: его там нет), а из-за классического ограничения Docker-in-Docker — файловая система
самого тестового контейнера уже смонтирована внешним Docker-хоста через overlay2, и родной
overlay2-driver вложенного dockerd поверх неё (overlay2-на-overlay2) не монтируется
(`failed to mount ... invalid argument`). Тестировать саму роль `docker` (устанавливающую Docker
Engine) в таком контейнере означало бы упереться в то же ограничение — не потому, что она
конфликтовала бы с уже стоящим Docker, а потому, что свежеустановленный Docker всё равно уткнулся
бы в overlay2-на-overlay2, если не задать тот же `storage-driver: vfs`. Раз обходной путь всё
равно нужен, а сама установка Docker Engine уже покрыта empirически через зависящие от неё роли
(`reverse_proxy_npm`/`reverse_proxy_traefik`, где `docker`-роль реально устанавливает Docker
Engine в рамках их `converge`), отдельная `driver: docker`-проверка для самой роли `docker`
не добавляет покрытия, а только усложняет сценарий. Ручная/staging-проверка на реальном хосте
(`molecule converge -s docker` против группы `docker_hosts`) — вне автоматического тестового
контура этой роли.

### 9. Наименование роли

**Решение:** `docker` — короткое имя, соответствует общепринятым именам ролей-примитивов в
экосистеме Ansible Galaxy (`geerlingguy.docker` и т.п.). Отличается по стилю от доменных имён
остальных ролей коллекции (`monitoring_server`, `infra_dns`), но это осознанно: роль не является
доменной, а подключается только как зависимость через `meta/main.yml` (см. §2), напрямую из
плейбуков не вызывается.

## Открытые вопросы / вне скоупа

- RHEL/Rocky (dnf) — не начинать, пока нет конкретного запроса (см. §4).
- Rootless Docker — не рассматривался, доступ без root ограничен группой `docker` (§7).
- Взаимодействие Docker с iptables/nftables хоста (Docker по умолчанию сам управляет
  iptables-правилами, что может конфликтовать с внешним firewall-management) — не обсуждалось,
  зафиксировать при реализации, если станет проблемой на практике.
- Подключение к `reverse_proxy_npm` (см. ADR-0001, §4 — роль пока не реализована) — когда дойдёт
  до реализации, она тоже должна получить `docker` через `meta/main.yml` по этому же паттерну.

## Ссылки

- `ROADMAP.md`, P2 №17 — баг, который закрывает эта роль (`reverse_proxy_traefik` без Docker на
  чистом хосте).
- `ROADMAP.md`, P0 №9 и P1 №13 — прецеденты, повлиявшие на решения §3 и §6 (сломанный Jinja-патч
  `daemon.json`, отсутствие checksum-проверки при скачивании бинарников).
- `roles/monitoring_server/meta/main.yml` — прецедент `dependencies` с условным `when` (паттерн
  для §2), только без тегов `init`/`never`, т.к. docker — не опциональный путь.
- `roles/nginx_multidomain/tasks/install_repo.yml` — прецедент подключения стороннего apt-репо
  (и антипаттерн `apt_key`, который в новой роли не повторяем, см. §3).
- `docs/adr/0001-reverse-proxy-npm-role.md` — тот же класс решений (§10 там: `orchestrator: docker`
  без выбора k3s для контейнеризованных «готовых приложений»).
